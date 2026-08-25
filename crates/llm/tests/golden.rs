//! Golden-sample assertions on the composed prompts: the exact system and
//! user text the rectify pipeline sends. Light-touch must forbid reordering
//! and rewording; full rectify must permit passage-level reorganization.

use spokenrectifier_engine::Style;
use spokenrectifier_engine::provider::llm::RectifyRequest;
use spokenrectifier_llm::{Intensity, compose_prompt};

// NOTE: this helper is deliberately duplicated in examples/gen_golden.rs;
// the golden assertions below fail loudly if the two ever drift.
fn request(style: Style, terms: &[&str], paragraphs: &[&str]) -> RectifyRequest {
    RectifyRequest {
        raw_transcript: paragraphs.join("\n"),
        paragraphs: paragraphs.iter().map(|p| p.to_string()).collect(),
        style,
        terms: terms.iter().map(|t| t.to_string()).collect(),
    }
}

#[test]
fn light_touch_general_written_system_prompt_is_golden() {
    let prompt = compose_prompt(
        &request(Style::GeneralWritten, &[], &["嗯,明天三点开会"]),
        Intensity::LightTouch,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/light-general-system.txt")
    );
    assert_eq!(prompt.user, include_str!("golden/light-general-user.txt"));
}

#[test]
fn full_rectify_prompt_style_system_prompt_is_golden() {
    let prompt = compose_prompt(
        &request(
            Style::Prompt,
            &["Kubernetes", "QRS 波群"],
            &["第一段话", "第二段话"],
        ),
        Intensity::Full,
    );
    assert_eq!(prompt.system, include_str!("golden/full-prompt-system.txt"));
    assert_eq!(prompt.user, include_str!("golden/full-prompt-user.txt"));
}
