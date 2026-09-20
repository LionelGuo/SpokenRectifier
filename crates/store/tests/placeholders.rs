//! The confirm-time slot table's landing (占位符钉入入库): one
//! placeholders row per fill beside the session row, in the same
//! transaction — with the store's two tolerance folds (number 0 is a
//! same-shape artifact the pins never mint; a repeated number keeps its
//! first row) and the CASCADE the deletion semantics ride. Straight SQL
//! reads the rows back, the same posture as the guard set's tests.

use std::path::PathBuf;
use std::sync::Arc;

use spokenrectifier_engine::prefill::PlaceholderFill;
use spokenrectifier_engine::provider::history::{RecordedSession, SessionRecorder};
use spokenrectifier_store::{HistoryConfig, NowMs, STORE_DB_FILE, Store};

fn clock() -> NowMs {
    Arc::new(|| 1_000)
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn store(dir: &PathBuf) -> Store {
    Store::open_at(
        &dir.join(STORE_DB_FILE),
        std::slice::from_ref(dir),
        HistoryConfig::default(),
        clock(),
    )
    .unwrap()
}

fn fill(number: u32, prefill: &str, value: &str) -> PlaceholderFill {
    PlaceholderFill {
        number,
        prefill: prefill.to_string(),
        value: value.to_string(),
    }
}

/// Every placeholders row, ordered by slot — the shape all assertions
/// read back.
fn rows(dir: &PathBuf) -> Vec<(i64, i64, Option<String>, String)> {
    let conn = rusqlite::Connection::open(dir.join(STORE_DB_FILE)).unwrap();
    let mut stmt = conn
        .prepare("SELECT session_id, slot, prefill, filled_value FROM placeholders ORDER BY slot")
        .unwrap();
    stmt.query_map((), |row| {
        Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
    })
    .unwrap()
    .collect::<Result<Vec<_>, _>>()
    .unwrap()
}

#[test]
fn confirm_rows_land_beside_the_session_row() {
    let dir = scratch("sr-store-ph-lands");
    let store = store(&dir);
    store.record(RecordedSession {
        raw_transcript: "发给‡1‡和‡2‡".into(),
        rectified_text: "发给张三和吧。".into(),
        scenario: None,
        source_session_id: None,
        placeholders: vec![
            fill(1, "张三", "张三"),
            fill(2, "", "吧"),
            fill(10, "李四", "改成李四"),
        ],
    });
    drop(store);

    let conn = rusqlite::Connection::open(dir.join(STORE_DB_FILE)).unwrap();
    let session_id: i64 = conn
        .query_row("SELECT id FROM sessions", (), |row| row.get(0))
        .unwrap();
    // An empty prefill writes NULL (裸钉: no value delivered); a
    // delivered value writes itself; the filled value is whatever the
    // confirm actually substituted, edited or not.
    assert_eq!(
        rows(&dir),
        vec![
            (session_id, 1, Some("张三".into()), "张三".into()),
            (session_id, 2, None, "吧".into()),
            (session_id, 10, Some("李四".into()), "改成李四".into()),
        ]
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_repeated_number_keeps_its_first_row() {
    let dir = scratch("sr-store-ph-dedupe");
    let store = store(&dir);
    store.record(RecordedSession {
        raw_transcript: "发给‡1‡再提‡1‡".into(),
        rectified_text: "发给张三。".into(),
        scenario: None,
        source_session_id: None,
        placeholders: vec![fill(1, "张三", "张三"), fill(1, "后来者", "后来者")],
    });
    drop(store);

    assert_eq!(rows(&dir), vec![(1, 1, Some("张三".into()), "张三".into())]);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn number_zero_is_skipped_and_the_session_still_lands() {
    let dir = scratch("sr-store-ph-zero");
    let store = store(&dir);
    store.record(RecordedSession {
        raw_transcript: "说出了‡0‡的形状".into(),
        rectified_text: "说出了0的形状。".into(),
        scenario: None,
        source_session_id: None,
        placeholders: vec![fill(0, "", "0"), fill(1, "", "一")],
    });
    drop(store);

    // The guard (slot >= 1) never sees the artifact: the row is skipped,
    // the session pair records anyway.
    assert_eq!(rows(&dir), vec![(1, 1, None, "一".into())]);
    let conn = rusqlite::Connection::open(dir.join(STORE_DB_FILE)).unwrap();
    let sessions: i64 = conn
        .query_row("SELECT COUNT(*) FROM sessions", (), |row| row.get(0))
        .unwrap();
    assert_eq!(sessions, 1);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn clearing_sessions_takes_the_placeholders_with_them() {
    let dir = scratch("sr-store-ph-cascade");
    let store = store(&dir);
    store.record(RecordedSession {
        raw_transcript: "发给‡1‡".into(),
        rectified_text: "发给张三。".into(),
        scenario: None,
        source_session_id: None,
        placeholders: vec![fill(1, "张三", "张三")],
    });
    store.clear();
    drop(store);

    // The one-click clear (and the keep-nothing mode's rows deletion)
    // rides the FK's ON DELETE CASCADE: no placeholder outlives its
    // session, and the library tables stay.
    assert_eq!(rows(&dir), vec![]);
    std::fs::remove_dir_all(dir).unwrap();
}
