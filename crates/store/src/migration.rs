//! The one-time legacy file migration, run inside the schema-init
//! transaction: copy the file trio — the history database, the terms
//! text file, the scenarios TOML — into the store, verify the row
//! counts, and hand back the files to delete once the transaction
//! commits. Any failure rolls the whole thing back; the files stay
//! untouched and the next launch retries.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags, Transaction};

use spokenrectifier_config::terms::TERMS_FILE;
use spokenrectifier_config::{find_file, scenarios::SCENARIO_FILE};

use crate::store::StoreError;

/// The legacy history database's file name (the store this crate
/// replaced).
const LEGACY_HISTORY_DB: &str = "spokenrectifier-history.db";

/// The trigger's whitespace set, mirrored in Rust so the migration can
/// skip legacy rows the schema would refuse (they were written before
/// any guard existed). Space, tab, newline, carriage return — exactly
/// the four the trigger strips.
fn is_all_whitespace(text: &str) -> bool {
    text.chars().all(|c| matches!(c, ' ' | '\t' | '\n' | '\r'))
}

/// What the migration consumed: the legacy files to delete once the
/// transaction commits, and whether there were any at all.
pub(super) struct MigrationReport {
    legacy_files: Vec<PathBuf>,
}

impl MigrationReport {
    /// Best-effort, post-commit: nothing reads these files again (the
    /// version gate stays open even if a delete fails), so a failure is
    /// inert — log it and move on.
    pub(super) fn delete_legacy_files(&self) {
        for path in &self.legacy_files {
            if let Err(err) = std::fs::remove_file(path)
                && err.kind() != std::io::ErrorKind::NotFound
            {
                eprintln!(
                    "spokenrectifier-store: cannot remove the migrated legacy file {}: {err}",
                    path.display()
                );
            }
        }
    }
}

/// Run the migration inside `tx`. The loader rules apply verbatim:
/// terms parse per the file loader (trim, skip blanks and `#` comments)
/// then dedupe keep-first with 0-based positions; scenarios load as the
/// TOML loader reads them (trimmed, blanks skipped, duplicates keep the
/// last entry) with positions in file order; sessions copy whole,
/// preserving ids and timestamps, with `scenario_id`/`source_session_id`
/// left NULL (未选场景 — nothing to backfill).
pub(super) fn run(tx: &Transaction, dirs: &[PathBuf]) -> Result<MigrationReport, StoreError> {
    let mut legacy_files = Vec::new();

    // -- sessions: the legacy history database --------------------------------
    let mut expected_sessions = 0usize;
    if let Some(path) = dirs
        .iter()
        .map(|dir| dir.join(LEGACY_HISTORY_DB))
        .find(|path| path.is_file())
    {
        match read_legacy_sessions(&path) {
            Ok(rows) => {
                expected_sessions = rows.len();
                for (id, created_at_ms, raw, rectified) in rows {
                    tx.execute(
                        "INSERT INTO sessions (id, created_at_ms, raw_transcript, rectified_text)
                         VALUES (?, ?, ?, ?)",
                        (id, created_at_ms, raw, rectified),
                    )?;
                }
            }
            Err(err) => {
                // An unreadable or corrupt legacy database must not hold
                // the scenarios and terms hostage: skip its rows (they
                // were unrecoverable anyway), take the file out of
                // circulation with the rest, and say so.
                eprintln!(
                    "spokenrectifier-store: cannot read the legacy history database {} \
                     (skipping its sessions): {err}",
                    path.display()
                );
            }
        }
        // Every copy in the search order goes, mirroring the wipe the
        // old store's modes did — a shadowed copy was never read.
        for dir in dirs {
            let path = dir.join(LEGACY_HISTORY_DB);
            if path.is_file() {
                legacy_files.push(path);
            }
        }
    }
    verify_count(tx, "sessions", expected_sessions)?;

    // -- terms: the plain-text dictionary -------------------------------------
    // Loader order with duplicates keeping their first appearance.
    let terms = spokenrectifier_config::terms::load_terms(dirs);
    let mut seen = HashSet::new();
    let deduped: Vec<&String> = terms
        .iter()
        .filter(|term| seen.insert(term.as_str()))
        .collect();
    let expected_terms = deduped.len();
    for (position, term) in deduped.into_iter().enumerate() {
        tx.execute(
            "INSERT INTO terms (text, position) VALUES (?, ?)",
            (term.as_str(), position as i64),
        )?;
    }
    if let Some(path) = find_file(dirs, TERMS_FILE) {
        legacy_files.push(path);
    }
    verify_count(tx, "terms", expected_terms)?;

    // -- scenarios: the TOML library ------------------------------------------
    let scenarios = spokenrectifier_config::scenarios::load_scenarios(dirs);
    let expected_scenarios = scenarios.len();
    for (position, scenario) in scenarios.iter().enumerate() {
        tx.execute(
            "INSERT INTO scenarios (name, directive, position) VALUES (?, ?, ?)",
            (
                scenario.name.as_str(),
                scenario.directive.as_str(),
                position as i64,
            ),
        )?;
    }
    if let Some(path) = find_file(dirs, SCENARIO_FILE) {
        legacy_files.push(path);
    }
    verify_count(tx, "scenarios", expected_scenarios)?;

    Ok(MigrationReport { legacy_files })
}

/// The row-count check the migration's honesty rides on: what the
/// loader read is what the table now holds.
fn verify_count(tx: &Transaction, table: &str, expected: usize) -> Result<(), StoreError> {
    let count: i64 = tx.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
        row.get(0)
    })?;
    if count as usize != expected {
        return Err(StoreError(format!(
            "the {table} migration verified {count} rows, expected {expected}"
        )));
    }
    Ok(())
}

/// One legacy session row: (id, created_at_ms, raw_transcript,
/// rectified_text). Rows the new schema would refuse — all-whitespace
/// texts, written before any guard existed — are dropped rather than
/// aborting the migration.
fn read_legacy_sessions(path: &Path) -> Result<Vec<(i64, i64, String, String)>, rusqlite::Error> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    // A stray empty file with the right name is a valid empty database:
    // no sessions table means no sessions to copy.
    let has_table: bool = conn
        .query_row(
            "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type = 'table' AND name = 'sessions'",
            [],
            |row| row.get(0),
        )
        .unwrap_or(false);
    if !has_table {
        return Ok(Vec::new());
    }
    let mut stmt = conn.prepare(
        "SELECT id, created_at_ms, raw_transcript, rectified_text
         FROM sessions ORDER BY id",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
        ))
    })?;
    let mut sessions = Vec::new();
    for row in rows {
        let (id, created_at_ms, raw, rectified) = row?;
        if is_all_whitespace(&raw) || is_all_whitespace(&rectified) {
            continue;
        }
        sessions.push((id, created_at_ms, raw, rectified));
    }
    Ok(sessions)
}
