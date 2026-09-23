//! The one-time legacy file migration: the trio comes in under the
//! loader rules, the row counts verify, the files go, and the version
//! gate keeps the whole thing to exactly one run — failures leave the
//! legacy files untouched for the next launch.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use spokenrectifier_store::{HistoryConfig, NowMs, STORE_DB_FILE, ScenarioFilter, Store};

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

/// A legacy history database with the old four-column schema and the
/// given rows — including, from one caller, rows the new guards would
/// refuse.
fn legacy_history_db(dir: &Path, rows: &[(&str, &str)]) {
    let conn = rusqlite::Connection::open(dir.join("spokenrectifier-history.db")).unwrap();
    conn.execute(
        "CREATE TABLE sessions (
             id INTEGER PRIMARY KEY,
             created_at_ms INTEGER NOT NULL,
             raw_transcript TEXT NOT NULL,
             rectified_text TEXT NOT NULL
         )",
        (),
    )
    .unwrap();
    for (i, (raw, rectified)) in rows.iter().enumerate() {
        conn.execute(
            "INSERT INTO sessions (id, created_at_ms, raw_transcript, rectified_text)
             VALUES (?, ?, ?, ?)",
            ((i + 1) as i64, 1_000_i64, *raw, *rectified),
        )
        .unwrap();
    }
}

fn legacy_trio(dir: &Path) {
    legacy_history_db(
        dir,
        &[("很早的原话", "很早的成文"), ("后来的原话", "后来的成文")],
    );
    std::fs::write(
        dir.join("spokenrectifier-terms.txt"),
        "# 注释\n首术语\n重复术语\n\n重复术语\n尾术语\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("spokenrectifier-scenarios.toml"),
        "[[scenario]]\nname = \"论文\"\ndirective = \"学术书面语\"\n\n\
         [[scenario]]\nname = \"聊天\"\ndirective = \"轻松自然\"\n",
    )
    .unwrap();
}

#[test]
fn the_legacy_trio_migrates_in_and_the_files_go() {
    let dir = scratch("sr-store-migrate");
    legacy_trio(&dir);

    let (_clock, now) = settable_clock(1_000);
    let store = Store::open(
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();

    // Sessions came over whole, ids and all, newest first.
    let listed = store.list(10, ScenarioFilter::All);
    assert_eq!(listed.len(), 2);
    assert_eq!(listed[0].raw_transcript, "后来的原话");
    assert_eq!(listed[0].id, 2, "legacy ids are preserved");

    // Terms: loader rules (comments and blanks dropped), duplicates
    // keep their first appearance, positions 0-based in file order.
    assert_eq!(
        store.list_terms(),
        vec![
            "首术语".to_string(),
            "重复术语".to_string(),
            "尾术语".to_string()
        ]
    );

    // Scenarios in file order.
    assert_eq!(
        store
            .list_scenarios()
            .iter()
            .map(|s| s.name.as_str())
            .collect::<Vec<_>>(),
        vec!["论文", "聊天"]
    );

    // The files are gone — all three, and only those.
    assert!(!dir.join("spokenrectifier-history.db").exists());
    assert!(!dir.join("spokenrectifier-terms.txt").exists());
    assert!(!dir.join("spokenrectifier-scenarios.toml").exists());
    assert!(dir.join(STORE_DB_FILE).is_file());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn rows_the_new_guards_would_refuse_are_skipped_not_fatal() {
    let dir = scratch("sr-store-migrate-guarded");
    legacy_history_db(
        &dir,
        &[
            ("好原话", "好成文"),
            ("   \t\n", "全空白的成文"), // all-whitespace raw
            ("全空白的原话", " \t\r\n"), // all-whitespace rectified
        ],
    );
    std::fs::write(dir.join("spokenrectifier-terms.txt"), "术语\n").unwrap();

    let (_clock, now) = settable_clock(1_000);
    let store = Store::open(
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();

    let listed = store.list(10, ScenarioFilter::All);
    assert_eq!(listed.len(), 1, "the guardable rows are dropped");
    assert_eq!(listed[0].raw_transcript, "好原话");
    assert_eq!(listed[0].id, 1, "the kept row keeps its id");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn an_unreadable_legacy_history_db_does_not_hostage_the_rest() {
    let dir = scratch("sr-store-migrate-corrupt-history");
    // Garbage bytes where the history database should be: its sessions
    // are unrecoverable, but the terms and scenarios still migrate.
    std::fs::write(dir.join("spokenrectifier-history.db"), "not a database").unwrap();
    std::fs::write(dir.join("spokenrectifier-terms.txt"), "术语\n").unwrap();
    std::fs::write(
        dir.join("spokenrectifier-scenarios.toml"),
        "[[scenario]]\nname = \"论文\"\ndirective = \"学术书面语\"\n",
    )
    .unwrap();

    let (_clock, now) = settable_clock(1_000);
    let store = Store::open(
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();

    assert!(store.list(10, ScenarioFilter::All).is_empty());
    assert_eq!(store.list_terms(), vec!["术语".to_string()]);
    assert_eq!(store.list_scenarios().len(), 1);
    // The corrupt file left with the rest.
    assert!(!dir.join("spokenrectifier-history.db").exists());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_failed_open_leaves_the_legacy_files_for_the_next_launch() {
    let dir = scratch("sr-store-migrate-retry");
    legacy_trio(&dir);
    // A corrupt store database in the way: every open fails until it is
    // gone, and the legacy files must wait right there.
    std::fs::write(dir.join(STORE_DB_FILE), "not a database either").unwrap();

    let (_clock, now) = settable_clock(1_000);
    let store = Store::open(
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();
    // The fallback is the ephemeral in-memory store.
    assert!(store.list_terms().is_empty());

    // The legacy trio is untouched — nothing consumed them.
    assert!(dir.join("spokenrectifier-history.db").is_file());
    assert!(dir.join("spokenrectifier-terms.txt").is_file());
    assert!(dir.join("spokenrectifier-scenarios.toml").is_file());

    // The obstruction gone, the next launch migrates as if nothing
    // happened.
    std::fs::remove_file(dir.join(STORE_DB_FILE)).unwrap();
    let store = Store::open(
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();
    assert_eq!(store.list_terms().len(), 3);
    assert!(dir.join(STORE_DB_FILE).is_file());
    assert!(!dir.join("spokenrectifier-terms.txt").exists());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn the_version_gate_lets_the_migration_run_only_once() {
    let dir = scratch("sr-store-migrate-once");
    legacy_trio(&dir);

    let (_clock, now) = settable_clock(1_000);
    let first = Store::open(
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();
    assert_eq!(first.list_terms().len(), 3);

    // Files reappearing after the fact (a restore, another machine's
    // copy) are inert: the gate is open, nothing reads them again.
    std::fs::write(dir.join("spokenrectifier-terms.txt"), "迟到的术语\n").unwrap();
    let second = Store::open(
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();
    assert_eq!(
        second.list_terms().len(),
        3,
        "the reappeared file was not re-migrated"
    );
    assert!(
        dir.join("spokenrectifier-terms.txt").is_file(),
        "and it was not consumed"
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn keep_nothing_migrates_the_library_but_holds_no_sessions() {
    let dir = scratch("sr-store-migrate-keep-nothing");
    legacy_trio(&dir);

    let (_clock, now) = settable_clock(1_000);
    let store = Store::open(
        std::slice::from_ref(&dir),
        HistoryConfig {
            enabled: false,
            retention_days: 30,
        },
        now.clone(),
    )
    .unwrap();

    // The user chose 不留存: the sessions that came over are cleared
    // with the mode, the scenarios and terms are not sessions and stay.
    assert!(store.list(10, ScenarioFilter::All).is_empty());
    assert_eq!(store.list_terms().len(), 3);
    assert_eq!(store.list_scenarios().len(), 2);
    assert!(!dir.join("spokenrectifier-terms.txt").exists());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_fresh_install_creates_the_schema_with_nothing_to_migrate() {
    let dir = scratch("sr-store-migrate-fresh");
    let (_clock, now) = settable_clock(1_000);
    let store = Store::open(
        std::slice::from_ref(&dir),
        HistoryConfig::default(),
        now.clone(),
    )
    .unwrap();

    assert!(store.list(10, ScenarioFilter::All).is_empty());
    assert!(store.list_terms().is_empty());
    assert!(store.list_scenarios().is_empty());
    let conn = rusqlite::Connection::open(dir.join(STORE_DB_FILE)).unwrap();
    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap();
    assert_eq!(version, 1);
    std::fs::remove_dir_all(dir).unwrap();
}
