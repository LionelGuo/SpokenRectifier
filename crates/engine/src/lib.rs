//! SpokenRectifier engine — the single test seam.
//!
//! Commands go in via [`Engine::execute`], events come out via
//! [`Engine::subscribe`]. Every I/O collaborator (ASR, rectify LLM, text
//! inserter, history recorder, hotword dictionary source, clock) is an
//! injectable trait, so the whole deterministic test suite and the
//! `sr-replay` CLI driver run without network or audio devices. Glossary
//! terms live in the repository `CONTEXT.md`.

pub mod clock;
pub mod command;
pub mod config;
pub mod engine;
pub mod event;
pub mod fakes;
pub mod provider;

pub mod style;

pub use clock::{Clock, TokioClock};
pub use command::Command;
pub use config::EngineConfig;
pub use engine::{Engine, EngineDeps, EngineError};
pub use event::{EngineEvent, EventEnvelope, SessionId, SessionState};
pub use provider::asr::{AsrEvent, AsrOpenError, AsrProvider};
pub use provider::history::{RecordedSession, SessionRecorder};
pub use provider::inserter::{InsertError, TextInserter};
pub use provider::llm::{RectifyError, RectifyLlm, RectifyRequest};
pub use provider::terms::TermSource;
pub use style::Style;
