//! Rectify pipeline (glossary: 修正): everything between the engine's
//! [`RectifyLlm`] seam and a real OpenAI-compatible endpoint.
//!
//! - [`select_intensity`] picks light-touch vs full rectify by utterance
//!   length — a prompt-level choice only; the configured model serves both.
//! - [`compose_prompt`] renders the fidelity rule, the five transforms, and
//!   the intensity/style/term directives.
//! - [`OpenAiCompatLlm`] streams token deltas from any OpenAI-compatible
//!   `/chat/completions` endpoint (DeepSeek, Volcengine Ark, DashScope, ...),
//!   with thinking mode on by default.

mod client;
mod config;
mod intensity;
mod prompt;
mod vendor;

pub use client::OpenAiCompatLlm;
pub use config::{
    ConfigError, LightTouchConfig, LightTouchEdit, LlmConfig, LlmConnectionEdit, ModelConfig,
    RectifyBehaviorEdit, RectifyConfig, RectifyTier, ThinkingPolicy, TierEdit, load_llm_config,
    save_llm_connection, save_rectify_behavior,
};
pub use intensity::{Intensity, select_intensity};
pub use prompt::{ChatPrompt, compose_prompt, compose_prompt_with_extra};
pub use vendor::Vendor;
