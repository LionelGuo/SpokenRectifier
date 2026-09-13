//! Golden-sample assertions on the composed prompts: the exact system and
//! user text the rectify pipeline sends. Light-touch must forbid reordering
//! and rewording; full rectify must permit passage-level reorganization;
//! the default register and a user style directive must each freeze their
//! own register line. Each no-pin case has a `-pins` twin with sentinels
//! in the transcript — diffing a pair shows exactly the placeholder
//! branch's injection (ADR-0012), and the no-pin files staying untouched
//! is the byte-identity contract. Each `-pins` case has a `-pins-off`
//! twin with prefill off — the raw pass-through form (ADR-0014) — so
//! diffing those two shows exactly what the switch swaps.

use spokenrectifier_engine::provider::llm::RectifyRequest;
use spokenrectifier_llm::{Intensity, compose_prompt};

// A representative scenario directive (the register a "Prompt 工程"
// scenario would carry).
const DIRECTIVE: &str = "输出将直接用作 AI 提示词:保留全部技术细节与指令语义,信息密度优先,可按逻辑分点、分行组织,行内代码用反引号";

// A representative global directive (ticket 22).
const GLOBAL: &str = "全部输出以简体中文书写,语气克制,不用网络流行语。";

// Twin of the light-general transcript with a pin in it.
const PIN_PARAGRAPHS_LIGHT: &[&str] = &["嗯,明天‡1‡开会"];

// Twin of the two-paragraph transcript carrying numbers 1, 2 and 10 —
// 1 twice, so the census dedup and the numeric row order are both frozen.
const PIN_PARAGRAPHS_FULL: &[&str] = &[
    "嗯,发给张三‡1‡,再打开这个文件‡2‡",
    "后来又提了‡1‡和‡10‡一次",
];

// NOTE: this helper is deliberately duplicated in examples/gen_golden.rs;
// the golden assertions below fail loudly if the two ever drift.
fn request(
    style_directive: Option<&str>,
    global_directive: Option<&str>,
    terms: &[&str],
    paragraphs: &[&str],
) -> RectifyRequest {
    RectifyRequest {
        raw_transcript: paragraphs.join("\n"),
        paragraphs: paragraphs.iter().map(|p| p.to_string()).collect(),
        style_directive: style_directive.map(str::to_string),
        global_directive: global_directive.map(str::to_string),
        terms: terms.iter().map(|t| t.to_string()).collect(),
        prefill: true,
    }
}

// NOTE: also duplicated in examples/gen_golden.rs; the pass-through twin
// of `request` (ADR-0014).
fn request_off(
    style_directive: Option<&str>,
    global_directive: Option<&str>,
    terms: &[&str],
    paragraphs: &[&str],
) -> RectifyRequest {
    let mut request = request(style_directive, global_directive, terms, paragraphs);
    request.prefill = false;
    request
}

#[test]
fn light_touch_default_register_system_prompt_is_golden() {
    let prompt = compose_prompt(
        &request(None, None, &[], &["嗯,明天三点开会"]),
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
        &request(
            None,
            None,
            &["Kubernetes", "QRS 波群"],
            &["第一段话", "第二段话"],
        ),
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
            None,
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

#[test]
fn a_global_directive_alone_keeps_the_default_register_and_is_golden() {
    let prompt = compose_prompt(
        &request(
            None,
            Some(GLOBAL),
            &["Kubernetes", "QRS 波群"],
            &["第一段话", "第二段话"],
        ),
        Intensity::Full,
    );
    assert_eq!(prompt.system, include_str!("golden/full-global-system.txt"));
    assert_eq!(prompt.user, include_str!("golden/full-global-user.txt"));
}

#[test]
fn a_global_directive_under_a_scenario_directive_is_golden() {
    let prompt = compose_prompt(
        &request(
            Some(DIRECTIVE),
            Some(GLOBAL),
            &["Kubernetes", "QRS 波群"],
            &["第一段话", "第二段话"],
        ),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-global-directive-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/full-global-directive-user.txt")
    );
}

// -- the placeholder twins (ticket 17) ------------------------------------
//
// Each mirrors its no-pin counterpart above with sentinels in the
// transcript; the untouched no-pin files above are the contract that the
// branch injects only with pins.

#[test]
fn light_touch_with_pins_is_golden() {
    let prompt = compose_prompt(
        &request(None, None, &[], PIN_PARAGRAPHS_LIGHT),
        Intensity::LightTouch,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/light-general-pins-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/light-general-pins-user.txt")
    );
}

#[test]
fn full_rectify_with_pins_and_the_default_register_is_golden() {
    let prompt = compose_prompt(
        &request(None, None, &["Kubernetes", "QRS 波群"], PIN_PARAGRAPHS_FULL),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-default-pins-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/full-default-pins-user.txt")
    );
}

#[test]
fn full_rectify_with_pins_and_a_directive_is_golden() {
    let prompt = compose_prompt(
        &request(
            Some(DIRECTIVE),
            None,
            &["Kubernetes", "QRS 波群"],
            PIN_PARAGRAPHS_FULL,
        ),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-directive-pins-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/full-directive-pins-user.txt")
    );
}

#[test]
fn full_rectify_with_pins_and_a_global_directive_is_golden() {
    let prompt = compose_prompt(
        &request(
            None,
            Some(GLOBAL),
            &["Kubernetes", "QRS 波群"],
            PIN_PARAGRAPHS_FULL,
        ),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-global-pins-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/full-global-pins-user.txt")
    );
}

#[test]
fn full_rectify_with_pins_and_both_directives_is_golden() {
    let prompt = compose_prompt(
        &request(
            Some(DIRECTIVE),
            Some(GLOBAL),
            &["Kubernetes", "QRS 波群"],
            PIN_PARAGRAPHS_FULL,
        ),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-global-directive-pins-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/full-global-directive-pins-user.txt")
    );
}

// -- the pass-through twins (ADR-0014) -------------------------------------
//
// Each mirrors its `-pins` counterpart with prefill off: same transcript,
// same directives — only the pinned branch's form differs.

#[test]
fn light_touch_with_pins_off_is_golden() {
    let prompt = compose_prompt(
        &request_off(None, None, &[], PIN_PARAGRAPHS_LIGHT),
        Intensity::LightTouch,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/light-general-pins-off-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/light-general-pins-off-user.txt")
    );
}

#[test]
fn full_rectify_with_pins_off_and_the_default_register_is_golden() {
    let prompt = compose_prompt(
        &request_off(None, None, &["Kubernetes", "QRS 波群"], PIN_PARAGRAPHS_FULL),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-default-pins-off-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/full-default-pins-off-user.txt")
    );
}

#[test]
fn full_rectify_with_pins_off_and_a_directive_is_golden() {
    let prompt = compose_prompt(
        &request_off(
            Some(DIRECTIVE),
            None,
            &["Kubernetes", "QRS 波群"],
            PIN_PARAGRAPHS_FULL,
        ),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-directive-pins-off-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/full-directive-pins-off-user.txt")
    );
}

#[test]
fn full_rectify_with_pins_off_and_a_global_directive_is_golden() {
    let prompt = compose_prompt(
        &request_off(
            None,
            Some(GLOBAL),
            &["Kubernetes", "QRS 波群"],
            PIN_PARAGRAPHS_FULL,
        ),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-global-pins-off-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/full-global-pins-off-user.txt")
    );
}

#[test]
fn full_rectify_with_pins_off_and_both_directives_is_golden() {
    let prompt = compose_prompt(
        &request_off(
            Some(DIRECTIVE),
            Some(GLOBAL),
            &["Kubernetes", "QRS 波群"],
            PIN_PARAGRAPHS_FULL,
        ),
        Intensity::Full,
    );
    assert_eq!(
        prompt.system,
        include_str!("golden/full-global-directive-pins-off-system.txt")
    );
    assert_eq!(
        prompt.user,
        include_str!("golden/full-global-directive-pins-off-user.txt")
    );
}
