#![allow(dead_code)]
//! Shared helpers for the llm crate's integration tests.

use spokenrectifier_engine::provider::llm::RectifyRequest;
use spokenrectifier_llm::{
    ConnectionThinking, Format, LlmConfig, ModelConfig, OpenAiCompatLlm, Overlays, ThinkingPolicy,
    ThinkingState, Vendor,
};

/// An `LlmConfig` pointing at one fake endpoint/model. `thinking` seeds
/// BOTH tiers' policy the way today's legacy bool did (the tests never
/// need a per-tier split — the client-level fold has its own unit
/// tests). The connection face carries the grandfathered deepseek
/// shares, so requests look exactly like the pre-0019 body.
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
    let (thinking_on, thinking_off) = spokenrectifier_llm::presets::legacy_shares(Vendor::DeepSeek);
    config.model = ModelConfig {
        base_url,
        model: "test-model".into(),
        api_key: Some("sk-test".into()),
        api_key_env: None,
        vendor: Vendor::DeepSeek,
        format: Format::OpenaiChat,
        thinking: ConnectionThinking {
            state: ThinkingState::On,
            overlays: Overlays {
                body: None,
                thinking_on: Some(thinking_on),
                thinking_off: Some(thinking_off),
            },
        },
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
        quick: false,
    }
}

/// The quick-mode twin of [`request`] (ADR-0020): the same utterance
/// asked for as a held-hotkey pass-through.
pub fn quick_request(text: &str) -> RectifyRequest {
    RectifyRequest {
        quick: true,
        ..request(text)
    }
}

/// A request at or above the 40-char threshold (full rectify).
pub fn long_request() -> RectifyRequest {
    request(&"字".repeat(40))
}
