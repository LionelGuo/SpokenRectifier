//! ASR collaborator (glossary: 原始转写).
//!
//! One adapter per provider — domestic cloud ASR services speak private
//! WebSocket protocols, so there is deliberately no "OpenAI-compatible"
//! assumption here. The provider owns audio capture and network details;
//! the engine only sees the event stream. Dropping the stream ends
//! recognition without further output.

use async_trait::async_trait;
use futures::stream::BoxStream;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsrEvent {
    /// Interim recognition of speech in progress; supersedes the previous
    /// partial for the current paragraph.
    Partial { text: String },
    /// Finalized recognized speech since the previous event.
    Final { text: String },
    /// Cumulative silence since the last speech event (VAD). The engine
    /// compares this against its configured silence thresholds.
    Silence { elapsed_ms: u64 },
}

#[derive(Debug, thiserror::Error)]
#[error("failed to open ASR stream: {0}")]
pub struct AsrOpenError(pub String);

#[async_trait]
pub trait AsrProvider: Send + Sync + 'static {
    async fn open_stream(&self) -> Result<BoxStream<'static, AsrEvent>, AsrOpenError>;
}
