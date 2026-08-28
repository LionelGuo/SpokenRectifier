//! The layered-config module: one implementation of the
//! defaults → `spokenrectifier.toml` → `spokenrectifier.local.toml`
//! rule every config section follows.
//!
//! Callers own their section's shape — a struct of `Option` fields plus a
//! fold onto their defaults — and this crate owns everything around it:
//! where the files live, reading them, error formatting, the secrets
//! guard, and section extraction. The interface is one generic load per
//! section; folding the returned overlays in order means local wins.
//! The write side lives in [`section_write`]: one section-preserving
//! writer every settings surface saves through.
//!
//! Error formatting never quotes the TOML source: the offending line may
//! carry a secret from an unrelated section, so errors carry the file,
//! a line and column, and the parser's message — nothing else.
//!
//! The hotword dictionary is not a TOML section: [`terms`] loads the
//! plain-text, one-term-per-line file beside the layer files. The
//! scenario library is not a config layer either: [`scenarios`] loads the
//! app-owned file of named style directives.

pub mod scenarios;
pub mod section_write;
pub mod terms;

use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;

/// The shared, committable layer. Secrets may not live here.
pub const SHARED_FILE: &str = "spokenrectifier.toml";
/// The git-ignored local layer; the only place an `api_key` may live.
pub const LOCAL_FILE: &str = "spokenrectifier.local.toml";

/// A load failure: the file's path plus a message that never quotes the
/// TOML source.
#[derive(Debug, thiserror::Error)]
#[error("config: {0}")]
pub struct ConfigError(pub String);

/// Which layer file an overlay came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayerSource {
    /// `spokenrectifier.toml` — shared, committable, secret-free.
    Shared,
    /// `spokenrectifier.local.toml` — git-ignored, may carry secrets.
    Local,
}

impl LayerSource {
    /// The file this layer lives in, for error messages naming it.
    pub fn file_name(&self) -> &'static str {
        match self {
            LayerSource::Shared => SHARED_FILE,
            LayerSource::Local => LOCAL_FILE,
        }
    }
}

/// One parsed section overlay from one layer file.
#[derive(Debug)]
pub struct Layer<T> {
    pub source: LayerSource,
    pub value: T,
}

/// The directories each layer file is searched in, first hit wins: the
/// working directory first (dev runs and CLI parity), then the
/// executable's directory (a double-clicked portable exe has an arbitrary
/// cwd). Resolve once per process and pass the result around.
pub fn search_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(cwd) = std::env::current_dir() {
        dirs.push(cwd);
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        dirs.push(dir.to_path_buf());
    }
    dirs
}

/// Load the overlays for one section from both layer files.
///
/// Each file resolves independently: the first directory in `dirs`
/// containing it wins, so a shared file in the working directory and a
/// local file beside the exe both apply. A missing file, or a file
/// without the section, contributes no layer. Layers come back
/// shared-first, so folding them onto defaults in order makes local win.
///
/// The shared file additionally passes the secrets guard whatever section
/// was asked for: an `api_key` anywhere in it is rejected, not just under
/// the caller's section.
pub fn load_section_layers<T: DeserializeOwned>(
    dirs: &[PathBuf],
    section: &str,
) -> Result<Vec<Layer<T>>, ConfigError> {
    let mut layers = Vec::new();
    for (file, source) in [
        (SHARED_FILE, LayerSource::Shared),
        (LOCAL_FILE, LayerSource::Local),
    ] {
        let Some(path) = find_file(dirs, file) else {
            continue; // no such layer anywhere: fine
        };
        let Some(table) = read_layer_file(&path)? else {
            continue; // unreadable: treat as absent, like a missing file
        };
        if source == LayerSource::Shared {
            guard_against_secrets(&path, &table)?;
        }
        let Some(value) = table.get(section) else {
            continue; // this layer has nothing to say about the section
        };
        let overlay = T::deserialize(value.clone()).map_err(|err| {
            ConfigError(format!(
                "{}: [{}]: {}",
                path.display(),
                section,
                one_line(&err.to_string())
            ))
        })?;
        layers.push(Layer {
            source,
            value: overlay,
        });
    }
    Ok(layers)
}

/// The first `file` found in `dirs`, if any. A directory that happens to
/// carry the layer's name does not count. Public so consumers that need
/// "where a layer file lives" (the settings entry creating a stub beside
/// the real files) resolve it with the same precedence as loading does.
pub fn find_file(dirs: &[PathBuf], file: &str) -> Option<PathBuf> {
    dirs.iter().map(|dir| dir.join(file)).find(|p| p.is_file())
}

/// Where the app's own created files land when nothing exists yet:
/// beside the local layer file if one exists (the user's config home),
/// else the last search directory (the executable's directory — a
/// portable app's stable home; a double-clicked app's working directory
/// is arbitrary). One rule for every app-owned file's first write.
pub fn settings_home(dirs: &[PathBuf]) -> PathBuf {
    find_file(dirs, LOCAL_FILE)
        .and_then(|local| local.parent().map(|dir| dir.to_path_buf()))
        .or_else(|| dirs.last().cloned())
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Read and parse one layer file. `Ok(None)` for a file that cannot be
/// read: layers are optional, and an unreadable one is as good as absent.
/// Parse failures name the file with a line and column — never the TOML
/// source, whose offending line may carry a secret from another section.
fn read_layer_file(path: &Path) -> Result<Option<toml::Table>, ConfigError> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Ok(None);
    };
    let table = toml::from_str(&text).map_err(|err| {
        let (line, column) = span_line_column(&text, err.span());
        ConfigError(format!(
            "{}: malformed TOML near line {line}, column {column}: {}",
            path.display(),
            one_line(err.message())
        ))
    })?;
    Ok(Some(table))
}

/// Flatten a parser message onto one line: error strings travel into UI
/// banners, and toml appends context on extra lines.
fn one_line(message: &str) -> String {
    message.replace('\n', "; ")
}

/// Line (1-based) and column of a span start, straight from the source
/// text; `(0, 0)` when the error carries no span.
fn span_line_column(text: &str, span: Option<std::ops::Range<usize>>) -> (usize, usize) {
    let Some(range) = span else {
        return (0, 0);
    };
    let before = &text[..range.start];
    let line = before.matches('\n').count() + 1;
    let column = range.start - before.rfind('\n').map_or(0, |i| i + 1) + 1;
    (line, column)
}

/// Reject a non-empty `api_key` anywhere in the shared (committable)
/// file — at the root, under any section, or nested deeper (inside
/// `[llm.extra_body]`, say) — including places the caller never asked
/// about. Failing loudly here beats accepting a key into a file that
/// gets committed. The local file is exempt: it is the key's legal home.
fn guard_against_secrets(path: &Path, table: &toml::Table) -> Result<(), ConfigError> {
    if table_carries_key(table) {
        return Err(ConfigError(format!(
            "{}: api_key may not live in the shared committed config; \
             move it to {LOCAL_FILE}",
            path.display()
        )));
    }
    Ok(())
}

/// Whether this table (at any depth) holds a non-empty string `api_key`.
fn table_carries_key(table: &toml::Table) -> bool {
    let carries_key = |value: &toml::Value| matches!(value.as_str(), Some(key) if !key.is_empty());
    table.get("api_key").is_some_and(carries_key) || table.values().any(value_carries_key)
}

/// Tables hide one level deeper inside values: sub-tables, and arrays of
/// tables (`[[section]]`).
fn value_carries_key(value: &toml::Value) -> bool {
    match value {
        toml::Value::Table(table) => table_carries_key(table),
        toml::Value::Array(items) => items.iter().any(value_carries_key),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    /// A caller-shaped section: all-`Option` fields, folded by the caller.
    #[derive(Debug, Default, Deserialize, PartialEq)]
    struct ToySection {
        name: Option<String>,
        count: Option<u64>,
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn missing_files_leave_no_layers() {
        let dir = scratch("sr-config-missing");
        assert_eq!(
            load_section_layers::<ToySection>(std::slice::from_ref(&dir), "toy")
                .unwrap()
                .len(),
            0
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn malformed_toml_names_line_and_column_and_never_quotes_source() {
        let dir = scratch("sr-config-malformed");
        // A secret line ABOVE the syntax error: an error that quotes the
        // offending region's surroundings would leak it.
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\napi_key = \"sk-secret\"\n[toy\nbroken",
        )
        .unwrap();

        let err = load_section_layers::<ToySection>(std::slice::from_ref(&dir), "toy")
            .unwrap_err()
            .0;
        assert!(err.contains(SHARED_FILE), "got: {err}");
        assert!(err.contains("near line 3, column 5"), "got: {err}");
        assert!(!err.contains('\n'), "multi-line error: {err}");
        assert!(err.contains("column"), "got: {err}");
        assert!(!err.contains("sk-secret"), "leaked the source: {err}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn layers_come_back_shared_first_and_local_last() {
        let dir = scratch("sr-config-order");
        std::fs::write(dir.join(SHARED_FILE), "[toy]\nname = \"shared\"\n").unwrap();
        std::fs::write(dir.join(LOCAL_FILE), "[toy]\ncount = 7\n").unwrap();

        let layers = load_section_layers::<ToySection>(std::slice::from_ref(&dir), "toy").unwrap();
        let sources: Vec<LayerSource> = layers.iter().map(|l| l.source).collect();
        assert_eq!(sources, vec![LayerSource::Shared, LayerSource::Local]);
        assert_eq!(layers[0].value.name.as_deref(), Some("shared"));
        assert_eq!(layers[1].value.count, Some(7));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_absent_section_contributes_no_layer() {
        let dir = scratch("sr-config-absent-section");
        std::fs::write(dir.join(LOCAL_FILE), "[other]\nname = \"x\"\n").unwrap();
        std::fs::write(dir.join(SHARED_FILE), "[toy]\ncount = 1\n").unwrap();

        // Shared has the section, local does not: one layer, from shared.
        let layers = load_section_layers::<ToySection>(std::slice::from_ref(&dir), "toy").unwrap();
        assert_eq!(layers.len(), 1);
        assert_eq!(layers[0].source, LayerSource::Shared);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn api_key_in_shared_is_rejected_under_any_section() {
        let dir = scratch("sr-config-guard");
        // The key sits under a section the caller never asked about.
        std::fs::write(dir.join(SHARED_FILE), "[llm]\napi_key = \"sk-oops\"\n").unwrap();

        let err = load_section_layers::<ToySection>(std::slice::from_ref(&dir), "toy")
            .unwrap_err()
            .0;
        assert!(err.contains(SHARED_FILE), "got: {err}");
        assert!(err.contains("local"), "got: {err}");
        assert!(!err.contains("sk-oops"), "leaked the key: {err}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn api_key_nested_in_a_sub_table_of_shared_is_rejected() {
        let dir = scratch("sr-config-guard-nested");
        // A key hidden one table deeper than a section header.
        std::fs::write(
            dir.join(SHARED_FILE),
            "[toy]\ncount = 1\n[llm.extra_body]\napi_key = \"sk-deep\"\n",
        )
        .unwrap();

        let err = load_section_layers::<ToySection>(std::slice::from_ref(&dir), "toy")
            .unwrap_err()
            .0;
        assert!(err.contains(SHARED_FILE), "got: {err}");
        assert!(err.contains("local"), "got: {err}");
        assert!(!err.contains("sk-deep"), "leaked the key: {err}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn api_key_in_local_is_fine() {
        let dir = scratch("sr-config-guard-local");
        std::fs::write(dir.join(LOCAL_FILE), "[toy]\nname = \"sk-local\"\n").unwrap();
        assert_eq!(
            load_section_layers::<ToySection>(std::slice::from_ref(&dir), "toy")
                .unwrap()
                .len(),
            1
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn each_file_resolves_independently_and_first_hit_wins() {
        let one = scratch("sr-config-search-one");
        let two = scratch("sr-config-search-two");
        std::fs::write(one.join(SHARED_FILE), "[toy]\nname = \"from-one\"\n").unwrap();
        std::fs::write(two.join(SHARED_FILE), "[toy]\nname = \"from-two\"\n").unwrap();
        std::fs::write(two.join(LOCAL_FILE), "[toy]\ncount = 9\n").unwrap();

        // Shared is found in `one` (first hit), local only exists in `two`:
        // both apply, each from where it lives.
        let layers = load_section_layers::<ToySection>(&[one.clone(), two.clone()], "toy").unwrap();
        assert_eq!(layers.len(), 2);
        assert_eq!(layers[0].value.name.as_deref(), Some("from-one"));
        assert_eq!(layers[1].value.count, Some(9));
        std::fs::remove_dir_all(one).unwrap();
        std::fs::remove_dir_all(two).unwrap();
    }

    #[test]
    fn a_type_mismatch_names_the_file_and_the_section() {
        let dir = scratch("sr-config-type");
        std::fs::write(dir.join(SHARED_FILE), "[toy]\ncount = \"many\"\n").unwrap();

        let err = load_section_layers::<ToySection>(std::slice::from_ref(&dir), "toy")
            .unwrap_err()
            .0;
        assert!(err.contains(SHARED_FILE), "got: {err}");
        assert!(err.contains("toy"), "got: {err}");
        // Single line only: a multi-line error is a quoted source snippet.
        assert!(!err.contains('\n'), "quoted the source: {err}");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
