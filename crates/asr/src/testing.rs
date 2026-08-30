//! The scripted-connection harness every cloud adapter's tests run on
//! (the transport twin of `spokenrectifier_engine::fakes`): plan the
//! `connect()` calls, watch what the adapter sends, feed it server
//! messages, and script the microphone — both directions through plain
//! channels, which is what keeps each adapter's protocol logic
//! deterministic.
//!
//! Generic over the wire message `M`, so the JSON dialects (`String`)
//! and the framed dialects (`Vec<u8>`) share one harness.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;
use tokio::sync::mpsc;

use spokenrectifier_audio::{FrameSource, MicEvent};
use spokenrectifier_engine::provider::asr::AsrEvent;

use crate::transport::{ConnectError, RealtimeChannel, RealtimeConnect};

/// What one planned `connect()` does.
pub enum PlanEntry<M> {
    /// A live channel; `release` gates when `connect()` resolves, so a
    /// test can hold a reconnect open while frames keep arriving.
    Live {
        channel: RealtimeChannel<M>,
        release: Option<mpsc::Receiver<()>>,
    },
    /// Fail before the session begins (auth, unreachable).
    Fail(ConnectError),
}

/// The halves of a planned connection the test keeps: watch what the
/// adapter sends (`observe`), feed it server messages (`feed`). The
/// observer lock is async — watching holds it across awaits.
#[derive(Clone)]
pub struct ConnHandles<M> {
    pub observe: Arc<tokio::sync::Mutex<mpsc::Receiver<M>>>,
    pub feed: mpsc::Sender<Result<M, String>>,
}

/// Plumb one planned live connection.
pub fn live_conn<M>(release: Option<mpsc::Receiver<()>>) -> (PlanEntry<M>, ConnHandles<M>) {
    let (client_tx, observe) = mpsc::channel(64);
    let (feed, client_rx) = mpsc::channel(64);
    (
        PlanEntry::Live {
            channel: RealtimeChannel {
                tx: client_tx,
                rx: client_rx,
            },
            release,
        },
        ConnHandles {
            observe: Arc::new(tokio::sync::Mutex::new(observe)),
            feed,
        },
    )
}

/// A [`RealtimeConnect`] playing a scripted plan of connections.
#[derive(Clone, Default)]
pub struct ScriptedConnect<M> {
    plan: Arc<Mutex<VecDeque<PlanEntry<M>>>>,
    connect_count: Arc<AtomicUsize>,
}

impl<M> ScriptedConnect<M> {
    /// The plan, in call order.
    pub fn new(plan: Vec<PlanEntry<M>>) -> Self {
        Self {
            plan: Arc::new(Mutex::new(plan.into())),
            connect_count: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// How many `connect()` calls came in.
    pub fn connect_count(&self) -> usize {
        self.connect_count.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl<M: Send + 'static> RealtimeConnect<M> for ScriptedConnect<M> {
    async fn connect(&self) -> Result<RealtimeChannel<M>, ConnectError> {
        self.connect_count.fetch_add(1, Ordering::SeqCst);
        let entry = self.plan.lock().unwrap().pop_front();
        match entry {
            Some(PlanEntry::Fail(err)) => Err(err),
            Some(PlanEntry::Live { channel, release }) => {
                if let Some(mut release) = release {
                    let _ = release.recv().await;
                }
                Ok(channel)
            }
            None => Err(ConnectError::Other("no more planned connections".into())),
        }
    }
}

/// A frame-source factory that scripts one mic session. With
/// `stay_open` the channel stays open after the script — a healthy
/// capture has no end-of-stream — so tests can keep feeding server
/// messages into a live session.
pub fn scripted_source(sends: Vec<MicEvent>, stay_open: bool) -> FrameSource {
    paced_source(sends, stay_open, None)
}

/// Like [`scripted_source`], but pacing frames `delay` apart so
/// wall-clock arms (a keepalive tick) get their turn.
pub fn paced_source(sends: Vec<MicEvent>, stay_open: bool, delay: Option<Duration>) -> FrameSource {
    Arc::new(move || {
        let (tx, rx) = std::sync::mpsc::channel();
        let script = sends.clone();
        std::thread::spawn(move || {
            for event in script {
                if let Some(delay) = delay {
                    std::thread::sleep(delay);
                }
                if tx.send(event).is_err() {
                    return;
                }
            }
            if stay_open {
                std::mem::forget(tx); // leak the sender: no end signal
            }
        });
        Ok(rx)
    })
}

/// Collect adapter events until the stream ends, a `Failed` lands, or
/// the deadline passes.
pub async fn collect(mut stream: BoxStream<'static, AsrEvent>) -> Vec<AsrEvent> {
    let mut events = Vec::new();
    while let Ok(Some(event)) =
        tokio::time::timeout(Duration::from_millis(800), stream.next()).await
    {
        let failed = matches!(event, AsrEvent::Failed { .. });
        events.push(event);
        if failed {
            break;
        }
    }
    events
}

/// Await at least one adapter-sent message matching `pred` (the JSON
/// dialects parse inside the predicate; the framed ones match on
/// shape) — the observer-side waiter every adapter's wire tests need.
pub async fn sent_matching<M>(
    observe: &Arc<tokio::sync::Mutex<mpsc::Receiver<M>>>,
    pred: impl Fn(&M) -> bool,
) -> M {
    let mut observe = observe.lock().await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while let Ok(Some(message)) = tokio::time::timeout_at(deadline, observe.recv()).await {
        if pred(&message) {
            return message;
        }
    }
    panic!("no matching message arrived in time");
}

/// One frame's little-endian PCM bytes — how every PCM dialect here
/// puts audio on the wire.
pub fn pcm_le_bytes(frame: &[i16]) -> Vec<u8> {
    frame.iter().flat_map(|s| s.to_le_bytes()).collect()
}
