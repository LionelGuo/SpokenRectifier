//! The global directive (glossary: 全局指令): one app-owned companion
//! file with a single `directive` key — not a layered config layer, and
//! never a home for secrets.
//!
//! A file, still, after the business data moved into the store
//! (ADR-0023): the directive is configuration — one value with no
//! relationships — not business data, so it stays beside the layer files
//! rather than inside the database. One file, one owner.
//!
//! Same tolerance posture as the rest of the config: a missing,
//! unparsable, or blank-directive file reads as "no global directive"
//! (`None`); the loader never errors and never writes. The save path
//! only ever runs on a user action (the settings editor's save button).

use std::path::PathBuf;

use crate::{find_file, settings_home};

/// The global directive's file name, looked up in every config search
/// directory.
pub const GLOBAL_FILE: &str = "spokenrectifier-global.toml";

#[derive(Debug, Default, serde::Deserialize)]
struct GlobalFile {
    #[serde(default)]
    directive: String,
}

/// Load the global directive from the first existing
/// `spokenrectifier-global.toml` among `dirs` (the config search order).
/// Tolerance rules: the directive is trimmed; blank, missing, or
/// unparsable all read as `None` (unset) — never an error, never a write.
pub fn load_global_directive(dirs: &[PathBuf]) -> Option<String> {
    let path = find_file(dirs, GLOBAL_FILE)?;
    match std::fs::read_to_string(&path) {
        Ok(text) => parse_global_directive(&text),
        Err(_) => None,
    }
}

/// The parsing rule, pure over the file text: one `directive` key,
/// trimmed; everything else about the file is tolerated away.
fn parse_global_directive(text: &str) -> Option<String> {
    let file = toml::from_str::<GlobalFile>(text).ok()?;
    let directive = file.directive.trim();
    (!directive.is_empty()).then(|| directive.to_string())
}

// -- the editor's write path (ticket 22) --------------------------------------

/// The serialization mirror of [`GlobalFile`] — same format the loader
/// reads, so a save-then-load round trip is the identity.
#[derive(serde::Serialize)]
struct GlobalFileOut {
    directive: String,
}

/// Save the global directive into the file the loader resolves, creating
/// it in [`settings_home`] when none exists yet. `None` and blank text
/// both write the canonical unset form (`directive = ""`), which loads
/// back as `None`: clearing the field and saving is how the directive is
/// turned off — there is no separate clear action. Only ever called on a
/// user action; loading never writes.
pub fn save_global_directive(dirs: &[PathBuf], directive: Option<&str>) -> std::io::Result<()> {
    let trimmed = directive.unwrap_or_default().trim();
    let text = toml::to_string_pretty(&GlobalFileOut {
        directive: trimmed.to_string(),
    })
    .map(|mut text| {
        if !text.ends_with('\n') {
            text.push('\n');
        }
        text
    })
    .map_err(|err| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("cannot render the global directive: {err}"),
        )
    })?;
    let path =
        find_file(dirs, GLOBAL_FILE).unwrap_or_else(|| settings_home(dirs).join(GLOBAL_FILE));
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
    fn parses_the_directive_key_trimmed() {
        assert_eq!(
            parse_global_directive("directive = \"  全部输出用简体。  \"\n").as_deref(),
            Some("全部输出用简体。")
        );
    }

    #[test]
    fn a_blank_directive_is_unset() {
        assert_eq!(parse_global_directive("directive = \"\"\n"), None);
        assert_eq!(parse_global_directive("directive = \"   \"\n"), None);
        // A file with no directive key at all — the same as blank.
        assert_eq!(parse_global_directive("[other]\nkey = 1\n"), None);
    }

    #[test]
    fn an_unparsable_or_empty_file_is_unset() {
        assert_eq!(parse_global_directive("not = = toml"), None);
        assert_eq!(parse_global_directive(""), None);
        // Unknown fields are ignored, not fatal.
        assert_eq!(
            parse_global_directive("directive = \"指令\"\nnote = \"未知字段\"\n").as_deref(),
            Some("指令")
        );
    }

    #[test]
    fn the_first_existing_file_in_search_order_wins() {
        let first = scratch("sr-global-first");
        let second = scratch("sr-global-second");
        std::fs::write(second.join(GLOBAL_FILE), "directive = \"第二目录\"\n").unwrap();
        assert_eq!(
            load_global_directive(&[first.clone(), second.clone()]).as_deref(),
            Some("第二目录")
        );

        std::fs::write(first.join(GLOBAL_FILE), "directive = \"第一目录\"\n").unwrap();
        assert_eq!(
            load_global_directive(&[first.clone(), second.clone()]).as_deref(),
            Some("第一目录")
        );
        std::fs::remove_dir_all(first).unwrap();
        std::fs::remove_dir_all(second).unwrap();
    }

    #[test]
    fn a_missing_file_or_empty_search_is_unset() {
        let dir = scratch("sr-global-absent");
        assert_eq!(load_global_directive(std::slice::from_ref(&dir)), None);
        assert_eq!(load_global_directive(&[]), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A directory entry with the file's name but not a regular file (a
    /// stray directory) does not crash the loader.
    #[test]
    fn a_directory_named_like_the_file_is_ignored() {
        let dir = scratch("sr-global-dir");
        std::fs::create_dir_all(dir.join(GLOBAL_FILE)).unwrap();
        assert_eq!(load_global_directive(std::slice::from_ref(&dir)), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    // -- the editor's write path (ticket 22) --------------------------------

    #[test]
    fn save_then_load_round_trips_the_directive() {
        fn save_then_load(directive: Option<&str>) -> Option<String> {
            let dir = scratch("sr-global-roundtrip");
            save_global_directive(std::slice::from_ref(&dir), directive).unwrap();
            let back = load_global_directive(std::slice::from_ref(&dir));
            std::fs::remove_dir_all(dir).unwrap();
            back
        }
        assert_eq!(save_then_load(None), None);
        assert_eq!(
            save_then_load(Some("  全部输出用简体。  ")).as_deref(),
            Some("全部输出用简体。")
        );
        assert_eq!(save_then_load(Some("   ")), None);
    }

    #[test]
    fn save_renders_the_loaders_file_format() {
        let dir = scratch("sr-global-format");
        save_global_directive(std::slice::from_ref(&dir), Some("全部输出用简体。")).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.join(GLOBAL_FILE)).unwrap(),
            "directive = \"全部输出用简体。\"\n"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn saving_unset_rewrites_the_canonical_empty_form() {
        let dir = scratch("sr-global-unset");
        save_global_directive(std::slice::from_ref(&dir), Some("旧指令")).unwrap();
        assert_eq!(
            load_global_directive(std::slice::from_ref(&dir)).as_deref(),
            Some("旧指令")
        );

        // Clearing the field and saving is the off switch: the file keeps
        // its valid shape, the loader reads unset.
        save_global_directive(std::slice::from_ref(&dir), None).unwrap();
        assert_eq!(load_global_directive(std::slice::from_ref(&dir)), None);
        assert_eq!(
            std::fs::read_to_string(dir.join(GLOBAL_FILE)).unwrap(),
            "directive = \"\"\n"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn save_creates_the_file_in_settings_home_when_none_exists() {
        let cwd = scratch("sr-global-save-cwd");
        let exe = scratch("sr-global-save-exe");

        save_global_directive(&[cwd.clone(), exe.clone()], Some("指令")).unwrap();

        // settings_home without a local layer = beside the executable (the
        // last search dir); nothing appears in the earlier directory.
        assert_eq!(
            load_global_directive(&[cwd.clone(), exe.clone()]).as_deref(),
            Some("指令")
        );
        assert!(!cwd.join(GLOBAL_FILE).exists());
        std::fs::remove_dir_all(cwd).unwrap();
        std::fs::remove_dir_all(exe).unwrap();
    }

    #[test]
    fn save_writes_into_the_file_the_loader_resolves() {
        let one = scratch("sr-global-save-order-one");
        let two = scratch("sr-global-save-order-two");
        std::fs::write(two.join(GLOBAL_FILE), "directive = \"既有\"\n").unwrap();

        save_global_directive(&[one.clone(), two.clone()], Some("新指令")).unwrap();

        // The existing file (found later in the search) is the one
        // rewritten; nothing is created in the earlier directory.
        assert_eq!(
            load_global_directive(&[one.clone(), two.clone()]).as_deref(),
            Some("新指令")
        );
        assert!(!one.join(GLOBAL_FILE).exists());
        std::fs::remove_dir_all(one).unwrap();
        std::fs::remove_dir_all(two).unwrap();
    }

    #[test]
    fn a_deliberate_save_replaces_a_corrupt_file_with_a_valid_one() {
        let dir = scratch("sr-global-save-corrupt");
        std::fs::write(dir.join(GLOBAL_FILE), "not = = toml").unwrap();
        assert_eq!(load_global_directive(std::slice::from_ref(&dir)), None);

        save_global_directive(std::slice::from_ref(&dir), Some("指令")).unwrap();
        assert_eq!(
            load_global_directive(std::slice::from_ref(&dir)).as_deref(),
            Some("指令")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_directive_save_rewrites_only_the_directive_file() {
        // The directive file is a file precisely because it is config,
        // not business data (ADR-0023 took the library and the terms to
        // the store); its writes must stay contained to their own file.
        let dir = scratch("sr-global-companion");
        std::fs::write(dir.join("spokenrectifier-scenarios.toml"), "not this one\n").unwrap();

        save_global_directive(std::slice::from_ref(&dir), Some("全局")).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.join("spokenrectifier-scenarios.toml")).unwrap(),
            "not this one\n",
            "a directive save must not rewrite a neighboring file"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
