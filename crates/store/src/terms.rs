//! The hotword dictionary's table access (glossary: 术语词表): one row
//! per term, ordered by `position` — 转写从前往后用. The quick panel's
//! quick-add and the settings editor's add/rename/remove ride the same
//! three calls, so an edit is live for the next session's dictionary
//! read (the engine re-reads per session, exactly as it did the file).

use std::path::PathBuf;

use rusqlite::{Connection, OpenFlags, OptionalExtension};

use crate::store::{STORE_DB_FILE, Store, StoreError};

/// The shared writer guard: a dictionary entry is its trimmed self, and
/// an empty entry is no entry at all.
fn reject_blank(term: &str) -> Result<&str, StoreError> {
    let term = term.trim();
    if term.is_empty() {
        Err(StoreError("a term may not be blank".into()))
    } else {
        Ok(term)
    }
}

impl Store {
    /// The dictionary in `position` order.
    pub fn list_terms(&self) -> Vec<String> {
        let conn = self.connection();
        let Ok(mut stmt) = conn.prepare("SELECT text FROM terms ORDER BY position") else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| row.get::<_, String>(0));
        match rows {
            Ok(rows) => rows.collect::<Result<Vec<_>, _>>().unwrap_or_default(),
            Err(_) => Vec::new(),
        }
    }

    /// Quick-add one term at the end of the dictionary — idempotent
    /// (a term already held is left alone), blank rejected.
    pub fn append_term(&self, term: &str) -> Result<(), StoreError> {
        let term = reject_blank(term)?;
        self.connection().execute(
            "INSERT OR IGNORE INTO terms (text, position)
             VALUES (?, (SELECT COALESCE(MAX(position), -1) + 1 FROM terms))",
            (term,),
        )?;
        Ok(())
    }

    /// Remove a term (a no-op when absent) and close the gap it leaves:
    /// the renumber rides the same transaction as the delete, so no
    /// reader ever sees a hole in the positions.
    pub fn remove_term(&self, term: &str) -> Result<(), StoreError> {
        let term = reject_blank(term)?;
        let mut conn = self.connection();
        let Some(position) = conn
            .query_row(
                "SELECT position FROM terms WHERE text = ?",
                (term,),
                |row| row.get::<_, i64>(0),
            )
            .optional()?
        else {
            return Ok(()); // not present: nothing to do
        };
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM terms WHERE text = ?", (term,))?;
        tx.execute(
            "UPDATE terms SET position = position - 1 WHERE position > ?",
            (position,),
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Rename a term in place, keeping its position — an error when the
    /// new name is already held (the editor wants one entry per term)
    /// or the old one is gone (the caller's model is stale).
    pub fn update_term(&self, old: &str, new: &str) -> Result<(), StoreError> {
        let old = reject_blank(old)?;
        let new = reject_blank(new)?;
        let conn = self.connection();
        let held: Option<i64> = conn
            .query_row("SELECT id FROM terms WHERE text = ?", (new,), |row| {
                row.get(0)
            })
            .optional()?;
        if held.is_some() {
            return Err(StoreError(format!(
                "the dictionary already holds \"{new}\""
            )));
        }
        let changed = conn.execute("UPDATE terms SET text = ? WHERE text = ?", (new, old))?;
        if changed == 0 {
            return Err(StoreError(format!(
                "the term \"{old}\" is not in the dictionary"
            )));
        }
        Ok(())
    }
}

/// Read the dictionary without opening the store: for tools that share
/// the dictionary but must not write (or migrate) — the CLI. The store
/// database wins when it is initialized; otherwise this is exactly the
/// legacy file read. Never writes, never migrates.
pub fn peek_terms(dirs: &[PathBuf]) -> Vec<String> {
    for dir in dirs {
        let path = dir.join(STORE_DB_FILE);
        if !path.is_file() {
            continue;
        }
        let Ok(conn) = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY) else {
            continue;
        };
        let Ok(version) = conn.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
        else {
            continue;
        };
        if version < 1 {
            continue;
        }
        if let Ok(mut stmt) = conn.prepare("SELECT text FROM terms ORDER BY position")
            && let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(0))
            && let Ok(terms) = rows.collect::<Result<Vec<_>, _>>()
        {
            return terms;
        }
    }
    // No initialized store anywhere: the dictionary is still a file.
    spokenrectifier_config::terms::load_terms(dirs)
}
