//! Intensity tiering (glossary: 整理强度, 轻修, 全量修正).
//!
//! Short utterances get light-touch rectify on the fast model; medium and
//! long ones get full rectify on the standard model. The threshold is the
//! character count of the raw transcript (CJK counts one per character).

/// How deeply rectify may intervene.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Intensity {
    /// Light-touch: remove filler, apply spoken corrections, keep sentence
    /// order and wording as spoken. Used below the length threshold.
    LightTouch,
    /// Full rectify: passage-level reorganization and compression allowed,
    /// still bounded by the fidelity rule. Used at or above the threshold.
    Full,
}

/// Pick the intensity for an utterance: strictly below `light_touch_max_chars`
/// characters is light-touch, otherwise full.
pub fn select_intensity(raw_transcript: &str, light_touch_max_chars: usize) -> Intensity {
    if raw_transcript.chars().count() < light_touch_max_chars {
        Intensity::LightTouch
    } else {
        Intensity::Full
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chars(n: usize) -> String {
        "字".repeat(n)
    }

    #[test]
    fn below_threshold_is_light_touch() {
        assert_eq!(select_intensity(&chars(39), 40), Intensity::LightTouch);
    }

    #[test]
    fn at_threshold_is_full() {
        // "低于阈值" 走轻修: the threshold itself already goes full.
        assert_eq!(select_intensity(&chars(40), 40), Intensity::Full);
    }

    #[test]
    fn threshold_is_configurable() {
        assert_eq!(select_intensity(&chars(9), 10), Intensity::LightTouch);
        assert_eq!(select_intensity(&chars(10), 10), Intensity::Full);
    }

    #[test]
    fn counts_characters_not_bytes() {
        // Each CJK character is one char but three bytes; a 30-character
        // utterance is 90 bytes and must still be light-touch at 40.
        assert_eq!(select_intensity(&chars(30), 40), Intensity::LightTouch);
        assert_eq!(chars(30).len(), 90);
    }

    #[test]
    fn empty_transcript_is_light_touch() {
        assert_eq!(select_intensity("", 40), Intensity::LightTouch);
    }
}
