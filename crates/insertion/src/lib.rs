//! Real text insertion for SpokenRectifier (glossary: 预览窗 → 目标输入框).
//!
//! [`TargetInserter`] implements the engine's `TextInserter` seam: it
//! borrows the clipboard (save → replace → Ctrl+V → restore) or types the
//! text key by key, at a target window remembered when the session
//! started. All platform behavior lives behind the [`InputOs`] trait, so
//! the flows are deterministic under a recording fake; the Win32 layer is
//! `cfg(windows)`.

mod config;
mod inserter;
mod os;
#[cfg(windows)]
mod windows;

pub use config::{InsertionConfig, InsertionConfigError, InsertionMode, load_insertion_config};
pub use inserter::TargetInserter;
pub use os::{InputOs, SavedClipboard};
