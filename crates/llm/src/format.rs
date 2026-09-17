//! The one behavioral axis of the connection face (ADR-0019): which of
//! the three wire formats the endpoint speaks. Path completion, auth
//! headers, prompt slots, and SSE framing all key off this — never off
//! a vendor name.

use serde::{Deserialize, Serialize};

/// The `[llm] format` value: how the engine speaks to the endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Format {
    /// The `/chat/completions` shape — the ecosystem's greatest common
    /// divisor (DeepSeek, Ark, DashScope, OpenAI itself, every
    /// compatible gateway).
    OpenaiChat,
    /// Anthropic Messages: `POST {base}/v1/messages`, the `event:`/`data:`
    /// SSE stream ending at `message_stop`.
    Anthropic,
    /// Gemini `streamGenerateContent?alt=sse`, the model riding in the
    /// path.
    Gemini,
}

impl Format {
    /// The file/wire name, spelled out for the settings editor's section
    /// writes and error messages.
    pub fn as_str(self) -> &'static str {
        match self {
            Format::OpenaiChat => "openai_chat",
            Format::Anthropic => "anthropic",
            Format::Gemini => "gemini",
        }
    }

    /// Parse the file/wire name, strictly: the three lowercase strings
    /// and nothing else — the format axis is explicit knowledge, never
    /// guessed (ADR-0019's no-auto-detection call).
    pub fn from_str_name(name: &str) -> Option<Self> {
        match name.trim() {
            "openai_chat" => Some(Format::OpenaiChat),
            "anthropic" => Some(Format::Anthropic),
            "gemini" => Some(Format::Gemini),
            _ => None,
        }
    }

    /// The accepted-values phrase every format error message carries.
    pub fn accepted() -> &'static str {
        "the strings \"openai_chat\", \"anthropic\", or \"gemini\" (lowercase)"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_spelled_names_match_serde_snake_case() {
        for (format, name) in [
            (Format::OpenaiChat, "openai_chat"),
            (Format::Anthropic, "anthropic"),
            (Format::Gemini, "gemini"),
        ] {
            assert_eq!(format.as_str(), name);
            // What a save writes must be what a load reads back.
            assert_eq!(
                serde_json::from_str::<Format>(format!("\"{name}\"").as_str()).unwrap(),
                format
            );
            assert_eq!(Format::from_str_name(name), Some(format));
        }
    }

    #[test]
    fn unknown_names_and_case_variants_are_refused() {
        for bad in ["openai", "chat", "Openai_Chat", "ANTHROPIC", ""] {
            assert_eq!(Format::from_str_name(bad), None, "{bad}");
        }
        // Like the vendor names, surrounding whitespace is tolerated.
        assert_eq!(Format::from_str_name(" gemini "), Some(Format::Gemini));
    }
}
