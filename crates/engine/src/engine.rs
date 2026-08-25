//! The engine: session state machine over injectable collaborators.
//!
//! Commands in ([`Engine::execute`]), events out ([`Engine::subscribe`]).
//! States: `Idle → Recording → Rectifying → Preview → Inserted|Cancelled →
//! Idle`, with `Cancel` valid in every active state. `Inserted` and
//! `Cancelled` are transient — the engine immediately continues to `Idle`,
//! so every state has an exit and no session can wedge.

use std::sync::{Arc, Mutex, MutexGuard, RwLock};

use futures::stream::{BoxStream, StreamExt};
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use crate::clock::Clock;
use crate::command::Command;
use crate::config::EngineConfig;
use crate::event::{EngineEvent, EventEnvelope, SessionId, SessionState};
use crate::provider::asr::{AsrEvent, AsrOpenError, AsrProvider};
use crate::provider::inserter::TextInserter;
use crate::provider::llm::{RectifyLlm, RectifyRequest, RectifyTokenStream};
use crate::style::Style;

/// Collaborators the engine is constructed with.
pub struct EngineDeps {
    pub asr: Arc<dyn AsrProvider>,
    pub llm: Arc<dyn RectifyLlm>,
    pub inserter: Arc<dyn TextInserter>,
    pub clock: Arc<dyn Clock>,
}

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("command {command:?} rejected in state {state}")]
    CommandRejected {
        command: Command,
        state: SessionState,
    },
    #[error(transparent)]
    AsrOpen(#[from] AsrOpenError),
}

pub struct Engine {
    inner: Arc<Inner>,
}

struct Inner {
    config: EngineConfig,
    style: RwLock<Style>,
    asr: Arc<dyn AsrProvider>,
    llm: Arc<dyn RectifyLlm>,
    inserter: Arc<dyn TextInserter>,
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
                style: RwLock::new(config.style),
                config,
                asr: deps.asr,
                llm: deps.llm,
                inserter: deps.inserter,
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

    /// Submit a command. Returns `Err` only for rejected commands (wrong
    /// state, ASR could not be opened); asynchronous outcomes arrive as
    /// events.
    pub async fn execute(&self, command: Command) -> Result<(), EngineError> {
        let _gate = self.inner.command_gate.lock().await;
        match command.clone() {
            Command::StartSession => self.start_session().await,
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
            Command::SetStyle(style) => {
                *self.inner.style.write().unwrap() = style;
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
        let stream = self.inner.asr.open_stream().await?;
        let (sid, cancel) = {
            let mut st = self.inner.state_lock();
            // The command gate serializes commands, so we are still idle.
            let id = SessionId(st.next_session_id);
            st.next_session_id += 1;
            let session = Session {
                id,
                paragraphs: Vec::new(),
                current_paragraph: String::new(),
                partial: String::new(),
                paragraph_marked_current_silence: false,
                speech_since_mark: false,
                any_speech: false,
                frozen: None,
                preview_text: String::new(),
                asr_cancel: CancellationToken::new(),
                rectify_cancel: None,
            };
            let cancel = session.asr_cancel.clone();
            st.session = Some(session);
            self.inner.transition(&mut st, id, SessionState::Recording);
            (id, cancel)
        };
        tokio::spawn(consume_asr(self.inner.clone(), sid, stream, cancel));
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
        let (sid, text) = {
            let st = self.inner.state_lock();
            if st.state != SessionState::Preview {
                return Err(EngineError::CommandRejected {
                    command: Command::ConfirmInsert,
                    state: st.state,
                });
            }
            let session = st.session.as_ref().expect("active session");
            (session.id, session.preview_text.clone())
        };
        match self.inner.inserter.insert(&text).await {
            Ok(()) => {
                let mut st = self.inner.state_lock();
                // The session cannot have changed: cancel needs the command
                // gate too, and rectify tasks never touch `Preview`.
                self.inner
                    .emit(&mut st, sid, EngineEvent::TextInserted { text });
                self.inner
                    .finish_session(&mut st, sid, SessionState::Inserted);
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
    /// states never persist, so no session can wedge.
    fn finish_session(&self, st: &mut SharedState, sid: SessionId, terminal: SessionState) {
        self.transition(st, sid, terminal);
        self.transition(st, sid, SessionState::Idle);
        st.session = None;
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

fn current_sid(st: &SharedState) -> SessionId {
    st.session.as_ref().expect("active session").id
}

/// Freeze the recorded raw transcript (on recording end), move to
/// `Rectifying`, and spawn a rectify attempt. Shared by manual stop,
/// silence auto-end (both from `Recording`), and reroll (from `Preview`).
/// No-op unless the session is in one of those states.
fn begin_rectify(inner: &Arc<Inner>) {
    let (sid, cancel, request) = {
        let mut st = inner.state_lock();
        let state = st.state;
        let Some(session) = st.session.as_mut() else {
            return;
        };
        let sid = session.id;
        let (cancel, request) = match state {
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
                (
                    cancel,
                    RectifyRequest {
                        raw_transcript,
                        paragraphs,
                        style: *inner.style.read().unwrap(),
                        terms: Vec::new(),
                    },
                )
            }
            SessionState::Preview => {
                // Reroll: the transcript is already frozen.
                let frozen = session.frozen.as_ref().expect("frozen before preview");
                let cancel = CancellationToken::new();
                session.rectify_cancel = Some(cancel.clone());
                (
                    cancel,
                    RectifyRequest {
                        raw_transcript: frozen.raw_transcript.clone(),
                        paragraphs: frozen.paragraphs.clone(),
                        style: *inner.style.read().unwrap(),
                        terms: Vec::new(),
                    },
                )
            }
            _ => return,
        };
        inner.transition(&mut st, sid, SessionState::Rectifying);
        (sid, cancel, request)
    };
    let llm = inner.llm.clone();
    tokio::spawn(rectify_task(inner.clone(), sid, llm, request, cancel));
}

impl Session {
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
                        // Interim speech still disarms the silence-run flag:
                        // the user resumed talking.
                        session.paragraph_marked_current_silence = false;
                        session.speech_since_mark = true;
                        session.any_speech = true;
                        let live = session.live_text();
                        inner.emit_stream_event(&mut st, sid, EngineEvent::LiveTranscriptUpdated { text: live });
                    }
                    AsrEvent::Final { text } => {
                        session.partial.clear();
                        session.current_paragraph.push_str(&text);
                        session.paragraph_marked_current_silence = false;
                        session.speech_since_mark = true;
                        session.any_speech = true;
                        let live = session.live_text();
                        inner.emit_stream_event(&mut st, sid, EngineEvent::LiveTranscriptUpdated { text: live });
                    }
                    AsrEvent::Silence { elapsed_ms } => {
                        if inner.config.passage_mode {
                            // Only mark a paragraph when speech happened
                            // since the last mark: silence before talking
                            // marks nothing. Transcript text is not required
                            // — until the real ASR adapter lands, VAD speech
                            // bursts alone carry the paragraph structure.
                            if elapsed_ms >= inner.config.paragraph_silence_ms
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
                        } else if elapsed_ms >= inner.config.session_end_silence_ms {
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
                            session.paragraph_marked_current_silence = false;
                            session.speech_since_mark = true;
                            session.any_speech = true;
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
/// session. Exits silently if the attempt is cancelled or superseded.
async fn rectify_task(
    inner: Arc<Inner>,
    sid: SessionId,
    llm: Arc<dyn RectifyLlm>,
    request: RectifyRequest,
    cancel: CancellationToken,
) {
    let stream: RectifyTokenStream = match llm.rectify(request).await {
        Ok(stream) => stream,
        Err(err) => {
            inner.abort_rectifying(sid, format!("rectify failed: {}", err.0));
            return;
        }
    };
    let mut stream = Box::pin(stream);
    let mut accumulated = String::new();
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return,
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
