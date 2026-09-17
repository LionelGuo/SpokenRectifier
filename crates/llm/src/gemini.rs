//! Gemini `streamGenerateContent?alt=sse` dialect (ADR-0019 item 6).
//!
//! Isolated as a replaceable module: generateContent is officially
//! labelled Legacy, Google is pushing the Interactions API, and a
//! swap should not touch the openai_chat or anthropic clients.
//!
//! Each SSE `data:` payload is one `GenerateContentResponse`. There
//! is no sentinel — the stream ends when the HTTP body does.
//! `usageMetadata.thoughtsTokenCount` is recorded in the contract
//! and not modelled here (ticket 03).
//!
//! Content vs thinking is on the part: an unmarked text part is
//! rectified text; `thought: true` is the thinking channel. A
//! `thoughtSignature` (with or without text) is integrity metadata
//! and never leaked into the rectified text.

use serde::Deserialize;

use crate::client::{ParsedEvent, SseDialect};

/// The gemini `alt=sse` dialect.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct GeminiDialect;

impl SseDialect for GeminiDialect {
    fn parse_event(&self, data: &str) -> Result<ParsedEvent, String> {
        parse_gemini_event(data)
    }
}

#[derive(Debug, Deserialize)]
struct Response {
    #[serde(default)]
    candidates: Vec<Candidate>,
    error: Option<ErrorBody>,
}

#[derive(Debug, Deserialize)]
struct Candidate {
    content: Option<Content>,
}

#[derive(Debug, Deserialize)]
struct Content {
    #[serde(default)]
    parts: Vec<Part>,
}

#[derive(Debug, Deserialize)]
struct Part {
    text: Option<String>,
    /// Thought-summary marker. Missing/false = rectified text.
    #[serde(default)]
    thought: bool,
}

#[derive(Debug, Deserialize)]
struct ErrorBody {
    message: Option<String>,
    status: Option<String>,
}

/// One gemini SSE data payload (`GenerateContentResponse`). Never sets
/// `done`: the format has no sentinel, and a last frame may still
/// carry content — the transport ends the stream when the body does.
pub(crate) fn parse_gemini_event(data: &str) -> Result<ParsedEvent, String> {
    if data.trim().is_empty() {
        return Ok(ParsedEvent::empty());
    }
    let response: Response =
        serde_json::from_str(data).map_err(|err| format!("malformed SSE data: {err}"))?;
    if let Some(error) = response.error {
        return Err(format_error(&error));
    }
    let Some(candidate) = response.candidates.into_iter().next() else {
        return Ok(ParsedEvent::empty());
    };
    let Some(content) = candidate.content else {
        return Ok(ParsedEvent::empty());
    };

    let mut text = String::new();
    let mut reasoning_chars = 0_u64;
    for part in content.parts {
        let piece = part.text.unwrap_or_default();
        if part.thought {
            reasoning_chars += piece.chars().count() as u64;
            continue;
        }
        text.push_str(&piece);
    }
    Ok(ParsedEvent {
        content: if text.is_empty() { None } else { Some(text) },
        reasoning_chars,
        done: false,
    })
}

fn format_error(error: &ErrorBody) -> String {
    if let Some(message) = error.message.as_deref().filter(|m| !m.is_empty()) {
        format!("stream error: {message}")
    } else if let Some(status) = error.status.as_deref().filter(|s| !s.is_empty()) {
        format!("stream error: {status}")
    } else {
        "stream error".into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unmarked_text_part_is_content() {
        let data =
            r#"{"candidates":[{"content":{"role":"model","parts":[{"text":"会议"}]},"index":0}]}"#;
        let event = parse_gemini_event(data).unwrap();
        assert_eq!(event.content.as_deref(), Some("会议"));
        assert_eq!(event.reasoning_chars, 0);
        assert!(!event.is_thinking_signal());
        assert!(!event.done);
    }

    #[test]
    fn thought_true_part_is_the_thinking_signal_and_never_content() {
        let data = r#"{"candidates":[{"content":{"role":"model","parts":[{"text":"The user wants a summary.","thought":true}]},"index":0}]}"#;
        let event = parse_gemini_event(data).unwrap();
        assert!(event.content.is_none(), "thought parts must not leak");
        assert_eq!(event.reasoning_chars, 25);
        assert!(event.is_thinking_signal());
        assert!(!event.done);
    }

    #[test]
    fn same_frame_thought_and_text_count_both() {
        let data = r#"{"candidates":[{"content":{"parts":[{"text":"想","thought":true},{"text":"会议"}]}}]}"#;
        let event = parse_gemini_event(data).unwrap();
        assert_eq!(event.content.as_deref(), Some("会议"));
        assert_eq!(event.reasoning_chars, 1);
        assert!(event.is_thinking_signal());
    }

    #[test]
    fn thought_signature_without_text_is_ignored() {
        // Gemini 3 often trails a signature-only part on the last frame
        // (contract §3.5). finishReason does not end our stream — no
        // sentinel, and this frame might have been the last content too.
        let data = r#"{"candidates":[{"content":{"parts":[{"thoughtSignature":"EjQKMgEM"}]},"finishReason":"STOP","index":0}],"usageMetadata":{"thoughtsTokenCount":8}}"#;
        let event = parse_gemini_event(data).unwrap();
        assert_eq!(event, ParsedEvent::empty());
        assert!(!event.done, "gemini has no sentinel; the body ending does");
    }

    #[test]
    fn thoughts_token_count_is_not_modelled() {
        // Recorded in the contract; the observation seam counts thinking
        // *text* chars, not billed thought tokens.
        let data = r#"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}],"usageMetadata":{"thoughtsTokenCount":47}}"#;
        let event = parse_gemini_event(data).unwrap();
        assert_eq!(event.content.as_deref(), Some("Hi"));
        assert_eq!(event.reasoning_chars, 0);
    }

    #[test]
    fn error_object_fails_the_stream() {
        let err = parse_gemini_event(
            r#"{"error":{"code":429,"message":"Resource exhausted","status":"RESOURCE_EXHAUSTED"}}"#,
        );
        assert_eq!(err, Err("stream error: Resource exhausted".into()));
        assert!(parse_gemini_event("not json").is_err());
    }

    #[test]
    fn empty_candidates_and_keep_alive_are_empty() {
        assert_eq!(
            parse_gemini_event(r#"{"candidates":[]}"#).unwrap(),
            ParsedEvent::empty()
        );
        assert_eq!(parse_gemini_event("  ").unwrap(), ParsedEvent::empty());
    }
}
