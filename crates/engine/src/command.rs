//! Commands accepted by the engine (glossary: 会话, 修正, 预览窗).

/// A command into the engine. Commands are validated against the session
/// state machine; illegal commands return
/// [`EngineError::CommandRejected`](crate::EngineError::CommandRejected)
/// without changing any state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    /// Begin a recording session (hotkey press). Only valid while idle.
    StartSession,
    /// Rectify a given raw transcript without recording — history
    /// retrieval re-running a past utterance. Jumps straight into the
    /// machine (`Idle → Rectifying`); only valid while idle, and the
    /// transcript must be non-empty.
    RectifyText(String),
    /// End the recording session and start rectifying (hotkey press again).
    StopSession,
    /// Abort the session at any point with zero output.
    Cancel,
    /// Insert the (possibly edited) rectified text at the cursor. Valid in
    /// preview.
    ConfirmInsert,
    /// Regenerate the rectified text from the same raw transcript. Valid in
    /// preview.
    Reroll,
    /// Replace the preview text with user edits. Valid in preview.
    UpdatePreviewText(String),
    /// Set the style-directive text for the next rectify — a selected
    /// scenario's resolved directive (the engine knows nothing about
    /// scenario names). `None` returns to the built-in default register.
    /// Valid any time.
    SetStyleDirective(Option<String>),
}
