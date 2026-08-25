//! Commands accepted by the engine (glossary: 会话, 修正, 预览窗).

use crate::style::Style;

/// A command into the engine. Commands are validated against the session
/// state machine; illegal commands return
/// [`EngineError::CommandRejected`](crate::EngineError::CommandRejected)
/// without changing any state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    /// Begin a recording session (hotkey press). Only valid while idle.
    StartSession,
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
    /// Switch the output style for the next rectify. Valid any time.
    SetStyle(Style),
}
