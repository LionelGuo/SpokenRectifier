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
use super::check::{check_parts, sentinel_counts};
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
/// stream → Preview → Cancel. Returns the rectified body (inline forms
/// verbatim — the engine's splitter only ever holds a half-grown `‡N`
/// run off the stream) and the prefill rows resolved from them (riding
/// `PreviewPrefills`, arriving before the Preview state change), or the
/// engine's own error message when the session aborted.
async fn rectify_case(
    engine: &Engine,
    rx: &mut broadcast::Receiver<EventEnvelope>,
    transcript: &str,
) -> Result<(String, Vec<(u32, String)>), String> {
    let mut accumulated = String::new();
    let mut prefill: Vec<(u32, String)> = Vec::new();
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
                    EngineEvent::PreviewPrefills { prefills } => {
                        prefill = prefills
                            .iter()
                            .map(|row| (row.number, row.value.clone()))
                            .collect();
                    }
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
            Ok((accumulated, prefill))
        }
        // The session ended on its own (an engine or LLM error already
        // carried the verdict): there is nothing to cancel, and trying
        // would only mask the real message with a rejected command.
        Err(message) => Err(message),
    }
}

/// Run the whole suite against the two form-clients, reporting every
/// case's start and finish through `on_event`. Returning `false` from
/// the callback aborts at the next case boundary; the run then fails
/// with [`RUN_ABORTED`] instead of half a suite (the caller asked for
/// the stop).
///
/// `on_llm` / `off_llm` are the two prompt forms (ADR-0014): the
/// production client applies `[llm] prefill` from its own config, so
/// the eval arm states the value by handing in two clients rather than
/// writing the request field the client would overwrite. A case with
/// `pass_through` swaps to `off_llm` for that attempt (and back); the
/// in-flight call always keeps the LLM it started with.
///
/// The engine instance is the runner's own — the caller's engine (the
/// app's singleton, say) is never touched, which is what makes the run
/// side-effect-free by construction: no insertion, no history, no term
/// leakage.
pub const RUN_ABORTED: &str = "aborted by the listener";

pub async fn run_suite(
    on_llm: Arc<dyn RectifyLlm>,
    off_llm: Arc<dyn RectifyLlm>,
    suite: &EvalSuite,
    on_event: &(dyn Fn(RunEvent<'_>) -> bool + Send + Sync),
) -> Result<Vec<CaseOutcome>, String> {
    let (asr, _scripter) = ChannelAsr::new();
    let engine = Engine::new(
        EngineConfig::default(),
        EngineDeps {
            asr,
            llm: on_llm.clone(),
            inserter: Arc::new(NoopInserter),
            history: None,
            terms: Some(Arc::new(FixedTermSource {
                terms: suite.terms.clone(),
            })),
            clock: Arc::new(TokioClock::new()),
        },
    );
    let mut rx = engine.subscribe();
    // The engine starts on the on-form client; swap only when the
    // next case's form disagrees, so a homogeneous suite never
    // touches the slot.
    let mut using_off = false;

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
        if case.pass_through != using_off {
            engine.set_llm_provider(if case.pass_through {
                off_llm.clone()
            } else {
                on_llm.clone()
            });
            using_off = case.pass_through;
        }
        let started = Instant::now();
        let outcome = match rectify_case(&engine, &mut rx, &case.transcript).await {
            Ok((text, prefill)) => {
                let trimmed = text.trim();
                // The chunks carry the body verbatim (inline forms
                // included); the rows ride the PreviewPrefills event —
                // the assertions take the split parts here, and
                // check_parts collapses the inline forms out of the
                // body probes' view itself.
                let pinned = sentinel_counts(&case.transcript);
                CaseOutcome {
                    id: case.id.clone(),
                    failures: check_parts(case, trimmed, &prefill, &pinned),
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
        let llm = scripted(&["alpha 的书面语", "别的词的书面语"]);
        let outcomes = run_suite(llm.clone(), llm, &suite, &|event| {
            seen.lock().unwrap().push(mark(event));
            true
        })
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
        let llm = scripted(&["alpha", "beta"]);
        let outcomes = run_suite(llm.clone(), llm, &suite, &|event| {
            !matches!(event, RunEvent::CaseStarted { index: 2, .. })
        })
        .await;

        assert_eq!(outcomes.unwrap_err(), RUN_ABORTED);
    }

    #[tokio::test]
    async fn an_llm_failure_lands_as_an_execution_error_not_a_pass() {
        let suite = suite_of(&["alpha"]);
        let llm = ScriptedLlm::new(vec![vec![LlmStep::Fail("上游 502".into())]]);
        let outcomes = run_suite(llm.clone(), llm, &suite, &|_| true)
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

    #[tokio::test]
    async fn prefill_rows_ride_the_event_and_reach_the_absorption_assertions() {
        // Inline prefills (ruling 26, tickets 28+30): the engine streams
        // the body verbatim — inline form and all — and the rows ride
        // `PreviewPrefills`. A response whose inline value carries the
        // referent must pass its absorption assertion (the value is
        // invisible to the body probes through the collapse), and one
        // with only a bare sentinel must fail on the empty value — the
        // wiring this locks (the live baseline once read empty for
        // every slot because the runner re-checked a body-only text).
        use crate::cases::PrefillExpectation;
        use crate::check::FailureCategory;

        let pinned_case = |id: &'static str| crate::cases::EvalCase {
            id: id.into(),
            transcript: "发给那个谁‡1‡一份材料".into(),
            convey: vec![vec!["材料".into()]],
            absorbed: vec!["那个谁".into()],
            prefill: vec![PrefillExpectation {
                pin: 1,
                any: vec!["李四".into()],
            }],
            ..EvalCase::default()
        };
        let suite = EvalSuite {
            terms: vec![],
            cases: vec![pinned_case("with-row"), pinned_case("bare-only")],
        };
        let llm = scripted(&["发给‡1:李四‡一份材料。", "发给‡1‡一份材料。"]);
        let outcomes = run_suite(llm.clone(), llm, &suite, &|_| true)
            .await
            .unwrap();

        assert_eq!(outcomes.len(), 2);
        assert!(outcomes[0].passed(), "{:?}", outcomes[0].failures);
        assert_eq!(outcomes[0].output, "发给‡1:李四‡一份材料。");
        assert!(!outcomes[1].passed());
        assert_eq!(
            outcomes[1].failures[0].category,
            FailureCategory::AbsorbFailed
        );
    }

    #[tokio::test]
    async fn a_pass_through_case_swaps_to_the_off_client_and_back() {
        // The production client overwrites request.prefill from its
        // config, so the eval arm states the form by swapping clients
        // (ADR-0014). A mixed suite must hit the off client for the
        // flagged case and restore the on client afterwards — call
        // counts, not the request field, are the hop this locks.
        let on = scripted(&["开态书面语", "开态书面语"]);
        let off = scripted(&["关态书面语"]);
        let suite = EvalSuite {
            terms: vec![],
            cases: vec![
                EvalCase {
                    id: "on-first".into(),
                    transcript: "开态书面语 的原话,足够当作一次转写".into(),
                    convey: vec![vec!["开态书面语".into()]],
                    ..EvalCase::default()
                },
                EvalCase {
                    id: "off-middle".into(),
                    transcript: "关态书面语 的原话,足够当作一次转写".into(),
                    convey: vec![vec!["关态书面语".into()]],
                    pass_through: true,
                    ..EvalCase::default()
                },
                EvalCase {
                    id: "on-last".into(),
                    transcript: "开态书面语 的原话,足够当作一次转写".into(),
                    convey: vec![vec!["开态书面语".into()]],
                    ..EvalCase::default()
                },
            ],
        };
        let outcomes = run_suite(on.clone(), off.clone(), &suite, &|_| true)
            .await
            .unwrap();
        assert!(outcomes.iter().all(|o| o.passed()), "{outcomes:?}");
        assert_eq!(on.call_count(), 2);
        assert_eq!(off.call_count(), 1);
        assert_eq!(outcomes[1].output, "关态书面语");
    }
}
