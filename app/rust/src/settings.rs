//! The tray's settings entry: which config file to open, and what to
//! create when none exists yet.
//!
//! Lives outside `api.rs` so flutter_rust_bridge's codegen (which mirrors
//! everything in the api module) does not pick these helpers up as part
//! of the Dart-facing surface.

use std::path::PathBuf;

use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

/// What a freshly created config stub says. Minimal on purpose: the full
/// schema lives in `spokenrectifier.example.toml` next to the source.
const STUB: &str = "\
# SpokenRectifier configuration. Every field is optional; the built-in
# defaults apply. The full schema (with explanations) is
# spokenrectifier.example.toml in the source repository.
# API keys never go in this file: put api_key under the matching section
# in spokenrectifier.local.toml instead (this file may be committed).

[engine]
# style = \"general-written\"   # general-written | prompt | formal-document

[llm]
# model = \"deepseek-v4-flash\"
";

/// The shared config file the settings entry opens: the first one the
/// layer search would load, or — when no shared file exists anywhere — a
/// commented stub, created where settings already live (beside the local
/// layer file if one exists, else beside the executable, whose directory
/// is a portable app's stable home; a double-clicked app's working
/// directory is arbitrary).
pub fn ensure_shared_config(dirs: &[PathBuf]) -> std::io::Result<PathBuf> {
    if let Some(found) = spokenrectifier_config::find_file(dirs, SHARED_FILE) {
        return Ok(found);
    }
    let home = spokenrectifier_config::find_file(dirs, LOCAL_FILE)
        .and_then(|local| local.parent().map(|dir| dir.to_path_buf()))
        .or_else(|| dirs.last().cloned())
        .unwrap_or_else(|| PathBuf::from("."));
    let path = home.join(SHARED_FILE);
    if !path.exists() {
        std::fs::write(&path, STUB)?;
    }
    Ok(path)
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
    fn the_existing_shared_file_opens_where_it_lives() {
        let empty = scratch("sr-settings-found-empty");
        let with_file = scratch("sr-settings-found-file");
        std::fs::write(with_file.join(SHARED_FILE), "[engine]\n").unwrap();

        let path = ensure_shared_config(&[empty.clone(), with_file.clone()]).unwrap();
        assert_eq!(path, with_file.join(SHARED_FILE));
        // Nothing was created in the empty directory.
        assert!(std::fs::read_dir(&empty).unwrap().next().is_none());
        std::fs::remove_dir_all(empty).unwrap();
        std::fs::remove_dir_all(with_file).unwrap();
    }

    #[test]
    fn no_shared_file_creates_the_stub_beside_the_local_file() {
        let cwd = scratch("sr-settings-local-cwd");
        let exe = scratch("sr-settings-local-exe");
        std::fs::write(exe.join(LOCAL_FILE), "[llm]\napi_key = \"sk\"\n").unwrap();

        let path = ensure_shared_config(&[cwd.clone(), exe.clone()]).unwrap();
        assert_eq!(path, exe.join(SHARED_FILE));
        let stub = std::fs::read_to_string(&path).unwrap();
        assert!(stub.contains("spokenrectifier.example.toml"), "got: {stub}");
        assert!(stub.contains("local.toml"), "got: {stub}");
        // The keys' directory, not the first search directory, got the file.
        assert!(!cwd.join(SHARED_FILE).exists());
        std::fs::remove_dir_all(cwd).unwrap();
        std::fs::remove_dir_all(exe).unwrap();
    }

    #[test]
    fn no_files_at_all_creates_the_stub_beside_the_exe() {
        let cwd = scratch("sr-settings-fresh-cwd");
        let exe = scratch("sr-settings-fresh-exe");

        let path = ensure_shared_config(&[cwd.clone(), exe.clone()]).unwrap();
        assert_eq!(path, exe.join(SHARED_FILE)); // the last dir, not the first
        assert!(path.is_file());
        std::fs::remove_dir_all(cwd).unwrap();
        std::fs::remove_dir_all(exe).unwrap();
    }

    #[test]
    fn an_early_call_does_not_overwrite_later_edits() {
        let dir = scratch("sr-settings-idempotent");
        let path = ensure_shared_config(std::slice::from_ref(&dir)).unwrap();
        std::fs::write(&path, "[engine]\nstyle = \"prompt\"\n").unwrap();

        let again = ensure_shared_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(again, path);
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "[engine]\nstyle = \"prompt\"\n"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
