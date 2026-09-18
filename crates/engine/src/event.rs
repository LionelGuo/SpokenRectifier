//! Events emitted by the engine, and the session state machine states.

use crate::prefill::PrefillRow;

/// Identifier of a recording session. Monotonic per engine instance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SessionId(pub u64);

impl std::fmt::Display for SessionId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "#{}", self.0)
    }
}

/// Session states. `Inserted` and `Cancelled` are transient terminal states:
/// the engine immediately continues to `Idle`, so there are no dead ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SessionState {
    #[default]
    Idle,
    /// Recording; ASR events flowing.
    Recording,
    /// Rectifying; LLM token stream flowing.
    Rectifying,
    /// Rectified text ready; awaiting confirm / edit / reroll.
    Preview,
    /// Text inserted (transient; auto-continues to `Idle`).
    Inserted,
    /// Session discarded (transient; auto-continues to `Idle`).
    Cancelled,
}

impl SessionState {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Idle => "Idle",
            Self::Recording => "Recording",
            Self::Rectifying => "Rectifying",
            Self::Preview => "Preview",
            Self::Inserted => "Inserted",
            Self::Cancelled => "Cancelled",
        }
    }
}

impl std::fmt::Display for SessionState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

/// Engine-emitted events (glossary: 原始转写, 修正文本, 预览窗).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineEvent {
    /// A session state transition happened.
    SessionStateChanged {
        from: SessionState,
        to: SessionState,
    },
    /// The cumulative live raw transcript changed (partials included).
    LiveTranscriptUpdated { text: String },
    /// A silence long enough to mark a paragraph boundary (passage mode).
    ParagraphMarked,
    /// The recording session was upgraded to quick mode (ADR-0020): the
    /// hotkey chord was held past the threshold with nothing pinned, so
    /// this session's release ends it and its stop goes straight through.
    /// Emitted once per session, the moment the flag is set; the shell
    /// hangs the 聆听中 phase word and the pin-hotkey disarm off it. No
    /// other event changes shape — the session is still `Recording`.
    QuickMarked,
    /// The user started / stopped speaking per VAD. Only flows while
    /// recording; the shell mirrors it into the orb's speaking state.
    SpeechActivityChanged { speaking: bool },
    /// An incremental piece of the rectified text. For a pin session
    /// the body streams verbatim with its inline prefill forms
    /// (`‡N:值‡`); only a half-grown sentinel run (`‡N`) is held back
    /// until it resolves, so fragments never flash (ruling 26).
    RectifiedTextChunk { delta: String },
    /// The prefill table parsed from a pin session's rectify response
    /// body, delivered once per attempt as it enters Preview: after the
    /// last `RectifiedTextChunk`, before the Preview state change. Rows
    /// ride exactly as the model wrote them — a bare `‡N‡` is an empty
    /// value, an unclosed `‡N:值` at the stream's end keeps its
    /// accumulated chars — and the rows come from the body itself, so
    /// every row's number is one the body carries. Never emitted for a
    /// pin-less session.
    PreviewPrefills { prefills: Vec<PrefillRow> },
    /// The preview text changed because of user edits.
    PreviewTextUpdated { text: String },
    /// The rectified text was handed to the inserter and accepted.
    TextInserted { text: String },
    /// A recoverable failure (e.g. LLM error, insertion failure); the state
    /// after the error tells whether the session survived.
    Error { message: String },
}

/// What subscribers receive: the event plus ordering and timing metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventEnvelope {
    /// Monotonic sequence number, assigned at emission.
    pub seq: u64,
    /// The session the event belongs to.
    pub session_id: SessionId,
    /// Emission time in ms from the injected [`Clock`](crate::Clock).
    pub at_ms: u64,
    pub event: EngineEvent,
}
