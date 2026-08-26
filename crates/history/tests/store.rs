//! Deterministic seam tests for the history store: record, list, clear,
//! retention sweep, disabled mode — all through the public API with an
//! injected wall clock, on real files under the temp directory.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use spokenrectifier_engine::provider::history::{RecordedSession, SessionRecorder};
use spokenrectifier_history::{HistoryConfig, HistoryStore, NowMs, resolve_db_path};

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

fn entry(raw: &str, rectified: &str) -> RecordedSession {
    RecordedSession {
        raw_transcript: raw.to_string(),
        rectified_text: rectified.to_string(),
    }
}

const DAY_MS: u64 = 24 * 60 * 60 * 1000;

#[test]
fn recorded_sessions_list_newest_first_with_both_texts() {
    let dir = scratch("sr-history-order");
    let (_clock, now) = settable_clock(1_000);
    let store = HistoryStore::open_at(
        &dir.join("history.db"),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();

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
    let dir = scratch("sr-history-limit");
    let (_clock, now) = settable_clock(1_000);
    let store = HistoryStore::open_at(
        &dir.join("history.db"),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();
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
fn history_survives_reopening_the_database() {
    let dir = scratch("sr-history-reopen");
    let db = dir.join("history.db");
    let (_clock, now) = settable_clock(1_000);
    let store = HistoryStore::open_at(&db, HistoryConfig::default(), now.clone()).unwrap();
    store.record(entry("要说的话", "写成的话"));

    let reopened = HistoryStore::open_at(&db, HistoryConfig::default(), now.clone()).unwrap();
    let listed = reopened.list(10);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].raw_transcript, "要说的话");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn recording_sweeps_rows_past_the_retention_period() {
    let dir = scratch("sr-history-retention");
    let db = dir.join("history.db");
    let (clock, now) = settable_clock(1_000);
    let store = HistoryStore::open_at(&db, HistoryConfig::default(), now.clone()).unwrap();
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
    let dir = scratch("sr-history-list-sweep");
    let db = dir.join("history.db");
    let (clock, now) = settable_clock(1_000);
    let store = HistoryStore::open_at(&db, HistoryConfig::default(), now.clone()).unwrap();
    store.record(entry("很旧的原话", "很旧的成文"));

    // No new record, no reopen: the bare read still hides — and sweeps —
    // the expired row, so a long-running panel never shows stale data.
    clock.store(1_000 + 31 * DAY_MS, Ordering::SeqCst);
    assert!(store.list(10).is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn opening_the_store_sweeps_expired_rows() {
    let dir = scratch("sr-history-open-sweep");
    let db = dir.join("history.db");
    let (clock, now) = settable_clock(1_000);
    let store = HistoryStore::open_at(&db, HistoryConfig::default(), now.clone()).unwrap();
    store.record(entry("旧原话", "旧成文"));

    clock.store(1_000 + 31 * DAY_MS, Ordering::SeqCst);
    let reopened = HistoryStore::open_at(&db, HistoryConfig::default(), now.clone()).unwrap();
    assert!(
        reopened.list(10).is_empty(),
        "expired row swept when the store reopened"
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn clear_removes_every_row_for_good() {
    let dir = scratch("sr-history-clear");
    let db = dir.join("history.db");
    let (_clock, now) = settable_clock(1_000);
    let store = HistoryStore::open_at(&db, HistoryConfig::default(), now.clone()).unwrap();
    store.record(entry("原话一", "成文一"));
    store.record(entry("原话二", "成文二"));

    store.clear();
    assert!(store.list(10).is_empty());

    // Cleared means cleared: reopening the file finds nothing either.
    let reopened = HistoryStore::open_at(&db, HistoryConfig::default(), now.clone()).unwrap();
    assert!(reopened.list(10).is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_disabled_store_keeps_nothing() {
    let dir = scratch("sr-history-disabled");
    let db = dir.join("history.db");
    let (_clock, now) = settable_clock(1_000);
    let store = HistoryStore::open_at(&db, HistoryConfig::default(), now.clone()).unwrap();
    store.record(entry("切换前的原话", "切换前的成文"));
    assert!(db.is_file());

    // Switch to keep-nothing: the previous rows must not linger on disk,
    // ready to resurface if history ever comes back on.
    let store = HistoryStore::open_at(
        &db,
        HistoryConfig {
            enabled: false,
            retention_days: 30,
        },
        now.clone(),
    )
    .unwrap();

    store.record(entry("不留存的原话", "不留存的成文"));
    assert!(store.list(10).is_empty());
    store.clear(); // a no-op, not an error
    assert!(!db.exists(), "keep-nothing wiped the database it replaced");
    assert!(
        dir.read_dir().unwrap().next().is_none(),
        "no database file was left anywhere"
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn open_store_falls_back_to_disabled_when_no_directory_is_writable() {
    let missing = PathBuf::from("/definitely/not/a/real/directory");
    let (_clock, now) = settable_clock(1_000);
    let store = HistoryStore::open(
        std::slice::from_ref(&missing),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();
    store.record(entry("原话", "成文"));
    assert!(store.list(10).is_empty());
}

#[test]
fn the_database_resolves_to_the_first_writable_directory() {
    let unwritable = scratch("sr-history-resolve-unwritable");
    let writable = scratch("sr-history-resolve-writable");
    // Make the first directory unwritable by replacing it with a file.
    std::fs::remove_dir(&unwritable).unwrap();
    std::fs::write(&unwritable, "not a directory").unwrap();

    let resolved = resolve_db_path(&[unwritable.clone(), writable.clone()]).unwrap();
    assert_eq!(resolved.parent(), Some(writable.as_path()));
    assert_eq!(
        resolved.file_name().and_then(|n| n.to_str()),
        Some("spokenrectifier-history.db")
    );

    std::fs::remove_file(&unwritable).unwrap();
    std::fs::remove_dir_all(&writable).unwrap();
}
