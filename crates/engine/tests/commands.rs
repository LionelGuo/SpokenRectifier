//! Command validation: illegal commands are rejected without emitting
//! events or changing state; styles flow into rectify requests.

mod common;

use common::{await_live, await_state, collect_summary, expect_quiet, harness, ok};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::{Command, Engine, EngineConfig, EngineError, SessionState, Style};

#[tokio::test]
async fn illegal_commands_are_rejected_without_events() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![vec![LlmStep::Token("修".into())]],
    );

    async fn rejected(engine: &Engine, command: Command) {
        let state = engine.state();
        let err = engine
            .execute(command.clone())
            .await
            .expect_err("command should be rejected");
        match err {
            EngineError::CommandRejected {
                command: c,
                state: s,
            } => {
                assert_eq!(c, command);
                assert_eq!(s, state, "rejection reports the current state");
            }
            other => panic!("expected CommandRejected, got {other:?}"),
        }
    }

    // Idle: every session command is rejected.
    rejected(&h.engine, Command::StopSession).await;
    rejected(&h.engine, Command::Cancel).await;
    rejected(&h.engine, Command::ConfirmInsert).await;
    rejected(&h.engine, Command::Reroll).await;
    rejected(&h.engine, Command::UpdatePreviewText("x".into())).await;

    // Recording: only stop and cancel (and style) are legal.
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    rejected(&h.engine, Command::StartSession).await;
    rejected(&h.engine, Command::ConfirmInsert).await;
    rejected(&h.engine, Command::Reroll).await;
    rejected(&h.engine, Command::UpdatePreviewText("x".into())).await;

    // Rectifying: only cancel is legal (stop already happened).
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    rejected(&h.engine, Command::StartSession).await;
    rejected(&h.engine, Command::StopSession).await;
    rejected(&h.engine, Command::ConfirmInsert).await;
    rejected(&h.engine, Command::Reroll).await;
    rejected(&h.engine, Command::UpdatePreviewText("x".into())).await;

    // Preview: start and stop are rejected; confirm/cancel/reroll/edit ok.
    await_state(&mut rx, SessionState::Preview).await;
    rejected(&h.engine, Command::StartSession).await;
    rejected(&h.engine, Command::StopSession).await;

    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    expect_quiet(&mut rx, 50).await;

    // None of the rejections produced an event.
    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"一段\"",
            "live \"一段\"",
            "state Recording->Rectifying",
            "chunk \"修\"",
            "state Rectifying->Preview",
            "state Preview->Cancelled",
            "state Cancelled->Idle",
        ]
    );
}

#[tokio::test]
async fn style_changes_apply_to_the_next_rectify_including_reroll() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![
            vec![LlmStep::Token("一".into())],
            vec![LlmStep::Token("二".into())],
        ],
    );

    ok(&h.engine, Command::SetStyle(Style::Prompt)).await;
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(h.llm.requests()[0].style, Style::Prompt);

    // Switching while in preview affects the reroll.
    ok(&h.engine, Command::SetStyle(Style::FormalDocument)).await;
    ok(&h.engine, Command::Reroll).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(h.llm.requests()[1].style, Style::FormalDocument);
}
