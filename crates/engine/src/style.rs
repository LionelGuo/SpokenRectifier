//! Output style presets for the rectified text (glossary: 风格).

/// Target register for the rectified text. Manually switchable; affects the
/// next rectify, including rerolls.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Style {
    /// 通用书面 — everyday written Chinese (default).
    #[default]
    GeneralWritten,
    /// Prompt — text destined for an LLM prompt; technical tokens verbatim.
    Prompt,
    /// 正式文档 — formal documents.
    FormalDocument,
}

impl Style {
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "general" | "general-written" | "通用书面" => Some(Self::GeneralWritten),
            "prompt" => Some(Self::Prompt),
            "formal" | "formal-document" | "正式文档" => Some(Self::FormalDocument),
            _ => None,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Self::GeneralWritten => "general-written",
            Self::Prompt => "prompt",
            Self::FormalDocument => "formal-document",
        }
    }
}
