//! Bridge API surface exposed to Dart via flutter_rust_bridge.
//!
//! All functions are synchronous and quick: commands block on the owned
//! runtime, the event stream forwards from a spawned task. The `Bridge*`
//! types are the wire format mirrored to Dart — deliberately decoupled
//! from the engine's own types so the engine can evolve without breaking
//! the Dart side.
//!
//! Two engine flavors: `create_engine` wires the real default microphone
//! with, when the `[asr]` config carries credentials, the configured
//! provider's cloud adapter streaming real transcripts — Aliyun or
//! Volcengine per `[asr]` provider (ADR-0009; otherwise the mic+VAD
//! provider's session semantics alone) — the real rectify LLM when
//! `[llm]` yields a key (a scripted cycling demo LLM otherwise, but
//! never under real ASR credentials — see `engine_factory`), the
//! production inserter (clipboard paste or typing at the remembered
//! target window), and the SQLite session history (per the `[history]`
//! config), while `create_fake_engine` keeps the all-fake setup
//! (scripted speech via `fake_say` / `fake_silence`, history disabled)
//! for tests and headless demos.

use std::sync::{Arc, Mutex, OnceLock};

use anyhow::anyhow;
use tokio::runtime::Runtime;

use crate::frb_generated::StreamSink;

use spokenrectifier_asr::schema::{
    AliyunConfig, AliyunEdit, AsrConfig, AsrConnectionEdit, AsrProviderKind, AzureEdit,
    TencentConfig, TencentEdit, VolcengineEdit, load_asr_config, save_asr_connection,
};
use spokenrectifier_engine::fakes::{
    AsrFeed, ChannelAsr, ChannelScripter, FakeClock, FakeInserter, LlmStep, ScriptedLlm,
};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, RectifyLlm,
    SessionState, SessionStyle, TokioClock,
};
use spokenrectifier_history::HistoryStore;

use crate::engine_factory::{LlmChoice, llm_choice, production_inserter};

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
    /// The global directive's text (ticket 22; the engine knows nothing
    /// about where it is stored); `None` unsets it. A live value read at
    /// every request assembly, never pinned per session.
    SetGlobalDirective {
        directive: Option<String>,
    },
    /// Passage mode (篇章模式) as it stands now — the value the next
    /// session opens with (the engine snapshots it per session).
    SetPassageMode {
        on: bool,
    },
    /// The latency timings as they stand now — the values the next
    /// session opens with (the engine snapshots them per session). The
    /// settings window's advanced form sends this right after the file
    /// write, so the live engine adopts the saved values at once.
    SetEngineTimings {
        paragraph_silence_ms: u64,
        session_end_silence_ms: u64,
        rectify_timeout_ms: u64,
    },
    /// Pin a placeholder (钉入) at the current end of the spoken segment
    /// — the Alt+B press while listening. Only valid while recording
    /// (rejected otherwise); the sentinel `‡N‡` appears in the live
    /// transcript at once via the usual `LiveTranscriptUpdated`.
    PinPlaceholder,
    /// History retrieval re-running a past utterance (see `RectifyText`).
    /// `style` pins the session's one-time style pick (ticket 23's named
    /// scenarios, ticket 28's 默认); `Live` runs under the live selection.
    RectifyText {
        raw_transcript: String,
        style: BridgeSessionStyle,
    },
}

/// Dart-side mirror of [`SessionStyle`]: how a re-rectify session picks
/// its style — follow the live selection, pin a scenario's directive
/// text, or pin the built-in default register (指定场景重新修正's 默认
/// item, ticket 28).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeSessionStyle {
    Live,
    Directive { text: String },
    DefaultRegister,
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
    /// The recording session was upgraded to quick mode (ADR-0020): the
    /// held chord crossed the threshold with nothing pinned. The session
    /// window hangs the 聆听中 phase word and the pin-hotkey disarm off
    /// it.
    QuickMarked,
    SpeechActivityChanged {
        speaking: bool,
    },
    RectifiedTextChunk {
        delta: String,
    },
    /// The pin session's prefill table (ticket 18), arriving between
    /// the last chunk and the Preview state change.
    PreviewPrefills {
        prefills: Vec<BridgePrefillRow>,
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

/// Dart-side mirror of one prefill-table row (【预填】 block row,
/// ticket 18): the slot's number and the model's initial value for it,
/// exactly as written — the shell's body-scan extraction decides which
/// identities exist and looks the rest up empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgePrefillRow {
    pub number: u32,
    pub value: String,
}

impl From<spokenrectifier_engine::prefill::PrefillRow> for BridgePrefillRow {
    fn from(value: spokenrectifier_engine::prefill::PrefillRow) -> Self {
        BridgePrefillRow {
            number: value.number,
            value: value.value,
        }
    }
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
            BridgeCommand::PinPlaceholder => Command::PinPlaceholder,
            BridgeCommand::Cancel => Command::Cancel,
            BridgeCommand::ConfirmInsert => Command::ConfirmInsert,
            BridgeCommand::Reroll => Command::Reroll,
            BridgeCommand::UpdatePreviewText { text } => Command::UpdatePreviewText(text),
            BridgeCommand::SetStyleDirective { directive } => Command::SetStyleDirective(directive),
            BridgeCommand::SetGlobalDirective { directive } => {
                Command::SetGlobalDirective(directive)
            }
            BridgeCommand::SetPassageMode { on } => Command::SetPassageMode(on),
            BridgeCommand::SetEngineTimings {
                paragraph_silence_ms,
                session_end_silence_ms,
                rectify_timeout_ms,
            } => Command::SetEngineTimings(spokenrectifier_engine::EngineTimings {
                paragraph_silence_ms,
                session_end_silence_ms,
                rectify_timeout_ms,
            }),
            BridgeCommand::RectifyText {
                raw_transcript,
                style,
            } => Command::RectifyText {
                raw_transcript,
                style: style.into(),
            },
        }
    }
}

impl From<BridgeSessionStyle> for SessionStyle {
    fn from(value: BridgeSessionStyle) -> Self {
        match value {
            BridgeSessionStyle::Live => SessionStyle::Live,
            BridgeSessionStyle::Directive { text } => SessionStyle::Directive(text),
            BridgeSessionStyle::DefaultRegister => SessionStyle::DefaultRegister,
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
            EngineEvent::QuickMarked => BridgeEvent::QuickMarked,
            EngineEvent::SpeechActivityChanged { speaking } => {
                BridgeEvent::SpeechActivityChanged { speaking }
            }
            EngineEvent::RectifiedTextChunk { delta } => BridgeEvent::RectifiedTextChunk { delta },
            EngineEvent::PreviewPrefills { prefills } => BridgeEvent::PreviewPrefills {
                prefills: prefills.into_iter().map(BridgePrefillRow::from).collect(),
            },
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
/// and, when the `[asr]` config carries credentials, the configured
/// provider's cloud adapter streaming real transcripts (see
/// `engine_factory::asr_provider` for the dispatch and its error
/// rules). Without credentials the mic+VAD provider keeps the session
/// semantics (speech activity, silence, device failure). The rectify
/// LLM is the real OpenAI-compatible client when
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
    let mut config = engine_config(&dirs)?;
    // Quick mode's two switches live in the rectify section, not under
    // [engine] — so they are read through the loader the settings window
    // writes with, and the engine boots on exactly what is saved. From
    // here on they follow the runtime switches (`set_rectify_behavior`).
    let rectify =
        spokenrectifier_llm::load_llm_config(&dirs).map_err(|err| anyhow!("LLM {}", err.0))?;
    config.quick_mode = rectify.rectify.quick.enabled;
    config.quick_rectify = rectify.rectify.quick.rectify;
    let asr = crate::engine_factory::asr_provider(&dirs)?;
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
    // Ending a session also ends its fake speech feed — and any hold
    // watch: the orb's Stop / Esc Cancel must not race the poller on
    // MarkQuick or a second Stop. The subscribe loop still stops the
    // watch on every Recording→* (silence auto-end, the watcher's own
    // release-stop) so a dropped isolate cannot leave a poller up.
    if matches!(command, BridgeCommand::StopSession | BridgeCommand::Cancel) {
        crate::hold_watcher::stop();
        if let SpeechSource::Fake { feed, .. } = &g.source {
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

/// Arm the primary-hotkey hold watcher (ADR-0020). `vks` are Win32
/// virtual-key codes of the current main-flow chord. Returns whether a
/// watch is now live — Dart swallows `WM_HOTKEY` repeats off that.
///
/// Arms for every primary-hotkey session, master switch on or off: the
/// watch owns the chord's release either way, so the auto-repeats of one
/// physical hold can never toggle the session (a switch-off hold used to
/// flicker start/stop through today's tap path). Whether the 400 ms mark
/// upgrades is the engine's call — with the switch off it refuses
/// `MarkQuick`, `is_quick()` stays false, and the hold ends as an
/// ordinary one (a short release keeps recording). A quiet `false`
/// (never an error) when the engine is not recording or `vks` is empty.
/// `stop_on_early_release` is the later press while already recording
/// (today's tap-to-stop); the opening hold that started the session
/// passes false so a short release keeps recording.
///
/// Independent of [`execute`] / `StartSession`: the orb click shares
/// that command and must not start a watch (球左键不跟).
pub fn watch_hold(vks: Vec<u32>, stop_on_early_release: bool) -> anyhow::Result<bool> {
    let g = global()?;
    if g.engine.state() != SessionState::Recording {
        return Ok(false);
    }
    if vks.is_empty() {
        return Ok(false);
    }
    Ok(crate::hold_watcher::start(
        vks,
        stop_on_early_release,
        g.engine.clone(),
        &g.rt,
    ))
}

/// Whether the hold watcher is currently running. Dart swallows
/// `WM_HOTKEY` repeats while this is true.
pub fn is_holding() -> anyhow::Result<bool> {
    Ok(crate::hold_watcher::is_holding())
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

/// The global directive (全局指令, ticket 22): the single `directive` key
/// from the app-owned `spokenrectifier-global.toml` — a companion file of
/// the scenario library's, so a library rewrite cannot lose it. A
/// missing, corrupt, or blank file reads as `None` (unset); this never
/// errors and never writes. The shell pushes the text at the engine via
/// `SetGlobalDirective` and repaints its preview from this same read.
pub fn global_directive() -> anyhow::Result<Option<String>> {
    let dirs = spokenrectifier_config::search_dirs();
    Ok(spokenrectifier_config::global::load_global_directive(&dirs))
}

/// Save the global directive into the file the loader resolves (created
/// in the app's settings home when none exists yet). `None` and blank
/// text both write the canonical unset form — clearing the field and
/// saving is the off switch. File-level and engine-independent like
/// [`global_directive`]: the main window re-reads the file and pushes the
/// fresh text at the engine (`SetGlobalDirective`) on the
/// global-changed event. Only ever runs on a user action.
pub fn save_global_directive(directive: Option<String>) -> anyhow::Result<()> {
    let dirs = spokenrectifier_config::search_dirs();
    spokenrectifier_config::global::save_global_directive(&dirs, directive.as_deref())
        .map_err(|err| anyhow!("cannot save the global directive: {err}"))
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

/// Dart-side mirror of a key's state for the diff-echo field (ADR-0008,
/// 2026-08-28 revision): a key stored in the git-ignored local file
/// rides the wire as its VALUE — the GUI paints it masked by default
/// with an eye toggle, and saves by diffing against it. An environment
/// key never echoes a value: only its placement, so the field starts
/// empty and typing would store a new local key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeKeyStatus {
    Unset,
    /// The stored key (from the local layer only — the loader's
    /// shared-file guard makes that the sole source).
    InLocalFile(String),
    FromEnv(String),
}

/// The key view from a section's key pair: the local-file value when
/// stored, else the env placement, else nothing.
fn bridge_key(api_key: Option<String>, api_key_env: Option<String>) -> BridgeKeyStatus {
    match spokenrectifier_config::section_write::key_status(
        api_key.as_deref(),
        api_key_env.as_deref(),
    ) {
        spokenrectifier_config::section_write::KeyStatus::Unset => BridgeKeyStatus::Unset,
        spokenrectifier_config::section_write::KeyStatus::InLocalFile => {
            BridgeKeyStatus::InLocalFile(api_key.unwrap_or_default())
        }
        spokenrectifier_config::section_write::KeyStatus::FromEnv(name) => {
            BridgeKeyStatus::FromEnv(name)
        }
    }
}

/// Dart-side mirror of what a connection save does to the api_key: the
/// field echoes the stored local key (see [`BridgeKeyStatus`]), so a
/// save DIFFS against it — keep the stored one, replace it, or clear it
/// (an empty `Set` is a `Clear` — an empty key is no key).
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
/// common segment's folded fields, every vendor sub-section (the pane
/// renders the active one), the resolved endpoint (a read-only preview;
/// `None` for providers without an adapter yet), and each secret's
/// placement.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeAsrConnection {
    /// `aliyun` / `volcengine` / `tencent` / `openai` / `azure`.
    pub provider: String,
    pub model: String,
    pub language: String,
    pub base_url: Option<String>,
    /// The WebSocket URL the current fields resolve to.
    pub endpoint: Option<String>,
    /// The common Bearer key pair (the active provider's, when its
    /// family is the Bearer one).
    pub key: BridgeKeyStatus,
    pub aliyun: BridgeAsrAliyun,
    pub volcengine: BridgeAsrVolcengine,
    pub tencent: BridgeAsrTencent,
    pub azure: BridgeAsrAzure,
}

/// `[asr.aliyun]` for the pane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrAliyun {
    pub workspace_id: Option<String>,
    pub region: String,
}

/// `[asr.volcengine]` for the pane; the access token echoes per the
/// diff-echo key block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrVolcengine {
    pub app_id: Option<String>,
    pub resource_id: String,
    pub access_key: BridgeKeyStatus,
}

/// `[asr.tencent]` for the pane; both account credentials echo per
/// the diff-echo key block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrTencent {
    pub app_id: Option<String>,
    pub secret_id: BridgeKeyStatus,
    pub secret_key: BridgeKeyStatus,
}

/// `[asr.azure]` for the pane (adapter not scheduled).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrAzure {
    pub region: Option<String>,
    pub endpoint_id: Option<String>,
}

/// The editor's whole `[asr]` card, mirroring the schema's
/// [`AsrConnectionEdit`]: common fields plus every vendor sub-section
/// (a provider switch never clears another vendor's fields).
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeAsrEdit {
    pub provider: String,
    pub model: String,
    pub language: String,
    pub base_url: Option<String>,
    pub api_key: BridgeKeyEdit,
    pub aliyun: BridgeAsrAliyunEdit,
    pub volcengine: BridgeAsrVolcengineEdit,
    pub tencent: BridgeAsrTencentEdit,
    pub azure: BridgeAsrAzureEdit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrAliyunEdit {
    pub workspace_id: Option<String>,
    pub region: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrVolcengineEdit {
    pub app_id: Option<String>,
    pub resource_id: String,
    pub access_key: BridgeKeyEdit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrTencentEdit {
    pub app_id: Option<String>,
    pub secret_id: BridgeKeyEdit,
    pub secret_key: BridgeKeyEdit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrAzureEdit {
    pub region: Option<String>,
    pub endpoint_id: Option<String>,
}

/// The effective `[llm]` connection as the settings pane paints it.
/// `key` is the ACTIVE vendor's resolved pair; `keys` carries every
/// vendor's — a key authenticates exactly one vendor, so the pane
/// re-binds its key block per vendor chip and a switch never shows
/// another vendor's key (ADR-0011).
///
/// The open shape (ADR-0019) rides here resolved: the format axis, the
/// thinking switch's four-state reading, and the three overlays as the
/// JSON text the pane's boxes hold (pretty, so a reopen reformats
/// whatever the file's table ordering was).
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeLlmConnection {
    pub vendor: String,
    pub base_url: String,
    pub model: String,
    /// `openai_chat` | `anthropic` | `gemini` (ADR-0019 item 1).
    pub format: String,
    pub key: BridgeKeyStatus,
    pub keys: Vec<BridgeLlmVendorKey>,
    /// The thinking group's reading: `on` | `off` | `unconfigured` |
    /// `broken`. Only `on` is the switch's painted state — the other
    /// three are one semantic for every consumer (ADR-0019 item 3).
    pub thinking_state: String,
    /// `broken`'s file-and-key detail, for the card's warning slot.
    pub thinking_detail: Option<String>,
    /// The resident overlay's JSON text; `None` when unset.
    pub body_json: Option<String>,
    pub thinking_on_json: Option<String>,
    pub thinking_off_json: Option<String>,
}

/// One chip's fill, straight from the engine-side single source
/// (`crates/llm::presets`) — the pane never copies the table (ADR-0019
/// item 5). The model rule (only when empty or still a preset name) and
/// the blank custom seventh chip live in the pane, not here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeLlmPreset {
    /// The chip's wire name — also the vendor slot it names.
    pub name: String,
    pub format: String,
    pub base_url: String,
    pub model: String,
    /// The 「设置思考字段」 switch the chip stamps.
    pub thinking_fields: bool,
    /// The two shares as JSON text, for the boxes.
    pub thinking_on_json: String,
    pub thinking_off_json: String,
}

/// The editor's whole `[llm]` card: the endpoint fields, the format
/// axis, the thinking switch, and the three overlay boxes as the JSON
/// text they hold (blank or `{}` = that share unset). The save writes
/// exactly this model, so the next load returns what the user saw.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeLlmEdit {
    pub vendor: String,
    pub base_url: String,
    pub model: String,
    /// One of the three format wire names (validated on the Rust side).
    pub format: String,
    pub thinking_fields: bool,
    /// The resident overlay's JSON text; blank/`{}`/None = unset.
    pub body_json: Option<String>,
    pub thinking_on_json: Option<String>,
    pub thinking_off_json: Option<String>,
    pub api_key: BridgeKeyEdit,
}

/// One vendor's resolved key pair, for the pane's per-vendor key block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeLlmVendorKey {
    pub vendor: String,
    pub key: BridgeKeyStatus,
}

fn asr_view(config: AsrConfig) -> BridgeAsrConnection {
    let stored = |value: &Option<String>| match value {
        Some(_) => BridgeKeyStatus::InLocalFile(value.clone().unwrap_or_default()),
        None => BridgeKeyStatus::Unset,
    };
    BridgeAsrConnection {
        provider: config.provider.as_str().to_string(),
        endpoint: config.endpoint(),
        key: bridge_key(config.api_key, config.api_key_env),
        model: config.model,
        language: config.language,
        base_url: config.base_url,
        aliyun: BridgeAsrAliyun {
            workspace_id: config.aliyun.workspace_id,
            region: config.aliyun.region,
        },
        volcengine: BridgeAsrVolcengine {
            app_id: config.volcengine.app_id,
            resource_id: config.volcengine.resource_id,
            access_key: stored(&config.volcengine.access_key),
        },
        tencent: BridgeAsrTencent {
            app_id: config.tencent.app_id,
            secret_id: stored(&config.tencent.secret_id),
            secret_key: stored(&config.tencent.secret_key),
        },
        azure: BridgeAsrAzure {
            region: config.azure.region,
            endpoint_id: config.azure.endpoint_id,
        },
    }
}

fn llm_view(config: spokenrectifier_llm::LlmConfig) -> BridgeLlmConnection {
    let keys = spokenrectifier_llm::Vendor::ALL
        .iter()
        .map(|&vendor| {
            let pair = config.resolved_keys(vendor);
            BridgeLlmVendorKey {
                vendor: vendor.as_str().to_string(),
                key: bridge_key(pair.api_key, pair.api_key_env),
            }
        })
        .collect();
    let share = |share: &Option<serde_json::Map<String, serde_json::Value>>| {
        share.as_ref().map(|map| {
            serde_json::to_string_pretty(&serde_json::Value::Object(map.clone()))
                .unwrap_or_default()
        })
    };
    BridgeLlmConnection {
        key: bridge_key(config.model.api_key, config.model.api_key_env),
        vendor: config.model.vendor.as_str().to_string(),
        base_url: config.model.base_url,
        model: config.model.model,
        format: config.model.format.as_str().to_string(),
        keys,
        thinking_state: config.model.thinking.state.as_str().to_string(),
        thinking_detail: config.model.thinking.state.detail().map(str::to_string),
        body_json: share(&config.model.thinking.overlays.body),
        thinking_on_json: share(&config.model.thinking.overlays.thinking_on),
        thinking_off_json: share(&config.model.thinking.overlays.thinking_off),
    }
}

/// The preset port (ADR-0019 item 5): the settings pane's chip row, read
/// from the engine-side single source rather than copied into Dart. The
/// blank 自定义 seventh chip is the pane's own — it names no preset.
pub fn llm_presets() -> Vec<BridgeLlmPreset> {
    spokenrectifier_llm::presets::all()
        .into_iter()
        .map(|preset| {
            let share = |map: &serde_json::Map<String, serde_json::Value>| {
                serde_json::to_string_pretty(&serde_json::Value::Object(map.clone()))
                    .unwrap_or_default()
            };
            BridgeLlmPreset {
                name: preset.name.to_string(),
                format: preset.format.as_str().to_string(),
                base_url: preset.base_url.to_string(),
                model: preset.model.to_string(),
                thinking_fields: preset.thinking_fields,
                thinking_on_json: share(&preset.thinking_on),
                thinking_off_json: share(&preset.thinking_off),
            }
        })
        .collect()
}

/// The effective `[asr]` and `[llm]` connections from the layer files —
/// the connection domain's initial paint. File-level and
/// engine-independent: the engine adopts the config at its creation,
/// and a save re-adopts it at once via [`apply_connection_configs`] —
/// next session (ASR) / next attempt (LLM), no restart (ADR-0010). The
/// fidelity-eval run builds its own engine per run, unaffected.
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

/// Write the editor's whole `[asr]` card back into the layer files (see
/// `save_asr_connection` for the placement and preservation rules —
/// common fields plus every vendor sub-section, every secret to the
/// local layer only) and return the re-read view — the file's truth,
/// not the ask.
pub fn set_asr_connection(edit: BridgeAsrEdit) -> anyhow::Result<BridgeAsrConnection> {
    let BridgeAsrEdit {
        provider,
        model,
        language,
        base_url,
        api_key,
        aliyun,
        volcengine,
        tencent,
        azure,
    } = edit;
    let provider = AsrProviderKind::from_str_name(&provider).ok_or_else(|| {
        anyhow!("[asr] provider \"{provider}\" is unknown: pick one of the known providers")
    })?;
    let dirs = spokenrectifier_config::search_dirs();
    save_asr_connection(
        &dirs,
        &AsrConnectionEdit {
            provider,
            model,
            language,
            base_url,
            api_key: api_key.into(),
            aliyun: AliyunEdit {
                workspace_id: aliyun.workspace_id,
                region: aliyun.region,
            },
            volcengine: VolcengineEdit {
                app_id: volcengine.app_id,
                resource_id: volcengine.resource_id,
                access_key: volcengine.access_key.into(),
            },
            tencent: TencentEdit {
                app_id: tencent.app_id,
                secret_id: tencent.secret_id.into(),
                secret_key: tencent.secret_key.into(),
            },
            azure: AzureEdit {
                region: azure.region,
                endpoint_id: azure.endpoint_id,
            },
        },
    )
    .map_err(|err| anyhow!("ASR {}", err.0))?;
    let config = load_asr_config(&dirs).map_err(|err| anyhow!("ASR {}", err.0))?;
    Ok(asr_view(config))
}

/// The settings pane's live endpoint preview: the WebSocket URL the
/// form's current fields resolve to, recomputed while the user types
/// or switches the provider chip — the same [`AsrConfig::endpoint`]
/// derivation the loaded view previews with, so there is exactly one.
pub fn asr_endpoint_preview(
    provider: String,
    model: String,
    base_url: Option<String>,
    workspace_id: Option<String>,
    region: String,
    app_id: Option<String>,
) -> anyhow::Result<Option<String>> {
    let provider = AsrProviderKind::from_str_name(&provider).ok_or_else(|| {
        anyhow!("[asr] provider \"{provider}\" is unknown: pick one of the known providers")
    })?;
    Ok(AsrConfig {
        provider,
        model,
        // `endpoint` trims and ignores whitespace-only overrides.
        base_url,
        aliyun: AliyunConfig {
            workspace_id,
            region,
        },
        tencent: TencentConfig {
            app_id,
            ..TencentConfig::default()
        },
        ..AsrConfig::defaults()
    }
    .endpoint())
}

/// Write the editor's `[llm]` model back into the layer files (see
/// `save_llm_connection`) and return the re-read view — the file's
/// truth, not the ask. The format and the thinking group ride the edit
/// whole (ADR-0019 items 1/2); the group's boxes are the JSON text the
/// pane holds, and a bad one refuses the save before anything is
/// written.
pub fn set_llm_connection(edit: BridgeLlmEdit) -> anyhow::Result<BridgeLlmConnection> {
    let dirs = spokenrectifier_config::search_dirs();
    let vendor = spokenrectifier_llm::Vendor::from_str_name(&edit.vendor).ok_or_else(|| {
        anyhow!(
            "[llm] vendor \"{}\" is unknown: pick one of the known endpoints",
            edit.vendor
        )
    })?;
    let format = spokenrectifier_llm::Format::from_str_name(&edit.format).ok_or_else(|| {
        anyhow!(
            "[llm] format \"{}\" is unknown: pick {}",
            edit.format,
            spokenrectifier_llm::Format::accepted()
        )
    })?;
    spokenrectifier_llm::save_llm_connection(
        &dirs,
        &spokenrectifier_llm::LlmConnectionEdit {
            vendor,
            base_url: edit.base_url,
            model: edit.model,
            format,
            thinking_fields: edit.thinking_fields,
            body_json: edit.body_json,
            thinking_on_json: edit.thinking_on_json,
            thinking_off_json: edit.thinking_off_json,
            api_key: edit.api_key.into(),
        },
    )
    .map_err(|err| anyhow!("LLM {}", err.0))?;
    let config =
        spokenrectifier_llm::load_llm_config(&dirs).map_err(|err| anyhow!("LLM {}", err.0))?;
    Ok(llm_view(config))
}

/// Adopt the saved `[asr]` / `[llm]` connections — and, riding the same
/// rebuilt client, every `[rectify]` key (ADR-0010, scope extended by
/// ADR-0015) — into the live engine at once: the settings window calls
/// this right after a save lands, so the next session opens with the new
/// ASR provider and the next rectify attempt with the new LLM and the new
/// rectify behavior (thinking policy, prefill, the light-touch gate, the
/// extra directive), no restart. Re-reads the layer files and rebuilds
/// both collaborators through the same factory the startup path uses
/// (mic-only fallback included: clearing the provider's credentials
/// really does drop back to mic+VAD at runtime).
///
/// The rebuild happens before any handover, so any refusal (an incomplete
/// credential set, an unadapted provider, the demo-mode LLM that has no
/// runtime script — all tested in `engine_factory`) returns `Err` and
/// keeps BOTH previous collaborators running; the files stay saved either
/// way, so the next launch adopts them regardless. The swap semantics are
/// locked by the engine's `live_swap` tests. A no-op on the fake engine
/// (tests and demos hold no production collaborators to swap).
pub fn apply_connection_configs() -> anyhow::Result<()> {
    let g = global()?;
    if !matches!(g.source, SpeechSource::Mic) {
        return Ok(());
    }
    let (asr, llm) =
        crate::engine_factory::rebuild_connections(&spokenrectifier_config::search_dirs())?;
    g.engine.set_asr_provider(asr);
    g.engine.set_llm_provider(llm);
    Ok(())
}

// -- the rectify domain (修正, ticket 13) --------------------------------------

/// The `[rectify]` behavior as the settings pane paints and saves it:
/// both tiers' thinking policy and prefill, the light-touch master
/// switch, threshold, and extra directive (ADR-0015/0016), plus the
/// quick-mode sub-section (ADR-0020). One struct both ways — the read
/// paints the initial form, the save writes exactly the model it
/// receives. The thinking policy rides the wire as its lowercase string;
/// `light_touch_extra_directive` and `quick_extra_directive` are `None`
/// when unset (empty saves remove the key).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeRectifyBehavior {
    /// `always` | `placeholders` | `off` (ADR-0015).
    pub full_thinking_policy: String,
    pub full_prefill: bool,
    pub light_touch_enabled: bool,
    pub light_touch_max_chars: u64,
    pub light_touch_thinking_policy: String,
    pub light_touch_prefill: bool,
    pub light_touch_extra_directive: Option<String>,
    /// `[rectify.quick]` (ADR-0020): holding the main hotkey past the
    /// threshold upgrades the session, which then skips preview and
    /// pastes on its own. `quick_enabled` is the master switch (off by
    /// default: no hold upgrades anything), `quick_rectify` whether the
    /// session still rectifies (off = paste the raw transcript),
    /// `quick_extra_directive` the quick-mode-only directive (`None` =
    /// unset; an empty save removes the key).
    pub quick_enabled: bool,
    pub quick_rectify: bool,
    pub quick_extra_directive: Option<String>,
    /// The CONNECTION domain's thinking reading (`on` / `off` /
    /// `unconfigured` / `broken`): the two cards' thinking-policy chips
    /// are disabled and the combination warning silenced while the
    /// connection's fields are inert (ADR-0019 item 3; design-spec
    /// §4.4's 修正 section). Carried on this read because the cards
    /// paint from it and nothing else — one round trip, and a chip
    /// click's re-read keeps the disable state fresh.
    pub connection_thinking: String,
}

fn rectify_view(config: &spokenrectifier_llm::LlmConfig) -> BridgeRectifyBehavior {
    let rectify = &config.rectify;
    BridgeRectifyBehavior {
        full_thinking_policy: rectify.full.thinking_policy.as_str().to_string(),
        full_prefill: rectify.full.prefill,
        light_touch_enabled: rectify.light_touch.enabled,
        light_touch_max_chars: rectify.light_touch.max_chars as u64,
        light_touch_thinking_policy: rectify
            .light_touch
            .tier
            .thinking_policy
            .as_str()
            .to_string(),
        light_touch_prefill: rectify.light_touch.tier.prefill,
        light_touch_extra_directive: rectify.light_touch.extra_directive.clone(),
        quick_enabled: rectify.quick.enabled,
        quick_rectify: rectify.quick.rectify,
        quick_extra_directive: rectify.quick.extra_directive.clone(),
        connection_thinking: config.model.thinking.state.as_str().to_string(),
    }
}

fn parse_policy(section: &str, name: &str) -> anyhow::Result<spokenrectifier_llm::ThinkingPolicy> {
    spokenrectifier_llm::ThinkingPolicy::from_str_name(name).ok_or_else(|| {
        anyhow!(
            "[{section}] thinking_policy \"{name}\" is unknown: pick one of \
             \"always\", \"placeholders\", \"off\""
        )
    })
}

/// The effective `[rectify]` behavior from the layer files — the
/// rectify pane's initial paint, legacy `[llm]` keys already folded in
/// through the grandfather (ADR-0015). File-level and
/// engine-independent: the client adopts the keys at its (re)build, and
/// the window's save re-adopts at once via [`apply_connection_configs`].
pub fn rectify_behavior() -> anyhow::Result<BridgeRectifyBehavior> {
    let dirs = spokenrectifier_config::search_dirs();
    let config =
        spokenrectifier_llm::load_llm_config(&dirs).map_err(|err| anyhow!("LLM {}", err.0))?;
    Ok(rectify_view(&config))
}

/// Write the rectify editor's whole model back into the layer files (see
/// `save_rectify_behavior`: the owning layers, the per-layer legacy-key
/// translation on the first save, the extra directive's blank-removal)
/// and return the re-read view — the files' truth, not the ask. No
/// combination validation rides this path: a thinking-off × prefill-on
/// tier saves fine, the pane's live warning is presentation only
/// (`.scratch/settings-window/issues/08`, ruling 4). The window calls
/// [`apply_connection_configs`] right after — the next attempt runs the
/// new behavior.
pub fn set_rectify_behavior(edit: BridgeRectifyBehavior) -> anyhow::Result<BridgeRectifyBehavior> {
    let dirs = spokenrectifier_config::search_dirs();
    let full = spokenrectifier_llm::TierEdit {
        thinking_policy: parse_policy("rectify.full", &edit.full_thinking_policy)?,
        prefill: edit.full_prefill,
    };
    let light = spokenrectifier_llm::LightTouchEdit {
        enabled: edit.light_touch_enabled,
        max_chars: usize::try_from(edit.light_touch_max_chars).map_err(|_| {
            anyhow!(
                "[rectify.light_touch] max_chars {} is out of range",
                edit.light_touch_max_chars
            )
        })?,
        tier: spokenrectifier_llm::TierEdit {
            thinking_policy: parse_policy(
                "rectify.light_touch",
                &edit.light_touch_thinking_policy,
            )?,
            prefill: edit.light_touch_prefill,
        },
        extra_directive: edit.light_touch_extra_directive,
    };
    let quick = spokenrectifier_llm::QuickEdit {
        enabled: edit.quick_enabled,
        rectify: edit.quick_rectify,
        extra_directive: edit.quick_extra_directive,
    };
    spokenrectifier_llm::save_rectify_behavior(
        &dirs,
        &spokenrectifier_llm::RectifyBehaviorEdit {
            full,
            light_touch: light,
            quick,
        },
    )
    .map_err(|err| anyhow!("LLM {}", err.0))?;
    let saved = rectify_behavior()?;
    // The live engine adopts the quick switches at once, exactly like the
    // advanced form's timings: `enabled` gates the next hold, `rectify`
    // the next session's snapshot. Internal to the save — no Dart-facing
    // command, because the save itself is one bridge call.
    let g = global()?;
    g.rt.block_on(g.engine.execute(Command::SetQuickMode {
        enabled: saved.quick_enabled,
        rectify: saved.quick_rectify,
    }))?;
    Ok(saved)
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
/// parameters, effective right now (the editable form's initial paint).
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
            mode: insertion.mode.as_str().to_string(),
            focus_settle_ms: insertion.focus_settle_ms,
            paste_settle_ms: insertion.paste_settle_ms,
            typing_delay_ms: insertion.typing_delay_ms,
        },
    })
}

/// Write the form's `[engine]` model (passage mode + the three timings)
/// into the layer files and hand it to the live engine at once
/// (ADR-0007, revised): both runtime commands adopt the saved values
/// immediately, and each session snapshots what it opens with — so the
/// save applies from the NEXT session on, while the file stays the
/// truth across launches. The quick panel's passage toggle stays the
/// runtime-only quick switch; this one persists. Returns the re-read
/// view.
pub fn set_engine_settings(
    passage_mode: bool,
    paragraph_silence_ms: u64,
    session_end_silence_ms: u64,
    rectify_timeout_ms: u64,
) -> anyhow::Result<BridgeEngineTiming> {
    let dirs = spokenrectifier_config::search_dirs();
    let engine = crate::engine_config::save_engine_settings(
        &dirs,
        passage_mode,
        spokenrectifier_engine::EngineTimings {
            paragraph_silence_ms,
            session_end_silence_ms,
            rectify_timeout_ms,
        },
    )?;
    execute(BridgeCommand::SetPassageMode {
        on: engine.passage_mode,
    })?;
    execute(BridgeCommand::SetEngineTimings {
        paragraph_silence_ms: engine.paragraph_silence_ms,
        session_end_silence_ms: engine.session_end_silence_ms,
        rectify_timeout_ms: engine.rectify_timeout_ms,
    })?;
    Ok(BridgeEngineTiming {
        passage_mode: engine.passage_mode,
        paragraph_silence_ms: engine.paragraph_silence_ms,
        session_end_silence_ms: engine.session_end_silence_ms,
        rectify_timeout_ms: engine.rectify_timeout_ms,
    })
}

/// Write the form's `[insertion]` model into the layer files and apply
/// it to the live inserter at once (ADR-0007, 2026-08-28 revision):
/// insertion is discrete per-confirm, so the swap is true real-time —
/// the very next ConfirmInsert runs with the new mode and pacing. A
/// no-op apply on the fake engine (tests and demos hold no target
/// window); the file write still lands. Returns the re-read view.
pub fn set_insertion_timing(
    mode: String,
    focus_settle_ms: u64,
    paste_settle_ms: u64,
    typing_delay_ms: u64,
) -> anyhow::Result<BridgeInsertionTiming> {
    let mode = spokenrectifier_insertion::InsertionMode::from_name(&mode).ok_or_else(|| {
        anyhow!("[insertion] mode \"{mode}\" is unknown: pick \"paste\" or \"typing\"")
    })?;
    let config = spokenrectifier_insertion::InsertionConfig {
        mode,
        focus_settle_ms,
        paste_settle_ms,
        typing_delay_ms,
    };
    let dirs = spokenrectifier_config::search_dirs();
    spokenrectifier_insertion::save_insertion_timing(&dirs, &config)
        .map_err(|err| anyhow!("insertion {}", err.0))?;
    if let InserterSlot::Real(inserter) = &global()?.inserter {
        inserter.set_config(config);
    }
    Ok(BridgeInsertionTiming {
        mode: mode.as_str().to_string(),
        focus_settle_ms: config.focus_settle_ms,
        paste_settle_ms: config.paste_settle_ms,
        typing_delay_ms: config.typing_delay_ms,
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
                    if let EngineEvent::SessionStateChanged { from, to, .. } = &envelope.event {
                        crate::esc_guard::set_armed(matches!(
                            to,
                            SessionState::Recording
                                | SessionState::Rectifying
                                | SessionState::Preview
                        ));
                        // The watch belongs to one Recording: cancel, a
                        // silence auto-end, an orb stop, or our own
                        // release-stop all land here. Independent of Dart
                        // so a dropped isolate cannot leave a poller up.
                        if *from == SessionState::Recording && *to != SessionState::Recording {
                            crate::hold_watcher::stop();
                        }
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

    #[test]
    fn the_endpoint_preview_matches_the_loaded_derivation() {
        // The form's live preview must be exactly what a load would
        // paint: the default aliyun URL carries the typed model.
        let preview = asr_endpoint_preview(
            "aliyun".into(),
            "my-engine".into(),
            None,
            None,
            "cn-beijing".into(),
            None,
        )
        .unwrap();
        assert_eq!(
            preview.as_deref(),
            Some("wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=my-engine")
        );

        // A base_url override wins; whitespace-only is no override.
        let preview = asr_endpoint_preview(
            "volcengine".into(),
            "bigmodel".into(),
            Some("  ".into()),
            None,
            String::new(),
            None,
        )
        .unwrap();
        assert_eq!(
            preview.as_deref(),
            Some("wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")
        );

        // Tencent: the app id rides the URL path — with one typed, the
        // preview is the connect base the adapter signs around; an
        // absent one leaves the path open.
        let preview = asr_endpoint_preview(
            "tencent".into(),
            "16k_zh_en".into(),
            None,
            None,
            String::new(),
            Some("1250012548".into()),
        )
        .unwrap();
        assert_eq!(
            preview.as_deref(),
            Some("wss://asr.cloud.tencent.com/asr/v2/1250012548")
        );

        // The unadapted providers promise no URL.
        let preview = asr_endpoint_preview(
            "openai".into(),
            "gpt-4o-transcribe".into(),
            None,
            None,
            String::new(),
            None,
        )
        .unwrap();
        assert_eq!(preview, None);

        assert!(
            asr_endpoint_preview("wat".into(), String::new(), None, None, String::new(), None)
                .unwrap_err()
                .to_string()
                .contains("provider")
        );
    }

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

    /// The pin command rides the wire with the engine's semantics
    /// (ticket 21's bridge seam; the engine's own behavior is locked by
    /// the engine tests): rejected outside recording, and inside it the
    /// sentinel surfaces through the live transcript event at once —
    /// a pin-only session rides the whole machine to insertion.
    #[test]
    fn pin_placeholder_rides_the_wire() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        let mut rx = global().unwrap().engine.subscribe();

        // Outside listening the wire reports the engine's rejection.
        let err = execute(BridgeCommand::PinPlaceholder)
            .unwrap_err()
            .to_string();
        assert!(err.contains("rejected"), "got: {err}");

        // While listening: the sentinel appears in the live transcript.
        fake_begin_session().unwrap();
        execute(BridgeCommand::StartSession).unwrap();
        execute(BridgeCommand::PinPlaceholder).unwrap();
        block_on(wait_for(&mut rx, |event| {
            matches!(
                event,
                EngineEvent::LiveTranscriptUpdated { text } if text.contains('‡')
            )
        }));

        // The pin-only session survives the recording end and inserts.
        execute(BridgeCommand::StopSession).unwrap();
        block_on(wait_state(&mut rx, SessionState::Preview));
        execute(BridgeCommand::ConfirmInsert).unwrap();
        block_on(wait_state(&mut rx, SessionState::Idle));
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
        // The global directive rides the same seam (ticket 22), with the
        // same any-time semantics and reset.
        execute(BridgeCommand::SetGlobalDirective {
            directive: Some("全部输出以简体中文书写".into()),
        })
        .unwrap();
        execute(BridgeCommand::SetGlobalDirective { directive: None }).unwrap();
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

    /// The advanced form's engine-timings switch rides the wire any
    /// time (the settings window sends it right after the file write)
    /// and reads back through the engine's getter.
    #[test]
    fn engine_timings_ride_the_wire_any_time() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        let defaults = global().unwrap().engine.engine_timings();
        execute(BridgeCommand::SetEngineTimings {
            paragraph_silence_ms: 1500,
            session_end_silence_ms: 2500,
            rectify_timeout_ms: 30_000,
        })
        .unwrap();
        let switched = global().unwrap().engine.engine_timings();
        assert_eq!(switched.paragraph_silence_ms, 1500);
        assert_eq!(switched.session_end_silence_ms, 2500);
        assert_eq!(switched.rectify_timeout_ms, 30_000);
        // Back to the seeded values so later tests see the defaults.
        execute(BridgeCommand::SetEngineTimings {
            paragraph_silence_ms: defaults.paragraph_silence_ms,
            session_end_silence_ms: defaults.session_end_silence_ms,
            rectify_timeout_ms: defaults.rectify_timeout_ms,
        })
        .unwrap();
    }

    /// The connection re-adoption is a quiet no-op on the fake engine:
    /// tests and demos hold no production collaborators to swap, and no
    /// config files are touched (the real path's refusals are tested in
    /// `engine_factory`, its swap semantics in the engine's live_swap
    /// tests).
    #[test]
    fn apply_connection_configs_is_a_noop_on_the_fake_engine() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        apply_connection_configs().unwrap();
    }

    /// The rectify pane's wire mirror maps every config field, the
    /// policies as their lowercase strings, and the extra directive
    /// as-is (the file-touching paths are tested at the llm crate's
    /// config layer; this locks the bridge mapping itself).
    #[test]
    fn the_rectify_view_mirrors_the_config_field_by_field() {
        use spokenrectifier_llm::{
            LightTouchConfig, QuickConfig, RectifyConfig, RectifyTier, ThinkingPolicy,
        };
        let rectify = RectifyConfig {
            full: RectifyTier {
                thinking_policy: ThinkingPolicy::Placeholders,
                prefill: false,
            },
            light_touch: LightTouchConfig {
                enabled: false,
                max_chars: 12,
                tier: RectifyTier {
                    thinking_policy: ThinkingPolicy::Off,
                    prefill: true,
                },
                extra_directive: Some("短句保留节奏".into()),
            },
            quick: QuickConfig {
                enabled: true,
                rectify: false,
                extra_directive: Some("快速短句保留节奏".into()),
            },
        };
        let mut config = spokenrectifier_llm::LlmConfig::defaults();
        config.rectify = rectify;
        let view = rectify_view(&config);
        assert_eq!(view.full_thinking_policy, "placeholders");
        assert!(!view.full_prefill);
        assert!(!view.light_touch_enabled);
        assert_eq!(view.light_touch_max_chars, 12);
        assert_eq!(view.light_touch_thinking_policy, "off");
        assert!(view.light_touch_prefill);
        assert_eq!(
            view.light_touch_extra_directive.as_deref(),
            Some("短句保留节奏")
        );
        // The quick sub-section (ADR-0020) rides the same mirror.
        assert!(view.quick_enabled);
        assert!(!view.quick_rectify);
        assert_eq!(
            view.quick_extra_directive.as_deref(),
            Some("快速短句保留节奏")
        );
        // The connection's reading rides the same view: the cards'
        // disable condition (ADR-0019 item 3). The default is `on`.
        assert_eq!(view.connection_thinking, "on");
        config.model.thinking.state = spokenrectifier_llm::ThinkingState::Unconfigured;
        assert_eq!(rectify_view(&config).connection_thinking, "unconfigured");
        // An unknown policy name is refused naming the section — the
        // wire never accepts a fourth tier.
        let err = parse_policy("rectify.full", "sometimes")
            .unwrap_err()
            .to_string();
        assert!(err.contains("rectify.full"), "got: {err}");
        assert!(err.contains("sometimes"), "got: {err}");
    }

    /// The connection view mirrors the open shape field by field
    /// (ADR-0019): the format axis, the thinking group's four-state
    /// reading with its broken detail, the three boxes as pretty JSON,
    /// and a key entry for every vendor slot.
    #[test]
    fn the_llm_view_mirrors_the_open_shape_field_by_field() {
        let mut config = spokenrectifier_llm::LlmConfig::defaults();
        config.model.format = spokenrectifier_llm::Format::Gemini;
        config.model.thinking.overlays.body =
            Some(serde_json::from_str(r#"{"temperature": 0.1}"#).unwrap());
        let view = llm_view(config);
        assert_eq!(view.format, "gemini");
        assert_eq!(view.thinking_state, "on");
        assert_eq!(view.thinking_detail, None);
        let body = view.body_json.expect("the resident share paints");
        assert!(body.contains("\"temperature\": 0.1"), "got: {body}");
        assert!(body.contains('\n'), "not pretty: {body}");
        assert!(view.thinking_on_json.is_some(), "the default on-share");
        assert!(
            view.keys.iter().any(|key| key.vendor == "custom"),
            "custom key entry missing"
        );

        // The broken branch carries its detail, and the group reads inert.
        let mut broken = spokenrectifier_llm::LlmConfig::defaults();
        broken.model.thinking.state =
            spokenrectifier_llm::ThinkingState::Broken("f.toml: [llm]: thinking_fields".into());
        broken.model.thinking.overlays = Default::default();
        let view = llm_view(broken);
        assert_eq!(view.thinking_state, "broken");
        assert_eq!(
            view.thinking_detail.as_deref(),
            Some("f.toml: [llm]: thinking_fields")
        );
        assert_eq!(view.thinking_on_json, None);
        assert_eq!(view.thinking_off_json, None);
    }

    /// The preset port carries the engine-side table (ADR-0019 item 5):
    /// six named chips, the custom seventh is the pane's own, and every
    /// share rides as JSON text the boxes can take verbatim.
    #[test]
    fn the_preset_port_carries_the_engine_table() {
        let presets = llm_presets();
        assert_eq!(presets.len(), 6, "custom is the pane's blank seventh");
        let row = |name: &str| {
            presets
                .iter()
                .find(|preset| preset.name == name)
                .unwrap_or_else(|| panic!("{name} missing"))
        };
        let anthropic = row("anthropic");
        assert_eq!(anthropic.format, "anthropic");
        assert_eq!(anthropic.base_url, "https://api.anthropic.com");
        assert!(anthropic.thinking_fields);
        assert!(anthropic.thinking_on_json.contains("adaptive"));
        let gemini = row("gemini");
        assert_eq!(gemini.format, "gemini");
        assert!(gemini.thinking_on_json.contains("includeThoughts"));
        // Every row's JSON parses back to an object — the boxes hold text.
        for preset in &presets {
            for json in [&preset.thinking_on_json, &preset.thinking_off_json] {
                let value: serde_json::Value = serde_json::from_str(json).unwrap();
                assert!(value.is_object(), "{}: {json}", preset.name);
            }
        }
        // The names are the vendor slot names the edit sends back.
        for preset in &presets {
            assert!(
                spokenrectifier_llm::Vendor::from_str_name(&preset.name).is_some(),
                "{} names no slot",
                preset.name
            );
        }
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
            style: BridgeSessionStyle::Live,
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
            EngineEvent::QuickMarked,
            EngineEvent::SpeechActivityChanged { speaking: true },
            EngineEvent::RectifiedTextChunk {
                delta: "好".into()
            },
            EngineEvent::PreviewPrefills {
                prefills: vec![spokenrectifier_engine::prefill::PrefillRow {
                    number: 1,
                    value: "张三".into(),
                }],
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
        // The prefill table's rows map field by field (ticket 18).
        let mapped: BridgeEvent = EngineEvent::PreviewPrefills {
            prefills: vec![
                spokenrectifier_engine::prefill::PrefillRow {
                    number: 1,
                    value: "张三".into(),
                },
                spokenrectifier_engine::prefill::PrefillRow {
                    number: 10,
                    value: String::new(),
                },
            ],
        }
        .into();
        assert_eq!(
            mapped,
            BridgeEvent::PreviewPrefills {
                prefills: vec![
                    BridgePrefillRow {
                        number: 1,
                        value: "张三".into()
                    },
                    BridgePrefillRow {
                        number: 10,
                        value: String::new()
                    },
                ]
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
