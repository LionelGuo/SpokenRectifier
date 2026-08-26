//! Golden-sample assertions on the composed prompts: the exact system and
//! user text the rectify pipeline sends. Light-touch must forbid reordering
//! and rewording; full rectify must permit passage-level reorganization;
//! the default register and a user style directive must each freeze their
//! own register line.

use spokenrectifier_engine::provider::llm::RectifyRequest;
use spokenrectifier_llm::{Intensity, compose_prompt};

// A representative scenario directive (the register a "Prompt 工程"
// scenario would carry).
const DIRECTIVE: &str = "输出将直接用作 AI 提示词:保留全部技术细节与指令语义,信息密度优先,可按逻辑分点、分行组织,行内代码用反引号";

// NOTE: this helper is deliberately duplicated in examples/gen_golden.rs;
// the golden assertions below fail loudly if the two ever drift.
fn request(style_directive: Option<&str>, terms: &[&str], paragraphs: &[&str]) -> RectifyRequest {
    RectifyRequest {
        raw_transcript: paragraphs.join("\n"),
        paragraphs: paragraphs.iter().map(|p| p.to_string()).collect(),
        style_directive: style_directive.map(str::to_string),
        terms: terms.iter().map(|t| t.to_string()).collect(),
    }
}

#[test]
fn light_touch_default_register_system_prompt_is_golden() {
    let prompt = compose_prompt(
        &request(None, &[], &["嗯,明天三点开会"]),
        Intensity::LightTouch,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/light-general-system.txt")
    );
    assert_eq!(prompt.user, include_str!("golden/light-general-user.txt"));
}

#[test]
fn full_rectify_default_register_system_prompt_is_golden() {
    let prompt = compose_prompt(
        &request(None, &["Kubernetes", "QRS 波群"], &["第一段话", "第二段话"]),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-default-system.txt")
    );
    assert_eq!(prompt.user, include_str!("golden/full-default-user.txt"));
}

#[test]
fn full_rectify_with_a_directive_system_prompt_is_golden() {
    let prompt = compose_prompt(
        &request(
            Some(DIRECTIVE),
            &["Kubernetes", "QRS 波群"],
            &["第一段话", "第二段话"],
        ),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-directive-system.txt")
    );
    assert_eq!(prompt.user, include_str!("golden/full-directive-user.txt"));
}
