//! The advanced domain (高级, ticket 19): the `[engine]` and
//! `[insertion]` latency parameters the pane paints and saves.

use anyhow::anyhow;

use super::engine::{execute, BridgeCommand};
use super::state::{global, InserterSlot};
use crate::engine_config::engine_config;

/// The effective `[engine]` timings as the advanced pane paints them
/// (read-only; see ADR-0007 for why they stay file-only).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BridgeEngineTiming {
    pub passage_mode: bool,
    pub paragraph_silence_ms: u64,
    pub session_end_silence_ms: u64,
    pub rectify_timeout_ms: u64,
}

/// The effective `[insertion]` timings as the advanced pane paints them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeInsertionTiming {
    /// `paste` or `typing`.
    pub mode: String,
    pub focus_settle_ms: u64,
    pub paste_settle_ms: u64,
    pub typing_delay_ms: u64,
}

/// The advanced domain's one read: the session and insertion latency
/// parameters, effective right now (the editable form's initial paint).
pub fn advanced_config() -> anyhow::Result<BridgeAdvancedConfig> {
    let dirs = spokenrectifier_config::search_dirs();
    let engine = engine_config(&dirs)?;
    let insertion = spokenrectifier_insertion::load_insertion_config(&dirs)
        .map_err(|err| anyhow!("insertion {}", err.0))?;
    Ok(BridgeAdvancedConfig {
        engine: BridgeEngineTiming {
            passage_mode: engine.passage_mode,
            paragraph_silence_ms: engine.paragraph_silence_ms,
            session_end_silence_ms: engine.session_end_silence_ms,
            rectify_timeout_ms: engine.rectify_timeout_ms,
        },
        insertion: BridgeInsertionTiming {
            mode: insertion.mode.as_str().to_string(),
            focus_settle_ms: insertion.focus_settle_ms,
            paste_settle_ms: insertion.paste_settle_ms,
            typing_delay_ms: insertion.typing_delay_ms,
        },
    })
}

/// Write the form's `[engine]` model (passage mode + the three timings)
/// into the layer files and hand it to the live engine at once
/// (ADR-0007, revised): both runtime commands adopt the saved values
/// immediately, and each session snapshots what it opens with — so the
/// save applies from the NEXT session on, while the file stays the
/// truth across launches. The quick panel's passage toggle stays the
/// runtime-only quick switch; this one persists. Returns the re-read
/// view.
pub fn set_engine_settings(
    passage_mode: bool,
    paragraph_silence_ms: u64,
    session_end_silence_ms: u64,
    rectify_timeout_ms: u64,
) -> anyhow::Result<BridgeEngineTiming> {
    let dirs = spokenrectifier_config::search_dirs();
    let engine = crate::engine_config::save_engine_settings(
        &dirs,
        passage_mode,
        spokenrectifier_engine::EngineTimings {
            paragraph_silence_ms,
            session_end_silence_ms,
            rectify_timeout_ms,
        },
    )?;
    execute(BridgeCommand::SetPassageMode {
        on: engine.passage_mode,
    })?;
    execute(BridgeCommand::SetEngineTimings {
        paragraph_silence_ms: engine.paragraph_silence_ms,
        session_end_silence_ms: engine.session_end_silence_ms,
        rectify_timeout_ms: engine.rectify_timeout_ms,
    })?;
    Ok(BridgeEngineTiming {
        passage_mode: engine.passage_mode,
        paragraph_silence_ms: engine.paragraph_silence_ms,
        session_end_silence_ms: engine.session_end_silence_ms,
        rectify_timeout_ms: engine.rectify_timeout_ms,
    })
}

/// Write the form's `[insertion]` model into the layer files and apply
/// it to the live inserter at once (ADR-0007, 2026-08-28 revision):
/// insertion is discrete per-confirm, so the swap is true real-time —
/// the very next ConfirmInsert runs with the new mode and pacing. A
/// no-op apply on the fake engine (tests and demos hold no target
/// window); the file write still lands. Returns the re-read view.
pub fn set_insertion_timing(
    mode: String,
    focus_settle_ms: u64,
    paste_settle_ms: u64,
    typing_delay_ms: u64,
) -> anyhow::Result<BridgeInsertionTiming> {
    let mode = spokenrectifier_insertion::InsertionMode::from_name(&mode).ok_or_else(|| {
        anyhow!("[insertion] mode \"{mode}\" is unknown: pick \"paste\" or \"typing\"")
    })?;
    let config = spokenrectifier_insertion::InsertionConfig {
        mode,
        focus_settle_ms,
        paste_settle_ms,
        typing_delay_ms,
    };
    let dirs = spokenrectifier_config::search_dirs();
    spokenrectifier_insertion::save_insertion_timing(&dirs, &config)
        .map_err(|err| anyhow!("insertion {}", err.0))?;
    if let InserterSlot::Real(inserter) = &global()?.inserter {
        inserter.set_config(config);
    }
    Ok(BridgeInsertionTiming {
        mode: mode.as_str().to_string(),
        focus_settle_ms: config.focus_settle_ms,
        paste_settle_ms: config.paste_settle_ms,
        typing_delay_ms: config.typing_delay_ms,
    })
}

/// Both timing cards in one read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAdvancedConfig {
    pub engine: BridgeEngineTiming,
    pub insertion: BridgeInsertionTiming,
}
