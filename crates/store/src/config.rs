//! `[history]` configuration: whether the session history keeps anything
//! at all, and for how long.
//!
//! Layered like every section (loading rules live in the config crate).
//! No secrets live here, so both files are equal citizens.

use std::path::PathBuf;

use serde::Deserialize;
use spokenrectifier_config::load_section_layers;
use spokenrectifier_config::section_write::{SectionField, WriteLayer};

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
/// 保留期 / 不留存 controls, ticket 18). The placement and preservation
/// rules live in the config crate's section writer: the owning layer
/// (the last one saying anything about `[history]`, or the shared file
/// when none does) gets a section-preserving edit — every other value,
/// comment, and blank line survives byte for byte, and a malformed file
/// is refused, never clobbered.
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
    spokenrectifier_config::section_write::write_section_fields(
        dirs,
        "history",
        &[
            SectionField::bool("enabled", config.enabled),
            SectionField::int("retention_days", config.retention_days as i64),
        ],
        WriteLayer::Owning,
    )
    .map_err(|err| HistoryConfigError(err.0))
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
