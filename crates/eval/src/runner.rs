//! The suite runner: drives every case through a dedicated engine
//! instance built exactly like the CLI's — a noop inserter (RectifyText +
//! Cancel never insert, but the dependency needs one), no recorder (no
//! history), and a fixed TermSource from the suite (a developer's local
//! hotword dictionary cannot leak into a run). The engine crate has no
//! global state, so this instance coexists with the app's live engine in
//! one process (ticket 18's bridge).
//!
//! Callers hear every case through one callback: each event is the
//! runner's only chance to be told to stop — returning `false` aborts at
//! the next case boundary (the in-flight LLM call finishes first).

use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tokio::sync::broadcast;

use spokenrectifier_engine::fakes::ChannelAsr;
use spokenrectifier_engine::provider::inserter::{InsertError, TextInserter};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, RectifyLlm,
    SessionState, SessionStyle, TermSource, TokioClock,
};

use super::cases::EvalSuite;
use super::check::check;
use super::report::CaseOutcome;

/// One live event from the running suite.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunEvent<'a> {
    /// A case is about to run (1-based `index`).
    CaseStarted {
        index: usize,
        total: usize,
        id: &'a str,
    },
    /// A case finished; `duration_ms` is the engine round trip.
    CaseFinished {
        index: usize,
        id: &'a str,
        passed: bool,
        duration_ms: u64,
    },
}

/// The suite's fixed dictionary: the same list for every case, immune to
/// whatever `spokenrectifier-terms.txt` sits on this machine.
struct FixedTermSource {
    terms: Vec<String>,
}

impl TermSource for FixedTermSource {
    fn terms(&self) -> Vec<String> {
        self.terms.clone()
    }
}

/// RectifyText + Cancel never insert; the dependency still needs one.
struct NoopInserter;

#[async_trait]
impl TextInserter for NoopInserter {
    async fn insert(&self, _text: &str) -> Result<(), InsertError> {
        Ok(())
    }
}

/// Run one case through the engine: RectifyText → accumulate the chunk
/// stream → Preview → Cancel. Returns the rectified text, or the
/// engine's own error message when the session aborted.
async fn rectify_case(
    engine: &Engine,
    rx: &mut broadcast::Receiver<EventEnvelope>,
    transcript: &str,
) -> Result<String, String> {
    let mut accumulated = String::new();
    engine
        .execute(Command::RectifyText {
            raw_transcript: transcript.to_string(),
            style: SessionStyle::Live,
        })
        .await
        .map_err(|err| format!("command rejected: {err}"))?;

    let outcome = tokio::time::timeout(Duration::from_secs(120), async {
        let mut last_error = String::new();
        loop {
            match rx.recv().await {
                Ok(envelope) => match envelope.event {
                    EngineEvent::RectifiedTextChunk { delta } => accumulated.push_str(&delta),
                    EngineEvent::SessionStateChanged {
                        to: SessionState::Preview,
                        ..
                    } => return Ok(()),
                    EngineEvent::SessionStateChanged {
                        to: SessionState::Idle,
                        ..
                    } => {
                        return Err(if last_error.is_empty() {
                            "session ended before reaching Preview".to_string()
                        } else {
                            last_error
                        });
                    }
                    EngineEvent::Error { message } => last_error = message,
                    _ => {}
                },
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => {
                    return Err("event stream closed".to_string());
                }
            }
        }
    })
    .await
    .map_err(|_| "timed out waiting for Preview".to_string())?;

    match outcome {
        Ok(()) => {
            // Close the session without inserting, then DRAIN the
            // Cancelled → Idle transitions from the broadcast buffer:
            // they are emitted synchronously inside Cancel, and a stale
            // Idle in the queue would make the NEXT case's wait loop
            // read "session ended" instantly.
            engine
                .execute(Command::Cancel)
                .await
                .map_err(|err| format!("cancel failed: {err}"))?;
            tokio::time::timeout(Duration::from_secs(10), async {
                loop {
                    match rx.recv().await {
                        Ok(envelope) => {
                            if let EngineEvent::SessionStateChanged {
                                to: SessionState::Idle,
                                ..
                            } = envelope.event
                            {
                                return;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(broadcast::error::RecvError::Closed) => return,
                    }
                }
            })
            .await
            .map_err(|_| "cancel did not settle into Idle".to_string())?;
            Ok(accumulated)
        }
        // The session ended on its own (an engine or LLM error already
        // carried the verdict): there is nothing to cancel, and trying
        // would only mask the real message with a rejected command.
        Err(message) => Err(message),
    }
}

/// Run the whole suite against `llm`, reporting every case's start and
/// finish through `on_event`. Returning `false` from the callback aborts
/// at the next case boundary; the run then fails with [`RUN_ABORTED`]
/// instead of half a suite (the caller asked for the stop).
///
/// The engine instance is the runner's own — the caller's engine (the
/// app's singleton, say) is never touched, which is what makes the run
/// side-effect-free by construction: no insertion, no history, no term
/// leakage.
pub const RUN_ABORTED: &str = "aborted by the listener";

pub async fn run_suite(
    llm: Arc<dyn RectifyLlm>,
    suite: &EvalSuite,
    on_event: &(dyn Fn(RunEvent<'_>) -> bool + Send + Sync),
) -> Result<Vec<CaseOutcome>, String> {
    let (asr, _scripter) = ChannelAsr::new();
    let engine = Engine::new(
        EngineConfig::default(),
        EngineDeps {
            asr,
            llm,
            inserter: Arc::new(NoopInserter),
            history: None,
            terms: Some(Arc::new(FixedTermSource {
                terms: suite.terms.clone(),
            })),
            clock: Arc::new(TokioClock::new()),
        },
    );
    let mut rx = engine.subscribe();

    let total = suite.cases.len();
    let mut outcomes = Vec::with_capacity(total);
    for (n, case) in suite.cases.iter().enumerate() {
        let index = n + 1;
        if !on_event(RunEvent::CaseStarted {
            index,
            total,
            id: &case.id,
        }) {
            return Err(RUN_ABORTED.to_string());
        }
        let started = Instant::now();
        let outcome = match rectify_case(&engine, &mut rx, &case.transcript).await {
            Ok(text) => {
                let trimmed = text.trim();
                CaseOutcome {
                    id: case.id.clone(),
                    failures: check(case, trimmed),
                    output: trimmed.to_string(),
                    error: None,
                    duration_ms: started.elapsed().as_millis() as u64,
                }
            }
            Err(message) => CaseOutcome {
                id: case.id.clone(),
                output: String::new(),
                failures: vec![],
                error: Some(message),
                duration_ms: started.elapsed().as_millis() as u64,
            },
        };
        let passed = outcome.passed();
        let duration_ms = outcome.duration_ms;
        outcomes.push(outcome);
        if !on_event(RunEvent::CaseFinished {
            index,
            id: &suite.cases[n].id,
            passed,
            duration_ms,
        }) {
            return Err(RUN_ABORTED.to_string());
        }
    }
    Ok(outcomes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cases::EvalCase;
    use spokenrectifier_engine::fakes::{LlmStep, ScriptedLlm};

    /// Chunk a text into scripted token deltas the way the app bridge
    /// does — a few characters at a time, like a streaming LLM.
    fn scripted(responses: &[&str]) -> Arc<ScriptedLlm> {
        let scripts = responses
            .iter()
            .map(|text| {
                let chars: Vec<char> = text.chars().collect();
                chars
                    .chunks(4)
                    .map(|chunk| LlmStep::Token(chunk.iter().collect()))
                    .collect::<Vec<_>>()
            })
            .collect::<Vec<_>>();
        ScriptedLlm::new_cycling(scripts)
    }

    /// A suite whose every case conveys its own id: whether a scripted
    /// response passes is then fully under the test's hand.
    fn suite_of(ids: &[&'static str]) -> EvalSuite {
        EvalSuite {
            terms: vec!["固定词表".into()],
            cases: ids
                .iter()
                .map(|id| EvalCase {
                    id: (*id).into(),
                    transcript: format!("{id} 的原话,足够当作一次转写"),
                    convey: vec![vec![(*id).into()]],
                    ..EvalCase::default()
                })
                .collect(),
        }
    }

    /// Owned rendering of one event, so a higher-ranked callback can
    /// record it beyond the borrow.
    fn mark(event: RunEvent<'_>) -> String {
        match event {
            RunEvent::CaseStarted { index, total, id } => format!("start {index}/{total} {id}"),
            RunEvent::CaseFinished {
                index, id, passed, ..
            } => {
                format!("finish {index} {id} {}", if passed { "ok" } else { "FAIL" })
            }
        }
    }

    #[tokio::test]
    async fn every_case_runs_through_and_finishes_with_its_verdict() {
        // One scripted response per case: the first passes its convey
        // assertion, the second cannot (its keyword never appears).
        let suite = suite_of(&["alpha", "beta"]);
        let seen = std::sync::Mutex::new(Vec::new());
        let outcomes = run_suite(
            scripted(&["alpha 的书面语", "别的词的书面语"]),
            &suite,
            &|event| {
                seen.lock().unwrap().push(mark(event));
                true
            },
        )
        .await
        .unwrap();

        assert_eq!(outcomes.len(), 2);
        assert_eq!(outcomes[0].id, "alpha");
        assert_eq!(outcomes[0].output, "alpha 的书面语");
        assert!(outcomes[0].passed());
        assert!(!outcomes[1].passed());
        assert_eq!(outcomes[1].failures.len(), 1);

        let seen = seen.into_inner().unwrap();
        assert_eq!(
            seen,
            vec![
                "start 1/2 alpha",
                "finish 1 alpha ok",
                "start 2/2 beta",
                "finish 2 beta FAIL",
            ]
        );
    }

    #[tokio::test]
    async fn a_false_callback_aborts_before_the_next_case() {
        let suite = suite_of(&["alpha", "beta"]);
        let outcomes = run_suite(scripted(&["alpha", "beta"]), &suite, &|event| {
            !matches!(event, RunEvent::CaseStarted { index: 2, .. })
        })
        .await;

        assert_eq!(outcomes.unwrap_err(), RUN_ABORTED);
    }

    #[tokio::test]
    async fn an_llm_failure_lands_as_an_execution_error_not_a_pass() {
        let suite = suite_of(&["alpha"]);
        let outcomes = run_suite(
            ScriptedLlm::new(vec![vec![LlmStep::Fail("上游 502".into())]]),
            &suite,
            &|_| true,
        )
        .await
        .unwrap();

        assert_eq!(outcomes.len(), 1);
        let outcome = &outcomes[0];
        assert!(!outcome.passed());
        assert!(
            outcome
                .error
                .as_deref()
                .is_some_and(|message| message.contains("502")),
            "expected the upstream failure, got {outcome:?}"
        );
        // An execution failure carries no assertion verdicts to show.
        assert!(outcome.failures.is_empty());
    }
}
