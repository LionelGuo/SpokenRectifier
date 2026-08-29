//! Commands accepted by the engine (glossary: 会话, 修正, 预览窗).

use crate::config::EngineTimings;

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
    /// transcript must be non-empty. `style_override` optionally pins a
    /// one-time style directive for this session alone (ticket 23's
    /// 指定场景重新修正): rerolls keep it, the session ends with it,
    /// and the live selection (SetStyleDirective) applies again. `None`
    /// runs under the live selection as before.
    RectifyText {
        raw_transcript: String,
        style_override: Option<String>,
    },
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
    /// Toggle passage mode (篇章模式) at runtime: silence only marks
    /// paragraphs vs. a long silence auto-ends the session. Snapshotted
    /// when a session opens, so a switch applies from the next session
    /// on. Valid any time.
    SetPassageMode(bool),
    /// Switch the latency timings at runtime (the settings window's
    /// advanced form). Snapshotted when a session opens, so a switch
    /// applies from the next session on. Valid any time.
    SetEngineTimings(EngineTimings),
}
