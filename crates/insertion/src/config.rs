//! `[insertion]` configuration: how confirmed text reaches the target
//! window, and the pacing of each mode.
//!
//! Layered like every section (loading rules live in the config crate).
//! No secrets live here, so both files are equal citizens.

use std::path::PathBuf;

use serde::Deserialize;
use spokenrectifier_config::load_section_layers;
use spokenrectifier_config::section_write::{SectionField, WriteLayer};

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

impl InsertionMode {
    /// The file/wire name — serde's lowercase form, spelled out for the
    /// settings editor's section writes and the bridge's mode field.
    pub fn as_str(self) -> &'static str {
        match self {
            InsertionMode::Paste => "paste",
            InsertionMode::Typing => "typing",
        }
    }

    /// Parse the file/wire name; unknown names are `None` for the caller
    /// to refuse.
    pub fn from_name(name: &str) -> Option<Self> {
        match name.trim() {
            "paste" => Some(InsertionMode::Paste),
            "typing" => Some(InsertionMode::Typing),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

// -- the settings editor's write path (ticket 19 rework) ----------------------

/// Write the advanced form's `[insertion]` model back into the layer
/// files: section-preserving into the layer that owns the section (no
/// secrets here, so both files are equal citizens). Saving writes
/// exactly these fields, so the next load returns what the form held.
pub fn save_insertion_timing(
    dirs: &[PathBuf],
    config: &InsertionConfig,
) -> Result<(), InsertionConfigError> {
    let int = |name: &str, value: u64| -> Result<SectionField, InsertionConfigError> {
        i64::try_from(value)
            .map(|value| SectionField::int(name, value))
            .map_err(|_| InsertionConfigError(format!("[insertion] {name} is out of range")))
    };
    let fields = vec![
        SectionField::str("mode", config.mode.as_str()),
        int("focus_settle_ms", config.focus_settle_ms)?,
        int("paste_settle_ms", config.paste_settle_ms)?,
        int("typing_delay_ms", config.typing_delay_ms)?,
    ];
    spokenrectifier_config::section_write::write_section_fields(
        dirs,
        "insertion",
        &fields,
        WriteLayer::Owning,
    )
    .map_err(|err| InsertionConfigError(err.0))
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

    #[test]
    fn the_spelled_names_round_trip_both_ways() {
        for (mode, name) in [
            (InsertionMode::Paste, "paste"),
            (InsertionMode::Typing, "typing"),
        ] {
            assert_eq!(mode.as_str(), name);
            assert_eq!(InsertionMode::from_name(name), Some(mode));
        }
        assert_eq!(InsertionMode::from_name("telepathy"), None);
    }

    // -- the settings editor's write path (ticket 19 rework) ---------------

    use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

    #[test]
    fn a_save_round_trips_into_the_owning_layer() {
        let dir = std::env::temp_dir().join("sr-insertion-save-owning");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // Local owns [insertion]; the write must land there or the shared
        // file's values would keep winning.
        std::fs::write(dir.join(SHARED_FILE), "[insertion]\nmode = \"paste\"\n").unwrap();
        std::fs::write(dir.join(LOCAL_FILE), "[insertion]\ntyping_delay_ms = 12\n").unwrap();

        save_insertion_timing(
            std::slice::from_ref(&dir),
            &InsertionConfig {
                mode: InsertionMode::Typing,
                focus_settle_ms: 80,
                paste_settle_ms: 250,
                typing_delay_ms: 12,
            },
        )
        .unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(
            shared.contains("mode = \"paste\""),
            "shared file was touched: {shared}"
        );
        let config = load_insertion_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.mode, InsertionMode::Typing);
        assert_eq!(config.focus_settle_ms, 80);
        assert_eq!(config.typing_delay_ms, 12); // sibling field survived
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_save_without_any_layer_creates_the_shared_file() {
        let dir = std::env::temp_dir().join("sr-insertion-save-fresh");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        save_insertion_timing(
            std::slice::from_ref(&dir),
            &InsertionConfig {
                mode: InsertionMode::Typing,
                focus_settle_ms: 50,
                paste_settle_ms: 300,
                typing_delay_ms: 8,
            },
        )
        .unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(shared.contains("mode = \"typing\""), "got: {shared}");
        assert!(shared.contains("paste_settle_ms = 300"));
        assert_eq!(
            load_insertion_config(std::slice::from_ref(&dir))
                .unwrap()
                .mode,
            InsertionMode::Typing
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
