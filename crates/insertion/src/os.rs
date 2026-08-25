//! The OS seam: everything platform-touching about insertion, behind one
//! trait. Production is Win32 (`cfg(windows)`); tests drive a recording
//! fake, so the orchestration is deterministic on any platform.

/// What the clipboard held before we replaced it, handed back verbatim on
/// restore. Raw bytes per clipboard format id; `Empty` restores an empty
/// clipboard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SavedClipboard {
    Empty,
    Formats(Vec<(u32, Vec<u8>)>),
}

/// The platform operations insertion needs. Implementations must be safe
/// to call from any thread (the engine awaits `insert` wherever the
/// command lands).
pub trait InputOs: Send + Sync + 'static {
    /// Snapshot the clipboard's contents (whatever formats the
    /// implementation preserves).
    fn clipboard_save(&self) -> Result<SavedClipboard, String>;

    /// Put `text` on the clipboard as Unicode text.
    fn clipboard_set_text(&self, text: &str) -> Result<(), String>;

    /// Put a saved snapshot back. `SavedClipboard::Empty` clears the
    /// clipboard.
    fn clipboard_restore(&self, saved: SavedClipboard) -> Result<(), String>;

    /// Remember the current foreground window as the insertion target.
    /// Implementations skip windows owned by this process: starting a
    /// session from our own orb must not make us our own target.
    fn note_target(&self);

    /// Bring the remembered target back to the foreground. Returns
    /// whether a target was remembered and activation was attempted.
    fn activate_target(&self) -> bool;

    /// Whether the window currently holding the foreground belongs to
    /// this process. With no remembered target and our own window in the
    /// foreground, there is nothing to insert into — the flows refuse
    /// instead of pasting into ourselves.
    fn foreground_is_own_process(&self) -> bool;

    /// Send a Ctrl+V paste keystroke to the foreground window.
    fn send_paste(&self) -> Result<(), String>;

    /// Type one character (Unicode-aware).
    fn send_char(&self, ch: char) -> Result<(), String>;

    /// Send one Enter keypress.
    fn send_enter(&self) -> Result<(), String>;

    /// Sleep for the given milliseconds. Sync by design: the pacing is
    /// part of the protocol with the target app.
    fn wait_ms(&self, ms: u64);
}

/// The non-Windows production layer: every operation fails. The app
/// targets Windows; other builds exist for tests and headless demos, where
/// insertion is never more than an error event away from honest.
#[cfg(not(windows))]
#[derive(Debug)]
pub struct UnsupportedOs;

#[cfg(not(windows))]
impl InputOs for UnsupportedOs {
    fn clipboard_save(&self) -> Result<SavedClipboard, String> {
        Err("text insertion is only implemented on Windows".into())
    }

    fn clipboard_set_text(&self, _text: &str) -> Result<(), String> {
        Err("text insertion is only implemented on Windows".into())
    }

    fn clipboard_restore(&self, _saved: SavedClipboard) -> Result<(), String> {
        Err("text insertion is only implemented on Windows".into())
    }

    fn note_target(&self) {}

    fn activate_target(&self) -> bool {
        false
    }

    fn foreground_is_own_process(&self) -> bool {
        false
    }

    fn send_paste(&self) -> Result<(), String> {
        Err("text insertion is only implemented on Windows".into())
    }

    fn send_char(&self, _ch: char) -> Result<(), String> {
        Err("text insertion is only implemented on Windows".into())
    }

    fn send_enter(&self) -> Result<(), String> {
        Err("text insertion is only implemented on Windows".into())
    }

    fn wait_ms(&self, ms: u64) {
        std::thread::sleep(std::time::Duration::from_millis(ms));
    }
}
