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

    /// Complete `{base_url}` to the format's request URL. The base is a
    /// prefix only — never a full-URL override (ADR-0019 item 1). Gemini
    /// interpolates the model into the path; the other two append a
    /// fixed suffix.
    pub fn complete_url(self, base_url: &str, model: &str) -> String {
        let base = base_url.trim_end_matches('/');
        match self {
            Format::OpenaiChat => format!("{base}/chat/completions"),
            Format::Anthropic => format!("{base}/v1/messages"),
            Format::Gemini => {
                format!("{base}/models/{model}:streamGenerateContent?alt=sse")
            }
        }
    }

    /// Auth (and companion) headers for one request. The key is the
    /// resolved secret; it never appears in a URL.
    pub fn auth_headers(self, api_key: &str) -> Vec<(&'static str, String)> {
        match self {
            Format::OpenaiChat => vec![("Authorization", format!("Bearer {api_key}"))],
            Format::Anthropic => vec![
                ("x-api-key", api_key.to_string()),
                ("anthropic-version", "2023-06-01".into()),
            ],
            Format::Gemini => vec![("x-goog-api-key", api_key.to_string())],
        }
    }

    /// Keys the assembler injects last and never lets an overlay keep
    /// (ADR-0019 item 2). The set varies with the format: prompt slots,
    /// `stream`, and `model` where the body carries them.
    pub fn protected_keys(self) -> &'static [&'static str] {
        match self {
            Format::OpenaiChat => &["model", "messages", "stream"],
            Format::Anthropic => &["model", "system", "messages", "stream"],
            Format::Gemini => &["systemInstruction", "contents"],
        }
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

    #[test]
    fn path_completion_is_a_prefix_plus_the_format_rule() {
        assert_eq!(
            Format::OpenaiChat.complete_url("https://api.deepseek.com/", "ignored"),
            "https://api.deepseek.com/chat/completions"
        );
        assert_eq!(
            Format::Anthropic.complete_url("https://api.anthropic.com", "ignored"),
            "https://api.anthropic.com/v1/messages"
        );
        assert_eq!(
            Format::Gemini.complete_url(
                "https://generativelanguage.googleapis.com/v1beta/",
                "gemini-3.8-flash"
            ),
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse"
        );
    }

    #[test]
    fn auth_headers_match_the_format_contract() {
        let openai = Format::OpenaiChat.auth_headers("sk-test");
        assert_eq!(openai, vec![("Authorization", "Bearer sk-test".into())]);
        let anthropic = Format::Anthropic.auth_headers("sk-test");
        assert_eq!(
            anthropic,
            vec![
                ("x-api-key", "sk-test".into()),
                ("anthropic-version", "2023-06-01".into()),
            ]
        );
        let gemini = Format::Gemini.auth_headers("sk-test");
        assert_eq!(gemini, vec![("x-goog-api-key", "sk-test".into())]);
    }
}
