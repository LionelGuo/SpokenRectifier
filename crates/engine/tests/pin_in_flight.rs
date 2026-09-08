//! The in-flight pin (钉入 while a draft is in flight, ticket 16): the
//! press freezes the draft spoken so far as the pin's left, and the
//! sentence's first non-empty Final resolves a snapshot constraint —
//! matching frames may only extend the frozen prefix, anything else is
//! dropped or appended after the pin. Speech is fed through the channel
//! ASR so commands interleave with transcript events exactly where each
//! test wants them; bare `partial`/`final_frame` feeds stand for the
//! adapter shapes the matrix is about (mid-utterance rewrites, Volcano's
//! no-utterance full-session restatement, Aliyun's empty Final).

mod common;

use common::{await_live, await_state, chan_harness, drain_said, expect_quiet, next_matching, ok};
use spokenrectifier_engine::fakes::LlmStep;
use spokenrectifier_engine::{Command, EngineConfig, EngineEvent, SessionState};

#[tokio::test]
async fn matching_final_lands_only_its_remainder() {
    // Press while the draft is in flight: the on-screen words freeze as
    // the pin's left (no relayout, no duplicate), and the sentence's
    // first non-empty Final — a full restatement starting with the frozen
    // words — appends only the remainder past the snapshot.
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.partial("我在说这句").await;
    await_live(&mut rx, "我在说这句").await;

    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "我在说这句‡1‡").await;

    h.feed.final_frame("我在说这句话说完").await;
    await_live(&mut rx, "我在说这句‡1‡话说完").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests.len(), 1);
    // One copy of the frozen words, one sentinel, the settled right —
    // never two drafts of the same sentence.
    assert_eq!(requests[0].raw_transcript, "我在说这句‡1‡话说完");
    assert_eq!(requests[0].paragraphs, vec!["我在说这句‡1‡话说完"]);
}

#[tokio::test]
async fn mismatching_final_appends_after_the_pin_and_ends_the_constraint() {
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.partial("草稿开头").await;
    await_live(&mut rx, "草稿开头").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "草稿开头‡1‡").await;

    // The Final does not start with the snapshot: it lands after the pin
    // as new finalized speech, the frozen left staying as pressed.
    h.feed.final_frame("完全不同的定稿").await;
    await_live(&mut rx, "草稿开头‡1‡完全不同的定稿").await;

    // The constraint is over: later frames fold normally instead of being
    // held against the snapshot — a non-matching partial now lands.
    h.feed.partial("新草").await;
    await_live(&mut rx, "草稿开头‡1‡完全不同的定稿新草").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "草稿开头‡1‡完全不同的定稿新草");
}

#[tokio::test]
async fn empty_final_is_ignored_while_the_constraint_stands() {
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.partial("半句").await;
    await_live(&mut rx, "半句").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "半句‡1‡").await;

    // An empty Final (Aliyun's missing-transcript shape) finalizes
    // nothing: no state change, no event, the constraint stands.
    h.feed.final_frame("").await;
    expect_quiet(&mut rx, 50).await;

    // The first NON-EMPTY Final still decides — the ignored empty one
    // did not consume the sentence's decision.
    h.feed.final_frame("半句说完").await;
    await_live(&mut rx, "半句‡1‡说完").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "半句‡1‡说完");
}

#[tokio::test]
async fn mismatching_partial_keeps_the_last_tail() {
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.partial("甲乙").await;
    await_live(&mut rx, "甲乙").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "甲乙‡1‡").await;

    // A matching frame grows the tail past the pin.
    h.feed.partial("甲乙丙").await;
    await_live(&mut rx, "甲乙‡1‡丙").await;

    // A frame that rewrites the frozen words is dropped whole: the tail
    // keeps its last frame and the constraint keeps waiting.
    h.feed.partial("X乙丙").await;
    expect_quiet(&mut rx, 50).await;

    // The recognizer's own Final version of the sentence wins: it starts
    // with the snapshot, so only its remainder lands. The pressed-time
    // words, not the rewrite, are what the freeze keeps.
    h.feed.final_frame("甲乙丙丁").await;
    await_live(&mut rx, "甲乙‡1‡丙丁").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "甲乙‡1‡丙丁");
}

#[tokio::test]
async fn full_session_partial_is_dropped_whole() {
    // Volcano's no-utterance fallback restates the whole session in one
    // Partial; under the constraint it starts with the earlier finalized
    // text, not the snapshot, so the frame is dropped whole instead of
    // being spliced anywhere near the pin.
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.say("已定稿").await;
    drain_said(&mut rx, "已定稿").await;
    h.feed.partial("第二句草稿").await;
    await_live(&mut rx, "已定稿第二句草稿").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "已定稿第二句草稿‡1‡").await;

    // The cumulative restatement is dropped: neither the finalized
    // prefix nor the frozen draft gets a second copy.
    h.feed.partial("已定稿第二句草稿更多").await;
    expect_quiet(&mut rx, 50).await;

    h.feed.final_frame("第二句草稿更多").await;
    await_live(&mut rx, "已定稿第二句草稿‡1‡更多").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "已定稿第二句草稿‡1‡更多");
}

#[tokio::test]
async fn stacked_pins_freeze_lefts_and_the_earlier_tail() {
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.partial("甲乙").await;
    await_live(&mut rx, "甲乙").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "甲乙‡1‡").await;

    h.feed.partial("甲乙丙丁").await;
    await_live(&mut rx, "甲乙‡1‡丙丁").await;

    // The second press freezes the first pin's collected right as its own
    // left; the constraint's snapshot grows to everything committed.
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "甲乙‡1‡丙丁‡2‡").await;

    h.feed.partial("甲乙丙丁戊").await;
    await_live(&mut rx, "甲乙‡1‡丙丁‡2‡戊").await;

    // A rewrite of the frozen middle cannot thaw the later pin's left:
    // the frame misses the cumulative snapshot and dies.
    h.feed.partial("甲乙丙X丁戊").await;
    expect_quiet(&mut rx, 50).await;

    h.feed.final_frame("甲乙丙丁戊己").await;
    await_live(&mut rx, "甲乙‡1‡丙丁‡2‡戊己").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "甲乙‡1‡丙丁‡2‡戊己");
    assert_eq!(requests[0].paragraphs, vec!["甲乙‡1‡丙丁‡2‡戊己"]);
}

#[tokio::test]
async fn paragraph_silence_does_not_split_the_pinned_row() {
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.say("第一段").await;
    drain_said(&mut rx, "第一段").await;
    // A row closed before the pin closes as always — the snapshot only
    // protects the row the pin sits in.
    h.feed.silence(1300).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;

    h.feed.partial("第二段草稿").await;
    await_live(&mut rx, "第一段\n第二段草稿").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "第一段\n第二段草稿‡1‡").await;

    // Silence past the threshold while the snapshot is in charge: no
    // paragraph mark, the pinned row stays one row.
    h.feed.silence(1300).await;
    expect_quiet(&mut rx, 50).await;

    // The sentence resolves, and the rhythm resumes: the next silence
    // run closes the now-settled row normally.
    h.feed.final_frame("第二段草稿完成").await;
    await_live(&mut rx, "第一段\n第二段草稿‡1‡完成").await;
    h.feed.silence(1300).await;
    next_matching(&mut rx, |env| env.event == EngineEvent::ParagraphMarked).await;

    h.feed.say("第三段").await;
    await_live(&mut rx, "第一段\n第二段草稿‡1‡完成\n第三段").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(
        requests[0].paragraphs,
        vec!["第一段", "第二段草稿‡1‡完成", "第三段"]
    );
}

#[tokio::test]
async fn freeze_while_the_constraint_is_open_keeps_the_tail() {
    // Recording ends before the sentence's Final arrives: the frozen left
    // keeps its pressed-time words and the collected tail rides the same
    // fidelity rule as any other in-flight draft.
    let h = chan_harness(
        EngineConfig::default(),
        vec![vec![LlmStep::Token("修".into())]],
    );
    let mut rx = h.engine.subscribe();

    ok(&h.engine, Command::StartSession).await;
    h.feed.partial("甲乙").await;
    await_live(&mut rx, "甲乙").await;
    ok(&h.engine, Command::PinPlaceholder).await;
    await_live(&mut rx, "甲乙‡1‡").await;
    h.feed.partial("甲乙丙").await;
    await_live(&mut rx, "甲乙‡1‡丙").await;

    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, SessionState::Preview).await;
    let requests = h.llm.requests();
    assert_eq!(requests[0].raw_transcript, "甲乙‡1‡丙");
    assert_eq!(requests[0].paragraphs, vec!["甲乙‡1‡丙"]);
}
