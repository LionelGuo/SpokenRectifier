//! The thinking channel's trip through the engine (14 号票): forwarded
//! verbatim as its own event, never into the rectified body, and
//! silenced with everything else once the attempt is gone.

mod common;

use common::{await_live, await_state, harness, next_matching, ok, summarize};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, SessionState};

/// The scripted thinking flow, end to end: reasoning deltas stream as
/// `RectifyThinkingDelta` in arrival order — interleaved with the body
/// chunks, thinking-after-body included (the shell's one-way latch is
/// the shell's business) — and the body (what the preview holds) carries
/// none of the thinking characters.
#[tokio::test]
async fn thinking_deltas_ride_their_own_event_and_never_the_body() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("你好世界".into())]],
        vec![vec![
            LlmStep::Think("先听原句".into()),
            LlmStep::Think(":".into()),
            LlmStep::Token("修好".into()),
            LlmStep::Think("回头看".into()),
            LlmStep::Token("了".into()),
        ]],
    );

    // A dedicated collector subscribed before the session sees the
    // whole ordered stream without interfering with the pacing awaits.
    let mut rx_all = h.engine.subscribe();
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "你好世界").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    let mut stream_events = Vec::new();
    let mut body = String::new();
    while let Ok(envelope) = rx_all.try_recv() {
        match envelope.event {
            EngineEvent::RectifyThinkingDelta { delta } => {
                stream_events.push(format!("think {delta:?}"))
            }
            EngineEvent::RectifiedTextChunk { delta } => {
                stream_events.push(format!("chunk {delta:?}"));
                body.push_str(&delta);
            }
            _ => {}
        }
    }
    assert_eq!(
        stream_events,
        vec![
            "think \"先听原句\"",
            "think \":\"",
            "chunk \"修好\"",
            "think \"回头看\"",
            "chunk \"了\"",
        ]
    );
    assert_eq!(body, "修好了");
}

/// The thinking characters never ride any other vehicle: not a
/// `RectifiedTextChunk` (the preview text is shell-accumulated from
/// exactly those), not the inserted text, not any other event (the
/// marquee's 「永不进修正正文」, enforced at the engine seam).
#[tokio::test]
async fn the_thinking_text_rides_only_its_own_event() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("你好世界".into())]],
        vec![vec![
            LlmStep::Think("这段思考文本绝不能进入正文".into()),
            LlmStep::Token("修好了".into()),
        ]],
    );

    let mut rx_all = h.engine.subscribe();
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "你好世界").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, SessionState::Idle).await;

    let mut body = String::new();
    let mut inserted = String::new();
    let mut leaked = false;
    while let Ok(envelope) = rx_all.try_recv() {
        match envelope.event {
            EngineEvent::RectifiedTextChunk { delta } => body.push_str(&delta),
            EngineEvent::TextInserted { text } => inserted.push_str(&text),
            EngineEvent::RectifyThinkingDelta { .. } => {}
            other => {
                if format!("{other:?}").contains("思考文本绝不能") {
                    leaked = true;
                }
            }
        }
    }
    assert_eq!(body, "修好了");
    assert_eq!(inserted, "修好了");
    assert!(!leaked, "thinking text appeared outside its own event");
}

/// A cancelled attempt stops the thinking feed with the body feed: no
/// straggler `RectifyThinkingDelta` after the terminal state change
/// (the stream-event gate drops both once the session left Rectifying).
#[tokio::test]
async fn cancelling_mid_thinking_leaves_no_thinking_straggler() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("你好世界".into())]],
        vec![vec![LlmStep::Think("想".into()), LlmStep::Token("修".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "你好世界").await;
    ok(&h.engine, Command::StopSession).await;
    // Cancel once the thinking feed has provably started.
    let _ = next_matching(&mut rx, |env| {
        matches!(env.event, EngineEvent::RectifyThinkingDelta { .. })
    })
    .await;
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;

    let summary = summarize_of(&mut rx);
    assert!(
        !summary.iter().any(|s| s.starts_with("think")),
        "stragglers after idle: {summary:?}"
    );
}

fn summarize_of(
    rx: &mut tokio::sync::broadcast::Receiver<spokenrectifier_engine::EventEnvelope>,
) -> Vec<String> {
    let mut events = Vec::new();
    while let Ok(envelope) = rx.try_recv() {
        events.push(envelope);
    }
    summarize(&events)
}
