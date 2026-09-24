//! The start path's latency contract (07): Recording begins the moment
//! the session exists. The stream open (microphone + provider handshake)
//! runs behind it on its own task — the command's reply, the card, and
//! every later command stay ahead of the network — and its failures
//! arrive as session-stream events, exactly like every mid-session one.

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use futures::stream::{BoxStream, StreamExt};
use tokio::sync::mpsc;
use tokio::sync::{Notify, broadcast};

use common::{await_state, next_matching};
use spokenrectifier_engine::fakes::{FakeClock, FakeInserter, ScriptedLlm};
use spokenrectifier_engine::provider::asr::{AsrEvent, AsrOpenError, AsrProvider};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, SessionState,
};

/// An ASR provider whose stream open parks on a gate: the test decides
/// when the "handshake" finishes, and can see whether it ever did. The
/// attempted channel fires the moment the open starts (before the gate),
/// so a test can prove the session is Recording while the open is still
/// provably in flight.
struct GatedAsr {
    gate: Arc<Notify>,
    attempted_tx: mpsc::UnboundedSender<()>,
    completed: Arc<AtomicBool>,
    fail: bool,
}

impl GatedAsr {
    /// Build the provider and an engine around it (pure fakes elsewhere),
    /// subscribed before any command runs. Returns the engine, the event
    /// stream, the release gate, the attempted signal, and the completion
    /// flag.
    fn engine(
        fail: bool,
    ) -> (
        Engine,
        broadcast::Receiver<EventEnvelope>,
        Arc<Notify>,
        mpsc::UnboundedReceiver<()>,
        Arc<AtomicBool>,
    ) {
        Self::engine_with(fail, EngineConfig::default())
    }

    /// [`GatedAsr::engine`] with the engine's config injected — the
    /// open-budget test needs a shrunk watchdog.
    #[allow(clippy::type_complexity)]
    fn engine_with(
        fail: bool,
        config: EngineConfig,
    ) -> (
        Engine,
        broadcast::Receiver<EventEnvelope>,
        Arc<Notify>,
        mpsc::UnboundedReceiver<()>,
        Arc<AtomicBool>,
    ) {
        let gate = Arc::new(Notify::new());
        let completed = Arc::new(AtomicBool::new(false));
        let (attempted_tx, attempted_rx) = mpsc::unbounded_channel();
        let asr = Arc::new(GatedAsr {
            gate: gate.clone(),
            attempted_tx,
            completed: completed.clone(),
            fail,
        });
        let clock = FakeClock::new(0);
        let engine = Engine::new(
            config,
            EngineDeps {
                asr,
                llm: ScriptedLlm::new(Vec::new()),
                inserter: FakeInserter::new(),
                history: None,
                terms: None,
                clock,
            },
        );
        let rx = engine.subscribe();
        (engine, rx, gate, attempted_rx, completed)
    }
}

#[async_trait::async_trait]
impl AsrProvider for GatedAsr {
    async fn open_stream(
        &self,
        _terms: &[String],
    ) -> Result<BoxStream<'static, AsrEvent>, AsrOpenError> {
        let _ = self.attempted_tx.send(());
        self.gate.notified().await;
        self.completed.store(true, Ordering::SeqCst);
        if self.fail {
            return Err(AsrOpenError("the handshake was refused".into()));
        }
        Ok(futures::stream::iter(vec![AsrEvent::Partial {
            text: "开闸后的转写".into(),
        }])
        .boxed())
    }
}

async fn ok(engine: &Engine, command: Command) {
    engine.execute(command).await.expect("command accepted");
}

#[tokio::test]
async fn recording_begins_while_the_open_is_still_in_flight() {
    let (engine, mut rx, gate, mut attempted, completed) = GatedAsr::engine(false);

    ok(&engine, Command::StartSession).await;
    // The open has started and is parked on the gate, yet the session is
    // already Recording — the reply and the card never waited for it.
    attempted.recv().await.expect("the open started");
    assert!(!completed.load(Ordering::SeqCst));
    assert_eq!(engine.state(), SessionState::Recording);

    gate.notify_one();
    let live = next_matching(&mut rx, |env| {
        matches!(env.event, EngineEvent::LiveTranscriptUpdated { .. })
    })
    .await;
    match live.event {
        EngineEvent::LiveTranscriptUpdated { text } => assert_eq!(text, "开闸后的转写"),
        _ => unreachable!("matched on the event kind above"),
    }
    assert!(completed.load(Ordering::SeqCst));
}

#[tokio::test]
async fn an_open_failure_lands_as_a_session_error_and_returns_to_idle() {
    let (engine, mut rx, gate, mut attempted, _completed) = GatedAsr::engine(true);

    ok(&engine, Command::StartSession).await;
    attempted.recv().await.expect("the open started");
    gate.notify_one();

    let error = next_matching(&mut rx, |env| {
        matches!(env.event, EngineEvent::Error { .. })
    })
    .await;
    match error.event {
        EngineEvent::Error { message } => {
            assert!(message.contains("the handshake was refused"), "{message}");
        }
        _ => unreachable!("matched on the event kind above"),
    }
    // The failed end is the cancelled one: focus restoration rides it,
    // and the engine comes back to idle instead of wedging in Recording.
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(engine.state(), SessionState::Idle);
}

#[tokio::test]
async fn a_stop_during_the_open_aborts_it_without_a_trace() {
    let (engine, mut rx, gate, mut attempted, completed) = GatedAsr::engine(false);

    ok(&engine, Command::StartSession).await;
    attempted.recv().await.expect("the open started");
    // A stop before any transcript: the speechless session is discarded
    // (Cancelled → Idle) and the open dies with it.
    ok(&engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Idle).await;

    gate.notify_one();
    // A beat for the aborted open's task to (wrongly) run to completion.
    tokio::time::sleep(Duration::from_millis(10)).await;
    assert!(
        !completed.load(Ordering::SeqCst),
        "the open must die with its session"
    );
    assert_eq!(engine.state(), SessionState::Idle);
    // Nothing it might have produced leaks out after the idle.
    assert!(matches!(
        rx.try_recv(),
        Err(broadcast::error::TryRecvError::Empty)
    ));
}

#[tokio::test]
async fn an_open_that_never_completes_fails_within_its_budget() {
    // The wedge this guards against (26 号票): the open leg's
    // collaborators can hang in ways nothing downstream can observe —
    // a device graph that never finishes opening the microphone, a
    // half-open network leg. Without a budget the session sits in
    // Recording with no events and no error; the panel listens forever.
    let config = EngineConfig {
        open_budget_ms: 50,
        ..EngineConfig::default()
    };
    let (engine, mut rx, _gate, mut attempted, completed) = GatedAsr::engine_with(false, config);

    ok(&engine, Command::StartSession).await;
    attempted.recv().await.expect("the open started");
    // The gate never opens; the budget must speak instead.
    let error = next_matching(&mut rx, |env| {
        matches!(env.event, EngineEvent::Error { .. })
    })
    .await;
    match error.event {
        EngineEvent::Error { message } => {
            assert!(message.contains("timed out"), "{message}");
        }
        _ => unreachable!("matched on the event kind above"),
    }
    // The failed end is the cancelled one — the engine must come back to
    // idle instead of wedging in Recording.
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(engine.state(), SessionState::Idle);
    assert!(
        !completed.load(Ordering::SeqCst),
        "the aborted open must never run to completion"
    );
}
