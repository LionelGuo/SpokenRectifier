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

    /// The parseable names, comma-joined — error messages listing the
    /// valid values quote this so the list cannot drift from [`parse`].
    pub fn valid_names() -> &'static str {
        "general-written, prompt, formal-document"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_valid_name_parses_and_names_round_trip() {
        for name in Style::valid_names().split(", ") {
            let style = Style::parse(name).unwrap_or_else(|| panic!("{name} did not parse"));
            assert_eq!(style.name(), name);
        }
    }
}
