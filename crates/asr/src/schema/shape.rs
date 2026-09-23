//! The folded `[asr]` types and their defaults.

use serde::Deserialize;

/// Which vendor the `[asr]` section routes to. One adapter crate per
/// kind (the cloud ASR protocols are private and mutually incompatible).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AsrProviderKind {
    Aliyun,
    Volcengine,
    Tencent,
    Openai,
    Azure,
}

impl AsrProviderKind {
    /// The file/wire name — serde's lowercase form, spelled out for the
    /// settings editor's section writes and the bridge.
    pub fn as_str(self) -> &'static str {
        match self {
            AsrProviderKind::Aliyun => "aliyun",
            AsrProviderKind::Volcengine => "volcengine",
            AsrProviderKind::Tencent => "tencent",
            AsrProviderKind::Openai => "openai",
            AsrProviderKind::Azure => "azure",
        }
    }

    /// Parse the file/wire name; unknown names are `None` for the caller
    /// to refuse.
    pub fn from_str_name(name: &str) -> Option<Self> {
        match name.trim() {
            "aliyun" => Some(AsrProviderKind::Aliyun),
            "volcengine" => Some(AsrProviderKind::Volcengine),
            "tencent" => Some(AsrProviderKind::Tencent),
            "openai" => Some(AsrProviderKind::Openai),
            "azure" => Some(AsrProviderKind::Azure),
            _ => None,
        }
    }
}

/// `[asr.aliyun]`: the DashScope realtime endpoint's optional routing.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AliyunConfig {
    /// Bailian workspace id — switches the endpoint to the
    /// workspace-scoped host.
    pub workspace_id: Option<String>,
    /// Host region for the default endpoint.
    pub region: String,
}

impl AliyunConfig {
    fn defaults() -> Self {
        AliyunConfig {
            workspace_id: None,
            region: "cn-beijing".into(),
        }
    }
}

/// `[asr.volcengine]`: the Seed-ASR bigmodel stream's credentials. The
/// access token authenticates by header (`X-Api-Access-Key`) — no
/// signature, no timestamp — so one static string is the whole secret.
#[derive(Clone, Default, PartialEq)]
pub struct VolcengineConfig {
    /// The console app id (`X-Api-App-Key`).
    pub app_id: Option<String>,
    /// The access token; local layer only.
    pub access_key: Option<String>,
    /// The resource id (`X-Api-Resource-Id`): generation + billing
    /// mode on the Volcengine side, "which model" in the UI's terms.
    pub resource_id: String,
}

/// Manual impl: the access token never reaches logs or panics.
impl std::fmt::Debug for VolcengineConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VolcengineConfig")
            .field("app_id", &self.app_id)
            .field(
                "access_key",
                &self.access_key.as_ref().map(|_| "<redacted>"),
            )
            .field("resource_id", &self.resource_id)
            .finish()
    }
}

impl VolcengineConfig {
    fn defaults() -> Self {
        VolcengineConfig {
            app_id: None,
            access_key: None,
            resource_id: "volc.seedasr.sauc.duration".into(),
        }
    }
}

/// `[asr.tencent]`: the realtime stream's account credentials. The
/// secret key signs every URL (HMAC-SHA1) — the most sensitive value in
/// the whole schema, local layer only.
#[derive(Clone, Default, PartialEq)]
pub struct TencentConfig {
    /// The account app id (rides the URL path).
    pub app_id: Option<String>,
    /// The account SecretId; local layer only.
    pub secret_id: Option<String>,
    /// The signing SecretKey; local layer only.
    pub secret_key: Option<String>,
}

/// Manual impl: neither account credential ever reaches logs or panics.
impl std::fmt::Debug for TencentConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TencentConfig")
            .field("app_id", &self.app_id)
            .field("secret_id", &self.secret_id.as_ref().map(|_| "<redacted>"))
            .field(
                "secret_key",
                &self.secret_key.as_ref().map(|_| "<redacted>"),
            )
            .finish()
    }
}

/// `[asr.azure]`: region + optional custom-speech endpoint (adapter not
/// scheduled — the schema carries it so the config surface is complete).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AzureConfig {
    pub region: Option<String>,
    pub endpoint_id: Option<String>,
}

/// The folded `[asr]` configuration: the common segment plus every
/// vendor sub-section (an inactive vendor's fields survive a provider
/// switch untouched).
#[derive(Clone, PartialEq)]
pub struct AsrConfig {
    /// Which sub-section is live.
    pub provider: AsrProviderKind,
    /// Model name — the UI's "which model" field; each adapter maps it
    /// onto its protocol (Volcengine's wire fixes `model_name` to
    /// `"bigmodel"` and selects by resource id instead).
    pub model: String,
    /// Target language; `zh` covers the mixed Chinese-English
    /// dictation v1 targets.
    pub language: String,
    /// Bearer-style key (Aliyun/OpenAI/Azure); never committed.
    pub api_key: Option<String>,
    /// Environment variable consulted when `api_key` is absent.
    pub api_key_env: Option<String>,
    /// Full host override; wins over every derived endpoint.
    pub base_url: Option<String>,
    pub aliyun: AliyunConfig,
    pub volcengine: VolcengineConfig,
    pub tencent: TencentConfig,
    pub azure: AzureConfig,
}

/// Manual impl: no secret ever reaches logs or panic messages (the
/// sub-sections' own Debug impls redact their fields).
impl std::fmt::Debug for AsrConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AsrConfig")
            .field("provider", &self.provider)
            .field("model", &self.model)
            .field("language", &self.language)
            .field("api_key", &self.api_key.as_ref().map(|_| "<redacted>"))
            .field("api_key_env", &self.api_key_env)
            .field("base_url", &self.base_url)
            .field("aliyun", &self.aliyun)
            .field("volcengine", &self.volcengine)
            .field("tencent", &self.tencent)
            .field("azure", &self.azure)
            .finish()
    }
}

impl AsrConfig {
    /// The v1 default: Aliyun qwen3-asr-flash-realtime on the Beijing
    /// realtime host, key from the environment.
    pub fn defaults() -> Self {
        AsrConfig {
            provider: AsrProviderKind::Aliyun,
            model: "qwen3-asr-flash-realtime".into(),
            language: "zh".into(),
            api_key: None,
            api_key_env: Some("DASHSCOPE_API_KEY".into()),
            base_url: None,
            aliyun: AliyunConfig::defaults(),
            volcengine: VolcengineConfig::defaults(),
            tencent: TencentConfig::default(),
            azure: AzureConfig::default(),
        }
    }

    /// The common Bearer-style key: local-file `api_key` first, then the
    /// configured environment variable. The vendors this key family does
    /// not fit (Volcengine, Tencent) keep their credentials in their own
    /// sub-sections.
    pub fn resolve_common_key(&self) -> Option<String> {
        if let Some(key) = &self.api_key {
            return Some(key.clone());
        }
        let env_name = self.api_key_env.as_deref()?;
        std::env::var(env_name).ok().filter(|k| !k.is_empty())
    }

    /// The active provider's full credential set, ready to connect:
    /// every field its adapter demands. `None` means something required
    /// is missing — the error names what.
    pub fn active_credentials(&self) -> Result<ActiveCredentials, String> {
        match self.provider {
            AsrProviderKind::Aliyun | AsrProviderKind::Openai | AsrProviderKind::Azure => {
                match self.resolve_common_key() {
                    Some(key) => Ok(ActiveCredentials::CommonKey(key)),
                    None => Err(
                        "[asr] no api key: set api_key in spokenrectifier.local.toml \
                                 (or export the api_key_env variable)"
                            .into(),
                    ),
                }
            }
            AsrProviderKind::Volcengine => {
                let missing = [
                    self.volcengine.app_id.as_deref().map(str::trim),
                    Some(self.volcengine.resource_id.trim()),
                    self.volcengine.access_key.as_deref().map(str::trim),
                ];
                if missing
                    .iter()
                    .all(|field| field.is_some_and(|v| !v.is_empty()))
                {
                    Ok(ActiveCredentials::Volcengine)
                } else {
                    Err(
                        "[asr.volcengine] needs app_id, access_key, and resource_id together \
                         (access_key only in spokenrectifier.local.toml)"
                            .into(),
                    )
                }
            }
            AsrProviderKind::Tencent => {
                let missing = [
                    self.tencent.app_id.as_deref().map(str::trim),
                    self.tencent.secret_id.as_deref().map(str::trim),
                    self.tencent.secret_key.as_deref().map(str::trim),
                ];
                if missing
                    .iter()
                    .all(|field| field.is_some_and(|v| !v.is_empty()))
                {
                    Ok(ActiveCredentials::Tencent)
                } else {
                    Err(
                        "[asr.tencent] needs app_id, secret_id, and secret_key together \
                         (secret_id/secret_key only in spokenrectifier.local.toml)"
                            .into(),
                    )
                }
            }
        }
    }

    /// Whether the active provider carries ANY credential value, stored
    /// or resolvable — the engine assembly's "an ASR key is set" check
    /// (a real-ASR + demo-LLM combination must be an error, never a
    /// silent fallback).
    pub fn carries_credentials(&self) -> bool {
        let present = |value: &Option<String>| {
            value
                .as_deref()
                .map(str::trim)
                .is_some_and(|text| !text.is_empty())
        };
        match self.provider {
            AsrProviderKind::Aliyun | AsrProviderKind::Openai | AsrProviderKind::Azure => {
                present(&self.api_key) || self.resolve_common_key().is_some()
            }
            AsrProviderKind::Volcengine => {
                present(&self.volcengine.app_id) || present(&self.volcengine.access_key)
            }
            AsrProviderKind::Tencent => {
                present(&self.tencent.app_id)
                    || present(&self.tencent.secret_id)
                    || present(&self.tencent.secret_key)
            }
        }
    }

    /// The WebSocket URL the current fields resolve to (the settings
    /// card's read-only preview): the active provider's default host
    /// with `base_url` overriding the whole host part. `None` for the
    /// providers whose adapter is not built yet — no URL to promise.
    pub fn endpoint(&self) -> Option<String> {
        let host = || {
            self.base_url
                .as_deref()
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .map(|base| base.trim_end_matches('/').to_string())
        };
        match self.provider {
            AsrProviderKind::Aliyun => {
                let host = host().unwrap_or_else(|| match &self.aliyun.workspace_id {
                    Some(workspace) if !workspace.trim().is_empty() => {
                        format!(
                            "wss://{}.{}.maas.aliyuncs.com",
                            workspace, self.aliyun.region
                        )
                    }
                    _ => "wss://dashscope.aliyuncs.com".to_string(),
                });
                Some(format!("{host}/api-ws/v1/realtime?model={}", self.model))
            }
            AsrProviderKind::Volcengine => {
                let host = host().unwrap_or_else(|| "wss://openspeech.bytedance.com".into());
                Some(format!("{host}/api/v3/sauc/bigmodel"))
            }
            // The app id rides the URL path; the query (secretid,
            // timestamp, nonce, voice id, signature…) is per-connection
            // and never part of the preview.
            AsrProviderKind::Tencent => {
                let host = host().unwrap_or_else(|| "wss://asr.cloud.tencent.com".into());
                let app_id = self.tencent.app_id.as_deref().map(str::trim).unwrap_or("");
                Some(format!("{host}/asr/v2/{app_id}"))
            }
            AsrProviderKind::Openai | AsrProviderKind::Azure => None,
        }
    }
}

/// The credentials an adapter connects with, per key family.
#[derive(Debug, Clone, PartialEq)]
pub enum ActiveCredentials {
    /// The common Bearer key resolved (Aliyun, OpenAI, Azure).
    CommonKey(String),
    /// The Volcengine sub-section is complete.
    Volcengine,
    /// The Tencent sub-section is complete.
    Tencent,
}

#[derive(Debug, thiserror::Error)]
#[error("ASR config: {0}")]
pub struct AsrConfigError(pub String);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_route_to_aliyun_realtime_with_env_key() {
        let config = AsrConfig::defaults();
        assert_eq!(config.provider, AsrProviderKind::Aliyun);
        assert_eq!(config.model, "qwen3-asr-flash-realtime");
        assert_eq!(config.api_key_env.as_deref(), Some("DASHSCOPE_API_KEY"));
        assert_eq!(config.language, "zh");
        assert_eq!(config.volcengine.resource_id, "volc.seedasr.sauc.duration");
    }

    #[test]
    fn provider_names_round_trip_through_serde_and_parse() {
        for (kind, name) in [
            (AsrProviderKind::Aliyun, "aliyun"),
            (AsrProviderKind::Volcengine, "volcengine"),
            (AsrProviderKind::Tencent, "tencent"),
            (AsrProviderKind::Openai, "openai"),
            (AsrProviderKind::Azure, "azure"),
        ] {
            assert_eq!(kind.as_str(), name);
            // What a save writes must be what a load reads back.
            assert_eq!(
                serde_json::from_str::<AsrProviderKind>(format!("\"{name}\"").as_str()).unwrap(),
                kind
            );
            assert_eq!(AsrProviderKind::from_str_name(name), Some(kind));
        }
        assert_eq!(AsrProviderKind::from_str_name("nonsense"), None);
    }

    #[test]
    fn key_resolution_covers_both_key_families() {
        let mut config = AsrConfig::defaults();
        config.api_key = Some("sk-file".into());
        assert_eq!(config.resolve_common_key().as_deref(), Some("sk-file"));

        let mut env_config = AsrConfig::defaults();
        // SAFETY: single test, unique variable, no parallel reader.
        unsafe { std::env::set_var("SR_TEST_ASRL_KEY", "sk-env") };
        env_config.api_key = None;
        env_config.api_key_env = Some("SR_TEST_ASRL_KEY".into());
        assert_eq!(env_config.resolve_common_key().as_deref(), Some("sk-env"));

        // The Volcengine family reads its sub-section instead: the whole
        // triple (the demand is spelled out in its own test below).
        let mut volc = AsrConfig::defaults();
        volc.provider = AsrProviderKind::Volcengine;
        volc.volcengine.app_id = Some("42".into());
        volc.volcengine.access_key = Some("volc-token".into());
        assert!(volc.active_credentials().is_ok());
        assert!(volc.carries_credentials());
    }

    #[test]
    fn volcengine_credentials_demand_the_whole_triple() {
        let mut config = AsrConfig::defaults();
        config.provider = AsrProviderKind::Volcengine;
        let err = config.active_credentials().unwrap_err();
        assert!(err.contains("app_id"), "got: {err}");
        assert!(err.contains("access_key"), "got: {err}");
        assert!(!config.carries_credentials());

        config.volcengine.access_key = Some("tok".into());
        assert!(
            config.carries_credentials(),
            "a partial set still counts as set"
        );
        assert!(config.active_credentials().is_err());

        config.volcengine.app_id = Some("42".into());
        assert!(config.active_credentials().is_ok());
    }

    #[test]
    fn tencent_credentials_demand_the_whole_triple() {
        let mut config = AsrConfig::defaults();
        config.provider = AsrProviderKind::Tencent;
        let err = config.active_credentials().unwrap_err();
        assert!(err.contains("app_id"), "got: {err}");
        assert!(err.contains("secret_id"), "got: {err}");
        assert!(err.contains("secret_key"), "got: {err}");
        assert!(!config.carries_credentials());

        config.tencent.secret_key = Some("signing".into());
        assert!(
            config.carries_credentials(),
            "a partial set still counts as set"
        );
        assert!(config.active_credentials().is_err());

        config.tencent.app_id = Some("1250012548".into());
        config.tencent.secret_id = Some("AKIDz".into());
        assert_eq!(
            config.active_credentials().unwrap(),
            ActiveCredentials::Tencent
        );
    }

    #[test]
    fn endpoint_previews_per_provider_with_base_url_winning() {
        let mut config = AsrConfig::defaults();
        assert_eq!(
            config.endpoint().as_deref(),
            Some("wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime")
        );

        config.aliyun.workspace_id = Some("llm-abc123".into());
        assert_eq!(
            config.endpoint().as_deref(),
            Some(
                "wss://llm-abc123.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
            )
        );

        config.base_url = Some("wss://custom.example.com/".into());
        assert_eq!(
            config.endpoint().as_deref(),
            Some("wss://custom.example.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime")
        );

        config.provider = AsrProviderKind::Volcengine;
        config.base_url = None;
        assert_eq!(
            config.endpoint().as_deref(),
            Some("wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")
        );
        config.base_url = Some("wss://proxy.example.com".into());
        assert_eq!(
            config.endpoint().as_deref(),
            Some("wss://proxy.example.com/api/v3/sauc/bigmodel")
        );

        config.provider = AsrProviderKind::Tencent;
        config.base_url = None;
        config.tencent.app_id = Some("1250012548".into());
        assert_eq!(
            config.endpoint().as_deref(),
            Some("wss://asr.cloud.tencent.com/asr/v2/1250012548")
        );
        config.base_url = Some("wss://proxy.example.com".into());
        assert_eq!(
            config.endpoint().as_deref(),
            Some("wss://proxy.example.com/asr/v2/1250012548")
        );

        // The never-adapter families still promise no URL.
        config.provider = AsrProviderKind::Openai;
        config.base_url = None;
        assert_eq!(config.endpoint(), None);
    }

    #[test]
    fn debug_never_leaks_a_secret() {
        let mut config = AsrConfig::defaults();
        config.api_key = Some("sk-super-secret".into());
        config.volcengine.access_key = Some("volc-super-secret".into());
        config.tencent.secret_key = Some("signing-super-secret".into());
        let text = format!("{config:?}");
        assert!(!text.contains("super-secret"), "leaked: {text}");
        assert!(text.contains("<redacted>"), "got: {text}");
    }
}
