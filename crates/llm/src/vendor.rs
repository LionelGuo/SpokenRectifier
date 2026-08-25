//! Which OpenAI-compatible vendor an endpoint speaks, and how each one
//! toggles thinking mode. Rewriting tasks want thinking off (latency and
//! over-rectify risk), so off is the default everywhere.

use serde::Deserialize;
use serde_json::{Value, json};

/// The dialect quirks of a compatible endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Vendor {
    /// api.deepseek.com: `thinking: {"type": ...}`; enabling also requires
    /// `reasoning_effort`.
    DeepSeek,
    /// Volcengine Ark: `thinking: {"type": ...}`.
    Volcengine,
    /// DashScope compatible mode: `enable_thinking: bool`.
    Qwen,
    /// Plain OpenAI shape; only `reasoning_effort` exists, so thinking-off
    /// sends no extra field.
    OpenAi,
}

impl Vendor {
    /// The fields to merge into the request body for the wanted thinking
    /// mode. Empty means: send nothing.
    pub fn thinking_fields(self, thinking: bool) -> Vec<(&'static str, Value)> {
        match (self, thinking) {
            (Vendor::DeepSeek, true) => vec![
                ("thinking", json!({"type": "enabled"})),
                ("reasoning_effort", json!("medium")),
            ],
            (Vendor::DeepSeek, false) => vec![("thinking", json!({"type": "disabled"}))],
            (Vendor::Volcengine, true) => vec![("thinking", json!({"type": "enabled"}))],
            (Vendor::Volcengine, false) => vec![("thinking", json!({"type": "disabled"}))],
            (Vendor::Qwen, true) => vec![("enable_thinking", json!(true))],
            (Vendor::Qwen, false) => vec![("enable_thinking", json!(false))],
            (Vendor::OpenAi, true) => vec![("reasoning_effort", json!("medium"))],
            (Vendor::OpenAi, false) => vec![],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deepseek_disabled_by_default_shape() {
        assert_eq!(
            Vendor::DeepSeek.thinking_fields(false),
            vec![("thinking", json!({"type": "disabled"}))]
        );
    }

    #[test]
    fn deepseek_enabled_requires_effort_pair() {
        let fields = Vendor::DeepSeek.thinking_fields(true);
        assert_eq!(
            fields,
            vec![
                ("thinking", json!({"type": "enabled"})),
                ("reasoning_effort", json!("medium")),
            ]
        );
    }

    #[test]
    fn volcengine_uses_type_object() {
        assert_eq!(
            Vendor::Volcengine.thinking_fields(false),
            vec![("thinking", json!({"type": "disabled"}))]
        );
    }

    #[test]
    fn qwen_uses_boolean_flag() {
        assert_eq!(
            Vendor::Qwen.thinking_fields(false),
            vec![("enable_thinking", json!(false))]
        );
        assert_eq!(
            Vendor::Qwen.thinking_fields(true),
            vec![("enable_thinking", json!(true))]
        );
    }

    #[test]
    fn openai_plain_sends_nothing_when_off() {
        assert!(Vendor::OpenAi.thinking_fields(false).is_empty());
    }
}
