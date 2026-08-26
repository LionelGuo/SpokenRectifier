//! SpokenRectifier session history: local-only persistence of every
//! inserted session's raw transcript and rectified text, with layered
//! `[history]` config, a lazy retention sweep, and one-call clear.
//!
//! The engine hands finished sessions over through its
//! [`SessionRecorder`] port; this crate is that port's adapter plus the
//! query surface the app's history panel reads. Text only — audio never
//! reaches this crate, or any disk.

pub mod config;
pub mod store;

pub use config::{HistoryConfig, HistoryConfigError, load_history_config};
pub use store::{
    HistoryEntry, HistoryError, HistoryStore, NowMs, SqliteHistory, resolve_db_path, wall_clock,
};
