//! The production [`TextInserter`]: confirmed text into the target
//! window, orchestrated over the [`InputOs`] seam.
//!
//! Paste mode puts the text on the clipboard and sends Ctrl+V at the
//! target; the text stays on the clipboard afterward — the newest entry
//! in the clipboard history, and a manual Ctrl+V fallback should the
//! paste itself fail. Typing mode sends the text key by key and never
//! touches the clipboard, for targets that block paste. Before the keys
//! go out, the keyboard is pointed at the insertion target: a foreign
//! window holding the foreground is the user's latest chosen point and
//! is pasted into directly, while the target remembered at session start
//! (`note_target`) is only activated when our own window holds the
//! foreground (editing the preview hands it to us). The mode/pacing
//! config is swapped at runtime by the settings window's advanced form
//! (`set_config`); each insert snapshots it up front, so a save applies
//! from the next insert on and never tears a running insert apart.

use std::sync::{Arc, RwLock};

use async_trait::async_trait;

use spokenrectifier_engine::provider::inserter::{InsertError, TextInserter};

use crate::config::{InsertionConfig, InsertionMode};
use crate::os::InputOs;

pub struct TargetInserter {
    os: Arc<dyn InputOs>,
    config: RwLock<InsertionConfig>,
}

impl TargetInserter {
    /// Test seam: the orchestration over a caller-supplied OS layer.
    pub fn new(os: Arc<dyn InputOs>, config: InsertionConfig) -> Self {
        Self {
            os,
            config: RwLock::new(config),
        }
    }

    /// The production OS layer: Win32 on Windows; a stub that fails every
    /// operation elsewhere (the WSL build exists for tests and headless
    /// demos).
    pub fn production(config: InsertionConfig) -> Self {
        #[cfg(windows)]
        let os: Arc<dyn InputOs> = Arc::new(crate::windows::Win32Os::new());
        #[cfg(not(windows))]
        let os: Arc<dyn InputOs> = Arc::new(crate::os::UnsupportedOs);
        Self::new(os, config)
    }

    /// Remember the current foreground window as the insertion target.
    /// The bridge calls this when a session starts — the window the user
    /// was typing in when they pressed the hotkey.
    pub fn note_target(&self) {
        self.os.note_target();
    }

    /// Swap the mode/pacing config at runtime (the settings window's
    /// advanced form saves through the bridge). Each insert snapshots
    /// the config it runs with, so the new values apply from the next
    /// insert on.
    pub fn set_config(&self, config: InsertionConfig) {
        *self.config.write().unwrap() = config;
    }

    /// The config one insert runs with, snapshotted up front so a
    /// mid-insert swap cannot tear mode and pacing apart.
    fn config_snapshot(&self) -> InsertionConfig {
        *self.config.read().unwrap()
    }

    /// Give the keyboard back on a cancelled session — but only what we
    /// are holding: when the MAIN window is the foreground (the panel
    /// borrowed it), hand it to the remembered target; anything else —
    /// the target itself on a hotkey session, a foreign window the user
    /// moved to mid-session, or our own SETTINGS window (same process,
    /// the user's latest choice) — is left exactly where it is.
    pub fn restore_focus(&self) {
        if self.os.foreground_is_main_window() {
            self.os.activate_target();
        }
    }

    fn insert_by_paste(&self, text: &str, config: &InsertionConfig) -> Result<(), InsertError> {
        let text = &to_crlf(text);
        self.focus_somewhere()?;
        self.os
            .clipboard_set_text(text)
            .map_err(|err| InsertError(format!("clipboard set failed: {err}")))?;
        self.os.wait_ms(config.focus_settle_ms);
        self.os
            .send_paste()
            .map_err(|err| InsertError(format!("paste keystroke failed: {err}")))?;
        self.os.wait_ms(config.paste_settle_ms);
        Ok(())
    }

    fn insert_by_typing(&self, text: &str, config: &InsertionConfig) -> Result<(), InsertError> {
        self.focus_somewhere()?;
        self.os.wait_ms(config.focus_settle_ms);
        for ch in text.chars() {
            match ch {
                // A CRLF pair types one Enter; a bare CR alone types
                // nothing (an artifact of normalization, not content).
                '\r' => continue,
                '\n' => self
                    .os
                    .send_enter()
                    .map_err(|err| InsertError(format!("typing Enter failed: {err}")))?,
                ch => self
                    .os
                    .send_char(ch)
                    .map_err(|err| InsertError(format!("typing failed at {ch:?}: {err}")))?,
            }
            self.os.wait_ms(config.typing_delay_ms);
        }
        Ok(())
    }

    /// Point the keyboard at the insertion target: the current foreground
    /// when a foreign window holds it, the remembered target otherwise —
    /// never our own window. A foreign foreground is the user's latest
    /// stated choice (they clicked into that window to place the caret
    /// while the preview was up); activating the remembered target there
    /// would stomp it and paste into the stale session-start window —
    /// the "selected a position, nothing inserted" failure. When our own
    /// window holds the foreground (the preview field still editing),
    /// re-note the target — the live tracker may name a window the user
    /// focused after the session began — and hand the keyboard over.
    fn focus_somewhere(&self) -> Result<(), InsertError> {
        if !self.os.foreground_is_own_process() {
            return Ok(());
        }
        self.os.note_target();
        if self.os.activate_target() {
            return Ok(());
        }
        Err(InsertError(
            "no target window to insert into: focus the window you \
             type in before starting the session, then start it from \
             the orb or the hotkey"
                .into(),
        ))
    }
}

#[async_trait]
impl TextInserter for TargetInserter {
    async fn insert(&self, text: &str) -> Result<(), InsertError> {
        if text.is_empty() {
            // An all-emptied confirmation is a completed insert of
            // nothing (空串也贴): the session finishes and history records
            // the empty text, and the OS is left untouched — no clipboard
            // churn, no keystroke, no focus steal for zero content.
            return Ok(());
        }
        let config = self.config_snapshot();
        match config.mode {
            InsertionMode::Paste => self.insert_by_paste(text, &config),
            InsertionMode::Typing => self.insert_by_typing(text, &config),
        }
    }

    fn restore_focus(&self) {
        TargetInserter::restore_focus(self);
    }
}

/// The Windows clipboard convention: lines end `\r\n`. Normalize any
/// existing CRLF first so it is not doubled, then give every remaining
/// LF its carriage return.
fn to_crlf(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\n', "\r\n")
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicBool, Ordering};

    use super::*;

    // -- fake ----------------------------------------------------------------

    #[derive(Debug, Clone, PartialEq)]
    enum OsCall {
        NoteTarget,
        SetText(String),
        Activate(bool),
        Paste,
        Char(char),
        Enter,
        Wait(u64),
    }

    /// Records every call; programmable own/main foreground and activate
    /// results, and one-shot failures per operation name.
    struct FakeOs {
        calls: std::sync::Mutex<Vec<OsCall>>,
        activate_result: AtomicBool,
        own_foreground: AtomicBool,
        main_foreground: AtomicBool,
        failures: std::sync::Mutex<VecDeque<(&'static str, String)>>,
    }

    impl FakeOs {
        fn new() -> Self {
            Self {
                calls: std::sync::Mutex::new(Vec::new()),
                activate_result: AtomicBool::new(true),
                own_foreground: AtomicBool::new(false),
                main_foreground: AtomicBool::new(false),
                failures: std::sync::Mutex::new(VecDeque::new()),
            }
        }

        fn arm_failure(&self, op: &'static str, message: &str) {
            self.failures
                .lock()
                .unwrap()
                .push_back((op, message.to_string()));
        }

        fn take_failure(&self, op: &'static str) -> Option<String> {
            let mut failures = self.failures.lock().unwrap();
            failures
                .iter()
                .position(|(name, _)| *name == op)
                .map(|i| failures.remove(i).unwrap().1)
        }

        fn calls(&self) -> Vec<OsCall> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl InputOs for FakeOs {
        fn clipboard_set_text(&self, text: &str) -> Result<(), String> {
            self.calls
                .lock()
                .unwrap()
                .push(OsCall::SetText(text.to_string()));
            if let Some(message) = self.take_failure("set_text") {
                return Err(message);
            }
            Ok(())
        }

        fn note_target(&self) {
            self.calls.lock().unwrap().push(OsCall::NoteTarget);
        }

        fn activate_target(&self) -> bool {
            let activated = self.activate_result.load(Ordering::SeqCst);
            self.calls.lock().unwrap().push(OsCall::Activate(activated));
            activated
        }

        fn foreground_is_own_process(&self) -> bool {
            // A query, not an action: never recorded in the call log.
            self.own_foreground.load(Ordering::SeqCst)
        }

        fn foreground_is_main_window(&self) -> bool {
            self.main_foreground.load(Ordering::SeqCst)
        }

        fn send_paste(&self) -> Result<(), String> {
            self.calls.lock().unwrap().push(OsCall::Paste);
            if let Some(message) = self.take_failure("paste") {
                return Err(message);
            }
            Ok(())
        }

        fn send_char(&self, ch: char) -> Result<(), String> {
            self.calls.lock().unwrap().push(OsCall::Char(ch));
            if let Some(message) = self.take_failure("char") {
                return Err(message);
            }
            Ok(())
        }

        fn send_enter(&self) -> Result<(), String> {
            self.calls.lock().unwrap().push(OsCall::Enter);
            if let Some(message) = self.take_failure("enter") {
                return Err(message);
            }
            Ok(())
        }

        fn wait_ms(&self, ms: u64) {
            self.calls.lock().unwrap().push(OsCall::Wait(ms));
        }
    }

    fn inserter(fake: &Arc<FakeOs>, mode: InsertionMode) -> TargetInserter {
        TargetInserter::new(
            fake.clone(),
            InsertionConfig {
                mode,
                ..InsertionConfig::default()
            },
        )
    }

    async fn insert(
        fake: &Arc<FakeOs>,
        mode: InsertionMode,
        text: &str,
    ) -> Result<(), InsertError> {
        inserter(fake, mode).insert(text).await
    }

    // -- paste mode ----------------------------------------------------------

    #[tokio::test]
    async fn paste_flow_targets_the_current_foreign_foreground_not_the_remembered_window() {
        // The user clicked into the window they want while the preview
        // was up, so a foreign window holds the keyboard — even though a
        // target from the session start IS remembered and would activate
        // (the fake's defaults). Activating it would stomp the fresh
        // choice and paste into the stale window while the user watches
        // their own: the foreground check must win, no activation at all.
        let fake = Arc::new(FakeOs::new());
        insert(&fake, InsertionMode::Paste, "第一行\n第二行")
            .await
            .unwrap();

        assert_eq!(
            fake.calls(),
            vec![
                // LF became CRLF: the Windows clipboard convention.
                OsCall::SetText("第一行\r\n第二行".into()),
                OsCall::Wait(50),
                OsCall::Paste,
                OsCall::Wait(250),
            ]
        );
    }

    #[tokio::test]
    async fn existing_crlf_is_not_doubled() {
        let fake = Arc::new(FakeOs::new());
        insert(&fake, InsertionMode::Paste, "a\r\nb").await.unwrap();
        assert_eq!(
            fake.calls(),
            vec![
                OsCall::SetText("a\r\nb".into()),
                OsCall::Wait(50),
                OsCall::Paste,
                OsCall::Wait(250),
            ]
        );
    }

    #[tokio::test]
    async fn our_own_foreground_renotes_the_target_then_activates_it() {
        // The preview field still holds the keyboard (an orb confirm):
        // the remembered target is re-noted first — the live tracker may
        // name a window the user focused after the session began — then
        // activated, and only then does the clipboard work begin.
        let fake = Arc::new(FakeOs::new());
        fake.own_foreground.store(true, Ordering::SeqCst);
        insert(&fake, InsertionMode::Paste, "话").await.unwrap();

        assert_eq!(
            fake.calls(),
            vec![
                OsCall::NoteTarget,
                OsCall::Activate(true),
                OsCall::SetText("话".into()),
                OsCall::Wait(50),
                OsCall::Paste,
                OsCall::Wait(250),
            ]
        );
    }

    #[tokio::test]
    async fn a_failed_paste_reports_the_error_and_leaves_the_text_on_the_clipboard() {
        let fake = Arc::new(FakeOs::new());
        fake.arm_failure("paste", "no target window");

        let err = insert(&fake, InsertionMode::Paste, "话").await.unwrap_err();
        assert!(err.0.contains("paste keystroke failed"), "got: {}", err.0);
        // No restore follows the failure: the text stays on the clipboard
        // as the newest entry — the user's manual Ctrl+V fallback.
        assert_eq!(fake.calls().last(), Some(&OsCall::Paste));
    }

    #[tokio::test]
    async fn without_a_target_and_our_own_window_focused_paste_refuses() {
        let fake = Arc::new(FakeOs::new());
        fake.activate_result.store(false, Ordering::SeqCst);
        fake.own_foreground.store(true, Ordering::SeqCst);

        let err = insert(&fake, InsertionMode::Paste, "话").await.unwrap_err();
        assert!(err.0.contains("no target window"), "got: {}", err.0);
        // Refused before any clipboard write or keystroke went out.
        assert_eq!(
            fake.calls(),
            vec![OsCall::NoteTarget, OsCall::Activate(false)]
        );
    }

    #[tokio::test]
    async fn without_a_target_and_our_own_window_focused_typing_refuses() {
        let fake = Arc::new(FakeOs::new());
        fake.activate_result.store(false, Ordering::SeqCst);
        fake.own_foreground.store(true, Ordering::SeqCst);

        let err = insert(&fake, InsertionMode::Typing, "话")
            .await
            .unwrap_err();
        assert!(err.0.contains("no target window"), "got: {}", err.0);
        assert_eq!(
            fake.calls(),
            vec![OsCall::NoteTarget, OsCall::Activate(false)]
        );
    }

    // -- typing mode ---------------------------------------------------------

    #[tokio::test]
    async fn typing_flow_types_each_character_and_never_touches_the_clipboard() {
        let fake = Arc::new(FakeOs::new());
        insert(&fake, InsertionMode::Typing, "你\r\n好")
            .await
            .unwrap();

        assert_eq!(
            fake.calls(),
            vec![
                OsCall::Wait(50),
                OsCall::Char('你'),
                OsCall::Wait(8),
                // One Enter for the CRLF pair, the CR itself typed nothing.
                OsCall::Enter,
                OsCall::Wait(8),
                OsCall::Char('好'),
                OsCall::Wait(8),
            ]
        );
    }

    #[tokio::test]
    async fn a_typing_failure_reports_where_it_stopped() {
        let fake = Arc::new(FakeOs::new());
        fake.arm_failure("char", "input queue full");

        let err = insert(&fake, InsertionMode::Typing, "你好")
            .await
            .unwrap_err();
        assert!(err.0.contains("typing failed at '你'"), "got: {}", err.0);
        assert!(err.0.contains("input queue full"), "got: {}", err.0);
        // The first character was attempted before the failure.
        assert!(fake.calls().contains(&OsCall::Char('你')));
    }

    // -- both modes ----------------------------------------------------------

    #[tokio::test]
    async fn empty_text_completes_without_touching_the_os() {
        // 空串也贴: an all-emptied confirmation is success, not a refusal
        // that strands the user in the preview — but "pasting nothing"
        // touches nothing on the way out.
        let fake = Arc::new(FakeOs::new());
        insert(&fake, InsertionMode::Paste, "").await.unwrap();
        assert!(fake.calls().is_empty());
    }

    // -- the runtime config swap (the advanced form's real-time save) -------

    #[tokio::test]
    async fn a_config_swap_applies_from_the_next_insert_on() {
        let fake = Arc::new(FakeOs::new());
        let inserter = TargetInserter::new(fake.clone(), InsertionConfig::default());

        // Construction config in effect: paste at the default pacing.
        inserter.insert("话").await.unwrap();
        assert_eq!(
            fake.calls(),
            vec![
                OsCall::SetText("话".into()),
                OsCall::Wait(50),
                OsCall::Paste,
                OsCall::Wait(250),
            ]
        );

        // The advanced form's save swaps mode and pacing at once: the
        // next insert runs typing with the new delay — never half of
        // each config.
        inserter.set_config(InsertionConfig {
            mode: InsertionMode::Typing,
            focus_settle_ms: 70,
            paste_settle_ms: 400,
            typing_delay_ms: 15,
        });
        inserter.insert("好").await.unwrap();
        assert_eq!(
            fake.calls()[4..],
            vec![OsCall::Wait(70), OsCall::Char('好'), OsCall::Wait(15),]
        );
    }

    // -- focus restore ---------------------------------------------------

    #[test]
    fn restore_focus_hands_the_keyboard_back_when_we_hold_it() {
        let fake = Arc::new(FakeOs::new());
        fake.main_foreground.store(true, Ordering::SeqCst);
        inserter(&fake, InsertionMode::Paste).restore_focus();
        assert_eq!(fake.calls(), vec![OsCall::Activate(true)]);
    }

    #[test]
    fn restore_focus_leaves_a_foreign_foreground_alone() {
        let fake = Arc::new(FakeOs::new());
        inserter(&fake, InsertionMode::Paste).restore_focus();
        // The user (or the target itself) holds the keyboard: nothing to
        // return, nothing touched.
        assert!(fake.calls().is_empty());
    }

    #[test]
    fn restore_focus_leaves_a_subwindow_foreground_alone() {
        // The settings window: OUR process, but not the window that
        // borrowed the keyboard. Restoring over it is how a quick-panel
        // collapse used to push the settings window to the background —
        // the panel and the settings window are independent.
        let fake = Arc::new(FakeOs::new());
        fake.own_foreground.store(true, Ordering::SeqCst);
        inserter(&fake, InsertionMode::Paste).restore_focus();
        assert!(fake.calls().is_empty());
    }
}
