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
    rectify_timeout_ms: Option<u64>,
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
            if let Some(v) = engine.rectify_timeout_ms {
                config.rectify_timeout_ms = v;
            }
        }
    }
    Ok(config)
}

/// The first directory in `dirs` holding either config file, if any. Pure
/// so the search order is testable.
fn pick_config_dir<'a>(dirs: &[&'a Path]) -> Option<&'a Path> {
    dirs.iter()
        .copied()
        .find(|dir| CONFIG_FILE_NAMES.iter().any(|name| dir.join(name).exists()))
}

const CONFIG_FILE_NAMES: [&str; 2] = ["spokenrectifier.toml", "spokenrectifier.local.toml"];

/// The first directory that has either config file — the working
/// directory first (dev runs and CLI parity), then the executable's
/// directory (a double-clicked portable exe has an arbitrary cwd). Every
/// config section loader ([`engine_config`], the `[asr]` loader) resolves
/// this same directory.
pub fn config_dir() -> anyhow::Result<Option<std::path::PathBuf>> {
    let cwd = std::env::current_dir()?;
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf));
    let candidates: Vec<&Path> = std::iter::once(cwd.as_path())
        .chain(exe_dir.as_deref())
        .collect();
    Ok(pick_config_dir(&candidates).map(Path::to_path_buf))
}

/// Load the session semantics for the app from [`config_dir`]; no file
/// anywhere means defaults.
pub fn engine_config() -> anyhow::Result<EngineConfig> {
    match config_dir()? {
        Some(dir) => engine_config_from_dir(&dir),
        None => Ok(EngineConfig::default()),
    }
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

    #[test]
    fn first_dir_with_a_config_file_wins_and_none_means_default() {
        let with_files = std::env::temp_dir().join("sr-bridge-engine-config-pick-a");
        let also_files = std::env::temp_dir().join("sr-bridge-engine-config-pick-b");
        let empty = std::env::temp_dir().join("sr-bridge-engine-config-pick-empty");
        for dir in [&with_files, &also_files, &empty] {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::write(
            also_files.join("spokenrectifier.local.toml"),
            "[engine]\npassage_mode = false\n",
        )
        .unwrap();

        // The earlier directory wins when it holds a file; a file-less
        // prefix is skipped.
        let picked = pick_config_dir(&[&empty, &also_files, &with_files]).unwrap();
        assert_eq!(picked, also_files);
        // Nothing anywhere: no directory is picked.
        assert_eq!(pick_config_dir(&[&empty]), None);
        std::fs::remove_dir_all(&with_files).unwrap();
        std::fs::remove_dir_all(&also_files).unwrap();
        std::fs::remove_dir_all(&empty).unwrap();
    }
}
