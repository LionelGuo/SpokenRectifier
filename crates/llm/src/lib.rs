//! Rectify pipeline (glossary: 修正): everything between the engine's
//! [`RectifyLlm`] seam and a real endpoint on one of the three wire
//! formats (ADR-0019).
//!
//! - [`select_intensity`] picks light-touch vs full rectify by utterance
//!   length — a prompt-level choice only; the configured model serves both.
//! - [`compose_prompt`] renders the fidelity rule, the five transforms, and
//!   the intensity/style/term directives; a quick-mode request (ADR-0020)
//!   takes the light-touch section with the quick extra directive in the
//!   light-touch one's place, and never thinks.
//! - [`live_llm`] builds the production client from a loaded config:
//!   format picks the SSE dialect (openai_chat, anthropic, gemini).
//!   [`live_llm_with_reasoning_counter`] is the eval observation hook.

mod anthropic;
mod assembly;
mod client;
mod config;
pub mod format;
mod gemini;
mod intensity;
pub mod presets;
mod prompt;
mod vendor;

pub use client::{OpenAiCompatLlm, live_llm, live_llm_with_reasoning_counter};
pub use config::{
    ConfigError, ConnectionThinking, CustomConnectionEdit, CustomSlot, LightTouchConfig,
    LightTouchEdit, LlmConfig, LlmConnectionEdit, ModelConfig, Overlays, QuickConfig, QuickEdit,
    RectifyBehaviorEdit, RectifyConfig, RectifyTier, ThinkingPolicy, ThinkingState, TierEdit,
    load_llm_config, save_llm_connection, save_rectify_behavior,
};
pub use format::Format;
pub use intensity::{Intensity, select_intensity};
pub use prompt::{ChatPrompt, compose_prompt, compose_prompt_with_extra};
pub use vendor::Vendor;
