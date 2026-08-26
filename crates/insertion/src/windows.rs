//! The Win32 [`InputOs`]: clipboard save/restore over global memory,
//! keystrokes over `SendInput`, and the foreground window as the
//! insertion target.
//!
//! Only the two-liner would be untestable here; everything with logic to
//! it lives in the crate's OS-agnostic orchestration and is covered by the
//! fake-driven tests.

use std::sync::Mutex;

use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{
    GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBD_EVENT_FLAGS, KEYBDINPUT,
    KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, SendInput, VIRTUAL_KEY, VK_CONTROL, VK_LWIN, VK_MENU,
    VK_RETURN, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetWindowTextW, GetWindowThreadProcessId, SetForegroundWindow,
};

use crate::os::{InjectedKey, InputOs, SavedClipboard, paced_paste_script};

// Standard clipboard format ids (documented Win32 constants, stable ABI;
// declared locally so the Ole feature is not pulled in for numbers).
const CF_DIB: u32 = 8;
const CF_UNICODETEXT: u32 = 13;
const CF_HDROP: u32 = 15;

/// The formats preserved across a paste: text, bitmap images
/// (screenshots), and file lists. Synthesized and exotic application
/// formats are not — a documented boundary of the clipboard restore.
const PRESERVED_FORMATS: [u32; 3] = [CF_UNICODETEXT, CF_DIB, CF_HDROP];

pub struct Win32Os {
    /// The remembered target window handle. Stored as `usize`: `HWND`
    /// wraps a pointer, which is not `Send`, and the OS seam must be.
    target: Mutex<Option<usize>>,
}

impl Win32Os {
    pub fn new() -> Self {
        Self {
            target: Mutex::new(None),
        }
    }
}

impl Default for Win32Os {
    fn default() -> Self {
        Self::new()
    }
}

impl InputOs for Win32Os {
    fn clipboard_save(&self) -> Result<SavedClipboard, String> {
        let result = with_clipboard(|| {
            let mut formats = Vec::new();
            for format in PRESERVED_FORMATS {
                // An absent format is not an error — most clipboards hold
                // one format.
                let Ok(handle) = (unsafe { GetClipboardData(format) }) else {
                    continue;
                };
                let Some(bytes) = read_global(handle) else {
                    continue;
                };
                formats.push((format, bytes));
            }
            Ok(if formats.is_empty() {
                SavedClipboard::Empty
            } else {
                SavedClipboard::Formats(formats)
            })
        });
        if let Err(err) = &result {
            debug_log(format!("[DEBUG-sr06f] clipboard_save failed: {err}"));
        }
        result
    }

    fn clipboard_set_text(&self, text: &str) -> Result<(), String> {
        let mut units: Vec<u16> = text.encode_utf16().collect();
        units.push(0); // CF_UNICODETEXT is NUL-terminated
        let bytes =
            unsafe { std::slice::from_raw_parts(units.as_ptr().cast::<u8>(), units.len() * 2) };
        with_clipboard(|| {
            win_call(unsafe { EmptyClipboard() }, "EmptyClipboard")?;
            let handle = write_global(bytes)?;
            let placed = unsafe { SetClipboardData(CF_UNICODETEXT, Some(HANDLE(handle.0))) };
            if let Err(err) = placed {
                // The system did not take ownership of the block, so it is
                // ours to free — but windows-rs prunes GlobalFree. Leak the
                // one small block instead of reaching for undocumented
                // equivalents; this path needs SetClipboardData itself to
                // fail, which is nearer to unreachable than to rare.
                return Err(format!("SetClipboardData failed: {err}"));
            }
            Ok(())
        })
    }

    fn clipboard_restore(&self, saved: SavedClipboard) -> Result<(), String> {
        let formats = match saved {
            SavedClipboard::Empty => Vec::new(),
            SavedClipboard::Formats(formats) => formats,
        };
        with_clipboard(|| {
            win_call(unsafe { EmptyClipboard() }, "EmptyClipboard")?;
            for (format, bytes) in formats {
                let handle = write_global(&bytes)?;
                if let Err(err) = unsafe { SetClipboardData(format, Some(HANDLE(handle.0))) } {
                    // See clipboard_set_text for the deliberate leak.
                    return Err(format!("SetClipboardData failed: {err}"));
                }
            }
            Ok(())
        })
    }

    fn note_target(&self) {
        let hwnd = unsafe { GetForegroundWindow() };
        if hwnd.is_invalid() {
            debug_log("[DEBUG-sr06f] note_target: foreground invalid, keeping previous".into());
            return;
        }
        if window_belongs_to_us(hwnd) {
            debug_log(format!(
                "[DEBUG-sr06f] note_target: foreground is ours ({}), keeping previous",
                hwnd_desc(hwnd)
            ));
            return;
        }
        debug_log(format!(
            "[DEBUG-sr06f] note_target: remembering {}",
            hwnd_desc(hwnd)
        ));
        *self.target.lock().unwrap() = Some(hwnd.0 as usize);
    }

    fn activate_target(&self) -> bool {
        let Some(handle) = *self.target.lock().unwrap() else {
            debug_log("[DEBUG-sr06f] activate_target: no target remembered".into());
            return false;
        };
        let hwnd = HWND(handle as *mut core::ffi::c_void);
        // Handing foreground away is permitted while we hold it (the
        // preview window had focus for editing). A refused call leaves
        // the current foreground alone, which the paste flow tolerates.
        let activated = unsafe { SetForegroundWindow(hwnd) }.as_bool();
        debug_log(format!(
            "[DEBUG-sr06f] activate_target: {} -> {activated}",
            hwnd_desc(hwnd)
        ));
        activated
    }

    fn foreground_is_own_process(&self) -> bool {
        let hwnd = unsafe { GetForegroundWindow() };
        let ours = !hwnd.is_invalid() && window_belongs_to_us(hwnd);
        debug_log(format!(
            "[DEBUG-sr06f] foreground_is_own_process: {ours} ({})",
            hwnd_desc(hwnd)
        ));
        ours
    }

    fn send_paste(&self) -> Result<(), String> {
        // Paced per the script's batches: the modifier must land before the
        // key it modifies goes out, or the target can see a bare 'v'
        // instead of Ctrl+V (see `paced_paste_script` for the measurement).
        debug_log(format!(
            "[DEBUG-sr06f] send_paste: fg now {}",
            hwnd_desc(unsafe { GetForegroundWindow() })
        ));
        for (keys, settle_ms) in paced_paste_script() {
            if keys
                .iter()
                .any(|k| matches!(k, InjectedKey::AwaitPhysicalModifiersUp))
            {
                self.await_physical_modifiers_up(MODIFIER_RELEASE_TIMEOUT_MS);
            }
            let inputs: Vec<INPUT> = keys.iter().filter_map(injected_to_input).collect();
            if !inputs.is_empty() {
                send_inputs(&inputs)?;
            }
            if settle_ms > 0 {
                self.wait_ms(settle_ms);
            }
        }
        debug_log("[DEBUG-sr06f] send_paste: all batches delivered".into());
        Ok(())
    }

    fn send_char(&self, ch: char) -> Result<(), String> {
        // One down/up pair per UTF-16 unit: non-BMP characters arrive as
        // a surrogate pair the system reassembles.
        let mut buffer = [0u16; 2];
        let units: Vec<u16> = ch.encode_utf16(&mut buffer).to_vec();
        let mut inputs = Vec::with_capacity(units.len() * 2);
        for unit in units {
            inputs.push(unicode_input(unit, KEYEVENTF_UNICODE));
            inputs.push(unicode_input(unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
        }
        send_inputs(&inputs)
    }

    fn send_enter(&self) -> Result<(), String> {
        send_inputs(&[
            key_input(VK_RETURN, KEYBD_EVENT_FLAGS(0)),
            key_input(VK_RETURN, KEYEVENTF_KEYUP),
        ])
    }

    fn wait_ms(&self, ms: u64) {
        std::thread::sleep(std::time::Duration::from_millis(ms));
    }
}

// -- window plumbing ----------------------------------------------------------

/// Whether `hwnd` belongs to this process.
fn window_belongs_to_us(hwnd: HWND) -> bool {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    pid == std::process::id()
}

// -- modifier gate ---------------------------------------------------------------

/// Modifiers whose PHYSICAL hold would turn an injected Ctrl+V into a
/// different chord (Ctrl+Alt+V pastes nowhere). Names for the debug log.
const PHYSICAL_MODIFIERS: [(VIRTUAL_KEY, &str); 5] = [
    (VK_CONTROL, "ctrl"),
    (VK_MENU, "alt"),
    (VK_SHIFT, "shift"),
    (VK_LWIN, "lwin"),
    (VK_RWIN, "rwin"),
];

/// How long to wait for a physically held modifier to be released before
/// flushing it with a synthetic key-up. Confirm fired by the Ctrl+Alt+V
/// hotkey starts with those keys held; a normal hold lasts well under
/// this, so the flush only covers a deliberately held or stuck modifier.
const MODIFIER_RELEASE_TIMEOUT_MS: u64 = 500;

impl Win32Os {
    /// Wait until no modifier is physically held (the hotkey that fired
    /// this confirm is still being pressed). On timeout, release whatever
    /// is still held synthetically so the paste chord goes out clean.
    fn await_physical_modifiers_up(&self, timeout_ms: u64) {
        let started = std::time::Instant::now();
        loop {
            let held: Vec<&str> = PHYSICAL_MODIFIERS
                .iter()
                .filter(|(vk, _)| physical_down(*vk))
                .map(|(_, name)| *name)
                .collect();
            if held.is_empty() {
                let waited = started.elapsed().as_millis();
                if waited > 0 {
                    debug_log(format!(
                        "[DEBUG-sr06f] modifier gate: clear after {waited}ms"
                    ));
                }
                return;
            }
            if started.elapsed() >= std::time::Duration::from_millis(timeout_ms) {
                debug_log(format!(
                    "[DEBUG-sr06f] modifier gate: still held {held:?} after {timeout_ms}ms, releasing synthetically"
                ));
                for (vk, _) in PHYSICAL_MODIFIERS {
                    if physical_down(vk) {
                        // Best effort: a short count still leaves the chord
                        // worth trying, so the result is only logged.
                        let _ = send_inputs(&[key_input(vk, KEYEVENTF_KEYUP)]);
                    }
                }
                return;
            }
            self.wait_ms(10);
        }
    }
}

/// Whether the key is physically down right now (high bit of
/// GetAsyncKeyState), as opposed to our own injected state.
fn physical_down(vk: VIRTUAL_KEY) -> bool {
    (unsafe { GetAsyncKeyState(vk.0 as i32) }) < 0
}

// -- [DEBUG-sr06f] temporary insert-path instrumentation -----------------------
//
// Append-only log next to the exe (sr_insert_debug.log): every step of the
// confirm-insert path with the window it acted on. Temporary for the
// ticket-06 diagnosis; grep the tag and delete once insertion is accepted.

fn debug_log(line: String) {
    use std::io::Write as _;
    let Some(dir) = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
    else {
        return;
    };
    let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("sr_insert_debug.log"))
    else {
        return;
    };
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let _ = writeln!(file, "{ts} {line}");
}

/// A one-line window identity: handle, owning pid (flagged when ours), title.
fn hwnd_desc(hwnd: HWND) -> String {
    if hwnd.is_invalid() {
        return "(invalid hwnd)".into();
    }
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    let mut buf = [0u16; 128];
    let n = unsafe { GetWindowTextW(hwnd, &mut buf) } as usize;
    let title = String::from_utf16_lossy(&buf[..n]);
    let ours = if pid == std::process::id() {
        " OURS"
    } else {
        ""
    };
    format!("hwnd=0x{:x} pid={pid}{ours} '{title}'", hwnd.0 as usize)
}

// -- clipboard plumbing ------------------------------------------------------

/// Run `body` with the clipboard open, retrying briefly: the clipboard is
/// a shared resource another app may be holding.
fn with_clipboard<T>(body: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    for attempt in 0..8 {
        if unsafe { OpenClipboard(None) }.is_ok() {
            let result = body();
            unsafe { CloseClipboard() }.ok();
            return result;
        }
        std::thread::sleep(std::time::Duration::from_millis(25 * (attempt + 1)));
    }
    debug_log("[DEBUG-sr06f] clipboard open failed after 8 attempts".into());
    Err("the clipboard stayed busy (another app holds it)".into())
}

/// Map a fallible Win32 call to a `String` error, naming the API.
fn win_call<T>(result: windows::core::Result<T>, api: &str) -> Result<T, String> {
    result.map_err(|err| format!("{api} failed: {err}"))
}

/// Copy a global-memory block owned by someone else into a Vec.
fn read_global(handle: HANDLE) -> Option<Vec<u8>> {
    let global = HGLOBAL(handle.0);
    let size = unsafe { GlobalSize(global) };
    if size == 0 {
        return None;
    }
    let src = unsafe { GlobalLock(global) };
    if src.is_null() {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(src.cast::<u8>(), size) }.to_vec();
    unsafe { GlobalUnlock(global) }.ok();
    Some(bytes)
}

/// Copy `bytes` into a fresh global-memory block ready for
/// `SetClipboardData`.
fn write_global(bytes: &[u8]) -> Result<HGLOBAL, String> {
    let handle = win_call(
        unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes.len()) },
        "GlobalAlloc",
    )?;
    let dst = unsafe { GlobalLock(handle) };
    if dst.is_null() {
        // windows-rs prunes GlobalFree; the empty GlobalAlloc failure block
        // leaks rather than reaches for undocumented equivalents.
        return Err("GlobalLock failed".into());
    }
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), dst.cast::<u8>(), bytes.len()) };
    unsafe { GlobalUnlock(handle) }.ok();
    Ok(handle)
}

// -- keystrokes ---------------------------------------------------------------

fn key_input(vk: VIRTUAL_KEY, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

/// Map a platform-independent script key onto its INPUT struct. `None` for
/// the gate: it is executed inline (an OS wait), never injected.
fn injected_to_input(key: &InjectedKey) -> Option<INPUT> {
    match key {
        InjectedKey::AwaitPhysicalModifiersUp => None,
        InjectedKey::CtrlDown => Some(key_input(VK_CONTROL, KEYBD_EVENT_FLAGS(0))),
        InjectedKey::CtrlUp => Some(key_input(VK_CONTROL, KEYEVENTF_KEYUP)),
        // VK codes follow the US layout, so Ctrl+V is Ctrl+V everywhere.
        InjectedKey::VkDown(code) => {
            Some(key_input(VIRTUAL_KEY(*code as u16), KEYBD_EVENT_FLAGS(0)))
        }
        InjectedKey::VkUp(code) => Some(key_input(VIRTUAL_KEY(*code as u16), KEYEVENTF_KEYUP)),
    }
}

fn unicode_input(unit: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(0),
                wScan: unit,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

fn send_inputs(inputs: &[INPUT]) -> Result<(), String> {
    let sent = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent == inputs.len() as u32 {
        Ok(())
    } else {
        debug_log(format!(
            "[DEBUG-sr06f] SendInput delivered {sent} of {} events",
            inputs.len()
        ));
        Err(format!(
            "SendInput delivered {sent} of {} events",
            inputs.len()
        ))
    }
}
