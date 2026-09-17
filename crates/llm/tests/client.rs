//! The OpenAI-compatible client against a mock server: request shape
//! (auth, single model, thinking field), SSE streaming, error mapping.

mod common;

use common::{config_with_base, long_request, request};
use futures::StreamExt;
use httpmock::{Method, MockServer};
use spokenrectifier_engine::provider::llm::{RectifyLlm, RectifyRequest};
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

async fn collect(llm: &OpenAiCompatLlm, request: RectifyRequest) -> Vec<String> {
    let stream = llm.rectify(request).await.expect("stream opens");
    stream
        .map(|item| item.expect("delta"))
        .collect::<Vec<String>>()
        .await
}

#[tokio::test]
async fn streams_content_deltas_in_order_and_skips_reasoning() {
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
    let deltas = collect(&llm, long_request()).await;

    assert_eq!(deltas, vec!["会议", "纪要"]);
    mock.assert_hits(1);
}

#[tokio::test]
async fn thinking_on_sends_the_enabled_pair() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/chat/completions")
            .body_contains("\"thinking\":{\"type\":\"enabled\"}")
            .body_contains("\"reasoning_effort\":\"medium\"");
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
    assert_eq!(stream.next().await.unwrap().unwrap(), "会");
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
    let deltas = collect(&llm, long_request()).await;
    assert_eq!(deltas, vec!["会议"]);
    assert_eq!(RectifyLlm::take_reasoning_chars(&llm), Some(1));
}

#[tokio::test]
async fn anthropic_and_gemini_formats_post_to_their_own_path_and_headers() {
    // Ticket 02 lands the request shape; ticket 03 swaps the SSE
    // dialect. The openai_chat decoder still reads the mock body.
    let server = MockServer::start();
    let anthropic = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/v1/messages")
            .header("x-api-key", "sk-test")
            .header("anthropic-version", "2023-06-01")
            .body_contains("\"system\":\"")
            .body_contains("\"max_tokens\":");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(sse_body());
    });
    let gemini = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/models/test-model:streamGenerateContent")
            .query_param("alt", "sse")
            .header("x-goog-api-key", "sk-test")
            .body_contains("\"systemInstruction\"")
            .body_contains("\"contents\"");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(sse_body());
    });

    let mut anthropic_config = config_with_base(server.base_url(), false);
    anthropic_config.model.format = Format::Anthropic;
    let llm = OpenAiCompatLlm::new(anthropic_config).unwrap();
    collect(&llm, long_request()).await;
    anthropic.assert_hits(1);

    let mut gemini_config = config_with_base(server.base_url(), false);
    gemini_config.model.format = Format::Gemini;
    let llm = OpenAiCompatLlm::new(gemini_config).unwrap();
    collect(&llm, long_request()).await;
    gemini.assert_hits(1);
}
