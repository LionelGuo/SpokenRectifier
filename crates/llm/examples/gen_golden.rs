//! Regenerate the golden prompt files under `tests/golden/`.
//!
//! Run with `cargo run -p spokenrectifier-llm --example gen_golden` after
//! deliberately changing prompt text, then review the diff like any code
//! change — the golden files are the contract with the model.

use std::fs;
use std::path::PathBuf;

use spokenrectifier_engine::Style;
use spokenrectifier_engine::provider::llm::RectifyRequest;
use spokenrectifier_llm::{Intensity, compose_prompt};

fn request(style: Style, terms: &[&str], paragraphs: &[&str]) -> RectifyRequest {
    RectifyRequest {
        raw_transcript: paragraphs.join("\n"),
        paragraphs: paragraphs.iter().map(|p| p.to_string()).collect(),
        style,
        terms: terms.iter().map(|t| t.to_string()).collect(),
    }
}

fn main() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden");

    let light = compose_prompt(
        &request(Style::GeneralWritten, &[], &["嗯,明天三点开会"]),
        Intensity::LightTouch,
    );
    fs::write(dir.join("light-general-system.txt"), &light.system).unwrap();
    fs::write(dir.join("light-general-user.txt"), &light.user).unwrap();

    let full = compose_prompt(
        &request(
            Style::Prompt,
            &["Kubernetes", "QRS 波群"],
            &["第一段话", "第二段话"],
        ),
        Intensity::Full,
    );
    fs::write(dir.join("full-prompt-system.txt"), &full.system).unwrap();
    fs::write(dir.join("full-prompt-user.txt"), &full.user).unwrap();

    println!("golden files written to {}", dir.display());
}
