//! Bridge API surface exposed to Dart via flutter_rust_bridge.
//!
//! All functions are synchronous and quick: commands block on the owned
//! runtime, the event stream forwards from a spawned task. The `Bridge*`
//! types are the wire format mirrored to Dart — deliberately decoupled
//! from the engine's own types so the engine can evolve without breaking
//! the Dart side.
//!
//! Two engine flavors: `create_engine` wires the real default microphone
//! with, when the `[asr]` config yields a key, the Aliyun realtime
//! adapter streaming real transcripts (otherwise the mic+VAD provider's
//! session semantics alone), the real rectify LLM when `[llm]` yields a
//! key (a scripted cycling demo LLM otherwise, but never under a real
//! ASR key — see `engine_factory`), the production inserter (clipboard
//! paste or typing at the remembered target window), and the SQLite
//! session history (per the `[history]` config), while
//! `create_fake_engine` keeps the all-fake setup (scripted speech via
//! `fake_say` / `fake_silence`, history disabled) for tests and headless
//! demos.

use std::sync::{Arc, Mutex, OnceLock};

use anyhow::anyhow;
use tokio::runtime::Runtime;

use crate::frb_generated::StreamSink;

use spokenrectifier_aliyun::{load_asr_config, AliyunAsr};
use spokenrectifier_audio::{MicVadAsr, VadConfig};
use spokenrectifier_engine::fakes::{
    AsrFeed, ChannelAsr, ChannelScripter, FakeClock, FakeInserter, LlmStep, ScriptedLlm,
};
use spokenrectifier_engine::AsrProvider;
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, RectifyLlm,
    SessionState, Style, TokioClock,
};
use spokenrectifier_history::HistoryStore;

use crate::engine_factory::{llm_choice, production_inserter, LlmChoice};

// -- wire types ---------------------------------------------------------------

/// Dart-side mirror of [`Command`].
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeCommand {
    StartSession,
    StopSession,
    Cancel,
    ConfirmInsert,
    Reroll,
    UpdatePreviewText {
        text: String,
    },
    SetStyle {
        style: BridgeStyle,
    },
    /// History retrieval re-running a past utterance (see `RectifyText`).
    RectifyText {
        raw_transcript: String,
    },
}

/// Dart-side mirror of [`Style`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeStyle {
    GeneralWritten,
    Prompt,
    FormalDocument,
}

/// Dart-side mirror of [`SessionState`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeSessionState {
    Idle,
    Recording,
    Rectifying,
    Preview,
    Inserted,
    Cancelled,
}

/// Dart-side mirror of [`EngineEvent`].
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeEvent {
    SessionStateChanged {
        from: BridgeSessionState,
        to: BridgeSessionState,
    },
    LiveTranscriptUpdated {
        text: String,
    },
    ParagraphMarked,
    SpeechActivityChanged {
        speaking: bool,
    },
    RectifiedTextChunk {
        delta: String,
    },
    PreviewTextUpdated {
        text: String,
    },
    TextInserted {
        text: String,
    },
    Error {
        message: String,
    },
}

/// Dart-side mirror of [`EventEnvelope`].
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeEventEnvelope {
    pub seq: u64,
    pub session_id: u64,
    pub at_ms: u64,
    pub event: BridgeEvent,
}

/// Dart-side mirror of the history store's row: one stored session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeHistoryEntry {
    pub id: i64,
    /// Unix-epoch milliseconds, for the panel's timestamps.
    pub created_at_ms: u64,
    pub raw_transcript: String,
    pub rectified_text: String,
}

impl From<spokenrectifier_history::HistoryEntry> for BridgeHistoryEntry {
    fn from(value: spokenrectifier_history::HistoryEntry) -> Self {
        BridgeHistoryEntry {
            id: value.id,
            created_at_ms: value.created_at_ms,
            raw_transcript: value.raw_transcript,
            rectified_text: value.rectified_text,
        }
    }
}

impl From<BridgeCommand> for Command {
    fn from(value: BridgeCommand) -> Self {
        match value {
            BridgeCommand::StartSession => Command::StartSession,
            BridgeCommand::StopSession => Command::StopSession,
            BridgeCommand::Cancel => Command::Cancel,
            BridgeCommand::ConfirmInsert => Command::ConfirmInsert,
            BridgeCommand::Reroll => Command::Reroll,
            BridgeCommand::UpdatePreviewText { text } => Command::UpdatePreviewText(text),
            BridgeCommand::SetStyle { style } => Command::SetStyle(style.into()),
            BridgeCommand::RectifyText { raw_transcript } => Command::RectifyText(raw_transcript),
        }
    }
}

impl From<BridgeStyle> for Style {
    fn from(value: BridgeStyle) -> Self {
        match value {
            BridgeStyle::GeneralWritten => Style::GeneralWritten,
            BridgeStyle::Prompt => Style::Prompt,
            BridgeStyle::FormalDocument => Style::FormalDocument,
        }
    }
}

impl From<Style> for BridgeStyle {
    fn from(value: Style) -> Self {
        match value {
            Style::GeneralWritten => BridgeStyle::GeneralWritten,
            Style::Prompt => BridgeStyle::Prompt,
            Style::FormalDocument => BridgeStyle::FormalDocument,
        }
    }
}

impl From<SessionState> for BridgeSessionState {
    fn from(value: SessionState) -> Self {
        match value {
            SessionState::Idle => BridgeSessionState::Idle,
            SessionState::Recording => BridgeSessionState::Recording,
            SessionState::Rectifying => BridgeSessionState::Rectifying,
            SessionState::Preview => BridgeSessionState::Preview,
            SessionState::Inserted => BridgeSessionState::Inserted,
            SessionState::Cancelled => BridgeSessionState::Cancelled,
        }
    }
}

impl From<EngineEvent> for BridgeEvent {
    fn from(value: EngineEvent) -> Self {
        match value {
            EngineEvent::SessionStateChanged { from, to } => BridgeEvent::SessionStateChanged {
                from: from.into(),
                to: to.into(),
            },
            EngineEvent::LiveTranscriptUpdated { text } => {
                BridgeEvent::LiveTranscriptUpdated { text }
            }
            EngineEvent::ParagraphMarked => BridgeEvent::ParagraphMarked,
            EngineEvent::SpeechActivityChanged { speaking } => {
                BridgeEvent::SpeechActivityChanged { speaking }
            }
            EngineEvent::RectifiedTextChunk { delta } => BridgeEvent::RectifiedTextChunk { delta },
            EngineEvent::PreviewTextUpdated { text } => BridgeEvent::PreviewTextUpdated { text },
            EngineEvent::TextInserted { text } => BridgeEvent::TextInserted { text },
            EngineEvent::Error { message } => BridgeEvent::Error { message },
        }
    }
}

impl From<EventEnvelope> for BridgeEventEnvelope {
    fn from(value: EventEnvelope) -> Self {
        BridgeEventEnvelope {
            seq: value.seq,
            session_id: value.session_id.0,
            at_ms: value.at_ms,
            event: value.event.into(),
        }
    }
}

// -- bridge state --------------------------------------------------------------

/// Where speech comes from for the current engine.
enum SpeechSource {
    /// Scripted speech through `fake_say` / `fake_silence`.
    Fake {
        scripter: ChannelScripter,
        feed: Mutex<Option<AsrFeed>>,
    },
    /// The real default microphone, through capture + VAD.
    Mic,
}

struct Global {
    rt: Runtime,
    engine: Engine,
    source: SpeechSource,
    inserter: InserterSlot,
    /// Session history: what the panel lists, what `RectifyText` re-runs,
    /// what the tray's clear empties. Disabled on the fake engine (tests
    /// and headless demos keep no files).
    history: Arc<HistoryStore>,
}

/// The real engine's inserter: the production one remembers the target
/// window (the fake engine's needs no target).
enum InserterSlot {
    /// Demo introspection: everything the fake inserter received.
    Fake(Arc<FakeInserter>),
    /// Real insertion at the remembered target window.
    Real(Arc<spokenrectifier_insertion::TargetInserter>),
}

static GLOBAL: OnceLock<Global> = OnceLock::new();

fn global() -> anyhow::Result<&'static Global> {
    GLOBAL.get().ok_or_else(|| {
        anyhow!("engine not created yet; call create_engine or create_fake_engine first")
    })
}

// -- api ------------------------------------------------------------------------

/// Chunk a text into scripted token deltas, mirroring how a real LLM
/// streams: a few characters at a time.
fn token_scripts(llm_responses: &[String]) -> Vec<Vec<LlmStep>> {
    llm_responses
        .iter()
        .map(|text| {
            let chars: Vec<char> = text.chars().collect();
            chars
                .chunks(4)
                .map(|chunk| LlmStep::Token(chunk.iter().collect()))
                .collect()
        })
        .collect()
}

/// Build the engine behind the bridge with the real default microphone
/// and, when the `[asr]` config yields an API key, the Aliyun realtime
/// adapter streaming real transcripts. Without a key the mic+VAD provider
/// keeps the session semantics (speech activity, silence, device
/// failure). The rectify LLM is the real OpenAI-compatible client when
/// `[llm]` yields a key; the scripted demo LLM otherwise — but that
/// combination is refused under a real ASR key (see `engine_factory`).
/// Insertion is the production inserter (clipboard paste with restore, or
/// typing per the `[insertion]` config). Session semantics load from the
/// `[engine]` section of the layered config files. Idempotent: a second
/// call is a no-op.
pub fn create_engine(llm_responses: Vec<String>) -> anyhow::Result<()> {
    if GLOBAL.get().is_some() {
        return Ok(());
    }
    // Resolved once: every section loader below reads the same layered
    // files from the same directories.
    let dirs = spokenrectifier_config::search_dirs();
    let config = engine_config(&dirs)?;
    let asr = asr_provider(&dirs)?;
    let llm: Arc<dyn RectifyLlm> = match llm_choice(&dirs)? {
        LlmChoice::Real(llm) => llm,
        LlmChoice::ScriptedDemo => ScriptedLlm::new_cycling(token_scripts(&llm_responses)),
    };
    let inserter = production_inserter(&dirs)?;
    // The same store the engine records into and the panel reads from.
    let history = crate::history::open_history(&dirs)?;
    let engine = Engine::new(
        config,
        EngineDeps {
            asr,
            llm,
            // The same instance the slot holds, so `note_target` on
            // StartSession arms the very inserter ConfirmInsert runs.
            inserter: inserter.clone(),
            history: Some(history.clone()),
            clock: Arc::new(TokioClock::new()),
        },
    );
    let _ = GLOBAL.set(Global {
        rt: Runtime::new()?,
        engine,
        source: SpeechSource::Mic,
        inserter: InserterSlot::Real(inserter),
        history,
    });
    Ok(())
}

/// The ASR provider for the real engine: the Aliyun realtime adapter when
/// the layered `[asr]` config resolves a key (an incomplete cloud config —
/// key but no endpoint — is an error, not a silent fallback), the mic+VAD
/// provider otherwise.
fn asr_provider(dirs: &[std::path::PathBuf]) -> anyhow::Result<std::sync::Arc<dyn AsrProvider>> {
    let config = load_asr_config(dirs).map_err(|err| anyhow::anyhow!("ASR {}", err.0))?;
    match config.resolve_key() {
        Some(_) => Ok(std::sync::Arc::new(
            AliyunAsr::new(config, VadConfig::default())
                .map_err(|err| anyhow::anyhow!("ASR {}", err.0))?,
        )),
        None => Ok(std::sync::Arc::new(MicVadAsr::new(VadConfig::default()))),
    }
}

/// Build the engine behind the bridge with all-fake collaborators.
/// `llm_responses` become the scripted rectify responses (streamed in small
/// chunks), repeating forever — the demo host never runs dry no matter how
/// many sessions or rerolls come. Idempotent: a second call is a no-op.
pub fn create_fake_engine(llm_responses: Vec<String>) -> anyhow::Result<()> {
    if GLOBAL.get().is_some() {
        return Ok(());
    }
    let (asr, scripter) = ChannelAsr::new();
    let llm = ScriptedLlm::new_cycling(token_scripts(&llm_responses));
    let inserter = FakeInserter::new();
    let engine = Engine::new(
        EngineConfig::default(),
        EngineDeps {
            asr,
            llm,
            inserter: inserter.clone(),
            history: None,
            clock: FakeClock::new(0),
        },
    );
    let _ = GLOBAL.set(Global {
        rt: Runtime::new()?,
        engine,
        source: SpeechSource::Fake {
            scripter,
            feed: Mutex::new(None),
        },
        inserter: InserterSlot::Fake(inserter),
        // The all-fake setup runs in tests and headless demos: no history
        // file appears next to the test binary.
        history: Arc::new(HistoryStore::default()),
    });
    Ok(())
}

/// Submit a command to the engine. Returns an error only for rejected
/// commands (wrong state); asynchronous outcomes arrive on the event stream.
pub fn execute(command: BridgeCommand) -> anyhow::Result<()> {
    let g = global()?;
    // Starting a session remembers the window the user was typing in, so
    // ConfirmInsert can bring it back before pasting (the preview window
    // takes the focus while its field is edited).
    if matches!(command, BridgeCommand::StartSession) {
        if let InserterSlot::Real(inserter) = &g.inserter {
            inserter.note_target();
        }
    }
    // Ending a session also ends its fake speech feed.
    if let SpeechSource::Fake { feed, .. } = &g.source {
        if matches!(command, BridgeCommand::StopSession | BridgeCommand::Cancel) {
            *feed.lock().unwrap() = None;
        }
    }
    g.rt.block_on(g.engine.execute(command.into()))?;
    Ok(())
}

/// Current session state, for initial paint before any event arrives.
pub fn state() -> anyhow::Result<BridgeSessionState> {
    Ok(global()?.engine.state().into())
}

/// Everything the fake inserter received, in order (demo introspection).
/// The production inserter does not record; insertion outcomes arrive on
/// the event stream instead (`TextInserted` / `Error`).
pub fn inserted_texts() -> anyhow::Result<Vec<String>> {
    match &global()?.inserter {
        InserterSlot::Fake(fake) => Ok(fake.inserted_texts()),
        InserterSlot::Real(_) => Err(anyhow!(
            "the production inserter does not record inserted texts"
        )),
    }
}

/// How many sessions the history panel lists per fetch.
const HISTORY_PANEL_LIMIT: usize = 200;

/// The most recent stored sessions, newest first — the history panel's
/// content. Empty in the keep-nothing mode (and on the fake engine).
pub fn history_list() -> anyhow::Result<Vec<BridgeHistoryEntry>> {
    Ok(global()?
        .history
        .list(HISTORY_PANEL_LIMIT)
        .into_iter()
        .map(BridgeHistoryEntry::from)
        .collect())
}

/// Remove every stored session — the tray's one-click clear. A no-op in
/// the keep-nothing mode.
pub fn history_clear() -> anyhow::Result<()> {
    global()?.history.clear();
    Ok(())
}

/// Subscribe the Dart side to the engine's event stream. Each call spawns
/// an independent forwarder; dropping the Dart stream stops it.
pub fn subscribe(sink: StreamSink<BridgeEventEnvelope>) -> anyhow::Result<()> {
    let g = global()?;
    let mut rx = g.engine.subscribe();
    g.rt.spawn(async move {
        loop {
            match rx.recv().await {
                Ok(envelope) => {
                    if sink.add(envelope.into()).is_err() {
                        break; // Dart side gone
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

/// Open the next fake ASR session and allow `fake_say` / `fake_silence` to
/// feed it. Call before `execute(BridgeCommand::StartSession)`.
pub fn fake_begin_session() -> anyhow::Result<()> {
    let g = global()?;
    let SpeechSource::Fake { scripter, feed } = &g.source else {
        return Err(anyhow!(
            "engine is in microphone mode; fake speech is unavailable"
        ));
    };
    *feed.lock().unwrap() = Some(scripter.begin_session());
    Ok(())
}

/// The open fake-session feed, shared by `fake_say` / `fake_silence`.
fn open_fake_feed(g: &Global) -> anyhow::Result<AsrFeed> {
    let SpeechSource::Fake { feed, .. } = &g.source else {
        return Err(anyhow!(
            "engine is in microphone mode; fake speech is unavailable"
        ));
    };
    feed.lock()
        .unwrap()
        .clone()
        .ok_or_else(|| anyhow!("no fake session open; call fake_begin_session first"))
}

/// Feed one scripted phrase (partial, then final) into the open session.
pub fn fake_say(text: String) -> anyhow::Result<()> {
    let g = global()?;
    let feed = open_fake_feed(g)?;
    g.rt.block_on(feed.say(&text));
    Ok(())
}

/// Feed one scripted cumulative-silence event (milliseconds) into the open
/// session.
pub fn fake_silence(elapsed_ms: u64) -> anyhow::Result<()> {
    let g = global()?;
    let feed = open_fake_feed(g)?;
    g.rt.block_on(feed.silence(elapsed_ms));
    Ok(())
}

// -- engine config ----------------------------------------------------------------

use crate::engine_config::engine_config;

#[cfg(test)]
mod tests {
    use super::*;

    /// The bridge is a process-wide singleton: serialize the tests.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    async fn wait_for<F>(
        rx: &mut tokio::sync::broadcast::Receiver<EventEnvelope>,
        predicate: F,
    ) -> EventEnvelope
    where
        F: Fn(&EngineEvent) -> bool,
    {
        loop {
            let envelope = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv())
                .await
                .expect("event within timeout")
                .expect("channel open");
            if predicate(&envelope.event) {
                return envelope;
            }
        }
    }

    async fn wait_state(
        rx: &mut tokio::sync::broadcast::Receiver<EventEnvelope>,
        want: SessionState,
    ) {
        wait_for(
            rx,
            |event| matches!(event, EngineEvent::SessionStateChanged { to, .. } if *to == want),
        )
        .await;
    }

    /// Wait on the bridge's own runtime: the tests run on plain threads so
    /// the bridge's `block_on` calls never nest inside another runtime.
    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        global().unwrap().rt.block_on(future)
    }

    fn setup() {
        // One shared engine for all tests: queue enough scripted LLM
        // responses for every session any test will run.
        create_fake_engine(vec!["修正后的书面文本".to_string(); 16]).unwrap();
    }

    #[test]
    fn full_flow_through_the_bridge_api() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        let mut rx = global().unwrap().engine.subscribe();

        fake_begin_session().unwrap();
        execute(BridgeCommand::StartSession).unwrap();
        fake_say("嗯那个原话".into()).unwrap();
        fake_silence(1300).unwrap();
        block_on(wait_for(
            &mut rx,
            |event| matches!(event, EngineEvent::LiveTranscriptUpdated { text } if text.contains("嗯那个原话")),
        ));

        execute(BridgeCommand::StopSession).unwrap();
        block_on(wait_state(&mut rx, SessionState::Preview));

        execute(BridgeCommand::ConfirmInsert).unwrap();
        block_on(wait_state(&mut rx, SessionState::Idle));

        // The inserter is shared across tests: assert the latest entry.
        assert_eq!(
            inserted_texts().unwrap().last(),
            Some(&"修正后的书面文本".to_string())
        );
        assert_eq!(state().unwrap(), BridgeSessionState::Idle);
    }

    #[test]
    fn commands_rejected_outside_the_bridge_report_errors() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        let err = execute(BridgeCommand::StopSession).unwrap_err().to_string();
        assert!(err.contains("rejected"), "got: {err}");
        assert_eq!(state().unwrap(), BridgeSessionState::Idle);
    }

    /// The demo host runs indefinitely: sessions keep working no matter how
    /// many rectify attempts came before. Past the scripted queue, a failed
    /// rectify surfaces as an Error event (never Preview), then Idle.
    #[test]
    fn repeated_sessions_never_run_dry() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        let mut rx = global().unwrap().engine.subscribe();

        // More sessions than the queued script count (setup queues 16).
        for session in 1..=20 {
            fake_begin_session().unwrap();
            execute(BridgeCommand::StartSession).unwrap();
            fake_say("第几场".into()).unwrap();
            fake_silence(1300).unwrap();
            block_on(wait_for(
                &mut rx,
                |event| matches!(event, EngineEvent::LiveTranscriptUpdated { text } if text.contains("第几场")),
            ));

            execute(BridgeCommand::StopSession).unwrap();
            let outcome = block_on(wait_for(&mut rx, |event| {
                matches!(
                    event,
                    EngineEvent::SessionStateChanged {
                        to: SessionState::Preview,
                        ..
                    } | EngineEvent::Error { .. }
                )
            }));
            if let EngineEvent::Error { message } = outcome.event {
                panic!("session {session} failed after stop: {message}");
            }

            execute(BridgeCommand::ConfirmInsert).unwrap();
            block_on(wait_state(&mut rx, SessionState::Idle));
        }
        assert_eq!(
            inserted_texts().unwrap().last(),
            Some(&"修正后的书面文本".to_string())
        );
    }

    #[test]
    fn fake_say_without_a_session_is_an_error() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        assert!(fake_say("没人听".into()).is_err());
    }

    #[test]
    fn create_is_idempotent() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        create_fake_engine(vec!["第二次".into()]).unwrap();
        // The first engine's queue is still in effect.
        let mut rx = global().unwrap().engine.subscribe();
        fake_begin_session().unwrap();
        execute(BridgeCommand::StartSession).unwrap();
        fake_say("话".into()).unwrap();
        block_on(wait_for(
            &mut rx,
            |event| matches!(event, EngineEvent::LiveTranscriptUpdated { text } if text == "话"),
        ));
        execute(BridgeCommand::StopSession).unwrap();
        block_on(wait_state(&mut rx, SessionState::Preview));
        execute(BridgeCommand::ConfirmInsert).unwrap();
        block_on(wait_state(&mut rx, SessionState::Idle));
        assert_eq!(
            inserted_texts().unwrap().last(),
            Some(&"修正后的书面文本".to_string())
        );
    }

    /// History retrieval re-runs an utterance without a microphone: the
    /// command goes through the wire, the machine runs to preview, and
    /// the insert lands like any session's.
    #[test]
    fn rectify_text_through_the_bridge() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        let mut rx = global().unwrap().engine.subscribe();

        execute(BridgeCommand::RectifyText {
            raw_transcript: "历史上的原话".into(),
        })
        .unwrap();
        block_on(wait_state(&mut rx, SessionState::Preview));
        execute(BridgeCommand::ConfirmInsert).unwrap();
        block_on(wait_state(&mut rx, SessionState::Idle));
        assert_eq!(
            inserted_texts().unwrap().last(),
            Some(&"修正后的书面文本".to_string())
        );
    }

    /// The fake engine keeps no history file: the panel reads an empty
    /// list and clear is a no-op, never an error.
    #[test]
    fn the_fake_engine_keeps_no_history() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        assert!(history_list().unwrap().is_empty());
        history_clear().unwrap();
        assert!(history_list().unwrap().is_empty());
    }

    #[test]
    fn wire_types_mirror_every_engine_variant() {
        // One representative of each engine event maps onto the wire.
        let cases = vec![
            EngineEvent::SessionStateChanged {
                from: SessionState::Idle,
                to: SessionState::Recording,
            },
            EngineEvent::LiveTranscriptUpdated {
                text: "你好".into(),
            },
            EngineEvent::ParagraphMarked,
            EngineEvent::SpeechActivityChanged { speaking: true },
            EngineEvent::RectifiedTextChunk {
                delta: "好".into()
            },
            EngineEvent::PreviewTextUpdated {
                text: "好的".into(),
            },
            EngineEvent::TextInserted {
                text: "好的".into(),
            },
            EngineEvent::Error {
                message: "挂了".into(),
            },
        ];
        for event in cases {
            // Every variant maps without panicking; names stay 1:1.
            let _bridge: BridgeEvent = event.into();
        }
        // Spot-check the two variants whose payloads can drift silently.
        let mapped: BridgeEvent = EngineEvent::SessionStateChanged {
            from: SessionState::Recording,
            to: SessionState::Rectifying,
        }
        .into();
        assert_eq!(
            mapped,
            BridgeEvent::SessionStateChanged {
                from: BridgeSessionState::Recording,
                to: BridgeSessionState::Rectifying,
            }
        );
        let mapped: BridgeEvent = EngineEvent::RectifiedTextChunk {
            delta: "字".into()
        }
        .into();
        assert_eq!(
            mapped,
            BridgeEvent::RectifiedTextChunk {
                delta: "字".into()
            }
        );
        let envelope = EventEnvelope {
            seq: 7,
            session_id: spokenrectifier_engine::SessionId(3),
            at_ms: 1_000,
            event: EngineEvent::ParagraphMarked,
        };
        let bridge: BridgeEventEnvelope = envelope.into();
        assert_eq!(bridge.seq, 7);
        assert_eq!(bridge.session_id, 3);
        assert_eq!(bridge.at_ms, 1_000);
        assert_eq!(bridge.event, BridgeEvent::ParagraphMarked);
    }
}
