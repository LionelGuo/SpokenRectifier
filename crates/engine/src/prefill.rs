//! The rectify response's prefill block (【预填】, ticket 18): the
//! streaming split that keeps the block off the main surface, and the
//! row parser that turns it into the identity→initial-value table the
//! preview event carries. Pure text machinery — no engine state, no
//! per-slot state (the slot model lives in the shell; rows ride the
//! wire exactly as the model wrote them, and identities the body lacks
//! are the shell's extraction to ignore).

/// The response block's header line: exactly `【预填】`, alone on its
/// line, after the rectified text (ticket 12's response contract —
/// 修正文本 + 空行 + 【预填】块). The request's census header is a
/// different, longer string and never matches here.
pub const PREFILL_BLOCK_HEADER: &str = "【预填】";

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

/// Mechanical sentinel census, mirroring the prompt's injection gate
/// (`crates/llm` `census_placeholder_numbers`): every `‡ASCII digits‡`
/// shape counts, provenance never checked — the engine's split decision
/// and the prompt's injection decision must fire on exactly the same
/// strings, so a response is split whenever its request carried the
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

/// Splits one streamed rectify response into preview body (still
/// carrying sentinels) and the trailing 【预填】 block. Built for token
/// deltas arriving at arbitrary char boundaries: anything the block
/// could still claim — a trailing newline run, a partial header line —
/// is held back, so no chunk ever streams text that later turns out to
/// belong to the separator or the block.
///
/// Inactive (a pin-less request), it is today's exact path: every delta
/// passes through verbatim and no prefill table ever exists.
pub struct ResponseSplitter {
    active: bool,
    /// The committed preview body: everything already streamed plus the
    /// held-back text once decided. While open it never ends in a
    /// newline — trailing newlines always sit in `pending`, which is
    /// what keeps the separator strippable after bytes have streamed.
    body: String,
    /// Text not yet decided: a suffix of the response that the block's
    /// separator or header might still grow into.
    pending: String,
    /// Block content after the header line, once the header committed.
    block: Option<String>,
}

impl ResponseSplitter {
    /// `active` = the request carried sentinels (see
    /// [`has_placeholders`]); only then does the response get split.
    pub fn new(active: bool) -> Self {
        Self {
            active,
            body: String::new(),
            pending: String::new(),
            block: None,
        }
    }

    /// Feed one token delta; returns the body text to stream out now
    /// (possibly empty — a fully held-back delta streams nothing).
    pub fn push(&mut self, delta: &str) -> String {
        if !self.active {
            self.body.push_str(delta);
            return delta.to_string();
        }
        if let Some(block) = self.block.as_mut() {
            // Past the header: the rest of the response is block, full
            // stop — nothing more ever streams.
            block.push_str(delta);
            return String::new();
        }
        self.pending.push_str(delta);
        if let Some(at) = find_header(&self.pending, false) {
            return self.commit(at);
        }
        let hold = hold_point(&self.pending);
        let out = self.pending[..hold].to_string();
        self.body.push_str(&out);
        self.pending.drain(..hold);
        out
    }

    /// Close the stream. Returns the preview body and — for an active
    /// split — the parsed prefill table (empty when the model sent no
    /// parseable block: no match, no failure).
    pub fn finish(mut self) -> SplitOutcome {
        if !self.active {
            return (self.body, None);
        }
        if self.block.is_none() {
            if let Some(at) = find_header(&self.pending, true) {
                self.commit(at);
            } else {
                // No block: the response stands as-is, trailing
                // newlines included, and every slot's prefill is empty.
                self.body.push_str(&self.pending);
            }
        }
        let rows = parse_prefill_rows(self.block.as_deref().unwrap_or(""));
        (self.body, Some(rows))
    }

    /// Commit the block header starting at byte `at` in `pending`:
    /// stream the body text before it (separator newlines stripped —
    /// they all sat in `pending`, per the never-emitted-trailing-newline
    /// invariant) and start collecting the block after the header line.
    fn commit(&mut self, at: usize) -> String {
        let out = self.pending[..at].trim_end_matches('\n').to_string();
        let rest = self.pending.split_off(at);
        self.pending.clear();
        let after = &rest[PREFILL_BLOCK_HEADER.len()..];
        // The byte past the header is the header line's own newline
        // (mid-stream commits require it; an end-of-stream commit has
        // nothing after).
        *self.block.insert(String::new()) = after.strip_prefix('\n').unwrap_or(after).to_string();
        self.body.push_str(&out);
        out
    }
}

/// The first committed header line start in `pending`, if any: a
/// position at a line start (byte 0 or right after a `\n`) where the
/// exact header begins and is either line-terminated (`\n` next) or —
/// only at the response's end (`at_eof`) — the last thing said. A
/// header followed by other same-line text is not a header: the line
/// streams as body and the fallback (empty table) holds.
fn find_header(pending: &str, at_eof: bool) -> Option<usize> {
    let bytes = pending.as_bytes();
    let header_at = |at: usize| {
        pending[at..].starts_with(PREFILL_BLOCK_HEADER) && {
            let after = at + PREFILL_BLOCK_HEADER.len();
            (after == bytes.len() && at_eof) || bytes.get(after) == Some(&b'\n')
        }
    };
    if header_at(0) {
        return Some(0);
    }
    bytes
        .iter()
        .enumerate()
        .filter(|&(_, &b)| b == b'\n')
        .map(|(i, _)| i + 1)
        .find(|&at| header_at(at))
}

/// Where `pending` splits into streamable body (before) and held-back
/// uncertainty (after): the trailing newline run — the separator's blank
/// line, however many newlines it turns out to be — plus a partial line
/// that could still grow into the header. This is what guarantees the
/// committed body's trailing-newline strip only ever removes bytes that
/// never streamed.
fn hold_point(pending: &str) -> usize {
    let bytes = pending.as_bytes();
    let last_nl = bytes.iter().rposition(|&b| b == b'\n');
    let line_start = last_nl.map_or(0, |i| i + 1);
    let run_start = |end: usize| {
        bytes[..end]
            .iter()
            .rposition(|&b| b != b'\n')
            .map_or(0, |i| i + 1)
    };
    if PREFILL_BLOCK_HEADER.starts_with(&pending[line_start..]) {
        return match last_nl {
            // No newline at all: the response itself might open with the
            // header line.
            None => 0,
            // The partial header line sits on a newline run; hold all of
            // it — any of those newlines could be the separator's.
            Some(nl) => run_start(nl),
        };
    }
    match bytes.last() {
        // Settled text not ending in a newline: nothing left to claim.
        Some(&b) if b != b'\n' => pending.len(),
        // A trailing newline run (possibly the whole pending).
        _ => run_start(bytes.len()),
    }
}

/// Parse the block's rows: `- ‡N‡` + `:` + optional single-line value,
/// verbatim (no trim). Anything else — malformed rows, prose, an empty
/// line — is ignored; a repeated number keeps the last row. Row syntax
/// is the request's own (ticket 12: 请求与响应同一套).
fn parse_prefill_rows(block: &str) -> Vec<PrefillRow> {
    let mut rows: Vec<PrefillRow> = Vec::new();
    for line in block.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        let Some(rest) = line.strip_prefix("- ‡") else {
            continue;
        };
        let Some(close) = rest.find(SENTINEL) else {
            continue;
        };
        let (digits, after) = rest.split_at(close);
        if !digits.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let Some(value) = after[SENTINEL.len_utf8()..].strip_prefix(':') else {
            continue;
        };
        let Ok(number) = digits.parse::<u32>() else {
            continue;
        };
        match rows.iter_mut().find(|row| row.number == number) {
            Some(existing) => existing.value = value.to_string(),
            None => rows.push(PrefillRow {
                number,
                value: value.to_string(),
            }),
        }
    }
    rows
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

    // -- the split, at whole-response granularity ---------------------

    #[test]
    fn block_splits_off_and_rows_parse() {
        let (body, rows) = run(true, &["发给‡1‡。\n\n【预", "填】\n- ‡1‡:张三\n- ‡2‡:"]);
        assert_eq!(body, "发给‡1‡。");
        assert_eq!(
            rows,
            Some(vec![
                PrefillRow {
                    number: 1,
                    value: "张三".into()
                },
                PrefillRow {
                    number: 2,
                    value: String::new()
                },
            ])
        );
    }

    #[test]
    fn no_block_streams_everything_with_an_empty_table() {
        let (body, rows) = run(true, &["打开‡1‡", "就好"]);
        assert_eq!(body, "打开‡1‡就好");
        assert_eq!(rows, Some(vec![]));
    }

    #[test]
    fn header_with_trailing_text_is_not_a_header() {
        // The header must own its whole line: same-line junk means no
        // block, the line streams, and every prefill is empty.
        let (body, rows) = run(true, &["正文\n【预填】(机械普查,值为空)\n- ‡1‡:值"]);
        assert_eq!(body, "正文\n【预填】(机械普查,值为空)\n- ‡1‡:值");
        assert_eq!(rows, Some(vec![]));
    }

    #[test]
    fn bare_header_at_the_end_commits_an_empty_block() {
        let (body, rows) = run(true, &["正文\n\n【预填】"]);
        assert_eq!(body, "正文");
        assert_eq!(rows, Some(vec![]));
    }

    #[test]
    fn inactive_passes_every_delta_through_verbatim() {
        // A pin-less response streams unsplit even when it happens to
        // contain a block-shaped tail — the engine never looks.
        let response = "正文‡1‡\n\n【预填】\n- ‡1‡:值";
        let (body, rows) = run(false, &[response]);
        assert_eq!(body, response);
        assert_eq!(rows, None);
    }

    // -- streaming: what is out when, at delta granularity ------------

    #[test]
    fn held_back_text_streams_only_once_decided() {
        let mut splitter = ResponseSplitter::new(true);
        // Body flows; the newline before a possible header holds.
        assert_eq!(splitter.push("正文"), "正文");
        assert_eq!(splitter.push("\n"), "");
        assert_eq!(splitter.push("\n【"), "");
        assert_eq!(splitter.push("预"), "");
        // The header line breaks: everything held streams at once.
        assert_eq!(splitter.push("填】续"), "\n\n【预填】续");
        assert_eq!(splitter.push("完"), "完");
        let (body, rows) = splitter.finish();
        assert_eq!(body, "正文\n\n【预填】续完");
        assert_eq!(rows, Some(vec![]));
    }

    #[test]
    fn the_separator_never_streams_before_the_block() {
        let mut splitter = ResponseSplitter::new(true);
        assert_eq!(splitter.push("正文"), "正文");
        // The whole separator + header arrives in hostile fragments,
        // some empty: nothing streams after the body.
        for fragment in ["\n", "\n【", "预填", "】", "\n- ‡1", "‡:值"] {
            assert_eq!(splitter.push(fragment), "");
        }
        let (body, rows) = splitter.finish();
        assert_eq!(body, "正文");
        assert_eq!(
            rows,
            Some(vec![PrefillRow {
                number: 1,
                value: "值".into()
            }])
        );
    }

    #[test]
    fn split_point_invariance_across_every_boundary() {
        // Wherever the deltas cut the response, the streamed body and
        // the parsed table come out identical.
        let response = "发给‡1‡,再给‡10‡。\n\n【预填】\n- ‡1‡:张三\n- ‡10‡:";
        let chars: Vec<char> = response.chars().collect();
        for cut in 0..=chars.len() {
            let (head, tail): (String, String) =
                (chars[..cut].iter().collect(), chars[cut..].iter().collect());
            let (body, rows) = run(true, &[head.as_str(), tail.as_str()]);
            assert_eq!(body, "发给‡1‡,再给‡10‡。", "cut at {cut}");
            assert_eq!(
                rows,
                Some(vec![
                    PrefillRow {
                        number: 1,
                        value: "张三".into()
                    },
                    PrefillRow {
                        number: 10,
                        value: String::new()
                    },
                ]),
                "cut at {cut}"
            );
        }
    }

    // -- row parsing --------------------------------------------------

    #[test]
    fn row_parsing_tolerates_the_neighborhood() {
        let block = "\n- ‡1‡:多冒号:值\r\n- ‡01‡:前导零\n- ‡1‡:后来者\n垃圾行\n- ‡2‡ 缺冒号\n- ‡99999999999‡:溢出\n- ‡3‡:";
        assert_eq!(
            parse_prefill_rows(block),
            vec![
                // Leading zero is the same identity as its number; a
                // repeated number keeps the last row.
                PrefillRow {
                    number: 1,
                    value: "后来者".into()
                },
                PrefillRow {
                    number: 3,
                    value: String::new()
                },
            ]
        );
    }

    #[test]
    fn an_empty_block_has_no_rows() {
        assert!(parse_prefill_rows("").is_empty());
    }
}
