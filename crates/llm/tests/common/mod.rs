#![allow(dead_code)]
//! Shared helpers for the llm crate's integration tests.

use spokenrectifier_engine::Style;
use spokenrectifier_engine::provider::llm::RectifyRequest;
use spokenrectifier_llm::{LlmConfig, ModelConfig, OpenAiCompatLlm, Vendor};

/// An `LlmConfig` pointing at one fake endpoint/model.
pub fn config_with_base(base_url: String, thinking: bool) -> LlmConfig {
    LlmConfig {
        thinking,
        light_touch_max_chars: 40,
        model: ModelConfig {
            base_url,
            model: "test-model".into(),
            api_key: Some("sk-test".into()),
            api_key_env: None,
            vendor: Vendor::DeepSeek,
            extra_body: None,
        },
    }
}

/// A client wired to a mock server.
pub fn mock_backed_llm(config: LlmConfig) -> OpenAiCompatLlm {
    OpenAiCompatLlm::new(config).expect("client builds")
}

/// A one-paragraph request of the given text.
pub fn request(text: &str) -> RectifyRequest {
    RectifyRequest {
        raw_transcript: text.into(),
        paragraphs: vec![text.into()],
        style: Style::GeneralWritten,
        terms: vec![],
    }
}

/// A request at or above the 40-char threshold (full rectify).
pub fn long_request() -> RectifyRequest {
    request(&"字".repeat(40))
}
