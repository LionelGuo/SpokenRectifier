//! LLM configuration: defaults from the v1 model matrix, overridable per
//! field from the layered config files (loading rules live in the config
//! crate; an `api_key` may only come from the git-ignored local layer).
//!
//! One model per mode: every intensity (light-touch or full) calls the same
//! endpoint — the length threshold only changes how the prompt asks the
//! model to rectify, never which model answers.
//!
//! The connection face is open (ADR-0019): `[llm] format` is the one
//! behavioral axis, the 「设置思考字段」 switch plus the three
//! `[llm.overlays]` shares own the request body's variable part, and the
//! pre-0019 keys (thinking dialect, the two extra-body cabins) survive
//! only as a read-time grandfather that the first connection-domain
//! save retires — the ratchet.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::Deserialize;
use serde_json::{Map, Value};
use spokenrectifier_config::LayerSource;
use spokenrectifier_config::load_section_layers;
use spokenrectifier_config::section_write::{
    KeyEdit, KeyStatus, SectionField, WriteLayer, owning_layer, validate_json_table_shape,
    write_section_fields,
};

use crate::format::Format;
use crate::intensity::Intensity;
use crate::presets;
use crate::vendor::Vendor;

/// Everything the rectify pipeline needs to call the model.
#[derive(Debug, Clone, PartialEq)]
pub struct LlmConfig {
    /// The rectify behavior face — the `[rectify]` section's keys
    /// (thinking policy, prefill, the light-touch gate and extra
    /// directive; ADR-0015/0016). Every key is a `LlmConfig` layer-file
    /// key: a rebuilt client carries a change for free, which is the
    /// whole runtime-adoption story for the rectify domain (ADR-0010).
    pub rectify: RectifyConfig,
    /// The one model the mode calls, for every intensity.
    pub model: ModelConfig,
    /// One key pair per vendor, from the `[llm.<vendor>]` sub-sections —
    /// a key authenticates exactly one vendor, so each keeps its own
    /// slot and a vendor switch never carries another vendor's key
    /// (ADR-0011; `model.api_key` mirrors the ACTIVE vendor's pair for
    /// the client, this map is the whole truth the settings view paints).
    pub vendor_keys: BTreeMap<Vendor, VendorKeys>,
    /// The `[llm.custom]` sub-section (ADR-0018, shrunk by ADR-0019 to a
    /// pure key slot on the wire): the legacy cabins still read from
    /// pre-0019 files — read-time grandfathering input, retired by the
    /// first connection-domain save. The slot's key pair lives in
    /// `vendor_keys[Vendor::Custom]` like every vendor's.
    pub custom: CustomSlot,
    /// The legacy flat `[llm] api_key`/`api_key_env` pair as the layers
    /// left it (save-time migration only; ADR-0011).
    pub(crate) legacy_flat: VendorKeys,
    /// The pre-0019 `[llm] extra_body` hold as the layers left it —
    /// read-time grandfathering input only (it folds into the thinking
    /// shares at load), retired by the first connection-domain save
    /// (ADR-0019 item 4).
    pub(crate) legacy_extra_body: Option<Map<String, Value>>,
    /// Whether any layer file shaped the endpoint (model, base_url, or
    /// any key): the user configured a real model, so a missing key is an
    /// error for the caller to surface, not a silent fallback to a demo.
    pub endpoint_configured: bool,
}

/// One vendor's key pair, from its `[llm.<vendor>]` sub-section.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct VendorKeys {
    /// Set from `spokenrectifier.local.toml`; never committed.
    pub api_key: Option<String>,
    /// Environment variable consulted when `api_key` is absent. `None`
    /// in the stored slots means "not file-set" — the vendor's
    /// conventional name applies at resolution.
    pub api_key_env: Option<String>,
}

// -- the rectify behavior face ([rectify], ADR-0015/0016) --------------------

/// When the model thinks (glossary: 思考策略). Three tiers, serialized as
/// the three lowercase strings — never a bool; the legacy `[llm]`
/// `thinking` bool maps onto `Always`/`Off` through the grandfather.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThinkingPolicy {
    /// Thinking on for every rectify (today's default: placeholder
    /// absorption depends on it — v4-flash probe, 工单 33).
    Always,
    /// Thinking on only when the transcript's placeholder census finds
    /// a pin — the same census the prompt's injection gate runs
    /// (ADR-0012); the two must never disagree.
    Placeholders,
    /// Thinking off for every rectify — buys back light-band latency
    /// and leaves prefill mostly empty.
    Off,
}

impl ThinkingPolicy {
    /// The file/wire name — one of the three lowercase strings.
    pub fn as_str(self) -> &'static str {
        match self {
            ThinkingPolicy::Always => "always",
            ThinkingPolicy::Placeholders => "placeholders",
            ThinkingPolicy::Off => "off",
        }
    }

    /// Parse the file/wire name, strictly: the three lowercase strings
    /// and nothing else — no bools, no case variants (ADR-0015).
    pub fn from_str_name(name: &str) -> Option<Self> {
        match name {
            "always" => Some(ThinkingPolicy::Always),
            "placeholders" => Some(ThinkingPolicy::Placeholders),
            "off" => Some(ThinkingPolicy::Off),
            _ => None,
        }
    }

    /// The save-time translation of the legacy `[llm] thinking` bool:
    /// `true` is today's default (always), `false` its opposite.
    fn from_legacy_bool(on: bool) -> Self {
        if on {
            ThinkingPolicy::Always
        } else {
            ThinkingPolicy::Off
        }
    }
}

/// One intensity tier's prompt knobs — the shape of `[rectify.full]`,
/// and of `[rectify.light_touch]`'s policy/prefill pair. The two tiers
/// never inherit from each other.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RectifyTier {
    /// When the model thinks for this tier's rectifies.
    pub thinking_policy: ThinkingPolicy,
    /// Whether pinned prompts teach the inline prefill grammar (on) or
    /// compose the pass-through form (off; ADR-0014). Independent of
    /// the policy: separate knobs.
    pub prefill: bool,
}

/// The `[rectify.light_touch]` tier: the two prompt knobs plus the
/// light-touch gate and the extra directive.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LightTouchConfig {
    /// The light-touch master switch. Off means every utterance takes
    /// full rectify at runtime — the keys below stay stored, just
    /// unadopted (ADR-0015), and the extra directive never injects.
    pub enabled: bool,
    /// Utterances strictly below this many characters take light-touch
    /// rectify; at or above, full rectify. Same model either way.
    pub max_chars: usize,
    pub tier: RectifyTier,
    /// The light-touch extra directive (ADR-0016): injected as its own
    /// section after the light-touch intensity section, light-touch
    /// attempts only. `None` (key absent, empty, or all-whitespace) =
    /// not injected — today's prompt byte for byte.
    pub extra_directive: Option<String>,
}

/// The `[rectify.quick]` sub-section (ADR-0020): the quick-mode gesture's
/// master switch, whether a quick session rectifies at all, and the quick
/// extra directive. No grandfather — the section is new, so a file
/// without it reads as the master switch off, today's gesture unchanged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickConfig {
    /// The quick-mode master switch. Off means no held hotkey ever
    /// upgrades a session; the keys below stay stored, just unadopted
    /// (ADR-0015's stance for a switch that is off, applied here).
    pub enabled: bool,
    /// Whether a quick session runs rectify (on) or pastes the raw
    /// transcript straight through (off — no model call at all).
    pub rectify: bool,
    /// The quick extra directive (ADR-0020): injected as its own section
    /// after the light-touch intensity section, on quick-mode rectifies
    /// only, where it replaces the light-touch directive. `None` (key
    /// absent, empty, or all-whitespace) = not injected.
    pub extra_directive: Option<String>,
}

/// The folded `[rectify]` section: the full and light-touch tiers plus
/// the quick-mode sub-section (ADR-0020). Missing section, missing keys
/// = today's behavior on every field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RectifyConfig {
    pub full: RectifyTier,
    pub light_touch: LightTouchConfig,
    pub quick: QuickConfig,
}

impl RectifyConfig {
    /// Today's defaults: both tiers think always with prefill on, the
    /// light-touch gate open at 40 characters, no extra directive, quick
    /// mode off (so no hold upgrades anything) but rectifying whenever it
    /// is enabled — existing users migrate nothing.
    fn today() -> Self {
        RectifyConfig {
            full: RectifyTier {
                thinking_policy: ThinkingPolicy::Always,
                prefill: true,
            },
            light_touch: LightTouchConfig {
                enabled: true,
                max_chars: 40,
                tier: RectifyTier {
                    thinking_policy: ThinkingPolicy::Always,
                    prefill: true,
                },
                extra_directive: None,
            },
            quick: QuickConfig {
                enabled: false,
                rectify: true,
                extra_directive: None,
            },
        }
    }

    /// The chosen intensity's prompt knobs (the evaluation order's step
    /// ②: intensity first, then that tier's policy/prefill — ADR-0015).
    pub fn tier(&self, intensity: Intensity) -> &RectifyTier {
        match intensity {
            Intensity::LightTouch => &self.light_touch.tier,
            Intensity::Full => &self.full,
        }
    }
}

/// One endpoint, any provider (ADR-0019): the format axis drives every
/// request-shape decision, the vendor names a key slot and the chip the
/// user last clicked — nothing more.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelConfig {
    /// Everything before the format's path completion.
    pub base_url: String,
    pub model: String,
    /// The ACTIVE vendor's resolved pair (its sub-section's key first,
    /// then the legacy flat pair, then nothing). Mirrors
    /// `vendor_keys[&vendor]` as resolved by [`load_llm_config`].
    pub api_key: Option<String>,
    /// Environment variable consulted when `api_key` is absent.
    pub api_key_env: Option<String>,
    /// The active key slot + last-clicked preset pointer (ADR-0019
    /// item 1): never drives request behavior.
    pub vendor: Vendor,
    /// The one behavioral axis: path completion, auth headers, prompt
    /// slots, and SSE framing all key off this.
    pub format: Format,
    /// The connection domain's thinking fields (ADR-0019 item 2): the
    /// switch's resolved state plus the three overlays, carried resolved
    /// so the request builder never re-derives them.
    pub thinking: ConnectionThinking,
}

/// The `[llm] thinking_fields` switch plus the `[llm.overlays]` shares,
/// resolved (ADR-0019 item 2/3). The switch and overlays validate and
/// invalidate as one group: a malformed key voids the whole group
/// (non-blocking — the file's name rides in the state for the settings
/// domain's warning slot) and requests carry no thinking keys at all,
/// leaving the endpoint on its own default.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionThinking {
    pub state: ThinkingState,
    pub overlays: Overlays,
}

/// The switch's three-state resolution plus the broken branch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ThinkingState {
    /// Switch on with a non-empty on-share: the rectify tier's thinking
    /// policy picks the share per request (ADR-0015's evaluation).
    On,
    /// Switch off: both shares stay stored but inert — off is a stance,
    /// not a deletion (ADR-0015 precedent); requests carry no thinking
    /// keys.
    Off,
    /// The files never set the switch (or set it on with no on-share):
    /// same no-thinking-keys semantics, a different warning face.
    Unconfigured,
    /// A malformed switch/overlays group — the non-blocking side of the
    /// bad-file boundary (ADR-0019 item 3). The detail names the file
    /// and the offending key for the settings domain's warning slot.
    Broken(String),
}

impl ThinkingState {
    /// The settings wire name (the bridge's paint): the four states'
    /// lowercase names — `on` / `off` / `unconfigured` / `broken`.
    pub fn as_str(&self) -> &'static str {
        match self {
            ThinkingState::On => "on",
            ThinkingState::Off => "off",
            ThinkingState::Unconfigured => "unconfigured",
            ThinkingState::Broken(_) => "broken",
        }
    }

    /// The Broken branch's file-and-key detail, for the settings
    /// domain's warning slot; `None` on the three good branches.
    pub fn detail(&self) -> Option<&str> {
        match self {
            ThinkingState::Broken(detail) => Some(detail),
            _ => None,
        }
    }
}

/// The three `[llm.overlays]` shares; `None` is the off form (an empty
/// table reads as unset, like the blank extra directive).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Overlays {
    /// The resident share (temperature and friends): merged into every
    /// request before the thinking share.
    pub body: Option<Map<String, Value>>,
    pub thinking_on: Option<Map<String, Value>>,
    pub thinking_off: Option<Map<String, Value>>,
}

/// The `[llm.custom]` sub-section as the bridge still paints it: the
/// legacy cabins read from pre-0019 files so the read-time grandfather
/// can expand them, and the first connection-domain save strips them —
/// the slot shrinks to its key pair (ADR-0019 item 4). While another
/// vendor is active the cabins sit stored, just unadopted (ADR-0018's
/// dormancy, honored until the ratchet retires the cabins wholesale).
#[derive(Debug, Clone, PartialEq)]
pub struct CustomSlot {
    /// The custom endpoint, cached for the chip's return (legacy read);
    /// the ACTIVE endpoint always lives in the common `[llm]` segment.
    pub base_url: Option<String>,
    pub model: Option<String>,
    /// One of the four adapted shapes; a missing key reads as `openai`
    /// (legacy read — the save-time ratchet composes the edit's dialect
    /// into the new shares).
    pub thinking_dialect: Vendor,
    /// `[llm.custom.extra_body]`; an empty table reads as absent
    /// (legacy read, same ratchet story).
    pub extra_body: Option<serde_json::Map<String, Value>>,
}

impl LlmConfig {
    /// The v1 default: DeepSeek V4-Flash over today's rectify behavior
    /// (thinking always, prefill on, light-touch gate open at 40
    /// characters, no extra directive). Every vendor's key slot starts
    /// empty (the conventional environment names apply at resolution).
    pub fn defaults() -> Self {
        // The default endpoint's thinking shares are the legacy deepseek
        // dictionary pair, byte for byte — the pre-0019 default body,
        // which is also what the read-time grandfather expands a bare
        // legacy file set into.
        let (thinking_on, thinking_off) = presets::legacy_shares(Vendor::DeepSeek);
        LlmConfig {
            rectify: RectifyConfig::today(),
            endpoint_configured: false,
            legacy_flat: VendorKeys::default(),
            legacy_extra_body: None,
            custom: CustomSlot {
                base_url: None,
                model: None,
                thinking_dialect: Vendor::OpenAi,
                extra_body: None,
            },
            vendor_keys: Vendor::ALL
                .iter()
                .map(|&vendor| (vendor, VendorKeys::default()))
                .collect(),
            model: ModelConfig {
                base_url: "https://api.deepseek.com".into(),
                model: "deepseek-v4-flash".into(),
                api_key: None,
                api_key_env: Some(
                    Vendor::DeepSeek
                        .default_env()
                        .expect("deepseek names an env")
                        .into(),
                ),
                vendor: Vendor::DeepSeek,
                format: Format::OpenaiChat,
                thinking: ConnectionThinking {
                    state: ThinkingState::On,
                    overlays: Overlays {
                        body: None,
                        thinking_on: Some(thinking_on),
                        thinking_off: Some(thinking_off),
                    },
                },
            },
        }
    }

    /// One vendor's resolved key pair for display and resolution: its
    /// own slot first, then (the ACTIVE vendor only) the legacy flat
    /// pair, then the vendor's conventional environment name — `None`
    /// for custom, which has none (ADR-0018). An inactive vendor never
    /// borrows the flat pair — it authenticated whatever vendor the
    /// files named, not this one.
    pub fn resolved_keys(&self, vendor: Vendor) -> VendorKeys {
        let slot = self.vendor_keys.get(&vendor).cloned().unwrap_or_default();
        let flat = if vendor == self.model.vendor {
            self.legacy_flat.clone()
        } else {
            Default::default()
        };
        VendorKeys {
            api_key: slot.api_key.or(flat.api_key),
            api_key_env: slot
                .api_key_env
                .or(flat.api_key_env)
                .or_else(|| vendor.default_env().map(str::to_string)),
        }
    }

    /// The fidelity-eval copy of this config: the eval never runs user
    /// directive text (ADR-0006 posture; ADR-0016 for the light-touch
    /// key, ADR-0020 for the quick one), so both extra directives are
    /// stripped whatever the layers carry — style and global are already
    /// `None` per request by construction.
    pub fn for_eval(mut self) -> Self {
        self.rectify.light_touch.extra_directive = None;
        self.rectify.quick.extra_directive = None;
        self
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
/// Vendor sub-sections (`[llm.deepseek]`, …) overlay field by field like
/// every other section; a vendor's key slot never touches another
/// vendor's (ADR-0011). The post-0019 keys (`format`,
/// `thinking_fields`, `overlays`) ride as raw TOML values and validate
/// after the load, so each lands on its own side of the bad-file
/// boundary (ADR-0019 item 3): a bad format refuses the load, a bad
/// switch/overlays degrades the thinking group.
#[derive(Debug, Default, Deserialize)]
struct LlmSection {
    thinking: Option<bool>,
    prefill: Option<bool>,
    light_touch_max_chars: Option<usize>,
    base_url: Option<String>,
    model: Option<String>,
    /// The legacy single key pair, predating the per-vendor slots. It
    /// authenticated whatever vendor the same files named, so the loader
    /// grandfathers it into the ACTIVE vendor's pair (a sub-section key
    /// still wins) and the first save migrates it into that vendor's
    /// slot and clears the flat fields.
    api_key: Option<String>,
    api_key_env: Option<String>,
    vendor: Option<Vendor>,
    /// The format axis (ADR-0019 item 1), raw: strict string validation
    /// happens after the load so the error names the accepted values.
    format: Option<toml::Value>,
    /// The 「设置思考字段」 switch, raw: a malformed value is the
    /// non-blocking branch (the thinking group reads as broken).
    thinking_fields: Option<toml::Value>,
    /// The `[llm.overlays]` node, raw: the three shares validate as one
    /// group after the load (malformed → the group voids, non-blocking).
    overlays: Option<toml::Value>,
    /// The pre-0019 hand-edit hold (ADR-0018, retired by ADR-0019):
    /// read-time grandfathering input; the first save folds it into the
    /// thinking shares and strips the key.
    extra_body: Option<serde_json::Map<String, Value>>,
    deepseek: Option<VendorKeysOverlay>,
    volcengine: Option<VendorKeysOverlay>,
    qwen: Option<VendorKeysOverlay>,
    openai: Option<VendorKeysOverlay>,
    anthropic: Option<VendorKeysOverlay>,
    gemini: Option<VendorKeysOverlay>,
    /// The custom endpoint's sub-section (ADR-0018): a key slot like
    /// every vendor's, plus the legacy cabins (restore cache, dialect,
    /// overlay) — read for the grandfather, stripped by the ratchet.
    custom: Option<CustomKeysOverlay>,
}

#[derive(Debug, Default, Deserialize)]
struct VendorKeysOverlay {
    api_key: Option<String>,
    api_key_env: Option<String>,
}

/// The `[llm.custom]` overlay shape (ADR-0018). `thinking_dialect`
/// rides as the raw string and validates after the load (naming the
/// file): the four adapted shapes only, never "custom".
#[derive(Debug, Default, Deserialize)]
struct CustomKeysOverlay {
    api_key: Option<String>,
    api_key_env: Option<String>,
    base_url: Option<String>,
    model: Option<String>,
    thinking_dialect: Option<String>,
    extra_body: Option<serde_json::Map<String, Value>>,
}

/// The legacy flat pair's TOML shape — same as a vendor slot's.
type FlatPair = VendorKeys;

impl LlmSection {
    fn slot(&self, vendor: Vendor) -> Option<&VendorKeysOverlay> {
        match vendor {
            Vendor::DeepSeek => self.deepseek.as_ref(),
            Vendor::Volcengine => self.volcengine.as_ref(),
            Vendor::Qwen => self.qwen.as_ref(),
            Vendor::OpenAi => self.openai.as_ref(),
            Vendor::Anthropic => self.anthropic.as_ref(),
            Vendor::Gemini => self.gemini.as_ref(),
            Vendor::Custom => None, // a different shape; folded separately
        }
    }

    /// Whether any vendor's sub-section carries a non-empty key.
    fn any_slot_key(&self) -> bool {
        Vendor::ALL.iter().any(|vendor| {
            let key = match vendor {
                Vendor::Custom => self.custom.as_ref().and_then(|o| o.api_key.as_deref()),
                _ => self.slot(*vendor).and_then(|o| o.api_key.as_deref()),
            };
            key.is_some_and(|k| !k.is_empty())
        })
    }
}

// -- the post-0019 connection keys (ADR-0019 items 1-3) -----------------------

/// One TOML value onto its JSON twin. Non-finite floats have no JSON
/// shape and refuse — the same shape a save could never write back
/// (`validate_json_table_shape`'s up-front twin). A datetime normally
/// never reaches this far as one (the serde hop into `LlmSection`
/// stringifies it first, the same coercion the pre-0019 extra-body
/// path performed); the arm stays for the day a caller hands a raw
/// table over.
fn toml_value_to_json(value: &toml::Value) -> Result<Value, &'static str> {
    match value {
        toml::Value::String(text) => Ok(Value::String(text.clone())),
        toml::Value::Integer(n) => Ok(Value::Number((*n).into())),
        toml::Value::Float(n) if n.is_finite() => Ok(Value::Number(
            serde_json::Number::from_f64(*n).expect("finite floats are JSON numbers"),
        )),
        toml::Value::Float(_) => Err("is not a finite number, so has no JSON shape"),
        toml::Value::Boolean(b) => Ok(Value::Bool(*b)),
        toml::Value::Datetime(_) => Err("is a TOML datetime, which has no JSON shape"),
        toml::Value::Array(items) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                out.push(toml_value_to_json(item)?);
            }
            Ok(Value::Array(out))
        }
        toml::Value::Table(table) => {
            let mut map = Map::new();
            for (name, item) in table {
                map.insert(name.clone(), toml_value_to_json(item)?);
            }
            Ok(Value::Object(map))
        }
    }
}

/// One layer's `[llm.overlays]` node: exactly the three shares, each a
/// table (a JSON object root); an empty share is the off form. Anything
/// else — an unknown key, a scalar share, a datetime inside — voids the
/// whole group (the group validates and invalidates together,
/// ADR-0019 item 2), the detail naming the file and key for the
/// warning slot.
fn parse_overlays_node(value: &toml::Value, file: &str) -> Result<Overlays, String> {
    let table = value
        .as_table()
        .ok_or_else(|| format!("{file}: [llm.overlays]: must be a table"))?;
    let mut overlays = Overlays::default();
    for (key, share) in table {
        let field = match key.as_str() {
            "body" => &mut overlays.body,
            "thinking_on" => &mut overlays.thinking_on,
            "thinking_off" => &mut overlays.thinking_off,
            other => {
                return Err(format!(
                    "{file}: [llm.overlays]: unknown key `{other}`; allowed: `body`, \
                     `thinking_on`, `thinking_off`"
                ));
            }
        };
        let share_table = share.as_table().ok_or_else(|| {
            format!("{file}: [llm.overlays]: the `{key}` share must be a table (a JSON object)")
        })?;
        let mut map = Map::new();
        for (name, item) in share_table {
            let json = toml_value_to_json(item)
                .map_err(|why| format!("{file}: [llm.overlays.{key}]: `{name}` {why}"))?;
            map.insert(name.clone(), json);
        }
        if !map.is_empty() {
            *field = Some(map); // an empty share is the off form, like blank
        }
    }
    Ok(overlays)
}

/// The folded raw state of the post-0019 keys, resolved from every
/// layer before the fold: the effective values (last layer wins; the
/// overlays node replaces wholesale, like the old extra-body hold) plus
/// the first offender on the non-blocking branch.
struct NewKeys {
    format: Option<Format>,
    switch: Option<bool>,
    overlays: Option<Overlays>,
    broken: Option<String>,
}

/// Resolve and validate the post-0019 keys across the layers. A
/// malformed `format` refuses the whole load (the blocking side of the
/// bad-file boundary); a malformed switch/overlays marks the thinking
/// group broken without blocking (ADR-0019 item 3).
fn resolve_new_keys(
    layers: &[spokenrectifier_config::Layer<LlmSection>],
) -> Result<NewKeys, ConfigError> {
    let mut keys = NewKeys {
        format: None,
        switch: None,
        overlays: None,
        broken: None,
    };
    for layer in layers {
        let file = layer.source.file_name();
        if let Some(value) = &layer.value.format {
            match value.as_str().and_then(Format::from_str_name) {
                Some(format) => keys.format = Some(format),
                None => {
                    let got = value.as_str().map_or_else(
                        || "a non-string value".to_string(),
                        |text| format!("\"{text}\""),
                    );
                    return Err(ConfigError(format!(
                        "{file}: [llm]: format accepts only {}; got {got}",
                        Format::accepted()
                    )));
                }
            }
        }
        if let Some(value) = &layer.value.thinking_fields {
            match value.as_bool() {
                Some(on) => keys.switch = Some(on),
                None => {
                    keys.broken.get_or_insert(format!(
                        "{file}: [llm]: thinking_fields must be a boolean (true/false)"
                    ));
                }
            }
        }
        if let Some(value) = &layer.value.overlays {
            match parse_overlays_node(value, file) {
                Ok(overlays) => keys.overlays = Some(overlays),
                Err(detail) => {
                    keys.broken.get_or_insert(detail);
                }
            }
        }
    }
    Ok(keys)
}

fn apply(config: &mut LlmConfig, llm: LlmSection, flat: &mut FlatPair) {
    // The three legacy prompt knobs are grandfather keys (ADR-0015):
    // they map onto BOTH tiers here, within this layer's fold — a same
    // layer's `[rectify]` overlay then wins (applied after), and a
    // deeper layer's overlay wins by the fold order below.
    if let Some(v) = llm.thinking {
        let policy = ThinkingPolicy::from_legacy_bool(v);
        config.rectify.full.thinking_policy = policy;
        config.rectify.light_touch.tier.thinking_policy = policy;
    }
    if let Some(v) = llm.prefill {
        config.rectify.full.prefill = v;
        config.rectify.light_touch.tier.prefill = v;
    }
    if let Some(v) = llm.light_touch_max_chars {
        config.rectify.light_touch.max_chars = v;
    }
    if let Some(v) = llm.base_url {
        config.model.base_url = v;
    }
    if let Some(v) = llm.model {
        config.model.model = v;
    }
    if let Some(v) = llm.api_key {
        flat.api_key = Some(v);
    }
    if let Some(v) = llm.api_key_env {
        flat.api_key_env = Some(v);
    }
    if let Some(v) = llm.vendor {
        config.model.vendor = v;
    }
    // Replaced wholesale: a local override redefines the hold (legacy
    // read — the grandfather folds it into the thinking shares at load).
    if let Some(v) = llm.extra_body {
        config.legacy_extra_body = Some(v);
    }
    for (vendor, overlay) in [
        (Vendor::DeepSeek, llm.deepseek),
        (Vendor::Volcengine, llm.volcengine),
        (Vendor::Qwen, llm.qwen),
        (Vendor::OpenAi, llm.openai),
        (Vendor::Anthropic, llm.anthropic),
        (Vendor::Gemini, llm.gemini),
    ]
    .into_iter()
    .filter_map(|(vendor, overlay)| overlay.map(|overlay| (vendor, overlay)))
    {
        let slot = config
            .vendor_keys
            .get_mut(&vendor)
            .expect("defaults seed every vendor");
        if let Some(v) = overlay.api_key {
            slot.api_key = Some(v);
        }
        if let Some(v) = overlay.api_key_env {
            slot.api_key_env = Some(v);
        }
    }
    // The custom slot (ADR-0018): the key pair into its vendor slot, the
    // rest into the restore cache. An empty overlay table reads as no
    // overlay — empty is the off form, like the blank extra directive.
    if let Some(custom) = llm.custom {
        let slot = config
            .vendor_keys
            .get_mut(&Vendor::Custom)
            .expect("defaults seed every vendor");
        if let Some(v) = custom.api_key {
            slot.api_key = Some(v);
        }
        if let Some(v) = custom.api_key_env {
            slot.api_key_env = Some(v);
        }
        if let Some(v) = custom.base_url {
            config.custom.base_url = Some(v);
        }
        if let Some(v) = custom.model {
            config.custom.model = Some(v);
        }
        if let Some(v) = custom.thinking_dialect {
            // The loader validated the string against its file before
            // folding; an impossible miss keeps the slot's default.
            config.custom.thinking_dialect =
                Vendor::dialect_from_name(&v).unwrap_or(config.custom.thinking_dialect);
        }
        if let Some(v) = custom.extra_body.filter(|map| !map.is_empty()) {
            config.custom.extra_body = Some(v);
        }
    }
}

/// Load the `[llm]` and `[rectify]` config from the layer files,
/// wherever they live among `dirs`: defaults, overlaid with
/// `spokenrectifier.toml`, then `spokenrectifier.local.toml` (which
/// wins). Missing files are fine; malformed ones are an error naming
/// the file. The grandfather (ADR-0015) folds per layer, shared first:
/// within one layer the legacy `[llm]` prompt knobs land before that
/// layer's `[rectify]` overlay, so a same-layer new key beats the old
/// one, and across layers local wins whatever it says.
pub fn load_llm_config(dirs: &[PathBuf]) -> Result<LlmConfig, ConfigError> {
    let mut config = LlmConfig::defaults();
    let mut flat = FlatPair::default();
    let mut llm_layers =
        load_section_layers::<LlmSection>(dirs, "llm").map_err(|err| ConfigError(err.0))?;
    // The custom dialect validates before any folding, naming its file:
    // the four adapted shapes only — "custom" names an endpoint, never
    // a dialect (ADR-0018).
    for layer in &llm_layers {
        if let Some(text) = layer
            .value
            .custom
            .as_ref()
            .and_then(|custom| custom.thinking_dialect.as_deref())
            && Vendor::dialect_from_name(text).is_none()
        {
            return Err(ConfigError(format!(
                "{}: [llm.custom]: thinking_dialect accepts only \"deepseek\", \
                 \"volcengine\", \"qwen\", or \"openai\" (lowercase); got \"{text}\"",
                layer.source.file_name()
            )));
        }
    }
    let rectify_layers = load_rectify_layers(dirs)?;
    // The post-0019 keys resolve from the raw layers up front (ADR-0019
    // item 3): a malformed format refuses the load here, before any
    // folding; a malformed switch/overlays rides as the broken marker.
    let new_keys = resolve_new_keys(&llm_layers)?;
    let new_keys_world =
        new_keys.format.is_some() || new_keys.switch.is_some() || new_keys.overlays.is_some();
    for source in [LayerSource::Shared, LayerSource::Local] {
        if let Some(at) = llm_layers.iter().position(|layer| layer.source == source) {
            let layer = llm_layers.swap_remove(at);
            // Endpoint fields carry real-model intent (api_key_env alone
            // does not: it only names where a key would come from, which
            // the built-in defaults do too).
            if layer.value.model.is_some()
                || layer.value.base_url.is_some()
                || layer
                    .value
                    .api_key
                    .as_deref()
                    .is_some_and(|k| !k.is_empty())
                || layer.value.any_slot_key()
            {
                config.endpoint_configured = true;
            }
            apply(&mut config, layer.value, &mut flat);
        }
        if let Some(layer) = rectify_layers.iter().find(|layer| layer.source == source) {
            apply_rectify(&mut config.rectify, &layer.value);
        }
    }
    // A blank extra directive is no directive (ADR-0016/0020) — folded
    // last so a local blank still overrides a shared text into nothing.
    // Both directive slots fold the same way, each on its own key.
    config.rectify.light_touch.extra_directive = config
        .rectify
        .light_touch
        .extra_directive
        .take()
        .filter(|text| !text.trim().is_empty());
    config.rectify.quick.extra_directive = config
        .rectify
        .quick
        .extra_directive
        .take()
        .filter(|text| !text.trim().is_empty());
    // The save path's migration input: the flat pair as left behind.
    config.legacy_flat = flat;
    // Resolve the connection face's format and thinking group.
    if new_keys_world {
        // The files speak the post-0019 keys: the group resolves from
        // the folded raw state. A broken group voids the overlays
        // wholesale (整组作废, ADR-0019 item 2).
        config.model.format = new_keys.format.unwrap_or(Format::OpenaiChat);
        config.model.thinking = if let Some(detail) = new_keys.broken {
            ConnectionThinking {
                state: ThinkingState::Broken(detail),
                overlays: Overlays::default(),
            }
        } else {
            let overlays = new_keys.overlays.unwrap_or_default();
            let state = match new_keys.switch {
                // Switch on needs a non-empty on-share to mean anything
                // (a save refuses the empty pair; a load reads it as
                // unconfigured).
                Some(true) if overlays.thinking_on.is_some() => ThinkingState::On,
                Some(false) => ThinkingState::Off,
                _ => ThinkingState::Unconfigured,
            };
            ConnectionThinking { state, overlays }
        };
    } else {
        // The read-time grandfather (ADR-0019 item 4): a legacy (or
        // bare-default) file set never touches disk — the dialect, the
        // custom overlay (awake only under the custom slot, ADR-0018's
        // dormancy), and the hold expand into the new keys here, byte
        // for byte, and the first connection-domain save writes them
        // down (the ratchet in `save_llm_connection`).
        let dialect = if config.model.vendor == Vendor::Custom {
            config.custom.thinking_dialect
        } else {
            config.model.vendor
        };
        let custom_extra = (config.model.vendor == Vendor::Custom)
            .then_some(config.custom.extra_body.as_ref())
            .flatten();
        let folded = presets::grandfather(dialect, custom_extra, config.legacy_extra_body.as_ref());
        config.model.format = folded.format;
        config.model.thinking = ConnectionThinking {
            state: ThinkingState::On,
            overlays: Overlays {
                body: None,
                thinking_on: (!folded.thinking_on.is_empty()).then_some(folded.thinking_on),
                thinking_off: (!folded.thinking_off.is_empty()).then_some(folded.thinking_off),
            },
        };
    }
    // Resolve the ACTIVE vendor's pair: its own slot first, the legacy
    // flat pair as the grandfather, the vendor's conventional env last.
    let resolved = config.resolved_keys(config.model.vendor);
    config.model.api_key = resolved.api_key;
    config.model.api_key_env = resolved.api_key_env;
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

// -- the [rectify] overlay: strict shape, hand-validated ---------------------

/// One layer's `[rectify]` overlay, already validated: every field the
/// section allows, none it does not.
#[derive(Debug, Default)]
struct RectifyOverlay {
    full: TierOverlay,
    light_touch: LightTouchOverlay,
    quick: QuickOverlay,
}

#[derive(Debug, Default)]
struct TierOverlay {
    thinking_policy: Option<ThinkingPolicy>,
    prefill: Option<bool>,
}

#[derive(Debug, Default)]
struct LightTouchOverlay {
    enabled: Option<bool>,
    max_chars: Option<usize>,
    tier: TierOverlay,
    extra_directive: Option<String>,
}

#[derive(Debug, Default)]
struct QuickOverlay {
    enabled: Option<bool>,
    rectify: Option<bool>,
    extra_directive: Option<String>,
}

/// Fold one validated `[rectify]` overlay onto the config, field by
/// field — the two tiers never touch each other (ADR-0015), and the
/// quick sub-section stands beside them: its keys land on `quick` alone,
/// whatever the tiers say (ADR-0020).
fn apply_rectify(config: &mut RectifyConfig, overlay: &RectifyOverlay) {
    if let Some(v) = overlay.full.thinking_policy {
        config.full.thinking_policy = v;
    }
    if let Some(v) = overlay.full.prefill {
        config.full.prefill = v;
    }
    if let Some(v) = overlay.light_touch.enabled {
        config.light_touch.enabled = v;
    }
    if let Some(v) = overlay.light_touch.max_chars {
        config.light_touch.max_chars = v;
    }
    if let Some(v) = overlay.light_touch.tier.thinking_policy {
        config.light_touch.tier.thinking_policy = v;
    }
    if let Some(v) = overlay.light_touch.tier.prefill {
        config.light_touch.tier.prefill = v;
    }
    if let Some(v) = &overlay.light_touch.extra_directive {
        config.light_touch.extra_directive = Some(v.clone());
    }
    if let Some(v) = overlay.quick.enabled {
        config.quick.enabled = v;
    }
    if let Some(v) = overlay.quick.rectify {
        config.quick.rectify = v;
    }
    if let Some(v) = &overlay.quick.extra_directive {
        config.quick.extra_directive = Some(v.clone());
    }
}

/// The strict `[rectify]` read (ADR-0015/0016/0020): the section allows
/// only `full` / `light_touch` / `quick`, each sub-section only its
/// listed keys, and every value must be exactly its type —
/// `thinking_policy` the three lowercase strings (never a bool),
/// `max_chars` an integer ≥ 1, `enabled` / `prefill` / `rectify`
/// booleans, `extra_directive` a string. Anything else fails the whole
/// load, naming the file and the section. The section is loaded raw and
/// validated here (not by serde) so the error can name the offending
/// sub-section.
fn load_rectify_layers(
    dirs: &[PathBuf],
) -> Result<Vec<spokenrectifier_config::Layer<RectifyOverlay>>, ConfigError> {
    let layers =
        load_section_layers::<toml::Table>(dirs, "rectify").map_err(|err| ConfigError(err.0))?;
    layers
        .iter()
        .map(|layer| {
            validate_rectify(&layer.value, layer.source.file_name()).map(|value| {
                spokenrectifier_config::Layer {
                    source: layer.source,
                    value,
                }
            })
        })
        .collect()
}

/// Validate one layer's raw `[rectify]` table into an overlay.
fn validate_rectify(table: &toml::Table, file: &str) -> Result<RectifyOverlay, ConfigError> {
    let mut overlay = RectifyOverlay::default();
    for (key, value) in table {
        match key.as_str() {
            "full" => {
                let sub = value.as_table().ok_or_else(|| {
                    ConfigError(format!("{file}: [rectify.full] must be a table"))
                })?;
                for (name, field) in sub {
                    match name.as_str() {
                        "thinking_policy" => {
                            overlay.full.thinking_policy =
                                Some(parse_policy(field, file, "rectify.full")?)
                        }
                        "prefill" => {
                            overlay.full.prefill =
                                Some(expect_bool(field, file, "rectify.full", "prefill")?)
                        }
                        other => {
                            return Err(unknown_key(
                                file,
                                "rectify.full",
                                other,
                                "`thinking_policy`, `prefill`",
                            ));
                        }
                    }
                }
            }
            "light_touch" => {
                let sub = value.as_table().ok_or_else(|| {
                    ConfigError(format!("{file}: [rectify.light_touch] must be a table"))
                })?;
                for (name, field) in sub {
                    match name.as_str() {
                        "enabled" => {
                            overlay.light_touch.enabled =
                                Some(expect_bool(field, file, "rectify.light_touch", "enabled")?)
                        }
                        "max_chars" => {
                            overlay.light_touch.max_chars =
                                Some(expect_max_chars(field, file, "rectify.light_touch")?)
                        }
                        "thinking_policy" => {
                            overlay.light_touch.tier.thinking_policy =
                                Some(parse_policy(field, file, "rectify.light_touch")?)
                        }
                        "prefill" => {
                            overlay.light_touch.tier.prefill =
                                Some(expect_bool(field, file, "rectify.light_touch", "prefill")?)
                        }
                        "extra_directive" => {
                            overlay.light_touch.extra_directive = Some(expect_string(
                                field,
                                file,
                                "rectify.light_touch",
                                "extra_directive",
                            )?)
                        }
                        other => {
                            return Err(unknown_key(
                                file,
                                "rectify.light_touch",
                                other,
                                "`enabled`, `max_chars`, `thinking_policy`, `prefill`, \
                                 `extra_directive`",
                            ));
                        }
                    }
                }
            }
            "quick" => {
                let sub = value.as_table().ok_or_else(|| {
                    ConfigError(format!("{file}: [rectify.quick] must be a table"))
                })?;
                for (name, field) in sub {
                    match name.as_str() {
                        "enabled" => {
                            overlay.quick.enabled =
                                Some(expect_bool(field, file, "rectify.quick", "enabled")?)
                        }
                        "rectify" => {
                            overlay.quick.rectify =
                                Some(expect_bool(field, file, "rectify.quick", "rectify")?)
                        }
                        "extra_directive" => {
                            overlay.quick.extra_directive = Some(expect_string(
                                field,
                                file,
                                "rectify.quick",
                                "extra_directive",
                            )?)
                        }
                        other => {
                            return Err(unknown_key(
                                file,
                                "rectify.quick",
                                other,
                                "`enabled`, `rectify`, `extra_directive`",
                            ));
                        }
                    }
                }
            }
            other => {
                return Err(unknown_key(
                    file,
                    "rectify",
                    other,
                    "`full`, `light_touch`, `quick`",
                ));
            }
        }
    }
    Ok(overlay)
}

/// One `thinking_policy` value: the three lowercase strings, nothing
/// else — a bool or a case variant is a loud refusal, never a silent
/// map (ADR-0015).
fn parse_policy(
    value: &toml::Value,
    file: &str,
    section: &str,
) -> Result<ThinkingPolicy, ConfigError> {
    let accepted = "the strings \"always\", \"placeholders\", or \"off\"";
    let text = value.as_str().ok_or_else(|| {
        ConfigError(format!(
            "{file}: [{section}]: thinking_policy accepts only {accepted} (lowercase), \
             never a boolean"
        ))
    })?;
    ThinkingPolicy::from_str_name(text).ok_or_else(|| {
        ConfigError(format!(
            "{file}: [{section}]: thinking_policy accepts only {accepted} (lowercase); \
             got \"{text}\""
        ))
    })
}

fn expect_bool(
    value: &toml::Value,
    file: &str,
    section: &str,
    field: &str,
) -> Result<bool, ConfigError> {
    value.as_bool().ok_or_else(|| {
        ConfigError(format!(
            "{file}: [{section}]: {field} must be a boolean (true/false)"
        ))
    })
}

fn expect_max_chars(value: &toml::Value, file: &str, section: &str) -> Result<usize, ConfigError> {
    let n = value.as_integer().ok_or_else(|| {
        ConfigError(format!(
            "{file}: [{section}]: max_chars must be a positive integer"
        ))
    })?;
    if n < 1 {
        return Err(ConfigError(format!(
            "{file}: [{section}]: max_chars must be a positive integer (at least 1); got {n}"
        )));
    }
    usize::try_from(n).map_err(|_| {
        ConfigError(format!(
            "{file}: [{section}]: max_chars {n} is out of range"
        ))
    })
}

fn expect_string(
    value: &toml::Value,
    file: &str,
    section: &str,
    field: &str,
) -> Result<String, ConfigError> {
    value
        .as_str()
        .map(String::from)
        .ok_or_else(|| ConfigError(format!("{file}: [{section}]: {field} must be a string")))
}

fn unknown_key(file: &str, section: &str, key: &str, allowed: &str) -> ConfigError {
    ConfigError(format!(
        "{file}: [{section}]: unknown key `{key}`; allowed: {allowed}"
    ))
}

// -- the settings editor's write path (ticket 19) ----------------------------

/// What the connection editor writes back: the GUI-managed subset of
/// `[llm]`. Values are the editor's whole model — saving writes exactly
/// these, so the next load returns what the user saw.
///
/// The open shape means the edit carries the WHOLE variable part of the
/// request (ADR-0019 items 1/2): the format axis, the 「设置思考字段」
/// switch, and the three overlays as the JSON text the pane's boxes
/// hold. The pane loads the resolved view — under a legacy file set
/// already the read-time grandfather's expansion — and hands it back, so
/// the ratchet writes down exactly the request bytes the old files
/// produced.
#[derive(Debug, Clone, PartialEq)]
pub struct LlmConnectionEdit {
    pub vendor: Vendor,
    pub base_url: String,
    pub model: String,
    /// The one behavioral axis (ADR-0019 item 1).
    pub format: Format,
    /// The 「设置思考字段」 switch. On requires a non-empty on-share:
    /// an on switch that turns nothing on is a mistake, not a stance
    /// (ADR-0019 item 2), so the save refuses the pair.
    pub thinking_fields: bool,
    /// The resident overlay's JSON text — merged into every request, and
    /// never blanked by a chip click.
    pub body_json: Option<String>,
    pub thinking_on_json: Option<String>,
    pub thinking_off_json: Option<String>,
    pub api_key: KeyEdit,
}

/// The sub-section a vendor's key slot lives in (`[llm.deepseek]`, …).
fn slot_section(vendor: Vendor) -> String {
    format!("llm.{}", vendor.as_str())
}

/// Write the connection editor's model back into the layer files. The
/// endpoint fields and the post-0019 keys land in the layer that owns
/// `[llm]` (section-preserving, one file for `[llm]` and
/// `[llm.overlays]` together); the key edit lands in THE EDIT'S
/// VENDOR's sub-section of the local file only — never the committable
/// shared file, whose loader rejects a key outright (the layering
/// ironclad, ADR-0008; per-vendor slots per ADR-0011).
///
/// Every save is the ratchet (ADR-0019 item 4): the new keys
/// (`format`/`thinking_fields`/`[llm.overlays]`) are written and every
/// legacy key retires — the dialect and both extra-body cabins strip
/// from every layer. The group written is the EDIT's, composed by the
/// caller from the loaded view; the read-time grandfather is what makes
/// that view equal to the old request bytes, so a legacy file set's
/// first save writes them down rather than re-deriving them here.
///
/// The legacy flat `[llm] api_key` pair is migrated first: it
/// authenticated the vendor the files named, so it parks in that
/// vendor's slot before this save re-routes the endpoint — switching
/// vendors never loses the old key — and the flat fields are then
/// stripped from every layer.
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
    // The three overlay boxes parse and shape-check up front (ADR-0018's
    // shape rule, ADR-0019's three boxes): a bad box refuses the whole
    // save before a single file is touched.
    let overlays = Overlays {
        body: parse_overlay(edit.body_json.as_deref(), "body")?,
        thinking_on: parse_overlay(edit.thinking_on_json.as_deref(), "thinking_on")?,
        thinking_off: parse_overlay(edit.thinking_off_json.as_deref(), "thinking_off")?,
    };
    // An on switch with an empty on-share would write a group that means
    // nothing (a load reads it straight back as unconfigured): refuse the
    // pair rather than write a switch that turns nothing on.
    if edit.thinking_fields && overlays.thinking_on.is_none() {
        return Err(ConfigError(
            "[llm.overlays] thinking_on is empty: the thinking-fields switch is on, so the \
             on-share must carry the thinking keys (or turn the switch off)"
                .into(),
        ));
    }
    // The migration needs to know which vendor the flat pair
    // authenticated; a malformed layer refuses the whole save, exactly
    // like the write path below.
    let current = load_llm_config(dirs)?;
    // A malformed thinking group refuses the save whole, before a single
    // file is touched: the ratchet cannot truthfully rewrite a group it
    // cannot read, and destroying it is worse than refusing (the
    // zero-write refusal, ADR-0018 precedent).
    if let ThinkingState::Broken(detail) = &current.model.thinking.state {
        return Err(ConfigError(format!(
            "[llm] the thinking fields are malformed and cannot be saved; fix the file \
             first: {detail}"
        )));
    }
    let previous = current.model.vendor;
    let previous_slot = current
        .vendor_keys
        .get(&previous)
        .cloned()
        .unwrap_or_default();
    if previous_slot.api_key.as_deref().is_none_or(str::is_empty) {
        let resolved = current.resolved_keys(previous);
        if let Some(key) = resolved.api_key.filter(|key| !key.is_empty()) {
            KeyEdit::Set(key)
                .write_to_local(dirs, &slot_section(previous), "api_key")
                .map_err(|err| ConfigError(err.0))?;
        }
        if previous_slot.api_key_env.is_none()
            && let Some(env) = current.legacy_flat.api_key_env
        {
            spokenrectifier_config::section_write::write_section_fields(
                dirs,
                &slot_section(previous),
                &[SectionField::str("api_key_env", env)],
                WriteLayer::Local,
            )
            .map_err(|err| ConfigError(err.0))?;
        }
    }
    // The shares' shapes validate before any write — the same refusal
    // the write itself would raise, but with nothing written first.
    for share in [
        &overlays.body,
        &overlays.thinking_on,
        &overlays.thinking_off,
    ]
    .into_iter()
    .flatten()
    {
        validate_json_table_shape(share)
            .map_err(|err| ConfigError(format!("[llm.overlays] {}", err.0)))?;
    }
    // One layer file for the whole common segment: `[llm]` and
    // `[llm.overlays]` land together, wherever `[llm]` lives.
    let owner = owning_layer(dirs, "llm");
    let mut fields = vec![
        SectionField::str("vendor", edit.vendor.as_str()),
        SectionField::str("base_url", base_url),
        SectionField::str("model", model),
        SectionField::str("format", edit.format.as_str()),
        SectionField::bool("thinking_fields", edit.thinking_fields),
    ];
    // The flat pair is parked above; the legacy hold folded into the
    // shares — both strip from every layer here.
    fields.push(SectionField::reset("api_key"));
    fields.push(SectionField::reset("api_key_env"));
    fields.push(SectionField::reset("extra_body"));
    write_section_fields(dirs, "llm", &fields, owner).map_err(|err| ConfigError(err.0))?;
    let overlay_field = |name: &str, share: &Option<Map<String, Value>>| match share {
        Some(map) => SectionField::Table {
            name: name.into(),
            value: map.clone(),
        },
        None => SectionField::reset(name),
    };
    write_section_fields(
        dirs,
        "llm.overlays",
        &[
            overlay_field("body", &overlays.body),
            overlay_field("thinking_on", &overlays.thinking_on),
            overlay_field("thinking_off", &overlays.thinking_off),
        ],
        owner,
    )
    .map_err(|err| ConfigError(err.0))?;
    // `[llm.custom]` shrinks to the pure key slot (ADR-0019 item 4):
    // the restore cache, dialect, and overlay cabins strip from every
    // layer; the slot's key pair rides untouched.
    write_section_fields(
        dirs,
        "llm.custom",
        &[
            SectionField::reset("base_url"),
            SectionField::reset("model"),
            SectionField::reset("thinking_dialect"),
            SectionField::reset("extra_body"),
        ],
        WriteLayer::Owning,
    )
    .map_err(|err| ConfigError(err.0))?;
    edit.api_key
        .clone()
        .write_to_local(dirs, &slot_section(edit.vendor), "api_key")
        .map_err(|err| ConfigError(err.0))?;
    Ok(())
}

/// One overlay box's JSON text (ADR-0018's shape rule, ADR-0019's three
/// boxes): blank or `{}` = no overlay; a non-object root or a JSON shape
/// TOML cannot render refuses the save, naming the share.
fn parse_overlay(
    text: Option<&str>,
    share: &str,
) -> Result<Option<serde_json::Map<String, Value>>, ConfigError> {
    let Some(text) = text.map(str::trim).filter(|text| !text.is_empty()) else {
        return Ok(None);
    };
    let value: Value = serde_json::from_str(text)
        .map_err(|err| ConfigError(format!("[llm.overlays] {share} is not valid JSON: {err}")))?;
    let map = value.as_object().ok_or_else(|| {
        ConfigError(format!(
            "[llm.overlays] {share} must be a JSON object (the request-body overlay)"
        ))
    })?;
    if map.is_empty() {
        return Ok(None); // the empty object is the off form, like blank
    }
    spokenrectifier_config::section_write::validate_json_table_shape(map)
        .map_err(|err| ConfigError(format!("[llm.overlays] {share}: {}", err.0)))?;
    Ok(Some(map.clone()))
}

// -- the rectify editor's write path (ticket 13) ------------------------------

/// One tier's editor fields, mirroring `[rectify.full]` (and the
/// light-touch tier's policy/prefill pair).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TierEdit {
    pub thinking_policy: ThinkingPolicy,
    pub prefill: bool,
}

/// The light-touch tier's editor fields, mirroring
/// `[rectify.light_touch]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LightTouchEdit {
    pub enabled: bool,
    pub max_chars: usize,
    pub tier: TierEdit,
    /// The extra directive's text; `None` or blank = unset (the key is
    /// removed — empty is the off form, ADR-0016).
    pub extra_directive: Option<String>,
}

/// The quick-mode editor fields, mirroring `[rectify.quick]` (ADR-0020).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickEdit {
    /// The quick-mode master switch (off = no hold upgrades a session).
    pub enabled: bool,
    /// Whether a quick session rectifies or pastes the raw transcript.
    pub rectify: bool,
    /// The quick extra directive's text; `None` or blank = unset (the
    /// key is removed — empty is the off form, ADR-0016's shape).
    pub extra_directive: Option<String>,
}

/// What the rectify editor writes back: the whole `[rectify]` model —
/// both tiers, the gate, the extra directive, and the quick sub-section.
/// Saving writes exactly this, so the next load returns what the user
/// saw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RectifyBehaviorEdit {
    pub full: TierEdit,
    pub light_touch: LightTouchEdit,
    pub quick: QuickEdit,
}

impl RectifyBehaviorEdit {
    fn tier_fields(tier: &TierEdit) -> Vec<SectionField> {
        vec![
            SectionField::str("thinking_policy", tier.thinking_policy.as_str()),
            SectionField::bool("prefill", tier.prefill),
        ]
    }
}

/// Write the rectify editor's model back into the layer files. The
/// model lands in the layer that owns each `[rectify.*]` sub-section
/// (the shared file when none does); every extra directive's blank form
/// removes the key. Three sub-sections ride one save: `full`,
/// `light_touch`, and — since ADR-0020 — `quick`.
///
/// The first rectify-domain save also retires the legacy `[llm]`
/// `thinking` / `prefill` / `light_touch_max_chars` keys, per layer
/// (ADR-0015): whichever layer file carries an old key gets its
/// translation written into that same layer (a local `thinking =
/// false` becomes local `[rectify]` policy "off", never promoted into
/// the committable shared file), then the old keys are stripped from
/// every layer. A same-layer new key already present is not clobbered
/// by the translation. Never opening the rectify domain leaves the old
/// keys readable forever — zero migration.
pub fn save_rectify_behavior(
    dirs: &[PathBuf],
    edit: &RectifyBehaviorEdit,
) -> Result<(), ConfigError> {
    if edit.light_touch.max_chars < 1 {
        return Err(ConfigError(
            "[rectify.light_touch] max_chars must be a positive integer (at least 1)".into(),
        ));
    }
    // The migration scan: which layers carry which legacy keys, and
    // which same-layer new keys already shadow them.
    let llm_layers =
        load_section_layers::<LlmSection>(dirs, "llm").map_err(|err| ConfigError(err.0))?;
    let rectify_layers = load_rectify_layers(dirs)?;
    for source in [LayerSource::Shared, LayerSource::Local] {
        let layer = match source {
            LayerSource::Shared => WriteLayer::Shared,
            LayerSource::Local => WriteLayer::Local,
        };
        let Some(llm) = llm_layers.iter().find(|l| l.source == source) else {
            continue;
        };
        let rectify = rectify_layers
            .iter()
            .find(|l| l.source == source)
            .map(|l| &l.value);
        let mut full_fields = Vec::new();
        let mut light_fields = Vec::new();
        if let Some(on) = llm.value.thinking {
            let policy = ThinkingPolicy::from_legacy_bool(on);
            if rectify.and_then(|r| r.full.thinking_policy).is_none() {
                full_fields.push(SectionField::str("thinking_policy", policy.as_str()));
            }
            if rectify
                .and_then(|r| r.light_touch.tier.thinking_policy)
                .is_none()
            {
                light_fields.push(SectionField::str("thinking_policy", policy.as_str()));
            }
        }
        if let Some(on) = llm.value.prefill {
            if rectify.and_then(|r| r.full.prefill).is_none() {
                full_fields.push(SectionField::bool("prefill", on));
            }
            if rectify.and_then(|r| r.light_touch.tier.prefill).is_none() {
                light_fields.push(SectionField::bool("prefill", on));
            }
        }
        if let Some(n) = llm.value.light_touch_max_chars
            && rectify.and_then(|r| r.light_touch.max_chars).is_none()
        {
            light_fields.push(SectionField::int("max_chars", n as i64));
        }
        if !full_fields.is_empty() {
            write_section_fields(dirs, "rectify.full", &full_fields, layer)
                .map_err(|err| ConfigError(err.0))?;
        }
        if !light_fields.is_empty() {
            write_section_fields(dirs, "rectify.light_touch", &light_fields, layer)
                .map_err(|err| ConfigError(err.0))?;
        }
    }
    // The old keys go, from every layer (a reset strips them all).
    write_section_fields(
        dirs,
        "llm",
        &[
            SectionField::reset("thinking"),
            SectionField::reset("prefill"),
            SectionField::reset("light_touch_max_chars"),
        ],
        WriteLayer::Owning,
    )
    .map_err(|err| ConfigError(err.0))?;
    // The editor's whole model, into the owning layers (now possibly
    // the layer the translation just created).
    write_section_fields(
        dirs,
        "rectify.full",
        &RectifyBehaviorEdit::tier_fields(&edit.full),
        WriteLayer::Owning,
    )
    .map_err(|err| ConfigError(err.0))?;
    write_section_fields(
        dirs,
        "rectify.light_touch",
        &[
            SectionField::bool("enabled", edit.light_touch.enabled),
            SectionField::int("max_chars", edit.light_touch.max_chars as i64),
            SectionField::str(
                "thinking_policy",
                edit.light_touch.tier.thinking_policy.as_str(),
            ),
            SectionField::bool("prefill", edit.light_touch.tier.prefill),
            directive_field(edit.light_touch.extra_directive.as_deref()),
        ],
        WriteLayer::Owning,
    )
    .map_err(|err| ConfigError(err.0))?;
    // The quick sub-section rides the same whole-model write (ADR-0020):
    // its three keys, no tier keys.
    write_section_fields(
        dirs,
        "rectify.quick",
        &[
            SectionField::bool("enabled", edit.quick.enabled),
            SectionField::bool("rectify", edit.quick.rectify),
            directive_field(edit.quick.extra_directive.as_deref()),
        ],
        WriteLayer::Owning,
    )
    .map_err(|err| ConfigError(err.0))?;
    Ok(())
}

/// One extra directive's write form: blank (`None`, empty, or
/// all-whitespace) removes the key rather than storing an empty string —
/// empty is the off form (ADR-0016).
fn directive_field(edit: Option<&str>) -> SectionField {
    match edit.filter(|text| !text.trim().is_empty()) {
        Some(text) => SectionField::str("extra_directive", text),
        None => SectionField::reset("extra_directive"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_single_model_deepseek() {
        let config = LlmConfig::defaults();
        // Today's rectify behavior on every field (zero migration).
        assert_eq!(config.rectify.full.thinking_policy, ThinkingPolicy::Always);
        assert!(config.rectify.full.prefill);
        assert!(config.rectify.light_touch.enabled);
        assert_eq!(config.rectify.light_touch.max_chars, 40);
        assert_eq!(
            config.rectify.light_touch.tier.thinking_policy,
            ThinkingPolicy::Always
        );
        assert!(config.rectify.light_touch.tier.prefill);
        assert_eq!(config.rectify.light_touch.extra_directive, None);
        // Quick mode is stored but off — no hold upgrades anything —
        // and rectifies whenever it is turned on (ADR-0020).
        assert!(!config.rectify.quick.enabled);
        assert!(config.rectify.quick.rectify);
        assert_eq!(config.rectify.quick.extra_directive, None);
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
            "[llm]\nthinking = false\nmodel = \"deepseek-v4-pro\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[llm]\napi_key = \"sk-local\"\n",
        )
        .unwrap();

        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        // The grandfather: shared thinking=false maps onto BOTH tiers.
        assert_eq!(config.rectify.full.thinking_policy, ThinkingPolicy::Off);
        assert_eq!(
            config.rectify.light_touch.tier.thinking_policy,
            ThinkingPolicy::Off
        ); // shared file overrides the on default
        assert_eq!(config.model.model, "deepseek-v4-pro"); // shared file
        assert_eq!(config.model.api_key.as_deref(), Some("sk-local")); // local wins
        assert_eq!(config.model.base_url, "https://api.deepseek.com"); // untouched default
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The prefill key defaults on (today's behavior, zero migration),
    /// layers like every prompt knob through the grandfather — shared
    /// off, local back on, local wins — and never marks endpoint intent:
    /// a user toggling the prompt form has not configured a real model.
    #[test]
    fn prefill_defaults_on_and_layers_without_endpoint_intent() {
        let dir = std::env::temp_dir().join("sr-llm-config-test-prefill");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let dirs = std::slice::from_ref(&dir);

        // No files at all: the default is on.
        assert!(load_llm_config(dirs).unwrap().rectify.full.prefill);

        std::fs::write(dir.join("spokenrectifier.toml"), "[llm]\nprefill = false\n").unwrap();
        let config = load_llm_config(dirs).unwrap();
        assert!(!config.rectify.full.prefill); // shared overrides the on default
        assert!(!config.endpoint_configured); // a prompt knob, not intent

        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[llm]\nprefill = true\n",
        )
        .unwrap();
        assert!(load_llm_config(dirs).unwrap().rectify.full.prefill); // local wins
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_non_boolean_prefill_is_rejected_naming_the_file_and_section() {
        let dir = std::env::temp_dir().join("sr-llm-config-test-prefill-type");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[llm]\nprefill = \"yes\"\n",
        )
        .unwrap();

        let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
        assert!(err.contains("spokenrectifier.toml"), "got: {err}");
        assert!(err.contains("llm"), "got: {err}");
        // Single line only: a multi-line error is a quoted source snippet.
        assert!(!err.contains('\n'), "multi-line error: {err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    // -- the [rectify] section (ADR-0015/0016) ----------------------------

    #[test]
    fn rectify_sections_layer_field_by_field_and_local_wins() {
        let dir = scratch("sr-llm-rectify-layers");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[rectify.full]\nthinking_policy = \"off\"\nprefill = false\n\
             [rectify.light_touch]\nmax_chars = 80\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[rectify.full]\nthinking_policy = \"placeholders\"\n",
        )
        .unwrap();

        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        // Local wins where it speaks; shared carries the rest; the two
        // tiers never inherit from each other.
        assert_eq!(
            config.rectify.full.thinking_policy,
            ThinkingPolicy::Placeholders
        ); // local wins
        assert!(!config.rectify.full.prefill); // shared only
        assert_eq!(config.rectify.light_touch.max_chars, 80); // shared only
        assert_eq!(
            config.rectify.light_touch.tier.thinking_policy,
            ThinkingPolicy::Always
        ); // untouched default
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A same layer's new key beats its own legacy key; the tier without
    /// a new key still takes the grandfather value — nothing is copied
    /// across tiers.
    #[test]
    fn a_same_layer_new_key_beats_the_legacy_key_per_tier() {
        let dir = scratch("sr-llm-rectify-same-layer");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[llm]\nthinking = false\n\
             [rectify.full]\nthinking_policy = \"always\"\n",
        )
        .unwrap();

        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.rectify.full.thinking_policy, ThinkingPolicy::Always);
        assert_eq!(
            config.rectify.light_touch.tier.thinking_policy,
            ThinkingPolicy::Off
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A deeper layer's legacy key beats a shallower layer's new key:
    /// the fold is per layer, shared first, so local wins whatever it
    /// says (ADR-0015's layering, applied across the two sections).
    #[test]
    fn a_deeper_legacy_key_beats_a_shallower_new_key() {
        let dir = scratch("sr-llm-rectify-deep-legacy");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[rectify.full]\nthinking_policy = \"off\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[llm]\nthinking = true\n",
        )
        .unwrap();

        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.rectify.full.thinking_policy, ThinkingPolicy::Always);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_boolean_thinking_policy_is_rejected_naming_file_and_section() {
        let dir = scratch("sr-llm-rectify-policy-bool");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[rectify.full]\nthinking_policy = true\n",
        )
        .unwrap();
        let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
        assert!(err.contains("spokenrectifier.toml"), "got: {err}");
        assert!(err.contains("[rectify.full]"), "got: {err}");
        assert!(err.contains("never a boolean"), "got: {err}");
        assert!(!err.contains('\n'), "multi-line error: {err}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn policy_case_variants_and_unknown_names_are_rejected() {
        for bad in ["Always", "ALWAYS", "", "sometimes"] {
            let dir = scratch("sr-llm-rectify-policy-name");
            std::fs::write(
                dir.join("spokenrectifier.local.toml"),
                format!("[rectify.light_touch]\nthinking_policy = \"{bad}\"\n"),
            )
            .unwrap();
            let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
            assert!(err.contains("[rectify.light_touch]"), "{bad}: got: {err}");
            assert!(!err.contains('\n'), "{bad}: multi-line: {err}");
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn unknown_sub_sections_and_keys_are_rejected() {
        for (name, body) in [
            (
                "sub-section",
                "[rectify.middle]\nthinking_policy = \"off\"\n",
            ),
            ("full key", "[rectify.full]\nextra = 1\n"),
            ("light_touch key", "[rectify.light_touch]\nthreshold = 40\n"),
            // Quick mode has no tier keys: its three are the whole
            // sub-section (ADR-0020), so a tier key here is a refusal
            // like any other unknown key.
            ("quick key", "[rectify.quick]\nthinking_policy = \"off\"\n"),
        ] {
            let dir = scratch("sr-llm-rectify-unknown");
            std::fs::write(dir.join("spokenrectifier.toml"), body).unwrap();
            let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
            assert!(err.contains("unknown key"), "{name}: got: {err}");
            assert!(err.contains("spokenrectifier.toml"), "{name}: got: {err}");
            assert!(!err.contains('\n'), "{name}: multi-line: {err}");
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn a_non_positive_or_non_integer_max_chars_is_rejected() {
        for (name, value) in [
            ("zero", "0"),
            ("negative", "-5"),
            ("float", "1.5"),
            ("text", "\"x\""),
        ] {
            let dir = scratch("sr-llm-rectify-max-chars");
            std::fs::write(
                dir.join("spokenrectifier.toml"),
                format!("[rectify.light_touch]\nmax_chars = {value}\n"),
            )
            .unwrap();
            let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
            assert!(err.contains("[rectify.light_touch]"), "{name}: got: {err}");
            assert!(err.contains("max_chars"), "{name}: got: {err}");
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn non_boolean_gates_are_rejected() {
        for (name, body) in [
            ("enabled", "[rectify.light_touch]\nenabled = \"on\"\n"),
            ("prefill", "[rectify.full]\nprefill = 1\n"),
            ("quick enabled", "[rectify.quick]\nenabled = \"on\"\n"),
            ("quick rectify", "[rectify.quick]\nrectify = 1\n"),
        ] {
            let dir = scratch("sr-llm-rectify-gate-type");
            std::fs::write(dir.join("spokenrectifier.toml"), body).unwrap();
            let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
            assert!(err.contains("must be a boolean"), "{name}: got: {err}");
            assert!(!err.contains('\n'), "{name}: multi-line: {err}");
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn a_non_string_extra_directive_is_rejected() {
        let dir = scratch("sr-llm-rectify-extra-type");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[rectify.light_touch]\nextra_directive = 3\n",
        )
        .unwrap();
        let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
        assert!(err.contains("[rectify.light_touch]"), "got: {err}");
        assert!(
            err.contains("extra_directive must be a string"),
            "got: {err}"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Missing, empty, and all-whitespace extra directives all read as
    /// unset; a local blank still overrides a shared text into nothing
    /// (the field-by-field layering applies to the blank form too).
    #[test]
    fn blank_extra_directives_read_as_unset_and_layer_like_any_field() {
        let dir = scratch("sr-llm-rectify-extra-blank");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[rectify.light_touch]\nextra_directive = \"短句尽量保留术语\"\n",
        )
        .unwrap();
        let loaded = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(
            loaded.rectify.light_touch.extra_directive.as_deref(),
            Some("短句尽量保留术语")
        );

        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[rectify.light_touch]\nextra_directive = \"  \"\n",
        )
        .unwrap();
        let loaded = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(loaded.rectify.light_touch.extra_directive, None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The eval copy never carries the user's directive text (ADR-0016;
    /// ADR-0020 for the quick key, which is the same stance).
    #[test]
    fn for_eval_strips_the_extra_directive() {
        let mut config = LlmConfig::defaults();
        config.rectify.light_touch.extra_directive = Some("用户的私货".into());
        config.rectify.quick.extra_directive = Some("快速私货".into());
        let eval = config.clone().for_eval();
        assert_eq!(eval.rectify.light_touch.extra_directive, None);
        assert_eq!(eval.rectify.quick.extra_directive, None);
        // The source config is untouched.
        assert_eq!(
            config.rectify.light_touch.extra_directive.as_deref(),
            Some("用户的私货")
        );
        assert_eq!(
            config.rectify.quick.extra_directive.as_deref(),
            Some("快速私货")
        );
    }

    // -- the [rectify.quick] sub-section (ADR-0020) ------------------------

    /// The quick keys layer field by field like every other key, local
    /// last; a file that never speaks them leaves the master switch off
    /// — today's gesture, unchanged.
    #[test]
    fn quick_keys_layer_field_by_field_and_default_to_off() {
        let dir = scratch("sr-llm-quick-layers");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[rectify.quick]\nenabled = true\nextra_directive = \"短句留节奏\"\n",
        )
        .unwrap();

        // Shared only: the keys it names, the defaults for the rest.
        let shared = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert!(shared.rectify.quick.enabled);
        assert!(shared.rectify.quick.rectify); // untouched default
        assert_eq!(
            shared.rectify.quick.extra_directive.as_deref(),
            Some("短句留节奏")
        );

        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[rectify.quick]\nrectify = false\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert!(config.rectify.quick.enabled); // shared only
        assert!(!config.rectify.quick.rectify); // local wins
        // The quick keys never touch the tiers, and the tiers never touch
        // quick: they are three separate sub-sections.
        assert!(config.rectify.light_touch.enabled);
        assert_eq!(config.rectify.light_touch.max_chars, 40);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The quick directive's blank forms read as unset and layer like
    /// any field — a local blank still overrides a shared text into
    /// nothing (ADR-0016's shape, on the quick key).
    #[test]
    fn a_blank_quick_extra_directive_reads_as_unset() {
        let dir = scratch("sr-llm-quick-extra-blank");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[rectify.quick]\nextra_directive = \"短句留节奏\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[rectify.quick]\nextra_directive = \"   \"\n",
        )
        .unwrap();

        let loaded = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(loaded.rectify.quick.extra_directive, None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_non_string_quick_extra_directive_is_rejected() {
        let dir = scratch("sr-llm-quick-extra-type");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[rectify.quick]\nextra_directive = 3\n",
        )
        .unwrap();
        let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
        assert!(err.contains("[rectify.quick]"), "got: {err}");
        assert!(
            err.contains("extra_directive must be a string"),
            "got: {err}"
        );
        assert!(!err.contains('\n'), "multi-line error: {err}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A non-table `[rectify.quick]` (`quick = 3`, or a dotted-key
    /// collision) refuses the load like every other sub-section.
    #[test]
    fn a_non_table_quick_sub_section_is_rejected() {
        let dir = scratch("sr-llm-quick-non-table");
        std::fs::write(dir.join("spokenrectifier.toml"), "[rectify]\nquick = 3\n").unwrap();
        let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
        assert!(
            err.contains("[rectify.quick] must be a table"),
            "got: {err}"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    // -- the rectify editor's write path (ticket 13) ----------------------

    use super::{LightTouchEdit, QuickEdit, RectifyBehaviorEdit, TierEdit, save_rectify_behavior};

    fn behavior_edit() -> RectifyBehaviorEdit {
        RectifyBehaviorEdit {
            full: TierEdit {
                thinking_policy: ThinkingPolicy::Always,
                prefill: true,
            },
            quick: QuickEdit {
                enabled: false,
                rectify: true,
                extra_directive: None,
            },
            light_touch: LightTouchEdit {
                enabled: true,
                max_chars: 40,
                tier: TierEdit {
                    thinking_policy: ThinkingPolicy::Always,
                    prefill: true,
                },
                extra_directive: None,
            },
        }
    }

    /// A save with no layers at all creates the shared file carrying
    /// the whole model, and the load returns exactly what was saved.
    #[test]
    fn a_fresh_rectify_save_round_trips_through_the_shared_file() {
        let dir = scratch("sr-llm-rectify-save-fresh");
        let mut edit = behavior_edit();
        edit.light_touch.max_chars = 60;
        edit.light_touch.tier.thinking_policy = ThinkingPolicy::Placeholders;
        edit.light_touch.extra_directive = Some("短句更口语一点".into());

        save_rectify_behavior(std::slice::from_ref(&dir), &edit).unwrap();

        let shared = std::fs::read_to_string(dir.join("spokenrectifier.toml")).unwrap();
        assert!(shared.contains("[rectify.full]"), "got: {shared}");
        assert!(
            shared.contains("thinking_policy = \"placeholders\""),
            "got: {shared}"
        );
        assert!(shared.contains("max_chars = 60"), "got: {shared}");
        assert!(
            shared.contains("extra_directive = \"短句更口语一点\""),
            "got: {shared}"
        );
        assert!(!dir.join("spokenrectifier.local.toml").exists());
        let loaded = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(loaded.rectify.light_touch.max_chars, 60);
        assert_eq!(
            loaded.rectify.light_touch.tier.thinking_policy,
            ThinkingPolicy::Placeholders
        );
        assert_eq!(
            loaded.rectify.light_touch.extra_directive.as_deref(),
            Some("短句更口语一点")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The first rectify-domain save retires the legacy keys per layer:
    /// a local `thinking = false` becomes local `[rectify]` policy
    /// "off" — never promoted into the committable shared file — and
    /// the old keys are stripped from every layer. The editor's model
    /// is the loaded (grandfathered) state, so translation and whole-
    /// model write agree; the translation's job is PLACEMENT, making
    /// the owning resolution land the model in the legacy key's layer.
    #[test]
    fn a_first_save_translates_legacy_keys_in_their_own_layer() {
        let dir = scratch("sr-llm-rectify-save-translate");
        std::fs::write(dir.join("spokenrectifier.toml"), "[llm]\nmodel = \"m\"\n").unwrap();
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[llm]\nthinking = false\nprefill = false\nlight_touch_max_chars = 25\n",
        )
        .unwrap();
        // What the pane painted from the load: the grandfathered state.
        let mut edit = behavior_edit();
        edit.full.thinking_policy = ThinkingPolicy::Off;
        edit.full.prefill = false;
        edit.light_touch.tier.thinking_policy = ThinkingPolicy::Off;
        edit.light_touch.tier.prefill = false;
        edit.light_touch.max_chars = 25;

        save_rectify_behavior(std::slice::from_ref(&dir), &edit).unwrap();

        let shared = std::fs::read_to_string(dir.join("spokenrectifier.toml")).unwrap();
        // No value the user had in local reaches the committable file.
        // The quick sub-section is the exception that proves the rule:
        // it is new, so it has no legacy key to follow into local — its
        // own write lands on the shared default layer, carrying the file
        // defaults and nothing else (ADR-0020).
        for key in ["thinking_policy", "prefill", "max_chars", "extra_directive"] {
            assert!(
                !shared.contains(key),
                "a local value was promoted into shared: {shared}"
            );
        }
        let quick = section(&shared, "[rectify.quick]");
        assert_eq!(
            quick.trim(),
            "enabled = false\nrectify = true",
            "the quick write carried more than its defaults: {quick}"
        );
        assert!(shared.contains("model = \"m\""), "sibling lost: {shared}");
        let local = std::fs::read_to_string(dir.join("spokenrectifier.local.toml")).unwrap();
        assert!(
            local.contains("thinking_policy = \"off\""),
            "policy not translated: {local}"
        );
        assert!(local.contains("prefill = false"), "got: {local}");
        assert!(local.contains("max_chars = 25"), "got: {local}");
        assert!(
            !local.contains("thinking ="),
            "legacy key survived: {local}"
        );
        assert!(
            !local.contains("light_touch_max_chars"),
            "legacy key survived: {local}"
        );
        // The load no longer leans on the grandfather: the translated
        // keys alone carry the behavior.
        let loaded = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(loaded.rectify.full.thinking_policy, ThinkingPolicy::Off);
        assert!(!loaded.rectify.full.prefill);
        assert_eq!(loaded.rectify.light_touch.max_chars, 25);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A same-layer new key already present is not clobbered by the
    /// translation; only the tiers without a new key inherit the
    /// translated legacy value. The whole-model write then carries the
    /// loaded state verbatim — pre-existing new key included.
    #[test]
    fn a_translation_never_clobbers_a_same_layer_new_key() {
        let dir = scratch("sr-llm-rectify-save-no-clobber");
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[llm]\nthinking = false\n\
             [rectify.light_touch]\nthinking_policy = \"placeholders\"\n",
        )
        .unwrap();
        // The loaded state: light-touch keeps its own policy, full takes
        // the grandfather's.
        let mut edit = behavior_edit();
        edit.full.thinking_policy = ThinkingPolicy::Off;
        edit.light_touch.tier.thinking_policy = ThinkingPolicy::Placeholders;

        save_rectify_behavior(std::slice::from_ref(&dir), &edit).unwrap();

        let local = std::fs::read_to_string(dir.join("spokenrectifier.local.toml")).unwrap();
        // Exactly one policy line per tier, the loaded values.
        assert_eq!(
            local.matches("thinking_policy").count(),
            2,
            "expected one per tier: {local}"
        );
        assert!(
            local.contains("thinking_policy = \"placeholders\""),
            "new key clobbered: {local}"
        );
        assert!(
            local.contains("thinking_policy = \"off\""),
            "translation missing: {local}"
        );
        assert!(
            !local.contains("thinking ="),
            "legacy key survived: {local}"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A blank extra directive save removes the key: empty is the off
    /// form, not a stored empty string.
    #[test]
    fn a_blank_extra_directive_save_removes_the_key() {
        let dir = scratch("sr-llm-rectify-save-blank-extra");
        std::fs::write(
            dir.join("spokenrectifier.toml"),
            "[rectify.light_touch]\nextra_directive = \"旧指令\"\n",
        )
        .unwrap();

        save_rectify_behavior(std::slice::from_ref(&dir), &behavior_edit()).unwrap();

        let shared = std::fs::read_to_string(dir.join("spokenrectifier.toml")).unwrap();
        assert!(!shared.contains("extra_directive"), "not removed: {shared}");
        assert_eq!(
            load_llm_config(std::slice::from_ref(&dir))
                .unwrap()
                .rectify
                .light_touch
                .extra_directive,
            None
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The quick sub-section rides the same whole-model save: its three
    /// keys written beside the tiers, a blank directive removing the key
    /// rather than storing an empty string (ADR-0020).
    #[test]
    fn a_quick_save_round_trips_and_a_blank_directive_removes_the_key() {
        let dir = scratch("sr-llm-quick-save");
        let dirs = std::slice::from_ref(&dir);
        let mut edit = behavior_edit();
        edit.quick.enabled = true;
        edit.quick.rectify = false;
        edit.quick.extra_directive = Some("短句留节奏".into());

        save_rectify_behavior(dirs, &edit).unwrap();

        let shared = std::fs::read_to_string(dir.join("spokenrectifier.toml")).unwrap();
        let quick = section(&shared, "[rectify.quick]");
        assert!(quick.contains("enabled = true"), "got: {quick}");
        assert!(quick.contains("rectify = false"), "got: {quick}");
        assert!(
            quick.contains("extra_directive = \"短句留节奏\""),
            "got: {quick}"
        );
        // No tier key leaked into the quick sub-section.
        assert!(!quick.contains("thinking_policy"), "got: {quick}");
        assert!(!quick.contains("prefill"), "got: {quick}");
        assert!(!quick.contains("max_chars"), "got: {quick}");
        let loaded = load_llm_config(dirs).unwrap();
        assert!(loaded.rectify.quick.enabled);
        assert!(!loaded.rectify.quick.rectify);
        assert_eq!(
            loaded.rectify.quick.extra_directive.as_deref(),
            Some("短句留节奏")
        );

        // A blank directive save removes the key and leaves the two
        // boolean gates exactly where they were.
        let mut blank = edit.clone();
        blank.quick.extra_directive = Some("   ".into());
        save_rectify_behavior(dirs, &blank).unwrap();
        let shared = std::fs::read_to_string(dir.join("spokenrectifier.toml")).unwrap();
        let quick = section(&shared, "[rectify.quick]");
        assert!(!quick.contains("extra_directive"), "not removed: {quick}");
        let loaded = load_llm_config(dirs).unwrap();
        assert_eq!(loaded.rectify.quick.extra_directive, None);
        assert!(loaded.rectify.quick.enabled, "the master switch was lost");
        assert!(!loaded.rectify.quick.rectify, "the rectify gate was lost");
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A disabled master switch still saves every light-touch key: off
    /// is a runtime stance, not a deletion (ADR-0015).
    #[test]
    fn a_disabled_master_switch_still_stores_the_tier() {
        let dir = scratch("sr-llm-rectify-save-disabled");
        let mut edit = behavior_edit();
        edit.light_touch.enabled = false;
        edit.light_touch.max_chars = 15;

        save_rectify_behavior(std::slice::from_ref(&dir), &edit).unwrap();

        let shared = std::fs::read_to_string(dir.join("spokenrectifier.toml")).unwrap();
        assert!(shared.contains("enabled = false"), "got: {shared}");
        assert!(shared.contains("max_chars = 15"), "got: {shared}");
        let loaded = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert!(!loaded.rectify.light_touch.enabled);
        assert_eq!(loaded.rectify.light_touch.max_chars, 15);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_zero_max_chars_save_is_refused_writing_nothing() {
        let dir = scratch("sr-llm-rectify-save-bad");
        let mut edit = behavior_edit();
        edit.light_touch.max_chars = 0;

        let err = save_rectify_behavior(std::slice::from_ref(&dir), &edit)
            .unwrap_err()
            .0;
        assert!(err.contains("max_chars"), "got: {err}");
        assert!(
            !dir.join("spokenrectifier.toml").exists(),
            "wrote on refusal"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The connection editor never touches the rectify keys: a vendor
    /// switch save leaves a legacy `thinking` exactly where it was.
    #[test]
    fn a_connection_save_leaves_the_rectify_keys_alone() {
        let dir = scratch("sr-llm-rectify-connection-untouched");
        std::fs::write(
            dir.join("spokenrectifier.local.toml"),
            "[llm]\nthinking = false\nmodel = \"deepseek-v4-flash\"\n",
        )
        .unwrap();

        save_llm_connection(std::slice::from_ref(&dir), &edit(KeyEdit::Keep)).unwrap();

        let local = std::fs::read_to_string(dir.join("spokenrectifier.local.toml")).unwrap();
        assert!(local.contains("thinking = false"), "touched: {local}");
        assert!(!local.contains("[rectify"), "rectify written: {local}");
        std::fs::remove_dir_all(dir).unwrap();
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
        assert_eq!(config.rectify.full.thinking_policy, ThinkingPolicy::Always);
        assert_eq!(config.rectify.light_touch.max_chars, 60); // grandfathered threshold
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn endpoint_fields_touched_mark_intent() {
        for section in [
            "[llm]\nmodel = \"other-model\"\n",
            "[llm]\nbase_url = \"https://example.com\"\n",
            "[llm]\napi_key = \"sk-x\"\n",
            "[llm.openai]\napi_key = \"sk-x\"\n",
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

    /// An overlay share as the pane's JSON box holds it (pretty-printed
    /// by the bridge; the save takes the text verbatim).
    fn box_text(share: &Option<Map<String, Value>>) -> Option<String> {
        share
            .as_ref()
            .map(|map| serde_json::to_string(&Value::Object(map.clone())).unwrap())
    }

    /// The edit a pane hands back: the endpoint fields as painted plus
    /// the whole group. The volcengine preset's, matching the endpoint
    /// below — what a chip click stamps (ADR-0019 item 5).
    fn edit(api_key: KeyEdit) -> LlmConnectionEdit {
        let preset = crate::presets::by_name("volcengine").expect("volcengine has a preset");
        LlmConnectionEdit {
            vendor: Vendor::Volcengine,
            base_url: "https://ark.cn-beijing.volces.com/api/v3".into(),
            model: "doubao-seed-2.0-lite".into(),
            format: preset.format,
            thinking_fields: preset.thinking_fields,
            body_json: None,
            thinking_on_json: box_text(&Some(preset.thinking_on)),
            thinking_off_json: box_text(&Some(preset.thinking_off)),
            api_key,
        }
    }

    /// The pane's model built from a LOADED view — what the connection
    /// card paints and would hand back untouched. The grandfather is
    /// what makes this equal to a legacy file set's old request bytes.
    fn edit_of(config: &LlmConfig, api_key: KeyEdit) -> LlmConnectionEdit {
        LlmConnectionEdit {
            vendor: config.model.vendor,
            base_url: config.model.base_url.clone(),
            model: config.model.model.clone(),
            format: config.model.format,
            thinking_fields: config.model.thinking.state == ThinkingState::On,
            body_json: box_text(&config.model.thinking.overlays.body),
            thinking_on_json: box_text(&config.model.thinking.overlays.thinking_on),
            thinking_off_json: box_text(&config.model.thinking.overlays.thinking_off),
            api_key,
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// One written section's body, header to the next header (or EOF) —
    /// so a key's presence is asserted inside the sub-section it belongs
    /// to, never by a substring that a sibling could satisfy.
    fn section<'a>(text: &'a str, header: &str) -> &'a str {
        let at = text
            .find(header)
            .unwrap_or_else(|| panic!("no {header} in: {text}"));
        let rest = &text[at + header.len()..];
        match rest.find("\n[") {
            Some(end) => &rest[..end],
            None => rest,
        }
    }

    #[test]
    fn a_save_without_any_layer_creates_both_files_and_round_trips() {
        let dir = scratch("sr-llm-save-fresh");
        let dirs = std::slice::from_ref(&dir);

        save_llm_connection(dirs, &edit(KeyEdit::Set("sk-new".into()))).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(shared.contains("vendor = \"volcengine\""), "got: {shared}");
        assert!(shared.contains("doubao-seed-2.0-lite"));
        // The ratchet's new keys land with the endpoint fields.
        assert!(shared.contains("format = \"openai_chat\""), "got: {shared}");
        assert!(shared.contains("thinking_fields = true"), "got: {shared}");
        assert!(
            shared.contains("[llm.overlays.thinking_on]"),
            "got: {shared}"
        );
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
        // The flat key authenticated the default vendor (deepseek), so
        // the clear must name THAT vendor to take it out.
        std::fs::write(dir.join(LOCAL_FILE), "[llm]\napi_key = \"sk-old\"\n").unwrap();
        let mut clear = edit(KeyEdit::Clear);
        clear.vendor = Vendor::DeepSeek;
        clear.model = "deepseek-v4-flash".into();
        clear.base_url = "https://api.deepseek.com".into();

        save_llm_connection(dirs, &clear).unwrap();

        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(!local.contains("api_key"), "not cleared: {local}");
        assert!(
            local.contains("model = \"deepseek-v4-flash\""),
            "endpoint fields lost: {local}"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    // -- per-vendor key slots (ADR-0011) -----------------------------------

    /// Each vendor resolves its own slot; the active vendor picks its own
    /// key, and switching the active vendor switches the key with it.
    #[test]
    fn per_vendor_slots_resolve_to_their_own_vendor() {
        let dir = scratch("sr-llm-slots-own-vendor");
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[llm]\nvendor = \"qwen\"\n\
             [llm.deepseek]\napi_key = \"ds-key\"\n\
             [llm.qwen]\napi_key = \"qw-key\"\n",
        )
        .unwrap();

        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.model.vendor, Vendor::Qwen);
        assert_eq!(config.model.api_key.as_deref(), Some("qw-key"));
        assert_eq!(
            config.resolved_keys(Vendor::DeepSeek).api_key.as_deref(),
            Some("ds-key"),
            "an inactive vendor's slot is still its own"
        );

        // Switching the active vendor switches the key (what the settings
        // card rides on a chip click plus save).
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[llm]\nvendor = \"deepseek\"\n\
             [llm.deepseek]\napi_key = \"ds-key\"\n\
             [llm.qwen]\napi_key = \"qw-key\"\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.model.api_key.as_deref(), Some("ds-key"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The defect this rework fixes: a vendor-switch save parks the
    /// previous vendor's key in its own slot instead of carrying it
    /// across (or losing it), and the flat pair retires.
    #[test]
    fn a_vendor_switch_save_parks_the_old_key_in_its_own_slot() {
        let dir = scratch("sr-llm-slots-switch-save");
        let dirs = std::slice::from_ref(&dir);
        // The pre-rework shape: one flat key under the deepseek endpoint.
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[llm]\nvendor = \"deepseek\"\nmodel = \"deepseek-v4-flash\"\napi_key = \"ds-old\"\n",
        )
        .unwrap();

        save_llm_connection(dirs, &edit(KeyEdit::Set("ark-key".into()))).unwrap();

        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("[llm.deepseek]\napi_key = \"ds-old\""),
            "old key not parked: {local}"
        );
        assert!(
            local.contains("[llm.volcengine]\napi_key = \"ark-key\""),
            "new key not slotted: {local}"
        );
        assert!(
            !local.contains("\napi_key = \"ds-old\"\nmodel"),
            "flat key survived: {local}"
        );

        // The switch resolves the new vendor's key; switching back (a
        // Keep on deepseek) resolves the parked one — round-trip intact.
        let switched = load_llm_config(dirs).unwrap();
        assert_eq!(switched.model.vendor, Vendor::Volcengine);
        assert_eq!(switched.model.api_key.as_deref(), Some("ark-key"));
        let mut back = edit(KeyEdit::Keep);
        back.vendor = Vendor::DeepSeek;
        back.model = "deepseek-v4-flash".into();
        back.base_url = "https://api.deepseek.com".into();
        save_llm_connection(dirs, &back).unwrap();
        assert_eq!(
            load_llm_config(dirs).unwrap().model.api_key.as_deref(),
            Some("ds-old")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The flat pair authenticated the vendor the files named — an
    /// inactive vendor never borrows it.
    #[test]
    fn an_inactive_vendor_never_borrows_the_flat_pair() {
        let dir = scratch("sr-llm-slots-flat-inactive");
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[llm]\nvendor = \"openai\"\napi_key = \"oa-key\"\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.model.api_key.as_deref(), Some("oa-key"));
        assert_eq!(config.resolved_keys(Vendor::DeepSeek).api_key, None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Every vendor falls back to its own conventional environment name.
    #[test]
    fn every_vendor_defaults_to_its_own_env_name() {
        let config = LlmConfig::defaults();
        for (vendor, env) in [
            (Vendor::DeepSeek, "DEEPSEEK_API_KEY"),
            (Vendor::Volcengine, "ARK_API_KEY"),
            (Vendor::Qwen, "DASHSCOPE_API_KEY"),
            (Vendor::OpenAi, "OPENAI_API_KEY"),
            (Vendor::Anthropic, "ANTHROPIC_API_KEY"),
            (Vendor::Gemini, "GEMINI_API_KEY"),
        ] {
            assert_eq!(
                config.resolved_keys(vendor).api_key_env.as_deref(),
                Some(env)
            );
        }
        // Custom has no conventional name (ADR-0018): unset means unset.
        assert_eq!(config.resolved_keys(Vendor::Custom).api_key_env, None);
    }

    // -- the custom slot (ADR-0018) ---------------------------------------

    /// The slot sits DORMANT while another vendor is active — cached, not
    /// adopted — and wakes (dialect + overlay folded into the
    /// grandfathered shares) when the files name custom. The endpoint
    /// itself always lives in the common segment; the slot's URL is a
    /// legacy cache the ratchet retires.
    #[test]
    fn a_custom_slot_loads_dormant_until_custom_is_active() {
        let dir = scratch("sr-llm-custom-dormant");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nvendor = \"deepseek\"\n\
             [llm.custom]\nbase_url = \"https://my-endpoint\"\nmodel = \"my-model\"\n\
             thinking_dialect = \"qwen\"\n\
             [llm.custom.extra_body]\ntop_p = 0.9\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        // Dormant: the grandfathered shares speak deepseek alone — the
        // slot's dialect and overlay never fold in while another vendor
        // is active (ADR-0018's dormancy, honored by the grandfather).
        assert_eq!(config.model.vendor, Vendor::DeepSeek);
        let on = config.model.thinking.overlays.thinking_on.as_ref().unwrap();
        assert_eq!(
            on["thinking"],
            serde_json::json!({"type": "enabled"}),
            "shares not the deepseek dictionary: {on:?}"
        );
        assert!(
            !on.contains_key("top_p"),
            "the dormant custom overlay leaked into the shares: {on:?}"
        );
        assert_eq!(
            config.custom.base_url.as_deref(),
            Some("https://my-endpoint")
        );
        assert_eq!(config.custom.thinking_dialect, Vendor::Qwen);

        std::fs::write(dir.join(LOCAL_FILE), "[llm]\nvendor = \"custom\"\n").unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        // Awake: the shares compose dict[qwen] ∘ custom overlay —
        // enable_thinking plus top_p, byte for byte the pre-0019 body.
        let on = config.model.thinking.overlays.thinking_on.as_ref().unwrap();
        assert_eq!(on["enable_thinking"], serde_json::json!(true));
        assert_eq!(on["top_p"], serde_json::json!(0.9));
        // The common segment stays the endpoint's truth (the default URL
        // here): the slot's cache never feeds the active endpoint.
        assert_eq!(config.model.base_url, "https://api.deepseek.com");
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A missing dialect key reads as openai; an unknown one — "custom"
    /// included, which names an endpoint, never a shape — refuses the
    /// load naming the file.
    #[test]
    fn a_custom_dialect_defaults_to_openai_and_rejects_unknown_names() {
        let dir = scratch("sr-llm-custom-dialect-default");
        std::fs::write(dir.join(SHARED_FILE), "[llm.custom]\nmodel = \"m\"\n").unwrap();
        assert_eq!(
            load_llm_config(std::slice::from_ref(&dir))
                .unwrap()
                .custom
                .thinking_dialect,
            Vendor::OpenAi
        );

        for bad in ["custom", "Always", "anthropic"] {
            std::fs::write(
                dir.join(LOCAL_FILE),
                format!("[llm.custom]\nthinking_dialect = \"{bad}\"\n"),
            )
            .unwrap();
            let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
            assert!(err.contains("spokenrectifier.local.toml"), "{bad}: {err}");
            assert!(err.contains("[llm.custom]"), "{bad}: {err}");
            assert!(err.contains("thinking_dialect"), "{bad}: {err}");
            assert!(!err.contains('\n'), "{bad}: multi-line: {err}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A custom slot key marks endpoint intent like every vendor's slot;
    /// without one, custom is simply keyless (no env fallback to hide
    /// behind), so an active custom endpoint with no key is the caller's
    /// error to surface — the same rule as the four.
    #[test]
    fn a_custom_slot_key_marks_intent_and_there_is_no_env_fallback() {
        let dir = scratch("sr-llm-custom-intent");
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[llm.custom]\napi_key = \"sk-mine\"\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert!(config.endpoint_configured);
        assert_eq!(
            config.resolved_keys(Vendor::Custom).api_key.as_deref(),
            Some("sk-mine")
        );
        // The slot's URL alone is a cache, not intent.
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[llm.custom]\nbase_url = \"https://my-endpoint\"\n",
        )
        .unwrap();
        assert!(
            !load_llm_config(std::slice::from_ref(&dir))
                .unwrap()
                .endpoint_configured
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The ratchet in full (ADR-0019 item 4) over the custom chip's own
    /// endpoint: the edit's group lands as the new keys, the `[llm.custom]`
    /// cabins strip, and the slot is a pure key slot after. The key lands
    /// in the slot's local sub-section only.
    #[test]
    fn a_custom_save_writes_the_edits_group_and_strips_the_cabins() {
        let dir = scratch("sr-llm-custom-save-mirror");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nvendor = \"custom\"\n\
             [llm.custom]\nbase_url = \"https://old-endpoint\"\nmodel = \"old-model\"\n\
             thinking_dialect = \"qwen\"\n\
             [llm.custom.extra_body]\ntop_p = 0.5\n",
        )
        .unwrap();
        let mut custom_edit = edit(KeyEdit::Set("sk-mine".into()));
        custom_edit.vendor = Vendor::Custom;
        custom_edit.base_url = "https://my-endpoint".into();
        custom_edit.model = "my-model".into();
        custom_edit.thinking_on_json =
            Some(r#"{"enable_thinking": true, "top_p": 0.9, "stop": ["嗯"]}"#.into());
        custom_edit.thinking_off_json = Some(r#"{"enable_thinking": false, "top_p": 0.9}"#.into());

        save_llm_connection(std::slice::from_ref(&dir), &custom_edit).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(shared.contains("vendor = \"custom\""), "got: {shared}");
        assert!(shared.contains("https://my-endpoint"), "got: {shared}");
        assert!(shared.contains("format = \"openai_chat\""), "got: {shared}");
        assert!(shared.contains("thinking_fields = true"), "got: {shared}");
        assert!(
            shared.contains("[llm.overlays.thinking_on]"),
            "shares not written: {shared}"
        );
        assert!(shared.contains("enable_thinking = true"), "got: {shared}");
        assert!(shared.contains("top_p = 0.9"), "got: {shared}");
        // The cabins are gone: the slot is a pure key slot now (the
        // reset pass leaves an empty header behind, which is nothing).
        assert!(
            !shared.contains("thinking_dialect"),
            "cabin survived: {shared}"
        );
        assert!(
            !shared.contains("https://old-endpoint")
                && !shared.contains("top_p = 0.5")
                && !shared.contains("extra_body")
                && !shared.contains("old-model"),
            "cabin content survived: {shared}"
        );
        assert!(
            !shared.contains("api_key"),
            "key leaked into shared: {shared}"
        );
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("[llm.custom]") && local.contains("api_key = \"sk-mine\""),
            "key not slotted: {local}"
        );
        // The load returns the whole save from the new keys alone: the
        // edit's shares, no grandfathering involved.
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.model.vendor, Vendor::Custom);
        assert_eq!(config.model.base_url, "https://my-endpoint");
        let on = config.model.thinking.overlays.thinking_on.as_ref().unwrap();
        assert_eq!(on["enable_thinking"], serde_json::json!(true));
        assert_eq!(on["top_p"], serde_json::json!(0.9));
        assert_eq!(config.model.resolve_key().as_deref(), Some("sk-mine"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A save from another chip in a legacy file set retires the custom
    /// cabins (ADR-0019 kills the restore cache), and the stored custom
    /// dialect and overlay never bleed into the shares the edit wrote.
    #[test]
    fn an_inactive_save_writes_the_edits_group_and_retires_the_cabins() {
        let dir = scratch("sr-llm-custom-save-untouched");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nvendor = \"custom\"\n\
             [llm.custom]\nbase_url = \"https://my-endpoint\"\nmodel = \"my-model\"\n\
             thinking_dialect = \"qwen\"\n\
             [llm.custom.extra_body]\ntop_p = 0.9\n",
        )
        .unwrap();

        save_llm_connection(std::slice::from_ref(&dir), &edit(KeyEdit::Keep)).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(!shared.contains("vendor = \"custom\""), "got: {shared}");
        assert!(
            !shared.contains("thinking_dialect"),
            "cabin survived: {shared}"
        );
        assert!(
            !shared.contains("top_p = 0.9"),
            "overlay survived: {shared}"
        );
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        // The volcengine shares the edit carried, not the custom slot's.
        let on = config.model.thinking.overlays.thinking_on.as_ref().unwrap();
        assert_eq!(
            on["thinking"],
            serde_json::json!({"type": "enabled"}),
            "custom dialect bled in: {on:?}"
        );
        assert!(!on.contains_key("top_p"), "custom overlay bled in: {on:?}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A bad overlay box refuses the whole save before a single file is
    /// touched: malformed JSON, a non-object root, and a JSON shape TOML
    /// cannot render all name the share they came from.
    #[test]
    fn bad_overlays_refuse_the_save_writing_nothing() {
        for (name, json) in [
            ("malformed", r#"{"top_p": 0.9"#),
            ("non-object root", r#"["top_p"]"#),
            ("shapeless", r#"{"top_p": null}"#),
        ] {
            for share in ["body", "thinking_on", "thinking_off"] {
                let dir = scratch("sr-llm-save-bad-json");
                let mut bad = edit(KeyEdit::Keep);
                match share {
                    "body" => bad.body_json = Some(json.into()),
                    "thinking_on" => bad.thinking_on_json = Some(json.into()),
                    _ => bad.thinking_off_json = Some(json.into()),
                }

                let err = save_llm_connection(std::slice::from_ref(&dir), &bad)
                    .unwrap_err()
                    .0;
                assert!(
                    err.contains("[llm.overlays]") && err.contains(share),
                    "{name}/{share}: got: {err}"
                );
                assert!(!dir.join(SHARED_FILE).exists(), "{name}: wrote on refusal");
                assert!(!dir.join(LOCAL_FILE).exists(), "{name}: wrote on refusal");
                std::fs::remove_dir_all(dir).unwrap();
            }
        }
    }

    /// A blank (or `{}`) box is the OFF form for that share: the key
    /// resets rather than a table landing, and the switch rides the edit
    /// as given.
    #[test]
    fn a_blank_box_is_the_off_form() {
        for blank in [None, Some("{}".to_string()), Some("   ".to_string())] {
            let dir = scratch("sr-llm-save-blank-box");
            let mut off = edit(KeyEdit::Keep);
            off.thinking_fields = false;
            off.body_json = blank.clone();
            off.thinking_on_json = blank.clone();
            off.thinking_off_json = blank;

            save_llm_connection(std::slice::from_ref(&dir), &off).unwrap();

            let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
            assert!(shared.contains("thinking_fields = false"), "got: {shared}");
            // The reset pass leaves a bare `[llm.overlays]` header behind
            // (an empty table, which reads back as three unset shares);
            // no share of its own may land.
            for share in ["body", "thinking_on", "thinking_off"] {
                assert!(
                    !shared.contains(&format!("[llm.overlays.{share}]")),
                    "wrote the {share} box: {shared}"
                );
            }
            let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
            assert_eq!(config.model.thinking.state, ThinkingState::Off);
            assert!(config.model.thinking.overlays.body.is_none());
            assert!(config.model.thinking.overlays.thinking_on.is_none());
            assert!(config.model.thinking.overlays.thinking_off.is_none());
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    /// An on switch with an empty on-share is refused: the group would
    /// load straight back as unconfigured, so the pair is a mistake
    /// rather than a stance (ADR-0019 item 2).
    #[test]
    fn an_on_switch_without_an_on_share_is_refused_writing_nothing() {
        let dir = scratch("sr-llm-save-on-empty");
        let mut on = edit(KeyEdit::Set("sk".into()));
        on.thinking_fields = true;
        on.thinking_on_json = None;

        let err = save_llm_connection(std::slice::from_ref(&dir), &on)
            .unwrap_err()
            .0;
        assert!(err.contains("thinking_on"), "got: {err}");
        assert!(!dir.join(SHARED_FILE).exists(), "wrote on a refused save");
        assert!(!dir.join(LOCAL_FILE).exists());
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

    // -- the post-0019 connection keys (ADR-0019) -------------------------

    use crate::assembly::request_body;
    use serde_json::json;

    fn prompt() -> crate::prompt::ChatPrompt {
        crate::prompt::ChatPrompt {
            system: "sys".into(),
            user: "usr".into(),
        }
    }

    /// The golden-body helper: the effective request body under both
    /// thinking policies, serialized — the byte-level comparison the
    /// grandfather and ratchet must survive.
    fn bodies(config: &LlmConfig) -> [String; 2] {
        [
            serde_json::to_string(&request_body(&config.model, &prompt(), true)).unwrap(),
            serde_json::to_string(&request_body(&config.model, &prompt(), false)).unwrap(),
        ]
    }

    /// The new keys load and drive the axis: format, the switch, and the
    /// three shares, layered like every other key (local wins; the
    /// overlays node replaces wholesale).
    #[test]
    fn the_new_keys_load_and_drive_the_axis() {
        let dir = scratch("sr-llm-new-keys-load");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nformat = \"anthropic\"\nthinking_fields = true\n\
             [llm.overlays.body]\ntemperature = 0.1\n\
             [llm.overlays.thinking_on]\nthinking = { type = \"adaptive\" }\n\
             [llm.overlays.thinking_off]\nthinking = { type = \"disabled\" }\n",
        )
        .unwrap();
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[llm]\nformat = \"gemini\"\n\
             [llm.overlays.thinking_on]\nthoughts = true\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.model.format, Format::Gemini); // local wins
        assert_eq!(config.model.thinking.state, ThinkingState::On);
        // The local node replaced the shared shares wholesale: its
        // on-share alone stands, the body share is gone.
        assert_eq!(
            config.model.thinking.overlays.thinking_on.as_ref().unwrap()["thoughts"],
            serde_json::json!(true)
        );
        assert!(config.model.thinking.overlays.body.is_none());
        assert!(config.model.thinking.overlays.thinking_off.is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The blocking branch of the bad-file boundary (ADR-0019 item 3):
    /// an illegal format value or type refuses the load, naming the
    /// file and the accepted values.
    #[test]
    fn an_illegal_format_refuses_the_load() {
        for (name, body) in [
            ("unknown name", "[llm]\nformat = \"openai\"\n"),
            ("case variant", "[llm]\nformat = \"Anthropic\"\n"),
            ("non-string", "[llm]\nformat = 3\n"),
        ] {
            let dir = scratch("sr-llm-format-illegal");
            std::fs::write(dir.join(SHARED_FILE), body).unwrap();
            let err = load_llm_config(std::slice::from_ref(&dir)).unwrap_err().0;
            assert!(err.contains("spokenrectifier.toml"), "{name}: {err}");
            assert!(err.contains("[llm]"), "{name}: {err}");
            assert!(err.contains("openai_chat"), "{name}: {err}");
            assert!(!err.contains('\n'), "{name}: multi-line: {err}");
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    /// The non-blocking branch: a malformed switch or overlays group
    /// degrades the thinking group to broken — the load succeeds, the
    /// whole group voids (shares included), and the detail names the
    /// file for the warning slot. Requests then carry no thinking keys
    /// (the client's own gating test covers the body).
    #[test]
    fn malformed_thinking_keys_degrade_to_broken_without_blocking() {
        for (name, body) in [
            (
                "non-boolean switch",
                "[llm]\nformat = \"openai_chat\"\nthinking_fields = \"yes\"\n",
            ),
            (
                "non-table overlays",
                "[llm]\nformat = \"openai_chat\"\noverlays = 3\n",
            ),
            (
                "unknown share key",
                "[llm]\nformat = \"openai_chat\"\n[llm.overlays.mystery]\nx = 1\n",
            ),
            (
                "non-table share",
                "[llm]\nformat = \"openai_chat\"\n[llm.overlays]\nbody = 3\n",
            ),
        ] {
            let dir = scratch("sr-llm-thinking-broken");
            std::fs::write(dir.join(LOCAL_FILE), body).unwrap();
            let config = load_llm_config(std::slice::from_ref(&dir))
                .unwrap_or_else(|err| panic!("{name}: load blocked: {err}"));
            let ThinkingState::Broken(detail) = &config.model.thinking.state else {
                panic!("{name}: not broken: {:?}", config.model.thinking.state);
            };
            assert!(
                detail.contains("spokenrectifier.local.toml"),
                "{name}: detail names no file: {detail}"
            );
            // 整组作废: even the healthy shares void with the group.
            assert!(
                config
                    .model
                    .thinking
                    .overlays
                    .body
                    .as_ref()
                    .is_none_or(|map| map.is_empty()),
                "{name}: shares survived the void"
            );
            // The resident body never merges while broken — nothing does.
            assert!(
                !bodies(&config).iter().any(|body| body.contains("when")),
                "{name}: broken group leaked into a request body"
            );
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    /// The switch absent (or on with no on-share) reads as
    /// unconfigured: no thinking keys, but the resident body still
    /// merges.
    #[test]
    fn an_unset_switch_reads_as_unconfigured_body_still_merges() {
        let dir = scratch("sr-llm-unconfigured");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nformat = \"openai_chat\"\n\
             [llm.overlays.body]\ntop_p = 0.9\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.model.thinking.state, ThinkingState::Unconfigured);
        let [on, off] = bodies(&config);
        for body in [on, off] {
            assert!(body.contains("top_p"), "body share dropped: {body}");
            assert!(
                !body.contains("thinking") && !body.contains("reasoning_effort"),
                "thinking keys leaked: {body}"
            );
        }

        // Switch on with an empty on-share is the same unconfigured
        // state (a save refuses the pair; a load reads it as void).
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nformat = \"openai_chat\"\nthinking_fields = true\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.model.thinking.state, ThinkingState::Unconfigured);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A TOML datetime inside a share reads as its string form — the
    /// same silent coercion the pre-0019 extra-body path performed (the
    /// serde hop stringifies datetimes before this crate ever sees
    /// them), so it is a value, not a refusal.
    #[test]
    fn a_datetime_share_value_reads_as_its_string_form() {
        let dir = scratch("sr-llm-datetime-share");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nformat = \"openai_chat\"\n[llm.overlays.body]\nwhen = 1979-05-27\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(
            config.model.thinking.overlays.body.as_ref().unwrap()["when"],
            serde_json::json!("1979-05-27")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The off switch stores but disables (off is a stance, not a
    /// deletion — ADR-0015 precedent): both shares stay loaded, no
    /// thinking key leaves.
    #[test]
    fn the_off_switch_stores_but_disables() {
        let dir = scratch("sr-llm-off-switch");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nformat = \"openai_chat\"\nthinking_fields = false\n\
             [llm.overlays.thinking_on]\nreasoning_effort = \"high\"\n\
             [llm.overlays.thinking_off]\nreasoning_effort = \"none\"\n",
        )
        .unwrap();
        let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.model.thinking.state, ThinkingState::Off);
        assert!(config.model.thinking.overlays.thinking_on.is_some());
        assert!(config.model.thinking.overlays.thinking_off.is_some());
        for body in bodies(&config) {
            assert!(!body.contains("reasoning_effort"), "leaked: {body}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The read-time grandfather's golden bytes (ADR-0019 item 4): for
    /// every legacy shape — a bare vendor, a hold overriding a thinking
    /// key, a custom endpoint with dialect + overlay + hold — the
    /// upgraded build composes request bodies byte-identical to the
    /// pre-0019 ones, under both thinking policies.
    #[test]
    fn legacy_files_send_byte_identical_requests() {
        struct Case {
            name: &'static str,
            file: &'static str,
            on: Value,
            off: Value,
        }
        let cases = [
            Case {
                name: "bare deepseek",
                file: "[llm]\nmodel = \"deepseek-v4-flash\"\n",
                on: json_skeleton(
                    "deepseek-v4-flash",
                    json!({
                        "reasoning_effort": "medium", "thinking": {"type": "enabled"}
                    }),
                ),
                off: json_skeleton(
                    "deepseek-v4-flash",
                    json!({"thinking": {"type": "disabled"}}),
                ),
            },
            Case {
                name: "hold overriding a thinking key",
                file: "[llm]\nvendor = \"deepseek\"\n\
                       [llm.extra_body]\ntop_p = 0.9\nthinking = { type = \"enabled\" }\n",
                on: json_skeleton(
                    "deepseek-v4-flash",
                    json!({
                        "reasoning_effort": "medium", "thinking": {"type": "enabled"}, "top_p": 0.9
                    }),
                ),
                off: json_skeleton(
                    "deepseek-v4-flash",
                    json!({
                        "thinking": {"type": "enabled"}, "top_p": 0.9
                    }),
                ),
            },
            Case {
                name: "volcengine",
                file: "[llm]\nvendor = \"volcengine\"\nmodel = \"doubao-seed-2.0-lite\"\n",
                on: json_skeleton(
                    "doubao-seed-2.0-lite",
                    json!({"thinking": {"type": "enabled"}}),
                ),
                off: json_skeleton(
                    "doubao-seed-2.0-lite",
                    json!({"thinking": {"type": "disabled"}}),
                ),
            },
            Case {
                name: "custom with dialect and overlay",
                file: "[llm]\nvendor = \"custom\"\nmodel = \"my-model\"\n\
                       [llm.custom]\nthinking_dialect = \"qwen\"\n\
                       [llm.custom.extra_body]\ntop_k = 5\n",
                on: json_skeleton("my-model", json!({"enable_thinking": true, "top_k": 5})),
                off: json_skeleton("my-model", json!({"enable_thinking": false, "top_k": 5})),
            },
        ];
        for case in cases {
            let dir = scratch("sr-llm-grandfather-golden");
            std::fs::write(dir.join(SHARED_FILE), case.file).unwrap();
            let config = load_llm_config(std::slice::from_ref(&dir)).unwrap();
            let [on, off] = bodies(&config);
            assert_eq!(
                on,
                serde_json::to_string(&case.on).unwrap(),
                "{}: on-policy body drifted",
                case.name
            );
            assert_eq!(
                off,
                serde_json::to_string(&case.off).unwrap(),
                "{}: off-policy body drifted",
                case.name
            );
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    /// The save-time ratchet's golden bytes: a legacy file set saved
    /// once carries new keys only, the legacy keys strip from every
    /// layer, and the requests stay byte-identical across the whole
    /// hop — the upgrade's behavior-faithfulness contract.
    #[test]
    fn the_ratchet_keeps_request_bytes_and_strips_the_legacy_keys() {
        let dir = scratch("sr-llm-ratchet-golden");
        let dirs = std::slice::from_ref(&dir);
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nvendor = \"deepseek\"\nmodel = \"deepseek-v4-flash\"\n\
             [llm.extra_body]\ntop_p = 0.9\n",
        )
        .unwrap();
        // The save keeps the endpoint exactly as loaded — only the key
        // layout is under test here, not a vendor switch — so the edit
        // is the loaded view handed straight back, as the card does.
        let loaded = load_llm_config(dirs).unwrap();
        let before = bodies(&loaded);
        let same = edit_of(&loaded, KeyEdit::Keep);

        save_llm_connection(dirs, &same).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(shared.contains("format = \"openai_chat\""), "got: {shared}");
        assert!(shared.contains("thinking_fields = true"), "got: {shared}");
        assert!(
            shared.contains("[llm.overlays.thinking_on]"),
            "shares missing: {shared}"
        );
        assert!(shared.contains("top_p = 0.9"), "hold bytes lost: {shared}");
        assert!(
            !shared.contains("[llm.extra_body]"),
            "hold survived: {shared}"
        );
        assert!(
            !shared.contains("thinking_dialect"),
            "dialect survived: {shared}"
        );

        let after = bodies(&load_llm_config(dirs).unwrap());
        assert_eq!(before, after, "the ratchet changed the request bytes");
        // A second save is a steady state: same files' truth, same bytes.
        let again = load_llm_config(dirs).unwrap();
        save_llm_connection(dirs, &edit_of(&again, KeyEdit::Keep)).unwrap();
        assert_eq!(bodies(&load_llm_config(dirs).unwrap()), after);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// From a new-keys file set the card's model IS the file's truth: a
    /// save changes the endpoint fields only, and the loaded group —
    /// format, off switch, both shares — rides back verbatim.
    #[test]
    fn a_new_keys_save_preserves_the_thinking_group() {
        let dir = scratch("sr-llm-new-keys-preserve");
        let dirs = std::slice::from_ref(&dir);
        std::fs::write(
            dir.join(SHARED_FILE),
            "[llm]\nvendor = \"openai\"\nformat = \"anthropic\"\nthinking_fields = false\n\
             base_url = \"https://api.anthropic.com\"\nmodel = \"claude-sonnet-5\"\n\
             [llm.overlays.thinking_on]\nthinking = { type = \"adaptive\" }\n\
             [llm.overlays.thinking_off]\nthinking = { type = \"disabled\" }\n",
        )
        .unwrap();
        let loaded = load_llm_config(dirs).unwrap();
        let before = bodies(&loaded);

        save_llm_connection(dirs, &edit_of(&loaded, KeyEdit::Keep)).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(shared.contains("format = \"anthropic\""), "got: {shared}");
        assert!(shared.contains("thinking_fields = false"), "got: {shared}");
        assert!(
            shared.contains("type = \"adaptive\""),
            "shares lost: {shared}"
        );
        let config = load_llm_config(dirs).unwrap();
        assert_eq!(config.model.format, Format::Anthropic);
        assert_eq!(config.model.thinking.state, ThinkingState::Off);
        assert!(config.model.thinking.overlays.thinking_on.is_some());
        // The off switch keeps the request bodies off: a save with the
        // card's own model changes no request bytes.
        assert_eq!(bodies(&config), before);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A broken thinking group refuses the save whole, before a single
    /// file is touched: the ratchet cannot truthfully rewrite a group
    /// it cannot read.
    #[test]
    fn a_broken_thinking_group_refuses_the_save_writing_nothing() {
        let dir = scratch("sr-llm-save-broken-group");
        let before = "[llm]\nmodel = \"m\"\nformat = \"openai_chat\"\nthinking_fields = 3\n";
        std::fs::write(dir.join(SHARED_FILE), before).unwrap();

        let err = save_llm_connection(std::slice::from_ref(&dir), &edit(KeyEdit::Keep))
            .unwrap_err()
            .0;
        assert!(err.contains("thinking"), "got: {err}");
        assert!(
            err.contains("spokenrectifier.toml"),
            "the refusal names the file: {err}"
        );
        assert_eq!(
            std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap(),
            before,
            "wrote on refusal"
        );
        assert!(!dir.join(LOCAL_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The grandfather serves the bare default too: no files at all is
    /// the deepseek dictionary on the default model, byte for byte the
    /// pre-0019 default request.
    #[test]
    fn bare_defaults_are_the_deepseek_dictionary() {
        let config = LlmConfig::defaults();
        assert_eq!(config.model.format, Format::OpenaiChat);
        assert_eq!(config.model.thinking.state, ThinkingState::On);
        let (on, off) = presets::legacy_shares(Vendor::DeepSeek);
        assert_eq!(config.model.thinking.overlays.thinking_on, Some(on));
        assert_eq!(config.model.thinking.overlays.thinking_off, Some(off));
    }

    /// The pre-0019 request body the golden tests compare against: the
    /// skeleton plus the thinking-era keys, exactly as the old client
    /// assembled them (skeleton → dialect pairs → custom overlay →
    /// hold, all flattened here into one key set).
    fn json_skeleton(model: &str, extra: Value) -> Value {
        let mut body = serde_json::json!({
            "model": model,
            "messages": [
                {"role": "system", "content": "sys"},
                {"role": "user", "content": "usr"},
            ],
            "stream": true,
            "temperature": 0.2,
        });
        let map = body.as_object_mut().unwrap();
        for (key, value) in extra.as_object().unwrap() {
            map.insert(key.clone(), value.clone());
        }
        body
    }

    /// The thinking state's wire names are the settings window's
    /// contract (the connection card's switch and warning, the rectify
    /// card's disable condition): four lowercase strings, and the
    /// detail only on the broken branch.
    #[test]
    fn the_thinking_states_wire_names_are_the_settings_contract() {
        assert_eq!(ThinkingState::On.as_str(), "on");
        assert_eq!(ThinkingState::Off.as_str(), "off");
        assert_eq!(ThinkingState::Unconfigured.as_str(), "unconfigured");
        let broken =
            ThinkingState::Broken("f.toml: [llm]: thinking_fields must be a boolean".into());
        assert_eq!(broken.as_str(), "broken");
        assert_eq!(
            broken.detail(),
            Some("f.toml: [llm]: thinking_fields must be a boolean")
        );
        for state in [
            ThinkingState::On,
            ThinkingState::Off,
            ThinkingState::Unconfigured,
        ] {
            assert_eq!(state.detail(), None, "{state:?}");
        }
        // The switch paints on exactly one state; the rectify domain's
        // disable condition is the other three (ADR-0019 item 3).
        assert_eq!(ThinkingState::On.as_str(), "on");
    }
}
