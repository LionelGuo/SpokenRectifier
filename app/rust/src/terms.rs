//! Hotword-dictionary wiring for the app: the file-backed [`TermSource`].
//!
//! Lives outside `api.rs` so flutter_rust_bridge's codegen (which mirrors
//! everything in the api module) does not pick the adapter internals up
//! as part of the Dart-facing surface. The loader rules live in the
//! config crate; this module only adapts.

use std::path::PathBuf;
use std::sync::Arc;

use spokenrectifier_config::terms::load_terms;
use spokenrectifier_engine::TermSource;

/// The dictionary read fresh from the layer files' directories on every
/// call, so an edit takes effect on the next session without a restart.
pub struct FileTermSource {
    dirs: Vec<PathBuf>,
}

impl FileTermSource {
    /// An `Arc` because the engine takes it as an injectable collaborator,
    /// the same shape as every other `EngineDeps` member.
    pub fn new(dirs: Vec<PathBuf>) -> Arc<Self> {
        Arc::new(Self { dirs })
    }
}

impl TermSource for FileTermSource {
    fn terms(&self) -> Vec<String> {
        load_terms(&self.dirs)
    }
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
    fn edits_take_effect_on_the_next_read() {
        let dir = scratch("sr-app-terms");
        let source = FileTermSource::new(vec![dir.clone()]);
        std::fs::write(dir.join("spokenrectifier-terms.txt"), "旧术语\n").unwrap();
        assert_eq!(source.terms(), vec!["旧术语".to_string()]);

        std::fs::write(dir.join("spokenrectifier-terms.txt"), "新术语\n").unwrap();
        assert_eq!(source.terms(), vec!["新术语".to_string()]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn no_file_anywhere_is_no_terms() {
        let dir = scratch("sr-app-terms-absent");
        let source = FileTermSource::new(vec![dir.clone()]);
        assert!(source.terms().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
