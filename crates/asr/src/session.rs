//! The streaming session every cloud ASR adapter runs on: mic frames
//! through the local VAD (speech activity and the silence clock drive
//! the engine exactly like the mic-only provider), the [`SendGate`]
//! deciding which frames also travel to the server, bounded reconnects
//! with an offline audio buffer, and a graceful drain on session end.
//!
//! What this module does NOT know is the vendor's dialect — that is a
//! [`WireProtocol`]: the session-opening message, how one audio frame
//! rides the wire, the graceful-end message, an optional liveness
//! message for streams the server times out when nothing arrives, and
//! how server messages fold back onto the engine's [`AsrEvent`]s. One
//! pump, every dialect (DashScope JSON, Volcengine's gzip'd frames,
//! Tencent's text frames in ticket 25).
//!
//! A lost connection is retried a bounded number of times; frames that
//! pass the gate while offline are buffered briefly and flushed after
//! the reconnect. Auth-looking failures are not retried. When retries
//! run out — or the server reports an error — the session ends with
//! [`AsrEvent::Failed`] feedback. On any session end the adapter sends
//! its graceful-end message and drains trailing finals for a moment
//! before closing.

use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use futures::stream::BoxStream;
use futures::{Stream, StreamExt};
use tokio::sync::mpsc as async_mpsc;

use spokenrectifier_audio::{FrameEvents, MicEvent, Vad, VadConfig};
use spokenrectifier_engine::provider::asr::{AsrEvent, AsrOpenError};

use crate::gate::{PAD_MS, SendGate};
use crate::transport::{ConnectError, RealtimeChannel, RealtimeConnect};

/// Reconnect attempts after a connection is lost before giving up;
/// healthy server traffic replenishes the budget.
const MAX_RECONNECTS: u32 = 2;
/// How long to wait for trailing finals after the graceful-end message.
const FINISH_DRAIN: Duration = Duration::from_secs(2);

/// One vendor's wire dialect: what a session says when it opens, how
/// audio travels, and how server messages fold back onto the engine's
/// events. Pure payload translation — the session machinery here is
/// shared and vendor-blind. Built per session (it may carry the
/// hotword dictionary and per-session parse state).
pub trait WireProtocol: Send + 'static {
    type Message: Send;

    /// The session-opening message: whatever configures recognition for
    /// this connection (the whole initial request).
    fn opening(&self) -> Self::Message;

    /// One gate-approved audio frame, ready for the wire.
    fn audio(&self, frame: &[i16]) -> Self::Message;

    /// The graceful-end message sent when the local side ends the
    /// session (the source died, or the engine side went away).
    fn finish(&self) -> Self::Message;

    /// A liveness message for streams the server times out when nothing
    /// arrives; `None` where the protocol tolerates idle silence. Sent
    /// no more often than the session's keepalive interval.
    fn keepalive(&self) -> Option<Self::Message> {
        None
    }

    /// Fold one server message into engine events — several, one, or
    /// none. A `Failed` event ends the session.
    fn parse(&mut self, message: &Self::Message) -> Vec<AsrEvent>;

    /// Whether one server message means "the session is over, stop
    /// draining" (DashScope's `session.finished`); protocols without
    /// such a marker drain until the deadline.
    fn session_over(&self, _message: &Self::Message) -> bool {
        false
    }
}

/// Everything one cloud session needs besides its dialect.
pub struct SessionParams<M> {
    pub connect: Arc<dyn RealtimeConnect<M>>,
    /// Handshake budget per (re)connect attempt.
    pub connect_timeout: Duration,
    /// How often to send the protocol's keepalive (when it has one)
    /// while no audio flows.
    pub keepalive_every: Option<Duration>,
}

/// Open one streaming session: connect, then pump until the source
/// ends, the engine side goes away, or the protocol fails. Returns the
/// engine-facing event stream; the session runs on its own task.
pub async fn open_session<P>(
    frames: std::sync::mpsc::Receiver<MicEvent>,
    protocol: P,
    vad: VadConfig,
    params: SessionParams<P::Message>,
) -> Result<BoxStream<'static, AsrEvent>, AsrOpenError>
where
    P: WireProtocol,
{
    let mut channel = connect_once(params.connect.as_ref(), params.connect_timeout).await?;
    let (tx, rx) = async_mpsc::channel::<AsrEvent>(64);

    // Bridge the blocking mic receiver into async land; when the pump
    // ends, the bridge ends, which drops the receiver and stops capture.
    let (frame_tx, mut frame_rx) = async_mpsc::channel::<MicEvent>(64);
    std::thread::spawn(move || {
        for event in frames {
            if frame_tx.blocking_send(event).is_err() {
                break;
            }
        }
    });

    tokio::spawn(async move {
        let SessionParams {
            connect,
            connect_timeout,
            keepalive_every,
        } = params;
        let mut protocol = protocol;
        let mut pump = Pump::new(vad);
        let mut next_keepalive = keepalive_every
            .zip(protocol.keepalive().is_some().then_some(()))
            .map(|(every, ())| tokio::time::Instant::now() + every);

        let _ = channel.tx.send(protocol.opening()).await;

        'session: loop {
            tokio::select! {
                biased;
                maybe = frame_rx.recv() => {
                    match maybe {
                        None => break 'session, // source gone quiet, no error report
                        Some(MicEvent::Error(message)) => {
                            let _ = tx.send(AsrEvent::Failed { message }).await;
                            break 'session;
                        }
                        Some(MicEvent::Frame(frame)) => {
                            let (events, on_wire) = pump.analyze(&frame);
                            if !emit(&tx, events).await {
                                break 'session; // engine side gone
                            }
                            if on_wire && channel.tx.send(protocol.audio(&frame)).await.is_ok() {
                                // Audio just flowed: the server's idle
                                // clock starts over, and so does ours.
                                if let Some(every) = keepalive_every {
                                    next_keepalive =
                                        Some(tokio::time::Instant::now() + every);
                                }
                            } else if on_wire {
                                // Writer gone: same story as a lost
                                // connection — reconnect.
                                match try_reconnect(
                                    &connect, &mut protocol, connect_timeout,
                                    &mut frame_rx, &mut pump, &tx,
                                )
                                .await
                                {
                                    Some(live) => channel = live,
                                    None => break 'session, // feedback already emitted
                                }
                            }
                        }
                    }
                }
                maybe = channel.rx.recv() => {
                    match maybe {
                        Some(Ok(message)) => {
                            if protocol.session_over(&message) {
                                // The server confirmed the end; nothing
                                // more to drain.
                                break 'session;
                            }
                            let events = protocol.parse(&message);
                            let failed = events
                                .iter()
                                .any(|event| matches!(event, AsrEvent::Failed { .. }));
                            // Healthy traffic replenishes the budget.
                            pump.reconnects_left = MAX_RECONNECTS;
                            if !emit(&tx, events).await || failed {
                                break 'session;
                            }
                        }
                        Some(Err(_)) | None => {
                            match try_reconnect(
                                &connect, &mut protocol, connect_timeout,
                                &mut frame_rx, &mut pump, &tx,
                            )
                            .await
                            {
                                Some(live) => channel = live,
                                None => break 'session, // feedback already emitted
                            }
                        }
                    }
                }
                _ = async {
                    match next_keepalive {
                        Some(deadline) => tokio::time::sleep_until(deadline).await,
                        None => std::future::pending().await,
                    }
                }, if next_keepalive.is_some() => {
                    if let Some(every) = keepalive_every
                        && let Some(message) = protocol.keepalive()
                    {
                        next_keepalive = Some(tokio::time::Instant::now() + every);
                        if channel.tx.send(message).await.is_err() {
                            match try_reconnect(
                                &connect, &mut protocol, connect_timeout,
                                &mut frame_rx, &mut pump, &tx,
                            )
                            .await
                            {
                                Some(live) => channel = live,
                                None => break 'session,
                            }
                        }
                    }
                }
            }
        }

        // Graceful end: tell the server, then forward trailing finals
        // for a moment — the engine may still be listening (e.g. the
        // mic died mid-session).
        let _ = channel.tx.send(protocol.finish()).await;
        let deadline = tokio::time::Instant::now() + FINISH_DRAIN;
        while let Ok(Some(Ok(message))) = tokio::time::timeout_at(deadline, channel.rx.recv()).await
        {
            if protocol.session_over(&message) {
                break;
            }
            let events = protocol.parse(&message);
            let failed = events
                .iter()
                .any(|event| matches!(event, AsrEvent::Failed { .. }));
            if !emit(&tx, events).await || failed {
                break;
            }
        }
    });

    Ok(RecvAsrStream { rx }.boxed())
}

/// The per-session analysis state shared by the live loop and reconnects:
/// one place for the VAD, the frame-to-event mapping, the send gate, and
/// the offline audio buffer.
struct Pump {
    vad: Vad,
    frame_events: FrameEvents,
    gate: SendGate,
    offline_buffer: VecDeque<Vec<i16>>,
    reconnects_left: u32,
}

impl Pump {
    fn new(vad_config: VadConfig) -> Self {
        Self {
            vad: Vad::new(vad_config),
            frame_events: FrameEvents::new(),
            gate: SendGate::new(PAD_MS),
            offline_buffer: VecDeque::new(),
            reconnects_left: MAX_RECONNECTS,
        }
    }

    /// Analyze one frame: the engine events it produces, and whether it
    /// belongs on the wire.
    fn analyze(&mut self, frame: &[i16]) -> (Vec<AsrEvent>, bool) {
        let decision = self.vad.push(frame);
        (self.frame_events.push(&decision), self.gate.push(&decision))
    }

    /// Stash a wire frame while offline; overflow drops the oldest.
    fn buffer_offline(&mut self, frame: Vec<i16>) {
        const RECONNECT_BUFFER_FRAMES: usize = 30;
        if self.offline_buffer.len() == RECONNECT_BUFFER_FRAMES {
            self.offline_buffer.pop_front();
        }
        self.offline_buffer.push_back(frame);
    }
}

struct RecvAsrStream {
    rx: async_mpsc::Receiver<AsrEvent>,
}

impl Stream for RecvAsrStream {
    type Item = AsrEvent;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<AsrEvent>> {
        self.rx.poll_recv(cx)
    }
}

/// Forward events to the engine; `false` when the engine side is gone.
async fn emit(tx: &async_mpsc::Sender<AsrEvent>, events: Vec<AsrEvent>) -> bool {
    for event in events {
        if tx.send(event).await.is_err() {
            return false;
        }
    }
    true
}

async fn connect_once<M>(
    connect: &dyn RealtimeConnect<M>,
    timeout: Duration,
) -> Result<RealtimeChannel<M>, AsrOpenError> {
    tokio::time::timeout(timeout, connect.connect())
        .await
        .map_err(|_| AsrOpenError("connecting to the ASR endpoint timed out".into()))?
        .map_err(|err| AsrOpenError(err.to_string()))
}

/// Replace a lost connection. While a reconnect is pending the mic keeps
/// being analyzed (the orb stays live) and gate-approved frames are
/// buffered; on success the session is reconfigured and the buffer
/// flushed. Each attempt gets the handshake budget — a hanging reconnect
/// fails over instead of wedging the session offline. Returns `None` when
/// the session must end — the `Failed` feedback (or a dead engine/source)
/// has already been emitted or makes further work moot.
async fn try_reconnect<M, P>(
    connect: &Arc<dyn RealtimeConnect<M>>,
    protocol: &mut P,
    connect_timeout: Duration,
    frame_rx: &mut async_mpsc::Receiver<MicEvent>,
    pump: &mut Pump,
    engine_tx: &async_mpsc::Sender<AsrEvent>,
) -> Option<RealtimeChannel<M>>
where
    P: WireProtocol<Message = M>,
    M: Send,
{
    while pump.reconnects_left > 0 {
        pump.reconnects_left -= 1;
        let deadline = tokio::time::Instant::now() + connect_timeout;
        let attempt = {
            let fut = connect.connect();
            tokio::pin!(fut);
            loop {
                tokio::select! {
                    result = &mut fut => break result,
                    _ = tokio::time::sleep_until(deadline) => {
                        break Err(ConnectError::Other("reconnecting timed out".into()));
                    }
                    maybe = frame_rx.recv() => match maybe {
                        Some(MicEvent::Frame(frame)) => {
                            let (events, on_wire) = pump.analyze(&frame);
                            if !emit(engine_tx, events).await {
                                return None; // engine side gone
                            }
                            if on_wire {
                                pump.buffer_offline(frame);
                            }
                        }
                        Some(MicEvent::Error(message)) => {
                            let _ = engine_tx.send(AsrEvent::Failed { message }).await;
                            return None;
                        }
                        None => return None, // source gone
                    },
                }
            }
        };
        match attempt {
            Ok(channel) => {
                if channel.tx.send(protocol.opening()).await.is_err() {
                    continue; // died instantly; try again
                }
                let mut flushed = true;
                while let Some(frame) = pump.offline_buffer.pop_front() {
                    if channel.tx.send(protocol.audio(&frame)).await.is_err() {
                        flushed = false;
                        break;
                    }
                }
                if flushed {
                    return Some(channel);
                }
            }
            Err(ConnectError::Auth(message)) => {
                let _ = engine_tx.send(AsrEvent::Failed { message }).await;
                return None; // credentials will not heal by retrying
            }
            Err(ConnectError::Other(_)) => {} // transient; bounded retry
        }
    }
    let _ = engine_tx
        .send(AsrEvent::Failed {
            message: "connection lost; reconnecting failed".into(),
        })
        .await;
    None
}
