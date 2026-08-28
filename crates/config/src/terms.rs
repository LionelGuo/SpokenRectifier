//! The hotword dictionary file: plain text, one term per line.
//!
//! Not a TOML section — the dictionary is a list the user edits like a
//! document, so it lives in its own plain-text file beside the layer
//! files and resolves through the same directory search. Lines are
//! trimmed, blank lines and `#` comments are ignored; a missing or
//! unreadable file is simply an absent dictionary, like a missing layer.
//! The quick-add path (ticket 16) appends into and removes from the very
//! file the loader resolves, so a quick-added term is live for the next
//! session's dictionary read without a restart.

use std::path::PathBuf;

use crate::{find_file, settings_home};

/// The dictionary file, git-ignored: it is the user's personal terms.
pub const TERMS_FILE: &str = "spokenrectifier-terms.txt";

/// Load the dictionary: the first `spokenrectifier-terms.txt` in `dirs`,
/// one term per line, in file order. Whitespace-only and `#` lines carry
/// no term.
pub fn load_terms(dirs: &[PathBuf]) -> Vec<String> {
    let Some(path) = find_file(dirs, TERMS_FILE) else {
        return Vec::new();
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    text.lines()
        .map(str::trim) // also drops the \r of CRLF files
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(str::to_string)
        .collect()
}

/// Append one term to the dictionary the loader resolves — creating the
/// file in [`settings_home`] when none exists yet. Idempotent: a term
/// already in the dictionary is left alone, byte for byte. The term is
/// trimmed; a whitespace-only term is rejected (the caller should not
/// offer it). A missing trailing newline is repaired so the term never
/// glues onto the current last line.
pub fn append_term(dirs: &[PathBuf], term: &str) -> std::io::Result<()> {
    let term = reject_blank(term)?;
    let path = find_file(dirs, TERMS_FILE).unwrap_or_else(|| settings_home(dirs).join(TERMS_FILE));
    let existing = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(err) => return Err(err), // unreadable: never clobber it blind
    };
    if existing.lines().any(|line| line.trim() == term) {
        return Ok(());
    }
    let mut text = existing;
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    text.push_str(term);
    text.push('\n');
    std::fs::write(&path, text)
}

/// Remove a term from the dictionary the loader resolves — every line
/// carrying it, trimmed-compared, like the loader reads. A no-op when no
/// dictionary exists or the term is not in it. The rewrite normalizes
/// the file to LF line endings.
pub fn remove_term(dirs: &[PathBuf], term: &str) -> std::io::Result<()> {
    let term = reject_blank(term)?;
    let Some(path) = find_file(dirs, TERMS_FILE) else {
        return Ok(());
    };
    let existing = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(err),
    };
    let filtered: Vec<&str> = existing
        .lines()
        .filter(|line| line.trim() != term)
        .collect();
    if filtered.len() == existing.lines().count() {
        return Ok(()); // not present: leave the file byte-identical
    }
    let mut text = filtered.join("\n");
    if !text.is_empty() {
        text.push('\n');
    }
    std::fs::write(&path, text)
}

/// Rename a term in place — the settings editor's 改. The line carrying
/// `old` (trimmed-compared, like the loader reads; every copy of a
/// duplicated term) becomes `new` where it sits: order, comments, and
/// blank lines survive, unlike an append-after-remove which would drag
/// the term to the end of the file. Renaming onto a term the dictionary
/// already holds elsewhere is refused — the editor wants one entry per
/// term, not silently-merging duplicates. A missing `old` is an error
/// too: the caller's model is stale (the editor re-reads after every
/// change, so this means the file moved underneath it).
pub fn update_term(dirs: &[PathBuf], old: &str, new: &str) -> std::io::Result<()> {
    let old = reject_blank(old)?;
    let new = reject_blank(new)?;
    let Some(path) = find_file(dirs, TERMS_FILE) else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "the term is not in the dictionary (no dictionary file exists)",
        ));
    };
    let existing = std::fs::read_to_string(&path)?;
    let lines: Vec<&str> = existing.lines().collect();
    if lines.iter().any(|line| line.trim() == new) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            format!("the dictionary already holds \"{new}\""),
        ));
    }
    let renamed: Vec<String> = lines
        .iter()
        .map(|line| {
            if line.trim() == old {
                line.replace(line.trim(), new) // keeps leading indentation
            } else {
                line.to_string()
            }
        })
        .collect();
    if renamed == lines {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("the term \"{old}\" is not in the dictionary"),
        ));
    }
    let mut text = renamed.join("\n");
    if !text.is_empty() {
        text.push('\n');
    }
    std::fs::write(&path, text)
}

/// The shared writer guard: a dictionary entry is its trimmed self, and
/// an empty entry is no entry at all.
fn reject_blank(term: &str) -> Result<&str, std::io::Error> {
    let term = term.trim();
    if term.is_empty() {
        Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "a term may not be blank",
        ))
    } else {
        Ok(term)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::LOCAL_FILE;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn missing_file_is_an_empty_dictionary() {
        let dir = scratch("sr-terms-missing");
        assert!(load_terms(std::slice::from_ref(&dir)).is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn one_term_per_line_in_file_order() {
        let dir = scratch("sr-terms-lines");
        std::fs::write(
            dir.join(TERMS_FILE),
            "SpokenRectifier\n语音实验室\r\n  EGFR抑制剂  \n",
        )
        .unwrap();

        // Trimmed (CRLF included), order preserved.
        assert_eq!(
            load_terms(std::slice::from_ref(&dir)),
            vec!["SpokenRectifier", "语音实验室", "EGFR抑制剂"]
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn blank_and_comment_lines_carry_no_term() {
        let dir = scratch("sr-terms-comments");
        std::fs::write(
            dir.join(TERMS_FILE),
            "# 领域术语\n\nSpokenRectifier\n\n   # indented comment\n语音实验室\n",
        )
        .unwrap();

        assert_eq!(
            load_terms(std::slice::from_ref(&dir)),
            vec!["SpokenRectifier", "语音实验室"]
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_first_directory_with_the_file_wins() {
        let one = scratch("sr-terms-order-one");
        let two = scratch("sr-terms-order-two");
        std::fs::write(one.join(TERMS_FILE), "第一处\n").unwrap();
        std::fs::write(two.join(TERMS_FILE), "第二处\n").unwrap();

        assert_eq!(
            load_terms(&[one.clone(), two.clone()]),
            vec!["第一处".to_string()]
        );
        std::fs::remove_dir_all(one).unwrap();
        std::fs::remove_dir_all(two).unwrap();
    }

    #[test]
    fn an_unreadable_file_is_an_absent_dictionary() {
        let dir = scratch("sr-terms-unreadable");
        // A directory carrying the file's name is not a readable file;
        // `is_file()` already says no, and the loader treats it as absent.
        std::fs::create_dir_all(dir.join(TERMS_FILE)).unwrap();
        assert!(load_terms(std::slice::from_ref(&dir)).is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    // -- the quick-add write path (ticket 16) --------------------------------

    #[test]
    fn append_then_load_round_trips_into_the_next_read() {
        let dir = scratch("sr-terms-append-round-trip");
        append_term(std::slice::from_ref(&dir), "SpokenRectifier").unwrap();

        // The very next read (the next session's dictionary) sees it.
        assert_eq!(
            load_terms(std::slice::from_ref(&dir)),
            vec!["SpokenRectifier".to_string()]
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn append_writes_into_the_file_the_loader_resolves() {
        let one = scratch("sr-terms-append-order-one");
        let two = scratch("sr-terms-append-order-two");
        std::fs::write(two.join(TERMS_FILE), "既有术语\n").unwrap();

        append_term(&[one.clone(), two.clone()], "新术语").unwrap();

        // The existing dictionary (found later in the search) got the term;
        // nothing was created in the earlier directory.
        assert_eq!(
            load_terms(&[one.clone(), two.clone()]),
            vec!["既有术语".to_string(), "新术语".to_string()]
        );
        assert!(!one.join(TERMS_FILE).exists());
        std::fs::remove_dir_all(one).unwrap();
        std::fs::remove_dir_all(two).unwrap();
    }

    #[test]
    fn append_creates_the_file_beside_the_local_layer_when_none_exists() {
        let cwd = scratch("sr-terms-append-cwd");
        let exe = scratch("sr-terms-append-exe");
        std::fs::write(exe.join(LOCAL_FILE), "[llm]\n").unwrap();

        append_term(&[cwd.clone(), exe.clone()], "首个术语").unwrap();

        assert_eq!(
            std::fs::read_to_string(exe.join(TERMS_FILE)).unwrap(),
            "首个术语\n"
        );
        assert!(!cwd.join(TERMS_FILE).exists());
        std::fs::remove_dir_all(cwd).unwrap();
        std::fs::remove_dir_all(exe).unwrap();
    }

    #[test]
    fn append_creates_the_file_in_the_last_search_dir_without_a_local_layer() {
        let cwd = scratch("sr-terms-append-fresh-cwd");
        let exe = scratch("sr-terms-append-fresh-exe");

        append_term(&[cwd.clone(), exe.clone()], "首术语").unwrap();

        assert_eq!(
            std::fs::read_to_string(exe.join(TERMS_FILE)).unwrap(),
            "首术语\n"
        );
        std::fs::remove_dir_all(cwd).unwrap();
        std::fs::remove_dir_all(exe).unwrap();
    }

    #[test]
    fn append_is_idempotent_for_an_already_present_term() {
        let dir = scratch("sr-terms-append-idempotent");
        std::fs::write(dir.join(TERMS_FILE), "旧术语\n").unwrap();

        append_term(std::slice::from_ref(&dir), "旧术语").unwrap();

        assert_eq!(
            std::fs::read_to_string(dir.join(TERMS_FILE)).unwrap(),
            "旧术语\n"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn append_repairs_a_missing_trailing_newline() {
        let dir = scratch("sr-terms-append-newline");
        std::fs::write(dir.join(TERMS_FILE), "旧术语").unwrap(); // no \n

        append_term(std::slice::from_ref(&dir), "新术语").unwrap();

        // Two lines, not one glued "旧术语新术语".
        assert_eq!(
            std::fs::read_to_string(dir.join(TERMS_FILE)).unwrap(),
            "旧术语\n新术语\n"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_whitespace_term_is_rejected_by_both_writers() {
        let dir = scratch("sr-terms-blank");
        assert!(append_term(std::slice::from_ref(&dir), "   ").is_err());
        assert!(remove_term(std::slice::from_ref(&dir), "\t").is_err());
        // Nothing was created along the way.
        assert!(!dir.join(TERMS_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn remove_deletes_only_the_matching_line() {
        let dir = scratch("sr-terms-remove");
        std::fs::write(
            dir.join(TERMS_FILE),
            "# 注释\n保留术语\r\n要删的术语\n保留术语\n",
        )
        .unwrap();

        remove_term(std::slice::from_ref(&dir), "要删的术语").unwrap();

        // Comments and untouched terms survive (CRLF normalized away by
        // the rewrite); the duplicate 保留术语 keeps both its copies.
        assert_eq!(
            load_terms(std::slice::from_ref(&dir)),
            vec!["保留术语".to_string(), "保留术语".to_string()]
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn remove_is_a_noop_without_a_dictionary() {
        let dir = scratch("sr-terms-remove-absent");
        remove_term(std::slice::from_ref(&dir), "不存在").unwrap();
        assert!(!dir.join(TERMS_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    // -- the settings editor's rename path (ticket 19) ----------------------

    #[test]
    fn update_renames_the_line_in_place_keeping_comments_and_order() {
        let dir = scratch("sr-terms-update");
        std::fs::write(
            dir.join(TERMS_FILE),
            "# 注释\n第一术语\r\n要改的术语\n最后一术语\n",
        )
        .unwrap();

        update_term(std::slice::from_ref(&dir), "要改的术语", "新术语").unwrap();

        // The renamed term keeps its position; comments, order, and the
        // untouched terms survive (CRLF normalized away by the rewrite).
        assert_eq!(
            load_terms(std::slice::from_ref(&dir)),
            vec![
                "第一术语".to_string(),
                "新术语".to_string(),
                "最后一术语".to_string()
            ]
        );
        assert!(
            std::fs::read_to_string(dir.join(TERMS_FILE))
                .unwrap()
                .contains("# 注释")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn update_renames_every_copy_of_a_duplicated_term() {
        let dir = scratch("sr-terms-update-duplicate");
        std::fs::write(dir.join(TERMS_FILE), "重复\n别的\n重复\n").unwrap();

        update_term(std::slice::from_ref(&dir), "重复", "不重复").unwrap();

        assert_eq!(
            load_terms(std::slice::from_ref(&dir)),
            vec![
                "不重复".to_string(),
                "别的".to_string(),
                "不重复".to_string()
            ]
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn update_onto_an_existing_term_is_refused() {
        let dir = scratch("sr-terms-update-collision");
        std::fs::write(dir.join(TERMS_FILE), "甲\n乙\n").unwrap();

        let err = update_term(std::slice::from_ref(&dir), "甲", "乙").unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists);
        // Nothing changed.
        assert_eq!(
            std::fs::read_to_string(dir.join(TERMS_FILE)).unwrap(),
            "甲\n乙\n"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn update_of_an_absent_term_is_an_error_not_a_silent_noop() {
        let dir = scratch("sr-terms-update-absent");
        std::fs::write(dir.join(TERMS_FILE), "甲\n").unwrap();

        let err = update_term(std::slice::from_ref(&dir), "不存在", "乙").unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::NotFound);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn update_without_a_dictionary_is_an_error() {
        let dir = scratch("sr-terms-update-no-file");
        assert!(update_term(std::slice::from_ref(&dir), "甲", "乙").is_err());
        assert!(!dir.join(TERMS_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_blank_new_term_is_rejected_by_the_rename() {
        let dir = scratch("sr-terms-update-blank");
        std::fs::write(dir.join(TERMS_FILE), "甲\n").unwrap();
        assert!(update_term(std::slice::from_ref(&dir), "甲", "  ").is_err());
        assert_eq!(
            std::fs::read_to_string(dir.join(TERMS_FILE)).unwrap(),
            "甲\n"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
