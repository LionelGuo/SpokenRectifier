//! sr-eval: the fidelity eval runner's CLI front door (工单 10) — the
//! 保真铁律's machine acceptance and the regression net for prompt
//! iterations.
//!
//! Usage: sr-eval [--suite <file>] [--only <id-or-prefix>] [--form on|off] [--report <file>]
//!
//! The harness itself lives in `spokenrectifier-eval` (`runner::run_suite`)
//! and rides the engine seam: every case's transcript goes in as
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

use spokenrectifier_engine::RectifyLlm;
use spokenrectifier_eval::cases::{EvalCase, default_suite_path, load_suite};
use spokenrectifier_eval::report::{ReportMeta, build_report};
use spokenrectifier_eval::runner::{RunEvent, run_suite};
use spokenrectifier_llm::{OpenAiCompatLlm, load_llm_config};

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
    // None = both forms (the file as authored). `on`/`off` keep the two
    // BASELINE anchors from mixing (ADR-0014): 94.3% stays the on-form
    // 35, the off-form arm is its own line.
    let mut form: Option<bool> = None;
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
            "--form" => {
                let value = args
                    .next()
                    .ok_or_else(|| "--form needs on or off".to_string())?;
                form = Some(match value.as_str() {
                    "on" => true,
                    "off" => false,
                    _ => return Err(format!("--form expected on or off, got {value:?}")),
                });
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
        .filter(|c| match form {
            None => true,
            Some(on) => c.pass_through != on,
        })
        .collect();
    if cases.is_empty() {
        return Err(format!("no cases match in {}", suite_path.display()));
    }
    // The selected subset becomes the suite under run: the report and
    // the progress totals reflect exactly what was asked for.
    let selected = spokenrectifier_eval::cases::EvalSuite {
        terms: suite.terms.clone(),
        cases: cases.into_iter().cloned().collect(),
    };

    // The same layer-file search the app uses; the [llm] key lives in
    // the git-ignored local layer.
    let dirs = spokenrectifier_config::search_dirs();
    let llm_config = load_llm_config(&dirs).map_err(|err| err.to_string())?;
    // Two form-clients (ADR-0014): the production client applies the
    // tiers' prefill keys from its own config, so the eval arm states
    // the value here rather than writing the request field the client
    // would overwrite. Both are eval-isolated copies — the light-touch
    // extra directive never rides a run (ADR-0016). Thinking and the
    // rest of the loaded config stay as-is on both — the probe's
    // thinking flip is a layer-file change, not a per-case one.
    let mut on_config = llm_config.clone().for_eval();
    on_config.rectify.full.prefill = true;
    on_config.rectify.light_touch.tier.prefill = true;
    let mut off_config = llm_config.clone().for_eval();
    off_config.rectify.full.prefill = false;
    off_config.rectify.light_touch.tier.prefill = false;
    let on_llm: Arc<dyn RectifyLlm> =
        Arc::new(OpenAiCompatLlm::new(on_config).map_err(|err| err.0)?);
    let off_llm: Arc<dyn RectifyLlm> =
        Arc::new(OpenAiCompatLlm::new(off_config).map_err(|err| err.0)?);

    let outcomes = run_suite(on_llm, off_llm, &selected, &|event| {
        match event {
            RunEvent::CaseStarted { index, total, id } => {
                eprintln!("[{index}/{total}] {id} …");
            }
            RunEvent::CaseFinished {
                passed,
                duration_ms,
                ..
            } => {
                eprintln!(
                    "         {} ({:.1}s)",
                    if passed { "ok" } else { "FAIL" },
                    duration_ms as f64 / 1000.0
                );
            }
        }
        true
    })
    .await?;

    let meta = ReportMeta {
        date: chrono::Local::now().format("%Y-%m-%d %H:%M").to_string(),
        model: llm_config.model.model.clone(),
        light_touch_max_chars: llm_config.rectify.light_touch.max_chars,
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
