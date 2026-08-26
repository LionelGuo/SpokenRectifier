//! The history port: the engine hands every inserted session's texts to
//! the injected recorder (glossary: 历史与取回, 原始转写, 修正文本).
//!
//! Recording is fire-and-forget: it must never block or fail the insert,
//! so the port is infallible and implementations swallow their own errors.

/// One completed session, exactly as it ended: what was said and what
/// went in. Cancelled and failed sessions are never recorded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedSession {
    pub raw_transcript: String,
    pub rectified_text: String,
}

/// Receiver of finished sessions. Absent from [`crate::EngineDeps`]
/// (a `None`) means the session history keeps nothing.
pub trait SessionRecorder: Send + Sync {
    fn record(&self, session: RecordedSession);
}
