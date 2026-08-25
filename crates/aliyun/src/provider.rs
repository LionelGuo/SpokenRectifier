//! [`AliyunAsr`]: the [`AsrProvider`] adapter over the DashScope realtime
//! WebSocket protocol.
//!
//! One recording session is one WebSocket: mic frames flow through the
//! local VAD (speech activity and the silence clock drive the engine
//! exactly like the mic-only provider), and the [`SendGate`] decides
//! which frames also travel to the server as `input_audio_buffer.append`
//! events. Server transcripts fold back as partials (`text`+`stash`) and
//! finals (`transcript`).
//!
//! A lost connection is retried a bounded number of times; frames that
//! pass the gate while offline are buffered briefly and flushed after the
//! reconnect. Auth-looking failures are not retried. When retries run out
//! — or the server reports an error — the session ends with
//! [`AsrEvent::Failed`] feedback. On any session end the adapter sends
//! `session.finish` and drains trailing finals for a moment before
//! closing.
//!
//! [`AsrProvider`]: spokenrectifier_engine::AsrProvider
//! [`AsrEvent::Failed`]: spokenrectifier_engine::provider::asr::AsrEvent::Failed

use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine as _;
use futures::stream::BoxStream;
use futures::{Stream, StreamExt};
use tokio::sync::mpsc as async_mpsc;

use spokenrectifier_audio::{FrameEvents, FrameSource, MicEvent, Vad, VadConfig};
use spokenrectifier_engine::provider::asr::{AsrEvent, AsrOpenError, AsrProvider};

use crate::config::{AsrConfig, AsrConfigError};
use crate::gate::{PAD_MS, SendGate};
use crate::transport::{ConnectError, RealtimeChannel, RealtimeConnect, TungsteniteConnect};

/// Reconnect attempts after a connection is lost before giving up; healthy
/// server traffic replenishes the budget.
const MAX_RECONNECTS: u32 = 2;
/// Handshake budget per (re)connect attempt.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Gate-approved frames buffered while a reconnect is pending; overflow
/// drops the oldest.
const RECONNECT_BUFFER_FRAMES: usize = 30;
/// How long to wait for trailing finals after `session.finish`.
const FINISH_DRAIN: Duration = Duration::from_secs(2);
/// The server-side VAD pause we configure — must sit comfortably inside
/// the gate's [`PAD_MS`].
const SERVER_SILENCE_MS: u64 = 400;

/// The cloud ASR adapter.
pub struct AliyunAsr {
    config: AsrConfig,
    vad: VadConfig,
    source: FrameSource,
    connect: Arc<dyn RealtimeConnect>,
    /// Handshake budget per (re)connect attempt; injectable for tests.
    connect_timeout: Duration,
}

impl AliyunAsr {
    /// Capture from the real default microphone and connect to the
    /// configured endpoint. Fails when the config is incomplete (no key,
    /// no resolvable endpoint).
    pub fn new(config: AsrConfig, vad: VadConfig) -> Result<Self, AsrConfigError> {
        let endpoint = config.endpoint()?;
        let api_key = config.resolve_key().ok_or_else(|| {
            AsrConfigError("no api key: set [asr] api_key in the local config".into())
        })?;
        Ok(Self::with_parts(
            config,
            vad,
            Arc::new(spokenrectifier_audio::open_mic),
            Arc::new(TungsteniteConnect::new(endpoint, api_key)),
            CONNECT_TIMEOUT,
        ))
    }

    /// Fully injected assembly (tests).
    pub fn with_parts(
        config: AsrConfig,
        vad: VadConfig,
        source: FrameSource,
        connect: Arc<dyn RealtimeConnect>,
        connect_timeout: Duration,
    ) -> Self {
        Self {
            config,
            vad,
            source,
            connect,
            connect_timeout,
        }
    }
}

#[async_trait]
impl AsrProvider for AliyunAsr {
    async fn open_stream(&self) -> Result<BoxStream<'static, AsrEvent>, AsrOpenError> {
        let frames = (self.source)().map_err(AsrOpenError)?;
        let mut channel = connect_once(self.connect.as_ref(), self.connect_timeout).await?;
        let (tx, rx) = async_mpsc::channel::<AsrEvent>(64);

        // Bridge the blocking mic receiver into async land; when the pump
        // ends, the bridge ends, which drops the receiver and stops
        // capture.
        let (frame_tx, mut frame_rx) = async_mpsc::channel::<MicEvent>(64);
        std::thread::spawn(move || {
            for event in frames {
                if frame_tx.blocking_send(event).is_err() {
                    break;
                }
            }
        });

        let connect = self.connect.clone();
        let language = self.config.language.clone();
        let connect_timeout = self.connect_timeout;
        let vad_config = self.vad;

        tokio::spawn(async move {
            let mut pump = Pump::new(vad_config);

            let _ = channel.tx.send(session_update_payload(&language)).await;

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
                                if on_wire
                                    && channel.tx.send(append_payload(&frame)).await.is_err()
                                {
                                    // Writer gone: same story as a lost
                                    // connection — reconnect.
                                    match try_reconnect(
                                        &connect, &language, connect_timeout,
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
                            Some(Ok(text)) => {
                                if let Some(event) = server_event(&text) {
                                    let failed = matches!(event, AsrEvent::Failed { .. });
                                    // Healthy traffic replenishes the budget.
                                    pump.reconnects_left = MAX_RECONNECTS;
                                    if !emit(&tx, vec![event]).await || failed {
                                        break 'session;
                                    }
                                } else {
                                    pump.reconnects_left = MAX_RECONNECTS;
                                }
                            }
                            Some(Err(_)) | None => {
                                match try_reconnect(
                                    &connect, &language, connect_timeout,
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
            }

            // Graceful end: tell the server, then forward trailing finals
            // for a moment — the engine may still be listening (e.g. the
            // mic died mid-session).
            let _ = channel.tx.send(finish_payload()).await;
            let deadline = tokio::time::Instant::now() + FINISH_DRAIN;
            while let Ok(Some(Ok(text))) =
                tokio::time::timeout_at(deadline, channel.rx.recv()).await
            {
                let event_type = serde_json::from_str::<serde_json::Value>(&text)
                    .ok()
                    .and_then(|value| value["type"].as_str().map(str::to_string));
                if event_type.as_deref() == Some("session.finished") {
                    break;
                }
                let Some(event) = server_event(&text) else {
                    continue;
                };
                if matches!(event, AsrEvent::Failed { .. }) {
                    let _ = tx.send(event).await;
                    break;
                }
                if tx.send(event).await.is_err() {
                    break; // engine side gone
                }
            }
        });

        Ok(RecvAsrStream { rx }.boxed())
    }
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

async fn connect_once(
    connect: &dyn RealtimeConnect,
    timeout: Duration,
) -> Result<RealtimeChannel, AsrOpenError> {
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
async fn try_reconnect(
    connect: &Arc<dyn RealtimeConnect>,
    language: &str,
    connect_timeout: Duration,
    frame_rx: &mut async_mpsc::Receiver<MicEvent>,
    pump: &mut Pump,
    engine_tx: &async_mpsc::Sender<AsrEvent>,
) -> Option<RealtimeChannel> {
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
                if channel
                    .tx
                    .send(session_update_payload(language))
                    .await
                    .is_err()
                {
                    continue; // died instantly; try again
                }
                let mut flushed = true;
                while let Some(frame) = pump.offline_buffer.pop_front() {
                    if channel.tx.send(append_payload(&frame)).await.is_err() {
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

fn session_update_payload(language: &str) -> String {
    serde_json::json!({
        "type": "session.update",
        "session": {
            "input_audio_format": "pcm",
            "sample_rate": 16000,
            "input_audio_transcription": { "language": language },
            "turn_detection": {
                "type": "server_vad",
                "threshold": 0.0,
                "silence_duration_ms": SERVER_SILENCE_MS
            }
        }
    })
    .to_string()
}

fn append_payload(frame: &[i16]) -> String {
    let bytes: Vec<u8> = frame.iter().flat_map(|s| s.to_le_bytes()).collect();
    serde_json::json!({
        "type": "input_audio_buffer.append",
        "audio": base64::engine::general_purpose::STANDARD.encode(bytes),
    })
    .to_string()
}

fn finish_payload() -> String {
    serde_json::json!({ "type": "session.finish" }).to_string()
}

/// Map one server text event onto the engine's ASR events; `None` for the
/// protocol chatter we do not act on.
fn server_event(text: &str) -> Option<AsrEvent> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    match value["type"].as_str()? {
        "conversation.item.input_audio_transcription.text" => {
            // The preview is the confirmed prefix plus the draft suffix.
            let combined = format!(
                "{}{}",
                value["text"].as_str().unwrap_or_default(),
                value["stash"].as_str().unwrap_or_default()
            );
            (!combined.is_empty()).then_some(AsrEvent::Partial { text: combined })
        }
        "conversation.item.input_audio_transcription.completed" => Some(AsrEvent::Final {
            text: value["transcript"].as_str().unwrap_or_default().to_string(),
        }),
        "error" => Some(AsrEvent::Failed {
            message: value["error"]["message"]
                .as_str()
                .unwrap_or("server error")
                .to_string(),
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    use async_trait::async_trait;
    use futures::StreamExt;
    use serde_json::Value;
    use tokio::sync::mpsc;

    use spokenrectifier_audio::MicEvent;

    use crate::gate::PAD_MS;
    use crate::test_support::{tone_frames as tone, zero_frames as zeros};
    use crate::transport::RealtimeChannel;

    // -- scripted connection ------------------------------------------------

    /// What one planned `connect()` does.
    enum PlanEntry {
        /// A live channel; `release` gates when `connect()` resolves, so a
        /// test can hold a reconnect open while frames keep arriving.
        Live {
            channel: RealtimeChannel,
            release: Option<mpsc::Receiver<()>>,
        },
        /// Fail before the session begins (auth, unreachable).
        Fail(ConnectError),
    }

    /// The halves of a planned connection the test keeps: watch what the
    /// adapter sends, feed it server events.
    #[derive(Clone)]
    struct ConnHandles {
        observe: Arc<tokio::sync::Mutex<mpsc::Receiver<String>>>,
        feed: mpsc::Sender<Result<String, String>>,
    }

    /// Plumb one planned live connection.
    fn live_conn(release: Option<mpsc::Receiver<()>>) -> (PlanEntry, ConnHandles) {
        let (client_tx, observe) = mpsc::channel(64);
        let (feed, client_rx) = mpsc::channel(64);
        (
            PlanEntry::Live {
                channel: RealtimeChannel {
                    tx: client_tx,
                    rx: client_rx,
                },
                release,
            },
            ConnHandles {
                observe: Arc::new(tokio::sync::Mutex::new(observe)),
                feed,
            },
        )
    }

    #[derive(Clone, Default)]
    struct ScriptedConnect {
        plan: Arc<std::sync::Mutex<std::collections::VecDeque<PlanEntry>>>,
        connect_count: Arc<std::sync::atomic::AtomicUsize>,
    }

    impl ScriptedConnect {
        fn new(plan: Vec<PlanEntry>) -> Self {
            Self {
                plan: Arc::new(std::sync::Mutex::new(plan.into())),
                connect_count: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            }
        }
    }

    #[async_trait]
    impl RealtimeConnect for ScriptedConnect {
        async fn connect(&self) -> Result<RealtimeChannel, ConnectError> {
            self.connect_count
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let entry = self.plan.lock().unwrap().pop_front();
            match entry {
                Some(PlanEntry::Fail(err)) => Err(err),
                Some(PlanEntry::Live { channel, release }) => {
                    if let Some(mut release) = release {
                        let _ = release.recv().await;
                    }
                    Ok(channel)
                }
                None => Err(ConnectError::Other("no more planned connections".into())),
            }
        }
    }

    // -- harness ------------------------------------------------------------

    /// Frame-source factory that scripts one mic session. With
    /// `stay_open` the channel stays open after the script — a healthy
    /// capture has no end-of-stream — so tests can keep feeding server
    /// events into a live session.
    fn scripted_source(sends: Vec<MicEvent>, stay_open: bool) -> FrameSource {
        Arc::new(move || {
            let (tx, rx) = std::sync::mpsc::channel();
            let script = sends.clone();
            std::thread::spawn(move || {
                for event in script {
                    if tx.send(event).is_err() {
                        return;
                    }
                }
                if stay_open {
                    std::mem::forget(tx); // leak the sender: no end signal
                }
            });
            Ok(rx)
        })
    }

    fn provider(connect: Arc<ScriptedConnect>, sends: Vec<MicEvent>, stay_open: bool) -> AliyunAsr {
        AliyunAsr::with_parts(
            AsrConfig::defaults(),
            Default::default(),
            scripted_source(sends, stay_open),
            connect,
            Duration::from_millis(500),
        )
    }

    /// Collect adapter events until the stream ends, a Failed lands, or
    /// the deadline passes.
    async fn collect(mut stream: BoxStream<'static, AsrEvent>) -> Vec<AsrEvent> {
        let mut events = Vec::new();
        while let Ok(Some(event)) =
            tokio::time::timeout(Duration::from_millis(800), stream.next()).await
        {
            let failed = matches!(event, AsrEvent::Failed { .. });
            events.push(event);
            if failed {
                break;
            }
        }
        events
    }

    /// Await at least one adapter-sent text matching `pred`.
    async fn sent_matching(
        observe: &Arc<tokio::sync::Mutex<mpsc::Receiver<String>>>,
        pred: impl Fn(&Value) -> bool,
    ) -> Value {
        let mut observe = observe.lock().await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while let Ok(Some(text)) = tokio::time::timeout_at(deadline, observe.recv()).await {
            if let Ok(value) = serde_json::from_str::<Value>(&text)
                && pred(&value)
            {
                return value;
            }
        }
        panic!("no matching sent text arrived in time");
    }

    /// Sent event types, drained briefly.
    async fn sent_types(observe: &Arc<tokio::sync::Mutex<mpsc::Receiver<String>>>) -> Vec<String> {
        let mut observe = observe.lock().await;
        let mut types = Vec::new();
        while let Ok(Some(text)) =
            tokio::time::timeout(Duration::from_millis(150), observe.recv()).await
        {
            if let Ok(value) = serde_json::from_str::<Value>(&text) {
                types.push(value["type"].as_str().unwrap_or_default().to_string());
            }
        }
        types
    }

    fn json_type(value: &Value) -> &str {
        value["type"].as_str().unwrap_or("")
    }

    fn audio_bytes(value: &Value) -> Vec<u8> {
        base64::engine::general_purpose::STANDARD
            .decode(value["audio"].as_str().unwrap_or_default())
            .unwrap()
    }

    fn server_text(text: &str, stash: &str) -> Result<String, String> {
        Ok(format!(
            r#"{{"type":"conversation.item.input_audio_transcription.text","text":"{text}","stash":"{stash}"}}"#
        ))
    }

    fn server_final(transcript: &str) -> Result<String, String> {
        Ok(format!(
            r#"{{"type":"conversation.item.input_audio_transcription.completed","transcript":"{transcript}"}}"#
        ))
    }

    fn frame_bytes(frame: &[i16]) -> Vec<u8> {
        frame.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    // -- tests --------------------------------------------------------------

    #[tokio::test]
    async fn open_configures_the_session_and_streams_transcripts() {
        // Calibration, speech, then a long quiet.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 6).into_iter().map(MicEvent::Frame));
        sends.extend(zeros(20).into_iter().map(MicEvent::Frame));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry]));
        let provider = provider(connect, sends, false);
        let stream = provider.open_stream().await.expect("open");

        // Server streams a partial then a final while audio flows.
        handles
            .feed
            .send(server_text("你好", "世界"))
            .await
            .unwrap();
        handles.feed.send(server_final("你好世界")).await.unwrap();

        let events = collect(stream).await;
        assert!(
            events.contains(&AsrEvent::Partial {
                text: "你好世界".into()
            }),
            "partial = text+stash, got {events:?}"
        );
        assert!(
            events.contains(&AsrEvent::Final {
                text: "你好世界".into()
            }),
            "got {events:?}"
        );
        assert!(
            events.contains(&AsrEvent::SpeechActivity { speaking: true }),
            "orb state flows, got {events:?}"
        );

        // Wire: session.update first, with the fields that matter.
        let update = sent_matching(&handles.observe, |v| json_type(v) == "session.update").await;
        assert_eq!(update["session"]["input_audio_format"], "pcm");
        assert_eq!(update["session"]["sample_rate"], 16000);
        assert_eq!(update["session"]["turn_detection"]["type"], "server_vad");
        assert_eq!(
            update["session"]["input_audio_transcription"]["language"],
            "zh"
        );

        // Then appends: the 6 speech frames plus the quiet pad, nothing else.
        let mut sent_audio = Vec::new();
        {
            let mut observe = handles.observe.lock().await;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
            while let Ok(Some(text)) = tokio::time::timeout_at(deadline, observe.recv()).await {
                if let Ok(value) = serde_json::from_str::<Value>(&text)
                    && json_type(&value) == "input_audio_buffer.append"
                {
                    sent_audio.push(audio_bytes(&value));
                }
            }
        }
        let mut expected: Vec<Vec<u8>> = tone(0.6, 6).iter().map(|f| frame_bytes(f)).collect();
        expected.extend(zeros(PAD_MS as usize / 100).iter().map(|f| frame_bytes(f)));
        assert_eq!(sent_audio, expected, "gate sends speech plus pad only");
    }

    #[tokio::test]
    async fn idle_session_never_sends_audio() {
        let mut sends: Vec<MicEvent> = zeros(30).into_iter().map(MicEvent::Frame).collect();
        sends.push(MicEvent::Error("device gone".into())); // end the session

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry]));
        let provider = provider(connect, sends, false);
        let stream = provider.open_stream().await.expect("open");

        let events = collect(stream).await;
        assert_eq!(
            events.last(),
            Some(&AsrEvent::Failed {
                message: "device gone".into()
            })
        );

        // Only the session.update (and the graceful finish) ever hit the
        // wire — no audio at all.
        let types = sent_types(&handles.observe).await;
        assert_eq!(types, vec!["session.update", "session.finish"]);
    }

    #[tokio::test]
    async fn server_error_ends_the_session_with_feedback() {
        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry]));
        let provider = provider(connect, vec![], true);
        let stream = provider.open_stream().await.expect("open");

        handles
            .feed
            .send(Ok(
                r#"{"type":"error","error":{"code":"x","message":"quota exceeded"}}"#.into(),
            ))
            .await
            .unwrap();
        let events = collect(stream).await;
        assert_eq!(
            events.last(),
            Some(&AsrEvent::Failed {
                message: "quota exceeded".into()
            })
        );
    }

    #[tokio::test]
    async fn connection_loss_reconnects_and_continues() {
        // Speech throughout; the first connection dies mid-stream.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 12).into_iter().map(MicEvent::Frame));

        let (entry1, handles1) = live_conn(None);
        let (release_tx, release_rx) = mpsc::channel(1);
        let (entry2, handles2) = live_conn(Some(release_rx));
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry1, entry2]));
        let provider = provider(connect, sends, true);
        let stream = provider.open_stream().await.expect("open");

        // Kill the first connection once speech is flowing.
        handles1
            .feed
            .send(Err("connection lost".into()))
            .await
            .unwrap();

        // Release the held-open reconnect (connect #2 was pending); the
        // assertions below wait on observed state, not on timing.
        release_tx.send(()).await.unwrap();

        // Fresh connection re-configures the session and carries on: the
        // buffered speech is flushed and transcripts flow again.
        let update = sent_matching(&handles2.observe, |v| json_type(v) == "session.update").await;
        assert_eq!(update["session"]["input_audio_format"], "pcm");

        handles2.feed.send(server_final("断线之后")).await.unwrap();
        let events = collect(stream).await;
        assert!(
            events.contains(&AsrEvent::Final {
                text: "断线之后".into()
            }),
            "got {events:?}"
        );
    }

    #[tokio::test]
    async fn exhausted_reconnects_end_with_feedback() {
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 6).into_iter().map(MicEvent::Frame));
        sends.extend(zeros(20).into_iter().map(MicEvent::Frame));

        let (entry1, handles1) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![
            entry1,
            PlanEntry::Fail(ConnectError::Other("connection failed: dns".into())),
            PlanEntry::Fail(ConnectError::Other("connection failed: dns".into())),
        ]));
        let provider = provider(connect, sends, true);
        let stream = provider.open_stream().await.expect("open");

        handles1
            .feed
            .send(Err("connection lost".into()))
            .await
            .unwrap();
        let events = collect(stream).await;
        assert!(
            matches!(events.last(), Some(AsrEvent::Failed { .. })),
            "got {events:?}"
        );
    }

    #[tokio::test]
    async fn auth_failure_is_not_retried() {
        let (entry1, handles1) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![
            entry1,
            PlanEntry::Fail(ConnectError::Auth("handshake rejected: HTTP 401".into())),
        ]));
        let provider = provider(connect.clone(), vec![], true);
        let stream = provider.open_stream().await.expect("open");

        handles1
            .feed
            .send(Err("connection lost".into()))
            .await
            .unwrap();
        let events = collect(stream).await;
        let Some(AsrEvent::Failed { message }) = events.last() else {
            panic!("got {events:?}")
        };
        assert!(message.contains("401"), "got: {message}");
        // One live connection, one auth-failed attempt — no second retry.
        assert_eq!(
            connect
                .connect_count
                .load(std::sync::atomic::Ordering::SeqCst),
            2
        );
    }

    #[tokio::test]
    async fn a_hanging_reconnect_times_out_and_ends_with_feedback() {
        // The second connection never resolves (no release); the handshake
        // budget must turn it into a bounded failure, not an offline wedge.
        let (entry1, handles1) = live_conn(None);
        let (_release_tx, release_rx) = mpsc::channel(1);
        let (entry2, _handles2) = live_conn(Some(release_rx));
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry1, entry2]));
        let provider = AliyunAsr::with_parts(
            AsrConfig::defaults(),
            Default::default(),
            scripted_source(vec![], true),
            connect.clone(),
            Duration::from_millis(150),
        );
        let stream = provider.open_stream().await.expect("open");

        handles1
            .feed
            .send(Err("connection lost".into()))
            .await
            .unwrap();
        let events = collect(stream).await;
        assert!(
            matches!(events.last(), Some(AsrEvent::Failed { .. })),
            "got {events:?}"
        );
        assert!(
            connect
                .connect_count
                .load(std::sync::atomic::Ordering::SeqCst)
                >= 2
        );
    }

    #[tokio::test]
    async fn auth_failure_at_open_is_an_open_error() {
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![PlanEntry::Fail(
            ConnectError::Auth("handshake rejected: HTTP 401".into()),
        )]));
        let provider = provider(connect, vec![], true);
        let Err(err) = provider.open_stream().await else {
            panic!("expected open to fail");
        };
        assert!(err.0.contains("401"), "got: {}", err.0);
        assert!(err.0.contains("handshake rejected"), "got: {}", err.0);
    }

    #[tokio::test]
    async fn trailing_finals_arrive_after_the_source_ends() {
        // The source ends quietly (no device error); the last utterance's
        // final still lands via the graceful drain.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 3).into_iter().map(MicEvent::Frame));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry]));
        let provider = provider(connect, sends, false);
        let stream = provider.open_stream().await.expect("open");

        // Wait for the graceful finish once the frames run out.
        sent_matching(&handles.observe, |v| json_type(v) == "session.finish").await;
        handles.feed.send(server_final("最后一句话")).await.unwrap();

        let events = collect(stream).await;
        assert!(
            events.contains(&AsrEvent::Final {
                text: "最后一句话".into()
            }),
            "got {events:?}"
        );
    }
}
