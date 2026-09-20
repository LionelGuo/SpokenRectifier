//! The store itself: one SQLite connection behind a mutex (every call
//! is short — single-row statements on a local file), the sessions
//! domain (record, list, clear, retention sweep), and the keep-nothing
//! mode as a rows-level switch — the database always exists, because it
//! is the only home scenarios and terms have too; 不留存 clears and
//! holds the sessions table empty, it never removes the file.
//!
//! Retention is lazy, exactly as before: expired rows are swept when
//! the store opens, when a session is recorded, and before every read.
//! All sweep points read the injected wall clock, so retention is
//! deterministic under tests and correct across process restarts.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::{Connection, OptionalExtension};

use spokenrectifier_engine::provider::history::{RecordedSession, SessionRecorder};

use crate::config::HistoryConfig;
use crate::schema;

/// Retention as a millisecond budget (the sweep's cutoff arithmetic).
fn retention_ms(retention_days: u64) -> u64 {
    retention_days.saturating_mul(24 * 60 * 60 * 1000)
}

/// Injected wall clock: Unix-epoch milliseconds. Real impl
/// [`wall_clock`]; tests hand in a settable one.
pub type NowMs = Arc<dyn Fn() -> u64 + Send + Sync>;

/// The real wall clock.
pub fn wall_clock() -> NowMs {
    Arc::new(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    })
}

/// The database file name inside the resolved directory.
pub const STORE_DB_FILE: &str = "spokenrectifier-store.db";

/// One stored session, as the history panel sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryEntry {
    pub id: i64,
    pub created_at_ms: u64,
    pub raw_transcript: String,
    pub rectified_text: String,
}

#[derive(Debug, thiserror::Error)]
#[error("store: {0}")]
pub struct StoreError(pub String);

impl From<rusqlite::Error> for StoreError {
    fn from(err: rusqlite::Error) -> Self {
        StoreError(err.to_string())
    }
}

/// The keep-nothing switch and the retention budget, under one lock so
/// [`Store::apply_config`] flips them atomically for every reader.
#[derive(Clone, Copy)]
struct Policy {
    record_enabled: bool,
    retention_ms: u64,
}

pub struct Store {
    pub(crate) conn: Mutex<Connection>,
    policy: Mutex<Policy>,
    now_ms: NowMs,
}

impl Store {
    /// Open the store: resolve the database among `dirs` (first writable
    /// wins, the config layer order), run the one-time migration against
    /// those same directories, and sweep expired rows. Nowhere writable
    /// — or a failed migration, whose legacy files stay put for the next
    /// launch to retry — degrades to an in-memory store for this run:
    /// the store is a convenience and never blocks startup.
    pub fn open(
        dirs: &[PathBuf],
        config: HistoryConfig,
        now_ms: NowMs,
    ) -> Result<Self, StoreError> {
        let Some(path) = resolve_store_path(dirs) else {
            eprintln!(
                "spokenrectifier-store: no writable directory for the store \
                 database; continuing without one for this run"
            );
            return Ok(Self::open_memory(config, now_ms));
        };
        match Self::open_at(&path, dirs, config, now_ms.clone()) {
            Ok(store) => Ok(store),
            Err(err) => {
                eprintln!(
                    "spokenrectifier-store: opening {} failed ({err}); the legacy \
                     files, if any, are untouched and the next launch retries",
                    path.display()
                );
                Ok(Self::open_memory(config, now_ms))
            }
        }
    }

    /// Open the store at an explicit path (tests, or a caller with its
    /// own location policy), migrating the legacy files resolved through
    /// `dirs`. Sweeps expired rows on open; the keep-nothing config
    /// clears the sessions table here too.
    pub fn open_at(
        path: &Path,
        dirs: &[PathBuf],
        config: HistoryConfig,
        now_ms: NowMs,
    ) -> Result<Self, StoreError> {
        let conn = Connection::open(path)
            .map_err(|err| StoreError(format!("{}: {err}", path.display())))?;
        Self::connect(conn, dirs, config, now_ms)
    }

    /// The ephemeral store: a fresh in-memory database with the full
    /// schema and no migration. The fake engine's home (tests and
    /// headless demos keep no files), and the degraded fallback when no
    /// database location is available.
    pub fn open_memory(config: HistoryConfig, now_ms: NowMs) -> Self {
        let conn = Connection::open_in_memory().expect("an in-memory database always opens");
        Self::connect(conn, &[], config, now_ms).expect("an in-memory schema always initializes")
    }

    fn connect(
        conn: Connection,
        dirs: &[PathBuf],
        config: HistoryConfig,
        now_ms: NowMs,
    ) -> Result<Self, StoreError> {
        schema::init_or_migrate(&conn, dirs)?;
        let store = Store {
            conn: Mutex::new(conn),
            policy: Mutex::new(Policy {
                record_enabled: config.enabled,
                retention_ms: retention_ms(config.retention_days),
            }),
            now_ms,
        };
        if config.enabled {
            store.sweep()?;
        } else {
            store.clear_sessions()?;
        }
        Ok(store)
    }

    /// Apply a runtime config change (the settings window's controls):
    /// a new retention takes effect at once (the sweep runs eagerly, so
    /// a tightened period hides old rows immediately), and the
    /// keep-nothing mode clears the sessions table and holds it empty —
    /// the file itself stays, as the scenarios' and terms' only home.
    pub fn apply_config(&self, config: HistoryConfig) -> Result<(), StoreError> {
        {
            let mut policy = self.policy.lock().unwrap();
            policy.retention_ms = retention_ms(config.retention_days);
            policy.record_enabled = config.enabled;
        }
        if config.enabled {
            self.sweep()
        } else {
            self.clear_sessions()
        }
    }

    /// Expired rows go (placeholders with them, by CASCADE). Called on
    /// open, on record, and before every read.
    fn sweep(&self) -> Result<(), StoreError> {
        let retention_ms = self.policy.lock().unwrap().retention_ms;
        let cutoff = (self.now_ms)().saturating_sub(retention_ms) as i64;
        self.conn
            .lock()
            .unwrap()
            .execute("DELETE FROM sessions WHERE created_at_ms <= ?", (cutoff,))?;
        Ok(())
    }

    /// Every stored session row — keep-nothing's own clear, and the
    /// tray's one-click clear shares it.
    fn clear_sessions(&self) -> Result<(), StoreError> {
        self.conn
            .lock()
            .unwrap()
            .execute("DELETE FROM sessions", ())
            .map(|_| ())
            .map_err(StoreError::from)
    }

    /// The most recent sessions, newest first, read through the
    /// sessions⋈scenarios view. Sweeps first: the panel must never show
    /// a row past its retention, however long the process has run.
    pub fn list(&self, limit: usize) -> Vec<HistoryEntry> {
        let _ = self.sweep();
        let conn = self.conn.lock().unwrap();
        let Ok(mut stmt) = conn.prepare(
            "SELECT id, created_at_ms, raw_transcript, rectified_text
             FROM sessions_with_scenario ORDER BY id DESC LIMIT ?",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([limit as i64], |row| {
            Ok(HistoryEntry {
                id: row.get(0)?,
                created_at_ms: row.get::<_, i64>(1)?.max(0) as u64,
                raw_transcript: row.get(2)?,
                rectified_text: row.get(3)?,
            })
        });
        match rows {
            Ok(rows) => rows.collect::<Result<Vec<_>, _>>().unwrap_or_default(),
            Err(_) => Vec::new(),
        }
    }

    /// Remove every stored session (the tray's one-click clear). A
    /// failed clear surfaces nowhere by design: the next list still
    /// shows whatever survived, and the user can retry.
    pub fn clear(&self) {
        let _ = self.clear_sessions();
    }

    /// Insert one finished session, resolving the pass-throughs: the
    /// scenario NAME becomes a scenario id (a name that no longer
    /// resolves records as 未选场景), and a source row that vanished
    /// mid-session records as none — the same SET NULL philosophy the
    /// schema applies on delete.
    fn insert_session(&self, session: &RecordedSession) -> Result<(), StoreError> {
        let conn = self.conn.lock().unwrap();
        let scenario_id: Option<i64> = match &session.scenario {
            Some(name) => conn
                .query_row(
                    "SELECT id FROM scenarios WHERE name = ?",
                    (name.as_str(),),
                    |row| row.get(0),
                )
                .optional()?,
            None => None,
        };
        let source_session_id = match session.source_session_id {
            Some(id) => conn
                .query_row("SELECT 1 FROM sessions WHERE id = ?", (id,), |_| Ok(()))
                .optional()?
                .map(|_| id),
            None => None,
        };
        conn.execute(
            "INSERT INTO sessions
                 (created_at_ms, raw_transcript, rectified_text, scenario_id, source_session_id)
             VALUES (?, ?, ?, ?, ?)",
            (
                (self.now_ms)() as i64,
                session.raw_transcript.as_str(),
                session.rectified_text.as_str(),
                scenario_id,
                source_session_id,
            ),
        )?;
        Ok(())
    }
}

impl SessionRecorder for Store {
    fn record(&self, session: RecordedSession) {
        if !self.policy.lock().unwrap().record_enabled {
            return;
        }
        // Sweep first, then insert: the new row's timestamp is always
        // inside retention, so the sweep can never take it.
        let _ = self.sweep();
        if let Err(err) = self.insert_session(&session) {
            // A failed write degrades to not recording this session,
            // never to failing the insert it follows.
            eprintln!("spokenrectifier-store: cannot record the session: {err}");
        }
    }
}

/// The first directory in `dirs` a database file could live in: probe by
/// creating and removing a scratch file next to where the database would
/// go. `None` when nowhere qualifies.
pub fn resolve_store_path(dirs: &[PathBuf]) -> Option<PathBuf> {
    dirs.iter()
        .find(|dir| dir.is_dir() && dir_writable(dir))
        .map(|dir| dir.join(STORE_DB_FILE))
}

fn dir_writable(dir: &Path) -> bool {
    let probe = dir.join(format!(".{STORE_DB_FILE}-probe"));
    let writable = std::fs::write(&probe, b"").is_ok();
    let _ = std::fs::remove_file(&probe);
    writable
}
