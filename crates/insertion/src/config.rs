//! `[insertion]` configuration: how confirmed text reaches the target
//! window, and the pacing of each mode.
//!
//! Layered like the other sections: defaults, then `spokenrectifier.toml`,
//! then `spokenrectifier.local.toml` (which wins). No secrets live here,
//! so both files are equal citizens.

use std::fs;
use std::path::Path;

use serde::Deserialize;

/// How confirmed text is inserted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

impl InsertionMode {
    fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "paste" => Some(InsertionMode::Paste),
            "typing" => Some(InsertionMode::Typing),
            _ => None,
        }
    }
}

// -- file layering ----------------------------------------------------------

#[derive(Debug, Default, Deserialize)]
struct FileConfig {
    insertion: Option<InsertionSection>,
}

#[derive(Debug, Default, Deserialize)]
struct InsertionSection {
    mode: Option<String>,
    focus_settle_ms: Option<u64>,
    paste_settle_ms: Option<u64>,
    typing_delay_ms: Option<u64>,
}

fn read_layer(config: &mut InsertionConfig, path: &Path) -> Result<(), InsertionConfigError> {
    let Ok(text) = fs::read_to_string(path) else {
        return Ok(()); // optional file
    };
    let parsed: FileConfig = toml::from_str(&text).map_err(|err| {
        // Not the crate's formatted message: it quotes the offending line,
        // which may carry a secret from another section.
        InsertionConfigError(format!(
            "{}: malformed TOML: {}",
            path.display(),
            err.message()
        ))
    })?;
    let Some(section) = parsed.insertion else {
        return Ok(());
    };
    if let Some(v) = section.mode {
        config.mode = InsertionMode::parse(&v).ok_or_else(|| {
            InsertionConfigError(format!(
                "{}: insertion mode must be \"paste\" or \"typing\", got {v:?}",
                path.display()
            ))
        })?;
    }
    if let Some(v) = section.focus_settle_ms {
        config.focus_settle_ms = v;
    }
    if let Some(v) = section.paste_settle_ms {
        config.paste_settle_ms = v;
    }
    if let Some(v) = section.typing_delay_ms {
        config.typing_delay_ms = v;
    }
    Ok(())
}

/// Load the `[insertion]` config from a directory: defaults, overlaid with
/// `spokenrectifier.toml`, then `spokenrectifier.local.toml` (which wins).
/// Missing files are fine; malformed ones are an error naming the file.
pub fn load_insertion_config(dir: &Path) -> Result<InsertionConfig, InsertionConfigError> {
    let mut config = InsertionConfig::default();
    read_layer(&mut config, &dir.join("spokenrectifier.toml"))?;
    read_layer(&mut config, &dir.join("spokenrectifier.local.toml"))?;
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

        let config = load_insertion_config(&dir).unwrap();
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

        let err = load_insertion_config(&dir).unwrap_err().0;
        assert!(err.contains("spokenrectifier.toml"), "got: {err}");
        assert!(err.contains("telepathy"), "got: {err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn missing_files_leave_defaults() {
        assert_eq!(
            load_insertion_config(Path::new("/nonexistent")).unwrap(),
            InsertionConfig::default()
        );
    }
}
