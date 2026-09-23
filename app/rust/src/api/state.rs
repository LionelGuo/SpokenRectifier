//! The bridge's process-wide state: the owned runtime, the engine, the
//! speech source, and the inserter slot — shared by every domain file.

use std::sync::{Arc, Mutex, OnceLock};

use anyhow::anyhow;
use tokio::runtime::Runtime;

use spokenrectifier_engine::fakes::{AsrFeed, ChannelScripter, FakeInserter};
use spokenrectifier_engine::Engine;
use spokenrectifier_store::Store;

/// Where speech comes from for the current engine.
pub(crate) enum SpeechSource {
    /// Scripted speech through `fake_say` / `fake_silence`.
    Fake {
        scripter: ChannelScripter,
        feed: Mutex<Option<AsrFeed>>,
    },
    /// The real default microphone, through capture + VAD.
    Mic,
}

pub(crate) struct Global {
    pub(crate) rt: Runtime,
    pub(crate) engine: Engine,
    pub(crate) source: SpeechSource,
    pub(crate) inserter: InserterSlot,
    /// The business store: what the panels list and the editors write —
    /// scenarios, terms, sessions. Ephemeral (in-memory) on the fake
    /// engine, so tests and headless demos keep no files.
    pub(crate) store: Arc<Store>,
}

/// The real engine's inserter: the production one remembers the target
/// window (the fake engine's needs no target).
pub(crate) enum InserterSlot {
    /// Demo introspection: everything the fake inserter received.
    Fake(Arc<FakeInserter>),
    /// Real insertion at the remembered target window.
    Real(Arc<spokenrectifier_insertion::TargetInserter>),
}

pub(crate) static GLOBAL: OnceLock<Global> = OnceLock::new();

pub(crate) fn global() -> anyhow::Result<&'static Global> {
    GLOBAL.get().ok_or_else(|| {
        anyhow!("engine not created yet; call create_engine or create_fake_engine first")
    })
}
