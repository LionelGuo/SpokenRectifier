//! The per-vendor key slots (ADR-0011, extended by ADR-0019): which
//! endpoint a chip names and which conventional environment variable
//! its key falls back to. A slot never drives request behavior — the
//! `[llm] format` axis does; `vendor` is the slot pointer plus the
//! last-clicked preset, nothing more (ADR-0019 item 1).
//!
//! The `thinking_fields` pair lists below are the pre-0019 request
//! shape, kept as the migration dictionary's one source: the
//! grandfather expands them into the new `[llm.overlays]` shares
//! byte for byte, and nothing on the live request path reads them.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// One endpoint slot on the connection card's chip row (custom last).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Vendor {
    /// api.deepseek.com.
    DeepSeek,
    /// Volcengine Ark.
    Volcengine,
    /// DashScope compatible mode.
    Qwen,
    /// api.openai.com.
    OpenAi,
    /// api.anthropic.com (ADR-0019): its own format, not a compat shape.
    Anthropic,
    /// generativelanguage.googleapis.com (ADR-0019).
    Gemini,
    /// The user's own endpoint (ADR-0018): no preset URL, no
    /// conventional environment variable — the local file or a
    /// hand-written `api_key_env` is the only road.
    Custom,
}

impl Vendor {
    /// Every vendor, in declaration order — keying the per-vendor key
    /// slots (ADR-0011) and the settings pane's chip row (custom last).
    pub const ALL: [Vendor; 7] = [
        Vendor::DeepSeek,
        Vendor::Volcengine,
        Vendor::Qwen,
        Vendor::OpenAi,
        Vendor::Anthropic,
        Vendor::Gemini,
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
            Vendor::Anthropic => "anthropic",
            Vendor::Gemini => "gemini",
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
            "anthropic" => Some(Vendor::Anthropic),
            "gemini" => Some(Vendor::Gemini),
            "custom" => Some(Vendor::Custom),
            _ => None,
        }
    }

    /// Parse a thinking-dialect name: the four pre-0019 adapted shapes
    /// only — `custom` names an endpoint, never a dialect (its own
    /// dialect was stored separately, ADR-0018). Read-side legacy only:
    /// the dictionary's consumer; the live path reads `[llm] format`.
    pub fn dialect_from_name(name: &str) -> Option<Self> {
        match name.trim() {
            "deepseek" | "volcengine" | "qwen" | "openai" => Self::from_str_name(name),
            _ => None,
        }
    }

    /// The conventional environment variable this vendor's key falls
    /// back to when no local-file key exists (each vendor keeps its own
    /// slot, so each names its own variable, ADR-0011). `None` for
    /// custom: an unadapted endpoint has no conventional name.
    pub fn default_env(self) -> Option<&'static str> {
        match self {
            Vendor::DeepSeek => Some("DEEPSEEK_API_KEY"),
            Vendor::Volcengine => Some("ARK_API_KEY"),
            Vendor::Qwen => Some("DASHSCOPE_API_KEY"),
            Vendor::OpenAi => Some("OPENAI_API_KEY"),
            Vendor::Anthropic => Some("ANTHROPIC_API_KEY"),
            Vendor::Gemini => Some("GEMINI_API_KEY"),
            Vendor::Custom => None,
        }
    }

    /// The pre-0019 request's thinking-field pairs for the wanted mode —
    /// the migration dictionary's one source, never the live request
    /// path (the new path merges `[llm.overlays]`, ADR-0019). The four
    /// adapted shapes carry their legacy pairs; empty means the old
    /// body sent nothing. The two post-0019 slots were never dialects
    /// and carry no pairs here — their grandfather expands to the
    /// preset shares (see `presets::grandfather`).
    pub fn thinking_fields(self, thinking: bool) -> Vec<(&'static str, Value)> {
        match (self, thinking) {
            (Vendor::DeepSeek, true) => vec![
                ("thinking", json!({"type": "enabled"})),
                // absorb-clock 05: "medium" only mapped up to the
                // endpoint's high; "low" measurably trims the pinned
                // absorption thinking (tokens and clock down, accuracy
                // held), and the user ruled any gain lands.
                ("reasoning_effort", json!("low")),
            ],
            (Vendor::DeepSeek, false) => vec![("thinking", json!({"type": "disabled"}))],
            (Vendor::Volcengine, true) => vec![("thinking", json!({"type": "enabled"}))],
            (Vendor::Volcengine, false) => vec![("thinking", json!({"type": "disabled"}))],
            (Vendor::Qwen, true) => vec![("enable_thinking", json!(true))],
            (Vendor::Qwen, false) => vec![("enable_thinking", json!(false))],
            (Vendor::OpenAi, true) => vec![("reasoning_effort", json!("medium"))],
            (Vendor::OpenAi, false) => vec![],
            // The custom slot's stored dialect picks one of the four
            // above; the openai shape is the safety default a raw
            // custom value falls to (ADR-0018).
            (Vendor::Custom, true) => vec![("reasoning_effort", json!("medium"))],
            (Vendor::Custom, false) => vec![],
            (Vendor::Anthropic, _) | (Vendor::Gemini, _) => vec![],
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
            (Vendor::Anthropic, "anthropic"),
            (Vendor::Gemini, "gemini"),
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

    /// The dialect names are the four pre-0019 adapted shapes: custom
    /// names an endpoint, never a dialect, and the two post-0019 slots
    /// were never dialects either.
    #[test]
    fn the_dialect_parser_accepts_the_four_shapes_only() {
        for name in ["deepseek", "volcengine", "qwen", "openai"] {
            assert_eq!(
                Vendor::dialect_from_name(name),
                Vendor::from_str_name(name),
                "{name}"
            );
        }
        for never in ["custom", "anthropic", "gemini", "nonsense"] {
            assert_eq!(Vendor::dialect_from_name(never), None, "{never}");
        }
    }

    /// Custom is in the slot registry but has no conventional
    /// environment variable and no thinking shape of its own.
    #[test]
    fn custom_has_no_env_and_the_openai_shape_as_safety() {
        assert_eq!(Vendor::ALL.len(), 7);
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

    /// The two post-0019 slots were never dialects and carry no legacy
    /// pairs — their grandfather expands to the preset shares.
    #[test]
    fn the_new_slots_carry_no_legacy_pairs() {
        assert!(Vendor::Anthropic.thinking_fields(true).is_empty());
        assert!(Vendor::Gemini.thinking_fields(false).is_empty());
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
                ("reasoning_effort", json!("low")),
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
