//! Preview interactions: edit, reroll, insertion failure.

mod common;

use common::{await_live, await_state, collect_summary, expect_quiet, harness, next_matching, ok};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, SessionState};

#[tokio::test]
async fn edited_preview_text_is_what_gets_inserted() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![vec![LlmStep::Token("机器修正".into())]],
    );

    let _rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    ok(&h.engine, Command::UpdatePreviewText("手改版本".into())).await;
    let preview = next_matching(&mut rx, |env| {
        env.event
            == EngineEvent::PreviewTextUpdated {
                text: "手改版本".into(),
            }
    })
    .await;
    assert_eq!(preview.seq, 7, "preview update follows the preview state");

    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(h.inserter.inserted_texts(), vec!["手改版本"]);
}

#[tokio::test]
async fn reroll_streams_a_fresh_result_and_inserts_it() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![
            vec![LlmStep::Token("一版".into())],
            vec![LlmStep::Token("二".into()), LlmStep::Token("版".into())],
        ],
    );

    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    ok(&h.engine, Command::Reroll).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, SessionState::Idle).await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"一段\"",
            "live \"一段\"",
            "state Recording->Rectifying",
            "chunk \"一版\"",
            "state Rectifying->Preview",
            // Reroll: back to rectifying, new chunks, preview again.
            "state Preview->Rectifying",
            "chunk \"二\"",
            "chunk \"版\"",
            "state Rectifying->Preview",
            "inserted \"二版\"",
            "state Preview->Inserted",
            "state Inserted->Idle",
        ]
    );
    // Both attempts rectified the same frozen transcript.
    let requests = h.llm.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].raw_transcript, requests[1].raw_transcript);
    assert_eq!(h.inserter.inserted_texts(), vec!["二版"]);
}

#[tokio::test]
async fn failed_insertion_keeps_preview_alive() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![vec![LlmStep::Token("修".into())]],
    );

    let _rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    h.inserter.fail_next_insert();
    ok(&h.engine, Command::ConfirmInsert).await; // insertion fails
    next_matching(&mut rx, |env| {
        matches!(env.event, EngineEvent::Error { .. })
    })
    .await;
    assert_eq!(h.engine.state(), SessionState::Preview, "preview survives");
    assert!(h.inserter.inserted_texts().is_empty());

    // Not a dead end: retry succeeds.
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(h.inserter.inserted_texts(), vec!["修"]);
}
