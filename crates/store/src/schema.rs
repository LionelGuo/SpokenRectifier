//! The store's schema: four tables, the guard set, the view, and the
//! one trigger — created once inside the migration transaction, gated by
//! `PRAGMA user_version` (which rolls back with the transaction, so a
//! crash mid-migration leaves the gate shut and the next launch retries
//! cleanly).

use rusqlite::Connection;

use crate::migration;
use crate::store::StoreError;

/// The whole schema, idempotent (`IF NOT EXISTS` throughout so a
/// half-created remnant from a failed run is repaired, not fatal).
///
/// The guard set, one line each (the submitted task brief's §4 wording
/// made literal):
/// - `scenarios.name` UNIQUE + blank-rejecting; `terms.text` likewise;
///   `placeholders(session_id, slot)` UNIQUE — 重名三处全 UNIQUE.
/// - Blank rejection is the space-only form (`trim(x) <> ''`); the
///   all-whitespace session needs the trigger below, because SQL's
///   `trim` only strips spaces.
/// - `placeholders.slot >= 1` (正整数); `position >= 0` on both ordered
///   master-data tables (0-based, the loaders' rule).
/// - FK ×3: `scenario_id` SET NULL (删场景,历史归未选), the
///   self-referencing `source_session_id` SET NULL (来源那场删了置空),
///   `placeholders.session_id` CASCADE (删会话,占位符随灭).
pub const SCHEMA_SQL: &str = "
CREATE TABLE IF NOT EXISTS scenarios (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE CHECK (trim(name) <> ''),
    directive TEXT NOT NULL CHECK (trim(directive) <> ''),
    position INTEGER NOT NULL CHECK (position >= 0)
);

CREATE TABLE IF NOT EXISTS terms (
    id INTEGER PRIMARY KEY,
    text TEXT NOT NULL UNIQUE CHECK (trim(text) <> ''),
    position INTEGER NOT NULL CHECK (position >= 0)
);

CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY,
    created_at_ms INTEGER NOT NULL,
    raw_transcript TEXT NOT NULL CHECK (trim(raw_transcript) <> ''),
    rectified_text TEXT NOT NULL CHECK (trim(rectified_text) <> ''),
    scenario_id INTEGER REFERENCES scenarios(id) ON DELETE SET NULL,
    source_session_id INTEGER REFERENCES sessions(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS placeholders (
    id INTEGER PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    slot INTEGER NOT NULL CHECK (slot >= 1),
    prefill TEXT,
    filled_value TEXT NOT NULL,
    UNIQUE (session_id, slot)
);

CREATE VIEW IF NOT EXISTS sessions_with_scenario AS
SELECT
    sessions.id               AS id,
    sessions.created_at_ms    AS created_at_ms,
    sessions.raw_transcript   AS raw_transcript,
    sessions.rectified_text   AS rectified_text,
    sessions.scenario_id      AS scenario_id,
    scenarios.name            AS scenario_name,
    sessions.source_session_id AS source_session_id
FROM sessions
LEFT JOIN scenarios ON scenarios.id = sessions.scenario_id;

-- The one write guard the checks cannot express: a session that is all
-- whitespace (spaces, tabs, newlines, carriage returns) never enters,
-- even though `trim` alone only strips the spaces. INSERT-only by
-- design: updates never change a session's texts.
CREATE TRIGGER IF NOT EXISTS sessions_reject_all_whitespace
BEFORE INSERT ON sessions
BEGIN
    SELECT RAISE(ABORT, 'a session may not be all whitespace')
    WHERE
        replace(replace(replace(replace(
            NEW.raw_transcript, char(32), ''), char(9), ''), char(10), ''), char(13), '') = ''
        OR replace(replace(replace(replace(
            NEW.rectified_text, char(32), ''), char(9), ''), char(10), ''), char(13), '') = '';
END;
";

/// Every fresh connection runs this: SQLite's foreign keys are OFF by
/// default, and this store's delete semantics (SET NULL / CASCADE) only
/// exist with them on.
pub(super) const FOREIGN_KEYS_ON: &str = "PRAGMA foreign_keys = ON;";

/// The schema version. Bump only with a real layout change (and a
/// migration step for it).
pub(super) const SCHEMA_VERSION: i64 = 1;

/// Prepare a just-opened connection: foreign keys on, then — when the
/// version gate is shut — create the schema and run the one-time legacy
/// file migration, both inside a single transaction whose commit also
/// stamps the version. `dirs` is the config search order the legacy
/// files resolve through.
pub(super) fn init_or_migrate(
    conn: &Connection,
    dirs: &[std::path::PathBuf],
) -> Result<(), StoreError> {
    conn.execute_batch(FOREIGN_KEYS_ON)?;
    let version: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version >= SCHEMA_VERSION {
        return Ok(());
    }
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(SCHEMA_SQL)?;
    let report = migration::run(&tx, dirs)?;
    tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    tx.commit()?;
    // The transaction owns the data; the file removals ride after it,
    // best-effort — a failed delete leaves inert files that nothing
    // reads again (the version gate stays open), so it never undoes the
    // migration.
    report.delete_legacy_files();
    Ok(())
}
