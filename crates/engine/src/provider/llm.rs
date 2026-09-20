//! Rectify LLM collaborator (glossary: 修正).
//!
//! Pure OpenAI-compatible endpoints with a user-supplied key; prompt
//! assembly, fidelity rules, and intensity routing live in the rectify
//! pipeline, not in the engine. The trait only streams token deltas.

use async_trait::async_trait;
use futures::stream::BoxStream;

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
    /// The selected scenario's style-directive text, verbatim; `None`
    /// means the built-in default register (通用书面). Only this resolved
    /// text crosses the engine seam — scenario names and lists live in
    /// the shell.
    pub style_directive: Option<String>,
    /// The global directive's text, verbatim; `None` = no global
    /// directive. Layered under the scenario's directive by the prompt
    /// (ADR-0006: conflicts follow the scenario). Read fresh when each
    /// request is built — never pinned per session.
    pub global_directive: Option<String>,
    /// Domain terms from the hotword dictionary, verbatim-preserved in the
    /// rectified text. Filled by the hotword pipeline; the rectify prompt
    /// renders them as a reference list.
    pub terms: Vec<String>,
    /// Whether a pinned prompt teaches the inline prefill grammar
    /// (absorption, `‡N:值‡`). `false` selects the raw pass-through form:
    /// zero absorption, marks riding the rectified text as-is, no census
    /// table (ADR-0014). Meaningless without pins — a no-pin composition
    /// is byte-identical either way (ADR-0012).
    pub prefill: bool,
    /// Whether this attempt is a quick-mode pass-through (ADR-0020): the
    /// session was upgraded by holding the hotkey past the threshold, so
    /// there is no preview, no edit phase, and never a placeholder slot.
    /// The client answers it by taking the light-touch intensity section
    /// whatever the length and the master switch say, swapping the quick
    /// extra directive in for the light-touch one, and forcing thinking
    /// off. `false` — every ordinary attempt — composes exactly as
    /// before: the flag changes nothing by itself.
    pub quick: bool,
}

/// One item off a rectify stream: the rectified-body delta and — when
/// the endpoint walks a thinking channel — the thinking-text delta
/// (ADR-0019 item 6). Either arm may be empty on a given item; a
/// non-empty [`Self::reasoning`] is the 「正在思考」 signal. Thinking
/// text is feedback material for the session window's one-shot marquee
/// (14 号票) — it never merges into the rectified body.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RectifyDelta {
    /// A rectified-text token delta, if this item carried one.
    pub content: Option<String>,
    /// Thinking-channel text delta, verbatim.
    pub reasoning: Option<String>,
}

impl RectifyDelta {
    /// A body-only item (the historical bare-`String` shape).
    pub fn content(text: String) -> Self {
        Self {
            content: Some(text),
            reasoning: None,
        }
    }

    /// A thinking-only item — the 「正在思考」 signal.
    pub fn reasoning(text: String) -> Self {
        Self {
            content: None,
            reasoning: Some(text),
        }
    }
}

/// Stream of rectify deltas: body and thinking text interleaved as the
/// endpoint produced them.
pub type RectifyTokenStream = BoxStream<'static, Result<RectifyDelta, RectifyError>>;

#[async_trait]
pub trait RectifyLlm: Send + Sync + 'static {
    async fn rectify(&self, request: RectifyRequest) -> Result<RectifyTokenStream, RectifyError>;

    /// Observation seam for the eval's thinking-length column
    /// (`.scratch/placeholder-process/issues/06`): called once after a
    /// case's stream has ended, returns the reasoning chars that one
    /// stream carried and resets the count for the next case. `None` —
    /// the default — marks a provider that does not instrument
    /// reasoning; the thinking text itself never crosses this seam.
    fn take_reasoning_chars(&self) -> Option<u64> {
        None
    }
}
