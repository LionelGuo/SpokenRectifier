//! `[asr]` configuration: the Aliyun realtime endpoint, model, and key.
//!
//! Layered like every section: defaults, then `spokenrectifier.toml`,
//! then `spokenrectifier.local.toml` (git-ignored; the only place an
//! `api_key` may live) — the loading rules live in the config crate; this
//! module owns the `[asr]` shape. The default endpoint is the legacy
//! shared domain (`wss://dashscope.aliyuncs.com`), which accepts a key
//! from any workspace in the region; a `workspace_id` switches to the
//! workspace-scoped host, and `base_url` overrides the whole host part.

use std::path::PathBuf;

use serde::Deserialize;
use spokenrectifier_config::load_section_layers;
use spokenrectifier_config::section_write::{KeyEdit, KeyStatus, SectionField, WriteLayer};

/// Everything the adapter needs to reach the model.
#[derive(Clone, PartialEq)]
pub struct AsrConfig {
    /// Model name, also the `?model=` query parameter.
    pub model: String,
    /// Set from `spokenrectifier.local.toml`; never committed.
    pub api_key: Option<String>,
    /// Environment variable consulted when `api_key` is absent.
    pub api_key_env: Option<String>,
    /// Bailian workspace id — required for the default endpoint host.
    pub workspace_id: Option<String>,
    /// Host region for the default endpoint.
    pub region: String,
    /// Full host override (everything before `/api-ws/v1/realtime`);
    /// wins over `workspace_id`/`region`.
    pub base_url: Option<String>,
    /// `session.update` transcription language; `zh` covers the
    /// mixed-Chinese-English code-switching v1 targets.
    pub language: String,
}

/// Manual impl: the key never reaches logs or panic messages.
impl std::fmt::Debug for AsrConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AsrConfig")
            .field("model", &self.model)
            .field("api_key", &self.api_key.as_ref().map(|_| "<redacted>"))
            .field("api_key_env", &self.api_key_env)
            .field("workspace_id", &self.workspace_id)
            .field("region", &self.region)
            .field("base_url", &self.base_url)
            .field("language", &self.language)
            .finish()
    }
}

impl AsrConfig {
    /// The v1 default: qwen3-asr-flash-realtime on the Beijing realtime
    /// host, key from the environment.
    pub fn defaults() -> Self {
        AsrConfig {
            model: "qwen3-asr-flash-realtime".into(),
            api_key: None,
            api_key_env: Some("DASHSCOPE_API_KEY".into()),
            workspace_id: None,
            region: "cn-beijing".into(),
            base_url: None,
            language: "zh".into(),
        }
    }

    /// The key to authenticate with: local-file `api_key` first, then the
    /// configured environment variable.
    pub fn resolve_key(&self) -> Option<String> {
        if let Some(key) = &self.api_key {
            return Some(key.clone());
        }
        let env_name = self.api_key_env.as_deref()?;
        std::env::var(env_name).ok().filter(|k| !k.is_empty())
    }

    /// The WebSocket endpoint URL. An explicit `base_url` wins; a
    /// `workspace_id` builds the workspace-scoped host; otherwise the
    /// legacy shared domain — it accepts a key from any workspace in the
    /// region, so key alone is enough to run.
    pub fn endpoint(&self) -> String {
        let host = match (&self.base_url, &self.workspace_id) {
            (Some(base), _) => base.trim_end_matches('/').to_string(),
            (None, Some(workspace)) if !workspace.is_empty() => {
                format!("wss://{workspace}.{}.maas.aliyuncs.com", self.region)
            }
            _ => "wss://dashscope.aliyuncs.com".to_string(),
        };
        format!("{host}/api-ws/v1/realtime?model={}", self.model)
    }
}

#[derive(Debug, thiserror::Error)]
#[error("ASR config: {0}")]
pub struct AsrConfigError(pub String);

// -- file layering ----------------------------------------------------------

/// The `[asr]` overlay: the config crate loads it, this crate folds it.
#[derive(Debug, Default, Deserialize)]
struct AsrSection {
    model: Option<String>,
    api_key: Option<String>,
    api_key_env: Option<String>,
    workspace_id: Option<String>,
    region: Option<String>,
    base_url: Option<String>,
    language: Option<String>,
}

fn apply(config: &mut AsrConfig, asr: AsrSection) {
    if let Some(v) = asr.model {
        config.model = v;
    }
    if let Some(v) = asr.api_key {
        config.api_key = Some(v);
    }
    if let Some(v) = asr.api_key_env {
        config.api_key_env = Some(v);
    }
    if let Some(v) = asr.workspace_id {
        config.workspace_id = Some(v);
    }
    if let Some(v) = asr.region {
        config.region = v;
    }
    if let Some(v) = asr.base_url {
        config.base_url = Some(v);
    }
    if let Some(v) = asr.language {
        config.language = v;
    }
}

/// Load the `[asr]` config from the layer files, wherever they live among
/// `dirs`: defaults, overlaid with `spokenrectifier.toml`, then
/// `spokenrectifier.local.toml` (which wins, and is the only layer an
/// `api_key` may come from). Missing files are fine; malformed ones are
/// an error naming the file.
pub fn load_asr_config(dirs: &[PathBuf]) -> Result<AsrConfig, AsrConfigError> {
    let mut config = AsrConfig::defaults();
    let layers =
        load_section_layers::<AsrSection>(dirs, "asr").map_err(|err| AsrConfigError(err.0))?;
    for layer in layers {
        apply(&mut config, layer.value);
    }
    Ok(config)
}

// -- the settings editor's write path (ticket 19) ----------------------------

/// What the connection editor writes back: the GUI-managed subset of
/// `[asr]`. Values are the editor's whole model — saving writes exactly
/// these, so the next load returns what the user saw. `None` on an
/// optional endpoint field resets it (the key is removed from every
/// layer, back to the built-in default).
#[derive(Debug, Clone, PartialEq)]
pub struct AsrConnectionEdit {
    pub model: String,
    pub language: String,
    pub region: String,
    /// A Bailian workspace id; `None` = the shared DashScope domain.
    pub workspace_id: Option<String>,
    /// A full host override; `None` = derive from workspace/region.
    pub base_url: Option<String>,
    pub api_key: KeyEdit,
}

impl AsrConfig {
    /// The key's placement for display: the local file first, then the
    /// configured environment variable, else nothing.
    pub fn key_status(&self) -> KeyStatus {
        if self.api_key.is_some() {
            return KeyStatus::InLocalFile;
        }
        match &self.api_key_env {
            Some(name) => {
                let from_env = std::env::var(name).is_ok_and(|key| !key.is_empty());
                if from_env {
                    KeyStatus::FromEnv(name.clone())
                } else {
                    KeyStatus::Unset
                }
            }
            None => KeyStatus::Unset,
        }
    }
}

/// Write the connection editor's model back into the layer files. The
/// non-secret fields land in the layer that owns `[asr]` (section-
/// preserving); the api_key lands in the local file only — never the
/// committable shared file, whose loader rejects a key outright (the
/// layering ironclad, ADR-0008).
pub fn save_asr_connection(
    dirs: &[PathBuf],
    edit: &AsrConnectionEdit,
) -> Result<(), AsrConfigError> {
    let model = non_empty(&edit.model, "model")?;
    let language = non_empty(&edit.language, "language")?;
    let region = non_empty(&edit.region, "region")?;
    let optional = |value: &Option<String>| {
        // An all-whitespace optional field is an absent one: reset.
        value
            .as_deref()
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
    };
    let workspace_id = optional(&edit.workspace_id);
    let base_url = optional(&edit.base_url);

    let endpoint_fields = vec![
        SectionField::str("model", model),
        SectionField::str("language", language),
        SectionField::str("region", region),
        match workspace_id {
            Some(id) => SectionField::str("workspace_id", id),
            None => SectionField::reset("workspace_id"),
        },
        match base_url {
            Some(url) => SectionField::str("base_url", url),
            None => SectionField::reset("base_url"),
        },
    ];
    spokenrectifier_config::section_write::write_section_fields(
        dirs,
        "asr",
        &endpoint_fields,
        WriteLayer::Owning,
    )
    .map_err(|err| AsrConfigError(err.0))?;
    edit.api_key
        .clone()
        .write_to_local(dirs, "asr")
        .map_err(|err| AsrConfigError(err.0))?;
    Ok(())
}

/// One required string: trimmed, and an error naming the field when the
/// editor's model carries nothing usable.
fn non_empty(value: &str, field: &str) -> Result<String, AsrConfigError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Err(AsrConfigError(format!(
            "[asr] {field} is empty: name a real value or reset the optional fields"
        )))
    } else {
        Ok(trimmed.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_target_qwen3_realtime_with_env_key() {
        let config = AsrConfig::defaults();
        assert_eq!(config.model, "qwen3-asr-flash-realtime");
        assert_eq!(config.api_key_env.as_deref(), Some("DASHSCOPE_API_KEY"));
        assert_eq!(config.language, "zh");
    }

    #[test]
    fn endpoint_defaults_to_the_shared_domain_and_overrides_win() {
        // Key alone is enough: the legacy shared domain accepts a key from
        // any workspace in the region.
        let config = AsrConfig::defaults();
        assert_eq!(
            config.endpoint(),
            "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
        );

        // A workspace id switches to the workspace-scoped host.
        let mut scoped = AsrConfig::defaults();
        scoped.workspace_id = Some("llm-abc123".into());
        assert_eq!(
            scoped.endpoint(),
            "wss://llm-abc123.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
        );

        // An explicit base_url outranks the workspace form.
        scoped.base_url = Some("wss://custom.example.com/".into());
        assert_eq!(
            scoped.endpoint(),
            "wss://custom.example.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
        );
    }

    #[test]
    fn file_layers_override_field_by_field_and_local_wins() {
        let dir = std::env::temp_dir().join("sr-asr-config-test-layers");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[asr]\nworkspace_id = \"llm-shared\"\nlanguage = \"en\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[asr]\napi_key = \"sk-local\"\nregion = \"ap-southeast-1\"\n",
        )
        .unwrap();

        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.workspace_id.as_deref(), Some("llm-shared"));
        assert_eq!(config.language, "en");
        assert_eq!(config.api_key.as_deref(), Some("sk-local"));
        assert_eq!(config.region, "ap-southeast-1");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn key_resolution_prefers_file_then_env() {
        let mut config = AsrConfig::defaults();
        config.api_key = Some("sk-file".into());
        assert_eq!(config.resolve_key().as_deref(), Some("sk-file"));

        let mut env_config = AsrConfig::defaults();
        // SAFETY: single test, unique variable, no parallel reader.
        unsafe { std::env::set_var("SR_TEST_DASHSCOPE_KEY", "sk-env") };
        env_config.api_key_env = Some("SR_TEST_DASHSCOPE_KEY".into());
        assert_eq!(env_config.resolve_key().as_deref(), Some("sk-env"));
    }

    // -- the settings editor's write path (ticket 19) -----------------------

    use spokenrectifier_config::section_write::KeyStatus;
    use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

    fn edit(api_key: KeyEdit) -> AsrConnectionEdit {
        AsrConnectionEdit {
            model: "qwen3-asr-flash-realtime".into(),
            language: "zh".into(),
            region: "cn-beijing".into(),
            workspace_id: None,
            base_url: None,
            api_key,
        }
    }

    #[test]
    fn a_save_without_any_layer_creates_both_files_in_the_home() {
        let dir = std::env::temp_dir().join("sr-asr-save-fresh");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        save_asr_connection(
            std::slice::from_ref(&dir),
            &edit(KeyEdit::Set("sk-new".into())),
        )
        .unwrap();

        // The non-secrets created the shared file; the key created the
        // local one — and the load passes the shared-file guard.
        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(
            shared.contains("model = \"qwen3-asr-flash-realtime\""),
            "got: {shared}"
        );
        assert!(
            !shared.contains("api_key"),
            "key leaked into shared: {shared}"
        );
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(local.contains("api_key = \"sk-new\""), "got: {local}");
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.api_key.as_deref(), Some("sk-new"));
        assert_eq!(config.key_status(), KeyStatus::InLocalFile);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The ironclad: a GUI save may never leave a key in the committable
    /// shared file — and whatever it writes must still load (the loader's
    /// guard would reject the file outright).
    #[test]
    fn a_saved_key_never_lands_in_the_shared_file_however_layers_sit() {
        let dir = std::env::temp_dir().join("sr-asr-save-ironclad");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // Shared owns [asr] (the local file does not exist): the owning
        // write targets shared, the key write must not follow it there.
        std::fs::write(
            dir.join(SHARED_FILE),
            "# committable\n[asr]\nmodel = \"qwen3-asr-flash-realtime\"\n",
        )
        .unwrap();

        save_asr_connection(
            std::slice::from_ref(&dir),
            &edit(KeyEdit::Set("sk-secret".into())),
        )
        .unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(shared.contains("# committable"), "comment lost: {shared}");
        assert!(
            !shared.contains("api_key"),
            "key leaked into shared: {shared}"
        );
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(local.contains("api_key = \"sk-secret\""), "got: {local}");
        // The load passes the guard and resolves the key from local.
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.resolve_key().as_deref(), Some("sk-secret"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn endpoint_edits_land_in_the_owning_local_layer_and_round_trip() {
        let dir = std::env::temp_dir().join("sr-asr-save-owning");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join(SHARED_FILE),
            "[asr]\nworkspace_id = \"llm-shared\"\nregion = \"cn-beijing\"\n",
        )
        .unwrap();
        std::fs::write(dir.join(LOCAL_FILE), "[asr]\napi_key = \"sk-old\"\n").unwrap();

        let mut model = edit(KeyEdit::Keep);
        model.workspace_id = None; // cleared: back to the shared domain
        save_asr_connection(std::slice::from_ref(&dir), &model).unwrap();

        // The owning local layer got the endpoint fields; the reset
        // removed the workspace id from EVERY layer (a surviving shared
        // copy would resurrect); the key stayed put (Keep).
        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(!shared.contains("workspace_id"), "not reset: {shared}");
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("api_key = \"sk-old\""),
            "keep touched the key: {local}"
        );
        assert!(
            local.contains("model = \"qwen3-asr-flash-realtime\""),
            "got: {local}"
        );
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.workspace_id, None);
        assert_eq!(config.api_key.as_deref(), Some("sk-old"));
        assert_eq!(
            config.endpoint(),
            "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_key_clear_removes_it_from_local_and_falls_back_to_env() {
        let dir = std::env::temp_dir().join("sr-asr-save-clear");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(LOCAL_FILE), "[asr]\napi_key = \"sk-old\"\n").unwrap();

        save_asr_connection(std::slice::from_ref(&dir), &edit(KeyEdit::Clear)).unwrap();

        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(!local.contains("api_key"), "not cleared: {local}");
        // No key anywhere now (the default env var is unset in tests):
        // the status reads unset, the load still passes.
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.key_status(), KeyStatus::Unset);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_keep_write_touches_no_local_file_at_all() {
        let dir = std::env::temp_dir().join("sr-asr-save-keep");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        save_asr_connection(std::slice::from_ref(&dir), &edit(KeyEdit::Keep)).unwrap();

        // Only the shared file exists: a keep must not create an empty
        // local file beside it.
        assert!(dir.join(SHARED_FILE).is_file());
        assert!(!dir.join(LOCAL_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_empty_required_field_is_refused_and_writes_nothing() {
        let dir = std::env::temp_dir().join("sr-asr-save-empty");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let mut model = edit(KeyEdit::Set("sk".into()));
        model.model = "  ".into();
        let err = save_asr_connection(std::slice::from_ref(&dir), &model)
            .unwrap_err()
            .0;
        assert!(err.contains("model"), "got: {err}");
        assert!(!dir.join(SHARED_FILE).exists(), "wrote on a refused save");
        assert!(!dir.join(LOCAL_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
