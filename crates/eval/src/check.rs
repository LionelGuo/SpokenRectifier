//! Assertion checking for the fidelity eval (glossary: 保真铁律, 口头更正,
//! 逐字保留).
//!
//! [`check`] is pure: a case plus a rectified text yield zero or more
//! categorized failures. Every category names a way the fidelity
//! contract can break, so the report can say not just "failed" but
//! how — the axis a prompt iteration needs.

use super::cases::EvalCase;

/// How a case failed. The category IS the report taxonomy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureCategory {
    /// Something noone said appeared in the output.
    Fabricated,
    /// A key idea the transcript conveyed is missing.
    Lost,
    /// A short utterance was reworded or reordered (light-touch breach).
    OverRectified,
    /// A term/URL/number that must survive verbatim did not.
    PreservationFailed,
    /// Something the rectify should have removed survived: filler,
    /// correction lead-ins, superseded values, un-normalized numerals,
    /// un-collapsed repetition.
    Residual,
}

impl FailureCategory {
    /// The Chinese display name used in reports.
    pub fn name(&self) -> &'static str {
        match self {
            FailureCategory::Fabricated => "捏造",
            FailureCategory::Lost => "丢失",
            FailureCategory::OverRectified => "过度改写",
            FailureCategory::PreservationFailed => "保留失败",
            FailureCategory::Residual => "残留",
        }
    }
}

/// One broken assertion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub category: FailureCategory,
    pub detail: String,
}

/// Check one rectified output against a case's assertions. All checks
/// are case-sensitive substring checks; `order` is an in-order
/// subsequence walk over the output.
pub fn check(case: &EvalCase, output: &str) -> Vec<Failure> {
    let mut failures = Vec::new();

    for text in &case.preserve {
        if !output.contains(text.as_str()) {
            failures.push(Failure {
                category: FailureCategory::PreservationFailed,
                detail: format!("未逐字保留:{text}"),
            });
        }
    }

    for group in &case.convey {
        if !group.iter().any(|alt| output.contains(alt.as_str())) {
            failures.push(Failure {
                category: FailureCategory::Lost,
                detail: format!("关键意思缺失:{}", group.join(" / ")),
            });
        }
    }

    for text in &case.fabricate {
        if output.contains(text.as_str()) {
            failures.push(Failure {
                category: FailureCategory::Fabricated,
                detail: format!("出现了未提及的内容:{text}"),
            });
        }
    }

    for text in &case.purge {
        if output.contains(text.as_str()) {
            failures.push(Failure {
                category: FailureCategory::Residual,
                detail: format!("应清除的口头残留:{text}"),
            });
        }
    }

    for text in &case.max_once {
        if output.matches(text.as_str()).count() > 1 {
            failures.push(Failure {
                category: FailureCategory::Residual,
                detail: format!(
                    "重复未收敛:{} ×{}",
                    text,
                    output.matches(text.as_str()).count()
                ),
            });
        }
    }

    if let Some(token) = first_out_of_order(&case.order, output) {
        failures.push(Failure {
            category: FailureCategory::OverRectified,
            detail: format!("措辞或语序被改写:{token} 未按原序出现"),
        });
    }

    failures
}

/// The first `order` token that cannot be found after all its
/// predecessors — `None` when the tokens form a subsequence of the
/// output. Greedy left-to-right; a missing token ends the walk (every
/// later token would also fail).
fn first_out_of_order<'a>(tokens: &'a [String], output: &str) -> Option<&'a str> {
    let mut cursor = 0;
    for token in tokens {
        match output[cursor..].find(token.as_str()) {
            Some(at) => cursor += at + token.len(),
            None => return Some(token),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A case with an id and only the assertion lists a test cares
    /// about; everything else defaults.
    fn case(id: &str) -> EvalCase {
        EvalCase {
            id: id.into(),
            ..Default::default()
        }
    }

    fn strs(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn a_clean_output_produces_no_failures() {
        let mut case = case("mixed-product");
        case.preserve = strs(&["SpokenRectifier", "EGFR"]);
        case.convey = vec![strs(&["语音输入"]), strs(&["抑制剂"])];
        case.fabricate = strs(&["Kubernetes"]);
        case.purge = strs(&["spoken rectifier", "egfr"]);
        let failures = check(
            &case,
            "我们组用 SpokenRectifier 做语音输入,EGFR 抑制剂这类术语也能正确输出。",
        );
        assert!(failures.is_empty(), "{failures:?}");
    }

    #[test]
    fn a_missing_preserve_string_is_a_preservation_failure() {
        let mut case = case("terms-medical");
        case.preserve = strs(&["EGFR"]);
        let failures = check(&case, "医生建议重新评估 egfr 抑制剂的剂量。");
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].category, FailureCategory::PreservationFailed);
        assert!(failures[0].detail.contains("EGFR"));
    }

    #[test]
    fn convey_passes_on_any_alternative() {
        let mut case = case("numeral-large");
        case.convey = vec![strs(&["1200万", "1,200万"])];
        for output in ["总投资1200万元,设备450万", "总投资 1,200万"] {
            assert!(check(&case, output).is_empty(), "{output}");
        }
    }

    #[test]
    fn convey_fails_when_every_alternative_is_missing() {
        let mut case = case("correction-date");
        case.convey = vec![strs(&["分页设计", "分页"])];
        let failures = check(&case, "会议定在周四上午十点。");
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].category, FailureCategory::Lost);
        assert!(failures[0].detail.contains("分页设计"));
    }

    #[test]
    fn a_fabrication_probe_is_reported_when_it_appears() {
        let mut case = case("correction-date");
        case.fabricate = strs(&["周五", "下午"]);
        let failures = check(&case, "会议改到周五下午两点。");
        assert_eq!(failures.len(), 2);
        assert!(
            failures
                .iter()
                .all(|f| f.category == FailureCategory::Fabricated)
        );
    }

    #[test]
    fn surviving_filler_and_superseded_value_are_residual() {
        let mut case = case("correction-multi");
        case.purge = strs(&["海淀区", "8899", "不对"]);
        let failures = check(&case, "地址是海淀区,不对,是朝阳区,尾号8899。");
        assert_eq!(failures.len(), 3);
        assert!(
            failures
                .iter()
                .all(|f| f.category == FailureCategory::Residual)
        );
    }

    #[test]
    fn un_collapsed_repetition_is_residual() {
        let mut case = case("stutter-repetition");
        case.max_once = strs(&["看了一下"]);
        let failures = check(&case, "文档看了一下,又看了一下。");
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].category, FailureCategory::Residual);
        assert!(failures[0].detail.contains("×2"));
    }

    #[test]
    fn order_passes_when_tokens_appear_in_sequence() {
        let mut case = case("short-mixed");
        case.order = strs(&["帮我", "看看", "logs"]);
        assert!(check(&case, "帮我看看logs").is_empty());
        assert!(check(&case, "请帮我再看看logs").is_empty());
    }

    #[test]
    fn order_fails_on_reordering_and_on_rewording() {
        let mut case = case("short-correction");
        case.order = strs(&["明天", "今天"]);
        let reordered = check(&case, "不是今天,是明天");
        assert_eq!(reordered.len(), 1);
        assert_eq!(reordered[0].category, FailureCategory::OverRectified);

        let reworded = check(&case, "次日而非当日");
        assert_eq!(reworded.len(), 1);
        assert_eq!(reworded[0].category, FailureCategory::OverRectified);
    }

    #[test]
    fn checks_are_case_sensitive() {
        // The terms fixture normalizes egfr → EGFR; the purge probe is
        // the lowercase spoken form and must not match the rectified one.
        let mut case = case("terms-medical");
        case.preserve = strs(&["EGFR"]);
        case.purge = strs(&["egfr"]);
        assert!(check(&case, "建议重新评估 EGFR 抑制剂剂量。").is_empty());
        assert_eq!(check(&case, "建议重新评估 egfr 抑制剂剂量。").len(), 2);
    }
}
