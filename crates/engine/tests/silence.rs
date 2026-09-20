//! Silence semantics: passage mode marks paragraphs without ending the
//! session; with passage mode off, a long silence auto-ends it.

mod common;

use common::{await_live, await_state, collect_summary, expect_quiet, harness, next_matching, ok};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, EngineTimings, SessionState};

#[tokio::test]
async fn passage_mode_silence_marks_paragraph_but_session_continues() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![
            AsrStep::Say("第一点".into()),
            // Sub-threshold silence: no event.
            AsrStep::Silence(500),
            // Same silence run crosses the threshold: one paragraph mark.
            AsrStep::Silence(1300),
            // Still the same run, well past the threshold: still one mark.
            AsrStep::Silence(1400),
            AsrStep::Say("第二点".into()),
            // New silence run after speech: a second mark.
            AsrStep::Silence(1300),
        ]],
        vec![vec![LlmStep::Token("unused".into())]],
    );

    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;

    // Two paragraph marks in total: silence only segments, never ends.
    let second = next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    assert_eq!(second.seq, 4, "mark fires once per silence run");
    let _ = next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    expect_quiet(&mut rx, 50).await;

    // The session is still recording; cancelling it shows the state.
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"第一点\"",
            "live \"第一点\"",
            "paragraph",
            "live \"第一点\\n第二点\"",
            "live \"第一点\\n第二点\"",
            "paragraph",
            "state Recording->Cancelled",
            "state Cancelled->Idle",
        ]
    );
    // Silence never triggered rectify: the LLM was never asked.
    assert_eq!(h.llm.call_count(), 0);
}

#[tokio::test]
async fn passage_mode_off_auto_ends_on_long_silence() {
    let config = EngineConfig {
        passage_mode: false,
        ..EngineConfig::default()
    };
    let (h, mut rx) = harness(
        config,
        vec![vec![
            AsrStep::Say("你好".into()),
            // Just below the 3 s default: session continues.
            AsrStep::Silence(2999),
            AsrStep::Say("世界".into()),
            // At the threshold: the session ends itself.
            AsrStep::Silence(3000),
            // Never reached: the stream is closed after auto-end.
            AsrStep::Say("不存在".into()),
        ]],
        vec![vec![LlmStep::Token("修好".into())]],
    );

    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    await_state(&mut rx, SessionState::Preview).await;

    ok(
        &h.engine,
        Command::ConfirmInsert {
            placeholders: Vec::new(),
        },
    )
    .await;
    await_state(&mut rx, SessionState::Idle).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"你好\"",
            "live \"你好\"",
            "live \"你好世界\"",
            "live \"你好世界\"",
            // No StopSession was issued: the silence ended the session.
            "state Recording->Rectifying",
            "chunk \"修好\"",
            "state Rectifying->Preview",
            "inserted \"修好\"",
            "state Preview->Inserted",
            "state Inserted->Idle",
        ]
    );
    // The speech after auto-end never reached the transcript.
    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "你好世界");
    assert_eq!(h.inserter.inserted_texts(), vec!["修好"]);
}

#[tokio::test]
async fn passage_mode_off_auto_end_threshold_is_configurable() {
    let config = EngineConfig {
        passage_mode: false,
        session_end_silence_ms: 1500,
        ..EngineConfig::default()
    };
    let (h, mut rx) = harness(
        config,
        vec![vec![AsrStep::Say("短".into()), AsrStep::Silence(1500)]],
        vec![vec![LlmStep::Token("x".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    // 1500 ms of silence was enough with the configured threshold.
    assert_eq!(h.llm.call_count(), 1);
}

#[tokio::test]
async fn passage_mode_paragraph_threshold_is_configurable() {
    let config = EngineConfig {
        paragraph_silence_ms: 2500,
        ..EngineConfig::default()
    };
    let (h, mut rx) = harness(
        config,
        vec![vec![AsrStep::Say("话".into()), AsrStep::Silence(2000)]],
        vec![],
    );

    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    // Consume the partial and the final live event, then confirm nothing
    // else happened: 2000 ms is below the configured 2500 ms threshold, so
    // no paragraph mark and no session end.
    next_matching(
        &mut rx,
        |env| matches!(&env.event, EngineEvent::LiveTranscriptUpdated { text } if text == "话"),
    )
    .await;
    next_matching(
        &mut rx,
        |env| matches!(&env.event, EngineEvent::LiveTranscriptUpdated { text } if text == "话"),
    )
    .await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(
        collect_summary(&mut rx_all),
        vec!["state Idle->Recording", "live \"话\"", "live \"话\""]
    );
}

#[tokio::test]
async fn set_passage_mode_applies_from_the_next_session_on() {
    let (h, mut rx) = harness(
        EngineConfig::default(), // passage mode on at construction
        vec![
            vec![
                AsrStep::Say("第一场".into()),
                // Past the auto-end threshold, but this session opened in
                // passage mode: a paragraph, not an end.
                AsrStep::Silence(3000),
            ],
            vec![
                AsrStep::Say("第二场".into()),
                // The same silence in the next session (opened after the
                // switch): auto-end.
                AsrStep::Silence(3000),
            ],
        ],
        vec![vec![LlmStep::Token("修好".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    assert!(h.engine.passage_mode());

    // Switch mid-session: the running session keeps the semantics it
    // opened with — the switch applies from the next session on.
    ok(&h.engine, Command::SetPassageMode(false)).await;
    assert!(!h.engine.passage_mode());
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    expect_quiet(&mut rx, 50).await;
    assert_eq!(h.engine.state(), SessionState::Recording);
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;

    // The next session opened with the switch in effect: the same 3 s
    // silence now ends it.
    ok(&h.engine, Command::StartSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(h.llm.call_count(), 1);
}

#[tokio::test]
async fn set_engine_timings_applies_from_the_next_session_on() {
    // Passage mode off, so the session-end silence is the threshold in
    // play. Construction seeds 3000 ms; the switch tightens it.
    let (h, mut rx) = harness(
        EngineConfig {
            passage_mode: false,
            ..EngineConfig::default()
        },
        vec![
            vec![
                AsrStep::Say("第一场".into()),
                // Under the switched-in threshold, but this session
                // opened with the construction seed: silence continues.
                AsrStep::Silence(1500),
            ],
            vec![
                AsrStep::Say("第二场".into()),
                // The same silence in the next session (opened after the
                // switch): auto-end.
                AsrStep::Silence(1500),
            ],
        ],
        vec![vec![LlmStep::Token("修好".into())]],
    );

    ok(&h.engine, Command::StartSession).await;
    // The scripted Say lands as partial + final: drain both before the
    // quiet assertion (next_matching skips the state change).
    await_live(&mut rx, "第一场").await;
    await_live(&mut rx, "第一场").await;
    // Switch mid-session: the running session keeps the thresholds it
    // opened with — the switch applies from the next session on.
    ok(
        &h.engine,
        Command::SetEngineTimings(EngineTimings {
            paragraph_silence_ms: 1200,
            session_end_silence_ms: 1000,
            rectify_timeout_ms: 25_000,
        }),
    )
    .await;
    assert_eq!(h.engine.engine_timings().session_end_silence_ms, 1000);
    expect_quiet(&mut rx, 50).await;
    assert_eq!(h.engine.state(), SessionState::Recording);
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;

    // The next session opened with the switch in effect: the same 1.5 s
    // silence now ends it.
    ok(&h.engine, Command::StartSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_eq!(h.llm.call_count(), 1);
}

#[tokio::test]
async fn silence_before_any_speech_marks_nothing() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![
            // The user sits silent before saying anything: no paragraph.
            AsrStep::Silence(2000),
            AsrStep::Say("第一点".into()),
            // This one closes actual speech: one paragraph.
            AsrStep::Silence(2000),
        ]],
        vec![],
    );

    ok(&h.engine, Command::StartSession).await;
    let mark = next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    expect_quiet(&mut rx, 50).await;

    // The only mark came after the speech events (seq 4, not earlier), and
    // it is the only one: the leading silence produced nothing.
    assert_eq!(mark.seq, 4);
    assert_eq!(h.engine.state(), SessionState::Recording);
}
