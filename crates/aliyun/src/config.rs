//! `[asr]` configuration: the Aliyun realtime endpoint, model, and key.
//!
//! Layered like `[llm]`: defaults, then `spokenrectifier.toml`, then
//! `spokenrectifier.local.toml` (git-ignored; the only place an `api_key`
//! may live). The default endpoint is the legacy shared domain
//! (`wss://dashscope.aliyuncs.com`), which accepts a key from any
//! workspace in the region; a `workspace_id` switches to the
//! workspace-scoped host, and `base_url` overrides the whole host part.

use std::fs;
use std::path::Path;

use serde::Deserialize;

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

fn read_layer(
    config: &mut AsrConfig,
    path: &Path,
    secrets_allowed: bool,
) -> Result<(), AsrConfigError> {
    let Ok(text) = fs::read_to_string(path) else {
        return Ok(()); // optional file
    };
    let parsed: FileConfig = match toml::from_str(&text) {
        Ok(parsed) => parsed,
        Err(err) => {
            // Not the crate's formatted message: it quotes the offending
            // line, which may carry a key.
            let (line, column) = match err.span() {
                Some(range) => {
                    let before = &text[..range.start];
                    let line = before.matches('\n').count() + 1;
                    let column = range.start - before.rfind('\n').map_or(0, |i| i + 1) + 1;
                    (line, column)
                }
                None => (0, 0),
            };
            return Err(AsrConfigError(format!(
                "{}: malformed TOML near line {}, column {}: {}",
                path.display(),
                line,
                column,
                err.message()
            )));
        }
    };
    if !secrets_allowed
        && parsed
            .asr
            .as_ref()
            .and_then(|section| section.api_key.as_deref())
            .is_some_and(|key| !key.is_empty())
    {
        // Fail loudly rather than accept a key into a file that gets
        // committed.
        return Err(AsrConfigError(format!(
            "{}: api_key may not live in the shared committed config; \
             move it to spokenrectifier.local.toml",
            path.display()
        )));
    }
    apply(config, parsed);
    Ok(())
}

/// Load the `[asr]` config from a directory: defaults, overlaid with
/// `spokenrectifier.toml`, then `spokenrectifier.local.toml` (which wins,
/// and is the only layer an `api_key` may come from). Missing files are
/// fine; malformed ones are an error naming the file.
pub fn load_asr_config(dir: &Path) -> Result<AsrConfig, AsrConfigError> {
    let mut config = AsrConfig::defaults();
    read_layer(&mut config, &dir.join("spokenrectifier.toml"), false)?;
    read_layer(&mut config, &dir.join("spokenrectifier.local.toml"), true)?;
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
    fn api_key_in_the_shared_committed_file_is_rejected() {
        let dir = std::env::temp_dir().join("sr-asr-config-test-shared-key");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[asr]\napi_key = \"sk-oops\"\n",
        )
        .unwrap();

        let err = load_asr_config(&dir).unwrap_err().0;
        assert!(err.contains("spokenrectifier.toml"), "got: {err}");
        assert!(err.contains("local"), "got: {err}");
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
