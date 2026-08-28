//! The fidelity eval (glossary: 保真铁律): golden cases, machine
//! assertions, a report, and the runner that drives the cases through a
//! dedicated engine (ticket 10; bridged into the app's settings window by
//! ticket 18). The [`sr-eval`](../../crates/cli/src/bin/sr-eval.rs) CLI
//! and the app's in-process run share this crate — one suite, one
//! harness, two front doors.

pub mod cases;
pub mod check;
pub mod report;
pub mod runner;

/// The suite as it ships: compiled into whatever binary runs the eval,
/// so an installed app evaluates exactly the suite its build carried
/// (a source-tree path would not exist on an end-user machine). The
/// [`cases`] tests pin it valid; the CLI's `--suite` flag stays the
/// iteration path for prompt work.
pub const EMBEDDED_SUITE: &str = include_str!("../cases.toml");
