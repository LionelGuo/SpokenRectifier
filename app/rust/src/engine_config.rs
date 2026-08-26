//! `[engine]` config loading for the app-side engine assembly.
//!
//! Lives outside `api.rs` so flutter_rust_bridge's codegen (which mirrors
//! everything in the api module) does not pick the loader types up as part
//! of the Dart-facing surface. The loading rules live in the config crate;
//! this module owns the `[engine]` shape and its fold.

use std::path::PathBuf;

use anyhow::anyhow;
use spokenrectifier_config::load_section_layers;
use spokenrectifier_engine::EngineConfig;

/// The `[engine]` overlay: the config crate loads it, this module folds it.
#[derive(Debug, Default, serde::Deserialize)]
struct EngineSection {
    passage_mode: Option<bool>,
    paragraph_silence_ms: Option<u64>,
    session_end_silence_ms: Option<u64>,
    rectify_timeout_ms: Option<u64>,
}

/// Load the session semantics from the layer files, wherever they live
/// among `dirs`: defaults, overlaid with `spokenrectifier.toml`, then
/// `spokenrectifier.local.toml` (which wins). Missing files are fine;
/// malformed ones are an error naming the file.
pub fn engine_config(dirs: &[PathBuf]) -> anyhow::Result<EngineConfig> {
    let mut config = EngineConfig::default();
    let layers =
        load_section_layers::<EngineSection>(dirs, "engine").map_err(|err| anyhow!("{}", err.0))?;
    for layer in layers {
        if let Some(v) = layer.value.passage_mode {
            config.passage_mode = v;
        }
        if let Some(v) = layer.value.paragraph_silence_ms {
            config.paragraph_silence_ms = v;
        }
        if let Some(v) = layer.value.session_end_silence_ms {
            config.session_end_silence_ms = v;
        }
        if let Some(v) = layer.value.rectify_timeout_ms {
            config.rectify_timeout_ms = v;
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

        let config = engine_config(std::slice::from_ref(&dir)).unwrap();
        assert!(config.paragraph_silence_ms == 2000); // shared file
        assert!(!config.passage_mode); // local wins over the default
        assert_eq!(config.session_end_silence_ms, 1500); // local file
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn missing_or_empty_files_leave_defaults() {
        let dir = std::env::temp_dir().join("sr-bridge-engine-config-empty");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("spokenrectifier.toml"), "").unwrap();

        assert_eq!(
            engine_config(std::slice::from_ref(&dir)).unwrap(),
            EngineConfig::default()
        );
        assert_eq!(engine_config(&[]).unwrap(), EngineConfig::default());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
