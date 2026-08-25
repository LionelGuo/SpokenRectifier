//! [`MicVadAsr`]: the microphone+VAD ASR provider.
//!
//! Pumps 100 ms frames through [`Vad`] and surfaces the engine's session
//! semantics as [`AsrEvent`]s: speech-activity transitions, cumulative
//! silence, and device failure. No text is recognized — that arrives with
//! the cloud adapter, which will reuse the same [`Vad`] gate to decide
//! which frames it may ever send.
//!
//! The frame source is injectable: production opens the real default
//! microphone ([`mic::open`]); tests feed scripted frames through a
//! channel, keeping the whole pipeline deterministic.

use std::sync::{Arc, mpsc};

use async_trait::async_trait;
use futures::stream::BoxStream;
use futures::{Stream, StreamExt};
use std::pin::Pin;
use std::task::{Context, Poll};

use spokenrectifier_engine::provider::asr::{AsrEvent, AsrOpenError, AsrProvider};

use crate::mic::{self, MicEvent};
use crate::vad::{Vad, VadConfig, VadDecision};

/// A fresh capture to pump: the receiver of [`MicEvent`]s.
pub type FrameStream = mpsc::Receiver<MicEvent>;
/// Factory for frame streams; injectable so tests script the microphone.
pub type FrameSource = Arc<dyn Fn() -> Result<FrameStream, String> + Send + Sync>;

/// Maps VAD decisions onto the engine's per-frame ASR events: speech
/// transitions plus the silence clock. Shared by every provider that
/// drives the engine from local VAD — mic-only and cloud alike, so their
/// session semantics stay identical.
pub struct FrameEvents {
    speaking: bool,
}

impl Default for FrameEvents {
    fn default() -> Self {
        Self::new()
    }
}

impl FrameEvents {
    pub fn new() -> Self {
        Self { speaking: false }
    }

    /// The events one analyzed frame produces (in emission order).
    pub fn push(&mut self, decision: &VadDecision) -> Vec<AsrEvent> {
        let mut events = Vec::with_capacity(2);
        if decision.speaking != self.speaking {
            self.speaking = decision.speaking;
            events.push(AsrEvent::SpeechActivity {
                speaking: self.speaking,
            });
        }
        if !self.speaking {
            // The silence clock the engine's paragraph / auto-end
            // thresholds compare against.
            events.push(AsrEvent::Silence {
                elapsed_ms: decision.silence_ms,
            });
        }
        events
    }
}

/// The mic+VAD ASR provider.
pub struct MicVadAsr {
    vad: VadConfig,
    source: FrameSource,
}

impl MicVadAsr {
    /// Capture from the real default microphone.
    pub fn new(vad: VadConfig) -> Self {
        Self::with_source(vad, Arc::new(mic::open))
    }

    /// Capture from an injected frame source (tests).
    pub fn with_source(vad: VadConfig, source: FrameSource) -> Self {
        Self { vad, source }
    }
}

#[async_trait]
impl AsrProvider for MicVadAsr {
    async fn open_stream(&self) -> Result<BoxStream<'static, AsrEvent>, AsrOpenError> {
        let frames = (self.source)().map_err(AsrOpenError)?;
        let config = self.vad;
        let (tx, rx) = tokio::sync::mpsc::channel::<AsrEvent>(64);

        // A dedicated thread: the capture receiver blocks, and the VAD work
        // is tiny but must not stall the async runtime.
        std::thread::spawn(move || {
            let mut vad = Vad::new(config);
            let mut frame_events = FrameEvents::new();
            for event in frames {
                let out = match event {
                    MicEvent::Frame(frame) => frame_events.push(&vad.push(&frame)),
                    MicEvent::Error(message) => vec![AsrEvent::Failed { message }],
                };
                for event in out {
                    if tx.blocking_send(event).is_err() {
                        return; // engine side gone (session ended)
                    }
                }
            }
            // Source ended without an error report (device driver gone
            // quiet): end the stream; the engine keeps its state machine.
        });

        Ok(RecvAsrStream { rx }.boxed())
    }
}

struct RecvAsrStream {
    rx: tokio::sync::mpsc::Receiver<AsrEvent>,
}

impl Stream for RecvAsrStream {
    type Item = AsrEvent;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<AsrEvent>> {
        self.rx.poll_recv(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::StreamExt;
    use std::time::Duration;

    use crate::test_support::{tone_frame, zero_frame};

    /// Wire a scripted source into the provider and collect its events
    /// until the stream ends or the deadline passes.
    async fn run_provider(sends: Vec<MicEvent>) -> Vec<AsrEvent> {
        let source: FrameSource = Arc::new(move || {
            let (tx, rx) = mpsc::channel();
            let script = sends.clone();
            std::thread::spawn(move || {
                for event in script {
                    if tx.send(event).is_err() {
                        break;
                    }
                }
            });
            Ok(rx)
        });
        let provider = MicVadAsr::with_source(VadConfig::default(), source);
        let mut stream = provider.open_stream().await.expect("open");
        let mut events = Vec::new();
        while let Ok(Some(event)) =
            tokio::time::timeout(Duration::from_millis(300), stream.next()).await
        {
            events.push(event);
            if matches!(events.last(), Some(AsrEvent::Failed { .. })) {
                // Drain anything the pump still had, then stop.
                while let Ok(Some(extra)) =
                    tokio::time::timeout(Duration::from_millis(50), stream.next()).await
                {
                    events.push(extra);
                }
                break;
            }
        }
        events
    }

    #[tokio::test]
    async fn silence_frames_emit_growing_silence_events() {
        let events = run_provider(vec![MicEvent::Frame(zero_frame()); 6]).await;
        assert_eq!(
            events,
            (1..=6)
                .map(|i| AsrEvent::Silence {
                    elapsed_ms: i * 100
                })
                .collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn speech_then_quiet_transitions_and_accumulates() {
        // 4 calibration zeros, speech, then quiet: speaking opens, closes
        // after hangover, silence accumulates.
        let mut sends: Vec<MicEvent> = (0..4).map(|_| MicEvent::Frame(zero_frame())).collect();
        sends.extend((4..7).map(|i| MicEvent::Frame(tone_frame(0.6, i))));
        sends.extend((7..13).map(|_| MicEvent::Frame(zero_frame())));
        let events = run_provider(sends).await;

        let speaking_on = events
            .iter()
            .position(|e| *e == AsrEvent::SpeechActivity { speaking: true })
            .expect("speech opens");
        // Silence from calibration precedes it.
        assert!(matches!(events[speaking_on - 1], AsrEvent::Silence { .. }));
        let speaking_off = events
            .iter()
            .position(|e| *e == AsrEvent::SpeechActivity { speaking: false })
            .expect("speech closes");
        // The close lands with the silence event that same frame.
        assert_eq!(
            events[speaking_off + 1],
            AsrEvent::Silence { elapsed_ms: 300 }
        );
        assert_eq!(events.last(), Some(&AsrEvent::Silence { elapsed_ms: 600 }));
    }

    #[tokio::test]
    async fn device_error_surfaces_as_failed_and_ends_the_stream() {
        let mut sends: Vec<MicEvent> = (0..2).map(|_| MicEvent::Frame(zero_frame())).collect();
        sends.push(MicEvent::Error("device invalidated".into()));
        let events = run_provider(sends).await;
        assert_eq!(
            events.last(),
            Some(&AsrEvent::Failed {
                message: "device invalidated".to_string()
            })
        );
    }

    #[tokio::test]
    async fn open_failure_maps_to_asr_open_error() {
        let source: FrameSource = Arc::new(|| Err("no default input device".into()));
        let provider = MicVadAsr::with_source(VadConfig::default(), source);
        let Err(err) = provider.open_stream().await else {
            panic!("expected the open to fail");
        };
        assert!(err.0.contains("no default input device"));
    }
}
