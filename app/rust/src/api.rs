//! Bridge API surface exposed to Dart via flutter_rust_bridge.
//!
//! All functions are synchronous and quick: commands block on the owned
//! runtime, the event stream forwards from a spawned task. The `Bridge*`
//! types are the wire format mirrored to Dart — deliberately decoupled
//! from the engine's own types so the engine can evolve without breaking
//! the Dart side.
//!
//! Two engine flavors: `create_engine` wires the real default microphone
//! with, when the `[asr]` config carries credentials, the configured
//! provider's cloud adapter streaming real transcripts — Aliyun or
//! Volcengine per `[asr]` provider (ADR-0009; otherwise the mic+VAD
//! provider's session semantics alone) — the real rectify LLM when
//! `[llm]` yields a key (a scripted cycling demo LLM otherwise, but
//! never under real ASR credentials — see `engine_factory`), the
//! production inserter (clipboard paste or typing at the remembered
//! target window), and the SQLite session history (per the `[history]`
//! config), while `create_fake_engine` keeps the all-fake setup
//! (scripted speech via `fake_say` / `fake_silence`, history disabled)
//! for tests and headless demos.

//! The surface is one file per domain under `api/`: the engine core and
//! event stream, the demo seam, the shared bridge state, and one file per
//! settings pane (library, history, connection, rectify, advanced, about,
//! eval). `rust_input: crate::api` prefix-matches every submodule, so the
//! bridge mirrors each domain under `lib/src/rust/api/<domain>.dart`; the
//! re-exports below keep `crate::api::<item>` paths working crate-wide.
//! The domain modules are `pub(crate)` because the generated
//! `frb_generated.rs` calls through them (`crate::api::<domain>::<fn>`).

pub(crate) mod about;
pub(crate) mod advanced;
pub(crate) mod connection;
pub(crate) mod demo;
pub(crate) mod engine;
pub(crate) mod eval;
pub(crate) mod history;
pub(crate) mod library;
pub(crate) mod rectify;
pub(crate) mod state;

pub use about::*;
pub use advanced::*;
pub use connection::*;
pub use demo::*;
pub use engine::*;
pub use eval::*;
pub use history::*;
pub use library::*;
pub use rectify::*;

#[cfg(test)]
mod tests;
