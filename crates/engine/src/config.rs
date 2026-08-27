//! Engine configuration, fixed at construction. Hot-reloadable config
//! arrives with the configuration work (file-backed settings); the fields
//! here cover the session semantics the state machine already needs.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineConfig {
    /// Passage mode (篇章模式): silence only marks paragraphs; the session
    /// ends only on explicit stop. Default on. This field is the
    /// construction-time value; the runtime switch is
    /// [`Command::SetPassageMode`](crate::Command::SetPassageMode).
    pub passage_mode: bool,
    /// Silence duration that marks a paragraph in passage mode.
    pub paragraph_silence_ms: u64,
    /// Silence duration that auto-ends the session when passage mode is off.
    pub session_end_silence_ms: u64,
    /// Wall-clock hard cap per rectify attempt (first stop and every
    /// reroll each get a fresh budget). Expiry aborts the session with an
    /// Error event instead of wedging in `Rectifying`.
    pub rectify_timeout_ms: u64,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            passage_mode: true,
            paragraph_silence_ms: 1200,
            session_end_silence_ms: 3000,
            rectify_timeout_ms: 25_000,
        }
    }
}
