//! The rectify response's inline prefill forms (ruling 26, ticket 28):
//! the streaming hold that keeps half-grown sentinel runs off the chunk
//! stream, and the body scan that turns inline forms into the
//! identity→initial-value table the preview event carries. Pure text
//! machinery — no engine state, no per-slot state (the slot model lives
//! in the shell; rows ride the wire exactly as the model wrote them,
//! and which identities exist stays the shell's body-scan call).
//!
//! Direction asymmetry (shape is truth): the request side — pinning,
//! transcript, census — only ever knows the bare `‡N‡` shape; the
//! response side additionally parses `‡N:值‡`. The retired 【预填】
//! block is gone: a habit tail the model still emits rides as plain
//! body residue, never split, never parsed.

/// The placeholder sentinel's two spellings share one shape: `‡` + ASCII
/// digits + `‡` (ticket 07).
const SENTINEL: char = '‡';

/// One row of the prefill table: the slot's number (its identity) and
/// the model's initial value for it, verbatim — possibly empty, never
/// trimmed (the effort's mechanical rule: no smart trimming anywhere).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrefillRow {
    pub number: u32,
    pub value: String,
}

/// One form occurrence anywhere in a response body: where it sits, the
/// slot number it carries, and its value verbatim. Bare `‡N‡` and
/// inline `‡N:值‡` are occurrences alike (a bare form's value is
/// empty); an overflow digit run never becomes one (it stays body, not
/// a form), and leading zeros fold into the number. Occurrences count
/// every form — the rows a body resolves keep the last per number
/// ([`scan_forms`] folds).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FormOccurrence {
    /// The form's byte span: opening `‡` through closing `‡`, or
    /// through the text's end for an unclosed value.
    pub span: std::ops::Range<usize>,
    pub number: u32,
    /// Verbatim, like a row's value — empty for the bare shape.
    pub value: String,
}

/// Every form occurrence in a text, left to right (the walk
/// [`scan_forms`] resolves rows from). Eval's assertions ride this to
/// see the same forms the engine would show.
pub fn scan_form_occurrences(text: &str) -> Vec<FormOccurrence> {
    walk_forms(text).0
}

/// Mechanical sentinel census, mirroring the prompt's injection gate
/// (`crates/llm` `census_placeholder_numbers`): every `‡ASCII digits‡`
/// shape counts, provenance never checked — the engine's split decision
/// and the prompt's injection decision must fire on exactly the same
/// strings, so a response is treated whenever its request carried the
/// placeholder branch.
pub fn has_placeholders(text: &str) -> bool {
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != SENTINEL {
            continue;
        }
        let mut digits = 0;
        while chars.peek().is_some_and(|&c| c.is_ascii_digit()) {
            digits += 1;
            chars.next();
        }
        if digits > 0 && chars.peek() == Some(&SENTINEL) {
            return true;
        }
    }
    false
}

/// How `ResponseSplitter::finish` closes a response.
pub type SplitOutcome = (String, Option<Vec<PrefillRow>>);

/// Streams one rectify response's body for a pin session under the
/// inline grammar (ruling 26): the body streams verbatim — inline forms
/// included; the shell's live capsules grow straight out of the chunks —
/// and the only thing ever held back is a trailing run that could still
/// grow into a sentinel shape, so a `‡N` fragment never flashes on the
/// surface as body text.
///
/// Inactive (a pin-less request), it is today's exact path: every delta
/// passes through verbatim and no prefill table ever exists.
pub struct ResponseSplitter {
    active: bool,
    /// The committed body: everything already streamed plus the
    /// held-back run once the stream decides or ends. Always settled —
    /// it never ends inside an unresolved `‡N` run (the no-flash
    /// invariant).
    body: String,
    /// Text not yet decided: always either empty or exactly one
    /// unresolved `‡[0-9]*` run — a `‡` whose digit run has not been
    /// terminated by `:`, `‡`, or a breaking character yet.
    pending: String,
}

impl ResponseSplitter {
    /// `active` = the request carried sentinels (see
    /// [`has_placeholders`]); only then does the response get watched.
    pub fn new(active: bool) -> Self {
        Self {
            active,
            body: String::new(),
            pending: String::new(),
        }
    }

    /// Feed one token delta; returns the body text to stream out now
    /// (possibly empty — a fully held-back delta streams nothing).
    pub fn push(&mut self, delta: &str) -> String {
        if !self.active {
            self.body.push_str(delta);
            return delta.to_string();
        }
        self.pending.push_str(delta);
        // Only an unresolved trailing run holds; everything before it is
        // settled and streams.
        let hold = scan_forms(&self.pending).1.unwrap_or(self.pending.len());
        let out = self.pending[..hold].to_string();
        self.body.push_str(&out);
        self.pending.drain(..hold);
        out
    }

    /// Close the stream. Returns the preview body and — for an active
    /// response — the prefill table parsed from it. The held run
    /// releases by end-of-stream semantics: a bare run was never a form
    /// (it stays body text), an unclosed value keeps the characters it
    /// accumulated after the colon.
    pub fn finish(mut self) -> SplitOutcome {
        if !self.active {
            return (self.body, None);
        }
        self.body.push_str(&self.pending);
        self.pending.clear();
        let (rows, _) = scan_forms(&self.body);
        (self.body, Some(rows))
    }
}

/// One greedy left-to-right pass over a response text, classifying
/// every character into body or form. Returns every form occurrence it
/// found and, when the text ends inside an unresolved `‡[0-9]*` run,
/// that run's opening byte — the only thing a stream must hold back.
/// This is the single classification the streaming hold, the
/// finish-time row parse ([`scan_forms`]), and the eval assertions
/// ([`scan_form_occurrences`]) all ride, so they can never disagree.
///
/// Forms: bare `‡N‡` prefills empty; inline `‡N:值‡` takes everything
/// after the colon up to the next `‡` — the taught contract forbids `‡`
/// and newlines inside a value, and mechanically the scanner simply
/// keeps whatever sits there (newline included, no failure); a form
/// whose colon never meets its closing `‡` runs to the text's end and
/// keeps the accumulated chars (ruling 26's unclosed rule). Numbers
/// parse as u32 — leading zeros fold to their number, an overflow drops
/// the occurrence and leaves the text as body. A `‡` that starts no
/// form (no digits, or a run broken by other text) is literal body
/// text, byte-for-byte.
fn walk_forms(text: &str) -> (Vec<FormOccurrence>, Option<usize>) {
    /// A run's digits are settled once terminated: by `:` (inline
    /// value), by `‡` (bare form), or by anything else (literal — the
    /// run never was a form).
    #[derive(PartialEq)]
    enum State {
        Body,
        Digits,
        Value,
    }

    let mut found: Vec<FormOccurrence> = Vec::new();
    let mut open_at: Option<usize> = None;
    let mut state = State::Body;
    // The current run's opening `‡` and the end of its digit span.
    let mut start = 0;
    let mut digits_end = 0;
    // The inline value's first byte, after its colon.
    let mut value_start = 0;

    let push_form = |found: &mut Vec<FormOccurrence>,
                     span: std::ops::Range<usize>,
                     number: &str,
                     value: &str| {
        let Ok(number) = number.parse::<u32>() else {
            return; // Overflow: not an identity; the text stays body.
        };
        found.push(FormOccurrence {
            span,
            number,
            value: value.to_string(),
        });
    };

    for (i, c) in text.char_indices() {
        match state {
            State::Body => {
                if c == SENTINEL {
                    state = State::Digits;
                    start = i;
                    digits_end = i + c.len_utf8();
                }
            }
            State::Digits => {
                let has_digits = digits_end > start + SENTINEL.len_utf8();
                if c.is_ascii_digit() {
                    digits_end = i + c.len_utf8();
                } else if c == ':' && has_digits {
                    state = State::Value;
                    value_start = i + c.len_utf8();
                } else if c == SENTINEL && has_digits {
                    push_form(
                        &mut found,
                        start..i + SENTINEL.len_utf8(),
                        &text[start + SENTINEL.len_utf8()..digits_end],
                        "",
                    );
                    state = State::Body;
                } else if c == SENTINEL {
                    // `‡‡`: the first was literal; this one opens anew.
                    state = State::Digits;
                    start = i;
                    digits_end = i + c.len_utf8();
                } else {
                    // A breaking character: the run was never a form.
                    state = State::Body;
                }
            }
            State::Value => {
                if c == SENTINEL {
                    push_form(
                        &mut found,
                        start..i + SENTINEL.len_utf8(),
                        &text[start + SENTINEL.len_utf8()..digits_end],
                        &text[value_start..i],
                    );
                    state = State::Body;
                }
            }
        }
    }
    match state {
        State::Digits => open_at = Some(start),
        State::Value => {
            // Unclosed to the stream's end: the value keeps everything
            // it accumulated (ruling 26).
            push_form(
                &mut found,
                start..text.len(),
                &text[start + SENTINEL.len_utf8()..digits_end],
                &text[value_start..],
            );
        }
        State::Body => {}
    }
    (found, open_at)
}

/// The prefill rows a response text resolves: the walk's occurrences
/// folded per number, a repeated number keeping the last form.
fn scan_forms(text: &str) -> (Vec<PrefillRow>, Option<usize>) {
    let (occurrences, open_at) = walk_forms(text);
    let mut rows: Vec<PrefillRow> = Vec::new();
    for occurrence in &occurrences {
        match rows.iter_mut().find(|row| row.number == occurrence.number) {
            Some(existing) => existing.value = occurrence.value.clone(),
            None => rows.push(PrefillRow {
                number: occurrence.number,
                value: occurrence.value.clone(),
            }),
        }
    }
    (rows, open_at)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(active: bool, deltas: &[&str]) -> SplitOutcome {
        let mut splitter = ResponseSplitter::new(active);
        for delta in deltas {
            splitter.push(delta);
        }
        splitter.finish()
    }

    fn row(number: u32, value: &str) -> PrefillRow {
        PrefillRow {
            number,
            value: value.into(),
        }
    }

    // -- has_placeholders: same edges as the prompt's census ----------

    #[test]
    fn sentinel_census_matches_the_prompt_gate() {
        assert!(has_placeholders("发给‡2‡再提‡10‡和‡1‡,又提了‡2‡"));
        assert!(has_placeholders("相邻‡1‡‡2‡与多位‡12‡"));
        // Every non-shape stays a non-shape: spaces, fullwidth digits,
        // letters, doubled sentinels alone.
        assert!(!has_placeholders("‡ 1‡ ‡１‡ ‡1 x‡ ‡1a‡ ‡‡ 没有记号"));
        assert!(!has_placeholders(""));
    }

    // -- the whole response, at response granularity ------------------

    #[test]
    fn inline_forms_parse_to_rows_verbatim() {
        let response = "发给‡1:张三‡一份‡2‡,还有‡10:李四‡。";
        let (body, rows) = run(true, &[response]);
        assert_eq!(body, response);
        assert_eq!(
            rows,
            Some(vec![row(1, "张三"), row(2, ""), row(10, "李四")])
        );
    }

    #[test]
    fn an_unclosed_value_keeps_its_accumulated_chars() {
        let (body, rows) = run(true, &["发给‡1:这个文"]);
        assert_eq!(body, "发给‡1:这个文");
        assert_eq!(rows, Some(vec![row(1, "这个文")]));
    }

    #[test]
    fn an_unclosed_bare_run_is_body_residue() {
        // No colon, no close: never a form, no row — just text.
        let (body, rows) = run(true, &["发给‡1"]);
        assert_eq!(body, "发给‡1");
        assert_eq!(rows, Some(vec![]));
    }

    #[test]
    fn a_retired_block_tail_streams_whole_as_residue() {
        // The model still emitting the old 【预填】 block shape gets it
        // back as plain body text, unsplit; the rows come from the body
        // alone — here both `‡1‡` occurrences are bare, so slot 1
        // prefills empty and the block-line value is lost to residue.
        let response = "发给‡1‡。\n\n【预填】\n- ‡1‡:张三";
        let (body, rows) = run(true, &[response]);
        assert_eq!(body, response);
        assert_eq!(rows, Some(vec![row(1, "")]));
    }

    #[test]
    fn inactive_passes_every_delta_through_verbatim() {
        // A pin-less response streams unsplit even when it happens to
        // contain forms — the engine never looks.
        let response = "正文‡1‡\n\n【预填】\n- ‡1‡:值";
        let (body, rows) = run(false, &[response]);
        assert_eq!(body, response);
        assert_eq!(rows, None);
    }

    // -- streaming: what is out when, at delta granularity ------------

    #[test]
    fn a_growing_run_holds_until_decided() {
        let mut splitter = ResponseSplitter::new(true);
        // The body flows; the half-grown `‡N` run holds, then releases
        // whole once its colon settles it into an inline form.
        assert_eq!(splitter.push("正文"), "正文");
        assert_eq!(splitter.push("‡1"), "");
        assert_eq!(splitter.push(":"), "‡1:");
        assert_eq!(splitter.push("张三"), "张三");
        assert_eq!(splitter.push("‡。"), "‡。");
        let (body, rows) = splitter.finish();
        assert_eq!(body, "正文‡1:张三‡。");
        assert_eq!(rows, Some(vec![row(1, "张三")]));
    }

    #[test]
    fn a_run_broken_mid_stream_releases_as_literal() {
        let mut splitter = ResponseSplitter::new(true);
        assert_eq!(splitter.push("发给"), "发给");
        assert_eq!(splitter.push("‡1"), "");
        // The `x` breaks the run: it was never a sentinel, and the
        // fragment never had a chance to flash.
        assert_eq!(splitter.push("1x"), "‡11x");
        let (body, rows) = splitter.finish();
        assert_eq!(body, "发给‡11x");
        assert_eq!(rows, Some(vec![]));
    }

    #[test]
    fn a_closed_bare_form_settles_adjacent_runs() {
        // `‡1‡2`: the second `‡` closes the first run — the body is
        // fully settled and everything streams, `2` included.
        let mut splitter = ResponseSplitter::new(true);
        assert_eq!(splitter.push("‡1‡2"), "‡1‡2");
        let (body, rows) = splitter.finish();
        assert_eq!(body, "‡1‡2");
        assert_eq!(rows, Some(vec![row(1, "")]));
    }

    #[test]
    fn split_point_invariance_across_every_boundary() {
        // Wherever the deltas cut the response, the body comes out
        // verbatim, the rows identical — and no chunk ever leaves the
        // stream ending inside an unresolved run.
        let response = "发给‡1:张三‡,再给‡10‡。";
        let chars: Vec<char> = response.chars().collect();
        for cut in 0..=chars.len() {
            let (head, tail): (String, String) =
                (chars[..cut].iter().collect(), chars[cut..].iter().collect());
            let mut splitter = ResponseSplitter::new(true);
            let mut streamed = String::new();
            for delta in [head.as_str(), tail.as_str()] {
                streamed.push_str(&splitter.push(delta));
                // The no-flash invariant: what has streamed never ends
                // inside a `‡N` run.
                assert!(
                    scan_forms(&streamed).1.is_none(),
                    "flashing cut at {cut}: {streamed:?}"
                );
            }
            let (body, rows) = splitter.finish();
            assert_eq!(body, response, "cut at {cut}");
            assert_eq!(
                rows,
                Some(vec![row(1, "张三"), row(10, "")]),
                "cut at {cut}"
            );
        }
    }

    // -- row parsing --------------------------------------------------

    #[test]
    fn row_parsing_tolerates_the_neighborhood() {
        let (rows, open) = scan_forms(
            "x‡3‡y ‡01:前导零‡ ‡99999999999:溢出‡ ‡:无号‡ ‡‡ ‡1:先‡ ‡1:后来者‡ ‡2:多冒号:值‡ ‡4:跨\n行‡",
        );
        assert_eq!(
            rows,
            vec![
                row(3, ""),
                row(1, "后来者"), // Leading zero folds; a repeat keeps the last.
                row(2, "多冒号:值"),
                row(4, "跨\n行"), // A newline in a value is kept, verbatim.
            ]
        );
        assert_eq!(open, None);
    }

    #[test]
    fn an_empty_text_has_no_forms() {
        assert_eq!(scan_forms(""), (vec![], None));
    }

    #[test]
    fn occurrences_carry_spans_and_do_not_deduplicate() {
        // The occurrence walk is what a body-side projection (the eval
        // assertions, the shell scan) rides: every form with its span,
        // folds and repeats included — unlike the rows, which fold a
        // repeated number to its last form.
        let text = "发给‡1:张三‡一份‡01:重号‡,备份‡1:后来者‡ ‡99999999999:溢出‡";
        let occurrences = scan_form_occurrences(text);
        let describe =
            |o: &FormOccurrence| format!("{}:{}:{}", o.number, o.value, &text[o.span.clone()]);
        assert_eq!(
            occurrences.iter().map(describe).collect::<Vec<_>>(),
            vec![
                "1:张三:‡1:张三‡".to_string(),
                "1:重号:‡01:重号‡".to_string(),
                "1:后来者:‡1:后来者‡".to_string(),
                // Overflow never becomes a form; its text stays body.
            ]
        );
        let (rows, _) = scan_forms(text);
        assert_eq!(rows, vec![row(1, "后来者")]);
    }

    #[test]
    fn an_unclosed_value_occurrence_spans_to_the_end() {
        let text = "发给‡1:这个文";
        assert_eq!(
            scan_form_occurrences(text)
                .iter()
                .map(|o| (o.number, o.value.as_str(), o.span.clone()))
                .collect::<Vec<_>>(),
            vec![(1, "这个文", 6..text.len())]
        );
    }
}
