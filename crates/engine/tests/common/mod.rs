//! Shared harness for the deterministic seam tests: everything rides the
//! engine public API only (commands in, events out), with fakes injected.
//! Not every test binary uses every helper or harness field.

#![allow(dead_code)]

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::broadcast;
use tokio::time::timeout;

use spokenrectifier_engine::fakes::{
    AsrFeed, AsrStep, ChannelAsr, ChannelScripter, FakeClock, FakeInserter, LlmStep, ScriptedAsr,
    ScriptedLlm,
};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EventEnvelope, SessionRecorder, SessionState,
    TermSource,
};

pub struct Harness {
    pub engine: Engine,
    pub asr: Arc<ScriptedAsr>,
    pub llm: Arc<ScriptedLlm>,
    pub inserter: Arc<FakeInserter>,
    pub clock: Arc<FakeClock>,
}

/// Build an engine with fakes and subscribe to its event stream before any
/// command runs.
pub fn harness(
    config: EngineConfig,
    asr_sessions: Vec<Vec<AsrStep>>,
    llm_scripts: Vec<Vec<LlmStep>>,
) -> (Harness, broadcast::Receiver<EventEnvelope>) {
    harness_with(config, asr_sessions, llm_scripts, None, None)
}

/// [`harness`] with a session-history recorder injected.
pub fn harness_with_history(
    config: EngineConfig,
    asr_sessions: Vec<Vec<AsrStep>>,
    llm_scripts: Vec<Vec<LlmStep>>,
    history: Option<Arc<dyn SessionRecorder>>,
) -> (Harness, broadcast::Receiver<EventEnvelope>) {
    harness_with(config, asr_sessions, llm_scripts, history, None)
}

/// [`harness`] with a hotword dictionary source injected.
pub fn harness_with_terms(
    config: EngineConfig,
    asr_sessions: Vec<Vec<AsrStep>>,
    llm_scripts: Vec<Vec<LlmStep>>,
    terms: Arc<dyn TermSource>,
) -> (Harness, broadcast::Receiver<EventEnvelope>) {
    harness_with(config, asr_sessions, llm_scripts, None, Some(terms))
}

fn harness_with(
    config: EngineConfig,
    asr_sessions: Vec<Vec<AsrStep>>,
    llm_scripts: Vec<Vec<LlmStep>>,
    history: Option<Arc<dyn SessionRecorder>>,
    terms: Option<Arc<dyn TermSource>>,
) -> (Harness, broadcast::Receiver<EventEnvelope>) {
    let asr = ScriptedAsr::new(asr_sessions);
    let llm = ScriptedLlm::new(llm_scripts);
    let inserter = FakeInserter::new();
    let clock = FakeClock::new(1_000);
    let engine = Engine::new(
        config,
        EngineDeps {
            asr: asr.clone(),
            llm: llm.clone(),
            inserter: inserter.clone(),
            history,
            terms,
            clock: clock.clone(),
        },
    );
    let rx = engine.subscribe();
    (
        Harness {
            engine,
            asr,
            llm,
            inserter,
            clock,
        },
        rx,
    )
}

/// Wait for the next envelope matching `pred`, skipping non-matching ones.
/// Panics after 2 s (the engine is instant under fakes, so any wait means
/// a bug, not slowness).
pub async fn next_matching(
    rx: &mut broadcast::Receiver<EventEnvelope>,
    pred: impl Fn(&EventEnvelope) -> bool,
) -> EventEnvelope {
    loop {
        let received = timeout(Duration::from_secs(2), rx.recv()).await;
        match received {
            Ok(Ok(envelope)) if pred(&envelope) => return envelope,
            Ok(Ok(_)) => continue,
            Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
            Ok(Err(broadcast::error::RecvError::Closed)) => {
                panic!("event stream closed before a matching event arrived")
            }
            Err(_) => panic!("timed out waiting for a matching event"),
        }
    }
}

/// Wait until the engine reaches `state`.
pub async fn await_state(rx: &mut broadcast::Receiver<EventEnvelope>, state: SessionState) {
    next_matching(rx, |env| {
        matches!(
            &env.event,
            spokenrectifier_engine::EngineEvent::SessionStateChanged { to, .. } if *to == state
        )
    })
    .await;
}

/// Wait for the cumulative live transcript to reach `text`. Because the
/// scripted ASR drains instantly, this is also how a test proves the whole
/// script was consumed before issuing `StopSession`.
pub async fn await_live(rx: &mut broadcast::Receiver<EventEnvelope>, text: &str) {
    next_matching(rx, |env| {
        matches!(
            &env.event,
            spokenrectifier_engine::EngineEvent::LiveTranscriptUpdated { text: t } if t == text
        )
    })
    .await;
}

/// Drain a fed phrase's two live frames (interim + final) so a following
/// command is deterministic: a pin issued after the first frame would
/// land before the phrase's final text, not after it.
pub async fn drain_said(rx: &mut broadcast::Receiver<EventEnvelope>, text: &str) {
    await_live(rx, text).await;
    await_live(rx, text).await;
}

/// Channel-driven harness: one fake ASR session queued up front (more via
/// [`ChanHarness::begin_session`]), the rest of the fakes as in
/// [`harness`]. For tests that must interleave commands with transcript
/// events at exact points — the scripted ASR drains its whole script
/// before any command lands.
pub struct ChanHarness {
    pub engine: Engine,
    pub scripter: ChannelScripter,
    pub feed: AsrFeed,
    pub llm: Arc<ScriptedLlm>,
}

/// Build a [`ChanHarness`] and queue its first fake ASR session.
pub fn chan_harness(config: EngineConfig, llm_scripts: Vec<Vec<LlmStep>>) -> ChanHarness {
    let (asr, scripter) = ChannelAsr::new();
    let llm = ScriptedLlm::new(llm_scripts);
    let inserter = FakeInserter::new();
    let engine = Engine::new(
        config,
        EngineDeps {
            asr,
            llm: llm.clone(),
            inserter,
            history: None,
            terms: None,
            clock: FakeClock::new(1_000),
        },
    );
    let feed = scripter.begin_session();
    ChanHarness {
        engine,
        scripter,
        feed,
        llm,
    }
}

impl ChanHarness {
    /// Queue the next fake ASR session and hand back its feed.
    pub fn begin_session(&self) -> AsrFeed {
        self.scripter.begin_session()
    }
}

/// Assert that no further event arrives within `ms` (lets spawned tasks
/// settle so absence assertions are meaningful).
pub async fn expect_quiet(rx: &mut broadcast::Receiver<EventEnvelope>, ms: u64) {
    match timeout(Duration::from_millis(ms), rx.recv()).await {
        Ok(Ok(envelope)) => panic!("expected no more events, got {:?}", envelope),
        Ok(Err(broadcast::error::RecvError::Lagged(_))) => {}
        Ok(Err(broadcast::error::RecvError::Closed)) => {}
        Err(_) => {}
    }
}

/// Run a command and assert it is accepted.
pub async fn ok(engine: &Engine, command: Command) {
    engine
        .execute(command)
        .await
        .expect("command should be accepted");
}

/// One compact line per event, for whole-sequence assertions.
pub fn summarize(events: &[EventEnvelope]) -> Vec<String> {
    use spokenrectifier_engine::EngineEvent;
    events
        .iter()
        .map(|env| match &env.event {
            EngineEvent::SessionStateChanged { from, to } => {
                format!("state {from}->{to}")
            }
            EngineEvent::LiveTranscriptUpdated { text } => format!("live {text:?}"),
            EngineEvent::ParagraphMarked => "paragraph".to_string(),
            EngineEvent::SpeechActivityChanged { speaking } => format!("speech {speaking}"),
            EngineEvent::RectifiedTextChunk { delta } => format!("chunk {delta:?}"),
            EngineEvent::PreviewTextUpdated { text } => format!("preview {text:?}"),
            EngineEvent::TextInserted { text } => format!("inserted {text:?}"),
            EngineEvent::Error { message } => format!("error {message:?}"),
        })
        .collect()
}

/// Drain a dedicated collector receiver into the summarized sequence:
/// `assert_eq!(collect_summary(&mut rx_all), vec![...])`.
pub fn collect_summary(rx: &mut broadcast::Receiver<EventEnvelope>) -> Vec<String> {
    let mut events = Vec::new();
    while let Ok(envelope) = rx.try_recv() {
        events.push(envelope);
    }
    summarize(&events)
}
