//! The engine core of the bridge: the command/event wire types, the two
//! engine flavors, command submission, the hold watcher, and the event
//! stream subscription.

use std::sync::{Arc, Mutex};

use anyhow::anyhow;
use tokio::runtime::Runtime;

use crate::frb_generated::StreamSink;

use spokenrectifier_engine::fakes::{ChannelAsr, FakeClock, FakeInserter, LlmStep, ScriptedLlm};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, RectifyLlm,
    SessionState, SessionStyle, TokioClock,
};
use spokenrectifier_store::{HistoryConfig, Store};

use super::state::{global, Global, InserterSlot, SpeechSource, GLOBAL};
use crate::engine_config::engine_config;
use crate::engine_factory::{llm_choice, production_inserter, LlmChoice};

/// Dart-side mirror of [`Command`].
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeCommand {
    StartSession,
    StopSession,
    Cancel,
    /// The confirm-time slot table rides beside the insert (占位符钉入
    /// 入库): one row per slot whose value the shell's substitution
    /// landed in the inserted text. A pass-through the engine ferries to
    /// the recorder; pin-less and degraded confirms send an empty table.
    ConfirmInsert {
        placeholders: Vec<BridgePlaceholderFill>,
    },
    Reroll,
    UpdatePreviewText {
        text: String,
    },
    /// The selected scenario's style-directive text and its name (a
    /// pass-through pair the engine carries without interpreting; the
    /// store resolves the name when the session is recorded); `None`
    /// returns to the built-in default register.
    SetStyleDirective {
        directive: Option<String>,
        scenario: Option<String>,
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
    /// `source_session_id` names the history row being re-run (another
    /// pass-through: the store records it as the new session's 来源会话).
    RectifyText {
        raw_transcript: String,
        style: BridgeSessionStyle,
        source_session_id: Option<i64>,
    },
}

/// Dart-side mirror of [`SessionStyle`]: how a re-rectify session picks
/// its style — follow the live selection, pin a scenario's directive
/// text, or pin the built-in default register (指定场景重新修正's 默认
/// item, ticket 28).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeSessionStyle {
    Live,
    /// `scenario` is the pick's name (a pass-through; `None` for a
    /// directive pinned without a library entry).
    Directive {
        text: String,
        scenario: Option<String>,
    },
    DefaultRegister,
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
    /// Thinking-channel text off the same rectify stream (14 号票,
    /// ADR-0019 item 6): the one-shot marquee's feed. Feedback material
    /// only — the shell keeps it out of the preview text and the
    /// insertion.
    RectifyThinkingDelta {
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

/// Dart-side mirror of one confirm-time slot row: the slot's number
/// (its identity), the model's prefill for it ('' = none delivered),
/// and the value the confirm actually substituted (possibly ''). The
/// shell's slot document is the fact source and folds same-number
/// occurrences to one row; the engine ferries the table without
/// interpreting it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgePlaceholderFill {
    pub number: u32,
    pub prefill: String,
    pub value: String,
}

impl From<BridgePlaceholderFill> for spokenrectifier_engine::prefill::PlaceholderFill {
    fn from(value: BridgePlaceholderFill) -> Self {
        spokenrectifier_engine::prefill::PlaceholderFill {
            number: value.number,
            prefill: value.prefill,
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

impl From<BridgeCommand> for Command {
    fn from(value: BridgeCommand) -> Self {
        match value {
            BridgeCommand::StartSession => Command::StartSession,
            BridgeCommand::StopSession => Command::StopSession,
            BridgeCommand::PinPlaceholder => Command::PinPlaceholder,
            BridgeCommand::Cancel => Command::Cancel,
            BridgeCommand::ConfirmInsert { placeholders } => Command::ConfirmInsert {
                placeholders: placeholders
                    .into_iter()
                    .map(spokenrectifier_engine::prefill::PlaceholderFill::from)
                    .collect(),
            },
            BridgeCommand::Reroll => Command::Reroll,
            BridgeCommand::UpdatePreviewText { text } => Command::UpdatePreviewText(text),
            BridgeCommand::SetStyleDirective {
                directive,
                scenario,
            } => Command::SetStyleDirective {
                directive,
                scenario,
            },
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
                source_session_id,
            } => Command::RectifyText {
                raw_transcript,
                style: style.into(),
                source_session_id,
            },
        }
    }
}

impl From<BridgeSessionStyle> for SessionStyle {
    fn from(value: BridgeSessionStyle) -> Self {
        match value {
            BridgeSessionStyle::Live => SessionStyle::Live,
            BridgeSessionStyle::Directive { text, scenario } => {
                SessionStyle::Directive { text, scenario }
            }
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
            EngineEvent::RectifyThinkingDelta { delta } => {
                BridgeEvent::RectifyThinkingDelta { delta }
            }
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
    // The same store the engine records into, the panels read from, and
    // the editors write to — its opening also runs the one-time legacy
    // file migration.
    let store = crate::store::open_store(&dirs)?;
    // The dictionary re-read per session: Aliyun recognition gets it as
    // the transcription corpus, the rectify prompt as the term reference.
    let terms = crate::store::DbTermSource::new(store.clone());
    let engine = Engine::new(
        config,
        EngineDeps {
            asr,
            llm,
            // The same instance the slot holds, so `note_target` on
            // StartSession arms the very inserter ConfirmInsert runs.
            inserter: inserter.clone(),
            history: Some(store.clone()),
            terms: Some(terms),
            clock: Arc::new(TokioClock::new()),
        },
    );
    let _ = GLOBAL.set(Global {
        rt: Runtime::new()?,
        engine,
        source: SpeechSource::Mic,
        inserter: InserterSlot::Real(inserter),
        store,
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
        // The all-fake setup runs in tests and headless demos: an
        // in-memory store, so no database file appears next to the test
        // binary. Keep-nothing, matching the disabled history before it.
        store: Arc::new(Store::open_memory(
            HistoryConfig {
                enabled: false,
                retention_days: 30,
            },
            spokenrectifier_store::wall_clock(),
        )),
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
        // The only refusal left is a rejected command (a double-click
        // racing the state machine): no state change will fire, so the
        // eager arm above must be taken back — an armed guard at idle
        // would eat a stranger's Esc. An open failure arrives later as
        // an event pair (Error + Cancelled→Idle); the forwarder disarms
        // on those state changes and the cancelled end restores focus.
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
