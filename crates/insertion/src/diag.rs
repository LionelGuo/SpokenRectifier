//! The insertion diagnostic record (25 号票): every insert's OS-level
//! facts land here, because the real machine has no console a GUI
//! subsystem exe can write to (oss-quality 07) and the on-screen error
//! short sentence deliberately classifies the raw message away.
//!
//! The seam follows the perf log's conventions: the file resolves in the
//! first writable search directory (the working directory before the
//! exe's — dev runs vs a double-clicked portable exe), each run stamps a
//! `--- run <time> ---` header, lines append one open per call, and a
//! disk that fails or vanishes retires the sink silently — diagnostics
//! must never be able to break the insertion it observes. One guard the
//! perf log does not need: a cap. Insertion is the app's hot path, so a
//! run start trims a record past 1 MiB back to the header alone.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// The record file's name, resolved inside the config search dirs — a
/// neighbor of `spokenrectifier-perf.log` and the toml files.
pub const DIAG_LOG_FILE: &str = "spokenrectifier-insert.log";

/// A run start trims the record back to nothing once it grows past
/// this: diagnostics stay bounded without a rotation scheme to maintain.
const MAX_BYTES: u64 = 1024 * 1024;

/// The record sink. `None`-like when no directory was writable or the
/// disk retired the file mid-run — every method is a no-op then.
#[derive(Debug)]
pub struct DiagLog {
    path: Mutex<Option<PathBuf>>,
}

impl DiagLog {
    /// A sink that records nowhere — tests and non-Windows builds.
    pub fn disabled() -> Self {
        Self {
            path: Mutex::new(None),
        }
    }

    /// Point the sink at the first writable dir among `dirs`, stamping
    /// the run's header line and trimming an overgrown record. When
    /// nothing is writable the sink stays disabled and every log is a
    /// no-op.
    pub fn open_in(dirs: &[PathBuf]) -> Self {
        for dir in dirs {
            let path = dir.join(DIAG_LOG_FILE);
            if overgrown(&path) && std::fs::remove_file(&path).is_err() {
                continue; // unwritable in a way the header write would hit too
            }
            let sink = Self {
                path: Mutex::new(Some(path.clone())),
            };
            if sink.write_line(&format!("--- run {} ---", now_stamp())) {
                return sink;
            }
        }
        Self::disabled()
    }

    /// Append one fact line. The record exists to be read beside a
    /// failure report, so a line carries its own timestamp.
    pub fn log(&self, facts: &str) {
        let stamp = now_stamp();
        self.write_line(&format!("[{stamp}] {facts}"));
    }

    /// Append one line, opening per call (a held handle would keep a
    /// deleted file alive; an open per insert-frequency call is free).
    /// Retires the sink when the write cannot land. Returns whether it
    /// did.
    fn write_line(&self, line: &str) -> bool {
        let mut slot = self.path.lock().unwrap();
        let Some(path) = slot.as_ref() else {
            return false;
        };
        let landed = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .and_then(|mut file| {
                file.write_all(line.as_bytes())?;
                file.write_all(b"\n")
            })
            .is_ok();
        if !landed {
            // The disk went away mid-run: a no-op sink from here.
            *slot = None;
        }
        landed
    }
}

/// Whether the record has outgrown its cap (a missing file has not).
fn overgrown(path: &Path) -> bool {
    std::fs::metadata(path).map(|m| m.len() > MAX_BYTES).unwrap_or(false)
}

/// Local-wall-clock-ish stamp without a date dependency: civil date
/// from epoch days (Hinnant's algorithm), then h:m:s.millis. The stamp
/// orients a reader next to a failure report; it is not parsed back.
fn now_stamp() -> String {
    let dur = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let millis = dur.subsec_millis();
    let secs = dur.as_secs();
    let (year, month, day) = civil_from_days((secs / 86_400) as i64);
    let clock = secs % 86_400;
    let (h, m, s) = (clock / 3600, (clock % 3600) / 60, clock % 60);
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}.{millis:03}")
}

/// Days since 1970-01-01 to (y, m, d) — the era-safe civil-from-days
/// algorithm, valid for the whole second-count the clock can hand it.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "sr-insert-diag-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_disabled_sink_swallows_lines() {
        DiagLog::disabled().log("nothing");
    }

    #[test]
    fn lines_append_with_the_run_header_above() {
        let dir = temp_dir();
        let log = DiagLog::open_in(std::slice::from_ref(&dir));
        log.log("note source=foreground target=0x1 class=X");
        let text = std::fs::read_to_string(dir.join(DIAG_LOG_FILE)).unwrap();
        let mut lines = text.lines();
        let header = lines.next().unwrap();
        assert!(header.starts_with("--- run "), "got: {header}");
        let fact = lines.next().unwrap();
        assert!(fact.contains("note source=foreground"), "got: {fact}");
        assert!(fact.ends_with("class=X"), "got: {fact}");
        assert!(lines.next().is_none(), "exactly one fact line");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_unwritable_dir_falls_through_to_the_next_one() {
        let dir = temp_dir();
        let nowhere = dir.join("not-a-dir");
        let sink = DiagLog::open_in(&[nowhere, dir.clone()]);
        sink.log("past=the-fallthrough");
        let text = std::fs::read_to_string(dir.join(DIAG_LOG_FILE)).unwrap();
        assert!(text.contains("past=the-fallthrough"), "got: {text}");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_overgrown_record_is_trimmed_at_run_start() {
        let dir = temp_dir();
        let path = dir.join(DIAG_LOG_FILE);
        std::fs::write(&path, vec![b'x'; MAX_BYTES as usize + 10]).unwrap();
        DiagLog::open_in(std::slice::from_ref(&dir));
        let len = std::fs::metadata(&path).unwrap().len();
        assert!(len < 200, "trimmed to the header alone, got {len} bytes");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_mid_run_failure_retires_the_sink() {
        let dir = temp_dir();
        let log = DiagLog::open_in(std::slice::from_ref(&dir));
        std::fs::remove_dir_all(&dir).unwrap(); // the disk went away
        log.log("retired=silently"); // must not panic
    }

    #[test]
    fn civil_dates_match_known_days() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(19_723), (2024, 1, 1));
        assert_eq!(civil_from_days(19_782), (2024, 2, 29)); // the leap day
        assert_eq!(civil_from_days(20_696), (2026, 8, 31));
    }
}
