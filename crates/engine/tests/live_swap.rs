//! Runtime provider swaps (ADR-0010): the engine holds its ASR and LLM
//! behind swappable slots — the ASR adopted when each session opens, the
//! LLM cloned per rectify attempt — so a switch never disturbs a stream
//! or attempt already in flight.

mod common;

use common::{await_live, await_state, expect_quiet, harness, next_matching, ok};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep, ScriptedAsr, ScriptedLlm};
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, SessionState};

/// A swap applies from the next session on, and a session that is already
/// recording keeps the stream it opened: swapping mid-session leaks no
/// event from the new provider into the running transcript.
#[tokio::test]
async fn an_asr_swap_applies_from_the_next_session_not_the_running_one() {
    // The first script ends without a session-ending silence, so the
    // first session stays recording after its one utterance.
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("旧家的原话".into())]],
        vec![vec![LlmStep::Token("旧家的修正".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    // A Say is two live events (partial, then final): drain both before
    // asserting the swap leaks nothing.
    await_live(&mut rx, "旧家的原话").await;
    await_live(&mut rx, "旧家的原话").await;

    // Swap while the session is still recording: the new provider must
    // not leak into the running session's transcript.
    let replacement = ScriptedAsr::new(vec![vec![AsrStep::Say("新家的原话".into())]]);
    h.engine.set_asr_provider(replacement.clone());
    expect_quiet(&mut rx, 50).await;

    // The running session still ends through the OLD stream's rectify
    // path and inserts normally.
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
    assert_eq!(
        h.inserter.inserted_texts().last(),
        Some(&"旧家的修正".to_string())
    );

    // The next session opens with the NEW provider; the old one is never
    // asked again (its only script is spent).
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "新家的原话").await;
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(
        h.asr.opened_terms().len(),
        1,
        "the old provider opened exactly one stream"
    );
    assert_eq!(replacement.opened_terms().len(), 1);
}

/// The LLM swap applies per attempt: a reroll after the swap runs with
/// the new model — the quick way to compare models on the same utterance.
#[tokio::test]
async fn an_llm_swap_applies_from_the_next_attempt_including_reroll() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一句原话".into())]],
        vec![vec![LlmStep::Token("模型一的输出".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一句原话").await;
    ok(&h.engine, Command::StopSession).await;
    next_matching(&mut rx, |env| {
        matches!(&env.event, EngineEvent::RectifiedTextChunk { delta } if delta == "模型一的输出")
    })
    .await;
    await_state(&mut rx, SessionState::Preview).await;

    // Swap models while the preview is showing, then reroll: the new
    // model handles the same frozen utterance.
    let replacement = ScriptedLlm::new(vec![vec![LlmStep::Token("模型二的输出".into())]]);
    h.engine.set_llm_provider(replacement.clone());
    ok(&h.engine, Command::Reroll).await;
    next_matching(&mut rx, |env| {
        matches!(&env.event, EngineEvent::RectifiedTextChunk { delta } if delta == "模型二的输出")
    })
    .await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;

    // The old model answered exactly once, the new one exactly once.
    assert_eq!(h.llm.call_count(), 1);
    assert_eq!(replacement.call_count(), 1);
    assert_eq!(
        h.inserter.inserted_texts().last(),
        Some(&"模型二的输出".to_string())
    );
}
