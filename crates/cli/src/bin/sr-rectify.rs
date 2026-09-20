//! sr-rectify: run canned noisy utterances through the engine with the real
//! rectify pipeline (OpenAI-compatible LLM, streaming). No microphone — the
//! utterance file drives the engine; the LLM does the rest.
//!
//! Usage: sr-rectify [--style-directive <text>] <utterance-file>
//!
//! `--style-directive` sets a style-directive text for every block (the
//! same text a selected scenario would carry, e.g. "以 Markdown 分条、
//! 行内代码用反引号"); the default is the built-in default register.
//!
//! The file contains one or more utterance blocks separated by `---` lines.
//! Each non-empty line inside a block is spoken as one scripted phrase,
//! with a paragraph-marking silence after it. `#` lines are comments.
//!
//! Config: `spokenrectifier.toml` + `spokenrectifier.local.toml` (for API
//! keys) are read from the working directory, as is the hotword dictionary
//! the store's terms table (or, before the store initializes, the legacy
//! `spokenrectifier-terms.txt`) — the scripted ASR has no recognition to
//! bias, so the dictionary rides the rectify prompt.

use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use async_trait::async_trait;
use tokio::sync::broadcast;

use spokenrectifier_engine::fakes::ChannelAsr;
use spokenrectifier_engine::provider::inserter::{InsertError, TextInserter};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, SessionState,
    TermSource, TokioClock,
};
use spokenrectifier_llm::{live_llm, load_llm_config};
use sr_replay::fmt::fmt_event;

/// An inserter that just prints: the demo target is stdout, not a real
/// input field.
struct StdoutInserter;

/// The dictionary, re-read per session like the app does: the store's
/// terms table when it is initialized, else the legacy file. Read-only —
/// this tool never writes and never migrates.
struct StoreTermSource {
    dirs: Vec<PathBuf>,
}

impl TermSource for StoreTermSource {
    fn terms(&self) -> Vec<String> {
        spokenrectifier_store::peek_terms(&self.dirs)
    }
}

#[async_trait]
impl TextInserter for StdoutInserter {
    async fn insert(&self, text: &str) -> Result<(), InsertError> {
        println!();
        println!("=== 插入 ===");
        println!("{text}");
        println!("============");
        Ok(())
    }
}

fn parse_blocks(source: &str) -> Vec<Vec<String>> {
    let mut blocks = Vec::new();
    let mut current: Vec<String> = Vec::new();
    for line in source.lines() {
        let line = line.trim();
        if line == "---" {
            blocks.push(std::mem::take(&mut current));
        } else if !line.is_empty() && !line.starts_with('#') {
            current.push(line.to_string());
        }
    }
    blocks.push(current);
    blocks
        .into_iter()
        .filter(|block| !block.is_empty())
        .collect()
}

async fn wait_for_state(
    rx: &mut broadcast::Receiver<EventEnvelope>,
    want: SessionState,
) -> Result<(), String> {
    tokio::time::timeout(Duration::from_secs(120), async {
        let mut last_error = String::new();
        loop {
            match rx.recv().await {
                Ok(envelope) => match envelope.event {
                    EngineEvent::SessionStateChanged { to, .. } if to == want => return Ok(()),
                    // A rectify failure cancels the session: fail fast with
                    // the engine's own error instead of waiting out the
                    // timeout for a state that will never come.
                    EngineEvent::SessionStateChanged {
                        to: SessionState::Idle,
                        ..
                    } => {
                        return Err(if last_error.is_empty() {
                            format!("session ended before reaching {want}")
                        } else {
                            last_error
                        });
                    }
                    EngineEvent::Error { message } => {
                        last_error = message;
                    }
                    _ => {}
                },
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => {
                    return Err("event stream closed".to_string());
                }
            }
        }
    })
    .await
    .map_err(|_| format!("timed out waiting for {want}"))?
}

async fn wait_for_live(
    rx: &mut broadcast::Receiver<EventEnvelope>,
    last_phrase: &str,
) -> Result<(), String> {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match rx.recv().await {
                Ok(envelope) => {
                    if let EngineEvent::LiveTranscriptUpdated { text } = &envelope.event
                        && text.contains(last_phrase)
                    {
                        return Ok(());
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => {
                    return Err("event stream closed".to_string());
                }
            }
        }
    })
    .await
    .map_err(|_| "timed out waiting for live transcript".to_string())?
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("sr-rectify: {err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    // Args: an optional --style-directive <text>, then the utterance file.
    let mut style_directive: Option<String> = None;
    let mut path = None;
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--style-directive" => {
                let text = args
                    .next()
                    .ok_or_else(|| "--style-directive needs a value".to_string())?;
                style_directive = Some(text);
            }
            _ if path.is_none() => path = Some(arg),
            _ => return Err(format!("unexpected argument {arg:?}")),
        }
    }
    let path = path.ok_or_else(|| {
        "usage: sr-rectify [--style-directive <text>] <utterance-file>".to_string()
    })?;
    let source = fs::read_to_string(&path).map_err(|err| format!("cannot read {path}: {err}"))?;
    let blocks = parse_blocks(&source);
    if blocks.is_empty() {
        return Err("no utterance blocks in the file".into());
    }

    // The same layer-file search the app uses: working directory first,
    // then beside the executable.
    let dirs = spokenrectifier_config::search_dirs();
    let llm =
        live_llm(load_llm_config(&dirs).map_err(|err| err.to_string())?).map_err(|err| err.0)?;

    let (asr, scripter) = ChannelAsr::new();
    let engine = Engine::new(
        EngineConfig::default(),
        EngineDeps {
            asr,
            llm,
            inserter: std::sync::Arc::new(StdoutInserter),
            history: None,
            terms: Some(std::sync::Arc::new(StoreTermSource { dirs: dirs.clone() })),
            clock: std::sync::Arc::new(TokioClock::new()),
        },
    );

    // Printer: stream every event as it arrives.
    let mut printer_rx = engine.subscribe();
    let printer = tokio::spawn(async move {
        loop {
            match printer_rx.recv().await {
                Ok(envelope) => println!(
                    "#{:<3} @{:>9}ms  s{}  {}",
                    envelope.seq,
                    envelope.at_ms,
                    envelope.session_id.0,
                    fmt_event(&envelope.event)
                ),
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    println!("      (printer lagged, skipped {skipped} events)")
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    let mut rx = engine.subscribe();

    // The directive applies to every block's rectify, like a user
    // selecting a scenario before speaking.
    engine
        .execute(Command::SetStyleDirective {
            directive: style_directive,
            scenario: None,
        })
        .await
        .map_err(|err| format!("command failed: {err}"))?;

    for block in &blocks {
        println!(">> StartSession");
        let feed = scripter.begin_session();
        engine
            .execute(Command::StartSession)
            .await
            .map_err(|err| format!("command failed: {err}"))?;

        let last = block.last().expect("non-empty block");
        for phrase in block {
            println!(".. (canned) say {phrase:?}");
            feed.say(phrase).await;
            // A silence long enough to mark a paragraph, like real speech
            // pauses in passage mode.
            feed.silence(1300).await;
            tokio::task::yield_now().await;
        }
        // Drain before stopping so the frozen transcript is complete.
        wait_for_live(&mut rx, last).await?;

        println!(">> StopSession");
        drop(feed);
        engine
            .execute(Command::StopSession)
            .await
            .map_err(|err| format!("command failed: {err}"))?;
        wait_for_state(&mut rx, SessionState::Preview).await?;

        println!(">> ConfirmInsert");
        engine
            .execute(Command::ConfirmInsert)
            .await
            .map_err(|err| format!("command failed: {err}"))?;
        wait_for_state(&mut rx, SessionState::Idle).await?;
    }

    tokio::time::sleep(Duration::from_millis(200)).await;
    printer.abort();
    println!();
    println!("rectify demo done: {} utterance(s)", blocks.len());
    Ok(())
}
