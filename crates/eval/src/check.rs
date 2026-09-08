//! Assertion checking for the fidelity eval (glossary: 保真铁律, 口头更正,
//! 逐字保留, 占位符, 预填).
//!
//! [`check`] is pure: a case plus a rectified text yield zero or more
//! categorized failures. Every category names a way the fidelity
//! contract can break, so the report can say not just "failed" but
//! how — the axis a prompt iteration needs.
//!
//! With pins the model's response is rectified text plus a trailing
//! 【预填】 block; [`check`] splits the two first and every assertion
//! sees only the body, so a prefill value can never trip a body probe
//! (and vice versa).

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
    /// The placeholder clause's absorption did not land: a referent it
    /// should have moved into a prefill stayed in the body, or a slot's
    /// 【预填】 value missed the case's expectation.
    AbsorbFailed,
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
            FailureCategory::AbsorbFailed => "吸收失败",
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
/// are case-sensitive substring checks over the body; `order` is an
/// in-order subsequence walk. A transcript carrying `‡N‡` sentinels
/// additionally asserts the derived placeholder contract: every
/// sentinel byte-exact, once per occurrence, unwrapped (ticket 24).
pub fn check(case: &EvalCase, output: &str) -> Vec<Failure> {
    let pinned = sentinel_counts(&case.transcript);
    let (raw_body, prefill) = split_prefill_block(!pinned.is_empty(), output);
    check_parts(case, raw_body, &prefill, &pinned)
}

/// The same assertions over an already-split response: body without the
/// 【预填】 block, the parsed prefill rows, and the transcript's
/// sentinel counts. The runner rides [`check`]; this is the seam the
/// engine-side split (ticket 18) feeds once the chunk stream carries
/// body only and the prefill table rides its own event.
pub fn check_parts(
    case: &EvalCase,
    raw_body: &str,
    prefill: &[(u32, String)],
    pinned: &[(String, usize)],
) -> Vec<Failure> {
    let body = raw_body.trim_end();
    let mut failures = Vec::new();

    for text in &case.preserve {
        if !body.contains(text.as_str()) {
            failures.push(Failure {
                category: FailureCategory::PreservationFailed,
                detail: format!("未逐字保留:{text}"),
            });
        }
    }

    for group in &case.convey {
        if !group.iter().any(|alt| body.contains(alt.as_str())) {
            failures.push(Failure {
                category: FailureCategory::Lost,
                detail: format!("关键意思缺失:{}", group.join(" / ")),
            });
        }
    }

    for text in &case.fabricate {
        if body.contains(text.as_str()) {
            failures.push(Failure {
                category: FailureCategory::Fabricated,
                detail: format!("出现了未提及的内容:{text}"),
            });
        }
    }

    for text in &case.purge {
        if body.contains(text.as_str()) {
            failures.push(Failure {
                category: FailureCategory::Residual,
                detail: format!("应清除的口头残留:{text}"),
            });
        }
    }

    for text in &case.max_once {
        if body.matches(text.as_str()).count() > 1 {
            failures.push(Failure {
                category: FailureCategory::Residual,
                detail: format!(
                    "重复未收敛:{} ×{}",
                    text,
                    body.matches(text.as_str()).count()
                ),
            });
        }
    }

    if let Some(token) = first_out_of_order(&case.order, body) {
        failures.push(Failure {
            category: FailureCategory::OverRectified,
            detail: format!("措辞或语序被改写:{token} 未按原序出现"),
        });
    }

    check_sentinels(pinned, body, &mut failures);
    check_absorption(case, body, prefill, &mut failures);

    failures
}

/// The derived placeholder contract: the body's `‡N‡` multiset must
/// equal the transcript's (byte-exact survival — a rewritten shape like
/// `‡01‡` or `‡ 1 ‡` both fails to match and reads as an invented
/// number), and no sentinel may sit against a decoration character.
fn check_sentinels(pinned: &[(String, usize)], body: &str, failures: &mut Vec<Failure>) {
    let found = sentinel_counts(body);

    for (digits, want) in pinned {
        let got = found
            .iter()
            .find(|(d, _)| d == digits)
            .map_or(0, |(_, n)| *n);
        if got < *want {
            failures.push(Failure {
                category: FailureCategory::PreservationFailed,
                detail: format!("哨兵少号:‡{digits}‡ 转写 {want} 处,正文 {got} 处"),
            });
        } else if got > *want {
            failures.push(Failure {
                category: FailureCategory::Fabricated,
                detail: format!("哨兵多号:‡{digits}‡ 正文 {got} 处,转写 {want} 处"),
            });
        } else if is_wrapped(body, digits) {
            failures.push(Failure {
                category: FailureCategory::PreservationFailed,
                detail: format!("哨兵被包裹:‡{digits}‡ 紧邻装饰字符"),
            });
        }
    }

    for (digits, _) in &found {
        if !pinned.iter().any(|(d, _)| d == digits) {
            failures.push(Failure {
                category: FailureCategory::Fabricated,
                detail: format!("捏造哨兵:‡{digits}‡ 转写没有这个号"),
            });
        }
    }
}

/// The authored absorption assertions: `absorbed` referents must have
/// left the body, and each `prefill` expectation must match the slot's
/// effective 【预填】 value (missing block or missing row reads empty —
/// 对不上不判失败, the assertion decides what that means).
fn check_absorption(
    case: &EvalCase,
    body: &str,
    prefill: &[(u32, String)],
    failures: &mut Vec<Failure>,
) {
    for text in &case.absorbed {
        if body.contains(text.as_str()) {
            failures.push(Failure {
                category: FailureCategory::AbsorbFailed,
                detail: format!("被吸收的指称留在正文:{text}"),
            });
        }
    }

    for expectation in &case.prefill {
        let value = prefill
            .iter()
            .find(|(number, _)| number == &expectation.pin)
            .map_or("", |(_, v)| v.as_str());
        let hit = expectation.any.iter().any(|alt| {
            if alt.is_empty() {
                value.is_empty()
            } else {
                value.contains(alt.as_str())
            }
        });
        if !hit {
            failures.push(Failure {
                category: FailureCategory::AbsorbFailed,
                detail: format!(
                    "预填未命中:‡{}‡ 期望 {} 实得「{value}」",
                    expectation.pin,
                    expectation.any.join(" / ")
                ),
            });
        }
    }
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

/// The placeholder sentinel (ticket 07): `‡` + ASCII digits + `‡`.
const SENTINEL: char = '‡';

/// The 【预填】 block's header line as the response contract fixes it
/// (ticket 12): rectified text, blank line, then the block — the header
/// owns its whole line.
const PREFILL_HEADER: &str = "【预填】";

/// Split a whole model response into its body and the 【预填】 block's
/// number→value rows, at whole-text granularity — same semantics the
/// engine's streaming split (crates/engine `prefill.rs`, ticket 18)
/// builds, so the assertions see exactly the world the engine would
/// show: the split fires only for a pinned request (`active`), the
/// header must be a line exactly, rows keep the exact `- ‡N‡:` shape
/// with the value verbatim, and a repeated number keeps the last row.
/// Lenient by contract (对不上不判失败): no block or unreadable rows
/// just mean empty values.
fn split_prefill_block(active: bool, output: &str) -> (&str, Vec<(u32, String)>) {
    let mut body_end = output.len();
    let mut block = String::new();
    let mut in_block = false;
    let mut offset = 0;
    for line in output.split('\n') {
        if !in_block && active && line == PREFILL_HEADER {
            in_block = true;
            body_end = offset;
        } else if in_block {
            block.push_str(line);
            block.push('\n');
        }
        offset += line.len() + 1; // + the '\n' split on
    }
    (&output[..body_end], parse_prefill_rows(&block))
}

/// Parse the block's rows: `- ‡N‡` + `:` + optional single-line value,
/// verbatim (no smart trimming anywhere). Anything else is ignored.
/// Mirrors the engine's row parser on purpose.
fn parse_prefill_rows(block: &str) -> Vec<(u32, String)> {
    let mut rows: Vec<(u32, String)> = Vec::new();
    for line in block.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        let Some(rest) = line.strip_prefix("- ‡") else {
            continue;
        };
        let Some(close) = rest.find(SENTINEL) else {
            continue;
        };
        let (digits, after) = rest.split_at(close);
        let Ok(number) = digits.parse::<u32>() else {
            continue;
        };
        let Some(value) = after[SENTINEL.len_utf8()..].strip_prefix(':') else {
            continue;
        };
        match rows.iter_mut().find(|(n, _)| *n == number) {
            Some(entry) => entry.1 = value.to_string(),
            None => rows.push((number, value.to_string())),
        }
    }
    rows
}

/// Count every `‡ASCII digits‡` shape in `text`, digit string verbatim
/// (a leading zero stays its own number — 不规范化; shape is truth,
/// story 20). Same mechanical walk the prompt census rides; ordered by
/// first appearance.
pub(crate) fn sentinel_counts(text: &str) -> Vec<(String, usize)> {
    let mut counts: Vec<(String, usize)> = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != SENTINEL {
            continue;
        }
        let mut digits = String::new();
        while let Some(&('0'..='9')) = chars.peek() {
            digits.push(chars.next().expect("peeked digit"));
        }
        if digits.is_empty() || chars.peek() != Some(&SENTINEL) {
            continue; // lone ‡ or digits without the closing sentinel
        }
        chars.next(); // the closing sentinel
        match counts.iter_mut().find(|(d, _)| *d == digits) {
            Some(entry) => entry.1 += 1,
            None => counts.push((digits, 1)),
        }
    }
    counts
}

/// Decoration characters a model wraps sentinels in: markdown emphasis,
/// code spans, and pairing brackets or quotes in both widths. Wrapping
/// is symmetric — the check demands both sides, so "(详见备份位置‡1‡)",
/// a parenthesized aside that merely ends at the sentinel, stays legal,
/// while "(‡1‡)" and "**‡1‡**", which hug the token, do not.
const WRAP_OPENERS: &[char] = &[
    '*', '_', '~', '$', '`', '(', '[', '{', '【', '「', '『', '《', '(', '[', '{', '"', '"', '\'',
];
const WRAP_CLOSERS: &[char] = &[
    '*', '_', '~', '$', '`', ')', ']', '}', '】', '」', '』', '》', ')', ']', '}', '"', '"', '\'',
];

/// Whether any `‡N‡` occurrence in `body` is decorated on both sides
/// (不包裹).
fn is_wrapped(body: &str, digits: &str) -> bool {
    let token = format!("{SENTINEL}{digits}{SENTINEL}");
    let mut from = 0;
    while let Some(at) = body[from..].find(token.as_str()) {
        let start = from + at;
        let end = start + token.len();
        let before = body[..start].chars().next_back();
        let after = body[end..].chars().next();
        if before.is_some_and(|c| WRAP_OPENERS.contains(&c))
            && after.is_some_and(|c| WRAP_CLOSERS.contains(&c))
        {
            return true;
        }
        from = end;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cases::PrefillExpectation;

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

    /// A pinned case: transcript carrying sentinels, minimal authored
    /// lists; the derived contract does the rest.
    fn pin_case(id: &str, transcript: &str) -> EvalCase {
        let mut c = case(id);
        c.transcript = transcript.into();
        c
    }

    #[test]
    fn sentinels_surviving_byte_exact_pass_clean() {
        let case = pin_case(
            "placeholder-multi",
            "备份到‡1‡,旧库的连接串记在‡2‡,其他不动",
        );
        let failures = check(&case, "备份到‡1‡,旧库的连接串记在‡2‡,其他不动。");
        assert!(failures.is_empty(), "{failures:?}");
    }

    #[test]
    fn a_missing_sentinel_is_a_preservation_failure() {
        let case = pin_case("placeholder-multi", "备份到‡1‡,连接串记在‡2‡");
        let failures = check(&case, "备份到‡1‡,连接串另行记录。");
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].category, FailureCategory::PreservationFailed);
        assert!(failures[0].detail.contains("‡2‡"), "{failures:?}");
    }

    #[test]
    fn a_duplicated_sentinel_and_an_invented_one_are_fabrications() {
        let case = pin_case("placeholder-multi", "备份到‡1‡");
        let failures = check(&case, "备份到‡1‡,再备份到‡1‡,顺便带上‡3‡。");
        let fabricated: Vec<_> = failures
            .iter()
            .filter(|f| f.category == FailureCategory::Fabricated)
            .collect();
        assert_eq!(fabricated.len(), 2, "{failures:?}");
        assert!(fabricated[0].detail.contains("哨兵多号"));
        assert!(fabricated[1].detail.contains("捏造哨兵") && fabricated[1].detail.contains("‡3‡"));
    }

    #[test]
    fn a_rewritten_shape_both_misses_and_invents() {
        // ‡01‡ is neither the expected ‡1‡ (少号) nor an honest number
        // (捏造) — normalization must not launder the shape.
        let case = pin_case("placeholder-multi", "备份到‡1‡");
        let failures = check(&case, "备份到‡01‡。");
        assert_eq!(failures.len(), 2, "{failures:?}");
        assert_eq!(failures[0].category, FailureCategory::PreservationFailed);
        assert_eq!(failures[1].category, FailureCategory::Fabricated);
    }

    #[test]
    fn a_wrapped_sentinel_is_a_preservation_failure() {
        let case = pin_case("placeholder-multi", "备份到‡1‡");
        for output in ["备份到**‡1‡**。", "备份到【‡1‡】。"] {
            let failures = check(&case, output);
            assert_eq!(failures.len(), 1, "{output}: {failures:?}");
            assert_eq!(failures[0].category, FailureCategory::PreservationFailed);
            assert!(failures[0].detail.contains("被包裹"));
        }
        // A phrase parenthesized around the sentinel stays legal: the
        // decoration does not hug the ‡N‡ itself.
        assert!(check(&case, "(详见备份位置‡1‡)的说明。").is_empty());
    }

    #[test]
    fn body_assertions_do_not_see_the_prefill_block() {
        let mut case = pin_case("placeholder-absorb-name", "记得发给张三‡1‡,别抄送");
        case.purge = strs(&["张三"]);
        case.prefill = vec![PrefillExpectation {
            pin: 1,
            any: strs(&["张三"]),
        }];
        // 张三 lives only in the 【预填】 row: the purge probe (body)
        // stays quiet and the prefill expectation hits.
        let output = "记得发给‡1‡,别抄送。\n\n【预填】\n- ‡1‡:张三";
        assert!(check(&case, output).is_empty());
    }

    #[test]
    fn a_missing_block_reads_as_empty_values() {
        let mut case = pin_case("placeholder-absorb-uncertain", "项目里的‡1‡先别填");
        case.prefill = vec![PrefillExpectation {
            pin: 1,
            any: strs(&[""]),
        }];
        // No block at all: the slot reads empty — 拿不准不吸 passes.
        assert!(check(&case, "项目里的‡1‡先别填。").is_empty());
        // A block whose row carries a value breaks the empty expectation.
        let failures = check(&case, "项目里的‡1‡先别填。\n\n【预填】\n- ‡1‡:项目");
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].category, FailureCategory::AbsorbFailed);
    }

    #[test]
    fn an_absorbed_referent_left_in_the_body_is_an_absorb_failure() {
        let mut case = pin_case("placeholder-absorb-file", "打开这个文件‡1‡看配置");
        case.absorbed = strs(&["这个文件"]);
        case.prefill = vec![PrefillExpectation {
            pin: 1,
            any: strs(&["这个文件", "该文件"]),
        }];
        // Absorbed twice over: the referent also stayed in the body.
        let failures = check(&case, "打开这个文件‡1‡看配置。\n\n【预填】\n- ‡1‡:这个文件");
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert_eq!(failures[0].category, FailureCategory::AbsorbFailed);
        assert!(failures[0].detail.contains("留在正文"));
    }

    #[test]
    fn a_prefill_expectation_misses_on_a_wrong_value() {
        let mut case = pin_case("placeholder-absorb-name", "发给张三‡1‡");
        case.prefill = vec![PrefillExpectation {
            pin: 1,
            any: strs(&["张三", "张叁"]),
        }];
        let failures = check(&case, "发给‡1‡。\n\n【预填】\n- ‡1‡:李四");
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].category, FailureCategory::AbsorbFailed);
        assert!(failures[0].detail.contains("实得「李四」"), "{failures:?}");
    }

    #[test]
    fn malformed_block_rows_are_ignored_not_failures() {
        // 对不上不判失败: stray lines are skipped, a repeated number
        // keeps the LAST row (the engine's rule), and a number nobody
        // pinned just sits unasserted.
        let output = "备份到‡1‡。\n\n【预填】\n说明一下\n- ‡1‡:备份盘\n- ‡1‡:重复行\n- ‡9‡:多号";
        let (body, rows) = split_prefill_block(true, output);
        assert_eq!(body.trim_end(), "备份到‡1‡。");
        assert_eq!(
            rows,
            vec![(1, "重复行".to_string()), (9, "多号".to_string())]
        );

        let mut case = pin_case("placeholder-multi", "备份到‡1‡");
        case.prefill = vec![PrefillExpectation {
            pin: 1,
            any: strs(&["重复行"]),
        }];
        assert!(check(&case, output).is_empty());
    }

    #[test]
    fn the_split_stays_inactive_for_a_pinless_case() {
        // The engine never looks for a block without pins; neither does
        // the eval — a block-shaped tail stays body text all the way
        // (the purge probe fires on it), and its sentinel shape then
        // reads as fabricated: shape is truth works both directions.
        let mut case = case("mixed-product");
        case.transcript = "发给张三,记得抄送".into();
        case.purge = strs(&["【预填】"]);
        let output = "发给张三,记得抄送。\n\n【预填】\n- ‡1‡:张三";
        let failures = check(&case, output);
        assert_eq!(failures.len(), 2, "{failures:?}");
        assert_eq!(failures[0].category, FailureCategory::Residual);
        assert_eq!(failures[1].category, FailureCategory::Fabricated);
        assert!(failures[1].detail.contains("捏造哨兵"));
    }

    #[test]
    fn the_census_walk_counts_only_closed_digit_shapes() {
        use super::sentinel_counts;
        let counts = sentinel_counts("‡1‡和‡2‡,再‡1‡;裸‡、‡3、1‡都不算");
        assert_eq!(counts, vec![("1".to_string(), 2), ("2".to_string(), 1)]);
        // A leading zero is its own number, never normalized away.
        assert_eq!(sentinel_counts("‡01‡"), vec![("01".to_string(), 1)]);
    }
}
