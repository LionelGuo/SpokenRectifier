//! The connection domain (模型与连接, ticket 19): the `[asr]` / `[llm]`
//! cards the pane paints and saves, the preset port, the live endpoint
//! preview, and the live re-adoption of saved connections.

use anyhow::anyhow;

use spokenrectifier_asr::schema::{
    load_asr_config, save_asr_connection, AliyunConfig, AliyunEdit, AsrConfig, AsrConnectionEdit,
    AsrProviderKind, AzureEdit, TencentConfig, TencentEdit, VolcengineEdit,
};

use super::state::{global, SpeechSource};

/// Dart-side mirror of a key's state for the diff-echo field (ADR-0008,
/// 2026-08-28 revision): a key stored in the git-ignored local file
/// rides the wire as its VALUE — the GUI paints it masked by default
/// with an eye toggle, and saves by diffing against it. An environment
/// key never echoes a value: only its placement, so the field starts
/// empty and typing would store a new local key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeKeyStatus {
    Unset,
    /// The stored key (from the local layer only — the loader's
    /// shared-file guard makes that the sole source).
    InLocalFile(String),
    FromEnv(String),
}

/// The key view from a section's key pair: the local-file value when
/// stored, else the env placement, else nothing.
fn bridge_key(api_key: Option<String>, api_key_env: Option<String>) -> BridgeKeyStatus {
    match spokenrectifier_config::section_write::key_status(
        api_key.as_deref(),
        api_key_env.as_deref(),
    ) {
        spokenrectifier_config::section_write::KeyStatus::Unset => BridgeKeyStatus::Unset,
        spokenrectifier_config::section_write::KeyStatus::InLocalFile => {
            BridgeKeyStatus::InLocalFile(api_key.unwrap_or_default())
        }
        spokenrectifier_config::section_write::KeyStatus::FromEnv(name) => {
            BridgeKeyStatus::FromEnv(name)
        }
    }
}

/// Dart-side mirror of what a connection save does to the api_key: the
/// field echoes the stored local key (see [`BridgeKeyStatus`]), so a
/// save DIFFS against it — keep the stored one, replace it, or clear it
/// (an empty `Set` is a `Clear` — an empty key is no key).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeKeyEdit {
    Keep,
    Clear,
    Set(String),
}

impl From<BridgeKeyEdit> for spokenrectifier_config::section_write::KeyEdit {
    fn from(value: BridgeKeyEdit) -> Self {
        use spokenrectifier_config::section_write::KeyEdit;
        match value {
            BridgeKeyEdit::Keep => KeyEdit::Keep,
            BridgeKeyEdit::Clear => KeyEdit::Clear,
            BridgeKeyEdit::Set(key) => KeyEdit::Set(key),
        }
    }
}

/// The effective `[asr]` connection as the settings pane paints it: the
/// common segment's folded fields, every vendor sub-section (the pane
/// renders the active one), the resolved endpoint (a read-only preview;
/// `None` for providers without an adapter yet), and each secret's
/// placement.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeAsrConnection {
    /// `aliyun` / `volcengine` / `tencent` / `openai` / `azure`.
    pub provider: String,
    pub model: String,
    pub language: String,
    pub base_url: Option<String>,
    /// The WebSocket URL the current fields resolve to.
    pub endpoint: Option<String>,
    /// The common Bearer key pair (the active provider's, when its
    /// family is the Bearer one).
    pub key: BridgeKeyStatus,
    pub aliyun: BridgeAsrAliyun,
    pub volcengine: BridgeAsrVolcengine,
    pub tencent: BridgeAsrTencent,
    pub azure: BridgeAsrAzure,
}

/// `[asr.aliyun]` for the pane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrAliyun {
    pub workspace_id: Option<String>,
    pub region: String,
}

/// `[asr.volcengine]` for the pane; the access token echoes per the
/// diff-echo key block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrVolcengine {
    pub app_id: Option<String>,
    pub resource_id: String,
    pub access_key: BridgeKeyStatus,
}

/// `[asr.tencent]` for the pane; both account credentials echo per
/// the diff-echo key block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrTencent {
    pub app_id: Option<String>,
    pub secret_id: BridgeKeyStatus,
    pub secret_key: BridgeKeyStatus,
}

/// `[asr.azure]` for the pane (adapter not scheduled).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrAzure {
    pub region: Option<String>,
    pub endpoint_id: Option<String>,
}

/// The editor's whole `[asr]` card, mirroring the schema's
/// [`AsrConnectionEdit`]: common fields plus every vendor sub-section
/// (a provider switch never clears another vendor's fields).
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeAsrEdit {
    pub provider: String,
    pub model: String,
    pub language: String,
    pub base_url: Option<String>,
    pub api_key: BridgeKeyEdit,
    pub aliyun: BridgeAsrAliyunEdit,
    pub volcengine: BridgeAsrVolcengineEdit,
    pub tencent: BridgeAsrTencentEdit,
    pub azure: BridgeAsrAzureEdit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrAliyunEdit {
    pub workspace_id: Option<String>,
    pub region: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrVolcengineEdit {
    pub app_id: Option<String>,
    pub resource_id: String,
    pub access_key: BridgeKeyEdit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrTencentEdit {
    pub app_id: Option<String>,
    pub secret_id: BridgeKeyEdit,
    pub secret_key: BridgeKeyEdit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAsrAzureEdit {
    pub region: Option<String>,
    pub endpoint_id: Option<String>,
}

/// The effective `[llm]` connection as the settings pane paints it.
/// `key` is the ACTIVE vendor's resolved pair; `keys` carries every
/// vendor's — a key authenticates exactly one vendor, so the pane
/// re-binds its key block per vendor chip and a switch never shows
/// another vendor's key (ADR-0011).
///
/// The open shape (ADR-0019) rides here resolved: the format axis, the
/// thinking switch's four-state reading, and the three overlays as the
/// JSON text the pane's boxes hold (pretty, so a reopen reformats
/// whatever the file's table ordering was).
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeLlmConnection {
    pub vendor: String,
    pub base_url: String,
    pub model: String,
    /// `openai_chat` | `anthropic` | `gemini` (ADR-0019 item 1).
    pub format: String,
    pub key: BridgeKeyStatus,
    pub keys: Vec<BridgeLlmVendorKey>,
    /// The thinking group's reading: `on` | `off` | `unconfigured` |
    /// `broken`. Only `on` is the switch's painted state — the other
    /// three are one semantic for every consumer (ADR-0019 item 3).
    pub thinking_state: String,
    /// `broken`'s file-and-key detail, for the card's warning slot.
    pub thinking_detail: Option<String>,
    /// The resident overlay's JSON text; `None` when unset.
    pub body_json: Option<String>,
    pub thinking_on_json: Option<String>,
    pub thinking_off_json: Option<String>,
}

/// One chip's fill, straight from the engine-side single source
/// (`crates/llm::presets`) — the pane never copies the table (ADR-0019
/// item 5). The model rule (only when empty or still a preset name) and
/// the blank custom seventh chip live in the pane, not here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeLlmPreset {
    /// The chip's wire name — also the vendor slot it names.
    pub name: String,
    pub format: String,
    pub base_url: String,
    pub model: String,
    /// The 「设置思考字段」 switch the chip stamps.
    pub thinking_fields: bool,
    /// The two shares as JSON text, for the boxes.
    pub thinking_on_json: String,
    pub thinking_off_json: String,
}

/// The editor's whole `[llm]` card: the endpoint fields, the format
/// axis, the thinking switch, and the three overlay boxes as the JSON
/// text they hold (blank or `{}` = that share unset). The save writes
/// exactly this model, so the next load returns what the user saw.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeLlmEdit {
    pub vendor: String,
    pub base_url: String,
    pub model: String,
    /// One of the three format wire names (validated on the Rust side).
    pub format: String,
    pub thinking_fields: bool,
    /// The resident overlay's JSON text; blank/`{}`/None = unset.
    pub body_json: Option<String>,
    pub thinking_on_json: Option<String>,
    pub thinking_off_json: Option<String>,
    pub api_key: BridgeKeyEdit,
}

/// One vendor's resolved key pair, for the pane's per-vendor key block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeLlmVendorKey {
    pub vendor: String,
    pub key: BridgeKeyStatus,
}

fn asr_view(config: AsrConfig) -> BridgeAsrConnection {
    let stored = |value: &Option<String>| match value {
        Some(_) => BridgeKeyStatus::InLocalFile(value.clone().unwrap_or_default()),
        None => BridgeKeyStatus::Unset,
    };
    BridgeAsrConnection {
        provider: config.provider.as_str().to_string(),
        endpoint: config.endpoint(),
        key: bridge_key(config.api_key, config.api_key_env),
        model: config.model,
        language: config.language,
        base_url: config.base_url,
        aliyun: BridgeAsrAliyun {
            workspace_id: config.aliyun.workspace_id,
            region: config.aliyun.region,
        },
        volcengine: BridgeAsrVolcengine {
            app_id: config.volcengine.app_id,
            resource_id: config.volcengine.resource_id,
            access_key: stored(&config.volcengine.access_key),
        },
        tencent: BridgeAsrTencent {
            app_id: config.tencent.app_id,
            secret_id: stored(&config.tencent.secret_id),
            secret_key: stored(&config.tencent.secret_key),
        },
        azure: BridgeAsrAzure {
            region: config.azure.region,
            endpoint_id: config.azure.endpoint_id,
        },
    }
}

pub(crate) fn llm_view(config: spokenrectifier_llm::LlmConfig) -> BridgeLlmConnection {
    let keys = spokenrectifier_llm::Vendor::ALL
        .iter()
        .map(|&vendor| {
            let pair = config.resolved_keys(vendor);
            BridgeLlmVendorKey {
                vendor: vendor.as_str().to_string(),
                key: bridge_key(pair.api_key, pair.api_key_env),
            }
        })
        .collect();
    let share = |share: &Option<serde_json::Map<String, serde_json::Value>>| {
        share.as_ref().map(|map| {
            serde_json::to_string_pretty(&serde_json::Value::Object(map.clone()))
                .unwrap_or_default()
        })
    };
    BridgeLlmConnection {
        key: bridge_key(config.model.api_key, config.model.api_key_env),
        vendor: config.model.vendor.as_str().to_string(),
        base_url: config.model.base_url,
        model: config.model.model,
        format: config.model.format.as_str().to_string(),
        keys,
        thinking_state: config.model.thinking.state.as_str().to_string(),
        thinking_detail: config.model.thinking.state.detail().map(str::to_string),
        body_json: share(&config.model.thinking.overlays.body),
        thinking_on_json: share(&config.model.thinking.overlays.thinking_on),
        thinking_off_json: share(&config.model.thinking.overlays.thinking_off),
    }
}

/// The preset port (ADR-0019 item 5): the settings pane's chip row, read
/// from the engine-side single source rather than copied into Dart. The
/// blank 自定义 seventh chip is the pane's own — it names no preset.
pub fn llm_presets() -> Vec<BridgeLlmPreset> {
    spokenrectifier_llm::presets::all()
        .into_iter()
        .map(|preset| {
            let share = |map: &serde_json::Map<String, serde_json::Value>| {
                serde_json::to_string_pretty(&serde_json::Value::Object(map.clone()))
                    .unwrap_or_default()
            };
            BridgeLlmPreset {
                name: preset.name.to_string(),
                format: preset.format.as_str().to_string(),
                base_url: preset.base_url.to_string(),
                model: preset.model.to_string(),
                thinking_fields: preset.thinking_fields,
                thinking_on_json: share(&preset.thinking_on),
                thinking_off_json: share(&preset.thinking_off),
            }
        })
        .collect()
}

/// The effective `[asr]` and `[llm]` connections from the layer files —
/// the connection domain's initial paint. File-level and
/// engine-independent: the engine adopts the config at its creation,
/// and a save re-adopts it at once via [`apply_connection_configs`] —
/// next session (ASR) / next attempt (LLM), no restart (ADR-0010). The
/// fidelity-eval run builds its own engine per run, unaffected.
pub fn connection_config() -> anyhow::Result<BridgeConnection> {
    let dirs = spokenrectifier_config::search_dirs();
    let asr = load_asr_config(&dirs).map_err(|err| anyhow!("ASR {}", err.0))?;
    let llm =
        spokenrectifier_llm::load_llm_config(&dirs).map_err(|err| anyhow!("LLM {}", err.0))?;
    Ok(BridgeConnection {
        asr: asr_view(asr),
        llm: llm_view(llm),
    })
}

/// Both connections in one read.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeConnection {
    pub asr: BridgeAsrConnection,
    pub llm: BridgeLlmConnection,
}

/// Write the editor's whole `[asr]` card back into the layer files (see
/// `save_asr_connection` for the placement and preservation rules —
/// common fields plus every vendor sub-section, every secret to the
/// local layer only) and return the re-read view — the file's truth,
/// not the ask.
pub fn set_asr_connection(edit: BridgeAsrEdit) -> anyhow::Result<BridgeAsrConnection> {
    let BridgeAsrEdit {
        provider,
        model,
        language,
        base_url,
        api_key,
        aliyun,
        volcengine,
        tencent,
        azure,
    } = edit;
    let provider = AsrProviderKind::from_str_name(&provider).ok_or_else(|| {
        anyhow!("[asr] provider \"{provider}\" is unknown: pick one of the known providers")
    })?;
    let dirs = spokenrectifier_config::search_dirs();
    save_asr_connection(
        &dirs,
        &AsrConnectionEdit {
            provider,
            model,
            language,
            base_url,
            api_key: api_key.into(),
            aliyun: AliyunEdit {
                workspace_id: aliyun.workspace_id,
                region: aliyun.region,
            },
            volcengine: VolcengineEdit {
                app_id: volcengine.app_id,
                resource_id: volcengine.resource_id,
                access_key: volcengine.access_key.into(),
            },
            tencent: TencentEdit {
                app_id: tencent.app_id,
                secret_id: tencent.secret_id.into(),
                secret_key: tencent.secret_key.into(),
            },
            azure: AzureEdit {
                region: azure.region,
                endpoint_id: azure.endpoint_id,
            },
        },
    )
    .map_err(|err| anyhow!("ASR {}", err.0))?;
    let config = load_asr_config(&dirs).map_err(|err| anyhow!("ASR {}", err.0))?;
    Ok(asr_view(config))
}

/// The settings pane's live endpoint preview: the WebSocket URL the
/// form's current fields resolve to, recomputed while the user types
/// or switches the provider chip — the same [`AsrConfig::endpoint`]
/// derivation the loaded view previews with, so there is exactly one.
pub fn asr_endpoint_preview(
    provider: String,
    model: String,
    base_url: Option<String>,
    workspace_id: Option<String>,
    region: String,
    app_id: Option<String>,
) -> anyhow::Result<Option<String>> {
    let provider = AsrProviderKind::from_str_name(&provider).ok_or_else(|| {
        anyhow!("[asr] provider \"{provider}\" is unknown: pick one of the known providers")
    })?;
    Ok(AsrConfig {
        provider,
        model,
        // `endpoint` trims and ignores whitespace-only overrides.
        base_url,
        aliyun: AliyunConfig {
            workspace_id,
            region,
        },
        tencent: TencentConfig {
            app_id,
            ..TencentConfig::default()
        },
        ..AsrConfig::defaults()
    }
    .endpoint())
}

/// Write the editor's `[llm]` model back into the layer files (see
/// `save_llm_connection`) and return the re-read view — the file's
/// truth, not the ask. The format and the thinking group ride the edit
/// whole (ADR-0019 items 1/2); the group's boxes are the JSON text the
/// pane holds, and a bad one refuses the save before anything is
/// written.
pub fn set_llm_connection(edit: BridgeLlmEdit) -> anyhow::Result<BridgeLlmConnection> {
    let dirs = spokenrectifier_config::search_dirs();
    let vendor = spokenrectifier_llm::Vendor::from_str_name(&edit.vendor).ok_or_else(|| {
        anyhow!(
            "[llm] vendor \"{}\" is unknown: pick one of the known endpoints",
            edit.vendor
        )
    })?;
    let format = spokenrectifier_llm::Format::from_str_name(&edit.format).ok_or_else(|| {
        anyhow!(
            "[llm] format \"{}\" is unknown: pick {}",
            edit.format,
            spokenrectifier_llm::Format::accepted()
        )
    })?;
    spokenrectifier_llm::save_llm_connection(
        &dirs,
        &spokenrectifier_llm::LlmConnectionEdit {
            vendor,
            base_url: edit.base_url,
            model: edit.model,
            format,
            thinking_fields: edit.thinking_fields,
            body_json: edit.body_json,
            thinking_on_json: edit.thinking_on_json,
            thinking_off_json: edit.thinking_off_json,
            api_key: edit.api_key.into(),
        },
    )
    .map_err(|err| anyhow!("LLM {}", err.0))?;
    let config =
        spokenrectifier_llm::load_llm_config(&dirs).map_err(|err| anyhow!("LLM {}", err.0))?;
    Ok(llm_view(config))
}

/// Adopt the saved `[asr]` / `[llm]` connections — and, riding the same
/// rebuilt client, every `[rectify]` key (ADR-0010, scope extended by
/// ADR-0015) — into the live engine at once: the settings window calls
/// this right after a save lands, so the next session opens with the new
/// ASR provider and the next rectify attempt with the new LLM and the new
/// rectify behavior (thinking policy, prefill, the light-touch gate, the
/// extra directive), no restart. Re-reads the layer files and rebuilds
/// both collaborators through the same factory the startup path uses
/// (mic-only fallback included: clearing the provider's credentials
/// really does drop back to mic+VAD at runtime).
///
/// The rebuild happens before any handover, so any refusal (an incomplete
/// credential set, an unadapted provider, the demo-mode LLM that has no
/// runtime script — all tested in `engine_factory`) returns `Err` and
/// keeps BOTH previous collaborators running; the files stay saved either
/// way, so the next launch adopts them regardless. The swap semantics are
/// locked by the engine's `live_swap` tests. A no-op on the fake engine
/// (tests and demos hold no production collaborators to swap).
pub fn apply_connection_configs() -> anyhow::Result<()> {
    let g = global()?;
    if !matches!(g.source, SpeechSource::Mic) {
        return Ok(());
    }
    let (asr, llm) =
        crate::engine_factory::rebuild_connections(&spokenrectifier_config::search_dirs())?;
    g.engine.set_asr_provider(asr);
    g.engine.set_llm_provider(llm);
    Ok(())
}
