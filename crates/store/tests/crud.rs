//! The scenarios and terms table access: the editor's wholesale
//! diff-save (renames keep identity and history references), the
//! dictionary's add/rename/remove with the same-transaction renumber.

use std::path::PathBuf;
use std::sync::Arc;

use spokenrectifier_engine::provider::history::{RecordedSession, SessionRecorder};
use spokenrectifier_store::{
    HistoryConfig, NowMs, STORE_DB_FILE, ScenarioInput, Store, StoreError,
};

fn clock() -> NowMs {
    Arc::new(|| 1_000)
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn store_at(dir: &PathBuf) -> Store {
    Store::open_at(
        &dir.join(STORE_DB_FILE),
        std::slice::from_ref(dir),
        HistoryConfig::default(),
        clock(),
    )
    .unwrap()
}

fn input(id: Option<i64>, name: &str, directive: &str) -> ScenarioInput {
    ScenarioInput {
        id,
        name: name.into(),
        directive: directive.into(),
    }
}

fn entry(raw: &str, rectified: &str) -> RecordedSession {
    RecordedSession {
        raw_transcript: raw.to_string(),
        rectified_text: rectified.to_string(),
        scenario: None,
        source_session_id: None,
    }
}

// -- the scenario library -----------------------------------------------------

#[test]
fn saving_and_listing_round_trips_in_payload_order() {
    let dir = scratch("sr-store-scenarios-round-trip");
    let store = store_at(&dir);
    store
        .save_scenarios(&[
            input(None, "论文", "学术书面语"),
            input(None, "聊天", "轻松自然"),
        ])
        .unwrap();

    let listed = store.list_scenarios();
    assert_eq!(
        listed
            .iter()
            .map(|s| (s.name.as_str(), s.directive.as_str()))
            .collect::<Vec<_>>(),
        vec![("论文", "学术书面语"), ("聊天", "轻松自然")]
    );
    assert!(listed[0].id > 0, "the table assigned ids");

    // A wholesale save that reorders rewrites the positions.
    let (paper, chat) = (listed[1].id, listed[0].id);
    store
        .save_scenarios(&[
            input(Some(chat), "聊天", "轻松自然"),
            input(Some(paper), "论文", "学术书面语"),
        ])
        .unwrap();
    assert_eq!(
        store
            .list_scenarios()
            .iter()
            .map(|s| s.name.as_str())
            .collect::<Vec<_>>(),
        vec!["聊天", "论文"]
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_rename_keeps_the_id_and_the_history_references() {
    let dir = scratch("sr-store-scenarios-rename");
    let store = store_at(&dir);
    store
        .save_scenarios(&[input(None, "论文", "学术书面语")])
        .unwrap();
    let id = store.list_scenarios()[0].id;

    let mut session = entry("原话", "成文");
    session.scenario = Some("论文".into());
    store.record(session);

    // The edit renames the scenario; the save carries the same id.
    store
        .save_scenarios(&[input(Some(id), "学术论文", "学术书面语")])
        .unwrap();

    let conn = rusqlite::Connection::open(dir.join(STORE_DB_FILE)).unwrap();
    let (scenario_id, name): (i64, String) = conn
        .query_row(
            "SELECT s.scenario_id, sc.name
             FROM sessions s JOIN scenarios sc ON sc.id = s.scenario_id",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(scenario_id, id, "the row kept its id through the rename");
    assert_eq!(name, "学术论文");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn deleting_a_scenario_nulls_its_sessions_by_the_fk() {
    let dir = scratch("sr-store-scenarios-delete");
    let store = store_at(&dir);
    store
        .save_scenarios(&[
            input(None, "论文", "学术书面语"),
            input(None, "聊天", "轻松自然"),
        ])
        .unwrap();
    let (_paper, chat) = (store.list_scenarios()[0].id, store.list_scenarios()[1].id);

    let mut session = entry("原话", "成文");
    session.scenario = Some("论文".into());
    store.record(session);

    // The payload drops 论文: its id is absent, so the row goes — and
    // the session's reference falls to 未选场景 by SET NULL.
    store
        .save_scenarios(&[input(Some(chat), "聊天", "轻松自然")])
        .unwrap();
    assert_eq!(store.list_scenarios().len(), 1);

    let conn = rusqlite::Connection::open(dir.join(STORE_DB_FILE)).unwrap();
    let scenario: Option<i64> = conn
        .query_row("SELECT scenario_id FROM sessions", [], |row| row.get(0))
        .unwrap();
    assert_eq!(scenario, None);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn the_writer_refuses_what_the_loader_would_mangle() {
    let dir = scratch("sr-store-scenarios-refuse");
    let store = store_at(&dir);

    assert!(matches!(
        store.save_scenarios(&[input(None, "  ", "指令")]),
        Err(StoreError(_))
    ));
    assert!(matches!(
        store.save_scenarios(&[input(None, "名", "   ")]),
        Err(StoreError(_))
    ));
    assert!(matches!(
        store.save_scenarios(&[input(None, "同名", "一版"), input(None, "同名", "二版")]),
        Err(StoreError(_))
    ));
    // Nothing landed.
    assert!(store.list_scenarios().is_empty());

    // A stale id (another window's deletion) is an error, not a silent
    // insert.
    assert!(matches!(
        store.save_scenarios(&[input(Some(42), "名", "指令")]),
        Err(StoreError(_))
    ));
    std::fs::remove_dir_all(dir).unwrap();
}

// -- the dictionary -----------------------------------------------------------

#[test]
fn terms_round_trip_in_order_with_idempotent_append() {
    let dir = scratch("sr-store-terms");
    let store = store_at(&dir);

    store.append_term("首术语").unwrap();
    store.append_term("尾术语").unwrap();
    // Idempotent: already held, nothing changes.
    store.append_term("首术语").unwrap();
    assert_eq!(
        store.list_terms(),
        vec!["首术语".to_string(), "尾术语".to_string()]
    );
    // Blank is refused, and the trim rule applies.
    assert!(store.append_term("   ").is_err());
    store.append_term("  带空白  ").unwrap();
    assert_eq!(store.list_terms()[2], "带空白");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn removing_a_term_closes_the_position_gap() {
    let dir = scratch("sr-store-terms-remove");
    let store = store_at(&dir);
    for term in ["一", "二", "三"] {
        store.append_term(term).unwrap();
    }

    store.remove_term("二").unwrap();
    assert_eq!(store.list_terms(), vec!["一".to_string(), "三".to_string()]);

    // The positions are contiguous — no hole where 二 was.
    let conn = rusqlite::Connection::open(dir.join(STORE_DB_FILE)).unwrap();
    let positions: Vec<i64> = conn
        .prepare("SELECT position FROM terms ORDER BY position")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(positions, vec![0, 1]);
    // Absent terms are a quiet no-op.
    store.remove_term("不存在").unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn renaming_keeps_the_position_and_refuses_collisions() {
    let dir = scratch("sr-store-terms-rename");
    let store = store_at(&dir);
    for term in ["一", "二", "三"] {
        store.append_term(term).unwrap();
    }

    store.update_term("二", "贰").unwrap();
    assert_eq!(
        store.list_terms(),
        vec!["一".to_string(), "贰".to_string(), "三".to_string()]
    );

    // Onto an existing term: refused, nothing changed.
    assert!(store.update_term("贰", "三").is_err());
    // Of an absent term: refused too.
    assert!(store.update_term("不存在", "四").is_err());
    assert_eq!(store.list_terms().len(), 3);
    std::fs::remove_dir_all(dir).unwrap();
}

// -- the read-only peek (the CLI's dictionary) ---------------------------------

#[test]
fn peek_reads_the_store_once_initialized_else_the_file() {
    let dir = scratch("sr-store-peek");
    // Before any store exists: the legacy file is the dictionary.
    std::fs::write(dir.join("spokenrectifier-terms.txt"), "文件术语\n").unwrap();
    assert_eq!(
        spokenrectifier_store::peek_terms(std::slice::from_ref(&dir)),
        vec!["文件术语".to_string()]
    );

    // After the store initializes: the migration consumed the file (its
    // term came along), and the database is the dictionary.
    let store = store_at(&dir);
    store.append_term("库术语").unwrap();
    assert_eq!(
        spokenrectifier_store::peek_terms(std::slice::from_ref(&dir)),
        vec!["文件术语".to_string(), "库术语".to_string()]
    );
    std::fs::remove_dir_all(dir).unwrap();
}
