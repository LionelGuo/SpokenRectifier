//! Rectify pipeline (glossary: 修正): everything between the engine's
//! [`RectifyLlm`] seam and a real OpenAI-compatible endpoint.
//!
//! - [`select_intensity`] picks light-touch vs full rectify by utterance
//!   length, which also routes the request to the fast or standard model.
//! - [`compose_prompt`] renders the fidelity rule, the five transforms, and
//!   the intensity/style/term directives.
//! - [`OpenAiCompatLlm`] streams token deltas from any OpenAI-compatible
//!   `/chat/completions` endpoint (DeepSeek, Volcengine Ark, DashScope, ...),
//!   with thinking mode off by default.

mod client;
mod config;
mod intensity;
mod prompt;
mod vendor;

pub use client::OpenAiCompatLlm;
pub use config::{ConfigError, LlmConfig, ModelConfig, load_llm_config};
pub use intensity::{Intensity, select_intensity};
pub use prompt::{ChatPrompt, compose_prompt};
pub use vendor::{Vendor, thinking_field};
