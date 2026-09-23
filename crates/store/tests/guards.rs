//! The guard set, tested as the schema enforces it: the three UNIQUEs,
//! the blank-rejecting CHECKs (the space-only form), the one trigger
//! (the all-whitespace form the CHECKs cannot see), slot >= 1, the
//! three foreign keys' delete semantics, and the view the filter will
//! read. All straight SQL against a real database file.

use std::path::{Path, PathBuf};
use std::sync::Arc;

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

/// A direct connection to the store's database with the foreign keys
/// ON — the same posture every store connection runs with.
fn raw(dir: &Path) -> rusqlite::Connection {
    let conn = rusqlite::Connection::open(dir.join(STORE_DB_FILE)).unwrap();
    conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
    conn
}

fn insert_session(
    conn: &rusqlite::Connection,
    raw_text: &str,
    rectified: &str,
) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO sessions (created_at_ms, raw_transcript, rectified_text)
         VALUES (1000, ?, ?)",
        (raw_text, rectified),
    )
}

#[test]
fn duplicate_names_are_unique_in_all_three_places() {
    let dir = scratch("sr-store-unique");
    let (_c, now) = ((), clock());
    Store::open_at(
        &dir.join(STORE_DB_FILE),
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();
    let conn = raw(&dir);

    conn.execute(
        "INSERT INTO scenarios (name, directive, position) VALUES ('论文', '学术', 0)",
        (),
    )
    .unwrap();
    assert!(
        conn.execute(
            "INSERT INTO scenarios (name, directive, position) VALUES ('论文', '别的', 1)",
            (),
        )
        .is_err(),
        "a duplicated scenario name is refused"
    );

    conn.execute("INSERT INTO terms (text, position) VALUES ('术语', 0)", ())
        .unwrap();
    assert!(
        conn.execute("INSERT INTO terms (text, position) VALUES ('术语', 1)", ())
            .is_err(),
        "a duplicated term spelling is refused"
    );

    insert_session(&conn, "原话", "成文").unwrap();
    conn.execute(
        "INSERT INTO placeholders (session_id, slot, prefill, filled_value)
         VALUES (1, 1, NULL, '一')",
        (),
    )
    .unwrap();
    assert!(
        conn.execute(
            "INSERT INTO placeholders (session_id, slot, prefill, filled_value)
             VALUES (1, 1, NULL, '又')",
            (),
        )
        .is_err(),
        "the same slot twice in one session is refused"
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn the_checks_reject_space_only_short_fields_and_texts() {
    let dir = scratch("sr-store-checks");
    Store::open_at(
        &dir.join(STORE_DB_FILE),
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        clock(),
    )
    .unwrap();
    let conn = raw(&dir);

    for bad in ["", "   "] {
        assert!(
            conn.execute(
                "INSERT INTO scenarios (name, directive, position) VALUES (?, '指令', 0)",
                (bad,),
            )
            .is_err()
        );
        assert!(
            conn.execute(
                "INSERT INTO scenarios (name, directive, position) VALUES ('名', ?, 0)",
                (bad,),
            )
            .is_err()
        );
        assert!(
            conn.execute("INSERT INTO terms (text, position) VALUES (?, 0)", (bad,))
                .is_err()
        );
    }
    // The session texts: space-only fails the CHECK on either field.
    assert!(insert_session(&conn, "   ", "成文").is_err());
    assert!(insert_session(&conn, "原话", " ").is_err());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn the_trigger_rejects_whitespace_the_checks_cannot_see() {
    let dir = scratch("sr-store-trigger");
    Store::open_at(
        &dir.join(STORE_DB_FILE),
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        clock(),
    )
    .unwrap();
    let conn = raw(&dir);

    // Tabs, newlines, carriage returns: trim() only strips spaces, so
    // these pass the CHECKs — and must die on the trigger.
    assert!(insert_session(&conn, "\t\n\r", "成文").is_err());
    assert!(insert_session(&conn, "原话", "\t \r\n").is_err());
    // The trigger's message is its identity (the submitted brief's
    // example, made literal).
    let err = insert_session(&conn, " \t\n", "成文")
        .unwrap_err()
        .to_string();
    assert!(err.contains("all whitespace"), "got: {err}");
    // Real text passes both guards.
    insert_session(&conn, "原话", "成文").unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_placeholder_slot_must_be_a_positive_integer() {
    let dir = scratch("sr-store-slot");
    Store::open_at(
        &dir.join(STORE_DB_FILE),
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        clock(),
    )
    .unwrap();
    let conn = raw(&dir);
    insert_session(&conn, "原话", "成文").unwrap();

    assert!(
        conn.execute(
            "INSERT INTO placeholders (session_id, slot, filled_value) VALUES (1, 0, '零')",
            (),
        )
        .is_err()
    );
    assert!(
        conn.execute(
            "INSERT INTO placeholders (session_id, slot, filled_value) VALUES (1, -1, '负')",
            (),
        )
        .is_err()
    );
    conn.execute(
        "INSERT INTO placeholders (session_id, slot, filled_value) VALUES (1, 1, '一')",
        (),
    )
    .unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn the_foreign_keys_carry_the_promised_delete_semantics() {
    let dir = scratch("sr-store-fk");
    Store::open_at(
        &dir.join(STORE_DB_FILE),
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        clock(),
    )
    .unwrap();
    let conn = raw(&dir);

    conn.execute(
        "INSERT INTO scenarios (name, directive, position) VALUES ('论文', '学术', 0)",
        (),
    )
    .unwrap();
    insert_session(&conn, "第一场原话", "第一场成文").unwrap();
    conn.execute(
        "INSERT INTO sessions (created_at_ms, raw_transcript, rectified_text, scenario_id, source_session_id)
         VALUES (1001, '重跑原话', '重跑成文', 1, 1)",
        (),
    )
    .unwrap();
    conn.execute(
        "INSERT INTO placeholders (session_id, slot, prefill, filled_value)
         VALUES (1, 1, '预填值', '填入值')",
        (),
    )
    .unwrap();

    // Deleting the scenario: the session rows stay, their scenario
    // reference becomes 未选场景.
    conn.execute("DELETE FROM scenarios WHERE id = 1", ())
        .unwrap();
    let scenario: Option<i64> = conn
        .query_row("SELECT scenario_id FROM sessions WHERE id = 2", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(scenario, None, "删场景,历史归未选");

    // Deleting the source session: the re-run's source goes NULL.
    conn.execute("DELETE FROM sessions WHERE id = 1", ())
        .unwrap();
    let source: Option<i64> = conn
        .query_row(
            "SELECT source_session_id FROM sessions WHERE id = 2",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(source, None, "来源那场删了置空");

    // Deleting a session: its placeholders go with it.
    let placeholders: i64 = conn
        .query_row("SELECT COUNT(*) FROM placeholders", [], |row| row.get(0))
        .unwrap();
    assert_eq!(placeholders, 0, "删会话,占位符随灭");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn the_view_joins_the_scenario_name_for_filtering() {
    let dir = scratch("sr-store-view");
    Store::open_at(
        &dir.join(STORE_DB_FILE),
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        clock(),
    )
    .unwrap();
    let conn = raw(&dir);

    conn.execute(
        "INSERT INTO scenarios (name, directive, position) VALUES ('论文', '学术', 0)",
        (),
    )
    .unwrap();
    insert_session(&conn, "默认原话", "默认成文").unwrap();
    conn.execute(
        "INSERT INTO sessions (created_at_ms, raw_transcript, rectified_text, scenario_id)
         VALUES (1001, '有场景原话', '有场景成文', 1)",
        (),
    )
    .unwrap();

    let under: Option<String> = conn
        .query_row(
            "SELECT scenario_name FROM sessions_with_scenario
             WHERE raw_transcript = '有场景原话'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(under.as_deref(), Some("论文"));

    let default_row: Option<String> = conn
        .query_row(
            "SELECT scenario_name FROM sessions_with_scenario
             WHERE scenario_id IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap_or(None);
    assert_eq!(default_row, None, "未选场景 reads through the view");
    std::fs::remove_dir_all(dir).unwrap();
}
