//! Bridge API surface exposed to Dart via flutter_rust_bridge.
//!
//! All functions are synchronous and quick: commands block on the owned
//! runtime, the event stream forwards from a spawned task. The `Bridge*`
//! types are the wire format mirrored to Dart — deliberately decoupled
//! from the engine's own types so the engine can evolve without breaking
//! the Dart side.
//!
//! The engine is built with all-fake collaborators (scripted ASR fed by
//! `fake_say` / `fake_silence`, scripted LLM responses passed to
//! `create_fake_engine`, recording inserter), so the shell drives the whole
//! interaction with no microphone, network, or target window.

use std::sync::{Mutex, OnceLock};

use anyhow::anyhow;
use tokio::runtime::Runtime;

use crate::frb_generated::StreamSink;

use spokenrectifier_engine::fakes::{
    AsrFeed, ChannelAsr, ChannelScripter, FakeClock, FakeInserter, LlmStep, ScriptedLlm,
};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, SessionState, Style,
};

// -- wire types ---------------------------------------------------------------

/// Dart-side mirror of [`Command`].
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeCommand {
    StartSession,
    StopSession,
    Cancel,
    ConfirmInsert,
    Reroll,
    UpdatePreviewText { text: String },
    SetStyle { style: BridgeStyle },
}

/// Dart-side mirror of [`Style`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeStyle {
    GeneralWritten,
    Prompt,
    FormalDocument,
}

/// Dart-side mirror of [`SessionState`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeSessionState {
    Idle,
    Recording,
    Rectifying,
    Preview,
    Inserted,
    Cancelled,
}

/// Dart-side mirror of [`EngineEvent`].
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeEvent {
    SessionStateChanged {
        from: BridgeSessionState,
        to: BridgeSessionState,
    },
    LiveTranscriptUpdated {
        text: String,
    },
    ParagraphMarked,
    RectifiedTextChunk {
        delta: String,
    },
    PreviewTextUpdated {
        text: String,
    },
    TextInserted {
        text: String,
    },
    Error {
        message: String,
    },
}

/// Dart-side mirror of [`EventEnvelope`].
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeEventEnvelope {
    pub seq: u64,
    pub session_id: u64,
    pub at_ms: u64,
    pub event: BridgeEvent,
}

impl From<BridgeCommand> for Command {
    fn from(value: BridgeCommand) -> Self {
        match value {
            BridgeCommand::StartSession => Command::StartSession,
            BridgeCommand::StopSession => Command::StopSession,
            BridgeCommand::Cancel => Command::Cancel,
            BridgeCommand::ConfirmInsert => Command::ConfirmInsert,
            BridgeCommand::Reroll => Command::Reroll,
            BridgeCommand::UpdatePreviewText { text } => Command::UpdatePreviewText(text),
            BridgeCommand::SetStyle { style } => Command::SetStyle(style.into()),
        }
    }
}

impl From<BridgeStyle> for Style {
    fn from(value: BridgeStyle) -> Self {
        match value {
            BridgeStyle::GeneralWritten => Style::GeneralWritten,
            BridgeStyle::Prompt => Style::Prompt,
            BridgeStyle::FormalDocument => Style::FormalDocument,
        }
    }
}

impl From<Style> for BridgeStyle {
    fn from(value: Style) -> Self {
        match value {
            Style::GeneralWritten => BridgeStyle::GeneralWritten,
            Style::Prompt => BridgeStyle::Prompt,
            Style::FormalDocument => BridgeStyle::FormalDocument,
        }
    }
}

impl From<SessionState> for BridgeSessionState {
    fn from(value: SessionState) -> Self {
        match value {
            SessionState::Idle => BridgeSessionState::Idle,
            SessionState::Recording => BridgeSessionState::Recording,
            SessionState::Rectifying => BridgeSessionState::Rectifying,
            SessionState::Preview => BridgeSessionState::Preview,
            SessionState::Inserted => BridgeSessionState::Inserted,
            SessionState::Cancelled => BridgeSessionState::Cancelled,
        }
    }
}

impl From<EngineEvent> for BridgeEvent {
    fn from(value: EngineEvent) -> Self {
        match value {
            EngineEvent::SessionStateChanged { from, to } => BridgeEvent::SessionStateChanged {
                from: from.into(),
                to: to.into(),
            },
            EngineEvent::LiveTranscriptUpdated { text } => {
                BridgeEvent::LiveTranscriptUpdated { text }
            }
            EngineEvent::ParagraphMarked => BridgeEvent::ParagraphMarked,
            EngineEvent::RectifiedTextChunk { delta } => BridgeEvent::RectifiedTextChunk { delta },
            EngineEvent::PreviewTextUpdated { text } => BridgeEvent::PreviewTextUpdated { text },
            EngineEvent::TextInserted { text } => BridgeEvent::TextInserted { text },
            EngineEvent::Error { message } => BridgeEvent::Error { message },
        }
    }
}

impl From<EventEnvelope> for BridgeEventEnvelope {
    fn from(value: EventEnvelope) -> Self {
        BridgeEventEnvelope {
            seq: value.seq,
            session_id: value.session_id.0,
            at_ms: value.at_ms,
            event: value.event.into(),
        }
    }
}

// -- bridge state --------------------------------------------------------------

struct Global {
    rt: Runtime,
    engine: Engine,
    scripter: ChannelScripter,
    inserter: std::sync::Arc<FakeInserter>,
    /// Feed of the currently open fake ASR session, if recording.
    feed: Mutex<Option<AsrFeed>>,
}

static GLOBAL: OnceLock<Global> = OnceLock::new();

fn global() -> anyhow::Result<&'static Global> {
    GLOBAL
        .get()
        .ok_or_else(|| anyhow!("engine not created yet; call create_fake_engine first"))
}

// -- api ------------------------------------------------------------------------

/// Build the engine behind the bridge with all-fake collaborators.
/// `llm_responses` become the scripted rectify responses (streamed in small
/// chunks), repeating forever — the demo host never runs dry no matter how
/// many sessions or rerolls come. Idempotent: a second call is a no-op.
pub fn create_fake_engine(llm_responses: Vec<String>) -> anyhow::Result<()> {
    if GLOBAL.get().is_some() {
        return Ok(());
    }
    let scripts: Vec<Vec<LlmStep>> = llm_responses
        .iter()
        .map(|text| {
            let chars: Vec<char> = text.chars().collect();
            chars
                .chunks(4)
                .map(|chunk| LlmStep::Token(chunk.iter().collect()))
                .collect()
        })
        .collect();
    let (asr, scripter) = ChannelAsr::new();
    let llm = ScriptedLlm::new_cycling(scripts);
    let inserter = FakeInserter::new();
    let engine = Engine::new(
        EngineConfig::default(),
        EngineDeps {
            asr,
            llm,
            inserter: inserter.clone(),
            clock: FakeClock::new(0),
        },
    );
    let _ = GLOBAL.set(Global {
        rt: Runtime::new()?,
        engine,
        scripter,
        inserter,
        feed: Mutex::new(None),
    });
    Ok(())
}

/// Submit a command to the engine. Returns an error only for rejected
/// commands (wrong state); asynchronous outcomes arrive on the event stream.
pub fn execute(command: BridgeCommand) -> anyhow::Result<()> {
    let g = global()?;
    // Ending a session also ends its fake speech feed.
    if matches!(command, BridgeCommand::StopSession | BridgeCommand::Cancel) {
        *g.feed.lock().unwrap() = None;
    }
    g.rt.block_on(g.engine.execute(command.into()))?;
    Ok(())
}

/// Current session state, for initial paint before any event arrives.
pub fn state() -> anyhow::Result<BridgeSessionState> {
    Ok(global()?.engine.state().into())
}

/// Everything the fake inserter received, in order (demo introspection).
pub fn inserted_texts() -> anyhow::Result<Vec<String>> {
    Ok(global()?.inserter.inserted_texts())
}

/// Subscribe the Dart side to the engine's event stream. Each call spawns
/// an independent forwarder; dropping the Dart stream stops it.
pub fn subscribe(sink: StreamSink<BridgeEventEnvelope>) -> anyhow::Result<()> {
    let g = global()?;
    let mut rx = g.engine.subscribe();
    g.rt.spawn(async move {
        loop {
            match rx.recv().await {
                Ok(envelope) => {
                    if sink.add(envelope.into()).is_err() {
                        break; // Dart side gone
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

/// Open the next fake ASR session and allow `fake_say` / `fake_silence` to
/// feed it. Call before `execute(BridgeCommand::StartSession)`.
pub fn fake_begin_session() -> anyhow::Result<()> {
    let g = global()?;
    *g.feed.lock().unwrap() = Some(g.scripter.begin_session());
    Ok(())
}

/// Feed one scripted phrase (partial, then final) into the open session.
pub fn fake_say(text: String) -> anyhow::Result<()> {
    let g = global()?;
    let feed = g
        .feed
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| anyhow!("no fake session open; call fake_begin_session first"))?;
    g.rt.block_on(feed.say(&text));
    Ok(())
}

/// Feed one scripted cumulative-silence event (milliseconds) into the open
/// session.
pub fn fake_silence(elapsed_ms: u64) -> anyhow::Result<()> {
    let g = global()?;
    let feed = g
        .feed
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| anyhow!("no fake session open; call fake_begin_session first"))?;
    g.rt.block_on(feed.silence(elapsed_ms));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bridge is a process-wide singleton: serialize the tests.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    async fn wait_for<F>(
        rx: &mut tokio::sync::broadcast::Receiver<EventEnvelope>,
        predicate: F,
    ) -> EventEnvelope
    where
        F: Fn(&EngineEvent) -> bool,
    {
        loop {
            let envelope = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv())
                .await
                .expect("event within timeout")
                .expect("channel open");
            if predicate(&envelope.event) {
                return envelope;
            }
        }
    }

    async fn wait_state(
        rx: &mut tokio::sync::broadcast::Receiver<EventEnvelope>,
        want: SessionState,
    ) {
        wait_for(
            rx,
            |event| matches!(event, EngineEvent::SessionStateChanged { to, .. } if *to == want),
        )
        .await;
    }

    /// Wait on the bridge's own runtime: the tests run on plain threads so
    /// the bridge's `block_on` calls never nest inside another runtime.
    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        global().unwrap().rt.block_on(future)
    }

    fn setup() {
        // One shared engine for all tests: queue enough scripted LLM
        // responses for every session any test will run.
        create_fake_engine(vec!["修正后的书面文本".to_string(); 16]).unwrap();
    }

    #[test]
    fn full_flow_through_the_bridge_api() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        let mut rx = global().unwrap().engine.subscribe();

        fake_begin_session().unwrap();
        execute(BridgeCommand::StartSession).unwrap();
        fake_say("嗯那个原话".into()).unwrap();
        fake_silence(1300).unwrap();
        block_on(wait_for(
            &mut rx,
            |event| matches!(event, EngineEvent::LiveTranscriptUpdated { text } if text.contains("嗯那个原话")),
        ));

        execute(BridgeCommand::StopSession).unwrap();
        block_on(wait_state(&mut rx, SessionState::Preview));

        execute(BridgeCommand::ConfirmInsert).unwrap();
        block_on(wait_state(&mut rx, SessionState::Idle));

        // The inserter is shared across tests: assert the latest entry.
        assert_eq!(
            inserted_texts().unwrap().last(),
            Some(&"修正后的书面文本".to_string())
        );
        assert_eq!(state().unwrap(), BridgeSessionState::Idle);
    }

    #[test]
    fn commands_rejected_outside_the_bridge_report_errors() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        let err = execute(BridgeCommand::StopSession).unwrap_err().to_string();
        assert!(err.contains("rejected"), "got: {err}");
        assert_eq!(state().unwrap(), BridgeSessionState::Idle);
    }

    /// The demo host runs indefinitely: sessions keep working no matter how
    /// many rectify attempts came before. Past the scripted queue, a failed
    /// rectify surfaces as an Error event (never Preview), then Idle.
    #[test]
    fn repeated_sessions_never_run_dry() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        let mut rx = global().unwrap().engine.subscribe();

        // More sessions than the queued script count (setup queues 16).
        for session in 1..=20 {
            fake_begin_session().unwrap();
            execute(BridgeCommand::StartSession).unwrap();
            fake_say("第几场".into()).unwrap();
            fake_silence(1300).unwrap();
            block_on(wait_for(
                &mut rx,
                |event| matches!(event, EngineEvent::LiveTranscriptUpdated { text } if text.contains("第几场")),
            ));

            execute(BridgeCommand::StopSession).unwrap();
            let outcome = block_on(wait_for(
                &mut rx,
                |event| {
                    matches!(
                        event,
                        EngineEvent::SessionStateChanged { to: SessionState::Preview, .. }
                            | EngineEvent::Error { .. }
                    )
                },
            ));
            if let EngineEvent::Error { message } = outcome.event {
                panic!("session {session} failed after stop: {message}");
            }

            execute(BridgeCommand::ConfirmInsert).unwrap();
            block_on(wait_state(&mut rx, SessionState::Idle));
        }
        assert_eq!(
            inserted_texts().unwrap().last(),
            Some(&"修正后的书面文本".to_string())
        );
    }

    #[test]
    fn fake_say_without_a_session_is_an_error() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        assert!(fake_say("没人听".into()).is_err());
    }

    #[test]
    fn create_is_idempotent() {
        let _guard = TEST_LOCK.lock().unwrap();
        setup();
        create_fake_engine(vec!["第二次".into()]).unwrap();
        // The first engine's queue is still in effect.
        let mut rx = global().unwrap().engine.subscribe();
        fake_begin_session().unwrap();
        execute(BridgeCommand::StartSession).unwrap();
        fake_say("话".into()).unwrap();
        block_on(wait_for(
            &mut rx,
            |event| matches!(event, EngineEvent::LiveTranscriptUpdated { text } if text == "话"),
        ));
        execute(BridgeCommand::StopSession).unwrap();
        block_on(wait_state(&mut rx, SessionState::Preview));
        execute(BridgeCommand::ConfirmInsert).unwrap();
        block_on(wait_state(&mut rx, SessionState::Idle));
        assert_eq!(
            inserted_texts().unwrap().last(),
            Some(&"修正后的书面文本".to_string())
        );
    }

    #[test]
    fn wire_types_mirror_every_engine_variant() {
        // One representative of each engine event maps onto the wire.
        let cases = vec![
            EngineEvent::SessionStateChanged {
                from: SessionState::Idle,
                to: SessionState::Recording,
            },
            EngineEvent::LiveTranscriptUpdated {
                text: "你好".into(),
            },
            EngineEvent::ParagraphMarked,
            EngineEvent::RectifiedTextChunk {
                delta: "好".into()
            },
            EngineEvent::PreviewTextUpdated {
                text: "好的".into(),
            },
            EngineEvent::TextInserted {
                text: "好的".into(),
            },
            EngineEvent::Error {
                message: "挂了".into(),
            },
        ];
        for event in cases {
            // Every variant maps without panicking; names stay 1:1.
            let _bridge: BridgeEvent = event.into();
        }
        // Spot-check the two variants whose payloads can drift silently.
        let mapped: BridgeEvent = EngineEvent::SessionStateChanged {
            from: SessionState::Recording,
            to: SessionState::Rectifying,
        }
        .into();
        assert_eq!(
            mapped,
            BridgeEvent::SessionStateChanged {
                from: BridgeSessionState::Recording,
                to: BridgeSessionState::Rectifying,
            }
        );
        let mapped: BridgeEvent = EngineEvent::RectifiedTextChunk {
            delta: "字".into()
        }
        .into();
        assert_eq!(
            mapped,
            BridgeEvent::RectifiedTextChunk {
                delta: "字".into()
            }
        );
        let envelope = EventEnvelope {
            seq: 7,
            session_id: spokenrectifier_engine::SessionId(3),
            at_ms: 1_000,
            event: EngineEvent::ParagraphMarked,
        };
        let bridge: BridgeEventEnvelope = envelope.into();
        assert_eq!(bridge.seq, 7);
        assert_eq!(bridge.session_id, 3);
        assert_eq!(bridge.at_ms, 1_000);
        assert_eq!(bridge.event, BridgeEvent::ParagraphMarked);
    }
}
