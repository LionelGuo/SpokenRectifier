//! The rectify hard cap: one wall-clock budget per attempt, visible as an
//! Error event, cancellable at any moment.

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use tokio::sync::broadcast;

use common::{await_live, await_state, expect_quiet, next_matching, ok};
use spokenrectifier_engine::fakes::{AsrStep, ScriptedAsr};
use spokenrectifier_engine::provider::llm::{
    RectifyError, RectifyLlm, RectifyRequest, RectifyTokenStream,
};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, SessionState,
};

/// A rectify LLM whose stream never yields: the server that hangs.
struct HangingLlm;

#[async_trait]
impl RectifyLlm for HangingLlm {
    async fn rectify(&self, _request: RectifyRequest) -> Result<RectifyTokenStream, RectifyError> {
        Ok(futures::stream::pending().boxed())
    }
}

/// Succeeds on the first call, then hangs: one good attempt followed by a
/// reroll that stalls.
struct OnceThenHanging {
    calls: AtomicU32,
}

#[async_trait]
impl RectifyLlm for OnceThenHanging {
    async fn rectify(&self, _request: RectifyRequest) -> Result<RectifyTokenStream, RectifyError> {
        if self.calls.fetch_add(1, Ordering::SeqCst) == 0 {
            return Ok(futures::stream::iter(vec![Ok("第一次".to_string())]).boxed());
        }
        Ok(futures::stream::pending().boxed())
    }
}

/// Build an engine whose LLM is not the scripted fake. Same shape as the
/// shared harness otherwise.
fn engine_with_llm(
    config: EngineConfig,
    llm: Arc<dyn RectifyLlm>,
) -> (Engine, broadcast::Receiver<EventEnvelope>) {
    let engine = Engine::new(
        config,
        EngineDeps {
            asr: ScriptedAsr::new(vec![vec![AsrStep::Say("嗯那个原话".into())]]),
            llm,
            inserter: spokenrectifier_engine::fakes::FakeInserter::new(),
            history: None,
            terms: None,
            clock: spokenrectifier_engine::fakes::FakeClock::new(1_000),
        },
    );
    let rx = engine.subscribe();
    (engine, rx)
}

async fn reach_rectifying(engine: &Engine, rx: &mut broadcast::Receiver<EventEnvelope>) {
    ok(engine, Command::StartSession).await;
    await_live(rx, "嗯那个原话").await;
    ok(engine, Command::StopSession).await;
    await_state(rx, SessionState::Rectifying).await;
}

#[tokio::test]
async fn a_stalled_rectify_times_out_with_a_visible_error_and_returns_to_idle() {
    let (engine, mut rx) = engine_with_llm(
        EngineConfig {
            rectify_timeout_ms: 80,
            ..EngineConfig::default()
        },
        Arc::new(HangingLlm),
    );

    reach_rectifying(&engine, &mut rx).await;

    let envelope = next_matching(&mut rx, |env| {
        matches!(env.event, EngineEvent::Error { .. })
    })
    .await;
    let EngineEvent::Error { message } = envelope.event else {
        unreachable!()
    };
    assert!(message.contains("timed out"), "got: {message}");
    await_state(&mut rx, SessionState::Idle).await;
    expect_quiet(&mut rx, 150).await;
}

#[tokio::test]
async fn a_stream_that_finishes_within_the_budget_is_not_cut() {
    // 120 ms of per-token delay inside a 2 s budget: slow, but legal.
    let llm = Arc::new(SlowLlm);

    let (engine, mut rx) = engine_with_llm(
        EngineConfig {
            rectify_timeout_ms: 2_000,
            ..EngineConfig::default()
        },
        llm,
    );

    reach_rectifying(&engine, &mut rx).await;
    await_state(&mut rx, SessionState::Preview).await;
}

/// Streams two deltas with 120 ms of delay between them.
struct SlowLlm;

#[async_trait]
impl RectifyLlm for SlowLlm {
    async fn rectify(&self, _request: RectifyRequest) -> Result<RectifyTokenStream, RectifyError> {
        Ok(futures::stream::iter(["慢慢", "来"])
            .then(|delta| async move {
                tokio::time::sleep(Duration::from_millis(120)).await;
                Ok::<_, RectifyError>(delta.to_string())
            })
            .boxed())
    }
}

#[tokio::test]
async fn a_reroll_gets_a_fresh_budget() {
    let (engine, mut rx) = engine_with_llm(
        EngineConfig {
            rectify_timeout_ms: 80,
            ..EngineConfig::default()
        },
        Arc::new(OnceThenHanging {
            calls: AtomicU32::new(0),
        }),
    );

    reach_rectifying(&engine, &mut rx).await;
    next_matching(
        &mut rx,
        |env| matches!(&env.event, EngineEvent::RectifiedTextChunk { delta } if delta == "第一次"),
    )
    .await;
    await_state(&mut rx, SessionState::Preview).await;

    // The reroll stalls, and its own budget expires — not the spent one.
    ok(&engine, Command::Reroll).await;
    await_state(&mut rx, SessionState::Rectifying).await;
    let envelope = next_matching(&mut rx, |env| {
        matches!(env.event, EngineEvent::Error { .. })
    })
    .await;
    let EngineEvent::Error { message } = envelope.event else {
        unreachable!()
    };
    assert!(message.contains("timed out"), "got: {message}");
    await_state(&mut rx, SessionState::Idle).await;
}

#[tokio::test]
async fn cancel_during_a_stalled_rectify_wins_over_the_clock() {
    let (engine, mut rx) = engine_with_llm(
        EngineConfig {
            rectify_timeout_ms: 10_000,
            ..EngineConfig::default()
        },
        Arc::new(HangingLlm),
    );

    reach_rectifying(&engine, &mut rx).await;
    ok(&engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Cancelled).await;
    await_state(&mut rx, SessionState::Idle).await;
    // No late error once the session is gone.
    expect_quiet(&mut rx, 150).await;
}
