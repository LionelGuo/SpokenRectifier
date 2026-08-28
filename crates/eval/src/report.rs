//! Report building for the fidelity eval (glossary: 保真铁律).
//!
//! Pure markdown composition: outcomes in, one string out. The header
//! carries the identity of the run (date, model, threshold, commit) so a
//! recorded baseline stays comparable across prompt iterations.

use super::check::{Failure, FailureCategory};

/// Who ran: run identity, supplied by the runner (the library has no
/// clock or git).
#[derive(Debug, Clone)]
pub struct ReportMeta {
    pub date: String,
    pub model: String,
    pub light_touch_max_chars: usize,
    pub commit: String,
}

/// What happened to one case.
#[derive(Debug, Clone)]
pub struct CaseOutcome {
    pub id: String,
    /// The final rectified text (empty when the run itself failed).
    pub output: String,
    pub failures: Vec<Failure>,
    /// Engine/LLM-level failure (timeout, API error): the case did not
    /// produce output to check.
    pub error: Option<String>,
    pub duration_ms: u64,
}

impl CaseOutcome {
    pub fn passed(&self) -> bool {
        self.error.is_none() && self.failures.is_empty()
    }
}

/// Every category the summary line tallies, in display order. The five
/// assertion categories plus execution failures.
const CATEGORIES: [FailureCategory; 5] = [
    FailureCategory::Fabricated,
    FailureCategory::Lost,
    FailureCategory::OverRectified,
    FailureCategory::PreservationFailed,
    FailureCategory::Residual,
];

/// The pass rate the recorded baseline earned (BASELINE.md beside the
/// suite: run at commit 2342441 on deepseek-v4-flash, 20/23 = 87.0%) —
/// the number an interactive run in the settings window is compared
/// against. Update it whenever a new baseline is recorded there.
pub const BASELINE_PASS_RATE: f64 = 87.0;

/// The structured summary behind the markdown report — what the
/// settings window paints as the 通过率 + 失败类别摘要. Pure over the
/// outcomes, same numbers the report header carries.
#[derive(Debug, Clone, PartialEq)]
pub struct EvalSummary {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    /// Cases that never produced output to check (engine/LLM errors) —
    /// already inside `failed`, broken out for display.
    pub exec_failed: usize,
    /// Passed share, 0.0–100.0.
    pub rate_percent: f64,
    /// Failure counts per assertion category, in display order (zero
    /// counts included; execution failures are not a category).
    pub category_counts: Vec<(FailureCategory, usize)>,
}

impl EvalSummary {
    pub fn of(outcomes: &[CaseOutcome]) -> Self {
        let total = outcomes.len();
        let passed = outcomes.iter().filter(|o| o.passed()).count();
        let rate = if total == 0 {
            0.0
        } else {
            passed as f64 * 100.0 / total as f64
        };
        let category_counts = CATEGORIES
            .iter()
            .map(|category| {
                let count = outcomes
                    .iter()
                    .flat_map(|o| &o.failures)
                    .filter(|f| f.category == *category)
                    .count();
                (*category, count)
            })
            .collect();
        Self {
            total,
            passed,
            failed: total - passed,
            exec_failed: outcomes.iter().filter(|o| o.error.is_some()).count(),
            rate_percent: rate,
            category_counts,
        }
    }
}

/// Compose the full markdown report.
pub fn build_report(meta: &ReportMeta, outcomes: &[CaseOutcome]) -> String {
    let summary = EvalSummary::of(outcomes);

    let mut report = String::new();
    report.push_str("# 保真评测报告\n\n");
    report.push_str(&format!(
        "- 日期:{}\n- 模型:{}(轻修阈值 {} 字)\n- commit:{}\n",
        meta.date, meta.model, meta.light_touch_max_chars, meta.commit
    ));
    report.push_str(&format!(
        "- 用例 {} · 通过 {} · 失败 {} · 通过率 {:.1}%\n\n",
        summary.total, summary.passed, summary.failed, summary.rate_percent
    ));

    let mut parts: Vec<String> = summary
        .category_counts
        .iter()
        .map(|(category, count)| format!("{} {}", category.name(), count))
        .collect();
    parts.push(format!("执行失败 {}", summary.exec_failed));
    report.push_str(&format!("失败分类:{}\n", parts.join(" ")));

    let bad: Vec<&CaseOutcome> = outcomes.iter().filter(|o| !o.passed()).collect();
    if !bad.is_empty() {
        report.push_str("\n## 失败明细\n");
        for outcome in bad {
            report.push_str(&format!("\n### {}\n", outcome.id));
            if let Some(error) = &outcome.error {
                report.push_str(&format!("- [执行失败] {error}\n"));
            }
            for failure in &outcome.failures {
                report.push_str(&format!(
                    "- [{}] {}\n",
                    failure.category.name(),
                    failure.detail
                ));
            }
            if !outcome.output.trim().is_empty() {
                report.push_str(&format!("\n> {}\n", outcome.output.replace('\n', "\n> ")));
            }
        }
    }

    report.push_str("\n## 全部用例\n\n");
    report.push_str("| 用例 | 结果 | 耗时 |\n| --- | --- | --- |\n");
    for outcome in outcomes {
        let verdict = if outcome.passed() {
            "通过"
        } else if outcome.error.is_some() {
            "执行失败"
        } else {
            "失败"
        };
        report.push_str(&format!(
            "| {} | {} | {:.1}s |\n",
            outcome.id,
            verdict,
            outcome.duration_ms as f64 / 1000.0
        ));
    }
    report
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta() -> ReportMeta {
        ReportMeta {
            date: "2026-08-26 22:41".into(),
            model: "deepseek-v4-flash".into(),
            light_touch_max_chars: 40,
            commit: "2342441".into(),
        }
    }

    fn passed(id: &str) -> CaseOutcome {
        CaseOutcome {
            id: id.into(),
            output: "输出".into(),
            failures: vec![],
            error: None,
            duration_ms: 3200,
        }
    }

    #[test]
    fn a_clean_run_reports_full_pass_rate_and_no_details_section() {
        let report = build_report(
            &meta(),
            &[passed("correction-date"), passed("short-simple")],
        );
        assert!(report.contains("用例 2 · 通过 2 · 失败 0 · 通过率 100.0%"));
        assert!(!report.contains("失败明细"));
        assert!(report.contains("| short-simple | 通过 | 3.2s |"));
        assert!(report.contains("模型:deepseek-v4-flash(轻修阈值 40 字)"));
    }

    #[test]
    fn failures_are_detailed_with_category_tags_and_output() {
        let outcome = CaseOutcome {
            id: "correction-date".into(),
            output: "会议定在周四上午十点。".into(),
            failures: vec![
                Failure {
                    category: FailureCategory::Lost,
                    detail: "关键意思缺失:分页设计 / 分页".into(),
                },
                Failure {
                    category: FailureCategory::PreservationFailed,
                    detail: "未逐字保留:302会议室".into(),
                },
            ],
            error: None,
            duration_ms: 4100,
        };
        let report = build_report(&meta(), &[outcome]);
        assert!(report.contains("用例 1 · 通过 0 · 失败 1 · 通过率 0.0%"));
        assert!(report.contains("失败分类:捏造 0 丢失 1 过度改写 0 保留失败 1 残留 0 执行失败 0"));
        assert!(report.contains("### correction-date"));
        assert!(report.contains("- [丢失] 关键意思缺失:分页设计 / 分页"));
        assert!(report.contains("- [保留失败] 未逐字保留:302会议室"));
        assert!(report.contains("> 会议定在周四上午十点。"));
        assert!(report.contains("| correction-date | 失败 | 4.1s |"));
    }

    #[test]
    fn an_engine_error_is_an_execution_failure_counted_in_the_totals() {
        let outcome = CaseOutcome {
            id: "numeral-large".into(),
            output: String::new(),
            failures: vec![],
            error: Some("timed out waiting for Preview".into()),
            duration_ms: 120_000,
        };
        let report = build_report(&meta(), &[outcome, passed("short-mixed")]);
        assert!(report.contains("用例 2 · 通过 1 · 失败 1 · 通过率 50.0%"));
        assert!(report.contains("执行失败 1"));
        assert!(report.contains("- [执行失败] timed out waiting for Preview"));
        assert!(report.contains("| numeral-large | 执行失败 | 120.0s |"));
    }

    #[test]
    fn multiline_output_is_quoted_line_by_line() {
        let outcome = CaseOutcome {
            id: "correction-date".into(),
            output: "第一行\n第二行".into(),
            failures: vec![Failure {
                category: FailureCategory::Residual,
                detail: "应清除的口头残留:嗯".into(),
            }],
            error: None,
            duration_ms: 500,
        };
        let report = build_report(&meta(), &[outcome]);
        assert!(report.contains("\n> 第一行\n> 第二行\n"));
    }

    #[test]
    fn the_summary_counts_categories_with_zeros_and_breaks_out_exec_failures() {
        let outcomes = vec![
            passed("terms-url"),
            CaseOutcome {
                id: "correction-date".into(),
                output: "输出".into(),
                failures: vec![
                    Failure {
                        category: FailureCategory::Lost,
                        detail: "关键意思缺失:分页".into(),
                    },
                    Failure {
                        category: FailureCategory::Lost,
                        detail: "关键意思缺失:设计".into(),
                    },
                    Failure {
                        category: FailureCategory::Fabricated,
                        detail: "捏造:没说过的话".into(),
                    },
                ],
                error: None,
                duration_ms: 3_000,
            },
            CaseOutcome {
                id: "numeral-large".into(),
                output: String::new(),
                failures: vec![],
                error: Some("timed out".into()),
                duration_ms: 120_000,
            },
        ];

        let summary = EvalSummary::of(&outcomes);
        assert_eq!(summary.total, 3);
        assert_eq!(summary.passed, 1);
        assert_eq!(summary.failed, 2);
        assert_eq!(summary.exec_failed, 1);
        assert!((summary.rate_percent - 100.0 / 3.0).abs() < 1e-9);
        // Every category appears in display order, zeros included; the
        // execution failure is broken out separately, not as a category.
        let rendered: Vec<String> = summary
            .category_counts
            .iter()
            .map(|(category, count)| format!("{} {count}", category.name()))
            .collect();
        assert_eq!(
            rendered,
            vec!["捏造 1", "丢失 2", "过度改写 0", "保留失败 0", "残留 0"]
        );
    }
}
