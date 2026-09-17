//! Anthropic Messages SSE dialect (ADR-0019 item 6).
//!
//! Isolated as a replaceable module so a future protocol swap does not
//! touch the openai_chat or gemini clients. The stream is `event:` +
//! `data:` dual-line frames; the JSON payload repeats the event `type`,
//! so the shared decoder (which ignores `event:` lines) is enough.
//!
//! Event flow: `message_start` → content blocks (`start` / `delta` /
//! `stop`) → `message_delta` → `message_stop`. There is no `[DONE]`;
//! `message_stop` ends the stream. `event: error` fails it. Unknown
//! event types are ignored (Anthropic's versioning policy).
//!
//! Content vs thinking is on the delta, not the block: `text_delta`
//! vs `thinking_delta`. A trailing `signature_delta` is integrity
//! metadata and never text. An empty `thinking_delta` (display:
//! omitted) is not the 「正在思考」 signal.

use serde::Deserialize;

use crate::client::{ParsedEvent, SseDialect};

/// The anthropic Messages SSE dialect.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct AnthropicDialect;

impl SseDialect for AnthropicDialect {
    fn parse_event(&self, data: &str) -> Result<ParsedEvent, String> {
        parse_anthropic_event(data)
    }
}

#[derive(Debug, Deserialize)]
struct Event {
    #[serde(rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    delta: Option<Delta>,
    #[serde(default)]
    error: Option<ErrorBody>,
}

#[derive(Debug, Deserialize)]
struct Delta {
    #[serde(rename = "type")]
    kind: Option<String>,
    text: Option<String>,
    thinking: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ErrorBody {
    #[serde(rename = "type")]
    kind: Option<String>,
    message: Option<String>,
}

/// One anthropic SSE data payload. The matching `event:` line is ignored
/// by the decoder; the JSON `type` is the source of truth.
pub(crate) fn parse_anthropic_event(data: &str) -> Result<ParsedEvent, String> {
    if data.trim().is_empty() {
        return Ok(ParsedEvent::empty());
    }
    let event: Event =
        serde_json::from_str(data).map_err(|err| format!("malformed SSE data: {err}"))?;
    let kind = event.kind.as_deref().unwrap_or("");
    if kind == "error" {
        return Err(format_error(event.error.as_ref()));
    }
    if kind == "message_stop" {
        return Ok(ParsedEvent {
            content: None,
            reasoning_chars: 0,
            done: true,
        });
    }
    if kind != "content_block_delta" {
        // ping, message_start, content_block_start/stop, message_delta,
        // and any future event type: ignore.
        return Ok(ParsedEvent::empty());
    }
    let Some(delta) = event.delta else {
        return Ok(ParsedEvent::empty());
    };
    match delta.kind.as_deref() {
        Some("text_delta") => Ok(ParsedEvent {
            content: delta.text.filter(|text| !text.is_empty()),
            reasoning_chars: 0,
            done: false,
        }),
        Some("thinking_delta") => {
            let reasoning_chars = delta
                .thinking
                .as_deref()
                .map(|text| text.chars().count() as u64)
                .unwrap_or(0);
            Ok(ParsedEvent {
                content: None,
                reasoning_chars,
                done: false,
            })
        }
        // signature_delta and any other delta type are not text.
        _ => Ok(ParsedEvent::empty()),
    }
}

fn format_error(error: Option<&ErrorBody>) -> String {
    match error {
        Some(ErrorBody {
            message: Some(message),
            ..
        }) if !message.is_empty() => format!("stream error: {message}"),
        Some(ErrorBody {
            kind: Some(kind), ..
        }) if !kind.is_empty() => format!("stream error: {kind}"),
        _ => "stream error".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_delta_is_content() {
        let data = r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#;
        let event = parse_anthropic_event(data).unwrap();
        assert_eq!(event.content.as_deref(), Some("Hello"));
        assert_eq!(event.reasoning_chars, 0);
        assert!(!event.is_thinking_signal());
        assert!(!event.done);
    }

    #[test]
    fn thinking_delta_is_the_thinking_signal_and_never_content() {
        // Official streaming-doc frame (contract §2.5 / ticket 03 fixture).
        let data = r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I need to find the GCD of 1071 and 462 using the Euclidean algorithm.\n\n1071 = 2 × 462 + 147"}}"#;
        let event = parse_anthropic_event(data).unwrap();
        assert!(event.content.is_none(), "thinking must not leak into text");
        assert!(event.reasoning_chars > 0);
        assert!(event.is_thinking_signal());
        assert!(!event.done);
    }

    #[test]
    fn empty_thinking_delta_is_not_a_signal() {
        // display: omitted streams an empty thinking string then a signature.
        let data = r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#;
        let event = parse_anthropic_event(data).unwrap();
        assert_eq!(event, ParsedEvent::empty());
        assert!(!event.is_thinking_signal());
    }

    #[test]
    fn signature_delta_ping_and_block_bookends_are_ignored() {
        let signature = r#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."}}"#;
        assert_eq!(
            parse_anthropic_event(signature).unwrap(),
            ParsedEvent::empty()
        );

        assert_eq!(
            parse_anthropic_event(r#"{"type":"ping"}"#).unwrap(),
            ParsedEvent::empty()
        );
        assert_eq!(
            parse_anthropic_event(
                r#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"output_tokens":1}}}"#
            )
            .unwrap(),
            ParsedEvent::empty()
        );
        assert_eq!(
            parse_anthropic_event(
                r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#
            )
            .unwrap(),
            ParsedEvent::empty()
        );
        assert_eq!(
            parse_anthropic_event(r#"{"type":"content_block_stop","index":0}"#).unwrap(),
            ParsedEvent::empty()
        );
        assert_eq!(
            parse_anthropic_event(
                r#"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}"#
            )
            .unwrap(),
            ParsedEvent::empty()
        );
    }

    #[test]
    fn message_stop_ends_the_stream() {
        // Official streaming-doc closer — no [DONE] (contract §2.5).
        let event = parse_anthropic_event(r#"{"type":"message_stop"}"#).unwrap();
        assert!(event.done);
        assert!(event.content.is_none());
        assert_eq!(event.reasoning_chars, 0);
    }

    #[test]
    fn error_event_fails_the_stream() {
        // Official streaming-doc error frame.
        let err = parse_anthropic_event(
            r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        );
        assert_eq!(err, Err("stream error: Overloaded".into()));
        assert!(parse_anthropic_event("not json").is_err());
    }

    #[test]
    fn unknown_event_types_are_ignored() {
        assert_eq!(
            parse_anthropic_event(r#"{"type":"something_new","index":0}"#).unwrap(),
            ParsedEvent::empty()
        );
    }

    #[test]
    fn keep_alive_whitespace_is_empty() {
        assert_eq!(parse_anthropic_event("  ").unwrap(), ParsedEvent::empty());
    }
}
