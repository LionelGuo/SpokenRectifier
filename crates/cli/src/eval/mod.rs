//! The fidelity eval (glossary: 保真铁律): golden cases, machine
//! assertions, and a report. The [`sr-eval`](../../src/bin/sr-eval.rs)
//! binary drives these against the real LLM through the engine seam.

pub mod cases;
pub mod check;
pub mod report;
