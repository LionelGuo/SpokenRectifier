//! Which OpenAI-compatible vendor an endpoint speaks, and how each one
//! toggles thinking mode. On by default (工单 33): under the zero-example
//! prompt, placeholder absorption needs it — v4-flash probed 10/10 with,
//! 3/10 without; off only buys back light-band latency.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The dialect quirks of a compatible endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
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
    /// Every vendor, in declaration order — keying the per-vendor key
    /// slots (ADR-0011).
    pub const ALL: [Vendor; 4] = [
        Vendor::DeepSeek,
        Vendor::Volcengine,
        Vendor::Qwen,
        Vendor::OpenAi,
    ];
}

impl Vendor {
    /// The file/wire name — serde's lowercase form, spelled out for the
    /// settings editor's section writes.
    pub fn as_str(self) -> &'static str {
        match self {
            Vendor::DeepSeek => "deepseek",
            Vendor::Volcengine => "volcengine",
            Vendor::Qwen => "qwen",
            Vendor::OpenAi => "openai",
        }
    }

    /// Parse the file/wire name (the settings editor's dropdown sends
    /// one of these); unknown names are `None` for the caller to refuse.
    pub fn from_str_name(name: &str) -> Option<Self> {
        match name.trim() {
            "deepseek" => Some(Vendor::DeepSeek),
            "volcengine" => Some(Vendor::Volcengine),
            "qwen" => Some(Vendor::Qwen),
            "openai" => Some(Vendor::OpenAi),
            _ => None,
        }
    }

    /// The conventional environment variable this vendor's key falls
    /// back to when no local-file key exists (each vendor keeps its own
    /// slot, so each names its own variable, ADR-0011).
    pub fn default_env(self) -> &'static str {
        match self {
            Vendor::DeepSeek => "DEEPSEEK_API_KEY",
            Vendor::Volcengine => "ARK_API_KEY",
            Vendor::Qwen => "DASHSCOPE_API_KEY",
            Vendor::OpenAi => "OPENAI_API_KEY",
        }
    }

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
    fn the_spelled_names_match_serde_lowercase() {
        for (vendor, name) in [
            (Vendor::DeepSeek, "deepseek"),
            (Vendor::Volcengine, "volcengine"),
            (Vendor::Qwen, "qwen"),
            (Vendor::OpenAi, "openai"),
        ] {
            assert_eq!(vendor.as_str(), name);
            // What a save writes must be what a load reads back.
            assert_eq!(
                serde_json::from_str::<Vendor>(format!("\"{name}\"").as_str()).unwrap(),
                vendor
            );
            assert_eq!(Vendor::from_str_name(name), Some(vendor));
        }
        assert_eq!(Vendor::from_str_name("nonsense"), None);
    }

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
