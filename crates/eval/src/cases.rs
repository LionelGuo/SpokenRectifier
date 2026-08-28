//! The fidelity eval suite (glossary: 保真铁律, 修正, 术语词表).
//!
//! One TOML file holds the terms fixture (the dictionary every case's
//! prompt carries — a fixed list, so a developer's local
//! `spokenrectifier-terms.txt` cannot leak into a run) and the cases:
//! raw transcripts plus machine-checkable expectations. Appending a case
//! is editing the file; nothing else in the repo needs to know.

use std::collections::HashSet;
use std::path::Path;

use serde::Deserialize;

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
/// what it authors.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct EvalCase {
    /// Stable id; the prefix before the first `-` names the coverage
    /// family (correction-, supplement-, stutter-, mixed-, terms-,
    /// numeral-, short-).
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
        if preserve.is_empty()
            && convey.is_empty()
            && fabricate.is_empty()
            && purge.is_empty()
            && max_once.is_empty()
            && order.is_empty()
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
transcript = \"那个我们用spoken rectifier\"
preserve = [\"SpokenRectifier\"]
convey = [[\"我们\", \"咱们\"]]
fabricate = [\"Kubernetes\"]
purge = [\"那个\"]
max_once = [\"spoken\"]
order = [\"我们\", \"spoken\"]
",
        );
        let suite = load_suite(&path).unwrap();
        assert_eq!(suite.terms, vec!["SpokenRectifier", "EGFR"]);
        let case = &suite.cases[0];
        assert_eq!(case.id, "mixed-01");
        assert_eq!(case.transcript, "那个我们用spoken rectifier");
        assert_eq!(case.preserve, vec!["SpokenRectifier"]);
        assert_eq!(case.convey, vec![vec!["我们", "咱们"]]);
        assert_eq!(case.fabricate, vec!["Kubernetes"]);
        assert_eq!(case.purge, vec!["那个"]);
        assert_eq!(case.max_once, vec!["spoken"]);
        assert_eq!(case.order, vec!["我们", "spoken"]);
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
}
