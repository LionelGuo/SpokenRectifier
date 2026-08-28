//! LLM configuration: defaults from the v1 model matrix, overridable per
//! field from the layered config files (loading rules live in the config
//! crate; an `api_key` may only come from the git-ignored local layer).
//!
//! One model per mode: every intensity (light-touch or full) calls the same
//! endpoint — the length threshold only changes how the prompt asks the
//! model to rectify, never which model answers.

use std::path::PathBuf;

use serde::Deserialize;
use serde_json::Value;
use spokenrectifier_config::load_section_layers;
use spokenrectifier_config::section_write::{KeyEdit, KeyStatus, SectionField, WriteLayer};

use crate::vendor::Vendor;

/// Everything the rectify pipeline needs to call the model.
#[derive(Debug, Clone, PartialEq)]
pub struct LlmConfig {
    /// Thinking mode. Off by default: rewriting tasks lose latency and
    /// risk over-rectifying with it on.
    pub thinking: bool,
    /// Utterances strictly below this many characters take light-touch
    /// rectify; at or above, full rectify. Same model either way.
    pub light_touch_max_chars: usize,
    /// The one model the mode calls, for every intensity.
    pub model: ModelConfig,
    /// Whether any layer file shaped the endpoint (model, base_url, or
    /// api_key): the user configured a real model, so a missing key is an
    /// error for the caller to surface, not a silent fallback to a demo.
    pub endpoint_configured: bool,
}

/// One OpenAI-compatible endpoint.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelConfig {
    /// Everything before `/chat/completions`.
    pub base_url: String,
    pub model: String,
    /// Set from `spokenrectifier.local.toml`; never committed.
    pub api_key: Option<String>,
    /// Environment variable consulted when `api_key` is absent.
    pub api_key_env: Option<String>,
    /// Dialect quirks of the endpoint (thinking-mode field shape).
    pub vendor: Vendor,
    /// Merged verbatim into the request body last — the escape hatch for
    /// anything this config does not model.
    pub extra_body: Option<serde_json::Map<String, Value>>,
}

impl LlmConfig {
    /// The v1 default: DeepSeek V4-Flash, thinking off, 40-character
    /// light-touch threshold.
    pub fn defaults() -> Self {
        LlmConfig {
            thinking: false,
            light_touch_max_chars: 40,
            endpoint_configured: false,
            model: ModelConfig {
                base_url: "https://api.deepseek.com".into(),
                model: "deepseek-v4-flash".into(),
                api_key: None,
                api_key_env: Some("DEEPSEEK_API_KEY".into()),
                vendor: Vendor::DeepSeek,
                extra_body: None,
            },
        }
    }
}

impl ModelConfig {
    /// The key to authenticate with: local-file `api_key` first, then the
    /// configured environment variable.
    pub fn resolve_key(&self) -> Option<String> {
        if let Some(key) = &self.api_key {
            return Some(key.clone());
        }
        let env_name = self.api_key_env.as_deref()?;
        std::env::var(env_name).ok().filter(|k| !k.is_empty())
    }

    /// The key's placement for display (see [`key_status`]).
    pub fn key_status(&self) -> KeyStatus {
        spokenrectifier_config::section_write::key_status(
            self.api_key.as_deref(),
            self.api_key_env.as_deref(),
        )
    }
}

#[derive(Debug, thiserror::Error)]
#[error("LLM config: {0}")]
pub struct ConfigError(pub String);

// -- file layering ----------------------------------------------------------

/// The `[llm]` overlay: the config crate loads it, this crate folds it.
#[derive(Debug, Default, Deserialize)]
struct LlmSection {
    thinking: Option<bool>,
    light_touch_max_chars: Option<usize>,
    base_url: Option<String>,
    model: Option<String>,
    api_key: Option<String>,
    api_key_env: Option<String>,
    vendor: Option<Vendor>,
    extra_body: Option<serde_json::Map<String, Value>>,
}

fn apply(config: &mut LlmConfig, llm: LlmSection) {
    if let Some(v) = llm.thinking {
        config.thinking = v;
    }
    if let Some(v) = llm.light_touch_max_chars {
        config.light_touch_max_chars = v;
    }
    if let Some(v) = llm.base_url {
        config.model.base_url = v;
    }
    if let Some(v) = llm.model {
        config.model.model = v;
    }
    if let Some(v) = llm.api_key {
        config.model.api_key = Some(v);
    }
    if let Some(v) = llm.api_key_env {
        config.model.api_key_env = Some(v);
    }
    if let Some(v) = llm.vendor {
        config.model.vendor = v;
    }
    // Replaced wholesale: a local override redefines the extra body.
    if let Some(v) = llm.extra_body {
        config.model.extra_body = Some(v);
    }
}

/// Load the `[llm]` config from the layer files, wherever they live among
/// `dirs`: defaults, overlaid with `spokenrectifier.toml`, then
/// `spokenrectifier.local.toml` (which wins). Missing files are fine;
/// malformed ones are an error naming the file.
pub fn load_llm_config(dirs: &[PathBuf]) -> Result<LlmConfig, ConfigError> {
    let mut config = LlmConfig::defaults();
    let layers =
        load_section_layers::<LlmSection>(dirs, "llm").map_err(|err| ConfigError(err.0))?;
    for layer in layers {
        // Endpoint fields carry real-model intent (api_key_env alone does
        // not: it only names where a key would come from, which the
        // built-in defaults do too).
        if layer.value.model.is_some()
            || layer.value.base_url.is_some()
            || layer
                .value
                .api_key
                .as_deref()
                .is_some_and(|k| !k.is_empty())
        {
            config.endpoint_configured = true;
        }
        apply(&mut config, layer.value);
    }
    // An explicitly emptied endpoint is a config mistake, not a setting:
    // the defaults are never empty, so only a layer can do this.
    if config.model.model.trim().is_empty() {
        return Err(ConfigError(
            "[llm] model is empty: remove the field or name a real model".into(),
        ));
    }
    if config.model.base_url.trim().is_empty() {
        return Err(ConfigError(
            "[llm] base_url is empty: remove the field or name a real endpoint".into(),
        ));
    }
    Ok(config)
}

// -- the settings editor's write path (ticket 19) ----------------------------

/// What the connection editor writes back: the GUI-managed subset of
/// `[llm]`. Values are the editor's whole model — saving writes exactly
/// these, so the next load returns what the user saw.
#[derive(Debug, Clone, PartialEq)]
pub struct LlmConnectionEdit {
    pub vendor: Vendor,
    pub base_url: String,
    pub model: String,
    pub api_key: KeyEdit,
}

/// Write the connection editor's model back into the layer files. The
/// endpoint fields land in the layer that owns `[llm]` (section-
/// preserving); the api_key lands in the local file only — never the
/// committable shared file, whose loader rejects a key outright (the
/// layering ironclad, ADR-0008).
pub fn save_llm_connection(dirs: &[PathBuf], edit: &LlmConnectionEdit) -> Result<(), ConfigError> {
    let base_url = edit.base_url.trim();
    let model = edit.model.trim();
    if model.is_empty() {
        return Err(ConfigError(
            "[llm] model is empty: name a real model".into(),
        ));
    }
    if base_url.is_empty() {
        return Err(ConfigError(
            "[llm] base_url is empty: name a real endpoint".into(),
        ));
    }
    let fields = vec![
        SectionField::str("vendor", edit.vendor.as_str()),
        SectionField::str("base_url", base_url),
        SectionField::str("model", model),
    ];
    spokenrectifier_config::section_write::write_section_fields(
        dirs,
        "llm",
        &fields,
        WriteLayer::Owning,
    )
    .map_err(|err| ConfigError(err.0))?;
    edit.api_key
        .clone()
        .write_to_local(dirs, "llm")
        .map_err(|err| ConfigError(err.0))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_single_model_deepseek() {
        let config = LlmConfig::defaults();
        assert!(!config.thinking);
        assert_eq!(config.light_touch_max_chars, 40);
        assert_eq!(config.model.model, "deepseek-v4-flash");
        assert_eq!(config.model.vendor, Vendor::DeepSeek);
        assert_eq!(
            config.model.api_key_env.as_deref(),
            Some("DEEPSEEK_API_KEY")
        );
    }

    #[test]
    fn file_layers_override_field_by_field_and_local_wins() {
        let dir = std::env::temp_dir().join("sr-llm-config-test-layers");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[llm]\nthinking = true\nmodel = \"deepseek-v4-pro\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[llm]\napi_key = \"sk-local\"\n",
        )
        .unwrap();

        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert!(config.thinking); // from the shared file
        assert_eq!(config.model.model, "deepseek-v4-pro"); // shared file
        assert_eq!(config.model.api_key.as_deref(), Some("sk-local")); // local wins
        assert_eq!(config.model.base_url, "https://api.deepseek.com"); // untouched default
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn key_resolution_prefers_file_then_env() {
        let mut model = LlmConfig::defaults().model;
        model.api_key = Some("sk-file".into());
        assert_eq!(model.resolve_key().as_deref(), Some("sk-file"));

        // Env fallback uses the configured variable name.
        let mut env_model = LlmConfig::defaults().model;
        env_model.api_key = None;
        // SAFETY: single test, unique variable, no parallel reader.
        unsafe { std::env::set_var("SR_TEST_DEEPSEEK_KEY", "sk-env") };
        env_model.api_key_env = Some("SR_TEST_DEEPSEEK_KEY".into());
        assert_eq!(env_model.resolve_key().as_deref(), Some("sk-env"));
    }

    /// Defaults alone are not endpoint intent: with no layer touching the
    /// endpoint fields, the app stays free to run its pure demo mode.
    #[test]
    fn untouched_defaults_are_not_endpoint_intent() {
        let dir = std::env::temp_dir().join("sr-llm-config-test-no-intent");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[llm]\nthinking = true\nlight_touch_max_chars = 60\n",
        )
        .unwrap();

        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert!(!config.endpoint_configured); // prompt knobs only
        assert!(config.thinking);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn endpoint_fields_touched_mark_intent() {
        for section in [
            "[llm]\nmodel = \"other-model\"\n",
            "[llm]\nbase_url = \"https://example.com\"\n",
            "[llm]\napi_key = \"sk-x\"\n",
        ] {
            let dir = std::env::temp_dir().join("sr-llm-config-test-intent");
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("spokenrectifier.local.toml"), section).unwrap();
            assert!(
                load_llm_config(std::slice::from_ref(&dir))
                    .unwrap()
                    .endpoint_configured,
                "not intent: {section}"
            );
            std::fs::remove_dir_all(&dir).unwrap();
        }
    }

    #[test]
    fn an_empty_model_string_is_rejected() {
        let dir = std::env::temp_dir().join("sr-llm-config-test-empty-model");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("spokenrectifier.toml"), "[llm]\nmodel = \"\"\n").unwrap();

        let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
        assert!(err.contains("model"), "got: {err}");
        assert!(!err.contains('\n'), "multi-line error: {err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_empty_base_url_string_is_rejected() {
        let dir = std::env::temp_dir().join("sr-llm-config-test-empty-url");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("spokenrectifier.toml"), "[llm]\nbase_url = \"\"\n").unwrap();

        let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
        assert!(err.contains("base_url"), "got: {err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
    // -- the settings editor's write path (ticket 19) -----------------------

    use spokenrectifier_config::section_write::KeyEdit;
    use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

    fn edit(api_key: KeyEdit) -> LlmConnectionEdit {
        LlmConnectionEdit {
            vendor: Vendor::Volcengine,
            base_url: "https://ark.cn-beijing.volces.com/api/v3".into(),
            model: "doubao-seed-2.0-lite".into(),
            api_key,
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_save_without_any_layer_creates_both_files_and_round_trips() {
        let dir = scratch("sr-llm-save-fresh");
        let dirs = std::slice::from_ref(&dir);

        save_llm_connection(dirs, &edit(KeyEdit::Set("sk-new".into()))).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(shared.contains("vendor = \"volcengine\""), "got: {shared}");
        assert!(shared.contains("doubao-seed-2.0-lite"));
        assert!(
            !shared.contains("api_key"),
            "key leaked into shared: {shared}"
        );
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(local.contains("api_key = \"sk-new\""), "got: {local}");
        // The load returns exactly the editor's model (endpoint intent
        // included), and passes the shared-file guard.
        let config = load_llm_config(dirs).unwrap();
        assert_eq!(config.model.model, "doubao-seed-2.0-lite");
        assert_eq!(config.model.vendor, Vendor::Volcengine);
        assert_eq!(
            config.model.base_url,
            "https://ark.cn-beijing.volces.com/api/v3"
        );
        assert!(config.endpoint_configured);
        assert_eq!(config.model.resolve_key().as_deref(), Some("sk-new"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The ironclad: a GUI save never puts a key in the committable
    /// shared file — whatever layer owns the section.
    #[test]
    fn a_saved_key_never_lands_in_the_shared_file() {
        let dir = scratch("sr-llm-save-ironclad");
        let dirs = std::slice::from_ref(&dir);
        std::fs::write(
            dir.join(SHARED_FILE),
            "# committable\n[llm]\nmodel = \"deepseek-v4-flash\"\nthinking = false\n",
        )
        .unwrap();

        save_llm_connection(dirs, &edit(KeyEdit::Set("sk-secret".into()))).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(shared.contains("# committable"), "comment lost: {shared}");
        assert!(
            shared.contains("thinking = false"),
            "sibling field lost: {shared}"
        );
        assert!(
            !shared.contains("api_key"),
            "key leaked into shared: {shared}"
        );
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(local.contains("api_key = \"sk-secret\""), "got: {local}");
        assert!(load_llm_config(dirs).is_ok());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_endpoint_edit_lands_in_the_owning_local_layer() {
        let dir = scratch("sr-llm-save-owning");
        let dirs = std::slice::from_ref(&dir);
        // Local owns [llm] (it holds the key); an endpoint edit must land
        // beside it, or the shared file's values would keep winning.
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nmodel = \"deepseek-v4-flash\"\n",
        )
        .unwrap();
        std::fs::write(dir.join(LOCAL_FILE), "[llm]\napi_key = \"sk-old\"\n").unwrap();

        save_llm_connection(dirs, &edit(KeyEdit::Keep)).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(
            shared.contains("deepseek-v4-flash"),
            "shared file was touched: {shared}"
        );
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("doubao-seed-2.0-lite"),
            "local not updated: {local}"
        );
        assert!(
            local.contains("api_key = \"sk-old\""),
            "keep touched the key: {local}"
        );
        assert_eq!(
            load_llm_config(dirs).unwrap().model.model,
            "doubao-seed-2.0-lite"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_key_clear_removes_it_from_local_only() {
        let dir = scratch("sr-llm-save-clear");
        let dirs = std::slice::from_ref(&dir);
        std::fs::write(dir.join(LOCAL_FILE), "[llm]\napi_key = \"sk-old\"\n").unwrap();

        save_llm_connection(dirs, &edit(KeyEdit::Clear)).unwrap();

        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(!local.contains("api_key"), "not cleared: {local}");
        assert!(
            local.contains("model = \"doubao-seed-2.0-lite\""),
            "endpoint fields lost: {local}"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_empty_endpoint_field_is_refused_and_writes_nothing() {
        let dir = scratch("sr-llm-save-empty");
        let dirs = std::slice::from_ref(&dir);
        let mut model = edit(KeyEdit::Set("sk".into()));
        model.base_url = "   ".into();

        let err = save_llm_connection(dirs, &model).unwrap_err().0;
        assert!(err.contains("base_url"), "got: {err}");
        assert!(!dir.join(SHARED_FILE).exists(), "wrote on a refused save");
        assert!(!dir.join(LOCAL_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
