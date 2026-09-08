//! The rectify response's prefill block (【预填】, ticket 18): the
//! streaming split that keeps the block off the chunks, the prefill
//! table's arrival ahead of the Preview state change, and the
//! pin-less path staying byte-identical to today. Pin placement itself
//! is `pin.rs`'s ground; here a single pin just marks the session as
//! carrying sentinels.

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

#[tokio::test]
async fn a_block_response_streams_only_the_body_and_delivers_the_table() {
    let (h, mut rx, (streamed, prefills)) = pin_session(
        vec![tokens(&[
            "打开‡1‡",
            "。\n\n【",
            "预填】\n- ‡1‡:",
            "这个文件\n- ‡2‡:多余号",
        ])],
        true,
    )
    .await;

    // The chunks carry the body only — separator and block never
    // stream, however the token boundaries cut them.
    assert_eq!(streamed, "打开‡1‡。");
    assert_eq!(
        prefills,
        Some(vec![
            PrefillRow {
                number: 1,
                value: "这个文件".into()
            },
            PrefillRow {
                number: 2,
                value: "多余号".into()
            },
        ])
    );

    // The preview body (and so the engine's insert, pre-substitution)
    // is the block-free text; the extra row rides as written for the
    // shell's extraction to ignore.
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, SessionState::Idle).await;
    assert_eq!(h.inserter.inserted_texts(), vec!["打开‡1‡。"]);
}

#[tokio::test]
async fn a_blockless_response_still_announces_an_empty_table() {
    let (_h, _rx, (streamed, prefills)) =
        pin_session(vec![tokens(&["打开‡1‡", "就好"])], true).await;
    // Everything streams (no block to find), and the pin session still
    // gets its table event — empty, so every slot prefills empty.
    assert_eq!(streamed, "打开‡1‡就好");
    assert_eq!(prefills, Some(vec![]));
}

#[tokio::test]
async fn an_unsplittable_header_streams_everything_and_prefills_empty() {
    let (_h, _rx, (streamed, prefills)) = pin_session(
        vec![tokens(&["正文\n【预填】(机械普查,值为空)\n- ‡1‡:值"])],
        true,
    )
    .await;
    // The header must own its line; same-line junk means no block, no
    // failure, an empty table.
    assert_eq!(streamed, "正文\n【预填】(机械普查,值为空)\n- ‡1‡:值");
    assert_eq!(prefills, Some(vec![]));
}

#[tokio::test]
async fn rows_ride_verbatim_whether_or_not_the_body_has_the_number() {
    // The body keeps its mechanical sentinels (‡3‡ streams through);
    // the table keeps its rows (‡2‡, absent from the body). Deciding
    // what exists is the shell's extraction, not the engine's.
    let (_h, _rx, (streamed, prefills)) = pin_session(
        vec![tokens(&["发给‡3‡\n\n【预填】\n- ‡2‡:幽灵号\n- ‡3‡:"])],
        true,
    )
    .await;
    assert_eq!(streamed, "发给‡3‡");
    assert_eq!(
        prefills,
        Some(vec![
            PrefillRow {
                number: 2,
                value: "幽灵号".into()
            },
            PrefillRow {
                number: 3,
                value: String::new()
            },
        ])
    );
}

#[tokio::test]
async fn a_pinless_session_is_byte_identical_and_never_announces() {
    // Even a response that happens to carry a block-shaped tail streams
    // whole: without sentinels in the request the engine never looks.
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
    // The insert carries the response whole, block and all.
    ok(&h.engine, Command::ConfirmInsert).await;
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
        vec![
            tokens(&["发给‡1‡\n\n【预填】\n- ‡1‡:张三"]),
            tokens(&["发给‡1‡\n\n【预填】\n- ‡1‡:李四"]),
        ],
    );
    ok(&h.engine, Command::StartSession).await;
    drain_said(&mut rx, "你好").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    ok(&h.engine, Command::StopSession).await;
    let (streamed, prefills) = attempt_timeline(&mut rx).await;
    assert_eq!(streamed, "发给‡1‡");
    assert_eq!(
        prefills,
        Some(vec![PrefillRow {
            number: 1,
            value: "张三".into()
        }])
    );

    // The reroll's table replaces the first round's — one event per
    // attempt, the fresh round's values.
    ok(&h.engine, Command::Reroll).await;
    let (streamed, prefills) = attempt_timeline(&mut rx).await;
    assert_eq!(streamed, "发给‡1‡");
    assert_eq!(
        prefills,
        Some(vec![PrefillRow {
            number: 1,
            value: "李四".into()
        }])
    );
}
