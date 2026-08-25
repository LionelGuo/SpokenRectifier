//! `[engine]` config loading for the app-side engine assembly.
//!
//! Lives outside `api.rs` so flutter_rust_bridge's codegen (which mirrors
//! everything in the api module) does not pick the loader types up as part
//! of the Dart-facing surface.

use std::path::Path;

use anyhow::anyhow;
use spokenrectifier_engine::EngineConfig;

/// The `[engine]` section of a config layer.
#[derive(Debug, Default, serde::Deserialize)]
struct EngineSection {
    passage_mode: Option<bool>,
    paragraph_silence_ms: Option<u64>,
    session_end_silence_ms: Option<u64>,
}

#[derive(Debug, Default, serde::Deserialize)]
struct EngineFile {
    engine: Option<EngineSection>,
}

/// Load the session semantics from `spokenrectifier.toml`, then
/// `spokenrectifier.local.toml` (which wins), over the defaults. Missing
/// files are fine; malformed ones are an error naming the file.
pub fn engine_config_from_dir(dir: &Path) -> anyhow::Result<EngineConfig> {
    let mut config = EngineConfig::default();
    for name in ["spokenrectifier.toml", "spokenrectifier.local.toml"] {
        let path = dir.join(name);
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue; // optional file
        };
        let file: EngineFile =
            toml::from_str(&text).map_err(|err| anyhow!("{}: {err}", path.display()))?;
        if let Some(engine) = file.engine {
            if let Some(v) = engine.passage_mode {
                config.passage_mode = v;
            }
            if let Some(v) = engine.paragraph_silence_ms {
                config.paragraph_silence_ms = v;
            }
            if let Some(v) = engine.session_end_silence_ms {
                config.session_end_silence_ms = v;
            }
        }
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_config_layers_over_defaults_and_local_wins() {
        let dir = std::env::temp_dir().join("sr-bridge-engine-config-layers");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[engine]\nparagraph_silence_ms = 2000\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[engine]\npassage_mode = false\nsession_end_silence_ms = 1500\n",
        )
        .unwrap();

        let config = engine_config_from_dir(&dir).unwrap();
        assert!(config.paragraph_silence_ms == 2000); // shared file
        assert!(!config.passage_mode); // local wins over the default
        assert_eq!(config.session_end_silence_ms, 1500); // local file
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn engine_config_missing_or_empty_files_leave_defaults() {
        let dir = std::env::temp_dir().join("sr-bridge-engine-config-empty");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("spokenrectifier.toml"), "").unwrap();

        assert_eq!(
            engine_config_from_dir(&dir).unwrap(),
            EngineConfig::default()
        );
        assert_eq!(
            engine_config_from_dir(Path::new("/nonexistent")).unwrap(),
            EngineConfig::default()
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn engine_config_malformed_file_names_the_path() {
        let dir = std::env::temp_dir().join("sr-bridge-engine-config-bad");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("spokenrectifier.local.toml"), "[engine\nbroken").unwrap();

        let err = engine_config_from_dir(&dir).unwrap_err().to_string();
        assert!(err.contains("spokenrectifier.local.toml"), "got: {err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
