//! Rectify pipeline (glossary: 修正): everything between the engine's
//! [`RectifyLlm`] seam and a real endpoint on one of the three wire
//! formats (ADR-0019).
//!
//! - [`select_intensity`] picks light-touch vs full rectify by utterance
//!   length — a prompt-level choice only; the configured model serves both.
//! - [`compose_prompt`] renders the fidelity rule, the five transforms, and
//!   the intensity/style/term directives.
//! - [`live_llm`] builds the production client from a loaded config:
//!   format picks the implementation. Ticket 02 lands openai_chat;
//!   anthropic and gemini still construct that client so a rebuild
//!   already sends the right URL/headers/body (ticket 03 swaps the
//!   dialects).

mod assembly;
mod client;
mod config;
pub mod format;
mod intensity;
pub mod presets;
mod prompt;
mod vendor;

pub use client::{OpenAiCompatLlm, live_llm};
pub use config::{
    ConfigError, ConnectionThinking, CustomConnectionEdit, CustomSlot, LightTouchConfig,
    LightTouchEdit, LlmConfig, LlmConnectionEdit, ModelConfig, Overlays, RectifyBehaviorEdit,
    RectifyConfig, RectifyTier, ThinkingPolicy, ThinkingState, TierEdit, load_llm_config,
    save_llm_connection, save_rectify_behavior,
};
pub use format::Format;
pub use intensity::{Intensity, select_intensity};
pub use prompt::{ChatPrompt, compose_prompt, compose_prompt_with_extra};
pub use vendor::Vendor;
