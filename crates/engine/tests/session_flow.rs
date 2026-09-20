//! Full-session flow tests: the complete command -> event contract.

mod common;

use common::{await_live, await_state, harness, next_matching, ok, summarize};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, SessionId, SessionState};

#[tokio::test]
async fn full_happy_path_event_sequence() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![
            AsrStep::Say("你好".into()),
            AsrStep::Say("世界".into()),
        ]],
        vec![vec![LlmStep::Token("修好".into())]],
    );

    // A second receiver collects everything without interfering with the
    // pacing awaits on the first one.
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "你好世界").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;

    // Collect every envelope, in order.
    let mut events = Vec::new();
    while let Ok(envelope) = rx_all.try_recv() {
        events.push(envelope);
    }
    assert_eq!(
        summarize(&events),
        vec![
            "state Idle->Recording",
            "live \"你好\"",
            "live \"你好\"",
            "live \"你好世界\"",
            "live \"你好世界\"",
            "state Recording->Rectifying",
            "chunk \"修好\"",
            "state Rectifying->Preview",
            "inserted \"修好\"",
            "state Preview->Inserted",
            "state Inserted->Idle",
        ]
    );
    // Sequence numbers are dense and monotonic; every event belongs to
    // session #1; timestamps come from the injected clock.
    for (i, envelope) in events.iter().enumerate() {
        assert_eq!(envelope.seq, (i + 1) as u64);
        assert_eq!(envelope.session_id, SessionId(1));
        assert_eq!(envelope.at_ms, 1_000);
    }

    // The rectify request carried the frozen raw transcript.
    let requests = h.llm.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].raw_transcript, "你好世界");
    assert_eq!(requests[0].paragraphs, vec!["你好世界"]);
    assert_eq!(requests[0].style_directive, None);

    // The inserter received the confirmed text, exactly once.
    assert_eq!(h.inserter.inserted_texts(), vec!["修好"]);
    assert_eq!(h.engine.state(), SessionState::Idle);
    assert_eq!(h.asr.remaining_sessions(), 0);

    // The insert path hands focus back itself while pasting; a confirmed
    // session does not ALSO run the cancel-path restore.
    assert_eq!(h.inserter.focus_restore_count(), 0);
}

#[tokio::test]
async fn cancelled_sessions_return_the_keyboard() {
    // The panel borrows the foreground for its affordances; ending
    // without inserting must give it back (real-machine round 4: after
    // Esc the target document sat unfocused and typing went nowhere).
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Say("一段".into())]],
        vec![vec![LlmStep::Token("修好".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "一段").await;
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(h.inserter.focus_restore_count(), 1);
}

#[tokio::test]
async fn sessions_run_back_to_back_with_fresh_ids() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![
            vec![AsrStep::Say("第一段".into())],
            vec![AsrStep::Say("第二段".into())],
        ],
        vec![
            vec![LlmStep::Token("一".into())],
            vec![LlmStep::Token("二".into())],
        ],
    );

    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "第一段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;

    // A finished session is not a dead end: the next one just works.
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "第二段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;

    let mut events = Vec::new();
    while let Ok(envelope) = rx_all.try_recv() {
        events.push(envelope);
    }
    let first_session: Vec<_> = events
        .iter()
        .filter(|env| env.session_id == SessionId(1))
        .collect();
    let second_session: Vec<_> = events
        .iter()
        .filter(|env| env.session_id == SessionId(2))
        .collect();
    assert_eq!(first_session.len(), second_session.len());
    assert_eq!(
        second_session.iter().map(|env| env.seq).min(),
        Some(10),
        "second session events continue the global sequence"
    );
    assert_eq!(h.inserter.inserted_texts(), vec!["一", "二"]);
}

#[tokio::test]
async fn trailing_interim_partial_reaches_the_transcript() {
    // Fidelity rule: speech still in flight when the user stops talking
    // must not be dropped from what gets rectified.
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![
            AsrStep::Say("你好".into()),
            AsrStep::Partial("世界还没说完".into()),
        ]],
        vec![vec![LlmStep::Token("修".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "你好世界还没说完").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "你好世界还没说完");
    assert_eq!(requests[0].paragraphs, vec!["你好世界还没说完"]);
}

#[tokio::test]
async fn live_transcript_shows_paragraph_breaks_in_passage_mode() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![
            AsrStep::Say("第一点".into()),
            AsrStep::Silence(1300),
            AsrStep::Say("第二点".into()),
        ]],
        vec![vec![LlmStep::Token("ok".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    let live = next_matching(&mut rx, |env| {
        matches!(&env.event, EngineEvent::LiveTranscriptUpdated { text } if text.contains('\n'))
    })
    .await;
    match live.event {
        EngineEvent::LiveTranscriptUpdated { text } => assert_eq!(text, "第一点\n第二点"),
        other => panic!("expected live transcript, got {other:?}"),
    }

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    // The paragraph split reached the rectify request.
    let requests = h.llm.requests();
    assert_eq!(requests[0].paragraphs, vec!["第一点", "第二点"]);
    assert_eq!(requests[0].raw_transcript, "第一点\n第二点");
}
