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
use crate::command::Command;
use crate::config::{EngineConfig, EngineTimings};
use crate::event::{EngineEvent, EventEnvelope, SessionId, SessionState};
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
    /// Whether the current silence run already emitted a paragraph mark.
    paragraph_marked_current_silence: bool,
    /// Speech happened since the last paragraph mark (VAD activity or
    /// transcript events) — the next threshold silence closes a paragraph.
    speech_since_mark: bool,
    /// Any speech at all this session. A session with none is discarded on
    /// stop/auto-end instead of rectifying an empty utterance.
    any_speech: bool,
    /// Raw transcript frozen when recording ended.
    frozen: Option<FrozenUtterance>,
    /// The one-time style directive this session was re-rectified under
    /// (ticket 23's 指定场景); `None` on mic sessions and plain
    /// re-rectifies, which follow the live selection instead. Pinned for
    /// the session's lifetime: rerolls keep it, and it dies with the
    /// session.
    style_override: Option<String>,
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

impl Engine {
    pub fn new(config: EngineConfig, deps: EngineDeps) -> Self {
        let (events, _) = broadcast::channel(1024);
        Self {
            inner: Arc::new(Inner {
                style_directive: RwLock::new(None),
                passage_mode: RwLock::new(config.passage_mode),
                timings: RwLock::new(config.timings()),
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
                style_override,
            } => self.rectify_text(raw_transcript, style_override),
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
            Command::Cancel => self.cancel_session(),
            Command::ConfirmInsert => self.confirm_insert().await,
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
            Command::SetStyleDirective(directive) => {
                // Blank directive text reads as no directive: the default
                // register. (Scenario entries with blank directives are
                // already filtered by the library loader; this guards the
                // engine seam itself.)
                *self.inner.style_directive.write().unwrap() =
                    directive.filter(|text| !text.trim().is_empty());
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
    /// `style_override` optionally pins a one-time directive for this
    /// session alone (see [`Command::RectifyText`]).
    fn rectify_text(
        &self,
        raw_transcript: String,
        style_override: Option<String>,
    ) -> Result<(), EngineError> {
        let (sid, cancel, request, timings) = {
            let mut st = self.inner.state_lock();
            if st.state != SessionState::Idle {
                return Err(EngineError::CommandRejected {
                    command: Command::RectifyText {
                        raw_transcript,
                        style_override,
                    },
                    state: st.state,
                });
            }
            if raw_transcript.trim().is_empty() {
                return Err(EngineError::EmptyUtterance);
            }
            // Same blank guard as SetStyleDirective's: whitespace-only
            // override text reads as no override.
            let style_override = style_override.filter(|text| !text.trim().is_empty());
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
            );
            session.frozen = Some(FrozenUtterance {
                raw_transcript: raw_transcript.clone(),
                paragraphs: paragraphs.clone(),
            });
            session.style_override = style_override;
            let cancel = CancellationToken::new();
            session.rectify_cancel = Some(cancel.clone());
            let sid = session.id;
            let terms = session.terms.clone();
            let timings = session.timings;
            let style_directive = Inner::session_style_directive(&session, &self.inner);
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
                    terms,
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

    async fn confirm_insert(&self) -> Result<(), EngineError> {
        let (sid, text, raw_transcript) = {
            let st = self.inner.state_lock();
            if st.state != SessionState::Preview {
                return Err(EngineError::CommandRejected {
                    command: Command::ConfirmInsert,
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
            (session.id, session.preview_text.clone(), raw_transcript)
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

    /// The directive a request inside [session] runs with: the session's
    /// one-time override if it has one, otherwise the live selection.
    fn session_style_directive(session: &Session, inner: &Inner) -> Option<String> {
        session
            .style_override
            .clone()
            .or_else(|| inner.current_style_directive())
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
            EngineEvent::RectifiedTextChunk { .. } => st.state == SessionState::Rectifying,
            EngineEvent::PreviewTextUpdated { .. } => st.state == SessionState::Preview,
            _ => true,
        };
        if session_current && allowed {
            self.emit(st, sid, event);
        }
    }

    /// Abort a rectifying session after a failure. No-op if the session
    /// already moved on (e.g. cancelled concurrently).
    fn abort_rectifying(&self, sid: SessionId, message: String) {
        let mut st = self.state_lock();
        if st.state != SessionState::Rectifying || !session_matches(&st, sid) {
            return;
        }
        self.emit(&mut st, sid, EngineEvent::Error { message });
        self.finish_session(&mut st, sid, SessionState::Cancelled);
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

/// Freeze the recorded raw transcript (on recording end), move to
/// `Rectifying`, and spawn a rectify attempt. Shared by manual stop,
/// silence auto-end (both from `Recording`), and reroll (from `Preview`).
/// No-op unless the session is in one of those states.
fn begin_rectify(inner: &Arc<Inner>) {
    let (sid, cancel, request, timings) = {
        let mut st = inner.state_lock();
        let state = st.state;
        let Some(session) = st.session.as_mut() else {
            return;
        };
        let sid = session.id;
        let (cancel, request, timings) = match state {
            SessionState::Recording => {
                session.asr_cancel.cancel();
                let mut paragraphs = std::mem::take(&mut session.paragraphs);
                // Speech still in flight when recording ended: the user
                // said it, so the fidelity rule keeps it in the transcript.
                session.current_paragraph.push_str(&session.partial);
                session.partial.clear();
                let current = std::mem::take(&mut session.current_paragraph);
                if !current.is_empty() {
                    paragraphs.push(current);
                }
                let raw_transcript = paragraphs.join("\n");
                if raw_transcript.is_empty() && !session.any_speech {
                    // A speechless session (noise only, nothing recognized):
                    // discard it rather than rectify an empty utterance.
                    inner.finish_session(&mut st, sid, SessionState::Cancelled);
                    return;
                }
                session.frozen = Some(FrozenUtterance {
                    raw_transcript: raw_transcript.clone(),
                    paragraphs: paragraphs.clone(),
                });
                let cancel = CancellationToken::new();
                session.rectify_cancel = Some(cancel.clone());
                let terms = session.terms.clone();
                let timings = session.timings;
                let style_directive = Inner::session_style_directive(session, inner);
                (
                    cancel,
                    RectifyRequest {
                        raw_transcript,
                        paragraphs,
                        style_directive,
                        terms,
                    },
                    timings,
                )
            }
            SessionState::Preview => {
                // Reroll: the transcript is already frozen.
                let frozen = session.frozen.as_ref().expect("frozen before preview");
                let cancel = CancellationToken::new();
                session.rectify_cancel = Some(cancel.clone());
                let terms = session.terms.clone();
                let timings = session.timings;
                let style_directive = Inner::session_style_directive(session, inner);
                (
                    cancel,
                    RectifyRequest {
                        raw_transcript: frozen.raw_transcript.clone(),
                        paragraphs: frozen.paragraphs.clone(),
                        style_directive,
                        terms,
                    },
                    timings,
                )
            }
            _ => return,
        };
        inner.transition(&mut st, sid, SessionState::Rectifying);
        (sid, cancel, request, timings)
    };
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

impl Session {
    /// A fresh session: nothing said, nothing frozen. Both session
    /// openings (recording, history re-rectify) start from this shape,
    /// each snapshotting the dictionary, passage mode, and timings as it
    /// opens.
    fn new(id: SessionId, terms: Vec<String>, passage_mode: bool, timings: EngineTimings) -> Self {
        Self {
            id,
            terms,
            passage_mode,
            timings,
            paragraphs: Vec::new(),
            current_paragraph: String::new(),
            partial: String::new(),
            paragraph_marked_current_silence: false,
            speech_since_mark: false,
            any_speech: false,
            frozen: None,
            style_override: None,
            preview_text: String::new(),
            asr_cancel: CancellationToken::new(),
            rectify_cancel: None,
        }
    }

    /// Cumulative live transcript: closed paragraphs, then the current
    /// paragraph with any interim partial appended on the same line.
    fn live_text(&self) -> String {
        let current = format!("{}{}", self.current_paragraph, self.partial);
        let mut text = self.paragraphs.join("\n");
        if !current.is_empty() {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&current);
        }
        text
    }

    /// Speech happened (transcript or VAD activity): re-arm the paragraph
    /// marker for the next silence run and remember the session had
    /// content.
    fn note_speech(&mut self) {
        self.paragraph_marked_current_silence = false;
        self.speech_since_mark = true;
        self.any_speech = true;
    }
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
                        session.partial = text;
                        session.note_speech();
                        let live = session.live_text();
                        inner.emit_stream_event(&mut st, sid, EngineEvent::LiveTranscriptUpdated { text: live });
                    }
                    AsrEvent::Final { text } => {
                        session.partial.clear();
                        session.current_paragraph.push_str(&text);
                        session.note_speech();
                        let live = session.live_text();
                        inner.emit_stream_event(&mut st, sid, EngineEvent::LiveTranscriptUpdated { text: live });
                    }
                    AsrEvent::Silence { elapsed_ms } => {
                        if session.passage_mode {
                            // Only mark a paragraph when speech happened
                            // since the last mark: silence before talking
                            // marks nothing. Transcript text is not required
                            // — until the real ASR adapter lands, VAD speech
                            // bursts alone carry the paragraph structure.
                            if elapsed_ms >= session.timings.paragraph_silence_ms
                                && session.speech_since_mark
                                && !session.paragraph_marked_current_silence
                            {
                                session.paragraph_marked_current_silence = true;
                                session.speech_since_mark = false;
                                if !session.current_paragraph.is_empty() {
                                    session.paragraphs.push(std::mem::take(&mut session.current_paragraph));
                                }
                                inner.emit_stream_event(&mut st, sid, EngineEvent::ParagraphMarked);
                            }
                        } else if elapsed_ms >= session.timings.session_end_silence_ms {
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
/// session. The attempt runs under the session's snapshotted wall-clock
/// hard cap (fresh per attempt, rerolls included); expiry aborts with a
/// visible error. Exits silently if the attempt is cancelled or
/// superseded.
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
    let stream: RectifyTokenStream = tokio::select! {
        biased;
        _ = cancel.cancelled() => return,
        _ = tokio::time::sleep_until(deadline) => {
            inner.abort_rectifying(sid, rectify_timeout_message(timings.rectify_timeout_ms));
            return;
        }
        stream = llm.rectify(request) => match stream {
            Ok(stream) => stream,
            Err(err) => {
                inner.abort_rectifying(sid, format!("rectify failed: {}", err.0));
                return;
            }
        }
    };
    let mut stream = Box::pin(stream);
    let mut accumulated = String::new();
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return,
            _ = tokio::time::sleep_until(deadline) => {
                inner.abort_rectifying(sid, rectify_timeout_message(timings.rectify_timeout_ms));
                return;
            }
            item = stream.next() => {
                match item {
                    Some(Ok(delta)) => {
                        accumulated.push_str(&delta);
                        let mut st = inner.state_lock();
                        if st.state != SessionState::Rectifying || !session_matches(&st, sid) {
                            return;
                        }
                        inner.emit_stream_event(&mut st, sid, EngineEvent::RectifiedTextChunk { delta });
                    }
                    Some(Err(err)) => {
                        inner.abort_rectifying(sid, format!("rectify stream failed: {}", err.0));
                        return;
                    }
                    None => {
                        let mut st = inner.state_lock();
                        if st.state != SessionState::Rectifying || !session_matches(&st, sid) {
                            return;
                        }
                        let session = st.session.as_mut().expect("active session");
                        session.preview_text = accumulated;
                        inner.transition(&mut st, sid, SessionState::Preview);
                        return;
                    }
                }
            }
        }
    }
}
