//! Quick mode (ADR-0020): the held-hotkey upgrade, the straight-through
//! insert with and without rectify, and the failure degradations.
//!
//! The engine's half only — the chord's physical watching lives in the
//! shell, which reports a hold as [`Command::MarkQuick`] and
//! [`Command::HoldGate`]. What is tested here is what those signals do: a
//! mark upgrades a recording with nothing pinned, a marked session's stop
//! never shows a preview, and any failure lands in the ordinary preview
//! instead of discarding the round.

mod common;

use std::sync::{Arc, Mutex};

use common::{
    await_live, await_state, chan_harness, collect_summary, drain_said, harness,
    harness_with_history, next_matching, ok,
};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::provider::history::{RecordedSession, SessionRecorder};
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, SessionState};

/// The engine as the settings window leaves it with quick mode switched
/// on; `rectify` is `[rectify.quick] rectify`.
fn quick_config(rectify: bool) -> EngineConfig {
    EngineConfig {
        quick_mode: true,
        quick_rectify: rectify,
        ..EngineConfig::default()
    }
}

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

#[tokio::test]
async fn a_held_hotkey_marks_the_session_and_the_stop_inserts_unseen() {
    // The whole point of the gesture: no preview, no confirmation — the
    // body the model streamed goes straight in.
    let (h, mut rx) = harness(
        quick_config(true),
        vec![vec![AsrStep::Say("嗯那个".into())]],
        vec![vec![LlmStep::Token("修好".into())]],
    );
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "嗯那个").await;
    ok(&h.engine, Command::HoldGate { held: true }).await;
    ok(&h.engine, Command::MarkQuick).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::QuickMarked).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"嗯那个\"",
            "live \"嗯那个\"",
            "quick",
            "state Recording->Rectifying",
            "chunk \"修好\"",
            "inserted \"修好\"",
            "state Rectifying->Inserted",
            "state Inserted->Idle",
        ]
    );
    assert_eq!(h.inserter.inserted_texts(), vec!["修好"]);
    // The attempt carried the quick flag the client assembles on.
    let requests = h.llm.requests();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].quick);
    assert_eq!(requests[0].raw_transcript, "嗯那个");
}

#[tokio::test]
async fn a_pin_before_the_hold_refuses_the_upgrade() {
    // 钉入 wins: the session is an ordinary one for its whole life, its
    // stop lands in preview, and nothing about it is quick.
    let (h, mut rx) = harness(
        quick_config(true),
        vec![vec![AsrStep::Say("嗯".into())]],
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "嗯").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "嗯‡1‡").await;
    ok(&h.engine, Command::HoldGate { held: true }).await;
    ok(&h.engine, Command::MarkQuick).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;

    let summary = collect_summary(&mut rx_all);
    assert!(
        !summary.contains(&"quick".to_string()),
        "a pinned session never upgrades: {summary:?}"
    );
    assert!(summary.contains(&"state Rectifying->Preview".to_string()));
    assert!(!h.llm.requests()[0].quick);
}

#[tokio::test]
async fn a_pin_after_the_upgrade_is_swallowed() {
    // The shell disarms the pin hotkey off the upgrade event; a press that
    // lost that race must leave no trace — no sentinel, no error.
    let (h, mut rx) = harness(
        quick_config(true),
        vec![vec![AsrStep::Say("嗯".into())]],
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "嗯").await;
    ok(&h.engine, Command::MarkQuick).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::QuickMarked).await;
    ok(&h.engine, Command::PinPlaceholder).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"嗯\"",
            "live \"嗯\"",
            "quick",
            "state Recording->Rectifying",
            "chunk \"修\"",
            "inserted \"修\"",
            "state Rectifying->Inserted",
            "state Inserted->Idle",
        ]
    );
    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "嗯");
    assert_eq!(h.inserter.inserted_texts(), vec!["修"]);
}

#[tokio::test]
async fn quick_with_rectify_off_pastes_the_raw_transcript() {
    // 启用修正 off: no model round at all, no Rectifying state — the
    // frozen transcript goes straight in, and history records it on both
    // sides.
    let sink = Arc::new(Sink::default());
    let (h, mut rx) = harness_with_history(
        quick_config(false),
        vec![vec![AsrStep::Say("嗯那个原话".into())]],
        vec![],
        Some(sink.clone()),
    );
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "嗯那个原话").await;
    ok(&h.engine, Command::HoldGate { held: true }).await;
    ok(&h.engine, Command::MarkQuick).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::QuickMarked).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"嗯那个原话\"",
            "live \"嗯那个原话\"",
            "quick",
            "inserted \"嗯那个原话\"",
            "state Recording->Inserted",
            "state Inserted->Idle",
        ]
    );
    assert_eq!(h.llm.call_count(), 0, "no model runs without rectify");
    assert_eq!(h.inserter.inserted_texts(), vec!["嗯那个原话"]);
    assert_eq!(
        sink.entries(),
        vec![RecordedSession {
            raw_transcript: "嗯那个原话".into(),
            rectified_text: "嗯那个原话".into(),
            scenario: None,
            placeholders: Vec::new(),
            source_session_id: None,
        }]
    );
}

#[tokio::test]
async fn a_speechless_hold_is_discarded_as_usual() {
    // 空转写 keeps today's shape: 已取消, nothing inserted.
    let (h, mut rx) = harness(quick_config(true), vec![vec![]], vec![]);
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    ok(&h.engine, Command::HoldGate { held: true }).await;
    ok(&h.engine, Command::MarkQuick).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "quick",
            "state Recording->Cancelled",
            "state Cancelled->Idle",
        ]
    );
    assert_eq!(h.inserter.inserted_texts(), Vec::<String>::new());
    assert_eq!(h.llm.call_count(), 0);
}

#[tokio::test]
async fn a_held_chord_suppresses_the_silence_auto_end() {
    // A held chord means the speaker is mid-gesture: a long pause must not
    // end the session under them. The release puts the threshold back.
    let h = chan_harness(
        EngineConfig {
            passage_mode: false,
            ..quick_config(true)
        },
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.say("话").await;
    await_live(&mut rx, "话").await;
    ok(&h.engine, Command::HoldGate { held: true }).await;
    h.feed.silence(3_000).await;
    // Still recording: the next thing said lands in the same transcript.
    h.feed.say("还有").await;
    await_live(&mut rx, "话还有").await;
    ok(&h.engine, Command::HoldGate { held: false }).await;
    h.feed.silence(3_000).await;
    await_state(&mut rx, SessionState::Preview).await;

    assert_eq!(h.llm.requests()[0].raw_transcript, "话还有");
}

#[tokio::test]
async fn paragraph_marks_still_flow_while_the_chord_is_held() {
    // 段落标记仍发: only the auto-end is gated, never the paragraph rule.
    let h = chan_harness(quick_config(true), vec![]);
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.say("一").await;
    await_live(&mut rx, "一").await;
    ok(&h.engine, Command::HoldGate { held: true }).await;
    h.feed.silence(1_200).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
}

#[tokio::test]
async fn a_failed_quick_attempt_degrades_into_preview() {
    // 失败降级: the round keeps what it streamed, the session enters the
    // ordinary preview, and the confirm after it is manual.
    let (h, mut rx) = harness(
        quick_config(true),
        vec![vec![AsrStep::Say("嗯".into())]],
        vec![vec![
            LlmStep::Token("修".into()),
            LlmStep::Fail("boom".into()),
        ]],
    );
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "嗯").await;
    ok(&h.engine, Command::MarkQuick).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::QuickMarked).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"嗯\"",
            "live \"嗯\"",
            "quick",
            "state Recording->Rectifying",
            "chunk \"修\"",
            "error \"rectify stream failed: boom\"",
            "state Rectifying->Preview",
        ]
    );
    // What the box shows is what confirm inserts: the streamed text.
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(h.inserter.inserted_texts(), vec!["修"]);
}

#[tokio::test]
async fn a_degraded_quick_session_rerolls_on_the_ordinary_path() {
    // The flag dies with the failure, so the reroll is an ordinary
    // attempt — and never auto-pastes again.
    let (h, mut rx) = harness(
        quick_config(true),
        vec![vec![AsrStep::Say("嗯".into())]],
        vec![
            vec![LlmStep::Token("修".into()), LlmStep::Fail("boom".into())],
            vec![LlmStep::Token("重来".into())],
        ],
    );

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "嗯").await;
    ok(&h.engine, Command::MarkQuick).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::QuickMarked).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    ok(&h.engine, Command::Reroll).await;
    await_state(&mut rx, SessionState::Preview).await;

    let requests = h.llm.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests[0].quick);
    assert!(!requests[1].quick, "the reroll runs the ordinary path");
    assert_eq!(h.inserter.inserted_texts(), Vec::<String>::new());

    // Still a preview: the reroll's body waits for a manual confirm.
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(h.inserter.inserted_texts(), vec!["重来"]);
}

#[tokio::test]
async fn a_failed_paste_degrades_into_preview_holding_the_raw_transcript() {
    // 直贴失败: the insert is the failure, not the model, so the preview
    // holds the raw transcript — and streams it, because this round had no
    // chunks of its own for the shell to have accumulated.
    let (h, mut rx) = harness(
        quick_config(false),
        vec![vec![AsrStep::Say("嗯那个原话".into())]],
        vec![],
    );
    let mut rx_all = h.engine.subscribe();
    h.inserter.fail_next_insert();

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "嗯那个原话").await;
    ok(&h.engine, Command::MarkQuick).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::QuickMarked).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"嗯那个原话\"",
            "live \"嗯那个原话\"",
            "quick",
            "error \"text insertion failed: scripted insertion failure\"",
            "chunk \"嗯那个原话\"",
            "state Recording->Preview",
        ]
    );
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(h.inserter.inserted_texts(), vec!["嗯那个原话"]);
}

#[tokio::test]
async fn a_silence_auto_end_in_a_quick_session_pastes_too() {
    // The auto-end is the same recording end as a manual stop, so it runs
    // the same straight-through.
    let h = chan_harness(
        EngineConfig {
            passage_mode: false,
            ..quick_config(false)
        },
        vec![],
    );
    let mut rx = h.engine.subscribe();
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.say("原话").await;
    await_live(&mut rx, "原话").await;
    ok(&h.engine, Command::MarkQuick).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::QuickMarked).await;
    h.feed.silence(3_000).await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"原话\"",
            "live \"原话\"",
            "quick",
            "inserted \"原话\"",
            "state Recording->Inserted",
            "state Inserted->Idle",
        ]
    );
    assert_eq!(h.llm.call_count(), 0);
}

#[tokio::test]
async fn cancel_takes_the_quick_flag_down_with_the_session() {
    let (h, mut rx) = harness(
        quick_config(true),
        vec![
            vec![AsrStep::Say("第一场".into())],
            vec![AsrStep::Say("第二场".into())],
        ],
        vec![vec![LlmStep::Token("修".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "第一场").await;
    ok(&h.engine, Command::MarkQuick).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::QuickMarked).await;
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;

    // The next session starts ordinary: nothing carries over.
    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "第二场").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert!(!h.llm.requests()[0].quick);
    assert_eq!(h.inserter.inserted_texts(), Vec::<String>::new());
}

#[tokio::test]
async fn with_the_master_switch_off_a_mark_changes_nothing() {
    // The default engine: the whole gesture is inert, so a stray mark
    // cannot turn an ordinary session into a straight-through one.
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("嗯".into())]],
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "嗯").await;
    ok(&h.engine, Command::HoldGate { held: true }).await;
    ok(&h.engine, Command::MarkQuick).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    let summary = collect_summary(&mut rx_all);
    assert!(
        !summary.contains(&"quick".to_string()),
        "the switch is off: {summary:?}"
    );
    assert!(summary.contains(&"state Rectifying->Preview".to_string()));
    assert!(!h.llm.requests()[0].quick);
}

#[tokio::test]
async fn an_unmarked_stop_under_quick_config_is_ordinary() {
    // No hold crossed the threshold, so 启用修正 off never applies: the
    // session rectifies and previews exactly as before.
    let (h, mut rx) = harness(
        quick_config(false),
        vec![vec![AsrStep::Say("嗯".into())]],
        vec![vec![LlmStep::Token("修".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "嗯").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    assert_eq!(h.llm.call_count(), 1);
    assert!(!h.llm.requests()[0].quick);
    assert_eq!(h.inserter.inserted_texts(), Vec::<String>::new());
}

#[tokio::test]
async fn the_quick_settings_apply_from_the_next_session_on() {
    // What the settings window's save sends. The switch is live; the
    // rectify flag is snapshotted per session like the timings.
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![
            vec![AsrStep::Say("第一场".into())],
            vec![AsrStep::Say("第二场".into())],
        ],
        vec![vec![LlmStep::Token("修".into())]],
    );

    // Session 1 opens with quick mode off; its mark is inert.
    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "第一场").await;
    ok(&h.engine, Command::MarkQuick).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;

    ok(
        &h.engine,
        Command::SetQuickMode {
            enabled: true,
            rectify: false,
        },
    )
    .await;

    // Session 2 snapshots the switch: marked, then straight through.
    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "第二场").await;
    ok(&h.engine, Command::MarkQuick).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::QuickMarked).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(h.llm.call_count(), 1);
    assert_eq!(h.inserter.inserted_texts(), vec!["修", "第二场"]);
}
