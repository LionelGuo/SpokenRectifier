//! The engine: session state machine over injectable collaborators.
//!
//! Commands in ([`Engine::execute`]), events out ([`Engine::subscribe`]).
//! States: `Idle → Recording → Rectifying → Preview → Inserted|Cancelled →
//! Idle` (or straight `Idle → Rectifying` via [`Command::RectifyText`],
//! history retrieval re-running a past utterance), with `Cancel` valid in
//! every active state. `Inserted` and
//! `Cancelled` are transient — the engine immediately continues to `Idle`,
//! so every state has an exit and no session can wedge.
//!
//! The recording session's transcript accumulation lives in
//! [`crate::session`]; the background tasks (ASR consumption, rectify
//! attempts, the straight-through paste) in [`crate::tasks`].

use std::sync::{Arc, Mutex, MutexGuard, RwLock};

use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use crate::clock::Clock;
use crate::command::{Command, SessionStyle};
use crate::config::{EngineConfig, EngineTimings};
use crate::event::{EngineEvent, EventEnvelope, SessionId, SessionState};
use crate::prefill;
use crate::provider::asr::AsrProvider;
use crate::provider::history::{RecordedSession, SessionRecorder};
use crate::provider::inserter::TextInserter;
use crate::provider::llm::{RectifyLlm, RectifyRequest};
use crate::provider::terms::TermSource;
use crate::session::{FrozenUtterance, Session};
use crate::tasks::{begin_rectify, consume_asr, rectify_task};

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
}

#[derive(Clone)]
pub struct Engine {
    inner: Arc<Inner>,
}

pub(crate) struct Inner {
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
    /// Wall-clock budget for one session's stream open (see
    /// [`EngineConfig::open_budget_ms`]): the watchdog that keeps a
    /// wedged open (device graph, network) from becoming a session that
    /// listens forever with no events.
    open_budget_ms: u64,
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
    pub(crate) llm: RwLock<Arc<dyn RectifyLlm>>,
    pub(crate) inserter: Arc<dyn TextInserter>,
    pub(crate) history: Option<Arc<dyn SessionRecorder>>,
    terms: Option<Arc<dyn TermSource>>,
    clock: Arc<dyn Clock>,
    events: broadcast::Sender<EventEnvelope>,
    /// Serializes command handling; background tasks never take it, so
    /// they cannot deadlock against a command waiting on them.
    pub(crate) command_gate: tokio::sync::Mutex<()>,
    state: Mutex<SharedState>,
}

pub(crate) struct SharedState {
    pub(crate) state: SessionState,
    next_session_id: u64,
    seq: u64,
    pub(crate) session: Option<Session>,
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
                open_budget_ms: config.open_budget_ms,
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
        let inner = self.inner.clone();
        let (sid, cancel) = {
            let mut st = inner.state_lock();
            // The command gate serializes commands, so we are still idle.
            let id = SessionId(st.next_session_id);
            st.next_session_id += 1;
            let session = Session::new(
                id,
                terms.clone(),
                inner.current_passage_mode(),
                inner.current_timings(),
                inner.current_quick_rectify(),
            );
            let cancel = session.asr_cancel.clone();
            st.session = Some(session);
            // Recording begins the moment the session exists (07): the
            // card's appearance, the command's reply, and every later
            // command must not queue behind the microphone open and the
            // provider handshake — the network leg runs below, off this
            // critical path.
            inner.transition(&mut st, id, SessionState::Recording);
            (id, cancel)
        };
        // The open runs on its own task: a stop or cancel during the
        // handshake aborts it through the same token consume_asr listens
        // to, and an open failure surfaces as the session-stream failure
        // every mid-session failure already uses (Error event + a
        // cancelled end, focus restored with it). The whole leg runs
        // under the open budget (26 号票): collaborators that wedge —
        // a device graph that never finishes opening the microphone, a
        // network leg that never answers — become that same visible
        // failure instead of a session that listens forever with no
        // events.
        let budget_ms = self.inner.open_budget_ms;
        tokio::spawn(async move {
            let budget = std::time::Duration::from_millis(budget_ms);
            tokio::select! {
                biased;
                _ = cancel.cancelled() => {}
                opened = tokio::time::timeout(budget, asr.open_stream(&terms)) => match opened {
                    Ok(Ok(stream)) => {
                        let st = inner.state_lock();
                        if session_matches(&st, sid) && st.state == SessionState::Recording {
                            drop(st);
                            tokio::spawn(consume_asr(inner, sid, stream, cancel));
                        }
                    }
                    Ok(Err(err)) => {
                        let mut st = inner.state_lock();
                        if session_matches(&st, sid) && st.state == SessionState::Recording {
                            inner.emit_stream_event(
                                &mut st,
                                sid,
                                EngineEvent::Error { message: err.to_string() },
                            );
                            inner.finish_session(&mut st, sid, SessionState::Cancelled);
                        }
                    }
                    Err(_) => {
                        let mut st = inner.state_lock();
                        if session_matches(&st, sid) && st.state == SessionState::Recording {
                            inner.emit_stream_event(
                                &mut st,
                                sid,
                                EngineEvent::Error {
                                    message: format!(
                                        "opening the recognizer timed out after {budget_ms} ms; \
                                         retry the session"
                                    ),
                                },
                            );
                            inner.finish_session(&mut st, sid, SessionState::Cancelled);
                        }
                    }
                }
            }
        });
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
    pub(crate) fn state_lock(&self) -> MutexGuard<'_, SharedState> {
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
    pub(crate) fn current_global_directive(&self) -> Option<String> {
        self.global_directive.read().unwrap().clone()
    }

    /// The directive a request inside [session] runs with: the session's
    /// one-time pick if it has one, otherwise the live selection. A
    /// session pinned to the default register carries no directive at
    /// all — the same shape as a session with no scenario.
    pub(crate) fn session_style_directive(session: &Session, inner: &Inner) -> Option<String> {
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
    pub(crate) fn session_scenario(session: &Session, inner: &Inner) -> Option<String> {
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
    pub(crate) fn emit(&self, st: &mut SharedState, sid: SessionId, event: EngineEvent) {
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

    pub(crate) fn transition(&self, st: &mut SharedState, sid: SessionId, to: SessionState) {
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
    pub(crate) fn finish_session(
        &self,
        st: &mut SharedState,
        sid: SessionId,
        terminal: SessionState,
    ) {
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
    pub(crate) fn emit_stream_event(
        &self,
        st: &mut SharedState,
        sid: SessionId,
        event: EngineEvent,
    ) {
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
    pub(crate) fn abort_rectifying(&self, sid: SessionId, message: String, streamed: String) {
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

pub(crate) fn session_matches(st: &SharedState, sid: SessionId) -> bool {
    st.session.as_ref().is_some_and(|s| s.id == sid)
}

fn current_sid(st: &SharedState) -> SessionId {
    st.session.as_ref().expect("active session").id
}
