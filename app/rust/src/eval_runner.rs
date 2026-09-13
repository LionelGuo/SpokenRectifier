//! The fidelity eval's process-side orchestration (保真评测, ticket 18):
//! one background thread per run, owning its own single-thread runtime
//! and a dedicated engine instance (the runner's own — the app's live
//! engine is never touched, which is what makes the run side-effect
//! free: no insertion, no history, no term leakage).
//!
//! Lives outside `api.rs` so flutter_rust_bridge's codegen (which
//! mirrors the whole api module) picks up only the wire function and
//! types, not the machinery.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::api::{BridgeEvalCaseDetail, BridgeEvalCategory, BridgeEvalEvent, BridgeEvalSummary};
use crate::frb_generated::StreamSink;
use spokenrectifier_engine::RectifyLlm;
use spokenrectifier_eval::cases::embedded_suite;
use spokenrectifier_eval::report::{EvalSummary, BASELINE_PASS_RATE};
use spokenrectifier_eval::runner::{run_suite, RunEvent, RUN_ABORTED};

/// One run at a time, process-wide (both Flutter engines share the one
/// dylib this static lives in).
static RUNNING: AtomicBool = AtomicBool::new(false);

/// Spawn one eval run feeding `sink`. Every case reports live; the run
/// closes with `Finished` (summary) or `Failed` (setup or abort). A
/// dropped Dart listener (the window closed, the pane cancelled) fails
/// the next sink write and stops the run at the next case boundary.
pub fn start(sink: StreamSink<BridgeEvalEvent>) -> anyhow::Result<()> {
    if RUNNING
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return Err(anyhow::anyhow!(
            "上一轮评测仍在收尾(在途用例最长 120 秒),请稍候再试"
        ));
    }
    std::thread::Builder::new()
        .name("fidelity-eval".into())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(err) => {
                    let _ = sink.add(BridgeEvalEvent::Failed {
                        message: format!("cannot start the eval runtime: {err}"),
                    });
                    RUNNING.store(false, Ordering::SeqCst);
                    return;
                }
            };
            let verdict = run(&runtime, &sink);
            match verdict {
                Ok(summary) => {
                    let _ = sink.add(BridgeEvalEvent::Finished { summary });
                }
                Err(message) => {
                    let _ = sink.add(BridgeEvalEvent::Failed { message });
                }
            }
            RUNNING.store(false, Ordering::SeqCst);
        })
        .map_err(|err| {
            RUNNING.store(false, Ordering::SeqCst);
            anyhow::anyhow!("cannot spawn the eval thread: {err}")
        })?;
    Ok(())
}

fn run(
    runtime: &tokio::runtime::Runtime,
    sink: &StreamSink<BridgeEvalEvent>,
) -> Result<BridgeEvalSummary, String> {
    // Real LLM only: the eval says nothing about the demo script, and a
    // scripted run would read as a broken rectifier.
    let dirs = spokenrectifier_config::search_dirs();
    let llm_config =
        spokenrectifier_llm::load_llm_config(&dirs).map_err(|err| format!("LLM {err}"))?;
    if llm_config
        .model
        .resolve_key()
        .is_none_or(|key| key.is_empty())
    {
        return Err(
            "评测需要真实 LLM 连接:[llm] 未解析到 api_key(评测不会退回演示剧本),\
             请在配置中加入 api_key 后重试"
                .into(),
        );
    }
    let model = llm_config.model.model.clone();
    // Two form-clients (ADR-0014): the production client applies
    // `[llm] prefill` from its own config, so the eval arm states the
    // value here rather than writing the request field the client
    // would overwrite. The settings-window run is the on-form
    // baseline plus the bundled off-form cases, same as `sr-eval`.
    let mut on_config = llm_config.clone();
    on_config.prefill = true;
    let mut off_config = llm_config.clone();
    off_config.prefill = false;
    let on_llm: Arc<dyn RectifyLlm> = Arc::new(
        spokenrectifier_llm::OpenAiCompatLlm::new(on_config)
            .map_err(|err| format!("LLM {}", err.0))?,
    );
    let off_llm: Arc<dyn RectifyLlm> = Arc::new(
        spokenrectifier_llm::OpenAiCompatLlm::new(off_config)
            .map_err(|err| format!("LLM {}", err.0))?,
    );

    // The settings-window run is the on-form regression net (the 94.3%
    // anchor, ADR-0014): off-form cases live in the same suite for the
    // CLI probe (`--form off` / `--only placeholder-off`) and must not
    // mix into this number. The prefill switch has no settings UI yet.
    let mut suite = embedded_suite().map_err(|err| format!("内置评测套件无效:{err}"))?;
    suite.cases.retain(|c| !c.pass_through);
    let total = suite.cases.len() as u32;
    if sink.add(BridgeEvalEvent::Started { total }).is_err() {
        return Err(RUN_ABORTED.into());
    }

    let outcomes = runtime
        .block_on(run_suite(on_llm, off_llm, &suite, &|event| {
            let outgoing = match event {
                RunEvent::CaseStarted { index, total, id } => BridgeEvalEvent::CaseStarted {
                    index: index as u32,
                    total: total as u32,
                    id: id.to_string(),
                },
                RunEvent::CaseFinished {
                    index, id, passed, ..
                } => BridgeEvalEvent::CaseFinished {
                    index: index as u32,
                    id: id.to_string(),
                    passed,
                },
            };
            sink.add(outgoing).is_ok()
        }))
        .map_err(|message| {
            if message == RUN_ABORTED {
                "评测已取消".to_string()
            } else {
                message
            }
        })?;

    let summary = EvalSummary::of(&outcomes);
    Ok(BridgeEvalSummary {
        total: summary.total as u32,
        passed: summary.passed as u32,
        failed: summary.failed as u32,
        exec_failed: summary.exec_failed as u32,
        rate_percent: summary.rate_percent,
        baseline_percent: BASELINE_PASS_RATE,
        model,
        categories: summary
            .category_counts
            .iter()
            .map(|(category, count)| BridgeEvalCategory {
                label: category.name().to_string(),
                count: *count as u32,
            })
            .collect(),
        failed_cases: outcomes
            .iter()
            .filter(|outcome| !outcome.passed())
            .map(|outcome| BridgeEvalCaseDetail {
                id: outcome.id.clone(),
                error: outcome.error.clone(),
                failures: outcome
                    .failures
                    .iter()
                    .map(|failure| format!("[{}] {}", failure.category.name(), failure.detail))
                    .collect(),
            })
            .collect(),
    })
}
