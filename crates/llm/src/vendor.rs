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
    /// The user's own OpenAI-compatible endpoint (ADR-0018): no preset
    /// URL, no conventional environment variable, and no thinking-field
    /// shape of its own — the stored `thinking_dialect` picks one of the
    /// four above (default `openai`). A vendor value, not a dialect: the
    /// dialect parser excludes it.
    Custom,
}

impl Vendor {
    /// Every vendor, in declaration order — keying the per-vendor key
    /// slots (ADR-0011) and the settings pane's chip row (custom last).
    pub const ALL: [Vendor; 5] = [
        Vendor::DeepSeek,
        Vendor::Volcengine,
        Vendor::Qwen,
        Vendor::OpenAi,
        Vendor::Custom,
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
            Vendor::Custom => "custom",
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
            "custom" => Some(Vendor::Custom),
            _ => None,
        }
    }

    /// Parse a thinking-dialect name: the four adapted shapes only —
    /// `custom` names an endpoint, never a dialect (its own dialect is
    /// stored separately, ADR-0018).
    pub fn dialect_from_name(name: &str) -> Option<Self> {
        match name.trim() {
            "deepseek" | "volcengine" | "qwen" | "openai" => Self::from_str_name(name),
            _ => None,
        }
    }

    /// The conventional environment variable this vendor's key falls
    /// back to when no local-file key exists (each vendor keeps its own
    /// slot, so each names its own variable, ADR-0011). `None` for
    /// custom: an unadapted endpoint has no conventional name — the
    /// local file or a hand-written `api_key_env` is the only road.
    pub fn default_env(self) -> Option<&'static str> {
        match self {
            Vendor::DeepSeek => Some("DEEPSEEK_API_KEY"),
            Vendor::Volcengine => Some("ARK_API_KEY"),
            Vendor::Qwen => Some("DASHSCOPE_API_KEY"),
            Vendor::OpenAi => Some("OPENAI_API_KEY"),
            Vendor::Custom => None,
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
            // Never reached through the model's dialect resolution (the
            // parser above excludes custom); the openai shape is the
            // safety default a raw custom vendor value falls to.
            (Vendor::Custom, true) => vec![("reasoning_effort", json!("medium"))],
            (Vendor::Custom, false) => vec![],
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
            (Vendor::Custom, "custom"),
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

    /// The dialect names are the four adapted shapes: custom names an
    /// endpoint, never a dialect, and every other name is refused.
    #[test]
    fn the_dialect_parser_accepts_the_four_shapes_only() {
        for name in ["deepseek", "volcengine", "qwen", "openai"] {
            assert_eq!(
                Vendor::dialect_from_name(name),
                Vendor::from_str_name(name),
                "{name}"
            );
        }
        assert_eq!(Vendor::dialect_from_name("custom"), None);
        assert_eq!(Vendor::dialect_from_name("nonsense"), None);
    }

    /// Custom is in the slot registry but has no conventional
    /// environment variable and no thinking shape of its own.
    #[test]
    fn custom_has_no_env_and_the_openai_shape_as_safety() {
        assert_eq!(Vendor::ALL.len(), 5);
        assert!(Vendor::ALL.contains(&Vendor::Custom));
        assert_eq!(Vendor::Custom.default_env(), None);
        assert_eq!(
            Vendor::Custom.thinking_fields(true),
            Vendor::OpenAi.thinking_fields(true)
        );
        assert_eq!(
            Vendor::Custom.thinking_fields(false),
            Vendor::OpenAi.thinking_fields(false)
        );
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
