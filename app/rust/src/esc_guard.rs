//! The global Esc guard: while a session is active, a bare Esc cancels it
//! no matter which window holds the keyboard.
//!
//! Why global: the session window does not reliably WIN the foreground
//! when it opens (Windows refuses `SetForegroundWindow` from a background
//! process about half the time on the hotkey path), and requiring the
//! user to click the panel first before Esc works reads as "Esc is dead".
//! A low-level keyboard hook settles the question at the source.
//!
//! Swallow rule (the [classify] table, unit-tested below): the key must
//! be a bare Esc (no modifier held), not injected by software, the guard
//! armed (engine in Recording/Rectifying/Preview), and the foreground NOT
//! our own window. The last clause keeps the key flowing when our window
//! does hold focus: the in-window Flutter handler owns that case, and an
//! IME composition in the preview field must see Esc first so it can
//! cancel the composition instead of the session.
//!
//! The hook thread and handle are deliberately leaked, like the insertion
//! tracker: they are meant to live exactly as long as the process.

use std::sync::atomic::{AtomicBool, Ordering};

/// Whether a session is active (Recording/Rectifying/Preview). Armed by
/// the bridge on StartSession and corrected on every state change the
/// event stream forwards.
static ARMED: AtomicBool = AtomicBool::new(false);

/// The one pure decision of the guard: swallow this key event or let it
/// pass. Every input is already normalized by the caller. Only the
/// Windows half calls it, but it stays cfg-free so its table tests run
/// on the dev host.
#[cfg_attr(not(windows), allow(dead_code))]
fn classify(
    armed: bool,
    is_esc: bool,
    injected: bool,
    modifiers_down: bool,
    own_foreground: bool,
) -> bool {
    armed && is_esc && !injected && !modifiers_down && !own_foreground
}

/// Arm or disarm the guard. Idempotent; called from any thread.
pub fn set_armed(active: bool) {
    let was = ARMED.swap(active, Ordering::SeqCst);
    if was != active {
        probe(&format!("armed={active}"));
    }
}

/// TEMPORARY diagnostic probe (e2e focus round): one line per event to
/// esc-debug.log next to the exe, mirroring the Flutter-side probe.
/// Delete together with its Flutter twin once the diagnosis lands.
#[cfg(windows)]
fn probe(line: &str) {
    use std::io::Write;
    let Some(dir) = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Into::into))
    else {
        return;
    };
    let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("esc-debug.log"))
    else {
        return;
    };
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let _ = writeln!(file, "{ms} rust {line}");
}

/// Off Windows there is no log and no hook; the arm flag still exists so
/// the bridge code stays cfg-free.
#[cfg(not(windows))]
fn probe(_line: &str) {}

/// Install the keyboard hook. `on_cancel` fires (on a hook-thread context)
/// when a swallow happens; it must be quick and non-blocking — it should
/// hand the cancel off to a runtime, not await it. No-op off Windows and
/// on a failed install (the in-window Esc path remains as the fallback).
pub fn install(on_cancel: std::sync::Arc<dyn Fn() + Send + Sync>) {
    #[cfg(windows)]
    install_windows(on_cancel);
    #[cfg(not(windows))]
    let _ = on_cancel;
}

// -- the Windows half ------------------------------------------------------

#[cfg(windows)]
mod windows_impl {
    use std::sync::atomic::Ordering;
    use std::sync::{Arc, Once};

    use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, VK_CONTROL, VK_ESCAPE, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetForegroundWindow, GetMessageW,
        GetWindowThreadProcessId, SetWindowsHookExW, TranslateMessage, KBDLLHOOKSTRUCT,
        KBDLLHOOKSTRUCT_FLAGS, LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_SYSKEYDOWN,
    };

    use super::{classify, ARMED};

    /// What to do when the guard swallows an Esc (issues the engine
    /// Cancel). Process-wide: one hook serves the one engine the process
    /// owns, and the LL callback carries no context pointer.
    static ON_CANCEL: std::sync::OnceLock<Arc<dyn Fn() + Send + Sync>> = std::sync::OnceLock::new();

    /// Modifiers whose physical hold turns a bare Esc into a chord
    /// (Ctrl+Esc opens the Start menu; those must pass through).
    const PHYSICAL_MODIFIERS: [windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY; 5] =
        [VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN];

    pub fn install(on_cancel: Arc<dyn Fn() + Send + Sync>) {
        let _ = ON_CANCEL.set(on_cancel);
        static ONCE: Once = Once::new();
        ONCE.call_once(|| {
            std::thread::Builder::new()
                .name("esc-guard".into())
                .spawn(|| unsafe {
                    // Low-level hook callbacks are delivered to the
                    // installing thread while it pumps messages.
                    match SetWindowsHookExW(WH_KEYBOARD_LL, Some(esc_proc), None, 0) {
                        Ok(_) => probe("hook installed"),
                        Err(_) => {
                            probe("hook install FAILED");
                            return; // degrade: the in-window Esc path remains
                        }
                    }
                    let mut msg = MSG::default();
                    loop {
                        let fetched = GetMessageW(&mut msg, None, 0, 0);
                        if fetched.0 == 0 || fetched.0 == -1 {
                            break; // WM_QUIT, or an error worth bailing on
                        }
                        let _ = TranslateMessage(&msg);
                        DispatchMessageW(&msg);
                    }
                })
                .expect("spawn esc guard");
        });
    }

    unsafe extern "system" fn esc_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code < 0 {
            // Contract: negative codes go straight down the chain.
            return CallNextHookEx(None, code, wparam, lparam);
        }
        let key_down = wparam.0 as u32 == WM_KEYDOWN || wparam.0 as u32 == WM_SYSKEYDOWN;
        if key_down {
            let kbd = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
            let is_esc = kbd.vkCode == VK_ESCAPE.0 as u32;
            let injected = (kbd.flags & LLKHF_INJECTED) != KBDLLHOOKSTRUCT_FLAGS(0);
            let modifiers_down = PHYSICAL_MODIFIERS
                .iter()
                .any(|vk| (GetAsyncKeyState(vk.0 as i32)) < 0);
            let own_foreground = foreground_is_own_process();
            let swallow = classify(
                ARMED.load(Ordering::SeqCst),
                is_esc,
                injected,
                modifiers_down,
                own_foreground,
            );
            if is_esc {
                probe(&format!(
                    "esc armed={} injected={} mods={} own_fg={} => swallow={swallow}",
                    ARMED.load(Ordering::SeqCst),
                    injected,
                    modifiers_down,
                    own_foreground,
                ));
            }
            if swallow {
                if let Some(on_cancel) = ON_CANCEL.get() {
                    on_cancel();
                }
                return LRESULT(1); // eat the key: no window ever sees it
            }
        }
        CallNextHookEx(None, code, wparam, lparam)
    }

    /// Whether the foreground window belongs to this process. When it
    /// does, the key belongs to our own surface (or its IME) and must
    /// take the normal path.
    fn foreground_is_own_process() -> bool {
        let hwnd = unsafe { GetForegroundWindow() };
        if hwnd.is_invalid() {
            return false;
        }
        let mut pid = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
        pid == std::process::id()
    }
}

#[cfg(windows)]
use windows_impl::install as install_windows;

#[cfg(test)]
mod tests {
    use super::classify;

    // The one behavior worth locking: every guard condition on its own.
    #[test]
    fn swallows_a_bare_physical_esc_while_armed_and_focus_elsewhere() {
        assert!(classify(true, true, false, false, false));
    }

    #[test]
    fn idle_passes_everything() {
        assert!(!classify(false, true, false, false, false));
    }

    #[test]
    fn non_esc_keys_pass() {
        assert!(!classify(true, false, false, false, false));
    }

    #[test]
    fn injected_esc_passes() {
        assert!(!classify(true, true, true, false, false));
    }

    #[test]
    fn modifier_chords_pass() {
        assert!(!classify(true, true, false, true, false));
    }

    #[test]
    fn esc_on_our_own_window_passes_to_the_ime_first() {
        assert!(!classify(true, true, false, false, true));
    }
}
