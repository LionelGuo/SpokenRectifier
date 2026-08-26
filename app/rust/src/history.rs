//! `[history]` wiring for the app: load the section, open the store.
//!
//! Lives outside `api.rs` so flutter_rust_bridge's codegen (which mirrors
//! everything in the api module) does not pick the loading internals up
//! as part of the Dart-facing surface. The rules live in the history
//! crate; this module only assembles.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::anyhow;
use spokenrectifier_history::{load_history_config, wall_clock, HistoryStore};

/// Open the session-history store from the layer files' directories:
/// `[history]` config folded per the layered rules, the SQLite database
/// at the first writable location, expired rows swept. Nowhere writable
/// degrades to the keep-nothing store — history is a convenience and
/// never blocks startup over a database location. (A malformed config
/// file still fails the caller, like every other section.)
pub fn open_history(dirs: &[PathBuf]) -> anyhow::Result<Arc<HistoryStore>> {
    let config = load_history_config(dirs).map_err(|err| anyhow!("history {}", err.0))?;
    let store = HistoryStore::open(dirs, config, wall_clock())
        .map_err(|err| anyhow!("history {}", err.0))?;
    Ok(Arc::new(store))
}
