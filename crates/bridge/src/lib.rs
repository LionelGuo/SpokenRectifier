//! The flutter_rust_bridge seam between the Flutter shell and the engine.
//!
//! The shell calls these plain functions from Dart: `create_fake_engine`
//! once at startup, then `execute` for commands and `subscribe` for the
//! event stream. Everything is synchronous from Dart's perspective; the
//! engine's async machinery runs on an owned tokio runtime here.
//!
//! The engine is built with all-fake collaborators (scripted ASR fed by
//! `fake_say` / `fake_silence`, scripted LLM responses passed to
//! `create_fake_engine`, recording inserter) — the shell drives the whole
//! interaction with no microphone, network, or target window.

mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */

mod api;

pub use api::*;
