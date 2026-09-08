//! Commands accepted by the engine (glossary: 会话, 修正, 预览窗).

use crate::config::EngineTimings;

/// How one rectify session picks its style directive (the 场景 layer):
/// follow the live selection, or pin one of the two one-time picks
/// history retrieval offers (指定场景重新修正's named scenarios and its
/// built-in 默认 item).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionStyle {
    /// No pin: every attempt of the session follows the live selection
    /// ([`Command::SetStyleDirective`]) — mic sessions and plain
    /// re-rectifies.
    Live,
    /// Pinned to a directive text for this session's lifetime: rerolls
    /// keep it, the session ends with it, and the live selection applies
    /// again afterwards.
    Directive(String),
    /// Pinned to the built-in default register for this session's
    /// lifetime (指定场景重新修正's 默认 item): the live selection is
    /// ignored and requests carry no style directive at all —
    /// byte-for-byte the shape of a session with no scenario.
    DefaultRegister,
}

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
    /// transcript must be non-empty. `style` optionally pins the
    /// session's style pick (see [`SessionStyle`]) — rerolls keep it,
    /// the session ends with it, and the live selection
    /// (SetStyleDirective) applies again.
    RectifyText {
        raw_transcript: String,
        style: SessionStyle,
    },
    /// End the recording session and start rectifying (hotkey press again).
    StopSession,
    /// Pin a placeholder (钉入) at the current position of the spoken
    /// segment. Valid only while recording: the sentinel `‡N‡` appears in
    /// the live transcript at once and rides the same join into the frozen
    /// transcript and the rectify request. Numbers run from 1 in pin order
    /// within the session — never reused, never carried across sessions.
    /// A pin is not speech: it never re-arms the paragraph rules, and a
    /// pin-only session survives the recording-end discard only through
    /// its non-empty frozen transcript. Rejected with no state change
    /// outside recording.
    PinPlaceholder,
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
    /// Set the global directive's text (ticket 22; the engine knows
    /// nothing about where it is stored). `None` unsets it. Unlike the
    /// one-time style override, the global directive is a live value read
    /// when each request is built: a change any time shapes the next
    /// attempt, rerolls of an open session included. Valid any time.
    SetGlobalDirective(Option<String>),
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
