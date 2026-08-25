//! Speech-activity events (VAD) and provider failures — the mic-only world
//! before transcript text exists (real ASR text arrives with the Aliyun
//! adapter). VAD speech re-arms paragraph marking, speechless sessions
//! never reach the LLM, and a failed provider ends the session with
//! feedback instead of wedging in `Recording`.

mod common;

use common::{collect_summary, expect_quiet, harness, next_matching, ok};
use spokenrectifier_engine::fakes::AsrStep;
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, SessionState};

#[tokio::test]
async fn speech_activity_flows_out_and_resets_silence_runs() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![
            AsrStep::Say("第一点".into()),
            // First silence run: one paragraph mark.
            AsrStep::Silence(1300),
            // VAD-only speech (no transcript event): re-arms the marker.
            AsrStep::Speech(true),
            // Second silence run marks again.
            AsrStep::Silence(1300),
        ]],
        vec![],
    );
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    let speech = next_matching(&mut rx, |env| {
        env.event == EngineEvent::SpeechActivityChanged { speaking: true }
    })
    .await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    expect_quiet(&mut rx, 50).await;

    // The activity event sits between the two marks, and only one fires.
    assert_eq!(speech.seq, 5, "speech event lands after the first mark");
    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"第一点\"",
            "live \"第一点\"",
            "paragraph",
            "speech true",
            "paragraph",
        ]
    );
}

#[tokio::test]
async fn paragraph_marks_follow_speech_bursts_without_transcript() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![
            // Leading silence: no speech yet, nothing to mark.
            AsrStep::Silence(1300),
            // Two VAD-only bursts, each closed by a threshold silence.
            AsrStep::Speech(true),
            AsrStep::Silence(1300),
            AsrStep::Speech(true),
            AsrStep::Silence(1300),
        ]],
        vec![],
    );
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(h.engine.state(), SessionState::Recording);
    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "speech true",
            "paragraph",
            "speech true",
            "paragraph",
        ]
    );
}

#[tokio::test]
async fn asr_failure_ends_session_with_error_feedback() {
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![
            AsrStep::Say("话".into()),
            AsrStep::Fail("麦克风设备丢失".into()),
            // Never reached: the stream dies at the failure.
            AsrStep::Say("不存在".into()),
        ]],
        vec![],
    );
    let mut rx_all = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    let failure = next_matching(
        &mut rx,
        |env| matches!(&env.event, EngineEvent::Error { message } if message.contains("麦克风")),
    )
    .await;
    next_matching(&mut rx, |env| {
        matches!(
            &env.event,
            EngineEvent::SessionStateChanged {
                to: SessionState::Idle,
                ..
            }
        )
    })
    .await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(h.engine.state(), SessionState::Idle);
    assert_eq!(
        collect_summary(&mut rx_all),
        vec![
            "state Idle->Recording",
            "live \"话\"",
            "live \"话\"",
            "error \"麦克风设备丢失\"",
            "state Recording->Cancelled",
            "state Cancelled->Idle",
        ]
    );
    assert!(failure.seq > 0);
}

#[tokio::test]
async fn stopping_a_speechless_session_discards_it_without_rectifying() {
    // Noise-only session: no speech, no transcript. A manual stop must not
    // hand an empty utterance to the LLM — it discards, like a cancel.
    let (h, mut rx) = harness(
        EngineConfig::default(),
        vec![vec![AsrStep::Silence(500), AsrStep::Silence(900)]],
        vec![],
    );

    ok(&h.engine, Command::StartSession).await;
    ok(&h.engine, Command::StopSession).await;
    next_matching(&mut rx, |env| {
        matches!(
            &env.event,
            EngineEvent::SessionStateChanged {
                to: SessionState::Idle,
                ..
            }
        )
    })
    .await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(h.llm.call_count(), 0, "no rectify for a speechless session");
    assert_eq!(h.engine.state(), SessionState::Idle);
}

#[tokio::test]
async fn silence_auto_end_without_any_speech_discards_the_session() {
    // Passage mode off: the 3 s auto-end fires on a session where the user
    // never spoke. Nothing was said, so nothing is rectified.
    let config = EngineConfig {
        passage_mode: false,
        ..EngineConfig::default()
    };
    let (h, mut rx) = harness(config, vec![vec![AsrStep::Silence(3000)]], vec![]);

    ok(&h.engine, Command::StartSession).await;
    next_matching(&mut rx, |env| {
        matches!(
            &env.event,
            EngineEvent::SessionStateChanged {
                to: SessionState::Idle,
                ..
            }
        )
    })
    .await;
    expect_quiet(&mut rx, 50).await;

    assert_eq!(h.llm.call_count(), 0);
    assert_eq!(h.engine.state(), SessionState::Idle);
}
