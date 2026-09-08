//! The pin command (钉入, ticket 15's static path): sentinels in the live
//! transcript, the freeze, and the rectify request. Speech is fed through
//! the channel ASR so commands interleave with transcript events exactly
//! where each test wants them — the scripted ASR would drain its whole
//! script before any command lands. The in-flight path (a press while a
//! draft is unpinned and in flight) lives in `pin_in_flight.rs`.

mod common;

use common::{await_live, await_state, chan_harness, drain_said, expect_quiet, next_matching, ok};
use spokenrectifier_engine::fakes::LlmStep;
use spokenrectifier_engine::{
    Command, Engine, EngineConfig, EngineError, EngineEvent, SessionState,
};

/// Assert the pin command is rejected with the given state and that the
/// state survived untouched.
async fn assert_pin_rejected(engine: &Engine, state: SessionState) {
    let err = engine
        .execute(Command::PinPlaceholder)
        .await
        .expect_err("pin must be rejected outside recording");
    match err {
        EngineError::CommandRejected {
            command,
            state: got,
        } => {
            assert_eq!(command, Command::PinPlaceholder);
            assert_eq!(got, state);
        }
        other => panic!("expected CommandRejected, got {other:?}"),
    }
    assert_eq!(engine.state(), state);
}

#[tokio::test]
async fn pin_appears_at_once_and_survives_later_speech() {
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.say("你好").await;
    drain_said(&mut rx, "你好").await;

    // The pin shows in the live transcript the moment it lands.
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "你好‡1‡").await;

    // The next sentence — interim frame first, final behind it — folds in
    // AFTER the pin; neither frame erases the sentinel.
    h.feed.say("世界").await;
    drain_said(&mut rx, "你好‡1‡世界").await;

    // An interim frame that never finalizes leaves the pin in place too.
    h.feed.partial("机器话").await;
    await_live(&mut rx, "你好‡1‡世界机器话").await;

    // The freeze carries the same splice: raw transcript and paragraphs
    // both keep the sentinel, numbered from 1 in pin order.
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].raw_transcript, "你好‡1‡世界机器话");
    assert_eq!(requests[0].paragraphs, vec!["你好‡1‡世界机器话"]);
}

#[tokio::test]
async fn repeated_pins_get_their_own_numbers() {
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.say("甲").await;
    drain_said(&mut rx, "甲").await;

    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "甲‡1‡").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "甲‡1‡‡2‡").await;

    h.feed.say("乙").await;
    drain_said(&mut rx, "甲‡1‡‡2‡乙").await;

    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "甲‡1‡‡2‡乙‡3‡").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "甲‡1‡‡2‡乙‡3‡");
    assert_eq!(requests[0].paragraphs, vec!["甲‡1‡‡2‡乙‡3‡"]);
}

#[tokio::test]
async fn pins_ride_paragraph_marks_from_both_sides() {
    let h = chan_harness(
        EngineConfig::default(),
        vec![
            vec![LlmStep::Token("修".into())],
            vec![LlmStep::Token("修".into())],
        ],
    );
    let mut rx = h.engine.subscribe();

    // Pin after a mark closed the paragraph: the pin lands at the end of
    // the closed paragraph, and the next paragraph's speech stays after
    // it on its own line.
    ok(&h.engine, Command::StartSession).await;
    h.feed.say("第一段").await;
    drain_said(&mut rx, "第一段").await;
    h.feed.silence(1300).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;

    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "第一段‡1‡").await;
    h.feed.say("第二段").await;
    drain_said(&mut rx, "第一段‡1‡\n第二段").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests[0].paragraphs, vec!["第一段‡1‡", "第二段"]);

    // Leave preview before the next session can open.
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;

    // Pin inside the open paragraph, then the mark closes it: the anchor
    // rides the close and the sentinel stays at the same text position.
    let feed = h.begin_session();
    ok(&h.engine, Command::StartSession).await;
    feed.say("甲").await;
    drain_said(&mut rx, "甲").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "甲‡1‡").await;
    feed.silence(1300).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
    feed.say("乙").await;
    drain_said(&mut rx, "甲‡1‡\n乙").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests[1].paragraphs, vec!["甲‡1‡", "乙"]);
}

#[tokio::test]
async fn pin_only_session_is_rectified_on_manual_stop() {
    // No speech at all — the session survives the discard because the
    // frozen transcript is non-empty, and rectifies as usual.
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "‡1‡").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].raw_transcript, "‡1‡");
    assert_eq!(requests[0].paragraphs, vec!["‡1‡"]);
}

#[tokio::test]
async fn pin_only_session_survives_silence_auto_end() {
    // Same survival on the non-passage auto-end path.
    let h = chan_harness(
        EngineConfig {
            passage_mode: false,
            ..EngineConfig::default()
        },
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "‡1‡").await;
    h.feed.silence(3000).await;

    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].raw_transcript, "‡1‡");
}

#[tokio::test]
async fn pinless_speechless_session_is_still_discarded() {
    // The existing discard criterion needs no pin special case: with
    // neither speech nor pins, the session dies on stop as before.
    let h = chan_harness(EngineConfig::default(), vec![]);
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Cancelled).await;
    await_state(&mut rx, SessionState::Idle).await;
    expect_quiet(&mut rx, 50).await;
    assert_eq!(h.llm.call_count(), 0);
}

#[tokio::test]
async fn a_pin_does_not_re_arm_the_paragraph_rhythm() {
    let h = chan_harness(EngineConfig::default(), vec![]);
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.say("话").await;
    drain_said(&mut rx, "话").await;
    h.feed.silence(1300).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;

    // A pin is not speech: the silence run's mark stands, and further
    // silence marks nothing new — speech re-arms the rhythm, not pins.
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "话‡1‡").await;
    h.feed.silence(1300).await;
    expect_quiet(&mut rx, 50).await;

    h.feed.say("更多").await;
    drain_said(&mut rx, "话‡1‡\n更多").await;
    h.feed.silence(1300).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;
}

#[tokio::test]
async fn pin_is_rejected_outside_recording() {
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    // Idle: rejected, nothing emitted.
    assert_pin_rejected(&h.engine, SessionState::Idle).await;
    expect_quiet(&mut rx, 50).await;

    // Preview: rejected, the session stays put.
    ok(&h.engine, Command::StartSession).await;
    h.feed.say("话").await;
    drain_said(&mut rx, "话").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    assert_pin_rejected(&h.engine, SessionState::Preview).await;
    expect_quiet(&mut rx, 50).await;
}

#[tokio::test]
async fn cancelled_session_leaves_no_pin_residue() {
    let h = chan_harness(EngineConfig::default(), vec![]);
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.say("话").await;
    drain_said(&mut rx, "话").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "话‡1‡").await;

    // Esc cancels the whole segment: the pins die with the session and
    // nothing was ever rectified.
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, SessionState::Idle).await;
    expect_quiet(&mut rx, 50).await;
    assert_eq!(h.llm.call_count(), 0);

    // The next session numbers from 1 again — no residue across
    // recordings.
    let feed = h.begin_session();
    ok(&h.engine, Command::StartSession).await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "‡1‡").await;
    feed.say("新话").await;
    drain_said(&mut rx, "‡1‡新话").await;
}
