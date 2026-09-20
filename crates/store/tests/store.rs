//! Deterministic seam tests for the store's sessions domain: record,
//! list, clear, retention sweep, keep-nothing — all through the public
//! API with an injected wall clock, on real files under the temp
//! directory.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use spokenrectifier_engine::provider::history::{RecordedSession, SessionRecorder};
use spokenrectifier_store::{HistoryConfig, NowMs, Store, resolve_store_path};

/// A settable wall clock: the test moves time by hand.
fn settable_clock(start_ms: u64) -> (Arc<AtomicU64>, NowMs) {
    let cell = Arc::new(AtomicU64::new(start_ms));
    let read = cell.clone();
    (cell, Arc::new(move || read.load(Ordering::SeqCst)))
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn open(dir: &PathBuf, config: HistoryConfig, now: NowMs) -> Store {
    Store::open_at(
        &dir.join("store.db"),
        std::slice::from_ref(dir),
        config,
        now,
    )
    .unwrap()
}

fn entry(raw: &str, rectified: &str) -> RecordedSession {
    RecordedSession {
        raw_transcript: raw.to_string(),
        rectified_text: rectified.to_string(),
        scenario: None,
        placeholders: Vec::new(),
        source_session_id: None,
    }
}

const DAY_MS: u64 = 24 * 60 * 60 * 1000;

#[test]
fn recorded_sessions_list_newest_first_with_both_texts() {
    let dir = scratch("sr-store-order");
    let (_clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());

    store.record(entry("第一句原话", "第一句成文"));
    store.record(entry("第二句原话", "第二句成文"));

    let listed = store.list(10);
    assert_eq!(listed.len(), 2);
    assert_eq!(listed[0].raw_transcript, "第二句原话", "newest first");
    assert_eq!(listed[0].rectified_text, "第二句成文");
    assert_eq!(listed[1].raw_transcript, "第一句原话");
    // Timestamps come from the injected clock.
    assert_eq!(listed[0].created_at_ms, 1_000);
    // Row ids are distinct and stable for the panel's keys.
    assert_ne!(listed[0].id, listed[1].id);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn list_respects_the_limit() {
    let dir = scratch("sr-store-limit");
    let (_clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());
    for i in 0..5 {
        store.record(entry(&format!("原话{i}"), &format!("成文{i}")));
    }
    let listed = store.list(3);
    assert_eq!(listed.len(), 3);
    assert_eq!(listed[0].raw_transcript, "原话4");
    assert_eq!(listed[2].raw_transcript, "原话2");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn sessions_survive_reopening_the_database() {
    let dir = scratch("sr-store-reopen");
    let (_clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());
    store.record(entry("要说的话", "写成的话"));

    let reopened = open(&dir, HistoryConfig::default(), now.clone());
    let listed = reopened.list(10);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].raw_transcript, "要说的话");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn recording_sweeps_rows_past_the_retention_period() {
    let dir = scratch("sr-store-retention");
    let (clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());
    store.record(entry("三十天前的原话", "三十天前的成文"));

    // One day past the 30-day retention, the next record sweeps the old
    // row away (rows at or past the retention age go).
    clock.store(1_000 + 31 * DAY_MS, Ordering::SeqCst);
    store.record(entry("今天的原话", "今天的成文"));

    let listed = store.list(10);
    assert_eq!(listed.len(), 1, "expired row swept on record");
    assert_eq!(listed[0].raw_transcript, "今天的原话");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn reading_the_list_sweeps_expired_rows_too() {
    let dir = scratch("sr-store-list-sweep");
    let (clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());
    store.record(entry("很旧的原话", "很旧的成文"));

    // No new record, no reopen: the bare read still hides — and sweeps —
    // the expired row, so a long-running panel never shows stale data.
    clock.store(1_000 + 31 * DAY_MS, Ordering::SeqCst);
    assert!(store.list(10).is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn opening_the_store_sweeps_expired_rows() {
    let dir = scratch("sr-store-open-sweep");
    let (clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());
    store.record(entry("旧原话", "旧成文"));

    clock.store(1_000 + 31 * DAY_MS, Ordering::SeqCst);
    let reopened = open(&dir, HistoryConfig::default(), now.clone());
    assert!(
        reopened.list(10).is_empty(),
        "expired row swept when the store reopened"
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn clear_removes_every_row_for_good() {
    let dir = scratch("sr-store-clear");
    let (_clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());
    store.record(entry("原话一", "成文一"));
    store.record(entry("原话二", "成文二"));

    store.clear();
    assert!(store.list(10).is_empty());

    // Cleared means cleared: reopening the database finds nothing
    // either.
    let reopened = open(&dir, HistoryConfig::default(), now.clone());
    assert!(reopened.list(10).is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}

// -- keep-nothing: rows, never the file (the database is the scenarios'
// and terms' only home now) -----------------------------------------------

#[test]
fn keep_nothing_clears_and_holds_the_sessions_but_keeps_the_database() {
    let dir = scratch("sr-store-disabled");
    let db = dir.join("store.db");
    let (_clock, now) = settable_clock(1_000);
    let store = Store::open_at(
        &db,
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();
    store.record(entry("切换前的原话", "切换前的成文"));
    store.append_term("术语").unwrap();
    assert!(!store.list(10).is_empty());

    // Switch to keep-nothing: the sessions rows must not linger, ready
    // to resurface if history ever comes back on — but the database
    // itself stays, scenarios and terms in it.
    store
        .apply_config(HistoryConfig {
            enabled: false,
            retention_days: 30,
        })
        .unwrap();

    store.record(entry("不留存的原话", "不留存的成文"));
    assert!(store.list(10).is_empty());
    store.clear(); // a no-op, not an error
    assert!(db.is_file(), "keep-nothing cleared rows, not the file");
    assert_eq!(store.list_terms(), vec!["术语".to_string()]);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn keep_nothing_from_the_start_holds_the_table_empty() {
    let dir = scratch("sr-store-disabled-open");
    let (_clock, now) = settable_clock(1_000);
    let store = open(
        &dir,
        HistoryConfig {
            enabled: false,
            retention_days: 30,
        },
        now.clone(),
    );
    store.record(entry("不留存的原话", "不留存的成文"));
    assert!(store.list(10).is_empty());
    assert!(dir.join("store.db").is_file());

    // And a pre-existing row from before the switch is gone on open.
    store.apply_config(HistoryConfig::default()).unwrap();
    store.record(entry("恢复后的原话", "恢复后的成文"));
    let listed = store.list(10);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].raw_transcript, "恢复后的原话");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn open_falls_back_to_an_in_memory_store_when_no_directory_is_writable() {
    let missing = PathBuf::from("/definitely/not/a/real/directory");
    let (_clock, now) = settable_clock(1_000);
    let store = Store::open(
        std::slice::from_ref(&missing),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();
    // The ephemeral store still works for the run — it just keeps
    // nothing across launches.
    store.record(entry("原话", "成文"));
    assert_eq!(store.list(10).len(), 1);
    assert!(store.list_scenarios().is_empty());
}

#[test]
fn the_database_resolves_to_the_first_writable_directory() {
    let unwritable = scratch("sr-store-resolve-unwritable");
    let writable = scratch("sr-store-resolve-writable");
    // Make the first directory unwritable by replacing it with a file.
    std::fs::remove_dir(&unwritable).unwrap();
    std::fs::write(&unwritable, "not a directory").unwrap();

    let resolved = resolve_store_path(&[unwritable.clone(), writable.clone()]).unwrap();
    assert_eq!(resolved.parent(), Some(writable.as_path()));
    assert_eq!(
        resolved.file_name().and_then(|n| n.to_str()),
        Some("spokenrectifier-store.db")
    );

    std::fs::remove_file(&unwritable).unwrap();
    std::fs::remove_dir_all(writable).unwrap();
}

// -- runtime config changes (the settings window) ----------------------------

#[test]
fn a_tightened_retention_applies_at_once() {
    let dir = scratch("sr-store-apply-retention");
    let (clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());
    store.record(entry("十天前的原话", "十天前的成文"));

    // Tighten to 7 days: the row is 9 days old under the moved clock,
    // so the eager sweep must take it without any further record/read.
    clock.store(1_000 + 9 * DAY_MS, Ordering::SeqCst);
    store
        .apply_config(HistoryConfig {
            enabled: true,
            retention_days: 7,
        })
        .unwrap();
    assert!(
        store.list(10).is_empty(),
        "the tightened retention swept the old row immediately"
    );

    // Loosening back keeps what comes after.
    store.record(entry("新原话", "新成文"));
    store.apply_config(HistoryConfig::default()).unwrap();
    assert_eq!(store.list(10).len(), 1);
    std::fs::remove_dir_all(dir).unwrap();
}

// -- scenario and source capture (the pass-throughs) --------------------------

#[test]
fn a_recorded_session_resolves_its_scenario_name_into_an_id() {
    let dir = scratch("sr-store-scenario-id");
    let (_clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());
    store
        .save_scenarios(&[spokenrectifier_store::ScenarioInput {
            id: None,
            name: "论文".into(),
            directive: "学术书面语".into(),
        }])
        .unwrap();

    let mut under_scenario = entry("原话", "成文");
    under_scenario.scenario = Some("论文".into());
    store.record(under_scenario);
    store.record(entry("无场景原话", "无场景成文"));

    let conn = rusqlite::Connection::open(dir.join("store.db")).unwrap();
    let with_scenario: i64 = conn
        .query_row(
            "SELECT scenario_id FROM sessions WHERE raw_transcript = '原话'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let scenario_row: i64 = conn
        .query_row("SELECT id FROM scenarios WHERE name = '论文'", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(with_scenario, scenario_row);
    let without: Option<i64> = conn
        .query_row(
            "SELECT scenario_id FROM sessions WHERE raw_transcript = '无场景原话'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(without, None, "no scenario named records as 未选场景");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_vanished_scenario_name_or_source_row_records_as_none() {
    let dir = scratch("sr-store-vanished-refs");
    let (_clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());

    // A name nothing resolves, and a source row that does not exist:
    // both record as NULL rather than failing the insert.
    let mut session = entry("原话", "成文");
    session.scenario = Some("已被删掉的场景".into());
    session.source_session_id = Some(999);
    store.record(session);

    let conn = rusqlite::Connection::open(dir.join("store.db")).unwrap();
    let (scenario, source): (Option<i64>, Option<i64>) = conn
        .query_row(
            "SELECT scenario_id, source_session_id FROM sessions",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(scenario, None);
    assert_eq!(source, None);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_rerun_session_names_its_source_row() {
    let dir = scratch("sr-store-source");
    let (_clock, now) = settable_clock(1_000);
    let store = open(&dir, HistoryConfig::default(), now.clone());
    store.record(entry("第一场原话", "第一场成文"));
    let source_id = store.list(10)[0].id;

    let mut rerun = entry("第一场原话", "重跑后的成文");
    rerun.source_session_id = Some(source_id);
    store.record(rerun);

    let conn = rusqlite::Connection::open(dir.join("store.db")).unwrap();
    let source: i64 = conn
        .query_row(
            "SELECT source_session_id FROM sessions WHERE rectified_text = '重跑后的成文'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(source, source_id);
    std::fs::remove_dir_all(dir).unwrap();
}
