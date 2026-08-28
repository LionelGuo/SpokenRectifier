//! The scenario library (glossary: 场景, 场景库, 风格指令): one app-owned
//! TOML file of named style directives — not a layered config layer, and
//! never a home for secrets.
//!
//! The library file is written by hand or by the settings screen's editor
//! (ticket 17); either way the app needs read-write ownership of its own
//! file, which the user-authored layer files cannot offer (ADR-0004). A
//! missing or unparsable file reads as an empty library: the loader never
//! errors and never writes, so a broken library degrades to the default
//! register instead of blocking startup. The save path (the editor's
//! writes) only ever runs on a user action, never on load.

use std::path::PathBuf;

use crate::{find_file, settings_home};

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

// -- the editor's write path (ticket 17) ------------------------------------

/// The serialization mirror of [`ScenarioFile`] — same format the loader
/// reads (`[[scenario]]` tables), so a save-then-load round trip is the
/// identity.
#[derive(serde::Serialize)]
struct ScenarioFileOut {
    scenario: Vec<ScenarioEntryOut>,
}

#[derive(serde::Serialize)]
struct ScenarioEntryOut {
    name: String,
    directive: String,
}

/// Render the library as the file text — pure, and the round-trip twin of
/// [`parse_scenarios`]. Every entry is written trimmed (the loader's own
/// normalization, applied up front so the file is canonical), and the
/// writer refuses what the loader would silently mangle: a blank name or
/// directive, and a duplicated name (whose saved file would read back
/// keeping only the last entry). An empty library renders as an empty
/// table list, which loads back as no scenarios.
fn render_scenarios(scenarios: &[Scenario]) -> std::io::Result<String> {
    let mut seen = std::collections::HashSet::new();
    let mut entries = Vec::with_capacity(scenarios.len());
    for scenario in scenarios {
        let name = scenario.name.trim();
        let directive = scenario.directive.trim();
        if name.is_empty() || directive.is_empty() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "a scenario needs both a name and a directive",
            ));
        }
        if !seen.insert(name) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("a duplicated scenario name: {name}"),
            ));
        }
        entries.push(ScenarioEntryOut {
            name: name.to_string(),
            directive: directive.to_string(),
        });
    }
    toml::to_string_pretty(&ScenarioFileOut { scenario: entries })
        .map(|mut text| {
            if !text.ends_with('\n') {
                text.push('\n');
            }
            text
        })
        .map_err(|err| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("cannot render the library: {err}"),
            )
        })
}

/// Save the whole library — the settings editor's model, wholesale — into
/// the file the loader resolves, creating it in [`settings_home`] when no
/// library exists yet. The rewrite replaces the file's bytes entirely
/// (hand comments and hand formatting go with them): after an edit the
/// file is the editor's canonical form, which the loader reads back as
/// exactly what was saved. Only ever called on a user action — loading
/// never writes, so a corrupt file stays untouched until the user edits.
pub fn save_scenarios(dirs: &[PathBuf], scenarios: &[Scenario]) -> std::io::Result<()> {
    let text = render_scenarios(scenarios)?;
    let path =
        find_file(dirs, SCENARIO_FILE).unwrap_or_else(|| settings_home(dirs).join(SCENARIO_FILE));
    std::fs::write(&path, text)
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

    // -- the editor's write path (ticket 17) --------------------------------

    fn sample_library() -> Vec<Scenario> {
        vec![
            Scenario {
                name: "论文".into(),
                directive: "学术书面语:客观严谨".into(),
            },
            Scenario {
                name: "聊天".into(),
                directive: "轻松自然".into(),
            },
        ]
    }

    #[test]
    fn save_then_load_round_trips_the_library() {
        let rendered = render_scenarios(&sample_library()).unwrap();
        assert_eq!(parse_scenarios(&rendered), sample_library());
    }

    #[test]
    fn save_renders_the_loaders_file_format() {
        let rendered = render_scenarios(&sample_library()).unwrap();
        assert_eq!(
            rendered,
            "[[scenario]]\nname = \"论文\"\ndirective = \"学术书面语:客观严谨\"\n\n\
             [[scenario]]\nname = \"聊天\"\ndirective = \"轻松自然\"\n"
        );
    }

    #[test]
    fn save_trims_entries_so_the_file_is_canonical() {
        let rendered = render_scenarios(&[Scenario {
            name: "  带空白  ".into(),
            directive: "  指令  ".into(),
        }])
        .unwrap();
        assert_eq!(parse_scenarios(&rendered).len(), 1);
        assert!(rendered.contains("name = \"带空白\""));
    }

    #[test]
    fn an_empty_library_renders_an_empty_table_list() {
        let rendered = render_scenarios(&[]).unwrap();
        assert!(parse_scenarios(&rendered).is_empty());
    }

    #[test]
    fn the_writer_refuses_what_the_loader_would_mangle() {
        assert!(
            render_scenarios(&[Scenario {
                name: "  ".into(),
                directive: "有指令".into()
            }])
            .is_err()
        );
        assert!(
            render_scenarios(&[Scenario {
                name: "有名字".into(),
                directive: "".into()
            }])
            .is_err()
        );
        assert!(
            render_scenarios(&[
                Scenario {
                    name: "同名".into(),
                    directive: "第一版".into()
                },
                Scenario {
                    name: "同名".into(),
                    directive: "第二版".into()
                },
            ])
            .is_err()
        );
    }

    #[test]
    fn save_creates_the_library_in_settings_home_when_none_exists() {
        let cwd = scratch("sr-scenarios-save-cwd");
        let exe = scratch("sr-scenarios-save-exe");

        save_scenarios(&[cwd.clone(), exe.clone()], &sample_library()).unwrap();

        // settings_home without a local layer = beside the executable (the
        // last search dir); nothing appears in the earlier directory.
        let written = std::fs::read_to_string(exe.join(SCENARIO_FILE)).unwrap();
        assert_eq!(parse_scenarios(&written), sample_library());
        assert!(!cwd.join(SCENARIO_FILE).exists());
        std::fs::remove_dir_all(cwd).unwrap();
        std::fs::remove_dir_all(exe).unwrap();
    }

    #[test]
    fn save_writes_into_the_file_the_loader_resolves() {
        let one = scratch("sr-scenarios-save-order-one");
        let two = scratch("sr-scenarios-save-order-two");
        std::fs::write(
            two.join(SCENARIO_FILE),
            "[[scenario]]\nname = \"既有\"\ndirective = \"指令\"\n",
        )
        .unwrap();

        save_scenarios(&[one.clone(), two.clone()], &sample_library()).unwrap();

        // The existing library (found later in the search) is the one
        // rewritten; nothing is created in the earlier directory.
        assert_eq!(
            load_scenarios(&[one.clone(), two.clone()]),
            sample_library()
        );
        assert!(!one.join(SCENARIO_FILE).exists());
        std::fs::remove_dir_all(one).unwrap();
        std::fs::remove_dir_all(two).unwrap();
    }

    #[test]
    fn a_failed_validation_writes_nothing() {
        let dir = scratch("sr-scenarios-save-invalid");
        assert!(
            save_scenarios(
                std::slice::from_ref(&dir),
                &[Scenario {
                    name: "  ".into(),
                    directive: "指令".into()
                }]
            )
            .is_err()
        );
        assert!(!dir.join(SCENARIO_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn saving_an_empty_library_empties_the_file() {
        let dir = scratch("sr-scenarios-save-empty");
        save_scenarios(std::slice::from_ref(&dir), &sample_library()).unwrap();
        assert_eq!(load_scenarios(std::slice::from_ref(&dir)).len(), 2);

        // Deleting the last scenario rewrites the file as a valid, empty
        // library — the pickers read empty, the file stays loadable.
        save_scenarios(std::slice::from_ref(&dir), &[]).unwrap();
        assert!(load_scenarios(std::slice::from_ref(&dir)).is_empty());
        assert!(
            parse_scenarios(&std::fs::read_to_string(dir.join(SCENARIO_FILE)).unwrap()).is_empty()
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_deliberate_save_replaces_a_corrupt_file_with_a_valid_one() {
        let dir = scratch("sr-scenarios-save-corrupt");
        std::fs::write(dir.join(SCENARIO_FILE), "not = = toml").unwrap();
        // Loading never wrote it away...
        assert!(load_scenarios(std::slice::from_ref(&dir)).is_empty());
        assert_eq!(
            std::fs::read_to_string(dir.join(SCENARIO_FILE)).unwrap(),
            "not = = toml"
        );
        // ...but the user's edit rewrites it into the canonical form.
        save_scenarios(std::slice::from_ref(&dir), &sample_library()).unwrap();
        assert_eq!(load_scenarios(std::slice::from_ref(&dir)), sample_library());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
