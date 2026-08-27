//! The production [`TextInserter`]: confirmed text into the target
//! window, orchestrated over the [`InputOs`] seam.
//!
//! Paste mode borrows the clipboard — save, replace, Ctrl+V at the
//! target, restore — so the user's clipboard survives the insert. Typing
//! mode sends the text key by key and never touches the clipboard, for
//! targets that block paste. The target window is remembered when the
//! session starts (`note_target`) and re-focused before the keys go out,
//! because editing the preview hands focus to our own window.

use std::sync::Arc;

use async_trait::async_trait;

use spokenrectifier_engine::provider::inserter::{InsertError, TextInserter};

use crate::config::{InsertionConfig, InsertionMode};
use crate::os::InputOs;

pub struct TargetInserter {
    os: Arc<dyn InputOs>,
    config: InsertionConfig,
}

impl TargetInserter {
    /// Test seam: the orchestration over a caller-supplied OS layer.
    pub fn new(os: Arc<dyn InputOs>, config: InsertionConfig) -> Self {
        Self { os, config }
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

    fn insert_by_paste(&self, text: &str) -> Result<(), InsertError> {
        let saved = self
            .os
            .clipboard_save()
            .map_err(|err| InsertError(format!("clipboard save failed: {err}")))?;
        let pasted = self.paste_steps(&to_crlf(text));
        // Always hand the clipboard back, however the paste went. A
        // restore failure after a successful paste is swallowed
        // deliberately: the text already landed, and reporting the insert
        // as failed would be a lie (only the clipboard was lost).
        drop(self.os.clipboard_restore(saved));
        pasted
    }

    fn paste_steps(&self, text: &str) -> Result<(), InsertError> {
        // Without a remembered target the keys go to whatever holds the
        // foreground — right whenever the user focused the target
        // themselves, wrong when that window is our own preview.
        self.focus_somewhere()?;
        self.os
            .clipboard_set_text(text)
            .map_err(|err| InsertError(format!("clipboard set failed: {err}")))?;
        self.os.wait_ms(self.config.focus_settle_ms);
        self.os
            .send_paste()
            .map_err(|err| InsertError(format!("paste keystroke failed: {err}")))?;
        self.os.wait_ms(self.config.paste_settle_ms);
        Ok(())
    }

    fn insert_by_typing(&self, text: &str) -> Result<(), InsertError> {
        self.focus_somewhere()?;
        self.os.wait_ms(self.config.focus_settle_ms);
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
            self.os.wait_ms(self.config.typing_delay_ms);
        }
        Ok(())
    }

    /// Point the keyboard at somewhere that is not us: the remembered
    /// target when there is one, the current foreground otherwise — but
    /// never our own window (a session started from the orb with the
    /// preview still focused would paste into itself).
    fn focus_somewhere(&self) -> Result<(), InsertError> {
        if self.os.activate_target() {
            return Ok(());
        }
        if self.os.foreground_is_own_process() {
            return Err(InsertError(
                "no target window to insert into: focus the window you \
                 type in before starting the session, then start it from \
                 the orb or the hotkey"
                    .into(),
            ));
        }
        Ok(())
    }
}

#[async_trait]
impl TextInserter for TargetInserter {
    async fn insert(&self, text: &str) -> Result<(), InsertError> {
        if text.is_empty() {
            return Err(InsertError(
                "nothing to insert: the preview text is empty".into(),
            ));
        }
        match self.config.mode {
            InsertionMode::Paste => self.insert_by_paste(text),
            InsertionMode::Typing => self.insert_by_typing(text),
        }
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
    use crate::os::SavedClipboard;

    // -- fake ----------------------------------------------------------------

    #[derive(Debug, Clone, PartialEq)]
    enum OsCall {
        Save,
        SetText(String),
        Restore(SavedClipboard),
        Activate(bool),
        Paste,
        Char(char),
        Enter,
        Wait(u64),
    }

    /// Records every call; programmable save results and one-shot
    /// failures per operation name.
    struct FakeOs {
        calls: std::sync::Mutex<Vec<OsCall>>,
        save_result: std::sync::Mutex<SavedClipboard>,
        activate_result: AtomicBool,
        own_foreground: AtomicBool,
        failures: std::sync::Mutex<VecDeque<(&'static str, String)>>,
    }

    impl FakeOs {
        fn new() -> Self {
            Self {
                calls: std::sync::Mutex::new(Vec::new()),
                save_result: std::sync::Mutex::new(SavedClipboard::Formats(vec![(
                    13,
                    b"old text".to_vec(),
                )])),
                activate_result: AtomicBool::new(true),
                own_foreground: AtomicBool::new(false),
                failures: std::sync::Mutex::new(VecDeque::new()),
            }
        }

        fn with_save(save: SavedClipboard) -> Self {
            let fake = Self::new();
            *fake.save_result.lock().unwrap() = save;
            fake
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
        fn clipboard_save(&self) -> Result<SavedClipboard, String> {
            self.calls.lock().unwrap().push(OsCall::Save);
            if let Some(message) = self.take_failure("save") {
                return Err(message);
            }
            Ok(self.save_result.lock().unwrap().clone())
        }

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

        fn clipboard_restore(&self, saved: SavedClipboard) -> Result<(), String> {
            self.calls.lock().unwrap().push(OsCall::Restore(saved));
            if let Some(message) = self.take_failure("restore") {
                return Err(message);
            }
            Ok(())
        }

        fn note_target(&self) {
            unreachable!("note_target is a pass-through, not part of insert flows");
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

    fn old_clipboard() -> SavedClipboard {
        SavedClipboard::Formats(vec![(13, b"old text".to_vec())])
    }

    // -- paste mode ----------------------------------------------------------

    #[tokio::test]
    async fn paste_flow_saves_pastes_at_the_target_and_restores_in_order() {
        let fake = Arc::new(FakeOs::new());
        insert(&fake, InsertionMode::Paste, "第一行\n第二行")
            .await
            .unwrap();

        assert_eq!(
            fake.calls(),
            vec![
                OsCall::Save,
                OsCall::Activate(true),
                // LF became CRLF: the Windows clipboard convention.
                OsCall::SetText("第一行\r\n第二行".into()),
                OsCall::Wait(50),
                OsCall::Paste,
                OsCall::Wait(250),
                OsCall::Restore(old_clipboard()),
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
                OsCall::Save,
                OsCall::Activate(true),
                OsCall::SetText("a\r\nb".into()),
                OsCall::Wait(50),
                OsCall::Paste,
                OsCall::Wait(250),
                OsCall::Restore(old_clipboard()),
            ]
        );
    }

    #[tokio::test]
    async fn an_empty_clipboard_is_restored_as_empty() {
        let fake = Arc::new(FakeOs::with_save(SavedClipboard::Empty));
        insert(&fake, InsertionMode::Paste, "话").await.unwrap();
        assert_eq!(
            fake.calls().last(),
            Some(&OsCall::Restore(SavedClipboard::Empty))
        );
    }

    #[tokio::test]
    async fn a_failed_paste_still_restores_the_clipboard_and_reports_the_error() {
        let fake = Arc::new(FakeOs::new());
        fake.arm_failure("paste", "no target window");

        let err = insert(&fake, InsertionMode::Paste, "话").await.unwrap_err();
        assert!(err.0.contains("paste keystroke failed"), "got: {}", err.0);
        // The restore ran before the error surfaced.
        assert_eq!(fake.calls().last(), Some(&OsCall::Restore(old_clipboard())));
    }

    #[tokio::test]
    async fn a_restore_failure_after_a_successful_paste_is_not_an_insert_failure() {
        let fake = Arc::new(FakeOs::new());
        fake.arm_failure("restore", "clipboard busy");

        insert(&fake, InsertionMode::Paste, "话").await.unwrap();
        assert!(fake.calls().contains(&OsCall::Paste));
    }

    #[tokio::test]
    async fn without_a_target_and_our_own_window_focused_paste_refuses() {
        let fake = Arc::new(FakeOs::new());
        fake.activate_result.store(false, Ordering::SeqCst);
        fake.own_foreground.store(true, Ordering::SeqCst);

        let err = insert(&fake, InsertionMode::Paste, "话").await.unwrap_err();
        assert!(err.0.contains("no target window"), "got: {}", err.0);
        // Refused before touching the clipboard contents or pasting; the
        // saved snapshot is still restored (a no-op net effect).
        assert_eq!(
            fake.calls(),
            vec![
                OsCall::Save,
                OsCall::Activate(false),
                OsCall::Restore(old_clipboard()),
            ]
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
        assert_eq!(fake.calls(), vec![OsCall::Activate(false)]);
    }

    #[tokio::test]
    async fn failed_focus_activation_does_not_abort_the_paste() {
        let fake = Arc::new(FakeOs::new());
        fake.activate_result.store(false, Ordering::SeqCst);

        insert(&fake, InsertionMode::Paste, "话").await.unwrap();
        // The paste still went out — to whatever held the foreground.
        assert_eq!(
            fake.calls(),
            vec![
                OsCall::Save,
                OsCall::Activate(false),
                OsCall::SetText("话".into()),
                OsCall::Wait(50),
                OsCall::Paste,
                OsCall::Wait(250),
                OsCall::Restore(old_clipboard()),
            ]
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
                OsCall::Activate(true),
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
    async fn empty_text_is_rejected_without_touching_the_os() {
        let fake = Arc::new(FakeOs::new());
        let err = insert(&fake, InsertionMode::Paste, "").await.unwrap_err();
        assert!(err.0.contains("nothing to insert"), "got: {}", err.0);
        assert!(fake.calls().is_empty());
    }
}
