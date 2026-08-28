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
//!
//! The settings window can change the `[history]` config while the app
//! runs (保留期 / 不留存, ticket 18): [`HistoryStore::apply_config`]
//! retightens retention on the open database or flips the keep-nothing
//! mode in place — the engine and the bridge hold the same store, so
//! both see the change without anyone rebuilding them.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::Connection;

use spokenrectifier_engine::provider::history::{RecordedSession, SessionRecorder};

use crate::config::HistoryConfig;

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
/// keeping nothing at all (the keep-nothing config, or nowhere
/// writable). The mode lives behind a mutex so it can flip at runtime
/// ([`HistoryStore::apply_config`]) on the one instance the engine
/// records into and the panels read from.
pub struct HistoryStore {
    state: Mutex<State>,
    now_ms: NowMs,
    /// The directories the database resolves among — kept so the
    /// keep-nothing mode can turn back off at runtime and find (or
    /// re-create) a home.
    dirs: Vec<PathBuf>,
}

enum State {
    /// Keep-nothing (or nowhere writable): nothing is recorded, and
    /// every database file the search order knows is gone.
    Off,
    On(SqliteHistory),
}

impl Default for HistoryStore {
    /// The off store with no home: the fake engine's placeholder (tests
    /// and headless demos keep no files, so `apply_config` has nowhere
    /// to open either).
    fn default() -> Self {
        Self {
            state: Mutex::new(State::Off),
            now_ms: wall_clock(),
            dirs: Vec::new(),
        }
    }
}

impl HistoryStore {
    fn off(dirs: Vec<PathBuf>, now_ms: NowMs) -> Self {
        Self {
            state: Mutex::new(State::Off),
            now_ms,
            dirs,
        }
    }

    /// Open the store: resolve the database among `dirs` (first writable
    /// wins, the config layer order) and sweep expired rows. Falls back
    /// to the keep-nothing mode when history is off or no directory is
    /// writable — history is a convenience and never blocks startup over
    /// a database location. (A malformed `[history]` layer still fails
    /// the caller, like every other config section.)
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
            return Ok(Self::off(dirs.to_vec(), now_ms));
        }
        let Some(path) = resolve_db_path(dirs) else {
            eprintln!(
                "spokenrectifier-history: no writable directory for the \
                 history database; keeping no history"
            );
            return Ok(Self::off(dirs.to_vec(), now_ms));
        };
        Self::open_at(&path, config, now_ms)
    }

    /// Open the store at an explicit path (tests, or a caller with its
    /// own location policy). Sweeps expired rows on open. The keep-nothing
    /// config holds here too — an existing file at the path is wiped.
    /// The path's directory becomes the store's search order, so a
    /// later [`Self::apply_config`] re-resolves to the same home.
    pub fn open_at(
        path: &Path,
        config: HistoryConfig,
        now_ms: NowMs,
    ) -> Result<Self, HistoryError> {
        let dirs = path
            .parent()
            .map(|dir| vec![dir.to_path_buf()])
            .unwrap_or_default();
        if !config.enabled {
            let _ = std::fs::remove_file(path);
            return Ok(Self::off(dirs, now_ms));
        }
        let sqlite = SqliteHistory::open(path, config.retention_days, now_ms.clone())?;
        Ok(Self {
            state: Mutex::new(State::On(sqlite)),
            now_ms,
            dirs,
        })
    }

    /// Apply a runtime config change (the settings window's controls):
    /// a new retention takes effect at once (the sweep runs eagerly, so
    /// a tightened period hides old rows immediately), and flipping the
    /// keep-nothing mode behaves exactly like opening the store under
    /// the new config — turning it ON clears and removes the database
    /// files; turning it OFF re-resolves a home among the search order
    /// and resumes recording.
    pub fn apply_config(&self, config: HistoryConfig) -> Result<(), HistoryError> {
        let mut state = self.state.lock().unwrap();
        match (&mut *state, config.enabled) {
            (State::On(sqlite), true) => {
                sqlite.retention_ms = retention_ms(config.retention_days);
                let _ = sqlite.sweep();
                Ok(())
            }
            (State::On(sqlite), false) => {
                // Empty first (a removed-but-locked file would otherwise
                // keep its rows), then close the connection so the file
                // can go, then remove the live file and every canonical
                // database the search order knows (open_at may sit on a
                // caller-chosen name).
                let path = sqlite.path.clone();
                let _ = sqlite.clear();
                *state = State::Off; // drops the connection
                let _ = std::fs::remove_file(&path);
                for dir in &self.dirs {
                    let _ = std::fs::remove_file(dir.join(DB_FILE));
                }
                Ok(())
            }
            (State::Off, true) => {
                // Nowhere writable is the off store's own situation too:
                // staying off is the same fallback `open` makes.
                let Some(path) = resolve_db_path(&self.dirs) else {
                    return Ok(());
                };
                let sqlite =
                    SqliteHistory::open(&path, config.retention_days, self.now_ms.clone())?;
                *state = State::On(sqlite);
                Ok(())
            }
            (State::Off, false) => Ok(()),
        }
    }

    /// The most recent sessions, newest first. Sweeps first: the panel
    /// must never show a row past its retention, however long the
    /// process has been running.
    pub fn list(&self, limit: usize) -> Vec<HistoryEntry> {
        match &*self.state.lock().unwrap() {
            State::Off => Vec::new(),
            State::On(store) => {
                let _ = store.sweep();
                store.list(limit).unwrap_or_default()
            }
        }
    }

    /// Remove every stored session. A no-op when off.
    pub fn clear(&self) {
        if let State::On(store) = &*self.state.lock().unwrap() {
            // A failed clear surfaces nowhere by design: the next list
            // still shows whatever survived, and the user can retry.
            let _ = store.clear();
        }
    }
}

impl SessionRecorder for HistoryStore {
    fn record(&self, session: RecordedSession) {
        if let State::On(store) = &*self.state.lock().unwrap() {
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
    /// Where this database lives — the file a mode flip removes.
    path: PathBuf,
}

impl SqliteHistory {
    /// Open (creating if needed), migrate, and sweep the database at
    /// `path` for the given retention.
    fn open(path: &Path, retention_days: u64, now_ms: NowMs) -> Result<Self, HistoryError> {
        let conn = Connection::open(path)
            .map_err(|err| HistoryError(format!("{}: {err}", path.display())))?;
        let store = SqliteHistory {
            conn: Mutex::new(conn),
            retention_ms: retention_ms(retention_days),
            now_ms,
            path: path.to_path_buf(),
        };
        store.migrate()?;
        store.sweep()?;
        Ok(store)
    }

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
            .execute("DELETE FROM sessions", ())
            .map(|_| ())
            .map_err(HistoryError::from)
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
