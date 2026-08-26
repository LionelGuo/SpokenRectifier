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
}
