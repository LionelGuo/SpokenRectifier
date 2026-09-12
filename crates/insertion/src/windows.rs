//! The Win32 [`InputOs`]: the clipboard over global memory, keystrokes
//! over `SendInput`, and the foreground window as the insertion target.
//!
//! Only the two-liner would be untestable here; everything with logic to
//! it lives in the crate's OS-agnostic orchestration and is covered by the
//! fake-driven tests.

use std::sync::{Mutex, OnceLock};

use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{
    GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock,
};
use windows::Win32::UI::Accessibility::{HWINEVENTHOOK, SetWinEventHook};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBD_EVENT_FLAGS, KEYBDINPUT,
    KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, SendInput, VIRTUAL_KEY, VK_CONTROL, VK_LWIN, VK_MENU,
    VK_RETURN, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, EVENT_SYSTEM_FOREGROUND, GetForegroundWindow, GetMessageW,
    GetWindowThreadProcessId, IsWindow, MSG, OBJID_WINDOW, SetForegroundWindow, SetTimer,
    TranslateMessage, WINEVENT_OUTOFCONTEXT, WM_TIMER,
};

use crate::os::{InjectedKey, InputOs, SavedClipboard, paced_paste_script};

// The Unicode-text clipboard format id (a documented Win32 constant,
// stable ABI; declared locally so the Ole feature is not pulled in for
// the number).
const CF_UNICODETEXT: u32 = 13;

pub struct Win32Os {
    /// The remembered target window handle. Stored as `usize`: `HWND`
    /// wraps a pointer, which is not `Send`, and the OS seam must be.
    target: Mutex<Option<usize>>,
}

impl Win32Os {
    pub fn new() -> Self {
        track_last_foreign_foreground();
        Self {
            target: Mutex::new(None),
        }
    }

    /// Wait until no modifier is physically held (the hotkey that fired
    /// this confirm may still be pressed). On timeout, release whatever is
    /// still held synthetically so the paste chord goes out clean.
    fn await_physical_modifiers_up(&self, timeout_ms: u64) {
        let started = std::time::Instant::now();
        while PHYSICAL_MODIFIERS.iter().any(|vk| physical_down(*vk)) {
            if started.elapsed() >= std::time::Duration::from_millis(timeout_ms) {
                // Best effort: a short count still leaves the chord worth
                // trying, so the flush result is ignored.
                for vk in PHYSICAL_MODIFIERS {
                    if physical_down(vk) {
                        let _ = send_inputs(&[key_input(vk, KEYEVENTF_KEYUP)]);
                    }
                }
                return;
            }
            self.wait_ms(10);
        }
    }
}

impl Default for Win32Os {
    fn default() -> Self {
        Self::new()
    }
}

impl InputOs for Win32Os {
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

    fn note_target(&self) {
        let hwnd = unsafe { GetForegroundWindow() };
        if !(hwnd.is_invalid() || window_belongs_to_us(hwnd)) {
            *self.target.lock().unwrap() = Some(hwnd.0 as usize);
            return;
        }
        // Our own window is foreground — the session started from a click
        // on the orb, which took the foreground away from the very app
        // the user was typing in. Fall back to the last foreign window
        // the tracker saw (the pre-click foreground) while it still
        // exists; remembering our own window would make us our own
        // insertion target.
        let Some(last) = LAST_FOREIGN_FOREGROUND
            .get()
            .and_then(|cell| *cell.lock().unwrap())
        else {
            return;
        };
        if unsafe { IsWindow(Some(HWND(last as *mut core::ffi::c_void))) }.as_bool() {
            *self.target.lock().unwrap() = Some(last);
        }
    }

    fn activate_target(&self) -> bool {
        let Some(handle) = *self.target.lock().unwrap() else {
            return false;
        };
        let hwnd = HWND(handle as *mut core::ffi::c_void);
        // Handing foreground away is permitted while we hold it (the
        // preview window had focus for editing). A refused call leaves
        // the current foreground alone, which the paste flow tolerates.
        unsafe { SetForegroundWindow(hwnd) }.as_bool()
    }

    fn foreground_is_own_process(&self) -> bool {
        let hwnd = unsafe { GetForegroundWindow() };
        !hwnd.is_invalid() && window_belongs_to_us(hwnd)
    }

    fn send_paste(&self) -> Result<(), String> {
        // Paced per the script's batches: the modifier must land before the
        // key it modifies goes out, or the target can see a bare 'v'
        // instead of Ctrl+V (see `paced_paste_script` for the measurement).
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

/// The last foreground window that was NOT ours. Process-wide because the
/// Win32 event callback carries no context pointer, and one tracker
/// serves the one inserter the process owns.
static LAST_FOREIGN_FOREGROUND: OnceLock<Mutex<Option<usize>>> = OnceLock::new();

/// Watch the foreground for the process lifetime so
/// [`Win32Os::note_target`] can fall back to the pre-click foreground
/// when an orb-click start took the foreground to us first. Two feeds,
/// one cell: a `SetWinEventHook` for instant updates, and a 200 ms poll
/// as the safety net (the event hook alone proved not to be relied on —
/// a missed delivery leaves orb-click starts with no target). The thread
/// and handles are deliberately leaked: they are meant to live exactly
/// as long as the process, which is the inserter's lifetime.
fn track_last_foreign_foreground() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        std::thread::Builder::new()
            .name("foreground-tracker".into())
            .spawn(|| unsafe {
                let _hook = SetWinEventHook(
                    EVENT_SYSTEM_FOREGROUND,
                    EVENT_SYSTEM_FOREGROUND,
                    None,
                    Some(foreground_changed),
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT,
                );
                // Hook or no hook, the poll below keeps the tracker alive
                // (a failed install degrades to poll-only, not to nothing).
                let _ = SetTimer(None, TRACKER_TIMER_ID, FOREGROUND_POLL_MS, None);
                let mut msg = MSG::default();
                // Out-of-context events are delivered while the thread
                // pumps messages; the loop runs for the process lifetime.
                loop {
                    let fetched = GetMessageW(&mut msg, None, 0, 0);
                    if fetched.0 == 0 || fetched.0 == -1 {
                        break; // WM_QUIT, or an error worth bailing on
                    }
                    if msg.message == WM_TIMER && msg.wParam.0 as usize == TRACKER_TIMER_ID {
                        record_if_foreign(GetForegroundWindow());
                    }
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            })
            .expect("spawn foreground tracker");
    });
}

/// How often the poll arm of the tracker re-reads the foreground. The
/// pre-click target is typically held for seconds before an orb click,
/// so a coarse cadence still never misses it.
const FOREGROUND_POLL_MS: u32 = 200;

/// Timer id of the tracker poll (thread timers address their thread, so
/// any small constant is unique enough here).
const TRACKER_TIMER_ID: usize = 1;

/// Records every foreign window that gains the foreground; our own
/// activations are skipped so the pre-click window survives them.
unsafe extern "system" fn foreground_changed(
    _hook: HWINEVENTHOOK,
    _event: u32,
    hwnd: HWND,
    id_object: i32,
    _id_child: i32,
    _event_thread: u32,
    _event_time: u32,
) {
    if id_object != OBJID_WINDOW.0 {
        return;
    }
    record_if_foreign(hwnd);
}

/// The shared body of both tracker arms: remember `hwnd` as the last
/// foreign foreground while it is a live window of another process.
fn record_if_foreign(hwnd: HWND) {
    if hwnd.is_invalid() || !unsafe { IsWindow(Some(hwnd)) }.as_bool() {
        return;
    }
    if window_belongs_to_us(hwnd) {
        return;
    }
    let cell = LAST_FOREIGN_FOREGROUND.get_or_init(|| Mutex::new(None));
    *cell.lock().unwrap() = Some(hwnd.0 as usize);
}

// -- modifier gate ---------------------------------------------------------------

/// Modifiers whose PHYSICAL hold would turn an injected Ctrl+V into a
/// different chord (Ctrl+Alt+V pastes nowhere).
const PHYSICAL_MODIFIERS: [VIRTUAL_KEY; 5] = [VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN];

/// How long to wait for a physically held modifier to be released before
/// flushing it with a synthetic key-up. Confirm fired by the Ctrl+Alt+V
/// hotkey starts with those keys held; a normal hold lasts well under
/// this, so the flush only covers a deliberately held or stuck modifier.
const MODIFIER_RELEASE_TIMEOUT_MS: u64 = 500;

/// Whether the key is physically down right now (high bit of
/// GetAsyncKeyState), as opposed to our own injected state.
fn physical_down(vk: VIRTUAL_KEY) -> bool {
    (unsafe { GetAsyncKeyState(vk.0 as i32) }) < 0
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
    Err("the clipboard stayed busy (another app holds it)".into())
}

/// Map a fallible Win32 call to a `String` error, naming the API.
fn win_call<T>(result: windows::core::Result<T>, api: &str) -> Result<T, String> {
    result.map_err(|err| format!("{api} failed: {err}"))
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
        Err(format!(
            "SendInput delivered {sent} of {} events",
            inputs.len()
        ))
    }
}
