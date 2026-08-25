//! Cancel semantics: a cancelled session produces zero output — nothing is
//! rectified into view, nothing is inserted — from every active state.

mod common;

use common::{await_live, await_state, collect_summary, expect_quiet, harness, next_matching, ok};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, SessionState};

#[tokio::test]
async fn cancel_while_recording_produces_zero_output() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![
            AsrStep::Say("说错的整段".into()),
            AsrStep::Silence(1300), // marks a paragraph, still recording
        ]],
        vec![vec![LlmStep::Token("不该出现".into())]],
    );

    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    // Drain the script (the paragraph mark is its last event).
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"说错的整段\"",
            "live \"说错的整段\"",
            "paragraph",
            "state Recording->Cancelled",
            "state Cancelled->Idle",
        ]
    );
    assert_eq!(h.llm.call_count(), 0, "rectify must not start");
    assert!(h.inserter.inserted_texts().is_empty(), "nothing inserted");
    assert_eq!(h.engine.state(), SessionState::Idle);
}

#[tokio::test]
async fn cancel_right_after_stop_suppresses_all_rectified_output() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![vec![LlmStep::Token("不该出现的修正".into())]],
    );

    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    // Cancel immediately, while rectify is streaming.
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"一段\"",
            "live \"一段\"",
            "state Recording->Rectifying",
            "state Rectifying->Cancelled",
            "state Cancelled->Idle",
        ]
    );
    // The LLM may have been invoked before cancellation landed, but no
    // rectified text ever surfaced and nothing was inserted.
    assert!(h.llm.call_count() <= 1);
    assert!(h.inserter.inserted_texts().is_empty());
}

#[tokio::test]
async fn cancel_in_preview_inserts_nothing() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![vec![LlmStep::Token("修好了".into())]],
    );

    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"一段\"",
            "live \"一段\"",
            "state Recording->Rectifying",
            "chunk \"修好了\"",
            "state Rectifying->Preview",
            "state Preview->Cancelled",
            "state Cancelled->Idle",
        ]
    );
    assert!(h.inserter.inserted_texts().is_empty());
}

#[tokio::test]
async fn llm_stream_error_aborts_session_to_idle() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![vec![
            LlmStep::Token("半截".into()),
            LlmStep::Fail("upstream blew up".into()),
        ]],
    );

    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Idle).await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"一段\"",
            "live \"一段\"",
            "state Recording->Rectifying",
            "chunk \"半截\"",
            "error \"rectify stream failed: upstream blew up\"",
            "state Rectifying->Cancelled",
            "state Cancelled->Idle",
        ]
    );
    assert_eq!(h.engine.state(), SessionState::Idle);
    assert!(h.inserter.inserted_texts().is_empty());
}
