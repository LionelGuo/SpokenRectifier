//! The three-format streaming client against a mock server: request
//! shape (auth, path, thinking field), SSE dialects, error mapping.

mod common;

use common::{config_with_base, long_request, quick_request, request};
use futures::StreamExt;
use httpmock::{Method, MockServer};
use spokenrectifier_engine::provider::llm::{RectifyDelta, RectifyLlm, RectifyRequest};
use spokenrectifier_llm::{Format, OpenAiCompatLlm};

fn sse_body() -> String {
    concat!(
        "data: {\"choices\":[{\"delta\":{\"content\":\"会议\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"思考\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"content\":\"纪要\"}}]}\n\n",
        "data: [DONE]\n\n",
    )
    .into()
}

async fn collect(llm: &OpenAiCompatLlm, request: RectifyRequest) -> Vec<RectifyDelta> {
    let stream = llm.rectify(request).await.expect("stream opens");
    stream
        .map(|item| item.expect("delta"))
        .collect::<Vec<RectifyDelta>>()
        .await
}

/// The two arms as plain strings: `(content deltas, reasoning deltas)`.
/// The empty deltas a keep-alive frame produces never appear — the
/// transport skips items with nothing to carry.
async fn collect_arms(
    llm: &OpenAiCompatLlm,
    request: RectifyRequest,
) -> (Vec<String>, Vec<String>) {
    let deltas = collect(llm, request).await;
    let content = deltas
        .iter()
        .filter_map(|d| d.content.clone())
        .collect::<Vec<_>>();
    let reasoning = deltas
        .iter()
        .filter_map(|d| d.reasoning.clone())
        .collect::<Vec<_>>();
    (content, reasoning)
}

#[tokio::test]
async fn streams_content_and_thinking_on_their_own_arms() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/chat/completions")
            .header("Authorization", "Bearer sk-test")
            // serde_json serializes maps alphabetically; assert the
            // interesting fields as compact-JSON substrings.
            .body_contains("字".repeat(40))
            .body_contains("\"model\":\"test-model\"")
            .body_contains("\"stream\":true")
            .body_contains("\"temperature\":0.2")
            .body_contains("\"thinking\":{\"type\":\"disabled\"}");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(sse_body());
    });

    let llm = OpenAiCompatLlm::new(config_with_base(server.base_url(), false)).unwrap();
    let (content, reasoning) = collect_arms(&llm, long_request()).await;

    assert_eq!(content, vec!["会议", "纪要"]);
    // The thinking channel rides its own arm (14 号票's marquee feed):
    // forwarded verbatim, never merged into the content arm.
    assert_eq!(reasoning, vec!["思考"]);
    mock.assert_hits(1);
}

#[tokio::test]
async fn thinking_on_sends_the_enabled_pair() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/chat/completions")
            .body_contains("\"thinking\":{\"type\":\"enabled\"}")
            .body_contains("\"reasoning_effort\":\"low\"");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(sse_body());
    });

    let llm = OpenAiCompatLlm::new(config_with_base(server.base_url(), true)).unwrap();
    collect(&llm, long_request()).await;
    mock.assert_hits(1);
}

#[tokio::test]
async fn short_and_long_utterances_call_the_same_model() {
    // One configured model serves both intensities; only the prompt's
    // intensity directive differs (轻修 below the threshold, 全量修正 at
    // or above it).
    let server = MockServer::start();
    let short = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/chat/completions")
            .body_contains("\"model\":\"test-model\"")
            .body_contains("轻修(本次输入较短)");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(sse_body());
    });
    let long = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/chat/completions")
            .body_contains("\"model\":\"test-model\"")
            .body_contains("全量修正(本次输入为中长段)");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(sse_body());
    });

    let llm = OpenAiCompatLlm::new(config_with_base(server.base_url(), false)).unwrap();
    collect(&llm, request(&"字".repeat(39))).await; // strictly below, light-touch
    collect(&llm, long_request()).await;

    short.assert_hits(1);
    long.assert_hits(1);
}

#[tokio::test]
async fn http_error_maps_status_and_message() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(Method::POST).path("/chat/completions");
        then.status(401)
            .header("content-type", "application/json")
            .body("{\"error\":{\"message\":\"Authentication Fails, Your api key is invalid\"}}");
    });

    let llm = OpenAiCompatLlm::new(config_with_base(server.base_url(), false)).unwrap();
    let err = match llm.rectify(long_request()).await {
        Err(err) => err.0,
        Ok(_) => panic!("expected an error"),
    };
    assert!(err.contains("401"), "got: {err}");
    assert!(err.contains("invalid"), "got: {err}");
}

#[tokio::test]
async fn missing_api_key_is_a_clear_error() {
    let mut config = config_with_base("http://unused.invalid".into(), false);
    config.model.api_key = None;
    config.model.api_key_env = Some("SR_UNSET_TEST_KEY".into());
    let llm = OpenAiCompatLlm::new(config).unwrap();

    let err = match llm.rectify(long_request()).await {
        Err(err) => err.0,
        Ok(_) => panic!("expected an error"),
    };
    assert!(err.contains("no API key"), "got: {err}");
    assert!(err.contains("spokenrectifier.local.toml"), "got: {err}");
    assert!(err.contains("SR_UNSET_TEST_KEY"), "got: {err}");
}

#[tokio::test]
async fn midstream_error_event_fails_the_stream() {
    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"会\"}}]}\n\n\
                data: {\"error\":{\"message\":\"quota exceeded\"}}\n\n";
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(Method::POST).path("/chat/completions");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(body);
    });

    let llm = OpenAiCompatLlm::new(config_with_base(server.base_url(), false)).unwrap();
    let mut stream = llm.rectify(long_request()).await.expect("stream opens");
    assert_eq!(
        stream.next().await.unwrap().unwrap(),
        RectifyDelta::content("会".into()),
    );
    let err = match stream.next().await {
        Some(Err(err)) => err.0,
        other => panic!("expected stream error, got {other:?}"),
    };
    assert!(err.contains("quota exceeded"), "got: {err}");
}

#[tokio::test]
async fn vllm_reasoning_field_is_counted_and_never_leaked() {
    let body = concat!(
        "data: {\"choices\":[{\"delta\":{\"reasoning\":\"想\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"content\":\"会议\"}}]}\n\n",
        "data: [DONE]\n\n",
    );
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(Method::POST).path("/chat/completions");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(body);
    });

    let counter = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let llm = OpenAiCompatLlm::new(config_with_base(server.base_url(), false))
        .unwrap()
        .with_reasoning_counter(counter.clone());
    let (content, reasoning) = collect_arms(&llm, long_request()).await;
    assert_eq!(content, vec!["会议"]);
    assert_eq!(reasoning, vec!["想"]);
    assert_eq!(RectifyLlm::take_reasoning_chars(&llm), Some(1));
}

/// Official streaming-doc frames (contract §2.5): thinking block then
/// text block, closed by `message_stop`. No `[DONE]`.
fn anthropic_sse_body() -> String {
    concat!(
        "event: message_start\n",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-sonnet-5\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":25,\"output_tokens\":1}}}\n\n",
        "event: content_block_start\n",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}\n\n",
        "event: ping\n",
        "data: {\"type\":\"ping\"}\n\n",
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"想\"}}\n\n",
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds...\"}}\n\n",
        "event: content_block_stop\n",
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
        "event: content_block_start\n",
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"会议\"}}\n\n",
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"纪要\"}}\n\n",
        "event: content_block_stop\n",
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n",
        "event: message_delta\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":15}}\n\n",
        "event: message_stop\n",
        "data: {\"type\":\"message_stop\"}\n\n",
    )
    .into()
}

/// `alt=sse` GenerateContentResponse frames (contract §3.5): thought
/// part then unmarked text, no sentinel, stream ends with the body.
fn gemini_sse_body() -> String {
    concat!(
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"想\",\"thought\":true}]},\"index\":0}]}\n\n",
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"会议\"}]},\"index\":0}]}\n\n",
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"纪要\"}]},\"index\":0}]}\n\n",
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"thoughtSignature\":\"EjQKMgEM\"}]},\"finishReason\":\"STOP\",\"index\":0}],\"usageMetadata\":{\"thoughtsTokenCount\":8}}\n\n",
    )
    .into()
}

#[tokio::test]
async fn anthropic_streams_text_deltas_skips_thinking_and_stops_at_message_stop() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/v1/messages")
            .header("x-api-key", "sk-test")
            .header("anthropic-version", "2023-06-01")
            .body_contains("\"system\":\"")
            .body_contains("\"max_tokens\":");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(anthropic_sse_body());
    });

    let mut config = config_with_base(server.base_url(), false);
    config.model.format = Format::Anthropic;
    let counter = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let llm = OpenAiCompatLlm::new(config)
        .unwrap()
        .with_reasoning_counter(counter);
    let (content, reasoning) = collect_arms(&llm, long_request()).await;
    assert_eq!(content, vec!["会议", "纪要"]);
    assert_eq!(reasoning, vec!["想"]);
    assert_eq!(RectifyLlm::take_reasoning_chars(&llm), Some(1));
    mock.assert_hits(1);
}

#[tokio::test]
async fn anthropic_error_event_fails_the_stream() {
    let body = concat!(
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"会\"}}\n\n",
        "event: error\n",
        "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n",
    );
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(Method::POST).path("/v1/messages");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(body);
    });

    let mut config = config_with_base(server.base_url(), false);
    config.model.format = Format::Anthropic;
    let llm = OpenAiCompatLlm::new(config).unwrap();
    let mut stream = llm.rectify(long_request()).await.expect("stream opens");
    assert_eq!(
        stream.next().await.unwrap().unwrap(),
        RectifyDelta::content("会".into()),
    );
    let err = match stream.next().await {
        Some(Err(err)) => err.0,
        other => panic!("expected stream error, got {other:?}"),
    };
    assert!(err.contains("Overloaded"), "got: {err}");
}

#[tokio::test]
async fn gemini_streams_unmarked_parts_skips_thoughts_and_ends_with_the_body() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/models/test-model:streamGenerateContent")
            .query_param("alt", "sse")
            .header("x-goog-api-key", "sk-test")
            .body_contains("\"systemInstruction\"")
            .body_contains("\"contents\"");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(gemini_sse_body());
    });

    let mut config = config_with_base(server.base_url(), false);
    config.model.format = Format::Gemini;
    let counter = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let llm = OpenAiCompatLlm::new(config)
        .unwrap()
        .with_reasoning_counter(counter);
    let (content, reasoning) = collect_arms(&llm, long_request()).await;
    assert_eq!(content, vec!["会议", "纪要"]);
    assert_eq!(reasoning, vec!["想"]);
    assert_eq!(RectifyLlm::take_reasoning_chars(&llm), Some(1));
    mock.assert_hits(1);
}

#[tokio::test]
async fn gemini_error_object_fails_the_stream() {
    let body = concat!(
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"会\"}]}}]}\n\n",
        "data: {\"error\":{\"code\":429,\"message\":\"Resource exhausted\",\"status\":\"RESOURCE_EXHAUSTED\"}}\n\n",
    );
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(Method::POST)
            .path("/models/test-model:streamGenerateContent");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(body);
    });

    let mut config = config_with_base(server.base_url(), false);
    config.model.format = Format::Gemini;
    let llm = OpenAiCompatLlm::new(config).unwrap();
    let mut stream = llm.rectify(long_request()).await.expect("stream opens");
    assert_eq!(
        stream.next().await.unwrap().unwrap(),
        RectifyDelta::content("会".into()),
    );
    let err = match stream.next().await {
        Some(Err(err)) => err.0,
        other => panic!("expected stream error, got {other:?}"),
    };
    assert!(err.contains("Resource exhausted"), "got: {err}");
}

/// A quick-mode attempt end to end (ADR-0020): the transcript is long
/// enough for full rectify, the light-touch master switch is open, and
/// the request still goes out with the light-touch intensity section,
/// the quick extra directive in the light-touch one's place, and the
/// thinking off share. The two never-firing mocks are the negative half:
/// neither the full-rectify form nor the light-touch directive rides
/// this body.
#[tokio::test]
async fn a_quick_attempt_streams_the_light_touch_section_with_the_quick_directive() {
    let server = MockServer::start();
    let quick = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/chat/completions")
            .body_contains("轻修(本次输入较短)")
            .body_contains("【快速额外指令】")
            .body_contains("快速私货")
            .body_contains("\"thinking\":{\"type\":\"disabled\"}");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(sse_body());
    });
    let full_form = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/chat/completions")
            .body_contains("全量修正(本次输入为中长段)");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(sse_body());
    });
    let light_directive = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/chat/completions")
            .body_contains("【轻修额外指令】");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(sse_body());
    });

    let mut config = config_with_base(server.base_url(), true);
    config.rectify.light_touch.extra_directive = Some("轻修私货".into());
    config.rectify.quick.extra_directive = Some("快速私货".into());
    let llm = OpenAiCompatLlm::new(config).unwrap();

    let (content, _) = collect_arms(&llm, quick_request(&"字".repeat(40))).await;
    assert_eq!(content, vec!["会议", "纪要"]);

    quick.assert_hits(1);
    full_form.assert_hits(0);
    light_directive.assert_hits(0);
}
