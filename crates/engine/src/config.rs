//! Engine configuration: the construction-time values (seeded from the
//! `[engine]` config files) and the runtime-switchable snapshot shape.

/// The engine's construction-time values. The passage-mode field is only
/// the seed: the runtime switch is
/// [`Command::SetPassageMode`](crate::Command::SetPassageMode), and the
/// timings likewise switch at runtime and snapshot per session (see
/// [`EngineTimings`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineConfig {
    /// Passage mode (篇章模式): silence only marks paragraphs; the session
    /// ends only on explicit stop. Default on.
    pub passage_mode: bool,
    /// Silence duration that marks a paragraph in passage mode.
    pub paragraph_silence_ms: u64,
    /// Silence duration that auto-ends the session when passage mode is off.
    pub session_end_silence_ms: u64,
    /// Wall-clock hard cap per rectify attempt (first stop and every
    /// reroll each get a fresh budget). Expiry aborts the session with an
    /// Error event instead of wedging in `Rectifying`.
    pub rectify_timeout_ms: u64,
    /// The quick-mode master switch (`[rectify.quick] enabled`): with it
    /// off (the default) a mark can never upgrade a session, so the held
    /// hotkey keeps today's exact meaning. Switched at runtime by
    /// [`Command::SetQuickMode`](crate::Command::SetQuickMode) and read
    /// when the hold crosses the threshold.
    pub quick_mode: bool,
    /// Whether an upgraded session runs the model at all
    /// (`[rectify.quick] rectify`): on, the stop goes through the light
    /// touch pass and its result is inserted; off, the frozen raw
    /// transcript is inserted untouched. Snapshotted when each session
    /// opens — the timings rule — so a switch applies from the next
    /// session on.
    pub quick_rectify: bool,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            passage_mode: true,
            paragraph_silence_ms: 1200,
            session_end_silence_ms: 3000,
            rectify_timeout_ms: 25_000,
            quick_mode: false,
            quick_rectify: true,
        }
    }
}

impl EngineConfig {
    /// The timing fields as the runtime-switchable snapshot (ADR-0007:
    /// a switch applies from the next session on, so each session opens
    /// with its own copy).
    pub fn timings(&self) -> EngineTimings {
        EngineTimings {
            paragraph_silence_ms: self.paragraph_silence_ms,
            session_end_silence_ms: self.session_end_silence_ms,
            rectify_timeout_ms: self.rectify_timeout_ms,
        }
    }
}

/// The latency timings a session runs with: seeded from
/// [`EngineConfig`] at construction, switched at runtime by
/// [`Command::SetEngineTimings`](crate::Command::SetEngineTimings)
/// (the settings window's advanced form), and snapshotted when each
/// session opens — so a switch applies from the next session on and
/// never pulls the thresholds out from under a running session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineTimings {
    /// Silence duration that marks a paragraph in passage mode.
    pub paragraph_silence_ms: u64,
    /// Silence duration that auto-ends the session when passage mode is off.
    pub session_end_silence_ms: u64,
    /// Wall-clock hard cap per rectify attempt.
    pub rectify_timeout_ms: u64,
}
