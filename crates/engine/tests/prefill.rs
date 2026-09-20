//! The rectify response's inline prefill forms (ruling 26, ticket 28):
//! the body streaming verbatim with its `‡N:值‡` forms, the half-grown
//! sentinel runs held off the chunk stream, the prefill table's arrival
//! ahead of the Preview state change, and the pin-less path staying
//! byte-identical to today. Pin placement itself is `pin.rs`'s ground;
//! here a single pin just marks the session as carrying sentinels.

mod common;

use common::{await_state, drain_said, harness, next_matching, ok};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::prefill::PrefillRow;
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, EventEnvelope, SessionState};

/// One scripted chunk sequence for a response text.
fn tokens(parts: &[&str]) -> Vec<LlmStep> {
    parts.iter().map(|p| LlmStep::Token((*p).into())).collect()
}

/// Collect one rectify attempt's chunk / prefill / preview sequence
/// from wherever the receiver stands through the Preview state change.
/// Returns the concatenated chunk text and the prefill table if one
/// arrived before Preview (the engine's gate would drop a late one, so
/// a mis-ordered delivery surfaces here as `None`).
async fn attempt_timeline(
    rx: &mut tokio::sync::broadcast::Receiver<EventEnvelope>,
) -> (String, Option<Vec<PrefillRow>>) {
    let mut streamed = String::new();
    let mut prefills = None;
    loop {
        let envelope = next_matching(rx, |env| {
            matches!(
                env.event,
                EngineEvent::RectifiedTextChunk { .. }
                    | EngineEvent::PreviewPrefills { .. }
                    | EngineEvent::SessionStateChanged {
                        to: SessionState::Preview,
                        ..
                    }
            )
        })
        .await;
        match envelope.event {
            EngineEvent::RectifiedTextChunk { delta } => streamed.push_str(&delta),
            EngineEvent::PreviewPrefills { prefills: rows } => prefills = Some(rows),
            EngineEvent::SessionStateChanged {
                to: SessionState::Preview,
                ..
            } => return (streamed, prefills),
            _ => unreachable!("filtered above"),
        }
    }
}

/// Run a recording session that says one phrase, pins once (or not —
/// `pin`), stops, and rides the scripted response to Preview.
async fn pin_session(
    llm: Vec<Vec<LlmStep>>,
    pin: bool,
) -> (
    common::Harness,
    tokio::sync::broadcast::Receiver<EventEnvelope>,
    (String, Option<Vec<PrefillRow>>),
) {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("你好".into())]],
        llm,
    );
    ok(&h.engine, Command::StartSession).await;
    // Land the phrase's frames first, so the freeze (and its empty-
    // session discard check) sees the speech regardless of pin.
    drain_said(&mut rx, "你好").await;
    if pin {
        ok(&h.engine, Command::PinPlaceholder).await;
    }
    ok(&h.engine, Command::StopSession).await;
    let timeline = attempt_timeline(&mut rx).await;
    (h, rx, timeline)
}

fn row(number: u32, value: &str) -> PrefillRow {
    PrefillRow {
        number,
        value: value.into(),
    }
}

#[tokio::test]
async fn an_inline_response_streams_verbatim_and_delivers_rows() {
    // Hostile token boundaries cutting through the form: the chunk
    // stream still carries the body verbatim (the shell's live capsule
    // grows straight out of it) and the rows parse from the body.
    let (h, mut rx, (streamed, prefills)) = pin_session(
        vec![tokens(&["发给‡1", ":这个文", "件‡一", "份,还有‡2‡。"])],
        true,
    )
    .await;

    assert_eq!(streamed, "发给‡1:这个文件‡一份,还有‡2‡。");
    assert_eq!(prefills, Some(vec![row(1, "这个文件"), row(2, "")]));

    // The preview body (and so the engine's insert, pre-substitution)
    // carries the forms verbatim.
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(
        h.inserter.inserted_texts(),
        vec!["发给‡1:这个文件‡一份,还有‡2‡。"]
    );
}

#[tokio::test]
async fn a_half_grown_run_never_flashes_on_the_stream() {
    // The deltas land mid-form: every emitted chunk leaves the
    // cumulative stream settled — a `‡N` fragment never reaches the
    // surface as body text, however the boundaries cut.
    let script = vec!["发给‡1", ":这个", "文件", "‡还有‡2", "‡。"];
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("你好".into())]],
        vec![tokens(&script)],
    );
    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "你好").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    ok(&h.engine, Command::StopSession).await;

    let mut cumulative = String::new();
    let prefills = loop {
        let envelope = next_matching(&mut rx, |env| {
            matches!(
                env.event,
                EngineEvent::RectifiedTextChunk { .. }
                    | EngineEvent::PreviewPrefills { .. }
                    | EngineEvent::SessionStateChanged {
                        to: SessionState::Preview,
                        ..
                    }
            )
        })
        .await;
        match envelope.event {
            EngineEvent::RectifiedTextChunk { delta } => {
                cumulative.push_str(&delta);
                // Settled means: not ending inside an unresolved `‡N`
                // run. The fragment chars may briefly sit past the last
                // decisive boundary only while held — the invariant is
                // on what has streamed.
                assert!(
                    !ends_unresolved(&cumulative),
                    "flashing chunk, cumulative {cumulative:?}"
                );
            }
            EngineEvent::PreviewPrefills { prefills } => break prefills,
            EngineEvent::SessionStateChanged {
                to: SessionState::Preview,
                ..
            } => panic!("Preview reached without the prefill table"),
            _ => unreachable!("filtered above"),
        }
    };
    assert_eq!(cumulative, "发给‡1:这个文件‡还有‡2‡。");
    assert_eq!(prefills, vec![row(1, "这个文件"), row(2, "")]);
}

/// The no-flash probe: the streamed text must not end inside a
/// `‡[0-9]*` run that no decisive character has settled yet. A faithful
/// mirror of the splitter's own classification (Body / Digits / Value):
/// only a trailing Digits run counts as unresolved — inside an inline
/// value everything is settled content (the capsule is already growing
/// by design).
fn ends_unresolved(streamed: &str) -> bool {
    #[derive(PartialEq)]
    enum State {
        Body,
        Digits,
        Value,
    }
    let mut state = State::Body;
    let mut digits = 0usize;
    for c in streamed.chars() {
        match state {
            State::Body => {
                if c == '‡' {
                    state = State::Digits;
                    digits = 0;
                }
            }
            State::Digits => {
                if c.is_ascii_digit() {
                    digits += 1;
                } else if c == ':' && digits > 0 {
                    state = State::Value;
                } else if c == '‡' && digits > 0 {
                    state = State::Body; // A bare form closed.
                } else if c == '‡' {
                    state = State::Digits; // `‡‡`: literal, reopen.
                    digits = 0;
                } else {
                    state = State::Body; // A breaking char: literal.
                }
            }
            State::Value => {
                if c == '‡' {
                    state = State::Body; // The value closed.
                }
            }
        }
    }
    state == State::Digits
}

#[tokio::test]
async fn a_formless_response_still_announces_an_empty_table() {
    let (_h, _rx, (streamed, prefills)) = pin_session(vec![tokens(&["打开就好"])], true).await;
    // Everything streams (no form to find), and the pin session still
    // gets its table event — empty, so every slot prefills empty.
    assert_eq!(streamed, "打开就好");
    assert_eq!(prefills, Some(vec![]));
}

#[tokio::test]
async fn a_retired_block_tail_streams_whole_as_residue() {
    // The model still emits the old 【预填】 block shape out of habit:
    // nothing splits, the tail rides the body verbatim, and the rows
    // come from the body's own forms — both `‡1‡` are bare, so slot 1
    // prefills empty and the block-line value is residue.
    let response = "发给‡1‡。\n\n【预填】\n- ‡1‡:张三";
    let (h, mut rx, (streamed, prefills)) = pin_session(vec![tokens(&[response])], true).await;
    assert_eq!(streamed, response);
    assert_eq!(prefills, Some(vec![row(1, "")]));
    // The insert carries the response whole, habit tail and all.
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(h.inserter.inserted_texts(), vec![response]);
}

#[tokio::test]
async fn a_pinless_session_is_byte_identical_and_never_announces() {
    // Even a response that happens to carry forms streams whole:
    // without sentinels in the request the engine never looks.
    let script = vec!["正文一\n", "\n【预填】\n", "- ‡1‡:值"];
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("你好".into())]],
        vec![tokens(&script)],
    );
    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "你好").await;
    ok(&h.engine, Command::StopSession).await;
    // Through Preview: the chunk events are exactly the scripted
    // deltas, one per token, and no prefill event ever.
    let mut chunks: Vec<String> = Vec::new();
    let prefills: Option<Vec<PrefillRow>> = loop {
        let envelope = next_matching(&mut rx, |env| {
            matches!(
                env.event,
                EngineEvent::RectifiedTextChunk { .. }
                    | EngineEvent::PreviewPrefills { .. }
                    | EngineEvent::SessionStateChanged {
                        to: SessionState::Preview,
                        ..
                    }
            )
        })
        .await;
        match envelope.event {
            EngineEvent::RectifiedTextChunk { delta } => chunks.push(delta),
            EngineEvent::PreviewPrefills { .. } => {
                panic!("pin-less session must never emit a prefill table")
            }
            EngineEvent::SessionStateChanged {
                to: SessionState::Preview,
                ..
            } => break None,
            _ => unreachable!("filtered above"),
        }
    };
    assert_eq!(chunks, script);
    assert_eq!(prefills, None);
    // The insert carries the response whole, forms and all.
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(
        h.inserter.inserted_texts(),
        vec!["正文一\n\n【预填】\n- ‡1‡:值"]
    );
}

#[tokio::test]
async fn a_reroll_delivers_the_new_round_table() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("你好".into())]],
        vec![tokens(&["发给‡1:张三‡"]), tokens(&["发给‡1:李四‡"])],
    );
    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "你好").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    ok(&h.engine, Command::StopSession).await;
    let (streamed, prefills) = attempt_timeline(&mut rx).await;
    assert_eq!(streamed, "发给‡1:张三‡");
    assert_eq!(prefills, Some(vec![row(1, "张三")]));

    // The reroll's table replaces the first round's — one event per
    // attempt, the fresh round's values.
    ok(&h.engine, Command::Reroll).await;
    let (streamed, prefills) = attempt_timeline(&mut rx).await;
    assert_eq!(streamed, "发给‡1:李四‡");
    assert_eq!(prefills, Some(vec![row(1, "李四")]));
}
