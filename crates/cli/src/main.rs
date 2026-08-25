//! sr-replay: replay a scripted recording session against the engine with
//! all-fake collaborators and print the full event stream. No network, no
//! audio devices — this is the seam demo driver.
//!
//! Usage: sr-replay <script-file>
//!
//! Script lines (leading `#` comments and blank lines ignored):
//!   start              begin a recording session
//!   stop               stop recording, start rectifying
//!   cancel             cancel the session (zero output)
//!   confirm            insert the preview text
//!   reroll             regenerate the rectified text
//!   say <text>         scripted speech (a partial, then a final)
//!   silence <ms>       scripted cumulative silence
//!   llm <text>         queue the next scripted rectify response
//!   edit <text>        replace the preview text
//!   style <name>       general-written | prompt | formal-document
//!   await <target>     wait for a state (idle/recording/...) or `paragraph`

use std::env;
use std::fs;
use std::time::Duration;

use tokio::sync::broadcast;
use tokio::time::timeout;

use spokenrectifier_engine::fakes::{ChannelAsr, FakeClock, FakeInserter, LlmStep, ScriptedLlm};
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineDeps, EngineEvent, EventEnvelope, SessionState, Style,
};

#[derive(Debug, Clone)]
enum Step {
    Start,
    Stop,
    Cancel,
    Confirm,
    Reroll,
    Say(String),
    Silence(u64),
    Llm(String),
    Edit(String),
    Style(Style),
    Await(AwaitTarget),
}

#[derive(Debug, Clone)]
enum AwaitTarget {
    State(SessionState),
    Paragraph,
}

fn parse_state(name: &str) -> Option<SessionState> {
    match name.to_ascii_lowercase().as_str() {
        "idle" => Some(SessionState::Idle),
        "recording" => Some(SessionState::Recording),
        "rectifying" => Some(SessionState::Rectifying),
        "preview" => Some(SessionState::Preview),
        "inserted" => Some(SessionState::Inserted),
        "cancelled" => Some(SessionState::Cancelled),
        _ => None,
    }
}

fn parse_script(source: &str) -> Result<Vec<Step>, String> {
    let mut steps = Vec::new();
    for (index, raw) in source.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (head, rest) = match line.split_once(' ') {
            Some((head, rest)) => (head, Some(rest.trim())),
            None => (line, None),
        };
        let argument = || {
            rest.map(str::to_string)
                .ok_or_else(|| format!("line {}: `{head}` needs an argument", index + 1))
        };
        let step =
            match head {
                "start" => Step::Start,
                "stop" => Step::Stop,
                "cancel" => Step::Cancel,
                "confirm" => Step::Confirm,
                "reroll" => Step::Reroll,
                "say" => Step::Say(argument()?),
                "silence" => Step::Silence(argument()?.parse::<u64>().map_err(|_| {
                    format!("line {}: silence needs a millisecond count", index + 1)
                })?),
                "llm" => Step::Llm(argument()?),
                "edit" => Step::Edit(argument()?),
                "style" => {
                    let name = argument()?;
                    Step::Style(
                        Style::parse(&name)
                            .ok_or_else(|| format!("line {}: unknown style `{name}`", index + 1))?,
                    )
                }
                "await" => {
                    let target = argument()?;
                    if target == "paragraph" {
                        Step::Await(AwaitTarget::Paragraph)
                    } else {
                        Step::Await(AwaitTarget::State(parse_state(&target).ok_or_else(
                            || format!("line {}: unknown await target `{target}`", index + 1),
                        )?))
                    }
                }
                other => return Err(format!("line {}: unknown step `{other}`", index + 1)),
            };
        steps.push(step);
    }
    Ok(steps)
}

/// Collect the fake LLM responses (one per `llm` line, in order) and count
/// the sessions the script will start.
fn build_llm_scripts(steps: &[Step]) -> (Vec<Vec<LlmStep>>, usize) {
    let mut llm_scripts = Vec::new();
    let mut session_count = 0usize;
    for step in steps {
        match step {
            Step::Llm(text) => llm_scripts.push(llm_script(text)),
            Step::Start => session_count += 1,
            _ => {}
        }
    }
    (llm_scripts, session_count)
}

/// Turn an `llm` line into a streaming script: chunks of a few characters.
fn llm_script(text: &str) -> Vec<LlmStep> {
    let chars: Vec<char> = text.chars().collect();
    chars
        .chunks(4)
        .map(|chunk| LlmStep::Token(chunk.iter().collect()))
        .collect()
}

fn fmt_event(event: &EngineEvent) -> String {
    sr_replay::fmt::fmt_event(event)
}

async fn await_target(
    rx: &mut broadcast::Receiver<EventEnvelope>,
    target: &AwaitTarget,
) -> Result<(), String> {
    let matched = timeout(Duration::from_secs(10), async {
        loop {
            match rx.recv().await {
                Ok(envelope) => {
                    let hit = match (target, &envelope.event) {
                        (AwaitTarget::State(want), EngineEvent::SessionStateChanged { to, .. }) => {
                            to == want
                        }
                        (AwaitTarget::Paragraph, EngineEvent::ParagraphMarked) => true,
                        _ => false,
                    };
                    if hit {
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
    .await;
    match matched {
        Ok(result) => result,
        Err(_) => Err("timed out waiting for await target".to_string()),
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("sr-replay: {err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let script_path = env::args()
        .nth(1)
        .ok_or_else(|| "usage: sr-replay <script-file>".to_string())?;
    let source = fs::read_to_string(&script_path)
        .map_err(|err| format!("cannot read {script_path}: {err}"))?;
    let steps = parse_script(&source)?;
    let (llm_scripts, session_count) = build_llm_scripts(&steps);

    let (asr, scripter) = ChannelAsr::new();
    let llm = ScriptedLlm::new(llm_scripts);
    let inserter = FakeInserter::new();
    let clock = FakeClock::new(0);
    let engine = Engine::new(
        EngineConfig::default(),
        EngineDeps {
            asr,
            llm: llm.clone(),
            inserter: inserter.clone(),
            clock: clock.clone(),
        },
    );

    // One receiver just prints; the loop's own receiver backs `await`.
    let mut printer_rx = engine.subscribe();
    let printer = tokio::spawn(async move {
        loop {
            match printer_rx.recv().await {
                Ok(envelope) => println!(
                    "#{:<3} @{:>4}ms  s{}  {}",
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
    // The feed of the currently open fake ASR session; script lines push
    // events into it step by step, like real speech arriving over time.
    let mut feed: Option<spokenrectifier_engine::fakes::AsrFeed> = None;
    for step in steps {
        let result = match &step {
            Step::Start => {
                println!(">> StartSession");
                feed = Some(scripter.begin_session());
                engine.execute(Command::StartSession).await
            }
            Step::Stop => {
                println!(">> StopSession");
                feed = None;
                engine.execute(Command::StopSession).await
            }
            Step::Cancel => {
                println!(">> Cancel");
                feed = None;
                engine.execute(Command::Cancel).await
            }
            Step::Confirm => {
                println!(">> ConfirmInsert");
                engine.execute(Command::ConfirmInsert).await
            }
            Step::Reroll => {
                println!(">> Reroll");
                engine.execute(Command::Reroll).await
            }
            Step::Edit(text) => {
                println!(">> UpdatePreviewText {text:?}");
                engine
                    .execute(Command::UpdatePreviewText(text.clone()))
                    .await
            }
            Step::Style(style) => {
                println!(">> SetStyle({})", style.name());
                engine.execute(Command::SetStyle(*style)).await
            }
            Step::Say(text) => {
                let session = feed
                    .as_ref()
                    .ok_or_else(|| "say/silence outside of a session".to_string())?;
                println!(".. (scripted) say {text:?}");
                session.say(text).await;
                // Let the engine consume the fed events before the next
                // step, so a following stop freezes the full transcript.
                tokio::task::yield_now().await;
                Ok(())
            }
            Step::Silence(ms) => {
                let session = feed
                    .as_ref()
                    .ok_or_else(|| "say/silence outside of a session".to_string())?;
                println!(".. (scripted) silence {ms}ms");
                session.silence(*ms).await;
                tokio::task::yield_now().await;
                Ok(())
            }
            Step::Llm(_) => {
                println!(".. (scripted) llm response queued");
                Ok(())
            }
            Step::Await(target) => {
                println!(".. await {target:?}");
                await_target(&mut rx, target).await?;
                Ok(())
            }
        };
        result.map_err(|err| format!("command failed: {err}"))?;
    }

    // Let the printer drain the tail, then stop it and summarize.
    tokio::time::sleep(Duration::from_millis(100)).await;
    printer.abort();

    println!();
    println!(
        "replay summary: {session_count} session(s), {} llm call(s), {} insert(s)",
        llm.call_count(),
        inserter.inserted_texts().len()
    );
    for (i, text) in inserter.inserted_texts().iter().enumerate() {
        println!("  inserted[{i}]: {text:?}");
    }
    for (i, request) in llm.requests().iter().enumerate() {
        println!("  llm[{i}] raw: {:?}", request.raw_transcript);
    }
    Ok(())
}
