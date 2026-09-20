//! SpokenRectifier's local business store (glossary: 场景库, 术语词表,
//! 历史与取回, 占位符): one SQLite database holding the four entities —
//! scenarios, hotword terms, inserted sessions, placeholders — behind the
//! full guard set: unique constraints, blank-rejecting checks, three
//! foreign keys (scenario SET NULL, source session SET NULL,
//! placeholder CASCADE), one BEFORE INSERT trigger the checks cannot
//! express (an all-whitespace session), and the sessions⋈scenarios view.
//!
//! Opening the store is also the one-time migration: when the legacy
//! file trio (history db, terms txt, scenarios toml) is still around,
//! a single verified transaction copies them in and deletes the files;
//! `PRAGMA user_version` is the only-run-once gate, and a failure leaves
//! the legacy files untouched for the next launch to retry.
//!
//! The engine hands finished sessions over through its
//! [`SessionRecorder`] port; this crate's [`Store`] is that port's
//! adapter plus the query surface the app's panels read. Text only —
//! audio never reaches this crate, and keys never enter this database
//! (they stay in the local config layer).

mod migration;
mod schema;

pub mod config;
pub mod scenarios;
pub mod store;
pub mod terms;

pub use config::{HistoryConfig, HistoryConfigError, load_history_config, save_history_config};
pub use scenarios::{Scenario, ScenarioInput};
pub use store::{
    HistoryEntry, NowMs, STORE_DB_FILE, Store, StoreError, resolve_store_path, wall_clock,
};
pub use terms::peek_terms;
