//! Command validation: illegal commands are rejected without emitting
//! events or changing state; style directives flow into rectify requests.

mod common;

use common::{await_live, await_state, collect_summary, expect_quiet, harness, ok};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineError, SessionState, SessionStyle,
};

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
    rejected(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    rejected(&h.engine, Command::Reroll).await;
    rejected(&h.engine, Command::UpdatePreviewText("x".into())).await;

    // Recording: only stop and cancel (and style) are legal.
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    rejected(&h.engine, Command::StartSession).await;
    rejected(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    rejected(&h.engine, Command::Reroll).await;
    rejected(&h.engine, Command::UpdatePreviewText("x".into())).await;

    // Rectifying: only cancel is legal (stop already happened).
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    rejected(&h.engine, Command::StartSession).await;
    rejected(&h.engine, Command::StopSession).await;
    rejected(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
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
async fn a_style_directive_applies_to_the_next_rectify_including_reroll() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![
            vec![LlmStep::Token("一".into())],
            vec![LlmStep::Token("二".into())],
        ],
    );

    // The engine starts on the built-in default register: no directive.
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(h.llm.requests()[0].style_directive, None);

    // A selected scenario's directive text rides the very next attempt —
    // a reroll included.
    ok(
        &h.engine,
        Command::SetStyleDirective {
            directive: Some("以 Markdown 分条输出".into()),
            scenario: None,
        },
    )
    .await;
    ok(&h.engine, Command::Reroll).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(
        h.llm.requests()[1].style_directive.as_deref(),
        Some("以 Markdown 分条输出")
    );
}

#[tokio::test]
async fn a_blank_directive_reads_as_the_default_register() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![vec![LlmStep::Token("修".into())]],
    );

    // Whitespace-only directive text normalizes to "no directive".
    ok(
        &h.engine,
        Command::SetStyleDirective {
            directive: Some("   ".into()),
            scenario: None,
        },
    )
    .await;
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(h.llm.requests()[0].style_directive, None);
}

#[tokio::test]
async fn a_one_time_directive_pins_the_re_rectify_session() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![]],
        vec![
            vec![LlmStep::Token("一".into())],
            vec![LlmStep::Token("二".into())],
            vec![LlmStep::Token("三".into())],
        ],
    );

    // A scenario stays selected, then history retrieval names a one-time
    // directive for just this session (ticket 23's 指定场景重新修正).
    ok(
        &h.engine,
        Command::SetStyleDirective {
            directive: Some("选中场景的指令".into()),
            scenario: None,
        },
    )
    .await;
    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "旧话".into(),
            style: SessionStyle::Directive {
                text: "一次性指令".into(),
                scenario: None,
            },
            source_session_id: None,
        },
    )
    .await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(
        h.llm.requests()[0].style_directive.as_deref(),
        Some("一次性指令")
    );

    // Rerolls keep the one-time directive — even over a selection switch
    // made mid-session.
    ok(
        &h.engine,
        Command::SetStyleDirective {
            directive: Some("中途换的指令".into()),
            scenario: None,
        },
    )
    .await;
    ok(&h.engine, Command::Reroll).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(
        h.llm.requests()[1].style_directive.as_deref(),
        Some("一次性指令")
    );

    // The session ends; the next rectify runs under the live selection
    // again — the override never outlives its session.
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "又一句".into(),
            style: SessionStyle::Live,
            source_session_id: None,
        },
    )
    .await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(
        h.llm.requests()[2].style_directive.as_deref(),
        Some("中途换的指令")
    );
}

#[tokio::test]
async fn a_blank_one_time_directive_reads_as_no_override() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![]],
        vec![vec![LlmStep::Token("修".into())]],
    );

    // Whitespace-only override text normalizes to "no override": the
    // request falls back to the live selection, same guard as
    // SetStyleDirective's.
    ok(
        &h.engine,
        Command::SetStyleDirective {
            directive: Some("选中场景的指令".into()),
            scenario: None,
        },
    )
    .await;
    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "旧话".into(),
            style: SessionStyle::Directive {
                text: "   ".into(),
                scenario: None,
            },
            source_session_id: None,
        },
    )
    .await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(
        h.llm.requests()[0].style_directive.as_deref(),
        Some("选中场景的指令")
    );
}

#[tokio::test]
async fn a_default_register_pin_ignores_the_live_selection() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![]],
        vec![
            vec![LlmStep::Token("一".into())],
            vec![LlmStep::Token("二".into())],
            vec![LlmStep::Token("三".into())],
        ],
    );

    // A scenario stays selected; history retrieval picks the built-in
    // 默认 instead (ticket 28): the session runs with no style section
    // at all — the selection never reaches it. The global directive
    // rides along regardless (the constant layer is independent of the
    // style pick).
    ok(
        &h.engine,
        Command::SetStyleDirective {
            directive: Some("选中场景的指令".into()),
            scenario: None,
        },
    )
    .await;
    ok(
        &h.engine,
        Command::SetGlobalDirective(Some("全局指令".into())),
    )
    .await;
    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "旧话".into(),
            style: SessionStyle::DefaultRegister,
            source_session_id: None,
        },
    )
    .await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(h.llm.requests()[0].style_directive, None);
    assert_eq!(
        h.llm.requests()[0].global_directive.as_deref(),
        Some("全局指令")
    );

    // Rerolls keep the pin — even over a selection switch made
    // mid-session — and the global layer keeps riding.
    ok(
        &h.engine,
        Command::SetStyleDirective {
            directive: Some("中途换的指令".into()),
            scenario: None,
        },
    )
    .await;
    ok(&h.engine, Command::Reroll).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(h.llm.requests()[1].style_directive, None);
    assert_eq!(
        h.llm.requests()[1].global_directive.as_deref(),
        Some("全局指令")
    );

    // The session ends; the next rectify runs under the live selection
    // again — the pin never outlives its session.
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "又一句".into(),
            style: SessionStyle::Live,
            source_session_id: None,
        },
    )
    .await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(
        h.llm.requests()[2].style_directive.as_deref(),
        Some("中途换的指令")
    );
}

#[tokio::test]
async fn a_global_directive_is_live_read_into_every_attempt() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![]],
        vec![
            vec![LlmStep::Token("一".into())],
            vec![LlmStep::Token("二".into())],
            vec![LlmStep::Token("三".into())],
        ],
    );

    // The global directive rides the first request alongside the (absent)
    // scenario directive.
    ok(
        &h.engine,
        Command::SetGlobalDirective(Some("全局第一版".into())),
    )
    .await;
    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "旧话".into(),
            style: SessionStyle::Live,
            source_session_id: None,
        },
    )
    .await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(
        h.llm.requests()[0].global_directive.as_deref(),
        Some("全局第一版")
    );
    assert_eq!(h.llm.requests()[0].style_directive, None);

    // A change made mid-session (the session is still open in preview)
    // shapes the very next attempt — a reroll included. Unlike the
    // one-time style override, the global layer is never pinned.
    ok(
        &h.engine,
        Command::SetGlobalDirective(Some("全局第二版".into())),
    )
    .await;
    ok(&h.engine, Command::Reroll).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(
        h.llm.requests()[1].global_directive.as_deref(),
        Some("全局第二版")
    );

    // Unsetting works the same way, with the same blank guard as
    // SetStyleDirective's.
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    ok(&h.engine, Command::SetGlobalDirective(Some("   ".into()))).await;
    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "又一句".into(),
            style: SessionStyle::Live,
            source_session_id: None,
        },
    )
    .await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(h.llm.requests()[2].global_directive, None);
}

#[tokio::test]
async fn a_global_directive_rides_alongside_a_scenario_or_one_time_override() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![]],
        vec![vec![LlmStep::Token("修".into())]],
    );

    // The two layers are independent fields on the request: a selected
    // scenario and the global directive both ride it (their layering is
    // the prompt's job, ADR-0006), and a one-time override pins only the
    // scenario layer — the global one stays live.
    ok(
        &h.engine,
        Command::SetStyleDirective {
            directive: Some("场景指令".into()),
            scenario: None,
        },
    )
    .await;
    ok(
        &h.engine,
        Command::SetGlobalDirective(Some("全局指令".into())),
    )
    .await;
    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "旧话".into(),
            style: SessionStyle::Directive {
                text: "一次性指令".into(),
                scenario: None,
            },
            source_session_id: None,
        },
    )
    .await;
    await_state(&mut rx, SessionState::Preview).await;
    let request = &h.llm.requests()[0];
    assert_eq!(request.style_directive.as_deref(), Some("一次性指令"));
    assert_eq!(request.global_directive.as_deref(), Some("全局指令"));
}
