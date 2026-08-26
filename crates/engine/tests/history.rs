//! History port tests: the engine hands every inserted session's raw
//! transcript and rectified text to the injected recorder, and text-only
//! sessions (history re-rectify) run the same machine without a microphone.

mod common;

use std::sync::{Arc, Mutex};

use common::{await_live, await_state, harness_with_history, next_matching, ok};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::provider::history::{RecordedSession, SessionRecorder};
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, SessionState};

/// Collecting recorder: remembers everything it is handed.
#[derive(Default)]
struct Sink {
    sessions: Mutex<Vec<RecordedSession>>,
}

impl SessionRecorder for Sink {
    fn record(&self, session: RecordedSession) {
        self.sessions.lock().unwrap().push(session);
    }
}

impl Sink {
    fn entries(&self) -> Vec<RecordedSession> {
        self.sessions.lock().unwrap().clone()
    }
}

/// A recorded pair, for assertions.
fn pair(raw: &str, rectified: &str) -> RecordedSession {
    RecordedSession {
        raw_transcript: raw.to_string(),
        rectified_text: rectified.to_string(),
    }
}

#[tokio::test]
async fn an_inserted_session_is_recorded_with_both_texts() {
    let sink = Arc::new(Sink::default());
    let (h, mut rx) = harness_with_history(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("嗯那个原话".into())]],
        vec![vec![LlmStep::Token("修正后的书面文本".into())]],
        Some(sink.clone()),
    );

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "嗯那个原话").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, SessionState::Idle).await;

    let entries = sink.entries();
    assert_eq!(entries.len(), 1, "exactly one recorded session");
    assert_eq!(entries[0], pair("嗯那个原话", "修正后的书面文本"));
}

#[tokio::test]
async fn a_preview_edit_is_recorded_as_the_rectified_text() {
    let sink = Arc::new(Sink::default());
    let (h, mut rx) = harness_with_history(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("原话".into())]],
        vec![vec![LlmStep::Token("初稿".into())]],
        Some(sink.clone()),
    );

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "原话").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(&h.engine, Command::UpdatePreviewText("改完的终稿".into())).await;
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, SessionState::Idle).await;

    // What went in is what history keeps: the edited text, with the raw
    // transcript of what was actually said.
    assert_eq!(sink.entries(), vec![pair("原话", "改完的终稿")]);
}

#[tokio::test]
async fn cancelled_and_failed_sessions_record_nothing() {
    let sink = Arc::new(Sink::default());
    let (h, mut rx) = harness_with_history(
        EngineConfig::default(),
        // First session: cancelled mid-recording. Second: rectify fails,
        // which aborts to Cancelled. Neither may reach history.
        vec![
            vec![AsrStep::Say("算了".into())],
            vec![AsrStep::Say("修不动".into())],
        ],
        vec![vec![LlmStep::Fail("模型挂了".into())]],
        Some(sink.clone()),
    );

    ok(&h.engine, Command::StartSession).await;
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "修不动").await;
    ok(&h.engine, Command::StopSession).await;
    next_matching(&mut rx, |env| {
        matches!(env.event, EngineEvent::Error { .. })
    })
    .await;
    await_state(&mut rx, SessionState::Idle).await;

    assert!(
        sink.entries().is_empty(),
        "aborted sessions never become history"
    );
}

#[tokio::test]
async fn rectify_text_runs_the_full_machine_without_a_microphone() {
    let sink = Arc::new(Sink::default());
    let (h, mut rx) = harness_with_history(
        EngineConfig::default(),
        vec![],
        vec![
            vec![LlmStep::Token("重修".into())],
            vec![LlmStep::Token("再修".into())],
        ],
        Some(sink.clone()),
    );

    // Re-rectify a historical transcript: straight into the machine.
    ok(
        &h.engine,
        Command::RectifyText("第一段\n不对，第二段".into()),
    )
    .await;
    await_state(&mut rx, SessionState::Rectifying).await;

    // The utterance is text, not speech: its transcript is published so the
    // preview's raw comparison has something to compare against. (Asserted
    // before awaiting Preview: waiting skips past events without replaying.)
    next_matching(&mut rx, |env| {
        matches!(
            env.event,
            EngineEvent::LiveTranscriptUpdated { ref text } if text == "第一段\n不对，第二段"
        )
    })
    .await;
    await_state(&mut rx, SessionState::Preview).await;

    // Reroll reuses the frozen text exactly like a recorded session's.
    ok(&h.engine, Command::Reroll).await;
    await_state(&mut rx, SessionState::Rectifying).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].raw_transcript, "第一段\n不对，第二段");
    assert_eq!(
        requests[0].paragraphs,
        vec!["第一段".to_string(), "不对，第二段".to_string()]
    );

    // Insert records the re-rectified pair like any other session.
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(h.inserter.inserted_texts(), vec!["再修"]);
    assert_eq!(sink.entries(), vec![pair("第一段\n不对，第二段", "再修")]);
    // No scripted ASR session was consumed: no microphone was opened.
    assert_eq!(h.asr.remaining_sessions(), 0);
}

#[tokio::test]
async fn rectify_text_is_rejected_outside_idle_and_when_empty() {
    let sink = Arc::new(Sink::default());
    let (h, mut rx) = harness_with_history(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("占位".into())]],
        vec![vec![LlmStep::Token("初稿".into())]],
        Some(sink.clone()),
    );

    // Empty utterance: rejected in idle.
    let err = h
        .engine
        .execute(Command::RectifyText("".into()))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("empty"), "got: {err}");

    // Occupied: rejected while recording.
    ok(&h.engine, Command::StartSession).await;
    let err = h
        .engine
        .execute(Command::RectifyText("排队的字".into()))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("rejected"), "got: {err}");

    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    assert!(sink.entries().is_empty());
}
