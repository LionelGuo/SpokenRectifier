//! The scenario library's table access (glossary: 场景库): one row per
//! named style directive, ordered by `position`. The editor saves its
//! whole model wholesale; the diff carries each row's id so a rename is
//! an update, not a delete-plus-insert — history rows keep pointing at
//! the scenario they ran under (删场景才归默认, per the FK's SET NULL).

use rusqlite::Connection;

use crate::store::{Store, StoreError};

/// One scenario row, as the pickers and the editor see it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scenario {
    pub id: i64,
    pub name: String,
    pub directive: String,
}

/// One entry of the editor's wholesale save: an existing scenario's id,
/// or `None` for a new one. Entries without their id in the table are
/// insertions; rows whose id is absent from the payload are deletions
/// (their sessions fall back to 未选场景).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScenarioInput {
    pub id: Option<i64>,
    pub name: String,
    pub directive: String,
}

impl Store {
    /// The library in `position` order.
    pub fn list_scenarios(&self) -> Vec<Scenario> {
        let conn = self.connection();
        let Ok(mut stmt) =
            conn.prepare("SELECT id, name, directive FROM scenarios ORDER BY position")
        else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| {
            Ok(Scenario {
                id: row.get(0)?,
                name: row.get(1)?,
                directive: row.get(2)?,
            })
        });
        match rows {
            Ok(rows) => rows.collect::<Result<Vec<_>, _>>().unwrap_or_default(),
            Err(_) => Vec::new(),
        }
    }

    /// Save the editor's whole model in one transaction: normalize
    /// (trim; refuse blank names, blank directives, and duplicated
    /// names — the same tolerance rules the file writer enforced),
    /// update identified rows in place (a rename keeps its id and its
    /// history references), insert the new ones, delete the rest, and
    /// rewrite `position` in payload order.
    pub fn save_scenarios(&self, entries: &[ScenarioInput]) -> Result<(), StoreError> {
        let mut normalized: Vec<(Option<i64>, String, String)> = Vec::new();
        let mut names = std::collections::HashSet::new();
        for entry in entries {
            let name = entry.name.trim();
            let directive = entry.directive.trim();
            if name.is_empty() || directive.is_empty() {
                return Err(StoreError(
                    "a scenario needs both a name and a directive".into(),
                ));
            }
            if !names.insert(name.to_string()) {
                return Err(StoreError(format!("a duplicated scenario name: {name}")));
            }
            normalized.push((entry.id, name.to_string(), directive.to_string()));
        }
        let kept: Vec<i64> = normalized.iter().filter_map(|(id, _, _)| *id).collect();

        let mut conn = self.connection();
        let tx = conn.transaction()?;
        // The rows that existed before this save: the deletion set is
        // their remainder against the payload's ids — never the rows
        // this save just inserted.
        let existing: Vec<i64> = {
            let mut stmt = tx.prepare("SELECT id FROM scenarios")?;
            let rows = stmt.query_map([], |row| row.get::<_, i64>(0))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        // Deletions first: a rename onto a deleted row's old name lands
        // clean once that row is gone.
        let dropped: Vec<i64> = existing
            .into_iter()
            .filter(|id| !kept.contains(id))
            .collect();
        if !dropped.is_empty() {
            let placeholders = vec!["?"; dropped.len()].join(", ");
            tx.execute(
                &format!("DELETE FROM scenarios WHERE id IN ({placeholders})"),
                rusqlite::params_from_iter(dropped.iter()),
            )?;
        }
        // Then the name dance: stash every kept row's name under a
        // per-row temporary first, so a rename or reorder never
        // transiently collides with another row's old name (SQLite
        // checks uniqueness per statement, not per transaction — even a
        // reorder that rewrites an unchanged name onto its own row would
        // collide with the row beside it).
        for id in &kept {
            tx.execute(
                "UPDATE scenarios SET name = ? WHERE id = ?",
                (format!("__sr_stash_{id}"), id),
            )?;
        }
        for (position, (id, name, directive)) in normalized.into_iter().enumerate() {
            match id {
                Some(id) => {
                    let changed = tx.execute(
                        "UPDATE scenarios SET name = ?, directive = ?, position = ?
                         WHERE id = ?",
                        (name.as_str(), directive.as_str(), position as i64, id),
                    )?;
                    if changed == 0 {
                        return Err(StoreError(format!(
                            "the scenario #{id} no longer exists; re-open the editor \
                             and save again"
                        )));
                    }
                }
                None => {
                    tx.execute(
                        "INSERT INTO scenarios (name, directive, position) VALUES (?, ?, ?)",
                        (name.as_str(), directive.as_str(), position as i64),
                    )?;
                }
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// The store's connection, locked for the call — the shared helper
    /// every table-access method in this crate starts from.
    pub(crate) fn connection(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap()
    }
}
