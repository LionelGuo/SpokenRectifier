//! Microphone capture over cpal: the default input device, converted to
//! the one format downstream code understands (16 kHz mono s16, 100 ms
//! frames).
//!
//! The capture thread owns the cpal stream; dropping the returned receiver
//! stops it (sends start failing, the thread parks out, the stream drops).
//! Device failures arrive as [`MicEvent::Error`] rather than a panic — a
//! pulled USB mic ends the frame flow with an explanation.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{InputCallbackInfo, SampleFormat, StreamConfig};

use crate::convert::Resampler;
use crate::diag;
use crate::vad::FRAME_SAMPLES;

/// What the capture thread sends upstream.
#[derive(Debug, Clone)]
pub enum MicEvent {
    /// One 100 ms frame of 16 kHz mono s16 ([`FRAME_SAMPLES`] long).
    Frame(Vec<i16>),
    /// The device failed; no further frames will arrive.
    Error(String),
}

/// Converts arbitrary capture chunks into whole frames, buffering the
/// remainder across callbacks.
struct CapturePipeline {
    resampler: Resampler,
    buffer: Vec<i16>,
}

impl CapturePipeline {
    fn new(channels: u16, rate: u32) -> Self {
        Self {
            resampler: Resampler::new(channels, rate),
            buffer: Vec::with_capacity(FRAME_SAMPLES),
        }
    }

    fn push(&mut self, interleaved: &[f32], out: &mut dyn FnMut(MicEvent)) {
        self.buffer.extend(self.resampler.push(interleaved));
        while self.buffer.len() >= FRAME_SAMPLES {
            let frame: Vec<i16> = self.buffer.drain(..FRAME_SAMPLES).collect();
            out(MicEvent::Frame(frame));
        }
    }
}

/// Forward frames to the caller; mark the stream dead when the receiver is
/// gone so the keep-alive thread can stop capture.
fn frame_forwarder(
    tx: mpsc::Sender<MicEvent>,
    dead: Arc<AtomicBool>,
) -> impl FnMut(MicEvent) + Send + 'static {
    move |event| {
        if tx.send(event).is_err() {
            dead.store(true, Ordering::Relaxed);
        }
    }
}

/// Surface device errors as the last event on the channel.
fn error_forwarder(
    tx: mpsc::Sender<MicEvent>,
    dead: Arc<AtomicBool>,
) -> impl FnMut(cpal::StreamError) + Send + 'static {
    move |err| {
        let _ = tx.send(MicEvent::Error(err.to_string()));
        dead.store(true, Ordering::Relaxed);
    }
}

/// Budget for the device open itself (26 号票): the device graph can
/// wedge — a default endpoint mid-switch, a resumed-from-sleep
/// Bluetooth profile, a driver holding the device — in ways no
/// downstream collaborator can observe, and the open runs inside the
/// async provider call, where an unbounded block also pins a runtime
/// worker. The engine's session-open budget catches the wedge too, but
/// this bound fails with the microphone named as the culprit.
const OPEN_BUDGET: Duration = Duration::from_secs(5);

/// Open the default input device and stream converted frames.
///
/// Returns the receiver the caller owns; dropping it stops capture. The
/// cpal stream never crosses threads — it is built and parked on one
/// dedicated capture thread (cpal's `Stream` is not `Send` on every
/// backend), with the open result relayed back through a channel. The
/// relay waits under [`OPEN_BUDGET`]; a caller that gave up leaves the
/// thread to drop whatever it managed to open and exit (no ghost
/// capture), and every verdict lands in the listening record.
pub fn open() -> Result<mpsc::Receiver<MicEvent>, String> {
    let started = Instant::now();
    let (result_tx, result_rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("spokenrectifier-mic".into())
        .spawn(move || match open_on_this_thread() {
            Ok((rx, stream, dead, summary)) => {
                if result_tx.send(Ok((rx, summary))).is_err() {
                    // The caller gave up on us (budget expiry, session
                    // cancelled mid-open): drop everything and exit —
                    // parking here would hold the device open forever.
                    return;
                }
                // Keep the stream alive until the receiver is dropped or
                // the device errors; dropping it stops capture.
                while !dead.load(Ordering::Relaxed) {
                    std::thread::park_timeout(Duration::from_millis(500));
                }
                drop(stream);
            }
            Err(e) => {
                let _ = result_tx.send(Err(e));
            }
        })
        .map_err(|e| format!("failed to start capture thread: {e}"))?;
    let outcome = match result_rx.recv_timeout(OPEN_BUDGET) {
        Ok(result) => result,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            diag::log(&format!(
                "mic open timed out after {}ms",
                OPEN_BUDGET.as_millis()
            ));
            return Err(format!(
                "opening the microphone timed out after {} ms",
                OPEN_BUDGET.as_millis()
            ));
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            return Err("capture thread died during open".to_string());
        }
    };
    let ms = started.elapsed().as_millis();
    match outcome {
        Ok((rx, summary)) => {
            diag::log(&format!("mic open ok {ms}ms {summary}"));
            Ok(rx)
        }
        Err(err) => {
            diag::log(&format!("mic open failed after {ms}ms: {err}"));
            Err(err)
        }
    }
}

/// Everything that must happen on the eventual owner thread of the stream.
fn open_on_this_thread() -> Result<
    (
        mpsc::Receiver<MicEvent>,
        cpal::Stream,
        Arc<AtomicBool>,
        String,
    ),
    String,
> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "no default input device".to_string())?;
    let name = device.name().unwrap_or_else(|_| "unknown device".into());
    let supported = device
        .default_input_config()
        .map_err(|e| format!("no usable input config: {e}"))?;
    let config: StreamConfig = supported.clone().into();
    let channels = supported.channels();
    let rate = supported.sample_rate().0;
    let summary = format!(
        "\"{name}\" {channels}ch {rate}Hz {:?}",
        supported.sample_format()
    );

    let (tx, rx) = mpsc::channel::<MicEvent>();
    let dead = Arc::new(AtomicBool::new(false));

    let stream = match supported.sample_format() {
        SampleFormat::F32 => {
            converting_stream::<f32, _>(&device, &config, channels, rate, &tx, &dead, |data| {
                data.to_vec()
            })?
        }
        SampleFormat::I16 => {
            converting_stream::<i16, _>(&device, &config, channels, rate, &tx, &dead, |data| {
                data.iter().map(|s| f32::from(*s) / 32_768.0).collect()
            })?
        }
        SampleFormat::U16 => {
            converting_stream::<u16, _>(&device, &config, channels, rate, &tx, &dead, |data| {
                data.iter()
                    .map(|s| (f32::from(*s) - 32_768.0) / 32_768.0)
                    .collect()
            })?
        }
        other => return Err(format!("unsupported input sample format: {other:?}")),
    };

    stream
        .play()
        .map_err(|e| format!("input stream failed to start: {e}"))?;
    Ok((rx, stream, dead, summary))
}

/// Build an input stream whose callback first converts each chunk to f32,
/// then feeds the shared capture pipeline. The three format arms of
/// `open_on_this_thread` differ in nothing else.
fn converting_stream<T, F>(
    device: &cpal::Device,
    config: &StreamConfig,
    channels: u16,
    rate: u32,
    tx: &mpsc::Sender<MicEvent>,
    dead: &Arc<AtomicBool>,
    convert: F,
) -> Result<cpal::Stream, String>
where
    T: cpal::SizedSample,
    F: Fn(&[T]) -> Vec<f32> + Send + 'static,
{
    let mut pipeline = CapturePipeline::new(channels, rate);
    let mut forward = frame_forwarder(tx.clone(), dead.clone());
    device
        .build_input_stream(
            config,
            move |data: &[T], _: &InputCallbackInfo| {
                let floats = convert(data);
                pipeline.push(&floats, &mut forward);
            },
            error_forwarder(tx.clone(), dead.clone()),
            None,
        )
        .map_err(|e| format!("failed to open input stream: {e}"))
}
