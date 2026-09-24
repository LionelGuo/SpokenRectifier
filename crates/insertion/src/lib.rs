//! Real text insertion for SpokenRectifier (glossary: 预览窗 → 目标输入框).
//!
//! [`TargetInserter`] implements the engine's `TextInserter` seam: it
//! puts the text on the clipboard and pastes (the text stays there — the
//! newest history entry, and a manual Ctrl+V fallback when a paste
//! fails) or types the text key by key, into the window the user last
//! focused (the current foreign foreground, falling back to the target
//! remembered when the session started). All platform behavior lives
//! behind the [`InputOs`] trait, so the flows are deterministic under a
//! recording fake; the Win32 layer is `cfg(windows)`.

mod config;
mod diag;
mod inserter;
mod os;
#[cfg(windows)]
mod windows;

pub use config::{
    InsertionConfig, InsertionConfigError, InsertionMode, load_insertion_config,
    save_insertion_timing,
};
pub use diag::DiagLog;
pub use inserter::TargetInserter;
pub use os::{InjectedKey, InputOs, paced_paste_script};
