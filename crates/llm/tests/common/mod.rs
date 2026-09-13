#![allow(dead_code)]
//! Shared helpers for the llm crate's integration tests.

use spokenrectifier_engine::provider::llm::RectifyRequest;
use spokenrectifier_llm::{LlmConfig, ModelConfig, OpenAiCompatLlm, ThinkingPolicy, Vendor};

/// An `LlmConfig` pointing at one fake endpoint/model. `thinking` seeds
/// BOTH tiers' policy the way today's legacy bool did (the tests never
/// need a per-tier split — the client-level fold has its own unit
/// tests).
pub fn config_with_base(base_url: String, thinking: bool) -> LlmConfig {
    let mut config = LlmConfig::defaults();
    let policy = if thinking {
        ThinkingPolicy::Always
    } else {
        ThinkingPolicy::Off
    };
    config.rectify.full.thinking_policy = policy;
    config.rectify.light_touch.tier.thinking_policy = policy;
    config.endpoint_configured = true;
    config.model = ModelConfig {
        base_url,
        model: "test-model".into(),
        api_key: Some("sk-test".into()),
        api_key_env: None,
        vendor: Vendor::DeepSeek,
        extra_body: None,
    };
    config
}

/// A client wired to a mock server.
pub fn mock_backed_llm(config: LlmConfig) -> OpenAiCompatLlm {
    OpenAiCompatLlm::new(config).expect("client builds")
}

/// A one-paragraph request of the given text on the default register.
pub fn request(text: &str) -> RectifyRequest {
    RectifyRequest {
        raw_transcript: text.into(),
        paragraphs: vec![text.into()],
        style_directive: None,
        global_directive: None,
        terms: vec![],
        prefill: true,
    }
}

/// A request at or above the 40-char threshold (full rectify).
pub fn long_request() -> RectifyRequest {
    request(&"字".repeat(40))
}
