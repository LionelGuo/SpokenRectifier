//! sr-eval: the fidelity eval runner (工单 10) — the 保真铁律's machine
//! acceptance and the regression net for prompt iterations.
//!
//! Usage: sr-eval [--suite <file>] [--only <id-or-prefix>] [--report <file>]
//!
//! Rides the engine seam: every case's transcript goes in as
//! `Command::RectifyText` against the real configured LLM, the streamed
//! chunks accumulate into the preview text, and `Command::Cancel` closes
//! the session without inserting (and without history — no recorder is
//! attached). A fixed TermSource from the suite file feeds the rectify
//! prompt, so a developer's local hotword dictionary cannot leak into a
//! run.
//!
//! Exit code: 0 when every case passes, 1 when any fails, 2 for usage,
//! config, or suite errors. The full markdown report always prints to
//! stdout; `--report` additionally writes it to a file.

use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tokio::sync::broadcast;

use spokenrectifier_engine::fakes::ChannelAsr;
use spokenrectifier_engine::provider::inserter::{InsertError, TextInserter};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, SessionState,
    TermSource, TokioClock,
};
use spokenrectifier_llm::{OpenAiCompatLlm, load_llm_config};
use sr_replay::eval::cases::{EvalCase, default_suite_path, load_suite};
use sr_replay::eval::check::check;
use sr_replay::eval::report::{CaseOutcome, ReportMeta, build_report};

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
    case: &EvalCase,
) -> Result<String, String> {
    let mut accumulated = String::new();
    engine
        .execute(Command::RectifyText(case.transcript.clone()))
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

    // Close the session without inserting, then DRAIN the Cancelled →
    // Idle transitions from the broadcast buffer: they are emitted
    // synchronously inside Cancel, and a stale Idle in the queue would
    // make the NEXT case's wait loop read "session ended" instantly.
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

    outcome.map(|()| accumulated)
}

fn short_commit() -> String {
    std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .ok()
        .filter(|out| out.status.success())
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".into())
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("sr-eval: {err}");
        std::process::exit(2);
    }
}

async fn run() -> Result<(), String> {
    let mut suite_path = default_suite_path();
    let mut only: Option<String> = None;
    let mut report_path: Option<String> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--suite" => {
                suite_path = args
                    .next()
                    .ok_or_else(|| "--suite needs a value".to_string())?
                    .into();
            }
            "--only" => {
                only = Some(
                    args.next()
                        .ok_or_else(|| "--only needs a value".to_string())?,
                );
            }
            "--report" => {
                report_path = Some(
                    args.next()
                        .ok_or_else(|| "--report needs a value".to_string())?,
                );
            }
            _ => return Err(format!("unexpected argument {arg:?}")),
        }
    }

    let suite = load_suite(&suite_path)?;
    let cases: Vec<&EvalCase> = suite
        .cases
        .iter()
        .filter(|c| match &only {
            None => true,
            Some(prefix) => c.id == *prefix || c.id.starts_with(&format!("{prefix}-")),
        })
        .collect();
    if cases.is_empty() {
        return Err(format!("no cases match in {}", suite_path.display()));
    }

    // The same layer-file search the app uses; the [llm] key lives in
    // the git-ignored local layer.
    let dirs = spokenrectifier_config::search_dirs();
    let llm_config = load_llm_config(&dirs).map_err(|err| err.to_string())?;
    let llm = OpenAiCompatLlm::new(llm_config.clone()).map_err(|err| err.0)?;

    let (asr, _scripter) = ChannelAsr::new();
    let engine = Engine::new(
        EngineConfig::default(),
        EngineDeps {
            asr,
            llm: Arc::new(llm),
            inserter: Arc::new(NoopInserter),
            history: None,
            terms: Some(Arc::new(FixedTermSource {
                terms: suite.terms.clone(),
            })),
            clock: Arc::new(TokioClock::new()),
        },
    );
    let mut rx = engine.subscribe();

    let mut outcomes = Vec::with_capacity(cases.len());
    for (n, case) in cases.iter().enumerate() {
        eprintln!("[{}/{}] {} …", n + 1, cases.len(), case.id);
        let started = Instant::now();
        let outcome = match rectify_case(&engine, &mut rx, case).await {
            Ok(text) => CaseOutcome {
                id: case.id.clone(),
                output: text.trim().to_string(),
                failures: check(case, text.trim()),
                error: None,
                duration_ms: started.elapsed().as_millis() as u64,
            },
            Err(message) => CaseOutcome {
                id: case.id.clone(),
                output: String::new(),
                failures: vec![],
                error: Some(message),
                duration_ms: started.elapsed().as_millis() as u64,
            },
        };
        eprintln!(
            "         {} ({:.1}s)",
            if outcome.passed() { "ok" } else { "FAIL" },
            outcome.duration_ms as f64 / 1000.0
        );
        outcomes.push(outcome);
    }

    let meta = ReportMeta {
        date: chrono::Local::now().format("%Y-%m-%d %H:%M").to_string(),
        model: llm_config.model.model.clone(),
        light_touch_max_chars: llm_config.light_touch_max_chars,
        commit: short_commit(),
    };
    let report = build_report(&meta, &outcomes);
    if let Some(path) = report_path {
        let path = std::path::Path::new(&path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|err| format!("cannot create {}: {err}", parent.display()))?;
        }
        std::fs::write(path, &report)
            .map_err(|err| format!("cannot write {}: {err}", path.display()))?;
        eprintln!("report written to {}", path.display());
    }
    println!("{report}");

    let failed = outcomes.iter().filter(|o| !o.passed()).count();
    if failed > 0 {
        std::process::exit(1);
    }
    Ok(())
}
