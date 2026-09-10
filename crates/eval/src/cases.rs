//! The fidelity eval suite (glossary: 保真铁律, 修正, 术语词表, 占位符,
//! 预填).
//!
//! One TOML file holds the terms fixture (the dictionary every case's
//! prompt carries — a fixed list, so a developer's local
//! `spokenrectifier-terms.txt` cannot leak into a run) and the cases:
//! raw transcripts plus machine-checkable expectations. Appending a case
//! is editing the file; nothing else in the repo needs to know.
//!
//! A transcript carrying `‡N‡` sentinels asserts the placeholder
//! contract whether or not the case authors a list for it: the checks
//! derive from the transcript itself (shape is truth).

use std::collections::HashSet;
use std::path::Path;

use serde::Deserialize;

use super::check::sentinel_counts;

/// The on-disk shape of the suite file (serde mirror of [`EvalSuite`]).
#[derive(Debug, Deserialize)]
struct SuiteFile {
    #[serde(default)]
    terms: Vec<String>,
    #[serde(default)]
    case: Vec<CaseFile>,
}

/// The on-disk shape of one case (serde mirror of [`EvalCase`]).
#[derive(Debug, Default, Deserialize)]
struct CaseFile {
    id: String,
    transcript: String,
    #[serde(default)]
    preserve: Vec<String>,
    #[serde(default)]
    convey: Vec<Vec<String>>,
    #[serde(default)]
    fabricate: Vec<String>,
    #[serde(default)]
    purge: Vec<String>,
    #[serde(default)]
    max_once: Vec<String>,
    #[serde(default)]
    order: Vec<String>,
    #[serde(default)]
    absorbed: Vec<String>,
    #[serde(default)]
    prefill: Vec<PrefillFile>,
}

/// The on-disk shape of one prefill expectation (serde mirror of
/// [`PrefillExpectation`]).
#[derive(Debug, Deserialize)]
struct PrefillFile {
    pin: u32,
    #[serde(default)]
    any: Vec<String>,
}

/// The suite: a fixed terms fixture plus every case.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct EvalSuite {
    /// The hotword dictionary riding every case's rectify prompt.
    pub terms: Vec<String>,
    pub cases: Vec<EvalCase>,
}

/// One golden case: a raw transcript and what a faithful rectify must
/// (and must not) produce. Every list is optional; a case asserts only
/// what it authors — plus, when the transcript carries `‡N‡`, the
/// derived placeholder contract.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct EvalCase {
    /// Stable id; the prefix before the first `-` names the coverage
    /// family (correction-, supplement-, stutter-, mixed-, terms-,
    /// numeral-, short-, placeholder-).
    pub id: String,
    /// The raw transcript exactly as speech would freeze it. Newlines
    /// carry paragraph structure.
    pub transcript: String,
    /// Strings that must survive verbatim (terms, URLs, numbers) —
    /// checked case-sensitively.
    pub preserve: Vec<String>,
    /// Key ideas: each group is alternative keywords; at least one
    /// alternative per group must appear.
    pub convey: Vec<Vec<String>>,
    /// Strings that must NOT appear — things noone said, authored as
    /// fabrication probes.
    pub fabricate: Vec<String>,
    /// Strings that must NOT appear — things the transcript said but a
    /// faithful rectify removes (fillers, correction lead-ins,
    /// superseded values, un-normalized numerals).
    pub purge: Vec<String>,
    /// Strings that may appear at most once (repetition collapse).
    pub max_once: Vec<String>,
    /// Tokens that must all appear, in this order (a subsequence of the
    /// output) — the light-touch no-rewording guard for short cases.
    pub order: Vec<String>,
    /// Strings that must NOT appear in the body — referents the
    /// placeholder clause absorbs into a prefill (被吸走的不留正文).
    pub absorbed: Vec<String>,
    /// Prefill expectations: each pin's effective 【预填】 value must
    /// contain one alternative; the empty alternative demands an empty
    /// value (拿不准不吸).
    pub prefill: Vec<PrefillExpectation>,
}

/// One authored prefill expectation: the pin's number (its identity —
/// the block's rows parse numerically, like the engine's) and any-of
/// alternatives like a convey group.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PrefillExpectation {
    /// The pin's number (e.g. 1).
    pub pin: u32,
    /// Alternative substrings; "" demands an empty value.
    pub any: Vec<String>,
}

/// Where the bundled suite lives, next to the crate manifest.
pub fn default_suite_path() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("cases.toml")
}

/// Load and validate a suite file.
pub fn load_suite(path: &Path) -> Result<EvalSuite, String> {
    let source = std::fs::read_to_string(path)
        .map_err(|err| format!("cannot read {}: {err}", path.display()))?;
    parse_suite(&source, &path.display().to_string())
}

/// The suite compiled into this binary ([`crate::EMBEDDED_SUITE`]) — the
/// app's runner never touches the file system for the suite.
pub fn embedded_suite() -> Result<EvalSuite, String> {
    parse_suite(crate::EMBEDDED_SUITE, "embedded cases.toml")
}

/// Parse and validate suite text; `origin` names the source in errors
/// (a path, or "embedded cases.toml").
fn parse_suite(source: &str, origin: &str) -> Result<EvalSuite, String> {
    let file: SuiteFile =
        toml::from_str(source).map_err(|err| format!("cannot parse {origin}: {err}"))?;

    let terms = file
        .terms
        .iter()
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .collect();

    let mut seen = HashSet::new();
    let mut cases = Vec::with_capacity(file.case.len());
    for raw in file.case {
        let id = raw.id.trim().to_string();
        if id.is_empty() {
            return Err(format!("a case has a blank id in {origin}"));
        }
        if !seen.insert(id.clone()) {
            return Err(format!("duplicate case id {id} in {origin}"));
        }
        let transcript = raw.transcript.trim().to_string();
        if transcript.is_empty() {
            return Err(format!("case {id} has a blank transcript"));
        }
        let convey = raw
            .convey
            .into_iter()
            .map(|group| {
                let group: Vec<String> = group
                    .into_iter()
                    .map(|alt| alt.trim().to_string())
                    .filter(|alt| !alt.is_empty())
                    .collect();
                if group.is_empty() {
                    Err(format!("case {id} has an empty convey group"))
                } else {
                    Ok(group)
                }
            })
            .collect::<Result<Vec<_>, _>>()?;
        let trimmed = |list: Vec<String>| {
            list.into_iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        };
        let preserve = trimmed(raw.preserve);
        let fabricate = trimmed(raw.fabricate);
        let purge = trimmed(raw.purge);
        let max_once = trimmed(raw.max_once);
        let order = trimmed(raw.order);
        let absorbed = trimmed(raw.absorbed);
        let prefill = raw
            .prefill
            .into_iter()
            .map(|expectation| {
                // Unlike every other list, the empty alternative is
                // meaningful here ("" demands an empty value — 拿不准不
                // 吸); only whitespace-only entries are dropped typos.
                let any = expectation
                    .any
                    .into_iter()
                    .filter_map(|alt| {
                        if alt.is_empty() {
                            Some(alt)
                        } else {
                            let t = alt.trim().to_string();
                            (!t.is_empty()).then_some(t)
                        }
                    })
                    .collect::<Vec<_>>();
                if any.is_empty() {
                    Err(format!(
                        "case {id} has a prefill expectation for ‡{}‡ with no alternative",
                        expectation.pin
                    ))
                } else {
                    Ok(PrefillExpectation {
                        pin: expectation.pin,
                        any,
                    })
                }
            })
            .collect::<Result<Vec<_>, _>>()?;
        // A transcript carrying sentinels asserts the derived placeholder
        // contract on its own — that counts as an assertion. Everything
        // else must author at least one list.
        let sentinels = sentinel_counts(&transcript);
        if id.starts_with("placeholder-") && sentinels.is_empty() {
            return Err(format!(
                "case {id} is family placeholder- but its transcript carries no ‡N‡ sentinel"
            ));
        }
        for expectation in &prefill {
            if !sentinels
                .iter()
                .any(|(digits, _)| digits.parse::<u32>() == Ok(expectation.pin))
            {
                return Err(format!(
                    "case {id} expects a prefill for ‡{}‡ but the transcript never carries it",
                    expectation.pin
                ));
            }
        }
        if preserve.is_empty()
            && convey.is_empty()
            && fabricate.is_empty()
            && purge.is_empty()
            && max_once.is_empty()
            && order.is_empty()
            && absorbed.is_empty()
            && prefill.is_empty()
            && sentinels.is_empty()
        {
            return Err(format!(
                "case {id} carries no assertion at all — at least one assertion list must be non-empty"
            ));
        }
        cases.push(EvalCase {
            id,
            transcript,
            preserve,
            convey,
            fabricate,
            purge,
            max_once,
            order,
            absorbed,
            prefill,
        });
    }
    if cases.is_empty() {
        return Err(format!("no cases in {origin}"));
    }
    Ok(EvalSuite { terms, cases })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_tmp(content: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("sr-eval-suite-{}-{n}.toml", std::process::id()));
        std::fs::write(&path, content).unwrap();
        path
    }

    #[test]
    fn parses_terms_and_every_assertion_list() {
        let path = write_tmp(
            "\
terms = [\"SpokenRectifier\", \"EGFR\"]

[[case]]
id = \"mixed-01\"
transcript = \"那个我们用spoken rectifier发给‡1‡\"
preserve = [\"SpokenRectifier\"]
convey = [[\"我们\", \"咱们\"]]
fabricate = [\"Kubernetes\"]
purge = [\"那个\"]
max_once = [\"spoken\"]
order = [\"我们\", \"spoken\"]
absorbed = [\"那个文件\"]
prefill = [{ pin = 1, any = [\"那个文件\", \"该文件\"] }]
",
        );
        let suite = load_suite(&path).unwrap();
        assert_eq!(suite.terms, vec!["SpokenRectifier", "EGFR"]);
        let case = &suite.cases[0];
        assert_eq!(case.id, "mixed-01");
        assert_eq!(case.transcript, "那个我们用spoken rectifier发给‡1‡");
        assert_eq!(case.preserve, vec!["SpokenRectifier"]);
        assert_eq!(case.convey, vec![vec!["我们", "咱们"]]);
        assert_eq!(case.fabricate, vec!["Kubernetes"]);
        assert_eq!(case.purge, vec!["那个"]);
        assert_eq!(case.max_once, vec!["spoken"]);
        assert_eq!(case.order, vec!["我们", "spoken"]);
        assert_eq!(case.absorbed, vec!["那个文件"]);
        assert_eq!(
            case.prefill,
            vec![PrefillExpectation {
                pin: 1,
                any: vec!["那个文件".into(), "该文件".into()],
            }]
        );
    }

    #[test]
    fn every_list_defaults_to_empty_and_transcript_trims() {
        let path = write_tmp(
            "\
[[case]]
id = \"short-01\"
transcript = \"\"\"嗯我先走了
\"\"\"
convey = [[\"我\"]]
",
        );
        let suite = load_suite(&path).unwrap();
        let case = &suite.cases[0];
        assert_eq!(case.transcript, "嗯我先走了");
        assert!(case.preserve.is_empty());
        assert!(case.convey == vec![vec!["我"]]);
        assert!(case.fabricate.is_empty());
        assert!(case.purge.is_empty());
        assert!(case.max_once.is_empty());
        assert!(case.order.is_empty());
    }

    #[test]
    fn blank_terms_are_dropped() {
        let path = write_tmp(
            "\
terms = [\"EGFR\", \" \"]

[[case]]
id = \"terms-01\"
transcript = \"检查肾功能和egfr水平,顺便复查一个电解质四项,看看肌酐清除率有没有变化\"
convey = [[\"肾功能\"]]
",
        );
        let suite = load_suite(&path).unwrap();
        assert_eq!(suite.terms, vec!["EGFR"]);
    }

    #[test]
    fn duplicate_ids_are_rejected() {
        let path = write_tmp(
            "\
[[case]]
id = \"short-01\"
transcript = \"嗯我先走了\"

[[case]]
id = \"short-01\"
transcript = \"嗯我回来了\"
",
        );
        let err = load_suite(&path).unwrap_err();
        assert!(err.contains("short-01"), "error should name the id: {err}");
    }

    #[test]
    fn blank_ids_and_transcripts_are_rejected() {
        let path = write_tmp(
            "\
[[case]]
id = \" \"
transcript = \"嗯我先走了\"
",
        );
        assert!(load_suite(&path).unwrap_err().contains("id"));

        let path = write_tmp(
            "\
[[case]]
id = \"short-01\"
transcript = \"   \"
",
        );
        assert!(load_suite(&path).unwrap_err().contains("transcript"));
    }

    #[test]
    fn empty_convey_groups_are_rejected_and_blank_alternatives_drop() {
        let path = write_tmp(
            "\
[[case]]
id = \"short-01\"
transcript = \"嗯我先走了\"
convey = [[]]
",
        );
        assert!(load_suite(&path).unwrap_err().contains("convey"));

        // A blank alternative is dropped like a blank term; the group
        // survives on its non-blank alternatives.
        let path = write_tmp(
            "\
[[case]]
id = \"short-01\"
transcript = \"嗯我先走了\"
convey = [[\"精神\", \" \"]]
",
        );
        let suite = load_suite(&path).unwrap();
        assert_eq!(suite.cases[0].convey, vec![vec!["精神"]]);
    }

    #[test]
    fn a_case_must_carry_at_least_one_assertion() {
        let path = write_tmp(
            "\
[[case]]
id = \"short-01\"
transcript = \"嗯我先走了\"
",
        );
        assert!(
            load_suite(&path)
                .unwrap_err()
                .contains("at least one assertion")
        );
    }

    #[test]
    fn a_sentinel_carrying_transcript_is_an_assertion_on_its_own() {
        // Shape is truth: no authored list, but the derived placeholder
        // contract rides the sentinels.
        let path = write_tmp(
            "\
[[case]]
id = \"placeholder-multi\"
transcript = \"备份到‡1‡,连接串记在‡2‡,其他一律不动\"
",
        );
        let suite = load_suite(&path).unwrap();
        assert_eq!(suite.cases[0].id, "placeholder-multi");
    }

    #[test]
    fn the_placeholder_family_requires_sentinels() {
        let path = write_tmp(
            "\
[[case]]
id = \"placeholder-absorb-file\"
transcript = \"嗯就是一个没有钉入的普通转写,足够长也没有用,族名说了算\"
convey = [[\"普通\"]]
",
        );
        let err = load_suite(&path).unwrap_err();
        assert!(
            err.contains("placeholder-"),
            "error should name the family: {err}"
        );
        assert!(err.contains("sentinel"), "error should say why: {err}");
    }

    #[test]
    fn a_prefill_expectation_must_target_a_pinned_number() {
        let path = write_tmp(
            "\
[[case]]
id = \"placeholder-absorb-file\"
transcript = \"打开这个文件‡1‡看配置\"
prefill = [{ pin = 2, any = [\"那个文件\"] }]
",
        );
        let err = load_suite(&path).unwrap_err();
        assert!(err.contains("‡2‡"), "error should name the pin: {err}");

        // And an expectation without a single alternative is refused.
        let path = write_tmp(
            "\
[[case]]
id = \"placeholder-absorb-file\"
transcript = \"打开这个文件‡1‡看配置\"
prefill = [{ pin = 1, any = [\" \"] }]
",
        );
        assert!(load_suite(&path).unwrap_err().contains("no alternative"));
    }

    #[test]
    fn the_embedded_suite_is_the_bundled_file() {
        // What the app compiles in must be what the repo ships — this
        // pins the include_str! against drift by construction (it reads
        // the same file), but keeps an explicit failure with a name if
        // either side moves.
        assert_eq!(
            embedded_suite().unwrap(),
            load_suite(&default_suite_path()).unwrap()
        );
    }

    #[test]
    fn the_bundled_suite_is_valid_and_covers_every_family() {
        let suite = load_suite(&default_suite_path()).unwrap();
        assert!(
            suite.cases.len() >= 20,
            "need >= 20 cases, has {}",
            suite.cases.len()
        );
        assert!(!suite.terms.is_empty(), "terms fixture must not be empty");

        for family in [
            "correction-",
            "supplement-",
            "stutter-",
            "mixed-",
            "terms-",
            "numeral-",
            "short-",
            "placeholder-",
        ] {
            assert!(
                suite.cases.iter().any(|c| c.id.starts_with(family)),
                "no case in family {family}"
            );
        }

        // The light-touch threshold defaults to 40 characters and is
        // config-adjustable; author short cases with a wide margin
        // below it and everything else well above, so threshold drift
        // cannot silently flip a case's intensity.
        for case in &suite.cases {
            let chars = case.transcript.chars().count();
            if case.id.starts_with("short-") {
                assert!(
                    chars <= 15,
                    "{} is {} chars; short cases stay <= 15",
                    case.id,
                    chars
                );
            } else {
                assert!(
                    chars >= 60,
                    "{} is {} chars; non-short cases stay >= 60",
                    case.id,
                    chars
                );
            }
        }
    }

    /// The injection branch, suite-wide (ticket 24): every pinless case
    /// composes with zero placeholder traces — the byte-level freeze of
    /// that no-pin path is the golden files' job (ticket 17), this gate
    /// keeps the suite itself honest — and every pinned case carries the
    /// clause, its census row per number, and the trailing reminder.
    #[test]
    fn every_bundled_case_composes_on_the_right_placeholder_branch() {
        use spokenrectifier_engine::RectifyRequest;
        use spokenrectifier_llm::{compose_prompt, select_intensity};

        let suite = load_suite(&default_suite_path()).unwrap();
        let mut saw_pinned = false;
        let mut saw_pinless = false;
        for case in &suite.cases {
            let request = RectifyRequest {
                raw_transcript: case.transcript.clone(),
                paragraphs: case.transcript.split('\n').map(str::to_string).collect(),
                style_directive: None,
                global_directive: None,
                terms: suite.terms.clone(),
            };
            let prompt = compose_prompt(&request, select_intensity(&case.transcript, 40));
            let pinned = !sentinel_counts(&case.transcript).is_empty();
            if pinned {
                saw_pinned = true;
                assert!(
                    prompt.system.contains("【占位符】"),
                    "{}: pinned case missing the placeholder clause",
                    case.id
                );
                for (digits, _) in sentinel_counts(&case.transcript) {
                    assert!(
                        prompt.user.contains(&format!("\n- ‡{digits}‡\n")),
                        "{}: census row for ‡{digits}‡ missing",
                        case.id
                    );
                }
                assert!(
                    prompt.user.trim_end().ends_with("仅保真铁律例外)"),
                    "{}: the placeholder reminder must close the user message",
                    case.id
                );
            } else {
                saw_pinless = true;
                for trace in ["【占位符】", "【预填】", "吸收只改预填"] {
                    assert!(
                        !prompt.system.contains(trace) && !prompt.user.contains(trace),
                        "{}: pinless composition carries placeholder trace {trace}",
                        case.id
                    );
                }
            }
        }
        assert!(saw_pinned, "the suite must carry pinned cases");
        assert!(saw_pinless, "the suite must carry pinless cases");
    }
}
