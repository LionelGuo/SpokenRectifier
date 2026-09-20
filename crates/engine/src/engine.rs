//! The engine: session state machine over injectable collaborators.
//!
//! Commands in ([`Engine::execute`]), events out ([`Engine::subscribe`]).
//! States: `Idle → Recording → Rectifying → Preview → Inserted|Cancelled →
//! Idle` (or straight `Idle → Rectifying` via [`Command::RectifyText`],
//! history retrieval re-running a past utterance), with `Cancel` valid in
//! every active state. `Inserted` and
//! `Cancelled` are transient — the engine immediately continues to `Idle`,
//! so every state has an exit and no session can wedge.

use std::sync::{Arc, Mutex, MutexGuard, RwLock};

use futures::stream::{BoxStream, StreamExt};
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use crate::clock::Clock;
use crate::command::{Command, SessionStyle};
use crate::config::{EngineConfig, EngineTimings};
use crate::event::{EngineEvent, EventEnvelope, SessionId, SessionState};
use crate::prefill;
use crate::provider::asr::{AsrEvent, AsrOpenError, AsrProvider};
use crate::provider::history::{RecordedSession, SessionRecorder};
use crate::provider::inserter::TextInserter;
use crate::provider::llm::{RectifyLlm, RectifyRequest, RectifyTokenStream};
use crate::provider::terms::TermSource;

/// Collaborators the engine is constructed with.
pub struct EngineDeps {
    pub asr: Arc<dyn AsrProvider>,
    pub llm: Arc<dyn RectifyLlm>,
    pub inserter: Arc<dyn TextInserter>,
    pub clock: Arc<dyn Clock>,
    /// Receiver of finished sessions; `None` keeps no history.
    pub history: Option<Arc<dyn SessionRecorder>>,
    /// Hotword dictionary; `None` injects nothing on either path.
    pub terms: Option<Arc<dyn TermSource>>,
}

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("command {command:?} rejected in state {state}")]
    CommandRejected {
        command: Command,
        state: SessionState,
    },
    #[error("rectify text rejected: the utterance is empty")]
    EmptyUtterance,
    #[error(transparent)]
    AsrOpen(#[from] AsrOpenError),
}

#[derive(Clone)]
pub struct Engine {
    inner: Arc<Inner>,
}

struct Inner {
    /// The selected scenario's style-directive text (`None` = the
    /// built-in default register). Read fresh when each rectify request
    /// is built, so a switch any time shapes the next attempt.
    style_directive: RwLock<Option<String>>,
    /// The selected scenario's NAME riding beside its directive — a
    /// pass-through the engine never interprets (the store resolves it
    /// to a scenario id when the session is recorded). Moves with
    /// [`Inner::style_directive`]: blanking the directive clears both.
    style_scenario: RwLock<Option<String>>,
    /// The global directive's text (ticket 22; `None` = unset). A live
    /// value like the style selection — read fresh when each request is
    /// built, never pinned per session: a change mid-session shapes the
    /// next attempt, rerolls included.
    global_directive: RwLock<Option<String>>,
    /// Passage mode as it stands now, seeded from the config at
    /// construction and switched at runtime (quick panel). Snapshotted
    /// when each session opens, so a switch applies from the next
    /// session on.
    passage_mode: RwLock<bool>,
    /// The latency timings as they stand now, seeded from the config at
    /// construction and switched at runtime (the settings window's
    /// advanced form). Snapshotted when each session opens, so a switch
    /// applies from the next session on.
    timings: RwLock<EngineTimings>,
    /// The quick-mode master switch as it stands now (ADR-0020), seeded
    /// from the config at construction and switched at runtime (the
    /// settings window's third card). Read when a hold crosses the
    /// threshold: with it off, no mark can upgrade a session.
    quick_mode: RwLock<bool>,
    /// `[rectify.quick] rectify` as it stands now — same seeding and
    /// runtime switch as [`Inner::quick_mode`]. Snapshotted when each
    /// session opens, so a switch applies from the next session on.
    quick_rectify: RwLock<bool>,
    /// The ASR provider the NEXT session opens with — the
    /// construction-time one, or a runtime replacement (ADR-0010). Read
    /// once at each session open, so a running session's stream never
    /// changes under it.
    asr: RwLock<Arc<dyn AsrProvider>>,
    /// The LLM each rectify attempt runs with — the construction-time
    /// one, or a runtime replacement (ADR-0010). Cloned per attempt,
    /// so a switch shapes the next attempt, never one in flight.
    llm: RwLock<Arc<dyn RectifyLlm>>,
    inserter: Arc<dyn TextInserter>,
    history: Option<Arc<dyn SessionRecorder>>,
    terms: Option<Arc<dyn TermSource>>,
    clock: Arc<dyn Clock>,
    events: broadcast::Sender<EventEnvelope>,
    /// Serializes command handling; background tasks never take it, so
    /// they cannot deadlock against a command waiting on them.
    command_gate: tokio::sync::Mutex<()>,
    state: Mutex<SharedState>,
}

struct SharedState {
    state: SessionState,
    next_session_id: u64,
    seq: u64,
    session: Option<Session>,
}

struct Session {
    id: SessionId,
    /// The hotword dictionary snapshotted when the session opened; the
    /// session's recognition bias and rectify term reference both read it,
    /// so mid-session dictionary edits wait for the next session.
    terms: Vec<String>,
    /// Passage mode snapshotted when the session opened, so a runtime
    /// switch applies from the next session on.
    passage_mode: bool,
    /// The latency timings snapshotted when the session opened, so a
    /// runtime switch applies from the next session on (and never pulls
    /// thresholds out from under a running session).
    timings: EngineTimings,
    /// Paragraphs closed by a paragraph mark.
    paragraphs: Vec<String>,
    /// Finalized speech since the last paragraph mark.
    current_paragraph: String,
    /// Interim speech not yet finalized.
    partial: String,
    /// Placeholders pinned so far, in pin order; the number is the index
    /// plus 1. Held outside the three transcript strings and spliced in
    /// at render time, so later speech never disturbs a pin and the
    /// freeze reuses the live join instead of recomputing positions.
    pins: Vec<Pin>,
    /// The snapshot constraint an in-flight pin opened: `Some` while the
    /// sentence a pin split is still awaiting its first non-empty Final.
    /// Transcript frames may only extend the frozen prefix, and a
    /// paragraph mark cannot split the pinned row. See [`InFlight`].
    in_flight: Option<InFlight>,
    /// Whether the current silence run already emitted a paragraph mark.
    paragraph_marked_current_silence: bool,
    /// Speech happened since the last paragraph mark (VAD activity or
    /// transcript events) — the next threshold silence closes a paragraph.
    speech_since_mark: bool,
    /// The current silence run's elapsed as last reported by the
    /// recognizer — the rebasing point a pin press captures (工单 35).
    last_silence_ms: u64,
    /// Silence already elapsed when the last pin pressed: the paragraph
    /// threshold is judged on what accumulated after the press, so a
    /// press mid-pause buys the pin its own full silence window (工单
    /// 35). The session-end threshold keeps the raw elapsed. Speech
    /// resets this along with the recognizer's own silence run.
    silence_baseline_ms: u64,
    /// Any speech at all this session. A session with none is discarded on
    /// stop/auto-end instead of rectifying an empty utterance.
    any_speech: bool,
    /// Raw transcript frozen when recording ended.
    frozen: Option<FrozenUtterance>,
    /// The one-time style pick this session was re-rectified under
    /// (ticket 23's 指定场景, ticket 28's 默认); `Live` on mic sessions
    /// and plain re-rectifies, which follow the live selection instead.
    /// Pinned for the session's lifetime: rerolls keep it, and it dies
    /// with the session.
    style: SessionStyle,
    /// The store id of the history entry this session re-runs, if any —
    /// a pass-through from the retrieval command, recorded with the
    /// session pair as its 来源会话. `None` on every mic session.
    source_session_id: Option<i64>,
    /// Whether this session was upgraded to quick mode (ADR-0020) by a
    /// hotkey chord held past the threshold. Decided at most once, and
    /// dropped the moment the session fails into preview: from there
    /// every attempt runs the ordinary path again.
    quick: bool,
    /// `[rectify.quick] rectify` as snapshotted when the session opened
    /// (the timings rule): on, a quick stop runs the light-touch pass and
    /// inserts its result; off, the frozen raw transcript is inserted
    /// untouched and no model runs.
    quick_rectify: bool,
    /// The hotkey chord is physically down right now — the shell's hold
    /// watcher reporting (ADR-0020). A held chord suppresses the silence
    /// auto-end: the speaker is mid-gesture and the release ends the
    /// session. False at open, because the watcher arms only after the
    /// session starts, so nothing carries over between sessions.
    hold_gate: bool,
    /// The rectified text as it will be inserted (possibly user-edited).
    preview_text: String,
    /// Ends the ASR stream consumption; fired when recording ends.
    asr_cancel: CancellationToken,
    /// Token of the current rectify attempt; fresh per attempt so rerolls
    /// get a live token after the previous recording-end cancellation.
    rectify_cancel: Option<CancellationToken>,
}

struct FrozenUtterance {
    raw_transcript: String,
    paragraphs: Vec<String>,
}

/// A pinned placeholder (钉入): the sentinel `‡N‡` held at a fixed point
/// of the transcript. The number is the identity — from 1, in pin order,
/// per session; never changed, never reused, never carried across
/// sessions.
struct Pin {
    number: usize,
    anchor: PinAnchor,
}

impl Pin {
    /// The placeholder's textual form: `‡N‡`, ASCII digits, no padding —
    /// the same bytes in the live transcript, the frozen transcript, and
    /// the rectify request.
    fn sentinel(&self) -> String {
        format!("‡{}‡", self.number)
    }
}

/// Where a pin sits: virtual paragraph `paragraph` (the closed paragraphs,
/// then the current paragraph as the last index) at byte `offset` within
/// it. The anchor cannot go stale: closed paragraphs are immutable, the
/// current paragraph only ever appends (keeping its content when it
/// closes), and the interim partial is never pinned into — a draft in
/// flight at the press is frozen onto the finalized side first (ticket
/// 16), so the pin still lands after finalized text.
#[derive(Debug)]
struct PinAnchor {
    paragraph: usize,
    offset: usize,
}

/// The constraint an in-flight pin opens (ticket 16): the press froze the
/// draft spoken so far into the finalized side as the pin's left — dead to
/// the recognizer's later rewrites — and until this sentence's first
/// non-empty Final arrives, transcript frames may only extend the text
/// after the pin on top of the frozen prefix. The snapshot is cumulative
/// across pins stacked in the same sentence: each later press freezes the
/// tail it collected, growing the prefix the recognizer must still start
/// with.
struct InFlight {
    /// The frozen speech-side prefix, in bytes: exactly what this sentence
    /// has committed to the current paragraph. Prefix checks and strips
    /// are byte-exact against it, and it never contains a sentinel (pins
    /// live outside the transcript strings).
    snapshot: String,
}

/// The directive seam's blank guard: whitespace-only text reads as no
/// directive. Shared by the live selection, the live global directive,
/// and a session's one-time override — the loaders already normalize,
/// this guards the engine seam itself.
fn non_blank(directive: Option<String>) -> Option<String> {
    directive.filter(|text| !text.trim().is_empty())
}

impl Engine {
    pub fn new(config: EngineConfig, deps: EngineDeps) -> Self {
        let (events, _) = broadcast::channel(1024);
        Self {
            inner: Arc::new(Inner {
                style_directive: RwLock::new(None),
                style_scenario: RwLock::new(None),
                global_directive: RwLock::new(None),
                passage_mode: RwLock::new(config.passage_mode),
                timings: RwLock::new(config.timings()),
                quick_mode: RwLock::new(config.quick_mode),
                quick_rectify: RwLock::new(config.quick_rectify),
                asr: RwLock::new(deps.asr),
                llm: RwLock::new(deps.llm),
                inserter: deps.inserter,
                history: deps.history,
                terms: deps.terms,
                clock: deps.clock,
                events,
                command_gate: tokio::sync::Mutex::new(()),
                state: Mutex::new(SharedState {
                    state: SessionState::Idle,
                    next_session_id: 1,
                    seq: 0,
                    session: None,
                }),
            }),
        }
    }

    /// Subscribe to the event stream. Subscribe before issuing commands to
    /// see every event of a session.
    pub fn subscribe(&self) -> broadcast::Receiver<EventEnvelope> {
        self.inner.events.subscribe()
    }

    /// Current session state, for introspection and CLI display.
    pub fn state(&self) -> SessionState {
        self.inner.state_lock().state
    }

    /// Passage mode as it stands now (config-seeded, runtime-switched) —
    /// the value the NEXT session opens with. For the panel's toggle.
    pub fn passage_mode(&self) -> bool {
        *self.inner.passage_mode.read().unwrap()
    }

    /// The latency timings as they stand now (config-seeded,
    /// runtime-switched) — the values the NEXT session opens with.
    pub fn engine_timings(&self) -> EngineTimings {
        *self.inner.timings.read().unwrap()
    }

    /// Quick-mode master switch as it stands now (config-seeded,
    /// runtime-switched). The hold watcher reads it before arming so a
    /// switch-off session never starts a watch (ADR-0020); [`Command::MarkQuick`]
    /// still no-ops on its own if the watcher races a flip.
    pub fn quick_mode(&self) -> bool {
        *self.inner.quick_mode.read().unwrap()
    }

    /// Whether the current session has been upgraded to quick mode.
    /// False when idle or when the session stayed ordinary (switch off,
    /// already pinned, never marked). The hold watcher reads it after
    /// [`Command::MarkQuick`]: a silent refusal must not treat the release
    /// as a stop.
    pub fn is_quick(&self) -> bool {
        self.inner
            .state_lock()
            .session
            .as_ref()
            .is_some_and(|session| session.quick)
    }

    /// Swap the ASR provider at runtime: the next session opens with the
    /// new one; a running session keeps the stream it opened (ADR-0010).
    pub fn set_asr_provider(&self, asr: Arc<dyn AsrProvider>) {
        *self.inner.asr.write().unwrap() = asr;
    }

    /// Swap the rectify LLM at runtime: the next attempt (first stop,
    /// reroll, history re-rectify alike) runs with the new one; an
    /// attempt in flight keeps the LLM it started with (ADR-0010).
    pub fn set_llm_provider(&self, llm: Arc<dyn RectifyLlm>) {
        *self.inner.llm.write().unwrap() = llm;
    }

    /// Submit a command. Returns `Err` only for rejected commands (wrong
    /// state, ASR could not be opened); asynchronous outcomes arrive as
    /// events.
    pub async fn execute(&self, command: Command) -> Result<(), EngineError> {
        let _gate = self.inner.command_gate.lock().await;
        match command.clone() {
            Command::StartSession => self.start_session().await,
            Command::RectifyText {
                raw_transcript,
                style,
                source_session_id,
            } => self.rectify_text(raw_transcript, style, source_session_id),
            Command::StopSession => {
                let state = self.inner.state_lock().state;
                if state != SessionState::Recording {
                    return Err(EngineError::CommandRejected {
                        command: Command::StopSession,
                        state,
                    });
                }
                begin_rectify(&self.inner);
                Ok(())
            }
            Command::PinPlaceholder => self.pin_placeholder(),
            Command::MarkQuick => self.mark_quick(),
            Command::HoldGate { held } => self.hold_gate(held),
            Command::Cancel => self.cancel_session(),
            Command::ConfirmInsert { placeholders } => self.confirm_insert(placeholders).await,
            Command::Reroll => {
                let state = self.inner.state_lock().state;
                if state != SessionState::Preview {
                    return Err(EngineError::CommandRejected {
                        command: Command::Reroll,
                        state,
                    });
                }
                begin_rectify(&self.inner);
                Ok(())
            }
            Command::UpdatePreviewText(text) => self.update_preview_text(text),
            Command::SetStyleDirective {
                directive,
                scenario,
            } => {
                // Blank directive text reads as no directive: the default
                // register. (Scenario entries with blank directives are
                // already filtered by the library loader; this guards the
                // engine seam itself.) The selection's name rides beside
                // its directive and falls with it.
                let directive = non_blank(directive);
                let scenario = if directive.is_some() {
                    non_blank(scenario)
                } else {
                    None
                };
                *self.inner.style_directive.write().unwrap() = directive;
                *self.inner.style_scenario.write().unwrap() = scenario;
                Ok(())
            }
            Command::SetGlobalDirective(directive) => {
                // Same blank guard as SetStyleDirective's, for the same
                // reason: the storage loader already normalizes, this
                // guards the engine seam itself.
                *self.inner.global_directive.write().unwrap() = non_blank(directive);
                Ok(())
            }
            Command::SetPassageMode(on) => {
                *self.inner.passage_mode.write().unwrap() = on;
                Ok(())
            }
            Command::SetEngineTimings(timings) => {
                *self.inner.timings.write().unwrap() = timings;
                Ok(())
            }
            Command::SetQuickMode { enabled, rectify } => {
                *self.inner.quick_mode.write().unwrap() = enabled;
                *self.inner.quick_rectify.write().unwrap() = rectify;
                Ok(())
            }
        }
    }

    // -- command handlers ---------------------------------------------------

    async fn start_session(&self) -> Result<(), EngineError> {
        {
            let st = self.inner.state_lock();
            if st.state != SessionState::Idle {
                return Err(EngineError::CommandRejected {
                    command: Command::StartSession,
                    state: st.state,
                });
            }
        }
        // One read feeds both injection paths for this session: the
        // stream opens biased by it and the rectify request carries it.
        let terms = self.inner.current_terms();
        // Clone out of the slot so the lock never crosses the await, and
        // so this session owns the provider it opened even if the slot is
        // swapped while the open is in flight.
        let asr = self.inner.asr.read().unwrap().clone();
        let stream = asr.open_stream(&terms).await?;
        let (sid, cancel) = {
            let mut st = self.inner.state_lock();
            // The command gate serializes commands, so we are still idle.
            let id = SessionId(st.next_session_id);
            st.next_session_id += 1;
            let session = Session::new(
                id,
                terms,
                self.inner.current_passage_mode(),
                self.inner.current_timings(),
                self.inner.current_quick_rectify(),
            );
            let cancel = session.asr_cancel.clone();
            st.session = Some(session);
            self.inner.transition(&mut st, id, SessionState::Recording);
            (id, cancel)
        };
        tokio::spawn(consume_asr(self.inner.clone(), sid, stream, cancel));
        Ok(())
    }

    /// History retrieval re-running a past utterance: freeze the given
    /// transcript as the session's utterance and jump straight into the
    /// machine (`Idle → Rectifying`), no microphone involved. Reroll,
    /// preview editing, cancel, and insert all work as after a recording.
    /// `style` optionally pins the session's one-time style pick (see
    /// [`Command::RectifyText`]).
    fn rectify_text(
        &self,
        raw_transcript: String,
        style: SessionStyle,
        source_session_id: Option<i64>,
    ) -> Result<(), EngineError> {
        let (sid, cancel, request, timings) = {
            let mut st = self.inner.state_lock();
            if st.state != SessionState::Idle {
                return Err(EngineError::CommandRejected {
                    command: Command::RectifyText {
                        raw_transcript,
                        style,
                        source_session_id,
                    },
                    state: st.state,
                });
            }
            if raw_transcript.trim().is_empty() {
                return Err(EngineError::EmptyUtterance);
            }
            // Same blank guard as SetStyleDirective's: whitespace-only
            // pinned text reads as no pin.
            let style = match style {
                SessionStyle::Directive { text, scenario } => match non_blank(Some(text)) {
                    Some(text) => SessionStyle::Directive {
                        text,
                        scenario: non_blank(scenario),
                    },
                    None => SessionStyle::Live,
                },
                other => other,
            };
            // Newlines carry the paragraph structure the transcript was
            // frozen with; splitting restores it exactly.
            let paragraphs: Vec<String> = raw_transcript.split('\n').map(str::to_string).collect();
            let id = SessionId(st.next_session_id);
            st.next_session_id += 1;
            let mut session = Session::new(
                id,
                self.inner.current_terms(),
                self.inner.current_passage_mode(),
                self.inner.current_timings(),
                self.inner.current_quick_rectify(),
            );
            session.frozen = Some(FrozenUtterance {
                raw_transcript: raw_transcript.clone(),
                paragraphs: paragraphs.clone(),
            });
            session.style = style;
            session.source_session_id = source_session_id;
            let cancel = CancellationToken::new();
            session.rectify_cancel = Some(cancel.clone());
            let sid = session.id;
            let terms = session.terms.clone();
            let timings = session.timings;
            let style_directive = Inner::session_style_directive(&session, &self.inner);
            let global_directive = self.inner.current_global_directive();
            st.session = Some(session);
            self.inner
                .transition(&mut st, sid, SessionState::Rectifying);
            // The utterance is text, not speech: publish its transcript so
            // the preview's raw comparison has something to compare against
            // (emitted directly, not as a stream event, because the session
            // is no longer in Recording).
            self.inner.emit(
                &mut st,
                sid,
                EngineEvent::LiveTranscriptUpdated {
                    text: raw_transcript.clone(),
                },
            );
            (
                sid,
                cancel,
                RectifyRequest {
                    raw_transcript,
                    paragraphs,
                    style_directive,
                    global_directive,
                    terms,
                    // The seam default: the production client applies
                    // the [llm] prefill config over this before
                    // composing (ADR-0014).
                    prefill: true,
                    // A rectified text never came from a held hotkey:
                    // quick mode is a gesture on a live session, and
                    // this path has no session to upgrade (ADR-0020).
                    quick: false,
                },
                timings,
            )
        };
        let llm = self.inner.llm.read().unwrap().clone();
        tokio::spawn(rectify_task(
            self.inner.clone(),
            sid,
            llm,
            request,
            cancel,
            timings,
        ));
        Ok(())
    }

    /// Pin a placeholder at the current end of the spoken segment. The
    /// whole mutation runs under the state lock and surfaces as one
    /// `LiveTranscriptUpdated` — no new event shape, so the shell needs
    /// nothing new to show it.
    fn pin_placeholder(&self) -> Result<(), EngineError> {
        let mut st = self.inner.state_lock();
        if st.state != SessionState::Recording {
            return Err(EngineError::CommandRejected {
                command: Command::PinPlaceholder,
                state: st.state,
            });
        }
        let sid = current_sid(&st);
        let session = st.session.as_mut().expect("active session");
        if session.quick {
            // An upgraded session takes no pins (ADR-0020). The shell
            // disarms the pin hotkey off the upgrade event, and this is
            // the belt to that braces: a press that lost the race is
            // swallowed whole — no sentinel, no error, nothing the user
            // would have to be told about.
            return Ok(());
        }
        session.pin();
        let text = session.live_text();
        self.inner
            .emit(&mut st, sid, EngineEvent::LiveTranscriptUpdated { text });
        Ok(())
    }

    /// Upgrade the recording session to quick mode (ADR-0020): the chord
    /// was held past the threshold with nothing pinned yet, so the release
    /// now ends the session and its stop goes straight through. The one
    /// call that lands emits [`EngineEvent::QuickMarked`], which the shell
    /// turns into the 聆听中 phase word and the pin-hotkey disarm.
    ///
    /// Silent in every other case — the master switch off, no session
    /// recording, an upgrade already made, or a pin already down (a pinned
    /// session is ordinary for its whole life). Silence, not rejection:
    /// this is a platform signal the user never issued directly, so there
    /// is nothing to surface.
    fn mark_quick(&self) -> Result<(), EngineError> {
        // Read before the state lock: the switch is a live setting, never
        // snapshotted into a session.
        let switch_on = *self.inner.quick_mode.read().unwrap();
        let mut st = self.inner.state_lock();
        if !switch_on || st.state != SessionState::Recording {
            return Ok(());
        }
        let sid = current_sid(&st);
        let session = st.session.as_mut().expect("active session");
        if session.quick || !session.pins.is_empty() {
            return Ok(());
        }
        session.quick = true;
        self.inner.emit(&mut st, sid, EngineEvent::QuickMarked);
        Ok(())
    }

    /// Report the chord's physical state while a session records. A held
    /// chord suppresses the silence auto-end (ADR-0020) — the speaker is
    /// mid-gesture, and their release is what ends the session; paragraph
    /// marks keep flowing, so a held pause still closes a paragraph. A
    /// quiet no-op outside recording: the signal belongs to a live
    /// session, and a release that lands after the session moved on has
    /// nothing left to gate.
    fn hold_gate(&self, held: bool) -> Result<(), EngineError> {
        let mut st = self.inner.state_lock();
        if st.state != SessionState::Recording {
            return Ok(());
        }
        st.session.as_mut().expect("active session").hold_gate = held;
        Ok(())
    }

    fn cancel_session(&self) -> Result<(), EngineError> {
        let mut st = self.inner.state_lock();
        if !matches!(
            st.state,
            SessionState::Recording | SessionState::Rectifying | SessionState::Preview
        ) {
            return Err(EngineError::CommandRejected {
                command: Command::Cancel,
                state: st.state,
            });
        }
        let sid = current_sid(&st);
        let session = st.session.as_mut().expect("active session");
        session.asr_cancel.cancel();
        if let Some(cancel) = session.rectify_cancel.take() {
            cancel.cancel();
        }
        self.inner
            .finish_session(&mut st, sid, SessionState::Cancelled);
        Ok(())
    }

    /// `placeholders` is the confirm-time slot table, ferried to the
    /// recorder beside the session pair (a pass-through; see
    /// [`Command::ConfirmInsert`]).
    async fn confirm_insert(
        &self,
        placeholders: Vec<prefill::PlaceholderFill>,
    ) -> Result<(), EngineError> {
        let (sid, text, raw_transcript, scenario, source_session_id) = {
            let st = self.inner.state_lock();
            if st.state != SessionState::Preview {
                return Err(EngineError::CommandRejected {
                    command: Command::ConfirmInsert {
                        placeholders: Vec::new(),
                    },
                    state: st.state,
                });
            }
            let session = st.session.as_ref().expect("active session");
            let raw_transcript = session
                .frozen
                .as_ref()
                .expect("frozen before preview")
                .raw_transcript
                .clone();
            let scenario = Inner::session_scenario(session, &self.inner);
            (
                session.id,
                session.preview_text.clone(),
                raw_transcript,
                scenario,
                session.source_session_id,
            )
        };
        match self.inner.inserter.insert(&text).await {
            Ok(()) => {
                {
                    let mut st = self.inner.state_lock();
                    // The session cannot have changed: cancel needs the command
                    // gate too, and rectify tasks never touch `Preview`.
                    self.inner.emit(
                        &mut st,
                        sid,
                        EngineEvent::TextInserted { text: text.clone() },
                    );
                    self.inner
                        .finish_session(&mut st, sid, SessionState::Inserted);
                }
                // History hands over the session pair after the insert
                // feedback, so recording can never delay or fail it.
                if let Some(history) = &self.inner.history {
                    history.record(RecordedSession {
                        raw_transcript,
                        rectified_text: text,
                        scenario,
                        source_session_id,
                        placeholders,
                    });
                }
                Ok(())
            }
            Err(err) => {
                // Stay in preview: the user can retry, edit, or cancel.
                let mut st = self.inner.state_lock();
                self.inner.emit(
                    &mut st,
                    sid,
                    EngineEvent::Error {
                        message: err.to_string(),
                    },
                );
                Ok(())
            }
        }
    }

    fn update_preview_text(&self, text: String) -> Result<(), EngineError> {
        let mut st = self.inner.state_lock();
        if st.state != SessionState::Preview {
            return Err(EngineError::CommandRejected {
                command: Command::UpdatePreviewText(text.clone()),
                state: st.state,
            });
        }
        let sid = current_sid(&st);
        let session = st.session.as_mut().expect("active session");
        session.preview_text = text.clone();
        self.inner
            .emit(&mut st, sid, EngineEvent::PreviewTextUpdated { text });
        Ok(())
    }
}

impl Inner {
    fn state_lock(&self) -> MutexGuard<'_, SharedState> {
        self.state.lock().unwrap()
    }

    /// The hotword dictionary as it stands now. Read once per session
    /// start (and once per history re-rectify) so both injection paths of
    /// one session always agree.
    fn current_terms(&self) -> Vec<String> {
        self.terms.as_ref().map(|s| s.terms()).unwrap_or_default()
    }

    /// The style-directive text every rectify request stamps — read when
    /// each request is built, so a switch any time shapes the next
    /// attempt (first stop, reroll, and history re-rectify alike).
    fn current_style_directive(&self) -> Option<String> {
        self.style_directive.read().unwrap().clone()
    }

    /// The selection's name, read fresh beside its directive — never
    /// snapshotted, same live-read rule.
    fn current_style_scenario(&self) -> Option<String> {
        self.style_scenario.read().unwrap().clone()
    }

    /// The global directive every rectify request stamps — same live-read
    /// rule: never snapshotted into a session, so a change any time
    /// shapes the next attempt.
    fn current_global_directive(&self) -> Option<String> {
        self.global_directive.read().unwrap().clone()
    }

    /// The directive a request inside [session] runs with: the session's
    /// one-time pick if it has one, otherwise the live selection. A
    /// session pinned to the default register carries no directive at
    /// all — the same shape as a session with no scenario.
    fn session_style_directive(session: &Session, inner: &Inner) -> Option<String> {
        match &session.style {
            SessionStyle::Live => inner.current_style_directive(),
            SessionStyle::Directive { text, .. } => Some(text.clone()),
            SessionStyle::DefaultRegister => None,
        }
    }

    /// The scenario NAME a recorded session runs under — the same
    /// resolution rule as [`Inner::session_style_directive`], for the
    /// store to resolve into a scenario id (a pin without a name, like
    /// the CLI's raw directive, records as 未选场景).
    fn session_scenario(session: &Session, inner: &Inner) -> Option<String> {
        match &session.style {
            SessionStyle::Live => inner.current_style_scenario(),
            SessionStyle::Directive { scenario, .. } => scenario.clone(),
            SessionStyle::DefaultRegister => None,
        }
    }

    /// Passage mode for a session about to open — the runtime-switchable
    /// value, snapshotted into the session so later switches cannot
    /// change a running session's semantics.
    fn current_passage_mode(&self) -> bool {
        *self.passage_mode.read().unwrap()
    }

    /// The timings for a session about to open — same snapshot rule as
    /// [`Inner::current_passage_mode`].
    fn current_timings(&self) -> EngineTimings {
        *self.timings.read().unwrap()
    }

    /// The quick-rectify setting for a session about to open — same
    /// snapshot rule as [`Inner::current_passage_mode`].
    fn current_quick_rectify(&self) -> bool {
        *self.quick_rectify.read().unwrap()
    }

    /// Emit an event; the guard must be held so `seq` order can never
    /// diverge from send order.
    fn emit(&self, st: &mut SharedState, sid: SessionId, event: EngineEvent) {
        st.seq += 1;
        let envelope = EventEnvelope {
            seq: st.seq,
            session_id: sid,
            at_ms: self.clock.now_ms(),
            event,
        };
        // Sending without receivers is fine; slow receivers see Lagged.
        let _ = self.events.send(envelope);
    }

    fn transition(&self, st: &mut SharedState, sid: SessionId, to: SessionState) {
        let from = st.state;
        st.state = to;
        self.emit(st, sid, EngineEvent::SessionStateChanged { from, to });
    }

    /// Run a session through a transient terminal state (`Inserted` /
    /// `Cancelled`) and straight back to idle, releasing it. Terminal
    /// states never persist, so no session can wedge. A cancelled end
    /// also returns the keyboard: the panel borrowed the foreground, and
    /// the user expects to keep typing where they were (the insert path
    /// hands focus back itself while pasting).
    fn finish_session(&self, st: &mut SharedState, sid: SessionId, terminal: SessionState) {
        self.transition(st, sid, terminal);
        self.transition(st, sid, SessionState::Idle);
        st.session = None;
        if terminal == SessionState::Cancelled {
            self.inserter.restore_focus();
        }
    }

    /// Emit a session-stream event only while it is still meaningful.
    /// Stragglers from tasks that lost a race against cancel/stop are
    /// dropped instead of leaking after a terminal event.
    fn emit_stream_event(&self, st: &mut SharedState, sid: SessionId, event: EngineEvent) {
        let session_current = session_matches(st, sid);
        let allowed = match &event {
            EngineEvent::LiveTranscriptUpdated { .. }
            | EngineEvent::ParagraphMarked
            | EngineEvent::SpeechActivityChanged { .. } => st.state == SessionState::Recording,
            EngineEvent::RectifiedTextChunk { .. }
            | EngineEvent::RectifyThinkingDelta { .. }
            | EngineEvent::PreviewPrefills { .. } => st.state == SessionState::Rectifying,
            EngineEvent::PreviewTextUpdated { .. } => st.state == SessionState::Preview,
            _ => true,
        };
        if session_current && allowed {
            self.emit(st, sid, event);
        }
    }

    /// Abort a rectifying attempt after a failure. No-op if the session
    /// already moved on (e.g. cancelled concurrently).
    ///
    /// An ordinary session is discarded (error, then `Cancelled`). A
    /// quick-mode one degrades instead (ADR-0020): it enters `Preview`
    /// holding whatever it had streamed — [`streamed`], the text the shell
    /// already shows — with its quick flag cleared, so the reroll there
    /// and the confirm after it run the ordinary path and nothing
    /// auto-pastes. That is the safety net: the round's words survive the
    /// failure.
    ///
    /// [`streamed`]: crate::prefill::ResponseSplitter::streamed_body
    fn abort_rectifying(&self, sid: SessionId, message: String, streamed: String) {
        let mut st = self.state_lock();
        if st.state != SessionState::Rectifying || !session_matches(&st, sid) {
            return;
        }
        self.emit(&mut st, sid, EngineEvent::Error { message });
        let quick = st.session.as_ref().is_some_and(|session| session.quick);
        if !quick {
            self.finish_session(&mut st, sid, SessionState::Cancelled);
            return;
        }
        let session = st.session.as_mut().expect("active session");
        session.preview_text = streamed;
        session.quick = false;
        self.transition(&mut st, sid, SessionState::Preview);
    }
}

fn session_matches(st: &SharedState, sid: SessionId) -> bool {
    st.session.as_ref().is_some_and(|s| s.id == sid)
}

/// The user-facing message when the hard cap expires.
fn rectify_timeout_message(timeout_ms: u64) -> String {
    format!("rectify timed out after the {timeout_ms} ms hard cap; retry or cancel")
}

fn current_sid(st: &SharedState) -> SessionId {
    st.session.as_ref().expect("active session").id
}

/// One straight-through insert's inputs (ADR-0020): what goes in, for
/// which session, and from where.
struct Passthrough {
    session: SessionId,
    /// The text that goes in: the frozen raw transcript when quick mode
    /// runs without rectify, the model's body when it runs with it.
    text: String,
    /// The session's raw transcript, for the history pair.
    raw_transcript: String,
    /// The state the session must still be in for the insert to stand.
    /// Anything else means it moved on under us — cancelled, stopped
    /// again, already degraded — and the insert must not land.
    from: SessionState,
    /// Whether the shell still needs this text streamed to it. True for a
    /// round with no model output of its own: the shell builds the
    /// preview it shows out of the chunk stream, so a paste that degrades
    /// into preview must stream the very text confirm would insert.
    /// False when the text already streamed as chunks.
    announce: bool,
    /// The scenario name / source row for the history pair (pass-throughs
    /// resolved from the session at plan time).
    scenario: Option<String>,
    source_session_id: Option<i64>,
}

/// What a recording end (or a reroll) leads to.
enum Plan {
    /// The model rewrites the transcript; the session is already in
    /// `Rectifying`.
    Rectify {
        sid: SessionId,
        cancel: CancellationToken,
        request: RectifyRequest,
        timings: EngineTimings,
    },
    /// Quick mode with 启用修正 off: no model runs and the session never
    /// enters `Rectifying` — the frozen raw transcript goes straight to
    /// the inserter (ADR-0020).
    Paste(Passthrough),
}

/// Freeze the recorded raw transcript (on recording end) and spawn what
/// follows: a rectify attempt that lands in `Preview` (or inserts itself,
/// a quick pass-through), or — quick mode with 启用修正 off — the
/// straight-through paste of the raw transcript. Shared by manual stop,
/// silence auto-end (both from `Recording`), and reroll (from `Preview`).
/// No-op unless the session is in one of those states.
fn begin_rectify(inner: &Arc<Inner>) {
    let plan = {
        let mut st = inner.state_lock();
        let state = st.state;
        let Some(session) = st.session.as_mut() else {
            return;
        };
        let sid = session.id;
        let plan = match state {
            SessionState::Recording => {
                // The freeze splices pins through the same join the live
                // transcript uses — position is never computed twice — and
                // a pin-only current line counts as content, which is what
                // keeps a pin-only session alive.
                if !session.freeze() {
                    // A speechless session (noise only, nothing recognized):
                    // discard it rather than rectify or paste an empty
                    // utterance.
                    inner.finish_session(&mut st, sid, SessionState::Cancelled);
                    return;
                }
                if session.quick && !session.quick_rectify {
                    // Quick mode with 启用修正 off (ADR-0020): the frozen
                    // transcript is the whole round, and the state never
                    // leaves `Recording` — there is no `Rectifying` to
                    // enter. The text is also what the preview must hold
                    // if the insert fails.
                    let raw_transcript = session
                        .frozen
                        .as_ref()
                        .expect("just frozen above")
                        .raw_transcript
                        .clone();
                    Plan::Paste(Passthrough {
                        session: sid,
                        text: raw_transcript.clone(),
                        raw_transcript,
                        from: SessionState::Recording,
                        announce: true,
                        scenario: Inner::session_scenario(session, inner),
                        source_session_id: session.source_session_id,
                    })
                } else {
                    let frozen = session.frozen.as_ref().expect("just frozen above");
                    let raw_transcript = frozen.raw_transcript.clone();
                    let paragraphs = frozen.paragraphs.clone();
                    let cancel = CancellationToken::new();
                    session.rectify_cancel = Some(cancel.clone());
                    let terms = session.terms.clone();
                    let timings = session.timings;
                    // The session's own flag: an upgraded session's stop
                    // runs the quick assembly and inserts itself (ADR-0020).
                    let quick = session.quick;
                    let style_directive = Inner::session_style_directive(session, inner);
                    let global_directive = inner.current_global_directive();
                    Plan::Rectify {
                        sid,
                        cancel,
                        request: RectifyRequest {
                            raw_transcript,
                            paragraphs,
                            style_directive,
                            global_directive,
                            terms,
                            // The seam default: the production client
                            // applies the [llm] prefill config over this
                            // before composing (ADR-0014).
                            prefill: true,
                            quick,
                        },
                        timings,
                    }
                }
            }
            SessionState::Preview => {
                // Reroll: the transcript is already frozen, and the
                // session is never quick here — a quick attempt that
                // failed into preview cleared its flag on the way
                // (ADR-0020), so a reroll runs the ordinary path.
                let frozen = session.frozen.as_ref().expect("frozen before preview");
                let cancel = CancellationToken::new();
                session.rectify_cancel = Some(cancel.clone());
                let terms = session.terms.clone();
                let timings = session.timings;
                let style_directive = Inner::session_style_directive(session, inner);
                let global_directive = inner.current_global_directive();
                Plan::Rectify {
                    sid,
                    cancel,
                    request: RectifyRequest {
                        raw_transcript: frozen.raw_transcript.clone(),
                        paragraphs: frozen.paragraphs.clone(),
                        style_directive,
                        global_directive,
                        terms,
                        // The seam default: the production client applies
                        // the [llm] prefill config over this before
                        // composing (ADR-0014).
                        prefill: true,
                        quick: false,
                    },
                    timings,
                }
            }
            _ => return,
        };
        // Only a rectify attempt moves the machine: a straight-through
        // paste stays in `Recording` until its insert lands (ADR-0020).
        if matches!(plan, Plan::Rectify { .. }) {
            inner.transition(&mut st, sid, SessionState::Rectifying);
        }
        plan
    };
    match plan {
        Plan::Rectify {
            sid,
            cancel,
            request,
            timings,
        } => {
            let llm = inner.llm.read().unwrap().clone();
            tokio::spawn(rectify_task(
                inner.clone(),
                sid,
                llm,
                request,
                cancel,
                timings,
            ));
        }
        // The paste takes the command gate itself, so a cancel or a second
        // stop waits rather than racing the insert.
        Plan::Paste(pass) => {
            tokio::spawn(paste_task(inner.clone(), pass));
        }
    }
}

/// A straight-through insert as its own task: it takes the command gate
/// first, so a cancel or a stop waits rather than racing the insert — a
/// session must not change under it, the rule
/// [`Engine::confirm_insert`] runs under too.
async fn paste_task(inner: Arc<Inner>, pass: Passthrough) {
    let _gate = inner.command_gate.lock().await;
    paste_through(&inner, pass).await;
}

/// The straight-through insert (ADR-0020): the round's text goes to the
/// inserter with no preview and no confirmation, the session closes as
/// `Inserted`, and its pair reaches history.
///
/// A failure degrades instead of discarding: the session enters `Preview`
/// holding that same text — the safety net that keeps the round's words —
/// with its quick flag cleared, so the reroll there and the confirm after
/// it run the ordinary path and nothing auto-pastes again.
///
/// Runs with the command gate held (the caller's or [`paste_task`]'s): the
/// insert is the session's one irreversible step.
async fn paste_through(inner: &Arc<Inner>, pass: Passthrough) {
    let Passthrough {
        session: sid,
        text,
        raw_transcript,
        from,
        announce,
        scenario,
        source_session_id,
    } = pass;
    {
        // Re-checked under the gate: the session must still be exactly
        // where the paste was planned.
        let st = inner.state_lock();
        if st.state != from || !session_matches(&st, sid) {
            return;
        }
    }
    match inner.inserter.insert(&text).await {
        Ok(()) => {
            let mut st = inner.state_lock();
            inner.emit(
                &mut st,
                sid,
                EngineEvent::TextInserted { text: text.clone() },
            );
            inner.finish_session(&mut st, sid, SessionState::Inserted);
            drop(st);
            // History hands over the session pair after the insert
            // feedback, so recording can never delay or fail it. The
            // quick straight-through carries no slot table: its sessions
            // upgraded with nothing pinned and never minted a slot.
            if let Some(history) = &inner.history {
                history.record(RecordedSession {
                    raw_transcript,
                    rectified_text: text,
                    scenario,
                    source_session_id,
                    placeholders: Vec::new(),
                });
            }
        }
        Err(err) => {
            let mut st = inner.state_lock();
            inner.emit(
                &mut st,
                sid,
                EngineEvent::Error {
                    message: err.to_string(),
                },
            );
            if st.state != from || !session_matches(&st, sid) {
                return;
            }
            if announce {
                // This round had no model stream of its own, so the shell
                // has seen nothing of the text this preview is about to
                // hold: it rides the channel the shell accumulates, so the
                // box shows exactly what a confirm would insert.
                let delta = text.clone();
                inner.emit(&mut st, sid, EngineEvent::RectifiedTextChunk { delta });
            }
            let session = st.session.as_mut().expect("active session");
            session.preview_text = text;
            session.quick = false;
            inner.transition(&mut st, sid, SessionState::Preview);
        }
    }
}

impl Session {
    /// A fresh session: nothing said, nothing frozen, not quick. Both
    /// session openings (recording, history re-rectify) start from this
    /// shape, each snapshotting the dictionary, passage mode, timings,
    /// and quick-rectify setting as it opens.
    fn new(
        id: SessionId,
        terms: Vec<String>,
        passage_mode: bool,
        timings: EngineTimings,
        quick_rectify: bool,
    ) -> Self {
        Self {
            id,
            terms,
            passage_mode,
            timings,
            quick_rectify,
            paragraphs: Vec::new(),
            current_paragraph: String::new(),
            partial: String::new(),
            pins: Vec::new(),
            in_flight: None,
            paragraph_marked_current_silence: false,
            speech_since_mark: false,
            last_silence_ms: 0,
            silence_baseline_ms: 0,
            any_speech: false,
            frozen: None,
            style: SessionStyle::Live,
            source_session_id: None,
            quick: false,
            hold_gate: false,
            preview_text: String::new(),
            asr_cancel: CancellationToken::new(),
            rectify_cancel: None,
        }
    }

    /// Cumulative live transcript: the paragraph lines with pins spliced
    /// in, the current line carrying any interim partial appended after
    /// the finalized text. An empty current line is dropped as before —
    /// pins make it non-empty.
    fn live_text(&self) -> String {
        let mut lines = self.rendered_paragraphs();
        let current = lines
            .last_mut()
            .expect("the current line is always rendered");
        current.push_str(&self.partial);
        if current.is_empty() {
            lines.pop();
        }
        lines.join("\n")
    }

    /// The transcript's paragraph lines with every pin spliced in: the
    /// closed paragraphs in order, then the current paragraph as the
    /// virtual last line — included even when textless, because a
    /// pin-only line is content. The one join behind both the live
    /// transcript and the freeze, so the frozen paragraphs are never a
    /// second computation of position.
    fn rendered_paragraphs(&self) -> Vec<String> {
        let mut lines: Vec<String> = self
            .paragraphs
            .iter()
            .enumerate()
            .map(|(index, text)| self.splice_pins(index, text))
            .collect();
        lines.push(self.splice_pins(self.paragraphs.len(), &self.current_paragraph));
        lines
    }

    /// One paragraph with the pins anchored in it spliced in at their
    /// offsets. Pins only ever anchor at the then-current end, so
    /// sorting by offset is a no-op that merely makes the order explicit.
    ///
    /// The splice is also the pause-pin normalization (工单 35): the
    /// clause-final punctuation run immediately before a pin is deleted
    /// from the render. The recognizer finalizes a sentence mid-pause,
    /// so a pin pressed while the speaker reaches for the key lands
    /// behind its period — stripping the mark returns the in-sentence
    /// shape (`文件。‡1‡` renders `文件‡1‡`) every placeholder rule is
    /// written against. A render projection only: the raw strings and
    /// the anchors keep their bytes, only the pin's own line's left text
    /// is examined (a previous line's closing mark stays), a line-start
    /// pin has no left text, and same-offset stacked pins strip only
    /// the run ahead of the first of them.
    fn splice_pins(&self, index: usize, text: &str) -> String {
        let mut anchored: Vec<&Pin> = self
            .pins
            .iter()
            .filter(|pin| pin.anchor.paragraph == index)
            .collect();
        if anchored.is_empty() {
            return text.to_string();
        }
        anchored.sort_by_key(|pin| pin.anchor.offset);
        let mut spliced = String::with_capacity(text.len());
        let mut prev = 0;
        for pin in anchored {
            let slice = &text[prev..pin.anchor.offset];
            let strip = trailing_punctuation_len(slice);
            spliced.push_str(&slice[..slice.len() - strip]);
            spliced.push_str(&pin.sentinel());
            prev = pin.anchor.offset;
        }
        spliced.push_str(&text[prev..]);
        spliced
    }

    /// Pin a placeholder at the current end of the transcript. The anchor
    /// rides the paragraph structure, so the splice point stays put while
    /// later speech keeps folding in after the pin. A pin is not speech:
    /// the paragraph and discard rules never see it — but it does restart
    /// the paragraph-silence clock (工单 35): the recognizer finalizes the
    /// sentence while the speaker is still reaching for the key, so
    /// silence already banked by the reach must not close the paragraph
    /// around the pin. The session-end threshold is untouched by this.
    ///
    /// A draft in flight at the press becomes this pin's frozen left
    /// (ticket 16): the draft commits to the finalized side — the words on
    /// screen stay on screen — and the sentence's first non-empty Final is
    /// awaited under a snapshot constraint, so it cannot append the same
    /// words a second time. Pressing again under an open constraint
    /// stacks: the later pin freezes the tail collected so far, growing
    /// the snapshot by it.
    fn pin(&mut self) {
        if !self.partial.is_empty() {
            let draft = std::mem::take(&mut self.partial);
            self.current_paragraph.push_str(&draft);
            match &mut self.in_flight {
                Some(constraint) => constraint.snapshot.push_str(&draft),
                None => self.in_flight = Some(InFlight { snapshot: draft }),
            }
        }
        let anchor = if self.current_paragraph.is_empty() && !self.paragraphs.is_empty() {
            // Nothing new said since the last mark: the shown transcript
            // ends with the last closed paragraph, and so does the pin.
            PinAnchor {
                paragraph: self.paragraphs.len() - 1,
                offset: self.paragraphs.last().expect("checked non-empty").len(),
            }
        } else {
            // End of the current paragraph — offset 0 when it is empty:
            // the pin opens the paragraph, and speech said afterwards
            // lands after it. An in-flight press never reaches here with
            // an empty current paragraph: the draft it just committed
            // opens the row.
            PinAnchor {
                paragraph: self.paragraphs.len(),
                offset: self.current_paragraph.len(),
            }
        };
        let number = self.pins.len() + 1;
        self.pins.push(Pin { number, anchor });
        // The press rebases the paragraph-silence clock: the silence run
        // in flight keeps counting from zero as of now. The rebasing
        // point is the last reported elapsed — silence ticks arrive
        // periodically, so the estimate is only as stale as one tick.
        self.silence_baseline_ms = self.last_silence_ms;
    }

    /// Fold one interim frame into the partial. Under an open snapshot
    /// constraint the frame may only extend the frozen prefix: its
    /// remainder past the snapshot becomes the new tail. A frame that
    /// rewrites the frozen words — Volcano's no-utterance full-session
    /// restatement among them — is dropped whole: the tail keeps its last
    /// frame, and the constraint stands until the sentence's first
    /// non-empty Final decides it. Returns whether the transcript changed.
    fn fold_partial(&mut self, text: String) -> bool {
        match self.in_flight.as_ref() {
            Some(constraint) if !text.starts_with(&constraint.snapshot) => false,
            Some(constraint) => {
                self.partial = text[constraint.snapshot.len()..].to_string();
                true
            }
            None => {
                self.partial = text;
                true
            }
        }
    }

    /// Fold one finalized frame into the current paragraph. Under an open
    /// snapshot constraint this is the sentence's first non-empty Final,
    /// and it ends the constraint: matching the snapshot appends only the
    /// remainder past it (the pin's settled right); not matching appends
    /// the whole text after the pin as new finalized speech — the frozen
    /// left stays dead either way. An empty Final is ignored while the
    /// constraint stands: nothing was finalized, so the tail survives and
    /// only a non-empty Final may decide. Outside a constraint the fold is
    /// today's. Returns whether the transcript changed.
    fn fold_final(&mut self, text: String) -> bool {
        if let Some(constraint) = self.in_flight.take() {
            if text.is_empty() {
                self.in_flight = Some(constraint);
                return false;
            }
            let settled = if text.starts_with(&constraint.snapshot) {
                &text[constraint.snapshot.len()..]
            } else {
                text.as_str()
            };
            self.partial.clear();
            self.current_paragraph.push_str(settled);
            return true;
        }
        self.partial.clear();
        self.current_paragraph.push_str(&text);
        true
    }

    /// Freeze the recording into the session's utterance (recording end):
    /// the speech still in flight joins the transcript, pins splice
    /// through the same join the live transcript uses — position is never
    /// computed twice — and the ASR stream is cancelled. A pin-only
    /// current line counts as content, which is what keeps a pin-only
    /// session alive. Returns whether there is an utterance at all: a
    /// speechless session (noise only, nothing recognized) has nothing to
    /// rectify or paste, so the caller discards it.
    fn freeze(&mut self) -> bool {
        self.asr_cancel.cancel();
        // Speech still in flight when recording ended: the user said it,
        // so the fidelity rule keeps it in the transcript.
        self.current_paragraph.push_str(&self.partial);
        self.partial.clear();
        let mut paragraphs = self.rendered_paragraphs();
        let current = paragraphs
            .pop()
            .expect("the current line is always rendered");
        if !current.is_empty() {
            paragraphs.push(current);
        }
        let raw_transcript = paragraphs.join("\n");
        if raw_transcript.is_empty() && !self.any_speech {
            return false;
        }
        self.frozen = Some(FrozenUtterance {
            raw_transcript,
            paragraphs,
        });
        true
    }

    /// Speech happened (transcript or VAD activity): re-arm the paragraph
    /// marker for the next silence run and remember the session had
    /// content. Speech also restarts the recognizer's silence run from
    /// zero, so the rebasing point and the last-seen elapsed follow it.
    fn note_speech(&mut self) {
        self.paragraph_marked_current_silence = false;
        self.speech_since_mark = true;
        self.any_speech = true;
        self.last_silence_ms = 0;
        self.silence_baseline_ms = 0;
    }
}

/// The length, in bytes, of the run of clause-final punctuation at the
/// end of `text` — the marks a recognizer stamps when it finalizes a
/// sentence mid-pause, full- and half-width alike. The pin splice
/// deletes this run from the render ahead of the pin (工单 35).
fn trailing_punctuation_len(text: &str) -> usize {
    let mut len = 0;
    for ch in text.chars().rev() {
        if !is_clause_punctuation(ch) {
            break;
        }
        len += ch.len_utf8();
    }
    len
}

/// Whether `ch` is a clause-final mark: period, question, exclamation,
/// comma, enumeration comma, semicolon, colon, or ellipsis — the set the
/// recognizer uses to close a sentence or clause, in either width.
fn is_clause_punctuation(ch: char) -> bool {
    matches!(
        ch,
        '。' | '．'
            | '.'
            | '！'
            | '!'
            | '？'
            | '?'
            | '，'
            | ','
            | '、'
            | '；'
            | ';'
            | '：'
            | ':'
            | '…'
    )
}

/// Consume the ASR event stream of one session: forward transcript updates,
/// apply silence rules (paragraph mark / auto-end), and stop when the
/// session's cancellation token fires.
async fn consume_asr(
    inner: Arc<Inner>,
    sid: SessionId,
    stream: BoxStream<'static, AsrEvent>,
    cancel: CancellationToken,
) {
    let mut stream = Box::pin(stream);
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => break,
            maybe = stream.next() => {
                let Some(event) = maybe else { break };
                let mut st = inner.state_lock();
                if !session_matches(&st, sid) || st.state != SessionState::Recording {
                    break;
                }
                let session = st.session.as_mut().expect("active session");
                match event {
                    AsrEvent::Partial { text } => {
                        if session.fold_partial(text) {
                            session.note_speech();
                            let live = session.live_text();
                            inner.emit_stream_event(&mut st, sid, EngineEvent::LiveTranscriptUpdated { text: live });
                        }
                    }
                    AsrEvent::Final { text } => {
                        if session.fold_final(text) {
                            session.note_speech();
                            let live = session.live_text();
                            inner.emit_stream_event(&mut st, sid, EngineEvent::LiveTranscriptUpdated { text: live });
                        }
                    }
                    AsrEvent::Silence { elapsed_ms } => {
                        session.last_silence_ms = elapsed_ms;
                        if session.passage_mode {
                            // Only mark a paragraph when speech happened
                            // since the last mark: silence before talking
                            // marks nothing. Transcript text is not required
                            // — until the real ASR adapter lands, VAD speech
                            // bursts alone carry the paragraph structure.
                            // While a pin's snapshot constraint is open, the
                            // pinned row must not split — the sentence is
                            // still resolving around the pin — so the mark
                            // waits. Rows closed before the pin stay closed
                            // either way; nothing here reopens them. The
                            // threshold is judged on the silence accumulated
                            // since the last pin press (工单 35): a press
                            // mid-pause restarts the paragraph clock, so the
                            // reach for the key cannot close the paragraph
                            // around the pin. The session-end threshold
                            // below keeps the raw elapsed.
                            let since_press_ms =
                                elapsed_ms.saturating_sub(session.silence_baseline_ms);
                            if since_press_ms >= session.timings.paragraph_silence_ms
                                && session.speech_since_mark
                                && !session.paragraph_marked_current_silence
                                && session.in_flight.is_none()
                            {
                                session.paragraph_marked_current_silence = true;
                                session.speech_since_mark = false;
                                if !session.current_paragraph.is_empty() {
                                    session.paragraphs.push(std::mem::take(&mut session.current_paragraph));
                                }
                                inner.emit_stream_event(&mut st, sid, EngineEvent::ParagraphMarked);
                            }
                        } else if elapsed_ms >= session.timings.session_end_silence_ms
                            && !session.hold_gate
                        {
                            // The held chord suppresses the auto-end
                            // (ADR-0020): a speaker holding the key
                            // through a long pause has not finished, and
                            // their release is what ends the session.
                            // Paragraph marks above are untouched — a
                            // held pause still closes a paragraph in
                            // passage mode.
                            drop(st);
                            // Auto-end: same path as a manual stop.
                            begin_rectify(&inner);
                            break;
                        }
                    }
                    AsrEvent::SpeechActivity { speaking } => {
                        if speaking {
                            // The user resumed talking: re-arm the marker
                            // even with no transcript event in between.
                            session.note_speech();
                        }
                        inner.emit_stream_event(
                            &mut st,
                            sid,
                            EngineEvent::SpeechActivityChanged { speaking },
                        );
                    }
                    AsrEvent::Failed { message } => {
                        // e.g. the microphone vanished mid-session: end with
                        // feedback instead of wedging in Recording.
                        inner.emit_stream_event(&mut st, sid, EngineEvent::Error { message });
                        inner.finish_session(&mut st, sid, SessionState::Cancelled);
                        break;
                    }
                }
            }
        }
    }
}

/// Stream one rectify attempt: token deltas out as
/// [`EngineEvent::RectifiedTextChunk`], then `Preview`; errors abort the
/// session. A quick attempt (ADR-0020) skips the preview — the body is
/// inserted as it stands — and any failure of it degrades into preview
/// holding what streamed, instead of discarding the session. The attempt
/// runs under the session's snapshotted wall-clock hard cap (fresh per
/// attempt, rerolls included); expiry aborts with a visible error. Exits
/// silently if the attempt is cancelled or superseded.
async fn rectify_task(
    inner: Arc<Inner>,
    sid: SessionId,
    llm: Arc<dyn RectifyLlm>,
    request: RectifyRequest,
    cancel: CancellationToken,
    timings: EngineTimings,
) {
    let cap = std::time::Duration::from_millis(timings.rectify_timeout_ms);
    let deadline = tokio::time::Instant::now() + cap;
    // Read before the request moves into the LLM call: the sentinel
    // census decides whether this response gets split at all, and the
    // quick flag decides where a finished stream lands (ADR-0020).
    let pins_present = prefill::has_placeholders(&request.raw_transcript);
    let quick = request.quick;
    let stream: RectifyTokenStream = tokio::select! {
        biased;
        _ = cancel.cancelled() => return,
        _ = tokio::time::sleep_until(deadline) => {
            // Nothing streamed yet, so the degraded preview is empty.
            inner.abort_rectifying(
                sid,
                rectify_timeout_message(timings.rectify_timeout_ms),
                String::new(),
            );
            return;
        }
        stream = llm.rectify(request) => match stream {
            Ok(stream) => stream,
            Err(err) => {
                inner.abort_rectifying(sid, format!("rectify failed: {}", err.0), String::new());
                return;
            }
        }
    };
    let mut stream = Box::pin(stream);
    // A pin request's response carries inline prefill forms (`‡N:值‡`,
    // ruling 26): the splitter streams the body verbatim, holding only a
    // half-grown sentinel run so `‡N` fragments never flash, and hands
    // the parsed rows over as the preview's prefill table. Pin-less
    // requests keep the exact pre-placeholder path — same chunks, same
    // bytes.
    let mut splitter = prefill::ResponseSplitter::new(pins_present);
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return,
            _ = tokio::time::sleep_until(deadline) => {
                inner.abort_rectifying(
                    sid,
                    rectify_timeout_message(timings.rectify_timeout_ms),
                    splitter.streamed_body().to_string(),
                );
                return;
            }
            item = stream.next() => {
                match item {
                    Some(Ok(item)) => {
                        // Thinking text rides its own one-shot channel
                        // (14 号票): forwarded verbatim, never through the
                        // splitter, never into the body.
                        if let Some(delta) = item.reasoning {
                            let mut st = inner.state_lock();
                            if st.state != SessionState::Rectifying
                                || !session_matches(&st, sid)
                            {
                                return;
                            }
                            inner.emit_stream_event(
                                &mut st,
                                sid,
                                EngineEvent::RectifyThinkingDelta { delta },
                            );
                        }
                        let Some(delta) = item.content else {
                            // A thinking-only item (or a keep-alive): the
                            // cancel/supersede check rides the next
                            // producing delta or the stream's end.
                            continue;
                        };
                        let out = splitter.push(&delta);
                        if out.is_empty() {
                            // Fully held back (a `‡N` run still growing):
                            // nothing streams; a cancel or supersede is
                            // caught on the next producing delta or at
                            // the stream's end.
                            continue;
                        }
                        let mut st = inner.state_lock();
                        if st.state != SessionState::Rectifying || !session_matches(&st, sid) {
                            return;
                        }
                        inner.emit_stream_event(&mut st, sid, EngineEvent::RectifiedTextChunk { delta: out });
                    }
                    Some(Err(err)) => {
                        inner.abort_rectifying(
                            sid,
                            format!("rectify stream failed: {}", err.0),
                            splitter.streamed_body().to_string(),
                        );
                        return;
                    }
                    None => {
                        let (body, prefills) = splitter.finish();
                        if quick {
                            // Quick mode's straight-through (ADR-0020):
                            // the body is inserted as it stands, with no
                            // preview and no confirmation. The shell
                            // already accumulated it as it streamed, so
                            // nothing needs announcing. The lock is
                            // scoped away before the insert: the gate
                            // goes on first, because the session must not
                            // change under it.
                            let pass = {
                                let mut st = inner.state_lock();
                                if st.state != SessionState::Rectifying
                                    || !session_matches(&st, sid)
                                {
                                    return;
                                }
                                let session = st.session.as_mut().expect("active session");
                                session.preview_text = body;
                                let raw_transcript = session
                                    .frozen
                                    .as_ref()
                                    .expect("frozen before rectifying")
                                    .raw_transcript
                                    .clone();
                                Passthrough {
                                    session: sid,
                                    text: session.preview_text.clone(),
                                    raw_transcript,
                                    from: SessionState::Rectifying,
                                    announce: false,
                                    scenario: Inner::session_scenario(session, &inner),
                                    source_session_id: session.source_session_id,
                                }
                            };
                            let _gate = inner.command_gate.lock().await;
                            paste_through(&inner, pass).await;
                            return;
                        }
                        let mut st = inner.state_lock();
                        if st.state != SessionState::Rectifying || !session_matches(&st, sid) {
                            return;
                        }
                        st.session
                            .as_mut()
                            .expect("active session")
                            .preview_text = body;
                        if let Some(prefills) = prefills {
                            // Ahead of the Preview state change, so the
                            // shell paints the entering preview with the
                            // table already in hand; empty when the model
                            // sent no parseable block.
                            inner.emit_stream_event(&mut st, sid, EngineEvent::PreviewPrefills { prefills });
                        }
                        inner.transition(&mut st, sid, SessionState::Preview);
                        return;
                    }
                }
            }
        }
    }
}
