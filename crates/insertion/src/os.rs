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

/// A platform-independent step of an injected key script: the Win32 layer
/// turns each into its INPUT struct (or, for the gate, an OS wait); tests
/// reason about the pacing here, where it is deterministic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InjectedKey {
    /// Not a keystroke: wait until no modifier is PHYSICALLY held before
    /// continuing. Confirms fired by a modifier hotkey (Ctrl+Alt+V) run
    /// while the user still holds those modifiers — pasting into that
    /// delivers Ctrl+Alt+V to the target, which nothing treats as paste.
    AwaitPhysicalModifiersUp,
    /// Ctrl modifier down.
    CtrlDown,
    /// Ctrl modifier up.
    CtrlUp,
    /// A virtual-key down (the code is the Win32 VK value, stable ABI).
    VkDown(u8),
    /// A virtual-key up.
    VkUp(u8),
}

/// The paste keystroke as a PACED script: first wait out any physically
/// held modifiers, then the modifier goes out in its own input batch,
/// ahead of the key it modifies, with room between batches.
///
/// Why pacing: injected input travels the low-level keyboard hook chain
/// (IME, clipboard tools) asynchronously. A Ctrl+V sent as one SendInput
/// batch routinely loses the modifier on arrival — the target types a bare
/// 'v' instead of pasting (measured on the ticket-06 machine probe: 2/6
/// rounds pasted single-batch vs 6/6 paced). The batching cannot be
/// observed from inside the process; this structure is the fix, and the
/// test below locks it.
pub fn paced_paste_script() -> Vec<(Vec<InjectedKey>, u64)> {
    const MODIFIER_SETTLE_MS: u64 = 40;
    const VK_V: u8 = 0x56;
    vec![
        (vec![InjectedKey::AwaitPhysicalModifiersUp], 0),
        (vec![InjectedKey::CtrlDown], MODIFIER_SETTLE_MS),
        (
            vec![InjectedKey::VkDown(VK_V), InjectedKey::VkUp(VK_V)],
            MODIFIER_SETTLE_MS,
        ),
        (vec![InjectedKey::CtrlUp], 0),
    ]
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The load-bearing property: a modifier NEVER shares an input batch
    /// with the key it modifies, and every batch is followed by settle
    /// time (except the last). Merging the batches back into one
    /// reintroduces the dropped-modifier bug the pacing exists to fix.
    #[test]
    fn the_paste_script_paces_the_modifier_away_from_the_key() {
        let script = paced_paste_script();

        assert!(
            script.len() >= 4,
            "await / ctrl-down / v / ctrl-up as separate steps"
        );
        let (gate_batch, _) = &script[0];
        assert_eq!(
            gate_batch,
            &vec![InjectedKey::AwaitPhysicalModifiersUp],
            "the script opens by waiting out physically held modifiers"
        );

        let (first_batch, first_settle) = &script[1];
        assert_eq!(first_batch, &vec![InjectedKey::CtrlDown]);
        assert!(
            *first_settle > 0,
            "settle after Ctrl down before V goes out"
        );

        let (key_batch, key_settle) = &script[2];
        assert!(
            !key_batch.is_empty(),
            "the modified key arrives in its own non-empty batch"
        );
        assert!(
            !key_batch
                .iter()
                .any(|k| matches!(k, InjectedKey::CtrlDown | InjectedKey::CtrlUp)),
            "no modifier event rides in the key's batch"
        );
        // Down then up for the same virtual key, so no key is left held.
        let downs: Vec<u8> = key_batch
            .iter()
            .filter_map(|k| match k {
                InjectedKey::VkDown(code) => Some(*code),
                _ => None,
            })
            .collect();
        let ups: Vec<u8> = key_batch
            .iter()
            .filter_map(|k| match k {
                InjectedKey::VkUp(code) => Some(*code),
                _ => None,
            })
            .collect();
        assert_eq!(downs, ups, "every key down has its up in the same batch");
        assert!(*key_settle > 0, "settle before the modifier is released");

        let (last_batch, _) = script.last().unwrap();
        assert_eq!(
            last_batch,
            &vec![InjectedKey::CtrlUp],
            "Ctrl is released last"
        );
    }

    /// Pacing buys reliability with latency: keep the added delay humanly
    /// imperceptible so the fix cannot silently degrade into sluggishness.
    #[test]
    fn the_paste_script_settle_total_stays_imperceptible() {
        let total: u64 = paced_paste_script()
            .iter()
            .map(|(_, settle_ms)| *settle_ms)
            .sum();
        assert!(
            total <= 200,
            "total settle {total}ms exceeds the latency budget"
        );
    }
}
