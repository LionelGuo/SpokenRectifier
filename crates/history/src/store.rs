//! The history store: SQLite persistence of every inserted session's raw
//! transcript and rectified text (glossary: 历史与取回).
//!
//! Only text is ever persisted — audio exists in memory alone, and this
//! store is the single place finished sessions land on disk. Recording is
//! fire-and-forget per the port: a failed write degrades to not recording
//! that session, never to failing the insert it follows.
//!
//! Retention is lazy: expired rows are swept when the store opens, when
//! a session is recorded, and before every read. All sweep points read
//! the injected wall clock, so retention is deterministic under tests
//! and correct across process restarts (unlike a monotonic clock, which
//! resets its epoch with every launch).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::Connection;

use spokenrectifier_engine::provider::history::{RecordedSession, SessionRecorder};

use crate::config::HistoryConfig;

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
const DB_FILE: &str = "spokenrectifier-history.db";

/// One stored session, as the history panel sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryEntry {
    pub id: i64,
    pub created_at_ms: u64,
    pub raw_transcript: String,
    pub rectified_text: String,
}

#[derive(Debug, thiserror::Error)]
#[error("history: {0}")]
pub struct HistoryError(pub String);

impl From<rusqlite::Error> for HistoryError {
    fn from(err: rusqlite::Error) -> Self {
        HistoryError(err.to_string())
    }
}

/// The store, in one of its two modes: keeping sessions in SQLite, or
/// keeping nothing at all (the keep-nothing config, or nowhere writable).
#[derive(Default)]
pub enum HistoryStore {
    #[default]
    Disabled,
    Sqlite(SqliteHistory),
}

impl HistoryStore {
    /// Open the store: resolve the database among `dirs` (first writable
    /// wins, the config layer order) and sweep expired rows. Falls back
    /// to [`HistoryStore::Disabled`] when history is off or no directory
    /// is writable — history is a convenience and never blocks startup
    /// over a database location. (A malformed `[history]` layer still
    /// fails the caller, like every other config section.)
    pub fn open(
        dirs: &[PathBuf],
        config: HistoryConfig,
        now_ms: NowMs,
    ) -> Result<Self, HistoryError> {
        if !config.enabled {
            // Keep-nothing means nothing on disk either: a database from
            // before the switch is wiped, so nothing resurfaces if
            // history ever comes back on.
            for dir in dirs.iter().filter(|dir| dir.is_dir()) {
                let _ = std::fs::remove_file(dir.join(DB_FILE));
            }
            return Ok(Self::Disabled);
        }
        let Some(path) = resolve_db_path(dirs) else {
            eprintln!(
                "spokenrectifier-history: no writable directory for the \
                 history database; keeping no history"
            );
            return Ok(Self::Disabled);
        };
        Self::open_at(&path, config, now_ms)
    }

    /// Open the store at an explicit path (tests, or a caller with its
    /// own location policy). Sweeps expired rows on open. The keep-nothing
    /// config holds here too — an existing file at the path is wiped.
    pub fn open_at(
        path: &Path,
        config: HistoryConfig,
        now_ms: NowMs,
    ) -> Result<Self, HistoryError> {
        if !config.enabled {
            let _ = std::fs::remove_file(path);
            return Ok(Self::Disabled);
        }
        let conn = Connection::open(path)
            .map_err(|err| HistoryError(format!("{}: {err}", path.display())))?;
        let store = SqliteHistory {
            conn: Mutex::new(conn),
            retention_ms: config.retention_days.saturating_mul(24 * 60 * 60 * 1000),
            now_ms,
        };
        store.migrate()?;
        store.sweep()?;
        Ok(Self::Sqlite(store))
    }

    /// The most recent sessions, newest first. Sweeps first: the panel
    /// must never show a row past its retention, however long the
    /// process has been running.
    pub fn list(&self, limit: usize) -> Vec<HistoryEntry> {
        match self {
            Self::Disabled => Vec::new(),
            Self::Sqlite(store) => {
                let _ = store.sweep();
                store.list(limit).unwrap_or_default()
            }
        }
    }

    /// Remove every stored session. A no-op when disabled.
    pub fn clear(&self) {
        if let Self::Sqlite(store) = self {
            // A failed clear surfaces nowhere by design: the next list
            // still shows whatever survived, and the user can retry.
            let _ = store.clear();
        }
    }
}

impl SessionRecorder for HistoryStore {
    fn record(&self, session: RecordedSession) {
        if let Self::Sqlite(store) = self {
            // Sweep first, then insert: the new row's timestamp is always
            // inside retention, so the sweep can never take it.
            let _ = store.sweep();
            let _ = store.insert(&session);
        }
    }
}

/// The SQLite-backed store. One connection behind a mutex: every call is
/// short (single-row statements on a local file).
pub struct SqliteHistory {
    conn: Mutex<Connection>,
    retention_ms: u64,
    now_ms: NowMs,
}

impl SqliteHistory {
    fn migrate(&self) -> Result<(), HistoryError> {
        self.conn.lock().unwrap().execute(
            "CREATE TABLE IF NOT EXISTS sessions (
                 id INTEGER PRIMARY KEY,
                 created_at_ms INTEGER NOT NULL,
                 raw_transcript TEXT NOT NULL,
                 rectified_text TEXT NOT NULL
             )",
            (),
        )?;
        Ok(())
    }

    fn sweep(&self) -> Result<(), HistoryError> {
        let cutoff = (self.now_ms)().saturating_sub(self.retention_ms) as i64;
        self.conn
            .lock()
            .unwrap()
            .execute("DELETE FROM sessions WHERE created_at_ms <= ?", (cutoff,))?;
        Ok(())
    }

    fn insert(&self, session: &RecordedSession) -> Result<(), HistoryError> {
        self.conn.lock().unwrap().execute(
            "INSERT INTO sessions (created_at_ms, raw_transcript, rectified_text)
             VALUES (?, ?, ?)",
            (
                (self.now_ms)() as i64,
                session.raw_transcript.as_str(),
                session.rectified_text.as_str(),
            ),
        )?;
        Ok(())
    }

    fn list(&self, limit: usize) -> Result<Vec<HistoryEntry>, HistoryError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, created_at_ms, raw_transcript, rectified_text
             FROM sessions ORDER BY id DESC LIMIT ?",
        )?;
        let rows = stmt.query_map([limit as i64], |row| {
            Ok(HistoryEntry {
                id: row.get(0)?,
                created_at_ms: row.get::<_, i64>(1)?.max(0) as u64,
                raw_transcript: row.get(2)?,
                rectified_text: row.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    fn clear(&self) -> Result<(), HistoryError> {
        self.conn
            .lock()
            .unwrap()
            .execute("DELETE FROM sessions", ())?;
        Ok(())
    }
}

/// The first directory in `dirs` a database file could live in: probe by
/// creating and removing a scratch file next to where the database would
/// go. `None` when nowhere qualifies.
pub fn resolve_db_path(dirs: &[PathBuf]) -> Option<PathBuf> {
    dirs.iter()
        .find(|dir| dir.is_dir() && dir_writable(dir))
        .map(|dir| dir.join(DB_FILE))
}

fn dir_writable(dir: &Path) -> bool {
    let probe = dir.join(format!(".{DB_FILE}-probe"));
    let writable = std::fs::write(&probe, b"").is_ok();
    let _ = std::fs::remove_file(&probe);
    writable
}
