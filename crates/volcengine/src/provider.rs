//! [`VolcengineAsr`]: the [`AsrProvider`] adapter over the Seed-ASR
//! bigmodel streaming WebSocket.
//!
//! One recording session is one WebSocket carrying the gzip'd binary
//! frame protocol (see [`crate::frame`]). Authentication is three
//! static strings in the handshake headers — app id, access token,
//! resource id — plus a fresh connect UUID per attempt (the endpoint
//! invalidates a connection on error; a reconnect must present a new
//! id). No signature, no timestamp. The session machinery (VAD pump,
//! send gate, bounded reconnects, graceful drain) is shared in
//! `spokenrectifier-asr`; the dialect ([`crate::protocol`]) supplies
//! the payloads and the event translation.
//!
//! While the send gate holds audio back (quiet room, mid-thought pause
//! in passage mode), keepalive frames flow so the endpoint's
//! wait-packet timeout (error 45000081) never fires — a session left
//! open in silence sends no audio, but stays connected.
//!
//! [`AsrProvider`]: spokenrectifier_engine::AsrProvider

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures::stream::BoxStream;

use spokenrectifier_asr::schema::{ActiveCredentials, AsrConfig, AsrConfigError, AsrProviderKind};
use spokenrectifier_asr::session::SessionParams;
use spokenrectifier_asr::transport::{BytesWire, RealtimeConnect, TungsteniteConnect};
use spokenrectifier_audio::{FrameSource, VadConfig};
use spokenrectifier_engine::provider::asr::{AsrEvent, AsrOpenError, AsrProvider};

use crate::protocol::VolcengineProtocol;

/// Handshake budget per (re)connect attempt.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// How often a keepalive frame flows while no audio does; comfortably
/// inside the endpoint's wait-packet window.
const KEEPALIVE_EVERY: Duration = Duration::from_secs(5);

/// The cloud ASR adapter.
pub struct VolcengineAsr {
    config: AsrConfig,
    vad: VadConfig,
    source: FrameSource,
    connect: Arc<dyn RealtimeConnect<Vec<u8>>>,
    connect_timeout: Duration,
    /// Keepalive cadence; injectable so tests tick it fast.
    keepalive_every: Option<Duration>,
}

impl VolcengineAsr {
    /// Capture from the real default microphone and connect to the
    /// configured endpoint. Fails when the config is incomplete (the
    /// `[asr.volcengine]` triple missing) or the endpoint does not
    /// resolve.
    pub fn new(config: AsrConfig, vad: VadConfig) -> Result<Self, AsrConfigError> {
        if config.provider != AsrProviderKind::Volcengine {
            return Err(AsrConfigError(format!(
                "[asr] provider \"{}\" is not volcengine",
                config.provider.as_str()
            )));
        }
        let ActiveCredentials::Volcengine = config.active_credentials().map_err(|err| {
            // The incomplete-triple message already names the fields.
            AsrConfigError(err)
        })?
        else {
            unreachable!("the provider check above pins the credential family");
        };
        let endpoint = config
            .endpoint()
            .ok_or_else(|| AsrConfigError("[asr.volcengine]: no endpoint resolves".into()))?;
        let app_id = config
            .volcengine
            .app_id
            .clone()
            .expect("the credential check above guarantees the triple");
        let access_key = config
            .volcengine
            .access_key
            .clone()
            .expect("the credential check above guarantees the triple");
        let resource_id = config.volcengine.resource_id.trim().to_string();
        let connect = TungsteniteConnect::with_dynamic_headers(
            endpoint,
            // A fresh connect id per attempt: the endpoint invalidates a
            // connection on error, and a reconnect presenting the old id
            // would be refused.
            Arc::new(move || {
                vec![
                    ("X-Api-App-Key".to_string(), app_id.clone()),
                    ("X-Api-Access-Key".to_string(), access_key.clone()),
                    ("X-Api-Resource-Id".to_string(), resource_id.clone()),
                    (
                        "X-Api-Connect-Id".to_string(),
                        uuid::Uuid::new_v4().to_string(),
                    ),
                ]
            }),
            BytesWire,
        );
        Ok(Self {
            config,
            vad,
            source: Arc::new(spokenrectifier_audio::open_mic),
            connect: Arc::new(connect),
            connect_timeout: CONNECT_TIMEOUT,
            keepalive_every: Some(KEEPALIVE_EVERY),
        })
    }

    /// Fully injected assembly (tests).
    pub fn with_parts(
        config: AsrConfig,
        vad: VadConfig,
        source: FrameSource,
        connect: Arc<dyn RealtimeConnect<Vec<u8>>>,
        connect_timeout: Duration,
        keepalive_every: Option<Duration>,
    ) -> Self {
        Self {
            config,
            vad,
            source,
            connect,
            connect_timeout,
            keepalive_every,
        }
    }
}

#[async_trait]
impl AsrProvider for VolcengineAsr {
    async fn open_stream(
        &self,
        terms: &[String],
    ) -> Result<BoxStream<'static, AsrEvent>, AsrOpenError> {
        let frames = (self.source)().map_err(AsrOpenError)?;
        let _ = &self.config; // the dialect reads nothing per-stream from it
        spokenrectifier_asr::open_session(
            frames,
            VolcengineProtocol::new(terms.to_vec()),
            self.vad,
            SessionParams {
                connect: self.connect.clone(),
                connect_timeout: self.connect_timeout,
                keepalive_every: self.keepalive_every,
            },
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    use async_trait::async_trait;
    use futures::StreamExt;
    use tokio::sync::mpsc;

    use spokenrectifier_asr::transport::{ConnectError, RealtimeChannel};
    use spokenrectifier_audio::MicEvent;

    use crate::frame::{MESSAGE_AUDIO_ONLY, encode_server_response};
    use crate::test_support::{tone_frames as tone, zero_frames as zeros};

    // -- scripted connection ------------------------------------------------

    /// What one planned `connect()` does.
    enum PlanEntry {
        Live {
            channel: RealtimeChannel<Vec<u8>>,
            release: Option<mpsc::Receiver<()>>,
        },
        Fail(ConnectError),
    }

    /// The halves of a planned connection the test keeps: watch what the
    /// adapter sends, feed it server frames.
    #[derive(Clone)]
    struct ConnHandles {
        observe: Arc<tokio::sync::Mutex<mpsc::Receiver<Vec<u8>>>>,
        feed: mpsc::Sender<Result<Vec<u8>, String>>,
    }

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
    impl RealtimeConnect<Vec<u8>> for ScriptedConnect {
        async fn connect(&self) -> Result<RealtimeChannel<Vec<u8>>, ConnectError> {
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

    fn scripted_source(sends: Vec<MicEvent>, stay_open: bool) -> FrameSource {
        paced_source(sends, stay_open, None)
    }

    /// Like [`scripted_source`], but pacing frames `delay` apart so
    /// wall-clock arms (the keepalive tick) get their turn.
    fn paced_source(sends: Vec<MicEvent>, stay_open: bool, delay: Option<Duration>) -> FrameSource {
        Arc::new(move || {
            let (tx, rx) = std::sync::mpsc::channel();
            let script = sends.clone();
            std::thread::spawn(move || {
                for event in script {
                    if let Some(delay) = delay {
                        std::thread::sleep(delay);
                    }
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

    fn provider(
        connect: Arc<ScriptedConnect>,
        sends: Vec<MicEvent>,
        stay_open: bool,
    ) -> VolcengineAsr {
        VolcengineAsr::with_parts(
            volc_config(),
            Default::default(),
            scripted_source(sends, stay_open),
            connect,
            Duration::from_millis(500),
            None,
        )
    }

    fn volc_config() -> AsrConfig {
        let mut config = AsrConfig::defaults();
        config.provider = AsrProviderKind::Volcengine;
        config.volcengine.app_id = Some("42".into());
        config.volcengine.access_key = Some("volc-token".into());
        config
    }

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

    /// Await at least one adapter-sent frame of the given message type,
    /// decompressed.
    async fn sent_frame(
        observe: &Arc<tokio::sync::Mutex<mpsc::Receiver<Vec<u8>>>>,
        message_type: u8,
    ) -> Vec<u8> {
        let mut observe = observe.lock().await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while let Ok(Some(bytes)) = tokio::time::timeout_at(deadline, observe.recv()).await {
            let (kind, payload) = crate::frame::client_payload(&bytes);
            if kind == message_type {
                return payload;
            }
        }
        panic!("no frame of type {message_type:#08b} arrived in time");
    }

    /// Await the stream's last-packet frame: audio-only, last flag, no
    /// payload.
    async fn sent_last_packet(observe: &Arc<tokio::sync::Mutex<mpsc::Receiver<Vec<u8>>>>) {
        let mut observe = observe.lock().await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while let Ok(Some(bytes)) = tokio::time::timeout_at(deadline, observe.recv()).await {
            if bytes[1] >> 4 == MESSAGE_AUDIO_ONLY && bytes[1] & crate::frame::FLAG_LAST_PACKET != 0
            {
                assert_eq!(bytes.len(), 8, "last packet carries no payload");
                return;
            }
        }
        panic!("no last-packet frame arrived in time");
    }

    fn server_response(json: serde_json::Value) -> Result<Vec<u8>, String> {
        Ok(encode_server_response(&json.to_string()))
    }

    fn utterance(text: &str, definite: bool) -> serde_json::Value {
        serde_json::json!({ "text": text, "definite": definite })
    }

    // -- tests --------------------------------------------------------------

    #[tokio::test]
    async fn open_sends_the_full_request_and_streams_transcripts() {
        // Calibration, speech, then a long quiet.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 6).into_iter().map(MicEvent::Frame));
        sends.extend(zeros(20).into_iter().map(MicEvent::Frame));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry]));
        let provider = provider(connect, sends, false);
        let dictionary = vec!["SpokenRectifier".to_string()];
        let stream = provider.open_stream(&dictionary).await.expect("open");

        // Server settles one utterance while audio flows.
        handles
            .feed
            .send(server_response(serde_json::json!({
                "result": { "utterances": [utterance("你好世界", true)] }
            })))
            .await
            .unwrap();

        let events = collect(stream).await;
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

        // Wire: the full client request first, carrying the dictionary.
        let payload = sent_frame(&handles.observe, crate::frame::MESSAGE_FULL_CLIENT_REQUEST).await;
        let request: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(
            request["request"]["corpus"]["context"]["hotwords"],
            serde_json::json!([{ "word": "SpokenRectifier" }])
        );
    }

    #[tokio::test]
    async fn audio_travels_as_gzip_pcm_for_gate_approved_frames_only() {
        // Calibration, speech, then a long quiet past the send pad.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 6).into_iter().map(MicEvent::Frame));
        sends.extend(zeros(30).into_iter().map(MicEvent::Frame));
        sends.push(MicEvent::Error("device gone".into()));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry]));
        let provider = provider(connect, sends, false);
        let stream = provider.open_stream(&[]).await.expect("open");
        let events = collect(stream).await;
        assert!(matches!(events.last(), Some(AsrEvent::Failed { .. })));

        // The audio frames on the wire: speech plus the quiet pad, and
        // nothing else — each the little-endian PCM of its frame.
        let mut observe = handles.observe.lock().await;
        let mut payloads = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while let Ok(Some(bytes)) = tokio::time::timeout_at(deadline, observe.recv()).await {
            let (kind, payload) = crate::frame::client_payload(&bytes);
            if kind == MESSAGE_AUDIO_ONLY && !payload.is_empty() {
                payloads.push(payload);
            }
        }
        let mut expected: Vec<Vec<u8>> = tone(0.6, 6)
            .iter()
            .map(|f| f.iter().flat_map(|s| s.to_le_bytes()).collect())
            .collect();
        let pad = spokenrectifier_asr::PAD_MS as usize / 100;
        expected.extend(
            zeros(pad)
                .iter()
                .map(|f| f.iter().flat_map(|s| s.to_le_bytes()).collect()),
        );
        assert_eq!(payloads, expected, "gate sends speech plus pad only");
    }

    #[tokio::test]
    async fn a_quiet_session_sends_keepalives_and_no_audio() {
        // A quiet capture paced in real time (30 frames x 40ms), so the
        // keepalive tick gets its turn between frames; the device error
        // ends the session.
        let mut sends: Vec<MicEvent> = zeros(30).into_iter().map(MicEvent::Frame).collect();
        sends.push(MicEvent::Error("device gone".into()));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry]));
        let provider = VolcengineAsr::with_parts(
            volc_config(),
            Default::default(),
            paced_source(sends, false, Some(Duration::from_millis(40))),
            connect,
            Duration::from_millis(500),
            Some(Duration::from_millis(30)), // tick the keepalive fast
        );
        let stream = provider.open_stream(&[]).await.expect("open");
        let events = collect(stream).await;
        assert!(matches!(events.last(), Some(AsrEvent::Failed { .. })));

        // Wire: the full request, keepalives while quiet, no audio, and
        // the last packet at the graceful end.
        let mut observe = handles.observe.lock().await;
        let mut kinds = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while let Ok(Some(bytes)) = tokio::time::timeout_at(deadline, observe.recv()).await {
            kinds.push((bytes[1] >> 4, bytes.len()));
        }
        assert_eq!(
            kinds.first().map(|(kind, _)| *kind),
            Some(crate::frame::MESSAGE_FULL_CLIENT_REQUEST)
        );
        assert!(
            kinds
                .iter()
                .any(|(kind, _)| *kind == crate::frame::MESSAGE_KEEPALIVE),
            "no keepalive on an idle stream: {kinds:?}"
        );
        assert!(
            !kinds
                .iter()
                .any(|&(kind, len)| kind == MESSAGE_AUDIO_ONLY && len > 8),
            "audio on silence: {kinds:?}"
        );
        assert_eq!(
            kinds.last(),
            Some(&(MESSAGE_AUDIO_ONLY, 8)),
            "graceful end is the last packet: {kinds:?}"
        );
    }

    #[tokio::test]
    async fn the_graceful_end_is_a_last_packet_frame() {
        // The source ends quietly; the drain forwards trailing finals.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 3).into_iter().map(MicEvent::Frame));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry]));
        let provider = provider(connect, sends, false);
        let stream = provider.open_stream(&[]).await.expect("open");

        // Wait for the last packet once the frames run out, then answer.
        sent_last_packet(&handles.observe).await;
        handles
            .feed
            .send(server_response(serde_json::json!({
                "result": { "utterances": [utterance("最后一句话", true)] }
            })))
            .await
            .unwrap();

        let events = collect(stream).await;
        assert!(
            events.contains(&AsrEvent::Final {
                text: "最后一句话".into()
            }),
            "got {events:?}"
        );
    }

    #[tokio::test]
    async fn server_error_frames_end_the_session_with_feedback() {
        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry]));
        let provider = provider(connect, vec![], true);
        let stream = provider.open_stream(&[]).await.expect("open");

        handles
            .feed
            .send(Ok(crate::frame::encode_server_error(
                r#"{"code":45000002,"message":"empty audio"}"#,
            )))
            .await
            .unwrap();
        let events = collect(stream).await;
        assert_eq!(
            events.last(),
            Some(&AsrEvent::Failed {
                message: "ASR 45000002: empty audio".into()
            })
        );
    }

    #[tokio::test]
    async fn a_lost_connection_reconnects_with_a_fresh_full_request() {
        // Speech throughout; the first connection dies mid-stream.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 12).into_iter().map(MicEvent::Frame));

        let (entry1, handles1) = live_conn(None);
        let (release_tx, release_rx) = mpsc::channel(1);
        let (entry2, handles2) = live_conn(Some(release_rx));
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![entry1, entry2]));
        let provider = provider(connect, sends, true);
        let dictionary = vec!["语音实验室".to_string()];
        let stream = provider.open_stream(&dictionary).await.expect("open");

        // Kill the first connection once speech is flowing.
        handles1
            .feed
            .send(Err("connection lost".into()))
            .await
            .unwrap();
        release_tx.send(()).await.unwrap();

        // The fresh connection gets its own full request (the server
        // holds no session state across connections) with the same
        // dictionary, and the buffered speech is flushed.
        let payload =
            sent_frame(&handles2.observe, crate::frame::MESSAGE_FULL_CLIENT_REQUEST).await;
        let request: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(
            request["request"]["corpus"]["context"]["hotwords"],
            serde_json::json!([{ "word": "语音实验室" }])
        );

        handles2
            .feed
            .send(server_response(serde_json::json!({
                "result": { "utterances": [utterance("断线之后", true)] }
            })))
            .await
            .unwrap();
        let events = collect(stream).await;
        assert!(
            events.contains(&AsrEvent::Final {
                text: "断线之后".into()
            }),
            "got {events:?}"
        );
    }

    #[tokio::test]
    async fn an_incomplete_triple_is_a_construction_error() {
        let mut config = AsrConfig::defaults();
        config.provider = AsrProviderKind::Volcengine;
        config.volcengine.access_key = Some("token only".into());
        let err = match VolcengineAsr::new(config, VadConfig::default()) {
            Err(err) => err.0,
            Ok(_) => panic!("an incomplete triple must not construct"),
        };
        assert!(err.contains("app_id"), "got: {err}");
        assert!(err.contains("resource_id"), "got: {err}");
    }

    #[tokio::test]
    async fn auth_failure_at_open_is_an_open_error() {
        let connect: Arc<ScriptedConnect> = Arc::new(ScriptedConnect::new(vec![PlanEntry::Fail(
            ConnectError::Auth("handshake rejected: HTTP 401".into()),
        )]));
        let provider = provider(connect, vec![], true);
        let Err(err) = provider.open_stream(&[]).await else {
            panic!("expected open to fail");
        };
        assert!(err.0.contains("401"), "got: {}", err.0);
    }
}
