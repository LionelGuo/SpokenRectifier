//! Scriptable fakes for the collaborator seams.
//!
//! Used by the deterministic test suite and the `sr-replay` CLI driver. No
//! network, no audio devices, no real time.

use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use async_trait::async_trait;
use futures::stream::{self, BoxStream};
use futures::{Stream, StreamExt};
use tokio::sync::mpsc;

use crate::clock::Clock;
use crate::provider::asr::{AsrEvent, AsrOpenError, AsrProvider};
use crate::provider::inserter::{InsertError, TextInserter};
use crate::provider::llm::{RectifyError, RectifyLlm, RectifyRequest, RectifyTokenStream};

// ---------------------------------------------------------------------------
// ScriptedAsr
// ---------------------------------------------------------------------------

/// One scripted ASR step.
#[derive(Debug, Clone)]
pub enum AsrStep {
    /// Speech: emits a partial, then a final, with the same text.
    Say(String),
    /// Interim speech that never finalizes (the user stopped talking
    /// mid-word).
    Partial(String),
    /// Reports cumulative silence of `elapsed_ms` since the last speech.
    Silence(u64),
    /// Reports a VAD speech-activity change.
    Speech(bool),
    /// Fails the stream mid-session.
    Fail(String),
}

/// Fake ASR provider: each `open_stream` consumes the next scripted session
/// and replays its steps instantly, in order. The dictionary handed to each
/// `open_stream` is recorded, so tests can assert the hotword path's
/// payload.
pub struct ScriptedAsr {
    sessions: Mutex<VecDeque<Vec<AsrStep>>>,
    opened_terms: Mutex<Vec<Vec<String>>>,
}

impl ScriptedAsr {
    pub fn new(sessions: Vec<Vec<AsrStep>>) -> Arc<Self> {
        Arc::new(Self {
            sessions: Mutex::new(sessions.into()),
            opened_terms: Mutex::new(Vec::new()),
        })
    }

    pub fn remaining_sessions(&self) -> usize {
        self.sessions.lock().unwrap().len()
    }

    /// The terms each opened stream received, in open order.
    pub fn opened_terms(&self) -> Vec<Vec<String>> {
        self.opened_terms.lock().unwrap().clone()
    }
}

#[async_trait]
impl AsrProvider for ScriptedAsr {
    async fn open_stream(
        &self,
        terms: &[String],
    ) -> Result<BoxStream<'static, AsrEvent>, AsrOpenError> {
        self.opened_terms.lock().unwrap().push(terms.to_vec());
        let script = self
            .sessions
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| AsrOpenError("no scripted ASR session left".into()))?;
        let events = script
            .into_iter()
            .flat_map(|step| match step {
                AsrStep::Say(text) => vec![
                    AsrEvent::Partial { text: text.clone() },
                    AsrEvent::Final { text },
                ],
                AsrStep::Partial(text) => vec![AsrEvent::Partial { text }],
                AsrStep::Silence(elapsed_ms) => vec![AsrEvent::Silence { elapsed_ms }],
                AsrStep::Speech(speaking) => vec![AsrEvent::SpeechActivity { speaking }],
                AsrStep::Fail(message) => vec![AsrEvent::Failed { message }],
            })
            .collect::<Vec<_>>();
        Ok(stream::iter(events).boxed())
    }
}

// ---------------------------------------------------------------------------
// ChannelAsr
// ---------------------------------------------------------------------------

/// Channel-driven fake ASR: sessions are fed event by event at replay time
/// instead of all at once, so a driver's script lines advance the world
/// step by step, like real speech does.
pub struct ChannelAsr {
    pending: Mutex<VecDeque<mpsc::Receiver<AsrEvent>>>,
}

/// Handle for feeding one fake ASR session. Dropping it ends the stream.
#[derive(Clone)]
pub struct AsrFeed {
    tx: mpsc::Sender<AsrEvent>,
}

impl AsrFeed {
    pub async fn say(&self, text: &str) {
        let _ = self.tx.send(AsrEvent::Partial { text: text.into() }).await;
        let _ = self.tx.send(AsrEvent::Final { text: text.into() }).await;
    }

    pub async fn silence(&self, elapsed_ms: u64) {
        let _ = self.tx.send(AsrEvent::Silence { elapsed_ms }).await;
    }
}

/// Creates sessions for [`ChannelAsr`] before the engine opens them.
pub struct ChannelScripter {
    asr: Arc<ChannelAsr>,
}

impl ChannelScripter {
    /// Queue one session and return its feed.
    pub fn begin_session(&self) -> AsrFeed {
        let (tx, rx) = mpsc::channel(64);
        self.asr.pending.lock().unwrap().push_back(rx);
        AsrFeed { tx }
    }
}

impl ChannelAsr {
    pub fn new() -> (Arc<Self>, ChannelScripter) {
        let asr = Arc::new(Self {
            pending: Mutex::new(VecDeque::new()),
        });
        (asr.clone(), ChannelScripter { asr })
    }
}

struct RecvAsrStream {
    rx: mpsc::Receiver<AsrEvent>,
}

impl Stream for RecvAsrStream {
    type Item = AsrEvent;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<AsrEvent>> {
        self.rx.poll_recv(cx)
    }
}

#[async_trait]
impl AsrProvider for ChannelAsr {
    async fn open_stream(
        &self,
        _terms: &[String],
    ) -> Result<BoxStream<'static, AsrEvent>, AsrOpenError> {
        let rx = self
            .pending
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| AsrOpenError("no channel ASR session queued".into()))?;
        Ok(RecvAsrStream { rx }.boxed())
    }
}

// ---------------------------------------------------------------------------
// ScriptedLlm
// ---------------------------------------------------------------------------

/// One scripted rectify response: a sequence of token deltas, optionally
/// ending in a failure.
#[derive(Debug, Clone)]
pub enum LlmStep {
    /// Stream one token delta.
    Token(String),
    /// Fail the stream with an error message.
    Fail(String),
}

/// Fake rectify LLM: each `rectify` call records the request and replays
/// the next scripted response. Calling with no script left fails.
pub struct ScriptedLlm {
    scripts: Mutex<VecDeque<Vec<LlmStep>>>,
    /// When set, a drained queue refills from this copy instead of failing.
    cycle_from: Option<Vec<Vec<LlmStep>>>,
    requests: Mutex<Vec<RectifyRequest>>,
}

impl ScriptedLlm {
    pub fn new(scripts: Vec<Vec<LlmStep>>) -> Arc<Self> {
        Arc::new(Self {
            scripts: Mutex::new(scripts.into()),
            cycle_from: None,
            requests: Mutex::new(Vec::new()),
        })
    }

    /// Like [`new`], but the scripts repeat forever: a drained queue
    /// refills from the start instead of failing. For long-running demo
    /// hosts that must never run dry.
    pub fn new_cycling(scripts: Vec<Vec<LlmStep>>) -> Arc<Self> {
        Arc::new(Self {
            cycle_from: (!scripts.is_empty()).then(|| scripts.clone()),
            scripts: Mutex::new(scripts.into()),
            requests: Mutex::new(Vec::new()),
        })
    }

    /// All rectify requests received so far, in order.
    pub fn requests(&self) -> Vec<RectifyRequest> {
        self.requests.lock().unwrap().clone()
    }

    pub fn call_count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
}

#[async_trait]
impl RectifyLlm for ScriptedLlm {
    async fn rectify(&self, request: RectifyRequest) -> Result<RectifyTokenStream, RectifyError> {
        self.requests.lock().unwrap().push(request);
        let script = {
            let mut scripts = self.scripts.lock().unwrap();
            if scripts.is_empty()
                && let Some(originals) = &self.cycle_from
            {
                scripts.extend(originals.iter().cloned());
            }
            scripts
                .pop_front()
                .ok_or_else(|| RectifyError("no scripted LLM response left".into()))?
        };
        let items = script
            .into_iter()
            .map(|step| match step {
                LlmStep::Token(delta) => Ok(delta),
                LlmStep::Fail(message) => Err(RectifyError(message)),
            })
            .collect::<Vec<_>>();
        Ok(stream::iter(items).boxed())
    }
}

// ---------------------------------------------------------------------------
// FakeInserter
// ---------------------------------------------------------------------------

/// Fake inserter: records every text handed to it; can be armed to fail
/// once to exercise the insertion-failure path. Also counts
/// [`TextInserter::restore_focus`] calls for the cancel-path assertions.
pub struct FakeInserter {
    calls: Mutex<Vec<String>>,
    fail_next: AtomicBool,
    focus_restores: AtomicUsize,
}

impl FakeInserter {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            calls: Mutex::new(Vec::new()),
            fail_next: AtomicBool::new(false),
            focus_restores: AtomicUsize::new(0),
        })
    }

    pub fn inserted_texts(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    /// How many times a session end asked for the keyboard back.
    pub fn focus_restore_count(&self) -> usize {
        self.focus_restores.load(Ordering::SeqCst)
    }

    /// Make the next `insert` call fail once.
    pub fn fail_next_insert(&self) {
        self.fail_next.store(true, Ordering::SeqCst);
    }
}

#[async_trait]
impl TextInserter for FakeInserter {
    async fn insert(&self, text: &str) -> Result<(), InsertError> {
        if self.fail_next.swap(false, Ordering::SeqCst) {
            return Err(InsertError("scripted insertion failure".into()));
        }
        self.calls.lock().unwrap().push(text.to_string());
        Ok(())
    }

    fn restore_focus(&self) {
        self.focus_restores.fetch_add(1, Ordering::SeqCst);
    }
}

// ---------------------------------------------------------------------------
// FakeClock
// ---------------------------------------------------------------------------

/// Fake clock: starts at `start_ms`; tests move time explicitly.
pub struct FakeClock {
    now: AtomicU64,
}

impl FakeClock {
    pub fn new(start_ms: u64) -> Arc<Self> {
        Arc::new(Self {
            now: AtomicU64::new(start_ms),
        })
    }

    pub fn advance(&self, ms: u64) {
        self.now.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }
}
