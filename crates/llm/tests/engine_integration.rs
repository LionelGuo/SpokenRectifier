//! The rectify pipeline wired into the engine seam: a scripted utterance
//! flows through the real client (against a mock endpoint) and comes back
//! as RectifiedTextChunk events, a Preview, and an insertion.

use std::sync::Arc;
use std::time::Duration;

use httpmock::{Method, MockServer};
use spokenrectifier_engine::fakes::{AsrStep, FakeClock, FakeInserter, ScriptedAsr};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, SessionState,
};
mod common;

use common::{config_with_base, mock_backed_llm};

async fn next_event(rx: &mut tokio::sync::broadcast::Receiver<EventEnvelope>) -> EventEnvelope {
    tokio::time::timeout(Duration::from_secs(2), rx.recv())
        .await
        .expect("event within timeout")
        .expect("channel open")
}

#[tokio::test]
async fn utterance_flows_through_the_real_client_to_preview_and_insert() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(Method::POST)
            .path("/chat/completions")
            .body_contains("嗯那个明天开会");
        then.status(200)
            .header("content-type", "text/event-stream")
            .body(concat!(
                "data: {\"choices\":[{\"delta\":{\"content\":\"明天\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"开会\"}}]}\n\n",
                "data: [DONE]\n\n",
            ));
    });

    let inserter = FakeInserter::new();
    let engine = Engine::new(
        EngineConfig::default(),
        EngineDeps {
            // The fake constructors already return Arc<Self>.
            asr: ScriptedAsr::new(vec![vec![AsrStep::Say("嗯那个明天开会".into())]]),
            llm: Arc::new(mock_backed_llm(config_with_base(server.base_url(), false))),
            inserter: inserter.clone(),
            clock: FakeClock::new(1_000),
        },
    );
    let mut rx = engine.subscribe();

    engine.execute(Command::StartSession).await.unwrap();
    // Drain the live transcript before stopping: the ASR fake is instant.
    loop {
        let env = next_event(&mut rx).await;
        if let EngineEvent::LiveTranscriptUpdated { text } = &env.event
            && text == "嗯那个明天开会"
        {
            break;
        }
    }
    engine.execute(Command::StopSession).await.unwrap();

    let mut chunks = Vec::new();
    loop {
        let env = next_event(&mut rx).await;
        match env.event {
            EngineEvent::RectifiedTextChunk { delta } => chunks.push(delta),
            // Preview entry itself does not announce the text: the UI
            // accumulates the chunks it already saw.
            EngineEvent::SessionStateChanged {
                to: SessionState::Preview,
                ..
            } => break,
            _ => {}
        }
    }
    assert_eq!(chunks, vec!["明天", "开会"]);

    engine.execute(Command::ConfirmInsert).await.unwrap();
    loop {
        let env = next_event(&mut rx).await;
        if let EngineEvent::SessionStateChanged { to, .. } = env.event
            && to == SessionState::Idle
        {
            break;
        }
    }
    assert_eq!(inserter.inserted_texts(), vec!["明天开会"]);
    assert_eq!(engine.state(), SessionState::Idle);
    mock.assert_hits(1);
}
