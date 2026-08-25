//! LLM tier configuration: defaults from the v1 model matrix, overridable
//! per field from `spokenrectifier.toml`, then `spokenrectifier.local.toml`
//! (git-ignored; the only place an `api_key` may live).

use std::fs;
use std::path::Path;

use serde::Deserialize;
use serde_json::Value;

use crate::vendor::Vendor;

/// Everything the rectify pipeline needs to pick and call models.
#[derive(Debug, Clone, PartialEq)]
pub struct LlmConfig {
    /// Thinking mode for both tiers. Off by default: rewriting tasks lose
    /// latency and risk over-rectifying with it on.
    pub thinking: bool,
    /// Utterances strictly below this many characters take light-touch
    /// rectify on the fast tier.
    pub light_touch_max_chars: usize,
    /// The standard tier: full rectify, medium and long utterances.
    pub standard: ModelConfig,
    /// The fast tier: light-touch rectify, short utterances.
    pub fast: ModelConfig,
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
    /// The v1 defaults: DeepSeek V4-Flash standard, doubao-seed-2.0-lite
    /// fast, thinking off, 40-character light-touch threshold.
    pub fn defaults() -> Self {
        LlmConfig {
            thinking: false,
            light_touch_max_chars: 40,
            standard: ModelConfig {
                base_url: "https://api.deepseek.com".into(),
                model: "deepseek-v4-flash".into(),
                api_key: None,
                api_key_env: Some("DEEPSEEK_API_KEY".into()),
                vendor: Vendor::DeepSeek,
                extra_body: None,
            },
            fast: ModelConfig {
                base_url: "https://ark.cn-beijing.volces.com/api/v3".into(),
                model: "doubao-seed-2.0-lite".into(),
                api_key: None,
                api_key_env: Some("ARK_API_KEY".into()),
                vendor: Vendor::Volcengine,
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
}

#[derive(Debug, thiserror::Error)]
#[error("LLM config: {0}")]
pub struct ConfigError(pub String);

// -- file layering ----------------------------------------------------------

#[derive(Debug, Default, Deserialize)]
struct FileConfig {
    llm: Option<LlmSection>,
}

#[derive(Debug, Default, Deserialize)]
struct LlmSection {
    thinking: Option<bool>,
    light_touch_max_chars: Option<usize>,
    standard: Option<ModelSection>,
    fast: Option<ModelSection>,
}

#[derive(Debug, Default, Deserialize)]
struct ModelSection {
    base_url: Option<String>,
    model: Option<String>,
    api_key: Option<String>,
    api_key_env: Option<String>,
    vendor: Option<Vendor>,
    extra_body: Option<serde_json::Map<String, Value>>,
}

fn apply_model(model: &mut ModelConfig, section: ModelSection) {
    if let Some(v) = section.base_url {
        model.base_url = v;
    }
    if let Some(v) = section.model {
        model.model = v;
    }
    if let Some(v) = section.api_key {
        model.api_key = Some(v);
    }
    if let Some(v) = section.api_key_env {
        model.api_key_env = Some(v);
    }
    if let Some(v) = section.vendor {
        model.vendor = v;
    }
    // Replaced wholesale: a local override redefines the extra body.
    if let Some(v) = section.extra_body {
        model.extra_body = Some(v);
    }
}

fn apply(config: &mut LlmConfig, file: FileConfig) {
    let Some(llm) = file.llm else { return };
    if let Some(v) = llm.thinking {
        config.thinking = v;
    }
    if let Some(v) = llm.light_touch_max_chars {
        config.light_touch_max_chars = v;
    }
    if let Some(section) = llm.standard {
        apply_model(&mut config.standard, section);
    }
    if let Some(section) = llm.fast {
        apply_model(&mut config.fast, section);
    }
}

fn read_layer(config: &mut LlmConfig, path: &Path) -> Result<(), ConfigError> {
    let Ok(text) = fs::read_to_string(path) else {
        return Ok(()); // optional file
    };
    let parsed: FileConfig =
        toml::from_str(&text).map_err(|err| ConfigError(format!("{}: {err}", path.display())))?;
    apply(config, parsed);
    Ok(())
}

/// Load the `[llm]` config from a directory: defaults, overlaid with
/// `spokenrectifier.toml`, then `spokenrectifier.local.toml` (which wins).
/// Missing files are fine; malformed ones are an error naming the file.
pub fn load_llm_config(dir: &Path) -> Result<LlmConfig, ConfigError> {
    let mut config = LlmConfig::defaults();
    read_layer(&mut config, &dir.join("spokenrectifier.toml"))?;
    read_layer(&mut config, &dir.join("spokenrectifier.local.toml"))?;
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_the_v1_model_matrix() {
        let config = LlmConfig::defaults();
        assert!(!config.thinking);
        assert_eq!(config.light_touch_max_chars, 40);
        assert_eq!(config.standard.model, "deepseek-v4-flash");
        assert_eq!(config.standard.vendor, Vendor::DeepSeek);
        assert_eq!(config.fast.model, "doubao-seed-2.0-lite");
        assert_eq!(config.fast.vendor, Vendor::Volcengine);
    }

    #[test]
    fn file_layers_override_field_by_field_and_local_wins() {
        let dir = std::env::temp_dir().join("sr-llm-config-test-layers");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[llm]\nthinking = true\n\n[llm.standard]\nmodel = \"deepseek-v4-pro\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[llm.standard]\napi_key = \"sk-local\"\n",
        )
        .unwrap();

        let config = load_llm_config(&dir).unwrap();
        assert!(config.thinking); // from the shared file
        assert_eq!(config.standard.model, "deepseek-v4-pro"); // shared file
        assert_eq!(config.standard.api_key.as_deref(), Some("sk-local")); // local wins
        assert_eq!(config.fast.model, "doubao-seed-2.0-lite"); // untouched tier
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn missing_files_leave_defaults() {
        let config = load_llm_config(Path::new("/nonexistent")).unwrap();
        assert_eq!(config, LlmConfig::defaults());
    }

    #[test]
    fn malformed_file_names_the_path() {
        let dir = std::env::temp_dir().join("sr-llm-config-test-bad");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("spokenrectifier.toml"), "[llm\nbroken").unwrap();
        let err = load_llm_config(&dir).unwrap_err().0;
        assert!(err.contains("spokenrectifier.toml"), "got: {err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn key_resolution_prefers_file_then_env() {
        let mut model = LlmConfig::defaults().standard;
        model.api_key = Some("sk-file".into());
        assert_eq!(model.resolve_key().as_deref(), Some("sk-file"));

        // Env fallback uses the configured variable name.
        let mut env_model = LlmConfig::defaults().fast;
        env_model.api_key = None;
        // SAFETY: single test, unique variable, no parallel reader.
        unsafe { std::env::set_var("SR_TEST_ARK_KEY", "sk-env") };
        env_model.api_key_env = Some("SR_TEST_ARK_KEY".into());
        assert_eq!(env_model.resolve_key().as_deref(), Some("sk-env"));
    }
}
