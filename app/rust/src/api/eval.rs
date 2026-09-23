//! The fidelity eval (保真评测, ticket 18): the run's live event wire
//! and its start call.

use crate::frb_generated::StreamSink;

/// Live progress from one fidelity-eval run: per-case start/finish, and
/// the terminal `Finished` (summary) or `Failed` (setup error or abort).
#[derive(Debug, Clone)]
pub enum BridgeEvalEvent {
    /// The suite loaded and the first case is about to run.
    Started {
        total: u32,
    },
    CaseStarted {
        index: u32,
        total: u32,
        id: String,
    },
    CaseFinished {
        index: u32,
        id: String,
        passed: bool,
    },
    /// The run completed; the summary carries everything the pane paints.
    Finished {
        summary: BridgeEvalSummary,
    },
    /// The run never completed (missing LLM config, an aborted run, an
    /// engine-level failure).
    Failed {
        message: String,
    },
}

/// What a finished run reports: the pass rate against the recorded
/// baseline, failure counts per category, and the failed cases with
/// their machine-verdict details.
#[derive(Debug, Clone)]
pub struct BridgeEvalSummary {
    pub total: u32,
    pub passed: u32,
    pub failed: u32,
    /// Cases that never produced output to check (engine/LLM errors) —
    /// already inside `failed`, broken out for display.
    pub exec_failed: u32,
    /// Passed share, 0.0–100.0.
    pub rate_percent: f64,
    /// The recorded baseline (BASELINE.md beside the suite) the run
    /// compares against.
    pub baseline_percent: f64,
    /// Which LLM actually ran the cases.
    pub model: String,
    /// Failure counts per category, display order (Chinese labels).
    pub categories: Vec<BridgeEvalCategory>,
    /// The failed cases only, with assertion details.
    pub failed_cases: Vec<BridgeEvalCaseDetail>,
}

/// One category line in the summary (label + count).
#[derive(Debug, Clone)]
pub struct BridgeEvalCategory {
    pub label: String,
    pub count: u32,
}

/// One failed case: the engine-level error when the case never produced
/// output, else the assertion verdicts that failed.
#[derive(Debug, Clone)]
pub struct BridgeEvalCaseDetail {
    pub id: String,
    pub error: Option<String>,
    pub failures: Vec<String>,
}

/// Start one fidelity-eval run in the background — the settings window's
/// manual entry. Every case rides the event stream; the run ends with
/// `Finished` or `Failed`. Dropping the Dart listener (window closed,
/// pane cancelled) aborts the run at the next case boundary. Only one
/// run at a time: a second call while running is an error.
///
/// The run builds its own engine instance (noop inserter, no history
/// recorder, the suite's fixed term list) against the real configured
/// LLM — the app's live engine is never touched, so the eval neither
/// inserts text nor pollutes history (the sr-eval seam, in-process).
pub fn start_fidelity_eval(sink: StreamSink<BridgeEvalEvent>) -> anyhow::Result<()> {
    crate::eval_runner::start(sink)
}
