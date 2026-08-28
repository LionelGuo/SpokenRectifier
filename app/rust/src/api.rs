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
    SessionState, TokioClock,
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
    /// The selected scenario's style-directive text; `None` returns to
    /// the built-in default register. The engine knows nothing about
    /// scenario names.
    SetStyleDirective {
        directive: Option<String>,
    },
    /// Passage mode (篇章模式) as it stands now — the value the next
    /// session opens with (the engine snapshots it per session).
    SetPassageMode {
        on: bool,
    },
    /// History retrieval re-running a past utterance (see `RectifyText`).
    RectifyText {
        raw_transcript: String,
    },
}

/// Dart-side mirror of one scenario (场景): a user-named style directive
/// from the scenario library.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeScenario {
    pub name: String,
    pub directive: String,
}

impl From<spokenrectifier_config::scenarios::Scenario> for BridgeScenario {
    fn from(value: spokenrectifier_config::scenarios::Scenario) -> Self {
        BridgeScenario {
            name: value.name,
            directive: value.directive,
        }
    }
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
            BridgeCommand::SetStyleDirective { directive } => Command::SetStyleDirective(directive),
            BridgeCommand::SetPassageMode { on } => Command::SetPassageMode(on),
            BridgeCommand::RectifyText { raw_transcript } => Command::RectifyText(raw_transcript),
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
    // The dictionary re-read per session: Aliyun recognition gets it as
    // the transcription corpus, the rectify prompt as the term reference.
    let terms = crate::terms::FileTermSource::new(dirs);
    let engine = Engine::new(
        config,
        EngineDeps {
            asr,
            llm,
            // The same instance the slot holds, so `note_target` on
            // StartSession arms the very inserter ConfirmInsert runs.
            inserter: inserter.clone(),
            history: Some(history.clone()),
            terms: Some(terms),
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
    // The real engine owns the keyboard-wide Esc semantics: while a
    // session is active, a bare Esc cancels it even when the session
    // window lost (or never won) the foreground. The hook hands the
    // cancel to the runtime and returns; it never blocks the hook thread.
    crate::esc_guard::install(std::sync::Arc::new(|| {
        if let Some(g) = GLOBAL.get() {
            let engine = g.engine.clone();
            g.rt.spawn(async move {
                let _ = engine.execute(Command::Cancel).await;
            });
        }
    }));
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
            // The all-fake setup keeps no files either: no dictionary is
            // read from whatever directory the test binary runs in.
            terms: None,
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
        // Arm eagerly: the global Esc guard must be live before the state
        // change event round-trips (the forwarder below corrects drift).
        crate::esc_guard::set_armed(true);
    }
    // Ending a session also ends its fake speech feed.
    if let SpeechSource::Fake { feed, .. } = &g.source {
        if matches!(command, BridgeCommand::StopSession | BridgeCommand::Cancel) {
            *feed.lock().unwrap() = None;
        }
    }
    let outcome = g.rt.block_on(g.engine.execute(command.clone().into()));
    if matches!(command, BridgeCommand::StartSession) && outcome.is_err() {
        // The session never opened (e.g. the microphone is busy): no state
        // change will fire, so the eager arm above must be taken back —
        // an armed guard at idle would eat a stranger's Esc.
        crate::esc_guard::set_armed(false);
        // The orb click that tried to start it still took the foreground;
        // hand it straight back so the user keeps typing where they were.
        if let InserterSlot::Real(inserter) = &g.inserter {
            inserter.restore_focus();
        }
    }
    outcome?;
    Ok(())
}

/// Current session state, for initial paint before any event arrives.
pub fn state() -> anyhow::Result<BridgeSessionState> {
    Ok(global()?.engine.state().into())
}

/// Passage mode as it stands now (config-seeded, runtime-switched) —
/// what the quick panel's toggle paints and what the next session opens
/// with.
pub fn passage_mode() -> anyhow::Result<bool> {
    Ok(global()?.engine.passage_mode())
}

/// Hand the keyboard back to the remembered target window — the quick
/// panel's own close path. Self-guarded on the inserter side: a foreign
/// foreground (or no remembered target) is left alone, exactly like the
/// cancel-path restore. No-op on the fake engine.
pub fn restore_focus() -> anyhow::Result<()> {
    if let InserterSlot::Real(inserter) = &global()?.inserter {
        inserter.restore_focus();
    }
    Ok(())
}

/// The hotword dictionary as it stands now, in file order — the quick
/// panel's term chips. File-level, engine-independent (the engine
/// re-reads the file when the next session opens, which is what makes a
/// quick-added term live for that session).
pub fn terms_list() -> anyhow::Result<Vec<String>> {
    Ok(spokenrectifier_config::terms::load_terms(
        &spokenrectifier_config::search_dirs(),
    ))
}

/// Quick-add one term to the dictionary (idempotent; blank rejected).
/// See [`spokenrectifier_config::terms::append_term`] for the placement
/// and repair rules.
pub fn append_term(term: String) -> anyhow::Result<()> {
    spokenrectifier_config::terms::append_term(&spokenrectifier_config::search_dirs(), &term)
        .map_err(|err| anyhow!("cannot add the term: {err}"))
}

/// Remove a term from the dictionary (a no-op when absent).
pub fn remove_term(term: String) -> anyhow::Result<()> {
    spokenrectifier_config::terms::remove_term(&spokenrectifier_config::search_dirs(), &term)
        .map_err(|err| anyhow!("cannot remove the term: {err}"))
}

/// The scenario library (场景库): user-named style directives from the
/// app-owned `spokenrectifier-scenarios.toml`. A missing or corrupt file
/// reads as an empty library — this never errors and never writes. The
/// shell paints its pickers from the list and resolves the selected
/// entry's directive text itself (selection lives app-side, never
/// persisted; ADR-0004).
pub fn scenarios() -> anyhow::Result<Vec<BridgeScenario>> {
    let dirs = spokenrectifier_config::search_dirs();
    Ok(spokenrectifier_config::scenarios::load_scenarios(&dirs)
        .into_iter()
        .map(BridgeScenario::from)
        .collect())
}

/// Save the whole scenario library — the settings editor's model,
/// wholesale — into the file the loader resolves (created in the app's
/// settings home when no library exists yet). File-level and
/// engine-independent like [`scenarios`]: the pickers re-read the library
/// after a save; the selected scenario's directive rides the next
/// `SetStyleDirective` as usual. Only ever runs on a user action (the
/// editor's add/edit/delete), never on load.
pub fn save_scenarios(scenarios: Vec<BridgeScenario>) -> anyhow::Result<()> {
    let dirs = spokenrectifier_config::search_dirs();
    let library: Vec<spokenrectifier_config::scenarios::Scenario> = scenarios
        .into_iter()
        .map(|scenario| spokenrectifier_config::scenarios::Scenario {
            name: scenario.name,
            directive: scenario.directive,
        })
        .collect();
    spokenrectifier_config::scenarios::save_scenarios(&dirs, &library)
        .map_err(|err| anyhow!("cannot save the scenario library: {err}"))
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

/// Dart-side mirror of the `[history]` settings (保留期 / 不留存).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BridgeHistoryConfig {
    pub enabled: bool,
    pub retention_days: u64,
}

impl From<spokenrectifier_history::HistoryConfig> for BridgeHistoryConfig {
    fn from(value: spokenrectifier_history::HistoryConfig) -> Self {
        BridgeHistoryConfig {
            enabled: value.enabled,
            retention_days: value.retention_days,
        }
    }
}

/// The `[history]` config errors share one shape across the pair.
fn history_config_err(err: spokenrectifier_history::HistoryConfigError) -> anyhow::Error {
    anyhow!("history {}", err.0)
}

/// The effective `[history]` settings from the layer files — the
/// settings window's history pane initial paint.
pub fn history_config() -> anyhow::Result<BridgeHistoryConfig> {
    let dirs = spokenrectifier_config::search_dirs();
    spokenrectifier_history::load_history_config(&dirs)
        .map(BridgeHistoryConfig::from)
        .map_err(history_config_err)
}

/// Write new `[history]` settings and apply them to the live store at
/// once (the settings window's 保留期 / 不留存 controls): the file edit
/// is section-preserving in the layer that owns the effective values,
/// and the store adopts the new config immediately — a tightened
/// retention sweeps at once, keep-nothing wipes, and turning it back on
/// resumes recording. Returns the re-read effective config.
pub fn set_history_config(
    enabled: bool,
    retention_days: u64,
) -> anyhow::Result<BridgeHistoryConfig> {
    let dirs = spokenrectifier_config::search_dirs();
    let config = spokenrectifier_history::HistoryConfig {
        enabled,
        retention_days,
    };
    spokenrectifier_history::save_history_config(&dirs, &config).map_err(history_config_err)?;
    global()?
        .history
        .apply_config(config)
        .map_err(|err| anyhow!("history {}", err.0))?;
    history_config()
}

// -- the connection domain (模型与连接, ticket 19) -----------------------------

/// Dart-side mirror of a secret's placement — never the secret itself
/// (the GUI paints this status; the stored key never leaves the file).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeKeyStatus {
    Unset,
    InLocalFile,
    FromEnv(String),
}

impl From<spokenrectifier_config::section_write::KeyStatus> for BridgeKeyStatus {
    fn from(value: spokenrectifier_config::section_write::KeyStatus) -> Self {
        use spokenrectifier_config::section_write::KeyStatus;
        match value {
            KeyStatus::Unset => BridgeKeyStatus::Unset,
            KeyStatus::InLocalFile => BridgeKeyStatus::InLocalFile,
            KeyStatus::FromEnv(name) => BridgeKeyStatus::FromEnv(name),
        }
    }
}

/// Dart-side mirror of what a connection save does to the api_key: the
/// stored key is never echoed back, so "keep" is a first-class action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeKeyEdit {
    Keep,
    Clear,
    Set(String),
}

impl From<BridgeKeyEdit> for spokenrectifier_config::section_write::KeyEdit {
    fn from(value: BridgeKeyEdit) -> Self {
        use spokenrectifier_config::section_write::KeyEdit;
        match value {
            BridgeKeyEdit::Keep => KeyEdit::Keep,
            BridgeKeyEdit::Clear => KeyEdit::Clear,
            BridgeKeyEdit::Set(key) => KeyEdit::Set(key),
        }
    }
}

/// The effective `[asr]` connection as the settings pane paints it: the
/// folded fields, the resolved endpoint (a read-only preview), and the
/// key's placement.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeAsrConnection {
    pub model: String,
    pub language: String,
    pub workspace_id: Option<String>,
    pub region: String,
    pub base_url: Option<String>,
    /// The WebSocket URL the current fields resolve to.
    pub endpoint: String,
    pub key: BridgeKeyStatus,
}

/// The effective `[llm]` connection as the settings pane paints it.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeLlmConnection {
    pub vendor: String,
    pub base_url: String,
    pub model: String,
    pub key: BridgeKeyStatus,
}

fn asr_view(config: spokenrectifier_aliyun::AsrConfig) -> BridgeAsrConnection {
    BridgeAsrConnection {
        endpoint: config.endpoint(),
        key: config.key_status().into(),
        model: config.model,
        language: config.language,
        workspace_id: config.workspace_id,
        region: config.region,
        base_url: config.base_url,
    }
}

fn llm_view(config: spokenrectifier_llm::LlmConfig) -> BridgeLlmConnection {
    let key = config.model.key_status().into();
    BridgeLlmConnection {
        vendor: config.model.vendor.as_str().to_string(),
        base_url: config.model.base_url,
        model: config.model.model,
        key,
    }
}

/// The effective `[asr]` and `[llm]` connections from the layer files —
/// the connection domain's initial paint. File-level, engine-
/// independent: the engine adopts the config at its creation, so a
/// change written here applies from the next launch on (the pane says
/// so; the fidelity-eval run is the one place that adopts it at once,
/// building its own engine per run).
pub fn connection_config() -> anyhow::Result<BridgeConnection> {
    let dirs = spokenrectifier_config::search_dirs();
    let asr = load_asr_config(&dirs).map_err(|err| anyhow!("ASR {}", err.0))?;
    let llm =
        spokenrectifier_llm::load_llm_config(&dirs).map_err(|err| anyhow!("LLM {}", err.0))?;
    Ok(BridgeConnection {
        asr: asr_view(asr),
        llm: llm_view(llm),
    })
}

/// Both connections in one read.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeConnection {
    pub asr: BridgeAsrConnection,
    pub llm: BridgeLlmConnection,
}

/// Write the editor's `[asr]` model back into the layer files (see
/// `save_asr_connection` for the placement and preservation rules) and
/// return the re-read view — the file's truth, not the ask.
pub fn set_asr_connection(
    model: String,
    language: String,
    workspace_id: Option<String>,
    region: String,
    base_url: Option<String>,
    api_key: BridgeKeyEdit,
) -> anyhow::Result<BridgeAsrConnection> {
    let dirs = spokenrectifier_config::search_dirs();
    spokenrectifier_aliyun::save_asr_connection(
        &dirs,
        &spokenrectifier_aliyun::AsrConnectionEdit {
            model,
            language,
            workspace_id,
            region,
            base_url,
            api_key: api_key.into(),
        },
    )
    .map_err(|err| anyhow!("ASR {}", err.0))?;
    let config = load_asr_config(&dirs).map_err(|err| anyhow!("ASR {}", err.0))?;
    Ok(asr_view(config))
}

/// Write the editor's `[llm]` model back into the layer files (see
/// `save_llm_connection`) and return the re-read view.
pub fn set_llm_connection(
    vendor: String,
    base_url: String,
    model: String,
    api_key: BridgeKeyEdit,
) -> anyhow::Result<BridgeLlmConnection> {
    let dirs = spokenrectifier_config::search_dirs();
    let vendor = spokenrectifier_llm::Vendor::from_str_name(&vendor).ok_or_else(|| {
        anyhow!("[llm] vendor \"{vendor}\" is unknown: pick one of the known endpoints")
    })?;
    spokenrectifier_llm::save_llm_connection(
        &dirs,
        &spokenrectifier_llm::LlmConnectionEdit {
            vendor,
            base_url,
            model,
            api_key: api_key.into(),
        },
    )
    .map_err(|err| anyhow!("LLM {}", err.0))?;
    let config =
        spokenrectifier_llm::load_llm_config(&dirs).map_err(|err| anyhow!("LLM {}", err.0))?;
    Ok(llm_view(config))
}

// -- the terms domain (术语, ticket 19) ----------------------------------------

/// Rename a term in the dictionary, in place (the settings editor's 改;
/// the quick panel's quick-add and quick-remove stay the same calls).
/// See [`spokenrectifier_config::terms::update_term`] for the placement
/// and collision rules.
pub fn update_term(old: String, new: String) -> anyhow::Result<()> {
    spokenrectifier_config::terms::update_term(&spokenrectifier_config::search_dirs(), &old, &new)
        .map_err(|err| anyhow!("cannot rename the term: {err}"))
}

// -- the advanced domain (高级, ticket 19) -------------------------------------

/// The effective `[engine]` timings as the advanced pane paints them
/// (read-only; see ADR-0007 for why they stay file-only).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BridgeEngineTiming {
    pub passage_mode: bool,
    pub paragraph_silence_ms: u64,
    pub session_end_silence_ms: u64,
    pub rectify_timeout_ms: u64,
}

/// The effective `[insertion]` timings as the advanced pane paints them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeInsertionTiming {
    /// `paste` or `typing`.
    pub mode: String,
    pub focus_settle_ms: u64,
    pub paste_settle_ms: u64,
    pub typing_delay_ms: u64,
}

/// The advanced domain's one read: the session and insertion latency
/// parameters, effective right now. Read-only by decision (ADR-0007):
/// they are engine-construction-time values, so a GUI form over them
/// would promise the hot-reload nothing delivers — the config file is
/// the escape hatch, and the pane links to it.
pub fn advanced_config() -> anyhow::Result<BridgeAdvancedConfig> {
    let dirs = spokenrectifier_config::search_dirs();
    let engine = engine_config(&dirs)?;
    let insertion = spokenrectifier_insertion::load_insertion_config(&dirs)
        .map_err(|err| anyhow!("insertion {}", err.0))?;
    Ok(BridgeAdvancedConfig {
        engine: BridgeEngineTiming {
            passage_mode: engine.passage_mode,
            paragraph_silence_ms: engine.paragraph_silence_ms,
            session_end_silence_ms: engine.session_end_silence_ms,
            rectify_timeout_ms: engine.rectify_timeout_ms,
        },
        insertion: BridgeInsertionTiming {
            mode: match insertion.mode {
                spokenrectifier_insertion::InsertionMode::Paste => "paste".to_string(),
                spokenrectifier_insertion::InsertionMode::Typing => "typing".to_string(),
            },
            focus_settle_ms: insertion.focus_settle_ms,
            paste_settle_ms: insertion.paste_settle_ms,
            typing_delay_ms: insertion.typing_delay_ms,
        },
    })
}

/// Both timing cards in one read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAdvancedConfig {
    pub engine: BridgeEngineTiming,
    pub insertion: BridgeInsertionTiming,
}

// -- the about domain (关于, ticket 19) ----------------------------------------

/// What the about pane paints. The version is the app crate's manifest
/// (kept in step with the Flutter `pubspec.yaml` — bump both together).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAbout {
    pub version: String,
    pub license: String,
    /// The public repository; absent until the open-source packaging
    /// (ticket 11) names one.
    pub repo_url: Option<String>,
}

/// The about pane's one read (version, license, repository).
pub fn about() -> BridgeAbout {
    BridgeAbout {
        version: env!("CARGO_PKG_VERSION").to_string(),
        license: "Apache-2.0".to_string(),
        repo_url: None,
    }
}

// -- the fidelity eval (保真评测, ticket 18) -----------------------------------

/// Live progress from one fidelity-eval run: per-case start/finish, and
/// the terminal `Finished` (summary) or `Failed` (setup error or abort).
#[derive(Debug, Clone)]
pub enum BridgeEvalEvent {
    /// The suite loaded and the first case is about to run.
    Started {
        total: u32,
    },
    CaseStarted {
        index: u32,
        total: u32,
        id: String,
    },
    CaseFinished {
        index: u32,
        id: String,
        passed: bool,
    },
    /// The run completed; the summary carries everything the pane paints.
    Finished {
        summary: BridgeEvalSummary,
    },
    /// The run never completed (missing LLM config, an aborted run, an
    /// engine-level failure).
    Failed {
        message: String,
    },
}

/// What a finished run reports: the pass rate against the recorded
/// baseline, failure counts per category, and the failed cases with
/// their machine-verdict details.
#[derive(Debug, Clone)]
pub struct BridgeEvalSummary {
    pub total: u32,
    pub passed: u32,
    pub failed: u32,
    /// Cases that never produced output to check (engine/LLM errors) —
    /// already inside `failed`, broken out for display.
    pub exec_failed: u32,
    /// Passed share, 0.0–100.0.
    pub rate_percent: f64,
    /// The recorded baseline (BASELINE.md beside the suite) the run
    /// compares against.
    pub baseline_percent: f64,
    /// Which LLM actually ran the cases.
    pub model: String,
    /// Failure counts per category, display order (Chinese labels).
    pub categories: Vec<BridgeEvalCategory>,
    /// The failed cases only, with assertion details.
    pub failed_cases: Vec<BridgeEvalCaseDetail>,
}

/// One category line in the summary (label + count).
#[derive(Debug, Clone)]
pub struct BridgeEvalCategory {
    pub label: String,
    pub count: u32,
}

/// One failed case: the engine-level error when the case never produced
/// output, else the assertion verdicts that failed.
#[derive(Debug, Clone)]
pub struct BridgeEvalCaseDetail {
    pub id: String,
    pub error: Option<String>,
    pub failures: Vec<String>,
}

/// Start one fidelity-eval run in the background — the settings window's
/// manual entry. Every case rides the event stream; the run ends with
/// `Finished` or `Failed`. Dropping the Dart listener (window closed,
/// pane cancelled) aborts the run at the next case boundary. Only one
/// run at a time: a second call while running is an error.
///
/// The run builds its own engine instance (noop inserter, no history
/// recorder, the suite's fixed term list) against the real configured
/// LLM — the app's live engine is never touched, so the eval neither
/// inserts text nor pollutes history (the sr-eval seam, in-process).
pub fn start_fidelity_eval(sink: StreamSink<BridgeEvalEvent>) -> anyhow::Result<()> {
    crate::eval_runner::start(sink)
}

/// Open the shared config file in the system text editor — the tray's
/// settings entry. Creates a commented stub first when no config file
/// exists yet (see `settings::ensure_shared_config` for where). Returns
/// the path that was opened.
pub fn open_config_file() -> anyhow::Result<String> {
    let dirs = spokenrectifier_config::search_dirs();
    let path = crate::settings::ensure_shared_config(&dirs)
        .map_err(|err| anyhow!("cannot create the config file: {err}"))?;
    launch_editor(&path)?;
    Ok(path.display().to_string())
}

/// Hand the file to the platform's editor: Notepad ships with every
/// Windows, `xdg-open` covers the development desktops.
fn launch_editor(path: &std::path::Path) -> anyhow::Result<()> {
    #[cfg(windows)]
    let mut command = std::process::Command::new("notepad");
    #[cfg(not(windows))]
    let mut command = std::process::Command::new("xdg-open");
    command
        .arg(path)
        .spawn()
        .map_err(|err| anyhow!("cannot open an editor for {}: {err}", path.display()))?;
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
                    // Authoritative arming for the global Esc guard: the
                    // active phases keep it live, everything else disarms
                    // (an idle Esc belongs to whatever app holds the
                    // keyboard, e.g. closing the quick panel is ours).
                    if let EngineEvent::SessionStateChanged { to, .. } = &envelope.event {
                        crate::esc_guard::set_armed(matches!(
                            to,
                            SessionState::Recording
                                | SessionState::Rectifying
                                | SessionState::Preview
                        ));
                    }
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

    /// A style directive rides the wire any time (no state machine role):
    /// the engine accepts it and the default-register reset alike.
    #[test]
    fn style_directive_commands_are_valid_any_time() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        execute(BridgeCommand::SetStyleDirective {
            directive: Some("以 Markdown 分条输出".into()),
        })
        .unwrap();
        execute(BridgeCommand::SetStyleDirective { directive: None }).unwrap();
    }

    /// The passage-mode switch rides the wire any time and reads back
    /// through the panel's getter (config default: on).
    #[test]
    fn passage_mode_round_trips_the_wire() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        assert!(passage_mode().unwrap());
        execute(BridgeCommand::SetPassageMode { on: false }).unwrap();
        assert!(!passage_mode().unwrap());
        execute(BridgeCommand::SetPassageMode { on: true }).unwrap();
        assert!(passage_mode().unwrap());
    }

    /// The quick panel's close-restore is a quiet no-op on the fake
    /// engine (tests and demos hold no target window).
    #[test]
    fn restore_focus_is_a_noop_on_the_fake_engine() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        restore_focus().unwrap();
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
