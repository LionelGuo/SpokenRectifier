//! `[history]` configuration: whether the session history keeps anything
//! at all, and for how long.
//!
//! Layered like every section (loading rules live in the config crate).
//! No secrets live here, so both files are equal citizens.

use std::path::PathBuf;

use serde::Deserialize;
use spokenrectifier_config::load_section_layers;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HistoryConfig {
    /// Whether sessions are kept at all. `false` is the keep-nothing
    /// mode: nothing is ever written, and clear is a no-op.
    pub enabled: bool,
    /// How long a session stays retrievable. Rows at or past this age
    /// are swept when the store opens, on every record, and on every
    /// read.
    pub retention_days: u64,
}

impl Default for HistoryConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            retention_days: 30,
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("history config: {0}")]
pub struct HistoryConfigError(pub String);

// -- file layering ----------------------------------------------------------

/// The `[history]` overlay: the config crate loads it, this crate folds
/// it onto the defaults.
#[derive(Debug, Default, Deserialize)]
struct HistorySection {
    enabled: Option<bool>,
    retention_days: Option<u64>,
}

/// Load the history settings from the layer files, wherever they live
/// among `dirs`: defaults, overlaid with `spokenrectifier.toml`, then
/// `spokenrectifier.local.toml` (which wins). Missing files are fine;
/// malformed ones are an error naming the file.
pub fn load_history_config(dirs: &[PathBuf]) -> Result<HistoryConfig, HistoryConfigError> {
    let layers = load_section_layers::<HistorySection>(dirs, "history")
        .map_err(|err| HistoryConfigError(err.0))?;
    let mut config = HistoryConfig::default();
    for layer in layers {
        if let Some(v) = layer.value.enabled {
            config.enabled = v;
        }
        if let Some(v) = layer.value.retention_days {
            config.retention_days = v;
        }
    }
    Ok(config)
}

/// Write both settings back into the layer files (the settings window's
/// 保留期 / 不留存 controls, ticket 18). The target is the layer file
/// that OWNS the effective values — the last one saying anything about
/// `[history]`, since writing anywhere else would be masked by it — or
/// the shared file when no layer overrides (created in the config home
/// when missing). The edit is section-preserving: every other value,
/// comment, and blank line in the file survives byte for byte, and a
/// malformed file is refused, never clobbered.
///
/// Saving does not touch a running store: the caller applies the new
/// config through [`crate::HistoryStore::apply_config`] and re-reads.
pub fn save_history_config(
    dirs: &[PathBuf],
    config: &HistoryConfig,
) -> Result<(), HistoryConfigError> {
    if config.retention_days == 0 {
        return Err(HistoryConfigError(
            "retention_days must be at least 1: zero would sweep every row on sight".into(),
        ));
    }
    // Who owns the effective values now? Writing both keys there means
    // the next load returns exactly what was saved.
    let layers = load_section_layers::<HistorySection>(dirs, "history")
        .map_err(|err| HistoryConfigError(err.0))?;
    let file = layers
        .last()
        .map(|layer| layer.source.file_name())
        .unwrap_or(spokenrectifier_config::SHARED_FILE);
    let path = spokenrectifier_config::find_file(dirs, file)
        .unwrap_or_else(|| spokenrectifier_config::settings_home(dirs).join(file));

    // A missing file starts a fresh document; an unreadable one (a
    // directory in its place, say) is an error like any other.
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(err) => return Err(HistoryConfigError(format!("{}: {err}", path.display()))),
    };
    let mut document = text
        .parse::<toml_edit::DocumentMut>()
        .map_err(|err| HistoryConfigError(format!("{}: {err}", path.display())))?;

    if document.get_mut("history").is_none() {
        // A fresh section (index-reading a missing key would panic).
        document["history"] = toml_edit::Item::Table(toml_edit::Table::new());
    }
    let Some(history) = document
        .get_mut("history")
        .and_then(|item| item.as_table_mut())
    else {
        return Err(HistoryConfigError(format!(
            "{}: [history] exists but is not a table",
            path.display()
        )));
    };
    // insert (not index-assign) keeps an existing key's position and
    // formatting, and creates a plain one when absent.
    history.insert("enabled", toml_edit::value(config.enabled));
    history.insert(
        "retention_days",
        toml_edit::value(config.retention_days as i64),
    );

    let mut rendered = document.to_string();
    if !rendered.ends_with('\n') {
        rendered.push('\n');
    }
    std::fs::write(&path, rendered)
        .map_err(|err| HistoryConfigError(format!("{}: {err}", path.display())))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layers_fold_onto_the_defaults_and_local_wins() {
        let dir = std::env::temp_dir().join("sr-history-config-layers");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join(spokenrectifier_config::SHARED_FILE),
            "[history]\nretention_days = 7\n",
        )
        .unwrap();
        std::fs::write(
            dir.join(spokenrectifier_config::LOCAL_FILE),
            "[history]\nenabled = false\n",
        )
        .unwrap();

        let config = load_history_config(std::slice::from_ref(&dir)).unwrap();
        assert!(!config.enabled); // local wins
        assert_eq!(config.retention_days, 7); // shared file
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn missing_files_leave_the_defaults() {
        let dir = std::env::temp_dir().join("sr-history-config-empty");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        assert_eq!(
            load_history_config(std::slice::from_ref(&dir)).unwrap(),
            HistoryConfig::default()
        );
        assert_eq!(load_history_config(&[]).unwrap(), HistoryConfig::default());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    // -- the settings window's write path (ticket 18) -----------------------

    use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

    fn dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn saving_without_any_override_creates_the_shared_file_in_the_home() {
        let cwd = dir("sr-history-save-cwd");
        let exe = dir("sr-history-save-exe");
        let dirs = vec![cwd.clone(), exe.clone()];

        save_history_config(&dirs, &HistoryConfig::default()).unwrap();

        // settings_home without a local layer = the last search dir; the
        // earlier directory stays untouched, and loading returns exactly
        // what was saved.
        let written = std::fs::read_to_string(exe.join(SHARED_FILE)).unwrap();
        assert!(written.contains("[history]"), "got: {written}");
        assert_eq!(
            load_history_config(&dirs).unwrap(),
            HistoryConfig::default()
        );
        assert!(!cwd.join(SHARED_FILE).exists());
        std::fs::remove_dir_all(cwd).unwrap();
        std::fs::remove_dir_all(exe).unwrap();
    }

    #[test]
    fn saving_preserves_every_other_value_and_comment_in_the_file() {
        let dir = dir("sr-history-save-preserve");
        std::fs::write(
            dir.join(SHARED_FILE),
            "# 手写注释要活着\n[engine]\nparagraph_gap_ms = 900\n\n[history]\nenabled = true\nretention_days = 90\n",
        )
        .unwrap();

        save_history_config(
            std::slice::from_ref(&dir),
            &HistoryConfig {
                enabled: false,
                retention_days: 7,
            },
        )
        .unwrap();

        let written = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(
            written.contains("# 手写注释要活着"),
            "comment lost: {written}"
        );
        assert!(
            written.contains("paragraph_gap_ms = 900"),
            "other section lost"
        );
        assert!(written.contains("enabled = false"));
        assert!(written.contains("retention_days = 7"));
        assert!(
            !written.contains("retention_days = 90"),
            "stale value left behind"
        );
        let config = load_history_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(
            config,
            HistoryConfig {
                enabled: false,
                retention_days: 7,
            }
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn saving_targets_the_layer_that_owns_the_effective_values() {
        let dir = dir("sr-history-save-winner");
        // Both layers speak; local wins, so the write must land there —
        // writing the shared file would be masked by the local override.
        std::fs::write(
            dir.join(SHARED_FILE),
            "[history]\nenabled = true\nretention_days = 90\n",
        )
        .unwrap();
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[history]\nenabled = true\nretention_days = 30\n",
        )
        .unwrap();

        save_history_config(
            std::slice::from_ref(&dir),
            &HistoryConfig {
                enabled: false,
                retention_days: 7,
            },
        )
        .unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(
            shared.contains("retention_days = 90"),
            "shared file was touched: {shared}"
        );
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("retention_days = 7"),
            "local file not updated: {local}"
        );
        assert_eq!(
            load_history_config(std::slice::from_ref(&dir)).unwrap(),
            HistoryConfig {
                enabled: false,
                retention_days: 7,
            }
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_zero_retention_is_refused_and_writes_nothing() {
        let dir = dir("sr-history-save-zero");
        let err = save_history_config(
            std::slice::from_ref(&dir),
            &HistoryConfig {
                enabled: true,
                retention_days: 0,
            },
        )
        .unwrap_err()
        .0;
        assert!(err.contains("retention_days"), "got: {err}");
        assert!(!dir.join(SHARED_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_malformed_target_file_is_refused_never_clobbered() {
        let dir = dir("sr-history-save-malformed");
        std::fs::write(dir.join(SHARED_FILE), "not = = toml").unwrap();

        let err = save_history_config(std::slice::from_ref(&dir), &HistoryConfig::default())
            .unwrap_err()
            .0;
        assert!(err.contains(SHARED_FILE), "got: {err}");
        assert_eq!(
            std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap(),
            "not = = toml"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
