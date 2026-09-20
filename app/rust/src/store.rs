//! Store wiring for the app: load the `[history]` section, open the
//! business store (whose one-time migration from the legacy file trio
//! rides along), and the database-backed dictionary source.
//!
//! Lives outside `api.rs` so flutter_rust_bridge's codegen (which mirrors
//! everything in the api module) does not pick the loading internals up
//! as part of the Dart-facing surface. The rules live in the store
//! crate; this module only assembles.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::anyhow;
use spokenrectifier_engine::TermSource;
use spokenrectifier_store::{load_history_config, wall_clock, Store};

/// Open the business store from the layer files' directories: `[history]`
/// config folded per the layered rules, the SQLite database at the first
/// writable location, the one-time legacy migration run, expired rows
/// swept. Nowhere writable — or a migration that fails, leaving the
/// legacy files for the next launch — degrades to an in-memory store
/// for the run: the store is a convenience and never blocks startup.
/// (A malformed config file still fails the caller, like every other
/// section.)
pub fn open_store(dirs: &[PathBuf]) -> anyhow::Result<Arc<Store>> {
    let config = load_history_config(dirs).map_err(|err| anyhow!("history {}", err.0))?;
    let store =
        Store::open(dirs, config, wall_clock()).map_err(|err| anyhow!("history {}", err.0))?;
    Ok(Arc::new(store))
}

/// The dictionary read fresh from the store on every call, so an edit
/// takes effect on the next session without a restart — the same
/// freshness the file it replaced had.
pub struct DbTermSource(Arc<Store>);

impl DbTermSource {
    /// An `Arc` because the engine takes it as an injectable
    /// collaborator, the same shape as every other `EngineDeps` member.
    pub fn new(store: Arc<Store>) -> Arc<Self> {
        Arc::new(Self(store))
    }
}

impl TermSource for DbTermSource {
    fn terms(&self) -> Vec<String> {
        self.0.list_terms()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use spokenrectifier_store::HistoryConfig;

    #[test]
    fn edits_take_effect_on_the_next_read() {
        let store = Store::open_memory(HistoryConfig::default(), wall_clock());
        let source = DbTermSource::new(Arc::new(store));
        assert!(source.terms().is_empty());
        source.0.append_term("新术语").unwrap();
        assert_eq!(source.terms(), vec!["新术语".to_string()]);
    }
}
