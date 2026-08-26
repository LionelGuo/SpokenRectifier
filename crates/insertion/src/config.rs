//! `[insertion]` configuration: how confirmed text reaches the target
//! window, and the pacing of each mode.
//!
//! Layered like every section (loading rules live in the config crate).
//! No secrets live here, so both files are equal citizens.

use std::path::PathBuf;

use serde::Deserialize;
use spokenrectifier_config::load_section_layers;

/// How confirmed text is inserted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InsertionMode {
    /// Replace the clipboard, send Ctrl+V at the target, restore the
    /// clipboard. The default: fast, layout-independent, works everywhere
    /// paste works.
    Paste,
    /// Type the text key by key (Unicode SendInput). For targets that
    /// block or mangle paste; slower, touches no clipboard.
    Typing,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InsertionConfig {
    pub mode: InsertionMode,
    /// Wait after re-focusing the target before sending keys: the target
    /// needs a moment to restore its caret.
    pub focus_settle_ms: u64,
    /// Wait after Ctrl+V before restoring the clipboard: the target reads
    /// the clipboard synchronously, but give slow apps room.
    pub paste_settle_ms: u64,
    /// Pause between typed characters, so targets can keep up.
    pub typing_delay_ms: u64,
}

impl Default for InsertionConfig {
    fn default() -> Self {
        Self {
            mode: InsertionMode::Paste,
            focus_settle_ms: 50,
            paste_settle_ms: 250,
            typing_delay_ms: 8,
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("insertion config: {0}")]
pub struct InsertionConfigError(pub String);

// -- file layering ----------------------------------------------------------

/// The `[insertion]` overlay: the config crate loads it (and validates
/// the mode against the serde enum), this crate folds it.
#[derive(Debug, Default, Deserialize)]
struct InsertionSection {
    mode: Option<InsertionMode>,
    focus_settle_ms: Option<u64>,
    paste_settle_ms: Option<u64>,
    typing_delay_ms: Option<u64>,
}

/// Load the `[insertion]` config from the layer files, wherever they live
/// among `dirs`: defaults, overlaid with `spokenrectifier.toml`, then
/// `spokenrectifier.local.toml` (which wins). Missing files are fine;
/// malformed ones — or an unknown mode — are an error naming the file.
pub fn load_insertion_config(dirs: &[PathBuf]) -> Result<InsertionConfig, InsertionConfigError> {
    let mut config = InsertionConfig::default();
    let layers = load_section_layers::<InsertionSection>(dirs, "insertion")
        .map_err(|err| InsertionConfigError(err.0))?;
    for layer in layers {
        if let Some(v) = layer.value.mode {
            config.mode = v;
        }
        if let Some(v) = layer.value.focus_settle_ms {
            config.focus_settle_ms = v;
        }
        if let Some(v) = layer.value.paste_settle_ms {
            config.paste_settle_ms = v;
        }
        if let Some(v) = layer.value.typing_delay_ms {
            config.typing_delay_ms = v;
        }
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_paste_mode_with_documented_pacing() {
        let config = InsertionConfig::default();
        assert_eq!(config.mode, InsertionMode::Paste);
        assert_eq!(config.focus_settle_ms, 50);
        assert_eq!(config.paste_settle_ms, 250);
        assert_eq!(config.typing_delay_ms, 8);
    }

    #[test]
    fn file_layers_apply_and_local_wins() {
        let dir = std::env::temp_dir().join("sr-insertion-config-layers");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[insertion]\nmode = \"typing\"\npaste_settle_ms = 400\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[insertion]\nmode = \"paste\"\ntyping_delay_ms = 12\n",
        )
        .unwrap();

        let config = load_insertion_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.mode, InsertionMode::Paste); // local wins
        assert_eq!(config.paste_settle_ms, 400); // shared file
        assert_eq!(config.typing_delay_ms, 12); // local file
        assert_eq!(config.focus_settle_ms, 50); // untouched default
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_unknown_mode_names_the_file_and_the_value() {
        let dir = std::env::temp_dir().join("sr-insertion-config-bad-mode");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[insertion]\nmode = \"telepathy\"\n",
        )
        .unwrap();

        let err = load_insertion_config(std::slice::from_ref(&dir))
            .unwrap_err()
            .0;
        assert!(err.contains("spokenrectifier.toml"), "got: {err}");
        assert!(err.contains("telepathy"), "got: {err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
