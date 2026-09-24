//! The engine's background tasks: ASR stream consumption (`consume_asr`),
//! rectify attempts (`rectify_task`), and the straight-through paste
//! (`paste_through`), plus the stop/reroll planner that spawns them
//! (`begin_rectify`). Spawned by the engine's command handlers; they take
//! the state lock only to mutate and never hold it across an await.

use std::sync::Arc;

use futures::stream::{BoxStream, StreamExt};
use tokio_util::sync::CancellationToken;

use crate::config::EngineTimings;
use crate::engine::{Inner, session_matches};
use crate::event::{EngineEvent, SessionId, SessionState};
use crate::prefill;
use crate::provider::asr::AsrEvent;
use crate::provider::history::RecordedSession;
use crate::provider::llm::{RectifyLlm, RectifyRequest, RectifyTokenStream};

/// The user-facing message when the hard cap expires.
fn rectify_timeout_message(timeout_ms: u64) -> String {
    format!("rectify timed out after the {timeout_ms} ms hard cap; retry or cancel")
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
pub(crate) fn begin_rectify(inner: &Arc<Inner>) {
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

/// Consume the ASR event stream of one session: forward transcript updates,
/// apply silence rules (paragraph mark / auto-end), and stop when the
/// session's cancellation token fires.
pub(crate) async fn consume_asr(
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
pub(crate) async fn rectify_task(
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
