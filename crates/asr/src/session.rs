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
//! Tencent's URL-signed mixed frames).
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
use std::sync::atomic::{AtomicU64, Ordering};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use futures::stream::BoxStream;
use futures::{Stream, StreamExt};
use tokio::sync::mpsc as async_mpsc;

use spokenrectifier_audio::diag;
use spokenrectifier_audio::frame_rms;
use spokenrectifier_audio::{FrameEvents, MicEvent, Vad, VadConfig};
use spokenrectifier_engine::provider::asr::{AsrEvent, AsrOpenError};

use crate::gate::{PAD_MS, SendGate};
use crate::transport::{ConnectError, RealtimeChannel, RealtimeConnect};

/// Reconnect attempts after a connection is lost before giving up;
/// healthy server traffic replenishes the budget.
const MAX_RECONNECTS: u32 = 2;
/// How long to wait for trailing finals after the graceful-end message.
const FINISH_DRAIN: Duration = Duration::from_secs(2);
/// Default budget for one wire send. A half-open connection (the server
/// stopped reading, a network leg died silently) parks the transport
/// task's socket write forever; without a budget that parking spreads to
/// the whole pump — frames stop being analyzed, keepalives stop, the
/// session listens with no events and no error (26 号票's wedge). A send
/// that overruns the budget is judged a lost connection and takes the
/// reconnect path.
pub const DEFAULT_SEND_BUDGET: Duration = Duration::from_secs(10);
/// Frames between the pump's stats lines in the listening record: one
/// line per five seconds of capture.
const STATS_EVERY_FRAMES: u64 = 50;
/// Distinct numbers for the listening record, so a session's lines read
/// as one story across connect, stats, reconnects, and the end line.
static SESSION_SEQ: AtomicU64 = AtomicU64::new(0);

/// One vendor's wire dialect: what a session says when it opens, how
/// audio travels, and how server messages fold back onto the engine's
/// events. Pure payload translation — the session machinery here is
/// shared and vendor-blind. Built per session (it may carry the
/// hotword dictionary and per-session parse state).
pub trait WireProtocol: Send + 'static {
    type Message: Send;

    /// The session-opening message: whatever configures recognition for
    /// this connection (the whole initial request). `None` where the
    /// entire configuration rides the connect URL (Tencent's signed
    /// query) — there is nothing to say on the socket.
    fn opening(&self) -> Option<Self::Message>;

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
    /// Budget for one wire send; overruns are judged a lost connection
    /// (see [`DEFAULT_SEND_BUDGET`]). Injectable so tests shrink it.
    pub send_budget: Duration,
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
    // The session number and the connect verdict open the record's story;
    // the mic's own open lines (from the audio crate) sit beside them in
    // the same file, stamped by the same clock.
    let session_no = SESSION_SEQ.fetch_add(1, Ordering::Relaxed) + 1;
    let connect_started = Instant::now();
    let mut channel = match connect_once(params.connect.as_ref(), params.connect_timeout).await {
        Ok(channel) => {
            diag::log(&format!(
                "asr session #{session_no} connect ok {}ms",
                connect_started.elapsed().as_millis()
            ));
            channel
        }
        Err(err) => {
            diag::log(&format!(
                "asr session #{session_no} connect failed after {}ms: {}",
                connect_started.elapsed().as_millis(),
                err.0
            ));
            return Err(err);
        }
    };
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
            send_budget,
        } = params;
        let mut protocol = protocol;
        let mut pump = Pump::new(vad, session_no);
        let mut next_keepalive = keepalive_every
            .zip(protocol.keepalive().is_some().then_some(()))
            .map(|(every, ())| tokio::time::Instant::now() + every);

        if let Some(opening) = protocol.opening() {
            // The fresh connection already refuses (or wedges on) writes:
            // treat it as the lost connection it will prove to be.
            let failed = match send_bounded(&channel.tx, opening, send_budget).await {
                Ok(()) => false,
                Err(WireFailure::Stalled) => {
                    pump.log_fact("opening send stalled past budget; reconnecting");
                    true
                }
                Err(WireFailure::Closed) => true,
            };
            if failed {
                match try_reconnect(
                    &connect,
                    &mut protocol,
                    connect_timeout,
                    send_budget,
                    &mut frame_rx,
                    &mut pump,
                    &tx,
                )
                .await
                {
                    Some(live) => channel = live,
                    None => return, // feedback already emitted
                }
            }
        }

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
                            if on_wire {
                                // Audio on the wire under the send budget:
                                // the server's idle clock starts over, and
                                // so does ours. A send that fails outright
                                // or parks past the budget is a lost
                                // connection — reconnect.
                                let sent = match send_bounded(
                                    &channel.tx, protocol.audio(&frame), send_budget,
                                )
                                .await
                                {
                                    Ok(()) => true,
                                    Err(WireFailure::Stalled) => {
                                        pump.log_fact(
                                            "audio send stalled past budget; reconnecting",
                                        );
                                        false
                                    }
                                    Err(WireFailure::Closed) => false,
                                };
                                if sent {
                                    pump.wire += 1;
                                    if let Some(every) = keepalive_every {
                                        next_keepalive =
                                            Some(tokio::time::Instant::now() + every);
                                    }
                                } else {
                                    match try_reconnect(
                                        &connect, &mut protocol, connect_timeout,
                                        send_budget, &mut frame_rx, &mut pump, &tx,
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
                            pump.server_msgs += 1;
                            if !emit(&tx, events).await || failed {
                                break 'session;
                            }
                        }
                        Some(Err(_)) | None => {
                            match try_reconnect(
                                &connect, &mut protocol, connect_timeout,
                                send_budget, &mut frame_rx, &mut pump, &tx,
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
                        let sent = match send_bounded(
                            &channel.tx, message, send_budget,
                        )
                        .await
                        {
                            Ok(()) => true,
                            Err(WireFailure::Stalled) => {
                                pump.log_fact(
                                    "keepalive send stalled past budget; reconnecting",
                                );
                                false
                            }
                            Err(WireFailure::Closed) => false,
                        };
                        if !sent {
                            match try_reconnect(
                                &connect, &mut protocol, connect_timeout,
                                send_budget, &mut frame_rx, &mut pump, &tx,
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
        // mic died mid-session). Best-effort under the same send budget.
        let _ = send_bounded(&channel.tx, protocol.finish(), send_budget).await;
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
        pump.log_end();
    });

    Ok(RecvAsrStream { rx }.boxed())
}

/// The per-session analysis state shared by the live loop and reconnects:
/// one place for the VAD, the frame-to-event mapping, the send gate, the
/// offline audio buffer, and the listening record's counters (26 号票).
struct Pump {
    vad: Vad,
    frame_events: FrameEvents,
    gate: SendGate,
    offline_buffer: VecDeque<Vec<i16>>,
    reconnects_left: u32,
    /// The session's number in the listening record.
    session_no: u64,
    /// Frames analyzed since the session opened.
    frames: u64,
    /// Frames the VAD judged voiced.
    voiced: u64,
    /// Audio frames that reached the wire (opening/keepalive/finish
    /// messages do not count).
    wire: u64,
    /// Server messages folded since the session opened.
    server_msgs: u64,
    /// The stats window's RMS bounds, reset by each stats line.
    win_rms_min: f32,
    win_rms_max: f32,
}

impl Pump {
    fn new(vad_config: VadConfig, session_no: u64) -> Self {
        Self {
            vad: Vad::new(vad_config),
            frame_events: FrameEvents::new(),
            gate: SendGate::new(PAD_MS),
            offline_buffer: VecDeque::new(),
            reconnects_left: MAX_RECONNECTS,
            session_no,
            frames: 0,
            voiced: 0,
            wire: 0,
            server_msgs: 0,
            win_rms_min: f32::MAX,
            win_rms_max: 0.0,
        }
    }

    /// Analyze one frame: the engine events it produces, and whether it
    /// belongs on the wire.
    fn analyze(&mut self, frame: &[i16]) -> (Vec<AsrEvent>, bool) {
        let decision = self.vad.push(frame);
        // The listening record's counters ride the analysis pass; the
        // line answers, per hypothesis of the no-text wedge: voiced=0
        // against a healthy win_rms is a VAD that never opened, a flat
        // near-zero win_rms is a device capturing silence, wire>0 with
        // svr=0 is a dead server session.
        let rms = frame_rms(frame);
        self.frames += 1;
        if decision.voiced {
            self.voiced += 1;
        }
        if rms < self.win_rms_min {
            self.win_rms_min = rms;
        }
        if rms > self.win_rms_max {
            self.win_rms_max = rms;
        }
        if self.frames.is_multiple_of(STATS_EVERY_FRAMES) {
            self.log_stats();
        }
        (self.frame_events.push(&decision), self.gate.push(&decision))
    }

    /// One stats line in the listening record, then a fresh RMS window.
    fn log_stats(&mut self) {
        diag::log(&format!(
            "asr session #{} frames={} voiced={} wire={} svr={} win_rms={:.2e}..{:.2e} floor={:.2e}",
            self.session_no,
            self.frames,
            self.voiced,
            self.wire,
            self.server_msgs,
            self.win_rms_min,
            self.win_rms_max,
            self.vad.floor(),
        ));
        self.win_rms_min = f32::MAX;
        self.win_rms_max = 0.0;
    }

    /// The session's totals as its last line in the listening record.
    fn log_end(&self) {
        diag::log(&format!(
            "asr session #{} end: frames={} voiced={} wire={} svr={}",
            self.session_no, self.frames, self.voiced, self.wire, self.server_msgs,
        ));
    }

    /// One session-scoped fact line in the listening record.
    fn log_fact(&self, facts: &str) {
        diag::log(&format!("asr session #{} {}", self.session_no, facts));
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
    send_budget: Duration,
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
                if let Some(opening) = protocol.opening()
                    && send_bounded(&channel.tx, opening, send_budget)
                        .await
                        .is_err()
                {
                    pump.log_fact("reconnected, but the opening send refused; retrying");
                    continue; // died (or wedged) instantly; try again
                }
                let mut flushed = true;
                while let Some(frame) = pump.offline_buffer.pop_front() {
                    if send_bounded(&channel.tx, protocol.audio(&frame), send_budget)
                        .await
                        .is_err()
                    {
                        flushed = false;
                        break;
                    }
                }
                if flushed {
                    pump.log_fact("reconnected");
                    return Some(channel);
                }
            }
            Err(ConnectError::Auth(message)) => {
                pump.log_fact(&format!("reconnect refused (auth): {message}"));
                let _ = engine_tx.send(AsrEvent::Failed { message }).await;
                return None; // credentials will not heal by retrying
            }
            Err(ConnectError::Other(err)) => {
                pump.log_fact(&format!("reconnect attempt failed: {err}"));
            }
        }
    }
    pump.log_fact("reconnects exhausted; failing the session");
    let _ = engine_tx
        .send(AsrEvent::Failed {
            message: "connection lost; reconnecting failed".into(),
        })
        .await;
    None
}

/// Why a budgeted wire send did not land.
enum WireFailure {
    /// The send failed outright — the connection task is gone.
    Closed,
    /// The send parked past the budget — the far end stopped reading
    /// (the half-open wedge of 26 号票).
    Stalled,
}

/// One wire send under the session's send budget. Either way the caller
/// treats the connection as lost and the failed or stalled message is
/// dropped with it; the distinction rides along for the listening
/// record, where a stall is the half-open fingerprint.
async fn send_bounded<M>(
    tx: &async_mpsc::Sender<M>,
    message: M,
    budget: Duration,
) -> Result<(), WireFailure> {
    match tokio::time::timeout(budget, tx.send(message)).await {
        Ok(result) => result.map_err(|_| WireFailure::Closed),
        Err(_) => Err(WireFailure::Stalled),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use spokenrectifier_engine::provider::asr::AsrEvent;

    use super::{DEFAULT_SEND_BUDGET, SessionParams, WireProtocol, open_session};
    use crate::test_support::{tone_frames as tone, zero_frames as zeros};
    use crate::testing::{PlanEntry, ScriptedConnect, collect, live_conn, scripted_source};
    use crate::transport::ConnectError;
    use spokenrectifier_audio::MicEvent;

    /// The dialect these tests speak: plain strings, no semantics.
    #[derive(Debug, Clone)]
    struct StringProtocol;

    impl WireProtocol for StringProtocol {
        type Message = String;

        fn opening(&self) -> Option<String> {
            Some("open".into())
        }

        fn audio(&self, frame: &[i16]) -> String {
            format!("audio {} samples", frame.len())
        }

        fn finish(&self) -> String {
            "finish".into()
        }

        fn parse(&mut self, _message: &String) -> Vec<AsrEvent> {
            Vec::new()
        }
    }

    #[tokio::test]
    async fn a_stalled_wire_send_is_judged_a_lost_connection() {
        // The live connection's far end never drains its client channel
        // (a server that stopped reading): the 64-slot buffer fills and
        // the next send parks. The send budget must turn that parking
        // into a lost-connection verdict — and with no healthy reconnect
        // left, the session fails visibly instead of the whole pump
        // wedging with no events and no error.
        let (stuck, _never_drained) = live_conn::<String>(None);
        let connect: Arc<ScriptedConnect<String>> = Arc::new(ScriptedConnect::new(vec![
            stuck,
            PlanEntry::Fail(ConnectError::Other("unreachable".into())),
            PlanEntry::Fail(ConnectError::Other("unreachable".into())),
        ]));
        // Speech from the fifth frame on — the opening message plus
        // voiced frames overflow the client channel's capacity.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 80).into_iter().map(MicEvent::Frame));

        let source = scripted_source(sends, true);
        let stream = open_session(
            source().expect("the scripted source opens"),
            StringProtocol,
            Default::default(),
            SessionParams {
                connect: connect.clone(),
                connect_timeout: Duration::from_millis(500),
                keepalive_every: None,
                send_budget: Duration::from_millis(100),
            },
        )
        .await
        .expect("open");

        let events = collect(stream).await;
        assert!(
            events.iter().any(|event| matches!(
                event,
                AsrEvent::Failed { message } if message.contains("connection lost")
            )),
            "the stalled send must fail the session, got {events:?}"
        );
        assert_eq!(connect.connect_count(), 3, "both reconnects spent");
        // The production budget stays generous: a healthy send is bounded
        // at ten seconds, not this test's shrunk value.
        assert_eq!(DEFAULT_SEND_BUDGET, Duration::from_secs(10));
    }
}
