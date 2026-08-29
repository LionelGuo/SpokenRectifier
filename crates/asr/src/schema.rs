//! The `[asr]` section's shape: one common segment plus one sub-section
//! per vendor (ADR-0009). The common segment carries every decision all
//! providers share — `provider` (which sub-section is live), `model`,
//! `language`, the Bearer-style `api_key`/`api_key_env`, and `base_url`;
//! each vendor sub-section carries only its own fields, matching the
//! adapter crate boundaries. Switching `provider` never clears another
//! vendor's configuration.
//!
//! Layered like every section: defaults, then `spokenrectifier.toml`,
//! then `spokenrectifier.local.toml` (git-ignored; the only place a
//! secret-shaped field may live — the loader's guard rejects `api_key`,
//! any `*_key`, and `secret_id` in the shared file, and the save path
//! here writes them to the local file only).
//!
//! No compatibility layer (v1 unreleased): the old flat `[asr]`
//! `workspace_id`/`region` moved into `[asr.aliyun]` — an existing file
//! hand-edits once, per the ADR.

use std::path::PathBuf;

use serde::Deserialize;
use spokenrectifier_config::load_section_layers;
use spokenrectifier_config::section_write::{
    KeyEdit, KeyStatus, SectionField, WriteLayer, write_section_fields,
};

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
/// the whole schema, local layer only (adapter: ticket 25).
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
            AsrProviderKind::Tencent => Err(
                "[asr] provider \"tencent\": the adapter is not built yet (ticket 25); \
                 pick aliyun or volcengine"
                    .into(),
            ),
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

    /// The key's placement for display (the diff-echo key block): the
    /// common `api_key` pair.
    pub fn common_key_status(&self) -> KeyStatus {
        spokenrectifier_config::section_write::key_status(
            self.api_key.as_deref(),
            self.api_key_env.as_deref(),
        )
    }

    /// The placement for a stored-only secret (the sub-section keys have
    /// no environment variant): stored, or nothing.
    pub fn stored_key_status(value: &Option<String>) -> KeyStatus {
        match value {
            Some(_) => KeyStatus::InLocalFile,
            None => KeyStatus::Unset,
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
            AsrProviderKind::Tencent | AsrProviderKind::Openai | AsrProviderKind::Azure => None,
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
}

#[derive(Debug, thiserror::Error)]
#[error("ASR config: {0}")]
pub struct AsrConfigError(pub String);

// -- file layering ----------------------------------------------------------

/// The `[asr]` overlay: the config crate loads it, this crate folds it.
/// Sub-sections overlay as whole tables (an overlay replaces the fields
/// it names, field by field, like every other section).
#[derive(Debug, Default, Deserialize)]
struct AsrSection {
    provider: Option<AsrProviderKind>,
    model: Option<String>,
    language: Option<String>,
    api_key: Option<String>,
    api_key_env: Option<String>,
    base_url: Option<String>,
    aliyun: Option<AliyunOverlay>,
    volcengine: Option<VolcengineOverlay>,
    tencent: Option<TencentOverlay>,
    azure: Option<AzureOverlay>,
}

#[derive(Debug, Default, Deserialize)]
struct AliyunOverlay {
    workspace_id: Option<String>,
    region: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct VolcengineOverlay {
    app_id: Option<String>,
    access_key: Option<String>,
    resource_id: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct TencentOverlay {
    app_id: Option<String>,
    secret_id: Option<String>,
    secret_key: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct AzureOverlay {
    region: Option<String>,
    endpoint_id: Option<String>,
}

/// Load the `[asr]` config from the layer files, wherever they live
/// among `dirs`: defaults, overlaid with `spokenrectifier.toml`, then
/// `spokenrectifier.local.toml` (which wins, and is the only layer a
/// secret may come from). Missing files are fine; malformed ones are an
/// error naming the file.
pub fn load_asr_config(dirs: &[PathBuf]) -> Result<AsrConfig, AsrConfigError> {
    let mut config = AsrConfig::defaults();
    let layers =
        load_section_layers::<AsrSection>(dirs, "asr").map_err(|err| AsrConfigError(err.0))?;
    for layer in layers {
        fold(&mut config, layer.value);
    }
    if config.model.trim().is_empty() {
        return Err(AsrConfigError(
            "[asr] model is empty: remove the field or name a real model".into(),
        ));
    }
    if config.language.trim().is_empty() {
        return Err(AsrConfigError(
            "[asr] language is empty: remove the field or name a real language".into(),
        ));
    }
    Ok(config)
}

/// Fold one overlay onto the defaults, field by field, sub-sections
/// included.
fn fold(config: &mut AsrConfig, section: AsrSection) {
    let AsrSection {
        provider,
        model,
        language,
        api_key,
        api_key_env,
        base_url,
        aliyun,
        volcengine,
        tencent,
        azure,
    } = section;
    if let Some(v) = provider {
        config.provider = v;
    }
    if let Some(v) = model {
        config.model = v;
    }
    if let Some(v) = language {
        config.language = v;
    }
    if let Some(v) = api_key {
        config.api_key = Some(v);
    }
    if let Some(v) = api_key_env {
        config.api_key_env = Some(v);
    }
    if let Some(v) = base_url {
        config.base_url = Some(v);
    }
    if let Some(overlay) = aliyun {
        if let Some(v) = overlay.workspace_id {
            config.aliyun.workspace_id = Some(v);
        }
        if let Some(v) = overlay.region {
            config.aliyun.region = v;
        }
    }
    if let Some(overlay) = volcengine {
        if let Some(v) = overlay.app_id {
            config.volcengine.app_id = Some(v);
        }
        if let Some(v) = overlay.access_key {
            config.volcengine.access_key = Some(v);
        }
        if let Some(v) = overlay.resource_id {
            config.volcengine.resource_id = v;
        }
    }
    if let Some(overlay) = tencent {
        if let Some(v) = overlay.app_id {
            config.tencent.app_id = Some(v);
        }
        if let Some(v) = overlay.secret_id {
            config.tencent.secret_id = Some(v);
        }
        if let Some(v) = overlay.secret_key {
            config.tencent.secret_key = Some(v);
        }
    }
    if let Some(overlay) = azure {
        if let Some(v) = overlay.region {
            config.azure.region = Some(v);
        }
        if let Some(v) = overlay.endpoint_id {
            config.azure.endpoint_id = Some(v);
        }
    }
}

// -- the settings editor's write path (ticket 24) -----------------------------

/// One optional string field: an all-whitespace value is an absent one.
fn trimmed(value: &Option<String>) -> Option<String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

/// `[asr.aliyun]`'s editor fields.
#[derive(Debug, Clone, PartialEq)]
pub struct AliyunEdit {
    /// A Bailian workspace id; `None` = the shared DashScope domain.
    pub workspace_id: Option<String>,
    pub region: String,
}

/// `[asr.volcengine]`'s editor fields.
#[derive(Debug, Clone, PartialEq)]
pub struct VolcengineEdit {
    /// The console app id; `None` = unset.
    pub app_id: Option<String>,
    pub resource_id: String,
    pub access_key: KeyEdit,
}

/// `[asr.tencent]`'s editor fields.
#[derive(Debug, Clone, PartialEq)]
pub struct TencentEdit {
    pub app_id: Option<String>,
    pub secret_id: KeyEdit,
    pub secret_key: KeyEdit,
}

/// `[asr.azure]`'s editor fields.
#[derive(Debug, Clone, PartialEq)]
pub struct AzureEdit {
    pub region: Option<String>,
    pub endpoint_id: Option<String>,
}

/// What the connection editor writes back: the whole `[asr]` card —
/// common fields plus every vendor sub-section, so a provider switch
/// never clears another vendor's configuration. Saving writes exactly
/// this model, so the next load returns what the user saw.
#[derive(Debug, Clone, PartialEq)]
pub struct AsrConnectionEdit {
    pub provider: AsrProviderKind,
    pub model: String,
    pub language: String,
    /// A full host override; `None` = the provider's derived endpoint.
    pub base_url: Option<String>,
    pub api_key: KeyEdit,
    pub aliyun: AliyunEdit,
    pub volcengine: VolcengineEdit,
    pub tencent: TencentEdit,
    pub azure: AzureEdit,
}

/// One required string: trimmed, and an error naming the field when the
/// editor's model carries nothing usable.
fn required(section: &str, field: &str, value: &str) -> Result<String, AsrConfigError> {
    let value = value.trim();
    if value.is_empty() {
        Err(AsrConfigError(format!(
            "[{section}] {field} is empty: name a real value"
        )))
    } else {
        Ok(value.to_string())
    }
}

/// An optional field's wire form: the trimmed value, or a reset (the
/// key leaves every layer, back to the built-in default).
fn optional(field: &str, value: Option<String>) -> SectionField {
    match trimmed(&value) {
        Some(value) => SectionField::str(field, value),
        None => SectionField::reset(field),
    }
}

/// Write the connection editor's model back into the layer files. The
/// non-secret fields land in the layer that owns their section
/// (section-preserving, per section: common and each sub-section
/// independently); every secret-shaped field lands in the local file
/// only — never the committable shared file, whose loader rejects the
/// whole ASR field set outright (the layering ironclad, ADR-0009).
pub fn save_asr_connection(
    dirs: &[PathBuf],
    edit: &AsrConnectionEdit,
) -> Result<(), AsrConfigError> {
    let model = required("asr", "model", &edit.model)?;
    let language = required("asr", "language", &edit.language)?;
    let region = required("asr.aliyun", "region", &edit.aliyun.region)?;
    let resource_id = required(
        "asr.volcengine",
        "resource_id",
        &edit.volcengine.resource_id,
    )?;

    let write = |section: &str, fields: &[SectionField]| {
        write_section_fields(dirs, section, fields, WriteLayer::Owning)
            .map_err(|err| AsrConfigError(err.0))
    };

    write(
        "asr",
        &[
            SectionField::str("provider", edit.provider.as_str()),
            SectionField::str("model", model),
            SectionField::str("language", language),
            optional("base_url", edit.base_url.clone()),
        ],
    )?;
    write(
        "asr.aliyun",
        &[
            optional("workspace_id", edit.aliyun.workspace_id.clone()),
            SectionField::str("region", region),
        ],
    )?;
    write(
        "asr.volcengine",
        &[
            optional("app_id", edit.volcengine.app_id.clone()),
            SectionField::str("resource_id", resource_id),
        ],
    )?;
    edit.volcengine
        .access_key
        .clone()
        .write_to_local(dirs, "asr.volcengine", "access_key")
        .map_err(|err| AsrConfigError(err.0))?;
    write(
        "asr.tencent",
        &[optional("app_id", edit.tencent.app_id.clone())],
    )?;
    for (field, edit_value) in [
        ("secret_id", &edit.tencent.secret_id),
        ("secret_key", &edit.tencent.secret_key),
    ] {
        edit_value
            .clone()
            .write_to_local(dirs, "asr.tencent", field)
            .map_err(|err| AsrConfigError(err.0))?;
    }
    write(
        "asr.azure",
        &[
            optional("region", edit.azure.region.clone()),
            optional("endpoint_id", edit.azure.endpoint_id.clone()),
        ],
    )?;
    edit.api_key
        .clone()
        .write_to_local(dirs, "asr", "api_key")
        .map_err(|err| AsrConfigError(err.0))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn edit() -> AsrConnectionEdit {
        AsrConnectionEdit {
            provider: AsrProviderKind::Aliyun,
            model: "qwen3-asr-flash-realtime".into(),
            language: "zh".into(),
            base_url: None,
            api_key: KeyEdit::Keep,
            aliyun: AliyunEdit {
                workspace_id: None,
                region: "cn-beijing".into(),
            },
            volcengine: VolcengineEdit {
                app_id: None,
                resource_id: "volc.seedasr.sauc.duration".into(),
                access_key: KeyEdit::Keep,
            },
            tencent: TencentEdit {
                app_id: None,
                secret_id: KeyEdit::Keep,
                secret_key: KeyEdit::Keep,
            },
            azure: AzureEdit {
                region: None,
                endpoint_id: None,
            },
        }
    }

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
    fn common_and_sub_section_layers_override_field_by_field() {
        let dir = scratch("sr-asr-schema-layers");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[asr]\nprovider = \"volcengine\"\nmodel = \"big\"\n\
             [asr.aliyun]\nworkspace_id = \"llm-shared\"\nregion = \"cn-beijing\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[asr]\napi_key = \"sk-local\"\nlanguage = \"en\"\n\
             [asr.volcengine]\naccess_key = \"volc-secret\"\napp_id = \"42\"\n",
        )
        .unwrap();

        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.provider, AsrProviderKind::Volcengine);
        assert_eq!(config.model, "big");
        assert_eq!(config.language, "en");
        assert_eq!(config.api_key.as_deref(), Some("sk-local"));
        // Sub-sections fold from both files, each field on its own.
        assert_eq!(config.aliyun.workspace_id.as_deref(), Some("llm-shared"));
        assert_eq!(config.volcengine.access_key.as_deref(), Some("volc-secret"));
        assert_eq!(config.volcengine.app_id.as_deref(), Some("42"));
        // Untouched fields keep their defaults.
        assert_eq!(config.volcengine.resource_id, "volc.seedasr.sauc.duration");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_unknown_provider_is_a_load_error_naming_the_section() {
        let dir = scratch("sr-asr-schema-unknown-provider");
        std::fs::write(dir.join(SHARED_FILE), "[asr]\nprovider = \"wat\"\n").unwrap();

        let err = load_asr_config(std::slice::from_ref(&dir)).unwrap_err().0;
        assert!(err.contains("asr"), "got: {err}");
        assert!(err.contains("provider"), "got: {err}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_explicitly_emptied_model_or_language_is_a_load_error() {
        for field in ["model", "language"] {
            let dir = scratch("sr-asr-schema-empty");
            std::fs::write(dir.join(SHARED_FILE), format!("[asr]\n{field} = \"\"\n")).unwrap();
            let err = load_asr_config(std::slice::from_ref(&dir)).unwrap_err().0;
            assert!(err.contains(field), "{field}: got: {err}");
            std::fs::remove_dir_all(&dir).unwrap();
        }
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
    fn the_tencent_provider_is_reserved_not_wired() {
        let mut config = AsrConfig::defaults();
        config.provider = AsrProviderKind::Tencent;
        let err = config.active_credentials().unwrap_err();
        assert!(err.contains("ticket 25"), "got: {err}");
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

    // -- the settings editor's write path (ticket 24) ----------------------

    #[test]
    fn a_volcengine_save_writes_the_sub_sections_and_keeps_the_key_local() {
        let dir = scratch("sr-asr-save-volcengine");
        let mut model = edit();
        model.provider = AsrProviderKind::Volcengine;
        model.model = "volc.seedasr.sauc.duration".into();
        model.volcengine.app_id = Some("42".into());
        model.volcengine.access_key = KeyEdit::Set("volc-secret".into());
        model.tencent.secret_id = KeyEdit::Set("tencent-id".into());

        save_asr_connection(std::slice::from_ref(&dir), &model).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(
            shared.contains("provider = \"volcengine\""),
            "got: {shared}"
        );
        assert!(shared.contains("[asr.aliyun]"), "got: {shared}");
        assert!(shared.contains("region = \"cn-beijing\""), "got: {shared}");
        assert!(shared.contains("[asr.volcengine]"), "got: {shared}");
        assert!(shared.contains("app_id = \"42\""), "got: {shared}");
        assert!(shared.contains("resource_id"), "got: {shared}");
        assert!(!shared.contains("access_key"), "secret leaked: {shared}");
        assert!(!shared.contains("secret_id"), "secret leaked: {shared}");

        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("[asr.volcengine]"),
            "sub-section not local: {local}"
        );
        assert!(
            local.contains("access_key = \"volc-secret\""),
            "got: {local}"
        );
        assert!(local.contains("[asr.tencent]"), "got: {local}");
        assert!(local.contains("secret_id = \"tencent-id\""), "got: {local}");

        // The load passes the guard and returns the saved world.
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.provider, AsrProviderKind::Volcengine);
        assert_eq!(config.volcengine.app_id.as_deref(), Some("42"));
        assert_eq!(config.volcengine.access_key.as_deref(), Some("volc-secret"));
        assert_eq!(config.tencent.secret_id.as_deref(), Some("tencent-id"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The ironclad for the extended field set: a GUI save may never
    /// leave an ASR credential in the committable shared file — and
    /// whatever it writes must still load (the loader's guard would
    /// reject the file outright).
    #[test]
    fn a_saved_secret_never_lands_in_shared_however_the_layers_sit() {
        let dir = scratch("sr-asr-save-ironclad");
        // Shared owns every ASR section (no local file exists): the
        // owning writes target shared, the secret writes must not follow.
        std::fs::write(
            dir.join(SHARED_FILE),
            "[asr]\nmodel = \"m\"\n[asr.volcengine]\napp_id = \"42\"\n",
        )
        .unwrap();

        let mut model = edit();
        model.volcengine.access_key = KeyEdit::Set("volc-secret".into());
        model.tencent.secret_key = KeyEdit::Set("signing".into());
        save_asr_connection(std::slice::from_ref(&dir), &model).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(!shared.contains("access_key"), "leaked: {shared}");
        assert!(!shared.contains("secret_key"), "leaked: {shared}");
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("access_key = \"volc-secret\""),
            "got: {local}"
        );
        assert!(local.contains("secret_key = \"signing\""), "got: {local}");
        load_asr_config(std::slice::from_ref(&dir)).unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_key_keep_touches_no_local_file_and_a_clear_strips_it() {
        let dir = scratch("sr-asr-save-keep");
        save_asr_connection(std::slice::from_ref(&dir), &edit()).unwrap();
        assert!(dir.join(SHARED_FILE).is_file());
        assert!(!dir.join(LOCAL_FILE).exists(), "keep created a local file");

        let dir = scratch("sr-asr-save-clear");
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[asr]\napi_key = \"sk-old\"\n[asr.volcengine]\naccess_key = \"volc-old\"\n",
        )
        .unwrap();
        let mut model = edit();
        model.api_key = KeyEdit::Clear;
        model.volcengine.access_key = KeyEdit::Clear;
        save_asr_connection(std::slice::from_ref(&dir), &model).unwrap();

        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(!local.contains("api_key"), "not cleared: {local}");
        assert!(!local.contains("access_key"), "not cleared: {local}");
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.api_key, None);
        assert_eq!(config.volcengine.access_key, None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_cleared_optional_sub_field_resets_in_every_layer() {
        let dir = scratch("sr-asr-save-reset");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[asr]\nbase_url = \"wss://old.example.com\"\n[asr.aliyun]\nworkspace_id = \"llm-x\"\n",
        )
        .unwrap();
        let mut model = edit();
        model.base_url = Some("   ".into()); // whitespace = reset
        save_asr_connection(std::slice::from_ref(&dir), &model).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(!shared.contains("base_url"), "not reset: {shared}");
        assert!(!shared.contains("workspace_id"), "not reset: {shared}");
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.base_url, None);
        assert_eq!(config.aliyun.workspace_id, None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_empty_required_field_is_refused_and_writes_nothing() {
        for (field, broken) in [("model", "  "), ("language", "")] {
            let dir = scratch("sr-asr-save-empty");
            let mut model = edit();
            match field {
                "model" => model.model = broken.into(),
                _ => model.language = broken.into(),
            }
            let err = save_asr_connection(std::slice::from_ref(&dir), &model)
                .unwrap_err()
                .0;
            assert!(err.contains(field), "got: {err}");
            assert!(!dir.join(SHARED_FILE).exists(), "wrote on a refused save");
            assert!(!dir.join(LOCAL_FILE).exists());
            std::fs::remove_dir_all(&dir).unwrap();
        }

        let dir = scratch("sr-asr-save-empty-resource");
        let mut model = edit();
        model.volcengine.resource_id = " ".into();
        let err = save_asr_connection(std::slice::from_ref(&dir), &model)
            .unwrap_err()
            .0;
        assert!(err.contains("resource_id"), "got: {err}");
        assert!(!dir.join(SHARED_FILE).exists(), "wrote on a refused save");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
