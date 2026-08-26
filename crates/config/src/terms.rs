//! The hotword dictionary file: plain text, one term per line.
//!
//! Not a TOML section — the dictionary is a list the user edits like a
//! document, so it lives in its own plain-text file beside the layer
//! files and resolves through the same directory search. Lines are
//! trimmed, blank lines and `#` comments are ignored; a missing or
//! unreadable file is simply an absent dictionary, like a missing layer.

use std::path::PathBuf;

/// The dictionary file, git-ignored: it is the user's personal terms.
pub const TERMS_FILE: &str = "spokenrectifier-terms.txt";

/// Load the dictionary: the first `spokenrectifier-terms.txt` in `dirs`,
/// one term per line, in file order. Whitespace-only and `#` lines carry
/// no term.
pub fn load_terms(dirs: &[PathBuf]) -> Vec<String> {
    let Some(path) = dirs
        .iter()
        .map(|dir| dir.join(TERMS_FILE))
        .find(|path| path.is_file())
    else {
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
