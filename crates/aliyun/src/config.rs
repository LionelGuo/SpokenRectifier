//! `[asr]` configuration: the Aliyun realtime endpoint, model, and key.
//!
//! Layered like `[llm]`: defaults, then `spokenrectifier.toml`, then
//! `spokenrectifier.local.toml` (git-ignored; the only place an `api_key`
//! may live). The default endpoint is the workspace-scoped realtime host
//! (`wss://{workspace_id}.{region}.maas.aliyuncs.com`); `base_url`
//! overrides the whole host part.

use std::fs;
use std::path::Path;

use serde::Deserialize;

/// Everything the adapter needs to reach the model.
#[derive(Debug, Clone, PartialEq)]
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

    /// The WebSocket endpoint URL. An explicit `base_url` wins; otherwise
    /// the workspace-scoped realtime host is built (and a missing
    /// `workspace_id` is an error naming the fix).
    pub fn endpoint(&self) -> Result<String, AsrConfigError> {
        let host = match &self.base_url {
            Some(base) => base.trim_end_matches('/').to_string(),
            None => {
                let workspace = self
                    .workspace_id
                    .as_deref()
                    .filter(|w| !w.is_empty())
                    .ok_or(AsrConfigError(
                        "asr endpoint needs a workspace_id (or a base_url override) in the config"
                            .into(),
                    ))?;
                format!("wss://{workspace}.{}.maas.aliyuncs.com", self.region)
            }
        };
        Ok(format!("{host}/api-ws/v1/realtime?model={}", self.model))
    }
}

#[derive(Debug, thiserror::Error)]
#[error("ASR config: {0}")]
pub struct AsrConfigError(pub String);

// -- file layering ----------------------------------------------------------

#[derive(Debug, Default, Deserialize)]
struct FileConfig {
    asr: Option<AsrSection>,
}

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

fn apply(config: &mut AsrConfig, file: FileConfig) {
    let Some(asr) = file.asr else { return };
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

fn read_layer(config: &mut AsrConfig, path: &Path) -> Result<(), AsrConfigError> {
    let Ok(text) = fs::read_to_string(path) else {
        return Ok(()); // optional file
    };
    let parsed: FileConfig = toml::from_str(&text)
        .map_err(|err| AsrConfigError(format!("{}: {err}", path.display())))?;
    apply(config, parsed);
    Ok(())
}

/// Load the `[asr]` config from a directory: defaults, overlaid with
/// `spokenrectifier.toml`, then `spokenrectifier.local.toml` (which wins).
/// Missing files are fine; malformed ones are an error naming the file.
pub fn load_asr_config(dir: &Path) -> Result<AsrConfig, AsrConfigError> {
    let mut config = AsrConfig::defaults();
    read_layer(&mut config, &dir.join("spokenrectifier.toml"))?;
    read_layer(&mut config, &dir.join("spokenrectifier.local.toml"))?;
    Ok(config)
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
    fn endpoint_builds_the_workspace_host_and_base_url_wins() {
        let mut config = AsrConfig::defaults();
        config.workspace_id = Some("llm-abc123".into());
        assert_eq!(
            config.endpoint().unwrap(),
            "wss://llm-abc123.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
        );

        config.base_url = Some("wss://custom.example.com/".into());
        assert_eq!(
            config.endpoint().unwrap(),
            "wss://custom.example.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
        );
    }

    #[test]
    fn endpoint_without_workspace_or_base_url_is_a_named_error() {
        let err = AsrConfig::defaults().endpoint().unwrap_err().0;
        assert!(err.contains("workspace_id"), "got: {err}");
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

        let config = load_asr_config(&dir).unwrap();
        assert_eq!(config.workspace_id.as_deref(), Some("llm-shared"));
        assert_eq!(config.language, "en");
        assert_eq!(config.api_key.as_deref(), Some("sk-local"));
        assert_eq!(config.region, "ap-southeast-1");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn missing_files_leave_defaults_and_malformed_names_the_path() {
        assert_eq!(
            load_asr_config(Path::new("/nonexistent")).unwrap(),
            AsrConfig::defaults()
        );

        let dir = std::env::temp_dir().join("sr-asr-config-test-bad");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("spokenrectifier.toml"), "[asr\nbroken").unwrap();
        let err = load_asr_config(&dir).unwrap_err().0;
        assert!(err.contains("spokenrectifier.toml"), "got: {err}");
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
}
