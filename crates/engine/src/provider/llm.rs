//! Rectify LLM collaborator (glossary: 修正).
//!
//! Pure OpenAI-compatible endpoints with a user-supplied key; prompt
//! assembly, fidelity rules, and intensity routing live in the rectify
//! pipeline, not in the engine. The trait only streams token deltas.

use async_trait::async_trait;
use futures::stream::BoxStream;

use crate::style::Style;

#[derive(Debug, thiserror::Error)]
#[error("rectify LLM failed: {0}")]
pub struct RectifyError(pub String);

/// What the engine asks the LLM to rectify.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RectifyRequest {
    /// The full raw transcript, paragraphs separated by `\n`.
    pub raw_transcript: String,
    /// The raw transcript split at paragraph marks.
    pub paragraphs: Vec<String>,
    /// Target output style.
    pub style: Style,
    /// Domain terms from the hotword dictionary, verbatim-preserved in the
    /// rectified text. Filled by the hotword pipeline; the rectify prompt
    /// renders them as a reference list.
    pub terms: Vec<String>,
}

/// Stream of rectified-text token deltas.
pub type RectifyTokenStream = BoxStream<'static, Result<String, RectifyError>>;

#[async_trait]
pub trait RectifyLlm: Send + Sync + 'static {
    async fn rectify(&self, request: RectifyRequest) -> Result<RectifyTokenStream, RectifyError>;
}
