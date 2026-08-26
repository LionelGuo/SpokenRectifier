//! The scenario library (glossary: 场景, 场景库, 风格指令): one app-owned
//! TOML file of named style directives — not a layered config layer, and
//! never a home for secrets.
//!
//! The library file is written by hand in v1 and by the settings screen
//! later; either way the app needs read-write ownership of its own file,
//! which the user-authored layer files cannot offer (ADR-0004). A missing
//! or unparsable file reads as an empty library: the loader never errors
//! and never writes, so a broken library degrades to the default register
//! instead of blocking startup.

use std::path::PathBuf;

/// The library file's name, looked up in every config search directory.
pub const SCENARIO_FILE: &str = "spokenrectifier-scenarios.toml";

/// One scenario: a user-chosen name for a style directive.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scenario {
    pub name: String,
    pub directive: String,
}

#[derive(Debug, Default, serde::Deserialize)]
struct ScenarioFile {
    #[serde(default)]
    scenario: Vec<ScenarioEntry>,
}

#[derive(Debug, Default, serde::Deserialize)]
struct ScenarioEntry {
    #[serde(default)]
    name: String,
    #[serde(default)]
    directive: String,
}

/// Load the library from the first existing `spokenrectifier-scenarios.toml`
/// among `dirs` (the config search order). Tolerance rules: names are
/// trimmed; an entry with a blank name or a blank directive is skipped; a
/// duplicated name keeps the last entry; a missing or unparsable file is
/// an empty library.
pub fn load_scenarios(dirs: &[PathBuf]) -> Vec<Scenario> {
    let Some(path) = dirs
        .iter()
        .map(|dir| dir.join(SCENARIO_FILE))
        .find(|path| path.is_file())
    else {
        return Vec::new();
    };
    match std::fs::read_to_string(&path) {
        Ok(text) => parse_scenarios(&text),
        Err(_) => Vec::new(),
    }
}

/// The parsing rules, pure over the file text.
fn parse_scenarios(text: &str) -> Vec<Scenario> {
    let Ok(file) = toml::from_str::<ScenarioFile>(text) else {
        return Vec::new();
    };
    let mut scenarios: Vec<Scenario> = Vec::new();
    for entry in file.scenario {
        let name = entry.name.trim().to_string();
        let directive = entry.directive.trim().to_string();
        if name.is_empty() || directive.is_empty() {
            continue;
        }
        match scenarios.iter_mut().find(|s| s.name == name) {
            Some(existing) => existing.directive = directive,
            None => scenarios.push(Scenario { name, directive }),
        }
    }
    scenarios
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
    fn parses_named_directives_in_file_order() {
        let library = parse_scenarios(
            "\
[[scenario]]
name = \"Prompt 工程\"
directive = \"输出将直接用作 AI 提示词:可分点分行\"

[[scenario]]
name = \"正式文档\"
directive = \"严谨规范,句式完整\"
",
        );
        assert_eq!(
            library,
            vec![
                Scenario {
                    name: "Prompt 工程".into(),
                    directive: "输出将直接用作 AI 提示词:可分点分行".into(),
                },
                Scenario {
                    name: "正式文档".into(),
                    directive: "严谨规范,句式完整".into(),
                },
            ]
        );
    }

    #[test]
    fn blank_names_or_directives_are_skipped_and_names_are_trimmed() {
        let library = parse_scenarios(
            "\
[[scenario]]
name = \"  \"
directive = \"有指令但名字是空白\"

[[scenario]]
name = \"有名字\"
directive = \"   \"

[[scenario]]
name = \"  带空白的名字  \"
directive = \"  指令两端的空白也被裁掉  \"
",
        );
        assert_eq!(
            library,
            vec![Scenario {
                name: "带空白的名字".into(),
                directive: "指令两端的空白也被裁掉".into(),
            }]
        );
    }

    #[test]
    fn a_duplicated_name_keeps_the_last_directive() {
        let library = parse_scenarios(
            "\
[[scenario]]
name = \"场景\"
directive = \"第一版指令\"

[[scenario]]
name = \"场景\"
directive = \"第二版指令\"
",
        );
        assert_eq!(
            library,
            vec![Scenario {
                name: "场景".into(),
                directive: "第二版指令".into(),
            }]
        );
    }

    #[test]
    fn unparsable_or_empty_files_are_empty_libraries() {
        assert!(parse_scenarios("not = = toml").is_empty());
        assert!(parse_scenarios("").is_empty());
        // A file with other tables but no scenarios is still empty (and
        // unknown fields inside an entry are ignored, not fatal).
        assert!(parse_scenarios("[other]\nkey = 1\n").is_empty());
        assert_eq!(
            parse_scenarios(
                "[[scenario]]\nname = \"保留\"\ndirective = \"指令\"\nnote = \"未知字段\"\n"
            ),
            vec![Scenario {
                name: "保留".into(),
                directive: "指令".into()
            }]
        );
    }

    #[test]
    fn the_first_existing_file_in_search_order_wins() {
        let first = scratch("sr-scenarios-first");
        let second = scratch("sr-scenarios-second");
        std::fs::write(
            second.join(SCENARIO_FILE),
            "[[scenario]]\nname = \"第二目录\"\ndirective = \"输\"\n",
        )
        .unwrap();

        assert_eq!(
            load_scenarios(&[first.clone(), second.clone()]),
            vec![Scenario {
                name: "第二目录".into(),
                directive: "输".into()
            }]
        );

        // Once the earlier directory has a file too, it wins.
        std::fs::write(
            first.join(SCENARIO_FILE),
            "[[scenario]]\nname = \"第一目录\"\ndirective = \"赢\"\n",
        )
        .unwrap();
        assert_eq!(
            load_scenarios(&[first.clone(), second.clone()]),
            vec![Scenario {
                name: "第一目录".into(),
                directive: "赢".into()
            }]
        );
        std::fs::remove_dir_all(first).unwrap();
        std::fs::remove_dir_all(second).unwrap();
    }

    #[test]
    fn a_missing_file_or_unreadable_path_is_an_empty_library() {
        let dir = scratch("sr-scenarios-absent");
        assert!(load_scenarios(std::slice::from_ref(&dir)).is_empty());
        assert!(load_scenarios(&[]).is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A directory entry with the library's name but not a regular file
    /// (a stray directory) does not crash the loader.
    #[test]
    fn a_directory_named_like_the_library_is_ignored() {
        let dir = scratch("sr-scenarios-dir");
        std::fs::create_dir_all(dir.join(SCENARIO_FILE)).unwrap();
        assert!(load_scenarios(std::slice::from_ref(&dir)).is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
