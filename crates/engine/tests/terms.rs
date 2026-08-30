//! Deterministic seam tests for the hotword dictionary's two injection
//! paths: providers that can bias recognition receive the dictionary when
//! the stream opens, and every rectify request carries it as the term
//! reference. Both read one source, snapshotted per session.

mod common;

use std::sync::{Arc, Mutex};

use common::{await_live, await_state, harness_with_terms, ok};
use spokenrectifier_engine::fakes::{AsrStep, LlmStep};
use spokenrectifier_engine::{Command, SessionStyle, TermSource};

/// A settable dictionary: the test edits the file mid-run, like a user
/// saving the terms file between sessions.
struct SettableTerms(Arc<Mutex<Vec<String>>>);

impl TermSource for SettableTerms {
    fn terms(&self) -> Vec<String> {
        self.0.lock().unwrap().clone()
    }
}

fn settable_terms(initial: Vec<&str>) -> (Arc<Mutex<Vec<String>>>, Arc<dyn TermSource>) {
    let cell = Arc::new(Mutex::new(initial.into_iter().map(String::from).collect()));
    (cell.clone(), Arc::new(SettableTerms(cell)))
}

fn dictionary() -> Vec<String> {
    vec!["SpokenRectifier".to_string(), "语音实验室".to_string()]
}

#[tokio::test]
async fn both_injection_paths_receive_the_dictionary_of_the_session() {
    let (_cell, handle) = settable_terms(vec!["SpokenRectifier", "语音实验室"]);
    let (h, mut rx) = harness_with_terms(
        Default::default(),
        vec![vec![AsrStep::Say("嗯那个 SpokenRectifier".into())]],
        vec![vec![LlmStep::Token("成文".into())]],
        handle,
    );

    ok(&h.engine, Command::StartSession).await;
    // Drain the script before stopping, so the frozen transcript is whole.
    await_live(&mut rx, "嗯那个 SpokenRectifier").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Preview).await;
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Idle).await;

    // Hotword path: the dictionary as of session start reached the
    // provider when the stream opened.
    assert_eq!(h.asr.opened_terms(), vec![dictionary()]);
    // Prompt path: the same dictionary rode the rectify request as the
    // term reference.
    assert_eq!(h.llm.requests().len(), 1);
    assert_eq!(h.llm.requests()[0].terms, dictionary());
}

#[tokio::test]
async fn dictionary_edits_take_effect_on_the_next_session_not_the_current_one() {
    let (cell, handle) = settable_terms(vec!["旧术语"]);
    let (h, mut rx) = harness_with_terms(
        Default::default(),
        vec![
            vec![AsrStep::Say("第一段".into())],
            vec![AsrStep::Say("第二段".into())],
        ],
        vec![
            vec![LlmStep::Token("一".into())],
            vec![LlmStep::Token("二".into())],
        ],
        handle,
    );

    // Session one opens on the old dictionary, then the file changes
    // mid-session — its rectify must still see what its recognition saw.
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "第一段").await;
    *cell.lock().unwrap() = vec!["新术语".to_string()];
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Preview).await;
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Idle).await;
    assert_eq!(h.llm.requests()[0].terms, vec!["旧术语".to_string()]);

    // The next session picks the edit up on both paths.
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "第二段").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Preview).await;
    ok(&h.engine, Command::ConfirmInsert).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Idle).await;
    assert_eq!(
        h.asr.opened_terms(),
        vec![vec!["旧术语".to_string()], vec!["新术语".to_string()]]
    );
    assert_eq!(h.llm.requests()[1].terms, vec!["新术语".to_string()]);
}

#[tokio::test]
async fn reroll_reuses_the_session_dictionary() {
    let (_cell, handle) = settable_terms(vec!["术语甲"]);
    let (h, mut rx) = harness_with_terms(
        Default::default(),
        vec![vec![AsrStep::Say("原话".into())]],
        vec![
            vec![LlmStep::Token("第一次".into())],
            vec![LlmStep::Token("第二次".into())],
        ],
        handle,
    );

    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "原话").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Preview).await;
    ok(&h.engine, Command::Reroll).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Preview).await;

    assert_eq!(h.llm.requests().len(), 2);
    assert_eq!(h.llm.requests()[1].terms, vec!["术语甲".to_string()]);
}

#[tokio::test]
async fn history_re_rectify_reads_the_dictionary_fresh() {
    let (cell, handle) = settable_terms(vec!["旧术语"]);
    let (h, mut rx) = harness_with_terms(
        Default::default(),
        vec![],
        vec![
            vec![LlmStep::Token("第一次".into())],
            vec![LlmStep::Token("第二次".into())],
        ],
        handle,
    );

    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "再修一遍的原话".into(),
            style: SessionStyle::Live,
        },
    )
    .await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Preview).await;
    ok(&h.engine, Command::Cancel).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Idle).await;

    // A retrieval is its own session: it starts, so it reads the
    // dictionary as it stands now.
    *cell.lock().unwrap() = vec!["新术语".to_string()];
    ok(
        &h.engine,
        Command::RectifyText {
            raw_transcript: "再修一遍的原话".into(),
            style: SessionStyle::Live,
        },
    )
    .await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Preview).await;
    assert_eq!(h.llm.requests()[0].terms, vec!["旧术语".to_string()]);
    assert_eq!(h.llm.requests()[1].terms, vec!["新术语".to_string()]);
}

#[tokio::test]
async fn without_a_source_both_paths_see_no_terms() {
    let (h, mut rx) = common::harness(
        Default::default(),
        vec![vec![AsrStep::Say("原话".into())]],
        vec![vec![LlmStep::Token("成文".into())]],
    );
    ok(&h.engine, Command::StartSession).await;
    await_live(&mut rx, "原话").await;
    ok(&h.engine, Command::StopSession).await;
    await_state(&mut rx, spokenrectifier_engine::SessionState::Preview).await;
    ok(&h.engine, Command::ConfirmInsert).await;

    assert_eq!(h.asr.opened_terms(), vec![Vec::<String>::new()]);
    assert_eq!(h.llm.requests()[0].terms, Vec::<String>::new());
}
