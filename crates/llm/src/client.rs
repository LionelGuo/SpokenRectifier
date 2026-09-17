//! The OpenAI Chat Completions rectify client: one `POST` with
//! `stream: true`, SSE deltas out. Path, auth, and body assembly live
//! on the format axis ([`Format`], [`crate::assembly`]); this module
//! owns the openai_chat SSE dialect (`delta.content` vs
//! `delta.reasoning` / `delta.reasoning_content`) and the shared
//! HTTP/SSE transport the other two formats plug into (ticket 03).
//!
//! A thinking-channel token is the 「正在思考」 signal (ADR-0019 item 6):
//! counted, never leaked into the rectified text. The session-window
//! display is out of this ticket's scope.

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use serde::Deserialize;
use serde_json::Value;

use spokenrectifier_engine::provider::llm::{
    RectifyError, RectifyLlm, RectifyRequest, RectifyTokenStream,
};

use crate::assembly::request_body;
use crate::config::{LlmConfig, ModelConfig, ThinkingPolicy};
use crate::format::Format;
use crate::intensity::{Intensity, select_intensity};
use crate::prompt::{ChatPrompt, compose_prompt_with_extra, has_pins};

/// One SSE data payload, decoded. Format dialects map their frames
/// onto this; the transport yields only `content` and counts
/// `reasoning_chars`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ParsedEvent {
    /// A rectified-text token delta, if this frame carried one.
    pub content: Option<String>,
    /// Thinking-channel characters on this frame. A non-zero value is
    /// the 「正在思考」 signal (ADR-0019 item 6): counted, never leaked
    /// into the rectified text. The session-window display is out of
    /// this ticket's scope.
    pub reasoning_chars: u64,
    /// End of stream (`[DONE]` for openai_chat; other dialects name
    /// their own sentinel in ticket 03).
    pub done: bool,
}

impl ParsedEvent {
    /// The 「正在思考」 signal: a non-empty thinking-channel token.
    pub(crate) fn is_thinking_signal(&self) -> bool {
        self.reasoning_chars > 0
    }
}

/// Decode one SSE data payload. One impl per format (ADR-0019 item 6);
/// today's client is openai_chat.
pub(crate) trait SseDialect: Send + Sync + 'static {
    fn parse_event(&self, data: &str) -> Result<ParsedEvent, String>;
}

/// The openai_chat SSE dialect: `choices[0].delta.content` vs the
/// thinking channel's two historical names.
pub(crate) struct OpenaiChatDialect;

impl SseDialect for OpenaiChatDialect {
    fn parse_event(&self, data: &str) -> Result<ParsedEvent, String> {
        parse_openai_chat_event(data)
    }
}

/// A rectify LLM backed by an OpenAI Chat Completions endpoint. Request
/// URL, auth, and body still key off [`ModelConfig::format`] so a
/// rebuild under another format sends the right shape; the SSE decoder
/// stays openai_chat until ticket 03 swaps the dialect.
pub struct OpenAiCompatLlm {
    config: LlmConfig,
    http: reqwest::Client,
    /// The reasoning-char observation counter (placeholder-process 06's
    /// falsifier column): inert until [`Self::with_reasoning_counter`]
    /// attaches one — production clients never do, and the thinking text
    /// itself never leaves the stream layer either way.
    reasoning_chars: Option<Arc<AtomicU64>>,
}

impl OpenAiCompatLlm {
    pub fn new(config: LlmConfig) -> Result<Self, RectifyError> {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(|err| RectifyError(format!("HTTP client build failed: {err}")))?;
        Ok(Self {
            config,
            http,
            reasoning_chars: None,
        })
    }

    /// Attach the reasoning-char counter the eval's observation column
    /// reads through [`RectifyLlm::take_reasoning_chars`]. Eval-only.
    pub fn with_reasoning_counter(mut self, counter: Arc<AtomicU64>) -> Self {
        self.reasoning_chars = Some(counter);
        self
    }

    /// The request's prompt under this client's config: the chosen
    /// tier's prefill key rides onto the request here — the same hop
    /// the thinking policy and the intensity gate take, the one place
    /// the config meets the composition. The engine's value is the seam
    /// default; the client owns the truth, so a runtime re-adoption (a
    /// rebuilt client) carries a changed key for free (ADR-0014/0015).
    fn composed_prompt(&self, request: &RectifyRequest, intensity: Intensity) -> ChatPrompt {
        let tier = self.config.rectify.tier(intensity);
        let mut shaped = request.clone();
        shaped.prefill = tier.prefill;
        let extra = match intensity {
            Intensity::LightTouch => self.config.rectify.light_touch.extra_directive.as_deref(),
            Intensity::Full => None,
        };
        compose_prompt_with_extra(&shaped, intensity, extra)
    }

    /// The chosen tier's thinking policy folded to the boolean the
    /// request body carries (ADR-0015's evaluation): `placeholders`
    /// runs the census the prompt's injection gate runs — the two can
    /// never disagree (one census, two consumers).
    fn thinking_enabled(&self, raw_transcript: &str, intensity: Intensity) -> bool {
        match self.config.rectify.tier(intensity).thinking_policy {
            ThinkingPolicy::Always => true,
            ThinkingPolicy::Off => false,
            ThinkingPolicy::Placeholders => has_pins(raw_transcript),
        }
    }
}

/// The production client for a loaded config. Format picks the
/// implementation (ADR-0019 item 6); ticket 02 lands openai_chat.
/// Anthropic and gemini still construct that client so a rebuild
/// already sends the right URL/headers/body — ticket 03 swaps those
/// two arms onto their own SSE dialects.
pub fn live_llm(config: LlmConfig) -> Result<Arc<dyn RectifyLlm>, RectifyError> {
    // Ticket 03 splits this match: openai_chat stays, anthropic/gemini
    // swap onto their own dialects. Until then every format rides this
    // client, which already posts the format's URL, headers, and body.
    match config.model.format {
        Format::OpenaiChat | Format::Anthropic | Format::Gemini => {
            Ok(Arc::new(OpenAiCompatLlm::new(config)?))
        }
    }
}

#[async_trait]
impl RectifyLlm for OpenAiCompatLlm {
    async fn rectify(&self, request: RectifyRequest) -> Result<RectifyTokenStream, RectifyError> {
        // The gate plus length pick the intensity — how the prompt asks
        // for rectify — never the model: one endpoint serves both
        // (ADR-0015's evaluation order: intensity first, then that
        // tier's policy and prefill).
        let gate = &self.config.rectify.light_touch;
        let intensity = select_intensity(&request.raw_transcript, gate.enabled, gate.max_chars);
        let model = &self.config.model;
        let key = model.resolve_key().ok_or_else(|| {
            let env_hint = model
                .api_key_env
                .as_deref()
                .map(|name| format!(" or export {name}"))
                .unwrap_or_default();
            RectifyError(format!(
                "no API key for the rectify model ({}): set api_key in \
                 spokenrectifier.local.toml{env_hint}",
                model.model
            ))
        })?;
        let prompt = self.composed_prompt(&request, intensity);
        let thinking = self.thinking_enabled(&request.raw_transcript, intensity);
        let url = model.format.complete_url(&model.base_url, &model.model);
        let body = request_body(model, &prompt, thinking);
        let response = post_sse(&self.http, model, &key, &url, &body).await?;
        Ok(Box::pin(sse_token_stream(
            response,
            self.reasoning_chars.clone(),
            OpenaiChatDialect,
        )))
    }

    /// Read-and-reset over the attached counter: one call pairs with one
    /// finished request, so the value the caller reads is exactly that
    /// request's reasoning length. Uninstrumented clients report `None`.
    fn take_reasoning_chars(&self) -> Option<u64> {
        self.reasoning_chars
            .as_ref()
            .map(|counter| counter.swap(0, Ordering::Relaxed))
    }
}

/// POST the assembled body with the format's auth headers. Shared with
/// ticket 03's clients.
pub(crate) async fn post_sse(
    http: &reqwest::Client,
    model: &ModelConfig,
    key: &str,
    url: &str,
    body: &Value,
) -> Result<reqwest::Response, RectifyError> {
    let mut req = http.post(url).json(body);
    for (name, value) in model.format.auth_headers(key) {
        req = req.header(name, value);
    }
    let response = req
        .send()
        .await
        .map_err(|err| RectifyError(format!("request to {url} failed: {err}")))?;
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        let message = serde_json::from_str::<ApiErrorBody>(&body)
            .ok()
            .and_then(|b| b.error.message);
        let detail = message.unwrap_or(body);
        return Err(RectifyError(format!(
            "{url} returned {}: {detail}",
            status.as_u16()
        )));
    }
    Ok(response)
}

// -- openai_chat SSE --------------------------------------------------------

#[derive(Debug, Deserialize)]
struct ApiErrorBody {
    error: ApiErrorWrap,
}

#[derive(Debug, Deserialize)]
struct ApiErrorWrap {
    message: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct ChatChunk {
    #[serde(default)]
    choices: Vec<Choice>,
    #[serde(default)]
    error: Option<ChunkError>,
}

#[derive(Debug, Default, Deserialize)]
struct Choice {
    #[serde(default)]
    delta: Delta,
}

#[derive(Debug, Default, Deserialize)]
struct Delta {
    content: Option<String>,
    /// DeepSeek / DashScope / Ark name.
    reasoning_content: Option<String>,
    /// vLLM's rename of `reasoning_content` (ADR-0019 item 6).
    reasoning: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ChunkError {
    message: String,
}

fn reasoning_chars(delta: &Delta) -> u64 {
    // Prefer the current vLLM name; fall back to the original. A
    // gateway that sends both with the same text is counted once.
    let text = delta
        .reasoning
        .as_deref()
        .or(delta.reasoning_content.as_deref())
        .unwrap_or("");
    text.chars().count() as u64
}

fn empty_event() -> ParsedEvent {
    ParsedEvent {
        content: None,
        reasoning_chars: 0,
        done: false,
    }
}

/// One openai_chat SSE data payload: content, thinking, keep-alive,
/// `[DONE]`, or a stream error.
pub(crate) fn parse_openai_chat_event(data: &str) -> Result<ParsedEvent, String> {
    if data.trim().is_empty() {
        return Ok(empty_event());
    }
    if data.trim() == "[DONE]" {
        return Ok(ParsedEvent {
            content: None,
            reasoning_chars: 0,
            done: true,
        });
    }
    let chunk: ChatChunk =
        serde_json::from_str(data).map_err(|err| format!("malformed SSE data: {err}"))?;
    if let Some(err) = chunk.error {
        return Err(format!("stream error: {}", err.message));
    }
    let Some(choice) = chunk.choices.into_iter().next() else {
        return Ok(empty_event());
    };
    let reasoning_chars = reasoning_chars(&choice.delta);
    Ok(ParsedEvent {
        content: choice.delta.content.filter(|text| !text.is_empty()),
        reasoning_chars,
        done: false,
    })
}

/// Feed one decoded SSE event (its joined data payload) into the stream.
struct StreamState<D> {
    response: reqwest::Response,
    decoder: SseDecoder,
    pending: VecDeque<String>,
    reasoning_chars: Option<Arc<AtomicU64>>,
    dialect: D,
}

fn sse_token_stream<D: SseDialect>(
    response: reqwest::Response,
    reasoning_chars: Option<Arc<AtomicU64>>,
    dialect: D,
) -> RectifyTokenStream {
    futures::stream::try_unfold(
        StreamState {
            response,
            decoder: SseDecoder::new(),
            pending: VecDeque::new(),
            reasoning_chars,
            dialect,
        },
        |mut state| async move {
            loop {
                if let Some(data) = state.pending.pop_front() {
                    match state.dialect.parse_event(&data) {
                        Ok(parsed) if parsed.done => return Ok(None),
                        Ok(parsed) => {
                            if parsed.is_thinking_signal()
                                && let Some(counter) = state.reasoning_chars.as_ref()
                            {
                                counter.fetch_add(parsed.reasoning_chars, Ordering::Relaxed);
                            }
                            if let Some(delta) = parsed.content {
                                return Ok(Some((delta, state)));
                            }
                            continue;
                        }
                        Err(message) => return Err(RectifyError(message)),
                    }
                }
                match state.response.chunk().await {
                    Ok(Some(bytes)) => {
                        state.pending.extend(state.decoder.feed(&bytes));
                    }
                    Ok(None) => {
                        // Stream ended; flush an unterminated final event.
                        state.pending.extend(state.decoder.finish());
                        if state.pending.is_empty() {
                            return Ok(None);
                        }
                    }
                    Err(err) => {
                        return Err(RectifyError(format!("stream read failed: {err}")));
                    }
                }
            }
        },
    )
    .boxed()
}

// -- SSE framing ------------------------------------------------------------

/// Server-sent-events line decoder: buffers bytes until a full line arrives,
/// accumulates `data:` payloads per event, and emits one String per event.
/// Handles `\n` and `\r\n`, `data:` with or without the space, ignores other
/// fields and `:` comments, and never splits a UTF-8 character (a `\n` is
/// ASCII and cannot appear inside a multi-byte character).
pub(crate) struct SseDecoder {
    buf: Vec<u8>,
    data_lines: Vec<String>,
}

impl SseDecoder {
    pub(crate) fn new() -> Self {
        Self {
            buf: Vec::new(),
            data_lines: Vec::new(),
        }
    }

    /// Feed raw bytes; returns the data payloads of every event the chunk
    /// completed.
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        self.buf.extend_from_slice(bytes);
        let mut events = Vec::new();
        while let Some(nl) = self.buf.iter().position(|&b| b == b'\n') {
            let mut line: Vec<u8> = self.buf.drain(..=nl).collect();
            line.pop(); // the \n
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            let line = String::from_utf8_lossy(&line);
            if line.is_empty() {
                if let Some(event) = self.take_event() {
                    events.push(event);
                }
            } else if let Some(payload) = line.strip_prefix("data:") {
                let payload = payload.strip_prefix(' ').unwrap_or(payload);
                self.data_lines.push(payload.to_string());
            }
            // `event:`, `id:`, `retry:` fields and `:` comments are ignored.
        }
        events
    }

    /// Flush a final event that was not terminated by a blank line.
    pub(crate) fn finish(&mut self) -> Vec<String> {
        self.buf.clear();
        self.take_event().into_iter().collect()
    }

    fn take_event(&mut self) -> Option<String> {
        if self.data_lines.is_empty() {
            return None;
        }
        Some(self.data_lines.drain(..).collect::<Vec<_>>().join("\n"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use spokenrectifier_engine::provider::llm::RectifyRequest;

    /// The wiring hop the prefill key lands through: the config — not
    /// the engine's seam default — decides the pinned prompt's form
    /// (census table on, pass-through off; ADR-0014), per tier.
    #[test]
    fn the_prefill_config_decides_the_pinned_prompt_form() {
        let pinned = RectifyRequest {
            raw_transcript: "记一下‡1‡的安排".into(),
            paragraphs: vec!["记一下‡1‡的安排".into()],
            style_directive: None,
            global_directive: None,
            terms: Vec::new(),
            prefill: true, // the engine's seam default
        };
        let mut off_config = LlmConfig::defaults();
        off_config.rectify.full.prefill = false;
        let on = OpenAiCompatLlm::new(LlmConfig::defaults()).unwrap();
        let off = OpenAiCompatLlm::new(off_config).unwrap();

        let on_prompt = on.composed_prompt(&pinned, Intensity::Full);
        assert!(on_prompt.user.contains("【占位符清单】"), "census missing");

        let off_prompt = off.composed_prompt(&pinned, Intensity::Full);
        assert!(
            !off_prompt.user.contains("【占位符清单】"),
            "census leaked into the pass-through form"
        );
    }

    /// The thinking policy's three tiers fold at this client (ADR-0015's
    /// evaluation): always/off directly, placeholders through the census
    /// — the same census the prompt's injection gate keys on, so a pin
    /// that injects the placeholder branch also turns thinking on, and a
    /// pinless transcript never does.
    #[test]
    fn the_thinking_policy_folds_through_the_census() {
        let mut config = LlmConfig::defaults();
        config.rectify.full.thinking_policy = ThinkingPolicy::Placeholders;
        let llm = OpenAiCompatLlm::new(config).unwrap();
        assert!(llm.thinking_enabled("记一下‡1‡的安排", Intensity::Full));
        assert!(!llm.thinking_enabled("没有记号的短句", Intensity::Full));
        // The tiers never inherit: the untouched light-touch tier stays
        // always-on, and each tier reads its own policy.
        assert!(llm.thinking_enabled("没有记号的短句", Intensity::LightTouch));

        let mut off = LlmConfig::defaults();
        off.rectify.light_touch.tier.thinking_policy = ThinkingPolicy::Off;
        let off = OpenAiCompatLlm::new(off).unwrap();
        assert!(!off.thinking_enabled("记一下‡1‡的安排", Intensity::LightTouch));
        assert!(off.thinking_enabled("记一下‡1‡的安排", Intensity::Full));
    }

    fn feed_all(chunks: &[&str]) -> Vec<String> {
        let mut decoder = SseDecoder::new();
        let mut events = Vec::new();
        for chunk in chunks {
            events.extend(decoder.feed(chunk.as_bytes()));
        }
        events.extend(decoder.finish());
        events
    }

    #[test]
    fn decodes_two_events_in_one_chunk() {
        let body = "data: {\"a\":1}\n\ndata: {\"b\":2}\n\n";
        assert_eq!(feed_all(&[body]), vec!["{\"a\":1}", "{\"b\":2}"]);
    }

    #[test]
    fn reassembles_events_split_at_every_byte_boundary() {
        // The body is pure ASCII, so one char is one byte.
        let body = "data: {\"a\":1}\r\n\r\ndata: {\"b\":2}\r\n\r\n";
        let chunks: Vec<String> = body.chars().map(|c| c.to_string()).collect();
        let refs: Vec<&str> = chunks.iter().map(|s| s.as_str()).collect();
        assert_eq!(feed_all(&refs), vec!["{\"a\":1}", "{\"b\":2}"]);
    }

    #[test]
    fn handles_data_without_space_and_crlf() {
        assert_eq!(feed_all(&["data:{\"a\":1}\r\n\r\n"]), vec!["{\"a\":1}"]);
    }

    #[test]
    fn joins_multi_line_data_with_newlines() {
        let events = feed_all(&["data: line1\ndata: line2\n\n"]);
        assert_eq!(events, vec!["line1\nline2"]);
    }

    #[test]
    fn ignores_comments_and_other_fields() {
        let events = feed_all(&[": keep-alive\nevent: message\nid: 7\ndata: {\"a\":1}\n\n"]);
        assert_eq!(events, vec!["{\"a\":1}"]);
    }

    #[test]
    fn utf8_payload_split_across_chunks_survives() {
        // "你好" split between the two characters (byte 3 of 6).
        let payload = "data: 你好\n\n".as_bytes();
        let (a, b) = payload.split_at(3 + 6); // "data: " + 你
        let mut decoder = SseDecoder::new();
        assert!(decoder.feed(a).is_empty());
        let events = decoder.feed(b);
        assert_eq!(events, vec!["你好"]);
    }

    #[test]
    fn done_marker_is_distinct_from_data() {
        // The dialect treats exactly "[DONE]" as end-of-stream.
        assert_eq!(feed_all(&["data: [DONE]\n\n"]), vec!["[DONE]"]);
        assert!(parse_openai_chat_event("[DONE]").unwrap().done);
    }

    #[test]
    fn parse_event_yields_content_and_signals_reasoning() {
        let content = r#"{"choices":[{"delta":{"content":"会议"}}]}"#;
        let event = parse_openai_chat_event(content).unwrap();
        assert_eq!(event.content.as_deref(), Some("会议"));
        assert_eq!(event.reasoning_chars, 0);
        assert!(!event.is_thinking_signal());

        let reasoning = r#"{"choices":[{"delta":{"reasoning_content":"思考中"}}]}"#;
        let event = parse_openai_chat_event(reasoning).unwrap();
        assert!(event.content.is_none());
        assert_eq!(event.reasoning_chars, 3);
        assert!(
            event.is_thinking_signal(),
            "a thinking-channel token is the 「正在思考」 signal"
        );

        // vLLM's renamed field is the same signal (ADR-0019 item 6).
        let vllm = r#"{"choices":[{"delta":{"reasoning":"想"}}]}"#;
        let event = parse_openai_chat_event(vllm).unwrap();
        assert_eq!(event.reasoning_chars, 1);
        assert!(event.is_thinking_signal());

        let both = r#"{"choices":[{"delta":{"content":"会议","reasoning_content":"想"}}]}"#;
        let event = parse_openai_chat_event(both).unwrap();
        assert_eq!(event.content.as_deref(), Some("会议"));
        assert_eq!(event.reasoning_chars, 1);
        assert!(event.is_thinking_signal());

        let empty = r#"{"choices":[{"delta":{}}]}"#;
        assert_eq!(parse_openai_chat_event(empty).unwrap(), empty_event());
        let keep_alive = "  ";
        assert_eq!(parse_openai_chat_event(keep_alive).unwrap(), empty_event());
    }

    /// The observation seam (placeholder-process 06): an attached counter
    /// reads and resets per call, an uninstrumented client reports None —
    /// the default every production client keeps.
    #[test]
    fn the_reasoning_counter_reads_and_resets_or_reports_none() {
        let counter = Arc::new(AtomicU64::new(7));
        let llm = OpenAiCompatLlm::new(LlmConfig::defaults())
            .unwrap()
            .with_reasoning_counter(counter);
        assert_eq!(RectifyLlm::take_reasoning_chars(&llm), Some(7));
        assert_eq!(RectifyLlm::take_reasoning_chars(&llm), Some(0));

        let plain = OpenAiCompatLlm::new(LlmConfig::defaults()).unwrap();
        assert_eq!(RectifyLlm::take_reasoning_chars(&plain), None);
    }

    #[test]
    fn parse_event_maps_stream_errors() {
        let err = r#"{"error":{"message":"quota exceeded"}}"#;
        assert_eq!(
            parse_openai_chat_event(err),
            Err("stream error: quota exceeded".into())
        );
        assert!(parse_openai_chat_event("not json").is_err());
    }

    #[test]
    fn live_llm_builds_the_openai_chat_client() {
        let llm = live_llm(LlmConfig::defaults()).expect("client builds");
        assert_eq!(llm.take_reasoning_chars(), None);
    }
}
