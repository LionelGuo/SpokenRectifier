//! Regenerate the golden prompt files under `tests/golden/`.
//!
//! Run with `cargo run -p spokenrectifier-llm --example gen_golden` after
//! deliberately changing prompt text, then review the diff like any code
//! change — the golden files are the contract with the model.

use std::fs;
use std::path::PathBuf;

use spokenrectifier_engine::provider::llm::RectifyRequest;
use spokenrectifier_llm::{Intensity, compose_prompt};

// Keep in sync with the copy in tests/golden.rs; a mismatch fails the
// golden tests on the next run.
const DIRECTIVE: &str = "输出将直接用作 AI 提示词:保留全部技术细节与指令语义,信息密度优先,可按逻辑分点、分行组织,行内代码用反引号";

// NOTE: kept in sync with the copy in tests/golden.rs; a mismatch fails
// the golden tests on the next run.
fn request(style_directive: Option<&str>, terms: &[&str], paragraphs: &[&str]) -> RectifyRequest {
    RectifyRequest {
        raw_transcript: paragraphs.join("\n"),
        paragraphs: paragraphs.iter().map(|p| p.to_string()).collect(),
        style_directive: style_directive.map(str::to_string),
        terms: terms.iter().map(|t| t.to_string()).collect(),
    }
}

fn main() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden");

    let light = compose_prompt(
        &request(None, &[], &["嗯,明天三点开会"]),
        Intensity::LightTouch,
    );
    fs::write(dir.join("light-general-system.txt"), &light.system).unwrap();
    fs::write(dir.join("light-general-user.txt"), &light.user).unwrap();

    let full_default = compose_prompt(
        &request(None, &["Kubernetes", "QRS 波群"], &["第一段话", "第二段话"]),
        Intensity::Full,
    );
    fs::write(dir.join("full-default-system.txt"), &full_default.system).unwrap();
    fs::write(dir.join("full-default-user.txt"), &full_default.user).unwrap();

    let full_directive = compose_prompt(
        &request(
            Some(DIRECTIVE),
            &["Kubernetes", "QRS 波群"],
            &["第一段话", "第二段话"],
        ),
        Intensity::Full,
    );
    fs::write(
        dir.join("full-directive-system.txt"),
        &full_directive.system,
    )
    .unwrap();
    fs::write(dir.join("full-directive-user.txt"), &full_directive.user).unwrap();

    println!("golden files written to {}", dir.display());
}
