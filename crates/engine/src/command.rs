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
    /// Upgrade the recording session to quick mode (ADR-0020): the shell's
    /// hold watcher reports that the hotkey chord crossed the hold
    /// threshold, so this session's release ends the recording and the
    /// stop goes straight through — no preview, no confirmation.
    ///
    /// A quiet no-op (never a rejection: this is a platform signal, not a
    /// user command) when the switch is off, when no session is recording,
    /// when this session already upgraded, or when something is already
    /// pinned — a pin makes the session an ordinary one for its whole
    /// life. Emits [`EngineEvent::QuickMarked`](crate::EngineEvent::QuickMarked)
    /// on the one call that lands.
    MarkQuick,
    /// The hotkey chord is physically down (`held`) or no longer down:
    /// the shell's hold watcher reports it while a session records. A
    /// held chord suppresses the silence auto-end (ADR-0020) — the
    /// speaker is mid-gesture, and the release is what ends the session —
    /// while paragraph marks keep flowing. A quiet no-op outside
    /// recording: the signal is bookkeeping for a live session, and a
    /// release that lands after the session moved on has nothing left to
    /// gate.
    HoldGate { held: bool },
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
    /// Switch the quick-mode settings at runtime (the settings window's
    /// third card, `[rectify.quick]`), right after the file write, so the
    /// live engine adopts the saved values at once instead of at the next
    /// launch (ADR-0010's re-adoption). `enabled` is read when a hold
    /// crosses the threshold, `rectify` when a session opens; both are
    /// valid any time.
    SetQuickMode { enabled: bool, rectify: bool },
}
