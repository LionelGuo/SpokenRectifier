//! LLM configuration: defaults from the v1 model matrix, overridable per
//! field from the layered config files (loading rules live in the config
//! crate; an `api_key` may only come from the git-ignored local layer).
//!
//! One model per mode: every intensity (light-touch or full) calls the same
//! endpoint — the length threshold only changes how the prompt asks the
//! model to rectify, never which model answers.
//!
//! The connection face is open (ADR-0019): `[llm] format` is the one
//! behavioral axis, the 「设置思考字段」 switch plus the three
//! `[llm.overlays]` shares own the request body's variable part, and the
//! pre-0019 keys (thinking dialect, the two extra-body cabins) survive
//! only as a read-time grandfather that the first connection-domain
//! save retires — the ratchet.
//!
//! Three submodules, one responsibility each: [`shape`] (the folded
//! types and their defaults), [`load`] (the layered read plus the
//! grandfather/ratchet migrations), and [`save`] (the settings editors'
//! write paths). This module re-exports their public surface unchanged.

mod load;
mod save;
mod shape;

#[cfg(test)]
mod testutil;

pub use load::load_llm_config;
pub use save::{
    LightTouchEdit, LlmConnectionEdit, QuickEdit, RectifyBehaviorEdit, TierEdit,
    save_llm_connection, save_rectify_behavior,
};
pub use shape::{
    ConfigError, ConnectionThinking, CustomSlot, LightTouchConfig, LlmConfig, ModelConfig,
    Overlays, QuickConfig, RectifyConfig, RectifyTier, ThinkingPolicy, ThinkingState,
};
