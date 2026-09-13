//! Assertion checking for the fidelity eval (glossary: 保真铁律, 口头更正,
//! 逐字保留, 占位符, 预填).
//!
//! [`check`] is pure: a case plus a rectified text yield zero or more
//! categorized failures. Every category names a way the fidelity
//! contract can break, so the report can say not just "failed" but
//! how — the axis a prompt iteration needs.
//!
//! With pins the prefill values ride inline forms in the body itself
//! (`‡N:值‡`, ruling 26; the 【预填】 block is retired). The assertions
//! ride the engine's own scan: [`check`] resolves the rows with the
//! engine's splitter, and every body probe sees the body with its
//! inline forms collapsed back to bare `‡N‡` shapes — so a prefill
//! value can never trip a body probe (and vice versa), the sentinel
//! contract counts a slot's every spelling, and the absorption
//! expectations read exactly the rows the engine would show. A
//! pass-through case (ADR-0014) skips absorption and instead forbids
//! any inline value in the raw body: marks ride as bare `‡N‡`.

use spokenrectifier_engine::prefill::{ResponseSplitter, scan_form_occurrences};

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
/// additionally asserts the derived placeholder contract: every number
/// present, once per occurrence, unwrapped — bare or inline spelling
/// alike (tickets 24, 30).
pub fn check(case: &EvalCase, output: &str) -> Vec<Failure> {
    let pinned = sentinel_counts(&case.transcript);
    // One whole response through the engine's own splitter (ruling 26,
    // ticket 28): the body is everything — inline forms verbatim, a
    // retired block tail as plain residue — and the rows resolve from
    // the inline forms exactly as the streaming path would deliver
    // them (inactive for a pin-less request: verbatim, no rows).
    let mut splitter = ResponseSplitter::new(!pinned.is_empty());
    splitter.push(output);
    let (body, rows) = splitter.finish();
    let prefill: Vec<(u32, String)> = rows
        .unwrap_or_default()
        .into_iter()
        .map(|row| (row.number, row.value))
        .collect();
    check_parts(case, &body, &prefill, &pinned)
}

/// The same assertions over the engine's split: the body exactly as the
/// chunk stream carried it (inline forms verbatim — the splitter only
/// ever holds a half-grown `‡N` run), the prefill rows the
/// `PreviewPrefills` event delivered, and the transcript's sentinel
/// counts. Body probes see the collapsed body
/// ([`collapse_inline_forms`]): a prefill value can neither trip a
/// body probe nor mask one. [`check`] stays the whole-response front
/// door for already-concatenated outputs.
pub fn check_parts(
    case: &EvalCase,
    raw_body: &str,
    prefill: &[(u32, String)],
    pinned: &[(String, usize)],
) -> Vec<Failure> {
    let collapsed = collapse_inline_forms(raw_body);
    let body = collapsed.trim_end();
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
    if case.pass_through {
        // Off-mode (ADR-0014): the derived sentinel contract still
        // demands the number multiset, and on top the body must carry
        // those numbers as bare `‡N‡` — a `‡N:值‡` is absorption the
        // form forbids, whether or not the collapsed probes would
        // still see the right count.
        check_pass_through(raw_body, &mut failures);
    } else {
        check_absorption(case, body, prefill, &mut failures);
    }

    failures
}

/// Off-mode anti-absorption: every form in the raw body must be the
/// bare `‡N‡` shape. An inline value is the on-form grammar leaking
/// through (零吸收, 正文不得混入 `‡编号:值‡`).
fn check_pass_through(raw_body: &str, failures: &mut Vec<Failure>) {
    for form in scan_form_occurrences(raw_body) {
        if !form.value.is_empty() {
            failures.push(Failure {
                category: FailureCategory::AbsorbFailed,
                detail: format!("关态混入值形:‡{}:{}‡", form.number, form.value),
            });
        }
    }
}

/// The derived placeholder contract over the collapsed body (every
/// form already its bare `‡N‡` shape): the sentinel multiset must
/// equal the transcript's — a number absent is 少号, an extra one is an
/// invention — and no sentinel may sit against a decoration character.
/// A broken shape (`‡ 1 ‡`) collapses to nothing and reads as 少号; a
/// leading zero folds to its number and reads as present (ruling 28's
/// response-side fold, not a rewritten shape).
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
/// left the collapsed body (a referent living inside an inline value
/// has been absorbed), and each `prefill` expectation must match the
/// slot's effective value from the inline parse (a missing number
/// reads empty — 对不上不判失败, the assertion decides what that
/// means).
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

/// Collapse every inline form to its bare shape: `‡N:值‡` becomes
/// `‡N‡`, the value leaving the body for the rows (an unclosed value
/// releases its accumulated chars the same way, ruling 26). Bare forms
/// and all other text pass through byte-for-byte, a leading zero folds
/// to its number, and an overflow digit run is no form at all — the
/// engine's own walk (`scan_form_occurrences`) decides what a form is,
/// so the probe body can never disagree with the rows the engine would
/// show.
fn collapse_inline_forms(text: &str) -> String {
    let occurrences = scan_form_occurrences(text);
    if occurrences.is_empty() {
        return text.to_string();
    }
    let mut collapsed = String::with_capacity(text.len());
    let mut at = 0;
    for form in &occurrences {
        collapsed.push_str(&text[at..form.span.start]);
        collapsed.push(SENTINEL);
        collapsed.push_str(&form.number.to_string());
        collapsed.push(SENTINEL);
        at = form.span.end;
    }
    collapsed.push_str(&text[at..]);
    collapsed
}

/// Count every `‡ASCII digits‡` shape in `text`, digit string verbatim
/// (a leading zero stays its own number — 不规范化; shape is truth,
/// story 20). The REQUEST side's walk — transcripts and the prompt
/// census only ever carry bare shapes (direction asymmetry, ruling
/// 26); the response side rides the engine's fold instead
/// ([`collapse_inline_forms`]). Ordered by first appearance.
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

/// Whether any sentinel occurrence in `body` is decorated on both
/// sides (不包裹). Runs over the collapsed body, so a wrapped inline
/// form (`**‡1:值‡**`) collapses to a wrapped bare one and fails here
/// too.
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
    fn an_inline_form_counts_as_its_number_present() {
        // Ruling 26: `‡N:值‡` is slot N in place — no 少号, no 改写
        // misfire, and the value never shows itself to the body.
        let case = pin_case("placeholder-absorb-name", "记得发给张三‡1‡,别抄送");
        let failures = check(&case, "记得发给‡1:张三‡,别抄送。");
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

        // Inline spellings count alike: a duplicated inline form is
        // still 多号, an invented inline number still 捏造.
        let failures = check(&case, "备份到‡1:甲‡,再备份到‡1:乙‡,带上‡3:丙‡。");
        let fabricated: Vec<_> = failures
            .iter()
            .filter(|f| f.category == FailureCategory::Fabricated)
            .collect();
        assert_eq!(fabricated.len(), 2, "{failures:?}");
        assert!(fabricated[0].detail.contains("哨兵多号"));
        assert!(fabricated[1].detail.contains("捏造哨兵") && fabricated[1].detail.contains("‡3‡"));
    }

    #[test]
    fn a_leading_zero_form_folds_to_its_number() {
        // Ruling 28 folds leading zeros on the response side: ‡01:值‡
        // IS slot 1 in the engine's world, not a rewritten shape. A
        // genuinely broken shape still misses — ‡ 1 ‡ is no form.
        let case = pin_case("placeholder-multi", "备份到‡1‡");
        assert!(check(&case, "备份到‡01:配置盘‡。").is_empty());
        let failures = check(&case, "备份到‡ 1 ‡。");
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert_eq!(failures[0].category, FailureCategory::PreservationFailed);
        assert!(failures[0].detail.contains("哨兵少号"));
    }

    #[test]
    fn a_wrapped_sentinel_is_a_preservation_failure() {
        let case = pin_case("placeholder-multi", "备份到‡1‡");
        for output in ["备份到**‡1‡**。", "备份到【‡1‡】。", "备份到**‡1:配置‡**。"]
        {
            let failures = check(&case, output);
            assert_eq!(failures.len(), 1, "{output}: {failures:?}");
            assert_eq!(failures[0].category, FailureCategory::PreservationFailed);
            assert!(failures[0].detail.contains("被包裹"));
        }
        // A phrase parenthesized around the sentinel stays legal: the
        // decoration does not hug the form itself.
        assert!(check(&case, "(详见备份位置‡1‡)的说明。").is_empty());
        assert!(check(&case, "(详见备份位置‡1:网盘‡)的说明。").is_empty());
    }

    #[test]
    fn body_assertions_do_not_see_inline_values() {
        let mut case = pin_case("placeholder-absorb-name", "记得发给张三‡1‡,别抄送");
        case.purge = strs(&["张三"]);
        case.prefill = vec![PrefillExpectation {
            pin: 1,
            any: strs(&["张三"]),
        }];
        // 张三 lives only inside the inline value: the purge probe
        // (collapsed body) stays quiet and the prefill expectation hits.
        assert!(check(&case, "记得发给‡1:张三‡,别抄送。").is_empty());
    }

    #[test]
    fn a_bare_form_reads_as_an_empty_value() {
        let mut case = pin_case("placeholder-absorb-uncertain", "项目里的‡1‡先别填");
        case.prefill = vec![PrefillExpectation {
            pin: 1,
            any: strs(&[""]),
        }];
        // Bare form: the row reads empty — 拿不准不吸 passes.
        assert!(check(&case, "项目里的‡1‡先别填。").is_empty());
        // An inline value breaks the empty expectation.
        let failures = check(&case, "项目里的‡1:项目‡先别填。");
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
        // Absorbed twice over: the referent also stayed in the body
        // outside the value (the collapsed body still shows it).
        let failures = check(&case, "打开这个文件‡1:这个文件‡看配置。");
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
        let failures = check(&case, "发给‡1:李四‡。");
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].category, FailureCategory::AbsorbFailed);
        assert!(failures[0].detail.contains("实得「李四」"), "{failures:?}");
    }

    #[test]
    fn repeated_numbers_keep_the_last_value() {
        // 对不上不判失败, engine rule: a repeated number keeps the LAST
        // form's value — and the derived contract still flags the extra
        // occurrence (多号), whatever the values.
        let mut case = pin_case("placeholder-multi", "备份到‡1‡");
        case.prefill = vec![PrefillExpectation {
            pin: 1,
            any: strs(&["乙"]),
        }];
        let failures = check(&case, "备份到‡1:甲‡,再记‡1:乙‡。");
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert_eq!(failures[0].category, FailureCategory::Fabricated);
        assert!(failures[0].detail.contains("哨兵多号"));
    }

    #[test]
    fn overflow_runs_and_retired_block_tails_stay_body() {
        // An overflow digit run never becomes a number (engine rule):
        // its text is body, uncounted, unasserted.
        let case = pin_case("placeholder-multi", "备份到‡1‡");
        assert!(check(&case, "备份到‡1‡ ‡99999999999:溢出‡。").is_empty());

        // A habit 【预填】 tail is plain residue (ruling 26): its bare
        // row overwrites the inline value (last form wins) and its
        // duplicate occurrence flags 多号 — the eval catches the habit.
        let mut case = pin_case("placeholder-multi", "备份到‡1‡");
        case.prefill = vec![PrefillExpectation {
            pin: 1,
            any: strs(&["备份盘"]),
        }];
        let failures = check(&case, "备份到‡1:备份盘‡。\n\n【预填】\n- ‡1‡:备份盘");
        assert_eq!(failures.len(), 2, "{failures:?}");
        assert!(failures
            .iter()
            .any(|f| f.category == FailureCategory::Fabricated && f.detail.contains("哨兵多号")));
        assert!(
            failures
                .iter()
                .any(|f| f.category == FailureCategory::AbsorbFailed
                    && f.detail.contains("实得「」"))
        );
    }

    #[test]
    fn pass_through_accepts_bare_marks_and_rejects_inline_values() {
        // Off-mode (ADR-0014): the number multiset still has to match,
        // and the raw body may not mix in a `‡N:值‡`. Collapse would
        // hide the value from every other probe — this check is the
        // one that sees it.
        let mut case = pin_case("placeholder-off-name", "记得发给张三‡1‡,别抄送");
        case.pass_through = true;
        case.preserve = strs(&["张三"]);
        assert!(check(&case, "记得发给张三‡1‡,别抄送。").is_empty());

        let failures = check(&case, "记得发给‡1:张三‡,别抄送。");
        assert_eq!(failures.len(), 2, "{failures:?}");
        assert!(failures.iter().any(|f| {
            f.category == FailureCategory::AbsorbFailed && f.detail.contains("关态混入值形")
        }));
        // The value left the collapsed body, so the preserve net
        // fires too — the referent was absorbed.
        assert!(failures.iter().any(|f| {
            f.category == FailureCategory::PreservationFailed && f.detail.contains("张三")
        }));
    }

    #[test]
    fn the_scan_stays_inactive_for_a_pinless_case() {
        // The engine never looks for forms without pins, but shape is
        // truth works both directions: the collapse is mechanical, so a
        // fabricated form in a pin-less response still reads as 捏造
        // and a habit block tail still trips its purge probe.
        let mut case = case("mixed-product");
        case.transcript = "发给张三,记得抄送".into();
        case.purge = strs(&["【预填】"]);
        let output = "发给张三,记得抄送。\n\n【预填】\n- ‡1:张三‡";
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
