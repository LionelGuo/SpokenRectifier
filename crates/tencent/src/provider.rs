//! [`TencentAsr`]: the [`AsrProvider`] adapter over Tencent Cloud's
//! realtime speech recognition WebSocket.
//!
//! One recording session is one WebSocket whose entire configuration —
//! engine, credentials, VAD settings, the hotword dictionary — rides
//! the signed query of the connect URL (see [`crate::sign`]). Every
//! (re)connect attempt builds a fresh URL: a new timestamp, nonce, and
//! voice id, hence a new signature, because the endpoint invalidates a
//! connection on error and refuses a reused voice id. The session
//! machinery (VAD pump, send gate, bounded reconnects, graceful drain)
//! is shared in `spokenrectifier-asr`; the dialect ([`crate::protocol`])
//! supplies the mixed frames and the event translation.
//!
//! While the send gate holds audio back (quiet room, mid-thought pause
//! in passage mode), silence slices flow so the endpoint's audio-gap
//! disconnect (~6 s, error 4008 at 15 s) never fires — a session left
//! open in silence sends no real audio, but stays connected.
//!
//! [`AsrProvider`]: spokenrectifier_engine::AsrProvider

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures::stream::BoxStream;

use spokenrectifier_asr::schema::{ActiveCredentials, AsrConfig, AsrConfigError, AsrProviderKind};
use spokenrectifier_asr::session::SessionParams;
use spokenrectifier_asr::transport::{RealtimeConnect, TungsteniteConnect};
use spokenrectifier_audio::{FrameSource, VadConfig};
use spokenrectifier_engine::provider::asr::{AsrEvent, AsrOpenError, AsrProvider};

use crate::protocol::{OutFrame, TencentProtocol, TencentWire};
use crate::sign::{UrlInputs, signed_url};

/// Handshake budget per (re)connect attempt.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// How often a silence slice flows while no audio does; comfortably
/// inside the endpoint's audio-gap window.
const KEEPALIVE_EVERY: Duration = Duration::from_secs(5);

/// The ingredients every per-attempt URL is signed from — everything
/// the connection needs except the freshness (clock, nonce, voice id)
/// and the stream's dictionary.
struct ConnectSeed {
    /// The resolved endpoint: `scheme://host/asr/v2/<appid>`.
    endpoint: String,
    secret_id: String,
    secret_key: String,
    engine_model_type: String,
}

/// The per-attempt URL builder for one stream: a fresh timestamp,
/// nonce, and voice id on every call.
fn url_builder(
    seed: Arc<ConnectSeed>,
    terms: Arc<Vec<String>>,
) -> Arc<dyn Fn() -> String + Send + Sync> {
    Arc::new(move || {
        signed_url(UrlInputs {
            endpoint: &seed.endpoint,
            secret_id: &seed.secret_id,
            secret_key: &seed.secret_key,
            engine_model_type: &seed.engine_model_type,
            terms: &terms,
            now_unix: unix_now(),
            nonce: fresh_nonce(),
            voice_id: &uuid::Uuid::new_v4().to_string(),
        })
    })
}

/// The wall clock in unix seconds (0 before the epoch — any
/// deterministic fallback keeps the URL well-formed).
fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| since.as_secs())
        .unwrap_or(0)
}

/// A random positive int under the documented 10-digit ceiling; any
/// varying value satisfies the nonce.
fn fresh_nonce() -> u64 {
    uuid::Uuid::new_v4().as_u128() as u64 % 1_000_000_000
}

/// Builds the connect for one stream, given that stream's dictionary
/// (the dictionary rides the connect URL; tests inject a scripted
/// connect regardless).
type ConnectMaker = Arc<dyn Fn(&[String]) -> Arc<dyn RealtimeConnect<OutFrame>> + Send + Sync>;

/// The cloud ASR adapter. The dictionary rides the connect URL, so the
/// transport is built per stream — the provider holds the signing seed
/// and hands the fresh-URL factory to each stream's session.
pub struct TencentAsr {
    vad: VadConfig,
    source: FrameSource,
    make_connect: ConnectMaker,
    connect_timeout: Duration,
    /// Keepalive cadence; injectable so tests tick it fast.
    keepalive_every: Option<Duration>,
}

impl TencentAsr {
    /// Capture from the real default microphone and connect to the
    /// configured endpoint. Fails when the config is incomplete (the
    /// `[asr.tencent]` triple missing) or the endpoint does not
    /// resolve.
    pub fn new(config: AsrConfig, vad: VadConfig) -> Result<Self, AsrConfigError> {
        if config.provider != AsrProviderKind::Tencent {
            return Err(AsrConfigError(format!(
                "[asr] provider \"{}\" is not tencent",
                config.provider.as_str()
            )));
        }
        let ActiveCredentials::Tencent = config.active_credentials().map_err(AsrConfigError)?
        else {
            unreachable!("the provider check above pins the credential family");
        };
        let endpoint = config
            .endpoint()
            .ok_or_else(|| AsrConfigError("[asr.tencent]: no endpoint resolves".into()))?;
        let seed = Arc::new(ConnectSeed {
            endpoint,
            secret_id: config
                .tencent
                .secret_id
                .expect("the credential check above guarantees the triple"),
            secret_key: config
                .tencent
                .secret_key
                .expect("the credential check above guarantees the triple"),
            engine_model_type: config.model.trim().to_string(),
        });
        Ok(Self {
            vad,
            source: Arc::new(spokenrectifier_audio::open_mic),
            make_connect: Arc::new(move |terms| {
                let terms = Arc::new(terms.to_vec());
                Arc::new(TungsteniteConnect::with_dynamic_url(
                    url_builder(seed.clone(), terms),
                    Arc::new(Vec::new),
                    TencentWire,
                ))
            }),
            connect_timeout: CONNECT_TIMEOUT,
            keepalive_every: Some(KEEPALIVE_EVERY),
        })
    }

    /// Fully injected assembly (tests): one scripted connect for every
    /// stream, the dictionary ignored (its URL ride is covered where
    /// the URL builder is tested directly).
    pub fn with_parts(
        vad: VadConfig,
        source: FrameSource,
        connect: Arc<dyn RealtimeConnect<OutFrame>>,
        connect_timeout: Duration,
        keepalive_every: Option<Duration>,
    ) -> Self {
        Self {
            vad,
            source,
            make_connect: Arc::new(move |_terms| connect.clone()),
            connect_timeout,
            keepalive_every,
        }
    }
}

#[async_trait]
impl AsrProvider for TencentAsr {
    async fn open_stream(
        &self,
        terms: &[String],
    ) -> Result<BoxStream<'static, AsrEvent>, AsrOpenError> {
        let frames = (self.source)().map_err(AsrOpenError)?;
        let connect = (self.make_connect)(terms);
        spokenrectifier_asr::open_session(
            frames,
            TencentProtocol,
            self.vad,
            SessionParams {
                connect,
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

    use spokenrectifier_asr::PAD_MS;
    use spokenrectifier_asr::testing::{
        PlanEntry, ScriptedConnect, collect, live_conn, paced_source, scripted_source,
    };
    use spokenrectifier_asr::transport::ConnectError;
    use spokenrectifier_audio::MicEvent;

    use crate::test_support::{tone_frames as tone, zero_frames as zeros};

    // -- harness ------------------------------------------------------------

    fn provider(
        connect: Arc<ScriptedConnect<OutFrame>>,
        sends: Vec<MicEvent>,
        stay_open: bool,
    ) -> TencentAsr {
        TencentAsr::with_parts(
            Default::default(),
            scripted_source(sends, stay_open),
            connect,
            Duration::from_millis(500),
            None,
        )
    }

    /// Await at least one adapter-sent frame matching `pred`.
    async fn sent_matching(
        observe: &Arc<tokio::sync::Mutex<tokio::sync::mpsc::Receiver<OutFrame>>>,
        pred: impl Fn(&OutFrame) -> bool,
    ) -> OutFrame {
        let mut observe = observe.lock().await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while let Ok(Some(frame)) = tokio::time::timeout_at(deadline, observe.recv()).await {
            if pred(&frame) {
                return frame;
            }
        }
        panic!("no matching frame arrived in time");
    }

    fn is_audio(frame: &OutFrame) -> bool {
        matches!(frame, OutFrame::Audio(_))
    }

    fn audio_bytes(frame: &OutFrame) -> Vec<u8> {
        let OutFrame::Audio(bytes) = frame else {
            panic!("expected an audio frame, got {frame:?}");
        };
        bytes.clone()
    }

    fn frame_bytes(frame: &[i16]) -> Vec<u8> {
        frame.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    fn server(json: serde_json::Value) -> Result<OutFrame, String> {
        Ok(OutFrame::Text(json.to_string()))
    }

    // -- tests --------------------------------------------------------------

    #[tokio::test]
    async fn open_streams_transcripts_with_no_opening_message() {
        // Calibration, speech, then a long quiet.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 6).into_iter().map(MicEvent::Frame));
        sends.extend(zeros(20).into_iter().map(MicEvent::Frame));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect<OutFrame>> =
            Arc::new(ScriptedConnect::<OutFrame>::new(vec![entry]));
        let provider = provider(connect, sends, false);
        let stream = provider.open_stream(&[]).await.expect("open");

        // Server settles one slice while audio flows: a draft, then the
        // stable end.
        handles
            .feed
            .send(server(serde_json::json!({
                "code": 0, "result": { "slice_type": 1, "index": 0,
                                       "voice_text_str": "你好" }
            })))
            .await
            .unwrap();
        handles
            .feed
            .send(server(serde_json::json!({
                "code": 0, "result": { "slice_type": 2, "index": 0,
                                       "voice_text_str": "你好世界" }
            })))
            .await
            .unwrap();

        let events = collect(stream).await;
        assert!(
            events.contains(&AsrEvent::Partial {
                text: "你好".into()
            }),
            "got {events:?}"
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

        // Wire: the first client frame is AUDIO — no opening message in
        // this dialect, the URL carries the configuration.
        let first = sent_matching(&handles.observe, |_| true).await;
        assert!(is_audio(&first), "got {first:?}");
    }

    #[tokio::test]
    async fn audio_travels_as_binary_pcm_for_gate_approved_frames_only() {
        // Calibration, speech, then a long quiet past the send pad.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 6).into_iter().map(MicEvent::Frame));
        sends.extend(zeros(30).into_iter().map(MicEvent::Frame));
        sends.push(MicEvent::Error("device gone".into()));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect<OutFrame>> =
            Arc::new(ScriptedConnect::<OutFrame>::new(vec![entry]));
        let provider = provider(connect, sends, false);
        let stream = provider.open_stream(&[]).await.expect("open");
        let events = collect(stream).await;
        assert!(matches!(events.last(), Some(AsrEvent::Failed { .. })));

        // The audio frames on the wire: speech plus the quiet pad, and
        // nothing else — each the little-endian PCM of its frame.
        let mut observe = handles.observe.lock().await;
        let mut payloads = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while let Ok(Some(frame)) = tokio::time::timeout_at(deadline, observe.recv()).await {
            if is_audio(&frame) {
                payloads.push(audio_bytes(&frame));
            }
        }
        let mut expected: Vec<Vec<u8>> = tone(0.6, 6).iter().map(|f| frame_bytes(f)).collect();
        let pad = PAD_MS as usize / 100;
        expected.extend(zeros(pad).iter().map(|f| frame_bytes(f)));
        assert_eq!(payloads, expected, "gate sends speech plus pad only");
    }

    #[tokio::test]
    async fn a_quiet_session_sends_silence_keepalives_and_no_speech() {
        // A quiet capture paced in real time (30 frames x 100ms), so
        // the keepalive tick gets its turn between frames; the device
        // error ends the session.
        let mut sends: Vec<MicEvent> = zeros(30).into_iter().map(MicEvent::Frame).collect();
        sends.push(MicEvent::Error("device gone".into()));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect<OutFrame>> =
            Arc::new(ScriptedConnect::<OutFrame>::new(vec![entry]));
        let provider = TencentAsr::with_parts(
            Default::default(),
            paced_source(sends, false, Some(Duration::from_millis(100))),
            connect,
            Duration::from_millis(500),
            Some(Duration::from_millis(30)), // tick the keepalive fast
        );
        let stream = provider.open_stream(&[]).await.expect("open");

        // Drain the wire concurrently: the keepalive cadence outpaces
        // what a post-hoc reader could catch up with (the channel
        // would fill and backpressure the pump).
        let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
        let recorder = seen.clone();
        let observer = handles.observe.clone();
        tokio::spawn(async move {
            let mut observe = observer.lock().await;
            while let Some(frame) = observe.recv().await {
                recorder.lock().unwrap().push(frame);
            }
        });

        let events = collect(stream).await;
        assert!(matches!(events.last(), Some(AsrEvent::Failed { .. })));

        // The graceful end trails the failure: wait for the end
        // message before judging the wire.
        let end = OutFrame::Text(r#"{"type":"end"}"#.into());
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            let last = seen.lock().unwrap().last().cloned();
            if last.as_ref() == Some(&end) {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "no end message arrived: {last:?}"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let frames = std::mem::take(&mut *seen.lock().unwrap());

        // Wire: silence keepalives while quiet, no speech audio, and
        // the end text message at the graceful end.
        let silences = frames
            .iter()
            .filter(|f| is_audio(f) && audio_bytes(f).iter().all(|b| *b == 0))
            .count();
        assert!(silences > 0, "no keepalive on an idle stream: {frames:?}");
        assert!(
            !frames
                .iter()
                .any(|f| is_audio(f) && audio_bytes(f).iter().any(|b| *b != 0)),
            "speech audio on silence: {frames:?}"
        );
        assert_eq!(
            frames.last(),
            Some(&end),
            "graceful end is the end text message: {:?}",
            frames.last()
        );
    }

    #[tokio::test]
    async fn trailing_finals_arrive_until_the_server_confirms_the_end() {
        // The source ends quietly; the drain forwards the trailing
        // final, and the server's final notice closes the drain early.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 3).into_iter().map(MicEvent::Frame));

        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect<OutFrame>> =
            Arc::new(ScriptedConnect::<OutFrame>::new(vec![entry]));
        let provider = provider(connect, sends, false);
        let stream = provider.open_stream(&[]).await.expect("open");

        // Wait for the end message once the frames run out, then
        // answer with the final result and the all-done notice.
        sent_matching(&handles.observe, |f| !is_audio(f)).await;
        handles
            .feed
            .send(server(serde_json::json!({
                "code": 0, "result": { "slice_type": 2, "index": 0,
                                       "voice_text_str": "最后一句话" }
            })))
            .await
            .unwrap();
        handles
            .feed
            .send(server(serde_json::json!({ "code": 0, "final": 1 })))
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
    async fn server_errors_end_the_session_with_feedback() {
        let (entry, handles) = live_conn(None);
        let connect: Arc<ScriptedConnect<OutFrame>> =
            Arc::new(ScriptedConnect::<OutFrame>::new(vec![entry]));
        let provider = provider(connect, vec![], true);
        let stream = provider.open_stream(&[]).await.expect("open");

        handles
            .feed
            .send(server(serde_json::json!({
                "code": 4002, "message": "鉴权失败"
            })))
            .await
            .unwrap();
        let events = collect(stream).await;
        assert_eq!(
            events.last(),
            Some(&AsrEvent::Failed {
                message: "ASR 4002: 鉴权失败".into()
            })
        );
    }

    #[tokio::test]
    async fn a_lost_connection_reconnects_and_carries_on() {
        // Speech throughout; the first connection dies mid-stream.
        let mut sends: Vec<MicEvent> = zeros(4).into_iter().map(MicEvent::Frame).collect();
        sends.extend(tone(0.6, 12).into_iter().map(MicEvent::Frame));

        let (entry1, handles1) = live_conn(None);
        let (release_tx, release_rx) = tokio::sync::mpsc::channel(1);
        let (entry2, handles2) = live_conn(Some(release_rx));
        let connect: Arc<ScriptedConnect<OutFrame>> =
            Arc::new(ScriptedConnect::<OutFrame>::new(vec![entry1, entry2]));
        let provider = provider(connect, sends, true);
        let stream = provider.open_stream(&[]).await.expect("open");

        // Kill the first connection once speech is flowing.
        handles1
            .feed
            .send(Err("connection lost".into()))
            .await
            .unwrap();
        release_tx.send(()).await.unwrap();

        // The fresh connection carries on: the buffered speech is
        // flushed (audio arrives) and transcripts flow again.
        sent_matching(&handles2.observe, is_audio).await;
        handles2
            .feed
            .send(server(serde_json::json!({
                "code": 0, "result": { "slice_type": 2, "index": 0,
                                       "voice_text_str": "断线之后" }
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
        config.provider = AsrProviderKind::Tencent;
        config.tencent.secret_key = Some("signing only".into());
        let err = match TencentAsr::new(config, VadConfig::default()) {
            Err(err) => err.0,
            Ok(_) => panic!("an incomplete triple must not construct"),
        };
        assert!(err.contains("app_id"), "got: {err}");
        assert!(err.contains("secret_id"), "got: {err}");
    }

    #[tokio::test]
    async fn auth_failure_at_open_is_an_open_error() {
        let connect: Arc<ScriptedConnect<OutFrame>> =
            Arc::new(ScriptedConnect::<OutFrame>::new(vec![PlanEntry::Fail(
                ConnectError::Auth("handshake rejected: HTTP 401".into()),
            )]));
        let provider = provider(connect, vec![], true);
        let Err(err) = provider.open_stream(&[]).await else {
            panic!("expected open to fail");
        };
        assert!(err.0.contains("401"), "got: {}", err.0);
    }

    #[test]
    fn every_url_attempt_carries_fresh_signing_inputs() {
        // The dictionary rides the URL; the seed pins the rest.
        let seed = Arc::new(ConnectSeed {
            endpoint: "wss://asr.cloud.tencent.com/asr/v2/1250012548".into(),
            secret_id: "AKIDz".into(),
            secret_key: "signing".into(),
            engine_model_type: "16k_zh_en".into(),
        });
        let terms = Arc::new(vec!["SpokenRectifier".to_string()]);
        let build = url_builder(seed, terms);

        let first = build();
        let second = build();
        assert_ne!(first, second, "a reconnect must never reuse a URL");
        for url in [&first, &second] {
            assert!(url.starts_with("wss://asr.cloud.tencent.com/asr/v2/1250012548?"));
            assert!(url.contains("secretid=AKIDz"), "got: {url}");
            assert!(url.contains("engine_model_type=16k_zh_en"), "got: {url}");
            assert!(
                url.contains("hotword_list=SpokenRectifier%7C10"),
                "got: {url}"
            );
            assert!(url.contains("signature="), "got: {url}");
        }
    }
}
