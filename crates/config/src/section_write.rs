//! The write side of the layered-config rule: section-preserving edits
//! into the layer files. The read side is [`crate::load_section_layers`];
//! every settings surface that writes a section back (history, ASR, LLM)
//! funnels through [`write_section_fields`] so one implementation owns
//! the placement and preservation rules.
//!
//! Placement: non-secret fields land in the layer that OWNS the section —
//! the last layer file saying anything about it (writing anywhere else
//! would be masked) — or the shared file when no layer does. A secret
//! (`api_key`) lands in the local file only, whatever owns the section:
//! the shared file may be committed, and the loader rejects a key found
//! there (see the guard in `lib.rs`). The GUI never echoes a stored key
//! back, so [`KeyEdit`] makes "keep the stored one" a first-class action.

use std::path::{Path, PathBuf};

use crate::{ConfigError, LOCAL_FILE, LayerSource, SHARED_FILE, find_file, settings_home};

/// Which layer file a section write lands in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteLayer {
    /// The last layer file saying anything about the section, or the
    /// shared file when none does — the history precedent: the next load
    /// returns exactly what was saved.
    Owning,
    /// The git-ignored local file — the only legal home for a secret,
    /// whatever layer owns the section.
    Local,
}

/// One field write inside a section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SectionField {
    Str {
        name: String,
        value: String,
    },
    Int {
        name: String,
        value: i64,
    },
    Bool {
        name: String,
        value: bool,
    },
    /// Remove the key — from every layer file's section, so a value a
    /// deeper layer still carries cannot resurrect behind the write.
    Reset {
        name: String,
    },
}

impl SectionField {
    /// A string field.
    pub fn str(name: &str, value: impl Into<String>) -> Self {
        SectionField::Str {
            name: name.to_string(),
            value: value.into(),
        }
    }

    /// An integer field.
    pub fn int(name: &str, value: i64) -> Self {
        SectionField::Int {
            name: name.to_string(),
            value,
        }
    }

    /// An integer field from an unsigned value — the u64 timings every
    /// settings form writes. Refused (not wrapped) when the value cannot
    /// ride TOML's i64; `section` prefixes the error so it names the
    /// file section the form was saving.
    pub fn int_u64(section: &str, name: &str, value: u64) -> Result<Self, ConfigError> {
        i64::try_from(value)
            .map(|value| SectionField::Int {
                name: name.to_string(),
                value,
            })
            .map_err(|_| ConfigError(format!("[{section}] {name} is out of range")))
    }

    /// A boolean field.
    pub fn bool(name: &str, value: bool) -> Self {
        SectionField::Bool {
            name: name.to_string(),
            value,
        }
    }

    /// A field removal (back to the built-in default).
    pub fn reset(name: &str) -> Self {
        SectionField::Reset {
            name: name.to_string(),
        }
    }

    fn name(&self) -> &str {
        match self {
            SectionField::Str { name, .. }
            | SectionField::Int { name, .. }
            | SectionField::Bool { name, .. }
            | SectionField::Reset { name } => name,
        }
    }
}

/// What a settings write does to a secret field. The stored value never
/// rides this API: `Keep` leaves the file alone, `Clear` removes the key
/// (falling back to the configured environment variable), `Set` replaces
/// it. An empty `Set` is a `Clear` — an empty key is no key. The field's
/// name is a parameter: every section's secret is `api_key` except the
/// ASR sub-sections (`access_key`, `secret_id`, `secret_key` — ADR-0009),
/// all of them local-layer-only like the rest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyEdit {
    Keep,
    Clear,
    Set(String),
}

impl KeyEdit {
    /// The local-layer field write this edit maps to; `None` when the
    /// file should not be touched at all.
    pub fn as_field(self, field: &str) -> Option<SectionField> {
        match self {
            KeyEdit::Keep => None,
            KeyEdit::Clear => Some(SectionField::reset(field)),
            KeyEdit::Set(key) => {
                let key = key.trim();
                if key.is_empty() {
                    Some(SectionField::reset(field))
                } else {
                    Some(SectionField::str(field, key))
                }
            }
        }
    }

    /// Apply this edit to `section`'s `field` of the local layer — the
    /// secret's only legal home, whatever layer owns the section. A
    /// `Keep` touches nothing (not even creating the file).
    pub fn write_to_local(
        self,
        dirs: &[PathBuf],
        section: &str,
        field: &str,
    ) -> Result<(), ConfigError> {
        match self.as_field(field) {
            Some(field) => write_section_fields(dirs, section, &[field], WriteLayer::Local),
            None => Ok(()),
        }
    }
}

/// A secret's effective placement, for display: the stored key itself
/// never leaves the file — the settings GUI paints this status instead.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyStatus {
    /// No key anywhere: the section runs keyless (or on its fallback).
    Unset,
    /// `api_key` sits in the git-ignored local layer.
    InLocalFile,
    /// The configured environment variable resolves a key.
    FromEnv(String),
}

/// The placement for a section's key pair (its `[asr]`/`[llm]` shape:
/// `api_key` + `api_key_env`): the stored key first, then the configured
/// environment variable, else nothing. One implementation for every
/// section that carries a key — the loader's shared-file guard means a
/// stored `api_key` can only have come from the local layer, so
/// `Some` reads as [`KeyStatus::InLocalFile`] without looking at files.
pub fn key_status(api_key: Option<&str>, api_key_env: Option<&str>) -> KeyStatus {
    if api_key.is_some() {
        return KeyStatus::InLocalFile;
    }
    match api_key_env {
        Some(name) => {
            let from_env = std::env::var(name).is_ok_and(|key| !key.is_empty());
            if from_env {
                KeyStatus::FromEnv(name.to_string())
            } else {
                KeyStatus::Unset
            }
        }
        None => KeyStatus::Unset,
    }
}

/// The components of a section's address: `"asr.volcengine"` addresses
/// the sub-table `[asr.volcengine]` — a `'.'`-separated path, the way
/// TOML itself nests sections.
fn section_steps(section: &str) -> Vec<&str> {
    section.split('.').collect()
}

/// Whether the document holds the section the steps address.
fn contains_section(document: &toml_edit::DocumentMut, steps: &[&str]) -> bool {
    let mut table = document.as_table();
    for key in steps {
        match table.get(key).and_then(toml_edit::Item::as_table) {
            Some(next) => table = next,
            None => return false,
        }
    }
    true
}

/// The nested table the steps address, when it already exists.
fn table_at_mut<'a>(
    document: &'a mut toml_edit::DocumentMut,
    steps: &[&str],
) -> Option<&'a mut toml_edit::Table> {
    let mut table = document.as_table_mut();
    for key in steps {
        table = table.get_mut(key)?.as_table_mut()?;
    }
    Some(table)
}

/// Write fields into one section of the layer files (see the module docs
/// for the placement rule). `section` may name a sub-section through a
/// dotted path (`"asr.volcengine"` → `[asr.volcengine]`), with the same
/// placement and preservation rules. The edit is section-preserving:
/// every other value, comment, and blank line in each touched file
/// survives byte for byte, and a malformed file is refused, never
/// clobbered.
///
/// A save touching two files (a `Reset` stripping a key from every
/// layer) is not atomic: an IO failure after the first write leaves the
/// layers inconsistent until the save is retried. The error surfaces to
/// the caller either way — nothing fails silently.
pub fn write_section_fields(
    dirs: &[PathBuf],
    section: &str,
    fields: &[SectionField],
    layer: WriteLayer,
) -> Result<(), ConfigError> {
    let steps = section_steps(section);
    // Every existing file parses before anything is written: a malformed
    // layer refuses the whole save, and no file is left half-edited.
    let mut documents = Vec::new();
    for source in [LayerSource::Shared, LayerSource::Local] {
        if let Some((path, document)) = read_layer_document(dirs, source)? {
            documents.push((path, document));
        }
    }

    let target = match layer {
        WriteLayer::Local => local_path(dirs),
        WriteLayer::Owning => documents
            .iter()
            .rev()
            .find(|(_, document)| contains_section(document, &steps))
            .map(|(path, _)| path.clone())
            .unwrap_or_else(|| shared_path(dirs)),
    };

    for (path, document) in documents.iter_mut() {
        let is_target = *path == target;
        let resets_here = fields
            .iter()
            .any(|field| matches!(field, SectionField::Reset { .. }));
        if !is_target && !resets_here {
            continue; // untouched by this save
        }
        let original = document.to_string();
        if is_target {
            let table = section_table_mut(document, &steps, path)?;
            for field in fields {
                write_field(table, field);
            }
        }
        if resets_here && let Some(table) = table_at_mut(document, &steps) {
            for field in fields
                .iter()
                .filter(|field| matches!(field, SectionField::Reset { .. }))
            {
                table.remove(field.name());
            }
        }
        if document.to_string() != original {
            render_and_write(path, document)?;
        }
    }

    // A target that does not exist yet still receives its fields — but
    // only meaningful ones: a lone reset creates nothing (there is no
    // key anywhere to remove).
    if !documents.iter().any(|(path, _)| *path == target)
        && fields
            .iter()
            .any(|field| !matches!(field, SectionField::Reset { .. }))
    {
        let mut document = toml_edit::DocumentMut::new();
        let table = section_table_mut(&mut document, &steps, &target)?;
        for field in fields {
            write_field(table, field);
        }
        render_and_write(&target, &document)?;
    }
    Ok(())
}

/// The parsed layer file where it lives, or `None` when absent. A file
/// that exists but cannot be read is an error — never clobbered blind.
fn read_layer_document(
    dirs: &[PathBuf],
    source: LayerSource,
) -> Result<Option<(PathBuf, toml_edit::DocumentMut)>, ConfigError> {
    let Some(path) = find_file(dirs, source.file_name()) else {
        return Ok(None);
    };
    let text = std::fs::read_to_string(&path)
        .map_err(|err| ConfigError(format!("{}: {err}", path.display())))?;
    let document = text
        .parse::<toml_edit::DocumentMut>()
        .map_err(|err| ConfigError(format!("{}: {err}", path.display())))?;
    Ok(Some((path, document)))
}

/// Where the local layer lives, created in [`settings_home`] when absent.
fn local_path(dirs: &[PathBuf]) -> PathBuf {
    find_file(dirs, LOCAL_FILE).unwrap_or_else(|| settings_home(dirs).join(LOCAL_FILE))
}

/// Where the shared layer lives, created in [`settings_home`] when absent.
fn shared_path(dirs: &[PathBuf]) -> PathBuf {
    find_file(dirs, SHARED_FILE).unwrap_or_else(|| settings_home(dirs).join(SHARED_FILE))
}

/// The section's table (nested for a dotted path), created — parents
/// first — when absent; an error when any step exists but is not a table
/// (index-reading a non-table would panic).
fn section_table_mut<'a>(
    document: &'a mut toml_edit::DocumentMut,
    steps: &[&str],
    path: &Path,
) -> Result<&'a mut toml_edit::Table, ConfigError> {
    let mut table = document.as_table_mut();
    for (depth, key) in steps.iter().enumerate() {
        if table.get_mut(key).is_none() {
            let mut created = toml_edit::Table::new();
            // A fresh ancestor renders no header of its own: only the
            // leaf section the write addresses appears in the file.
            if depth + 1 < steps.len() {
                created.set_implicit(true);
            }
            table.insert(key, toml_edit::Item::Table(created));
        }
        table = table
            .get_mut(key)
            .and_then(|item| item.as_table_mut())
            .ok_or_else(|| {
                ConfigError(format!(
                    "{}: [{}] exists but is not a table",
                    path.display(),
                    steps[..=depth].join(".")
                ))
            })?;
    }
    Ok(table)
}

/// One field onto the table: `insert` keeps an existing key's position
/// and formatting, and creates a plain one when absent.
fn write_field(table: &mut toml_edit::Table, field: &SectionField) {
    match field {
        SectionField::Str { name, value } => {
            table.insert(name, toml_edit::value(value));
        }
        SectionField::Int { name, value } => {
            table.insert(name, toml_edit::value(*value));
        }
        SectionField::Bool { name, value } => {
            table.insert(name, toml_edit::value(*value));
        }
        SectionField::Reset { .. } => {} // handled by the removal pass
    }
}

fn render_and_write(path: &Path, document: &toml_edit::DocumentMut) -> Result<(), ConfigError> {
    let mut rendered = document.to_string();
    if !rendered.ends_with('\n') {
        rendered.push('\n');
    }
    std::fs::write(path, rendered).map_err(|err| ConfigError(format!("{}: {err}", path.display())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{LOCAL_FILE, Layer, SHARED_FILE, load_section_layers};

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A toy section the round-trip checks load back through.
    #[derive(Debug, Default, serde::Deserialize, PartialEq)]
    struct ToySection {
        name: Option<String>,
        count: Option<i64>,
        on: Option<bool>,
    }

    fn load_toy(dirs: &[PathBuf]) -> Vec<Layer<ToySection>> {
        load_section_layers::<ToySection>(dirs, "toy").unwrap()
    }

    #[test]
    fn a_write_without_any_layer_creates_the_shared_file_in_the_home() {
        let cwd = scratch("sr-write-fresh-cwd");
        let exe = scratch("sr-write-fresh-exe");
        let dirs = vec![cwd.clone(), exe.clone()];

        write_section_fields(
            &dirs,
            "toy",
            &[
                SectionField::str("name", "a"),
                SectionField::int("count", 2),
            ],
            WriteLayer::Owning,
        )
        .unwrap();

        // settings_home without a local layer = the last search dir; the
        // earlier directory stays untouched, and loading returns exactly
        // what was saved.
        assert!(exe.join(SHARED_FILE).is_file());
        assert!(!cwd.join(SHARED_FILE).exists());
        let layers = load_toy(&dirs);
        assert_eq!(layers.len(), 1);
        assert_eq!(layers[0].value.name.as_deref(), Some("a"));
        assert_eq!(layers[0].value.count, Some(2));
        std::fs::remove_dir_all(cwd).unwrap();
        std::fs::remove_dir_all(exe).unwrap();
    }

    #[test]
    fn a_write_preserves_every_other_value_and_comment_in_the_file() {
        let dir = scratch("sr-write-preserve");
        std::fs::write(
            dir.join(SHARED_FILE),
            "# 手写注释要活着\n[engine]\nparagraph_gap_ms = 900\n\n[toy]\nname = \"old\"\ncount = 90\n",
        )
        .unwrap();

        write_section_fields(
            std::slice::from_ref(&dir),
            "toy",
            &[
                SectionField::str("name", "new"),
                SectionField::bool("on", true),
            ],
            WriteLayer::Owning,
        )
        .unwrap();

        let written = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(
            written.contains("# 手写注释要活着"),
            "comment lost: {written}"
        );
        assert!(
            written.contains("paragraph_gap_ms = 900"),
            "other section lost"
        );
        assert!(written.contains("name = \"new\""));
        assert!(written.contains("count = 90")); // untouched field kept
        assert!(written.contains("on = true"));
        assert!(!written.contains('\r'), "line endings rewritten: {written}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_owning_write_targets_the_layer_that_wins_the_load() {
        let dir = scratch("sr-write-owning");
        // Both layers speak; local wins the load, so the write must land
        // there — writing the shared file would be masked.
        std::fs::write(dir.join(SHARED_FILE), "[toy]\nname = \"shared\"\n").unwrap();
        std::fs::write(dir.join(LOCAL_FILE), "[toy]\ncount = 1\n").unwrap();

        write_section_fields(
            std::slice::from_ref(&dir),
            "toy",
            &[SectionField::str("name", "new")],
            WriteLayer::Owning,
        )
        .unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(
            shared.contains("shared"),
            "shared file was touched: {shared}"
        );
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("name = \"new\""),
            "local not updated: {local}"
        );
        // The load returns exactly what was saved: the shared overlay's
        // old value stays but is masked by the owning local layer.
        let layers = load_toy(std::slice::from_ref(&dir));
        assert_eq!(layers[0].value.name.as_deref(), Some("shared")); // masked
        assert_eq!(layers[1].value.name.as_deref(), Some("new")); // effective
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_local_write_targets_the_local_file_whatever_owns_the_section() {
        let dir = scratch("sr-write-local");
        std::fs::write(dir.join(SHARED_FILE), "[toy]\nname = \"shared\"\n").unwrap();

        write_section_fields(
            std::slice::from_ref(&dir),
            "toy",
            &[SectionField::str("api_key", "sk-local")],
            WriteLayer::Local,
        )
        .unwrap();

        // The shared file keeps its section untouched — a secret never
        // lands in the committable file, whatever owns the section.
        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert_eq!(shared, "[toy]\nname = \"shared\"\n");
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(local.contains("api_key = \"sk-local\""), "got: {local}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_local_write_creates_the_local_file_when_absent() {
        let cwd = scratch("sr-write-local-fresh-cwd");
        let exe = scratch("sr-write-local-fresh-exe");
        std::fs::write(exe.join(SHARED_FILE), "[toy]\nname = \"shared\"\n").unwrap();
        let dirs = vec![cwd.clone(), exe.clone()];

        write_section_fields(
            &dirs,
            "toy",
            &[SectionField::str("api_key", "sk")],
            WriteLayer::Local,
        )
        .unwrap();

        // Beside the shared file (the settings home), not the first dir.
        assert!(exe.join(LOCAL_FILE).is_file());
        assert!(!cwd.join(LOCAL_FILE).exists());
        assert_eq!(
            std::fs::read_to_string(exe.join(LOCAL_FILE)).unwrap(),
            "[toy]\napi_key = \"sk\"\n"
        );
        std::fs::remove_dir_all(cwd).unwrap();
        std::fs::remove_dir_all(exe).unwrap();
    }

    #[test]
    fn a_reset_removes_the_key_from_every_layer() {
        let dir = scratch("sr-write-reset");
        std::fs::write(dir.join(SHARED_FILE), "[toy]\nname = \"shared\"\n").unwrap();
        std::fs::write(dir.join(LOCAL_FILE), "[toy]\ncount = 7\nname = \"local\"\n").unwrap();

        write_section_fields(
            std::slice::from_ref(&dir),
            "toy",
            &[SectionField::reset("name")],
            WriteLayer::Owning,
        )
        .unwrap();

        // Both files lost the key (a surviving shared copy would
        // resurrect behind the owning layer's removal); the rest stays.
        assert_eq!(
            std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap(),
            "[toy]\n"
        );
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(local.contains("count = 7"), "kept: {local}");
        assert!(!local.contains("name"), "not removed: {local}");
        let layers = load_toy(std::slice::from_ref(&dir));
        assert!(layers.iter().all(|layer| layer.value.name.is_none()));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_lone_reset_into_a_missing_file_writes_nothing() {
        let dir = scratch("sr-write-reset-fresh");

        write_section_fields(
            std::slice::from_ref(&dir),
            "toy",
            &[SectionField::reset("name")],
            WriteLayer::Owning,
        )
        .unwrap();

        assert!(!dir.join(SHARED_FILE).exists());
        assert!(!dir.join(LOCAL_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_malformed_layer_refuses_the_whole_save() {
        let dir = scratch("sr-write-malformed");
        // The local file is malformed; the write targets shared. No file
        // may change (a half-applied save across layers is worse than
        // none).
        std::fs::write(dir.join(SHARED_FILE), "[toy]\nname = \"a\"\n").unwrap();
        std::fs::write(dir.join(LOCAL_FILE), "not = = toml").unwrap();

        let err = write_section_fields(
            std::slice::from_ref(&dir),
            "toy",
            &[SectionField::str("name", "b")],
            WriteLayer::Owning,
        )
        .unwrap_err()
        .0;
        assert!(err.contains(LOCAL_FILE), "got: {err}");
        assert_eq!(
            std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap(),
            "[toy]\nname = \"a\"\n"
        );
        assert_eq!(
            std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap(),
            "not = = toml"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_section_holding_a_non_table_is_refused() {
        let dir = scratch("sr-write-non-table");
        std::fs::write(dir.join(SHARED_FILE), "toy = 3\n").unwrap();

        let err = write_section_fields(
            std::slice::from_ref(&dir),
            "toy",
            &[SectionField::str("name", "a")],
            WriteLayer::Owning,
        )
        .unwrap_err()
        .0;
        assert!(err.contains("not a table"), "got: {err}");
        assert_eq!(
            std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap(),
            "toy = 3\n"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn key_edits_map_onto_local_fields_with_empty_set_clearing() {
        assert_eq!(KeyEdit::Keep.as_field("api_key"), None);
        assert_eq!(
            KeyEdit::Clear.as_field("api_key"),
            Some(SectionField::reset("api_key"))
        );
        assert_eq!(
            KeyEdit::Set("sk-x".into()).as_field("api_key"),
            Some(SectionField::str("api_key", "sk-x"))
        );
        assert_eq!(
            KeyEdit::Set("  ".into()).as_field("api_key"),
            Some(SectionField::reset("api_key"))
        );
        // The ASR sub-sections' secret fields ride the same edit shape.
        assert_eq!(
            KeyEdit::Set("volc".into()).as_field("access_key"),
            Some(SectionField::str("access_key", "volc"))
        );
    }

    // -- dotted sub-section paths (the [asr.*] sections, ADR-0009) ---------

    #[test]
    fn a_dotted_sub_section_write_creates_the_nested_tables() {
        let dir = scratch("sr-write-dotted-fresh");

        write_section_fields(
            std::slice::from_ref(&dir),
            "asr.volcengine",
            &[
                SectionField::str("app_id", "123"),
                SectionField::str("resource_id", "volc.seedasr.sauc.duration"),
            ],
            WriteLayer::Owning,
        )
        .unwrap();

        let written = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(written.contains("[asr.volcengine]"), "got: {written}");
        assert!(written.contains("app_id = \"123\""), "got: {written}");
        // The parent [asr] table itself is never emitted bare: only the
        // leaf section the write addressed.
        assert!(!written.contains("[asr]\n"), "got: {written}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_dotted_write_extends_an_existing_asr_section_preserving_its_fields() {
        let dir = scratch("sr-write-dotted-existing");
        std::fs::write(
            dir.join(SHARED_FILE),
            "# comment\n[asr]\nprovider = \"volcengine\"\nmodel = \"big\"\n",
        )
        .unwrap();

        write_section_fields(
            std::slice::from_ref(&dir),
            "asr.volcengine",
            &[SectionField::str("app_id", "123")],
            WriteLayer::Owning,
        )
        .unwrap();

        let written = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(written.contains("# comment"), "comment lost: {written}");
        assert!(
            written.contains("provider = \"volcengine\""),
            "asr fields lost: {written}"
        );
        assert!(written.contains("[asr.volcengine]"), "got: {written}");
        assert!(written.contains("app_id = \"123\""), "got: {written}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_dotted_local_write_targets_local_whatever_owns_the_sub_section() {
        let dir = scratch("sr-write-dotted-local");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[asr.volcengine]\napp_id = \"123\"\n",
        )
        .unwrap();

        write_section_fields(
            std::slice::from_ref(&dir),
            "asr.volcengine",
            &[SectionField::str("access_key", "volc-secret")],
            WriteLayer::Local,
        )
        .unwrap();

        // The secret created a local [asr.volcengine] without touching
        // the shared one.
        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(!shared.contains("access_key"), "leaked: {shared}");
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(local.contains("[asr.volcengine]"), "got: {local}");
        assert!(
            local.contains("access_key = \"volc-secret\""),
            "got: {local}"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_dotted_reset_strips_the_key_from_every_layers_sub_section() {
        let dir = scratch("sr-write-dotted-reset");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[asr.volcengine]\napp_id = \"123\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[asr.volcengine]\naccess_key = \"old\"\nresource_id = \"r\"\n",
        )
        .unwrap();

        write_section_fields(
            std::slice::from_ref(&dir),
            "asr.volcengine",
            &[SectionField::reset("access_key")],
            WriteLayer::Owning,
        )
        .unwrap();

        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(!local.contains("access_key"), "not removed: {local}");
        assert!(
            local.contains("resource_id = \"r\""),
            "over-removed: {local}"
        );
        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(shared.contains("app_id"), "over-removed: {shared}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_dotted_step_that_exists_as_a_value_is_refused() {
        let dir = scratch("sr-write-dotted-non-table");
        std::fs::write(dir.join(SHARED_FILE), "[asr]\nvolcengine = 3\n").unwrap();

        let err = write_section_fields(
            std::slice::from_ref(&dir),
            "asr.volcengine",
            &[SectionField::str("app_id", "1")],
            WriteLayer::Owning,
        )
        .unwrap_err()
        .0;
        assert!(err.contains("not a table"), "got: {err}");
        assert!(err.contains("asr.volcengine"), "got: {err}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_unsigned_int_field_refuses_what_i64_cannot_hold() {
        assert_eq!(
            SectionField::int_u64("engine", "paragraph_silence_ms", 1200).unwrap(),
            SectionField::int("paragraph_silence_ms", 1200)
        );
        let err = SectionField::int_u64("engine", "paragraph_silence_ms", i64::MAX as u64 + 1)
            .unwrap_err()
            .0;
        assert!(err.contains("[engine]"), "got: {err}");
        assert!(err.contains("paragraph_silence_ms"), "got: {err}");
    }
}
