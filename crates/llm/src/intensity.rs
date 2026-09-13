//! Intensity tiering (glossary: 整理强度, 轻修, 全量修正).
//!
//! Short utterances get light-touch rectify; medium and long ones get full
//! rectify. The threshold is the character count of the raw transcript
//! (CJK counts one per character). Intensity changes only how the prompt
//! asks for rectify — the model stays the same either way.
//!
//! The light-touch master switch (整理强度, `[rectify.light_touch] enabled`)
//! gates the tier: off means every utterance takes full rectify, whatever
//! its length (ADR-0015).

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

/// Pick the intensity for an utterance: with the light-touch gate open,
/// strictly below `light_touch_max_chars` characters is light-touch,
/// otherwise full; with the gate closed, always full.
pub fn select_intensity(
    raw_transcript: &str,
    light_touch_enabled: bool,
    light_touch_max_chars: usize,
) -> Intensity {
    if light_touch_enabled && raw_transcript.chars().count() < light_touch_max_chars {
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
        assert_eq!(
            select_intensity(&chars(39), true, 40),
            Intensity::LightTouch
        );
    }

    #[test]
    fn at_threshold_is_full() {
        // "低于阈值" 走轻修: the threshold itself already goes full.
        assert_eq!(select_intensity(&chars(40), true, 40), Intensity::Full);
    }

    #[test]
    fn threshold_is_configurable() {
        assert_eq!(select_intensity(&chars(9), true, 10), Intensity::LightTouch);
        assert_eq!(select_intensity(&chars(10), true, 10), Intensity::Full);
    }

    #[test]
    fn counts_characters_not_bytes() {
        // Each CJK character is one char but three bytes; a 30-character
        // utterance is 90 bytes and must still be light-touch at 40.
        assert_eq!(
            select_intensity(&chars(30), true, 40),
            Intensity::LightTouch
        );
        assert_eq!(chars(30).len(), 90);
    }

    #[test]
    fn empty_transcript_is_light_touch() {
        assert_eq!(select_intensity("", true, 40), Intensity::LightTouch);
    }

    /// The master switch closed (轻修总开关关) means full rectify for every
    /// length — the gate overrides the threshold entirely (ADR-0015).
    #[test]
    fn a_closed_gate_means_full_rectify_at_every_length() {
        assert_eq!(select_intensity("", false, 40), Intensity::Full);
        assert_eq!(select_intensity(&chars(39), false, 40), Intensity::Full);
        assert_eq!(select_intensity(&chars(1), false, 40), Intensity::Full);
    }
}
