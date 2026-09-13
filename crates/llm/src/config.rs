//! LLM configuration: defaults from the v1 model matrix, overridable per
//! field from the layered config files (loading rules live in the config
//! crate; an `api_key` may only come from the git-ignored local layer).
//!
//! One model per mode: every intensity (light-touch or full) calls the same
//! endpoint — the length threshold only changes how the prompt asks the
//! model to rectify, never which model answers.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::Deserialize;
use serde_json::Value;
use spokenrectifier_config::LayerSource;
use spokenrectifier_config::load_section_layers;
use spokenrectifier_config::section_write::{
    KeyEdit, KeyStatus, SectionField, WriteLayer, write_section_fields,
};

use crate::intensity::Intensity;
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
    /// The legacy flat `[llm] api_key`/`api_key_env` pair as the layers
    /// left it (save-time migration only; ADR-0011).
    pub(crate) legacy_flat: VendorKeys,
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

/// The folded `[rectify]` section: the full and light-touch tiers.
/// Missing section, missing keys = today's behavior on every field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RectifyConfig {
    pub full: RectifyTier,
    pub light_touch: LightTouchConfig,
}

impl RectifyConfig {
    /// Today's defaults: both tiers think always with prefill on, the
    /// light-touch gate open at 40 characters, no extra directive —
    /// existing users migrate nothing.
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

/// One OpenAI-compatible endpoint.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelConfig {
    /// Everything before `/chat/completions`.
    pub base_url: String,
    pub model: String,
    /// The ACTIVE vendor's resolved pair (its sub-section's key first,
    /// then the legacy flat pair, then nothing). Mirrors
    /// `vendor_keys[&vendor]` as resolved by [`load_llm_config`].
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
    /// The v1 default: DeepSeek V4-Flash over today's rectify behavior
    /// (thinking always, prefill on, light-touch gate open at 40
    /// characters, no extra directive). Every vendor's key slot starts
    /// empty (the conventional environment names apply at resolution).
    pub fn defaults() -> Self {
        LlmConfig {
            rectify: RectifyConfig::today(),
            endpoint_configured: false,
            legacy_flat: VendorKeys::default(),
            vendor_keys: Vendor::ALL
                .iter()
                .map(|&vendor| (vendor, VendorKeys::default()))
                .collect(),
            model: ModelConfig {
                base_url: "https://api.deepseek.com".into(),
                model: "deepseek-v4-flash".into(),
                api_key: None,
                api_key_env: Some(Vendor::DeepSeek.default_env().into()),
                vendor: Vendor::DeepSeek,
                extra_body: None,
            },
        }
    }

    /// One vendor's resolved key pair for display and resolution: its
    /// own slot first, then (the ACTIVE vendor only) the legacy flat
    /// pair, then the vendor's conventional environment name. An
    /// inactive vendor never borrows the flat pair — it authenticated
    /// whatever vendor the files named, not this one.
    pub fn resolved_keys(&self, vendor: Vendor) -> VendorKeys {
        let slot = self.vendor_keys.get(&vendor).cloned().unwrap_or_default();
        let flat = if vendor == self.model.vendor {
            self.legacy_flat.clone()
        } else {
            Default::default()
        };
        VendorKeys {
            api_key: slot.api_key.or(flat.api_key),
            api_key_env: Some(
                slot.api_key_env
                    .or(flat.api_key_env)
                    .unwrap_or_else(|| vendor.default_env().to_string()),
            ),
        }
    }

    /// The fidelity-eval copy of this config: the eval never runs user
    /// directive text (ADR-0006 posture; ADR-0016 for this key), so the
    /// light-touch extra directive is stripped whatever the layers
    /// carry — style and global are already `None` per request by
    /// construction.
    pub fn for_eval(mut self) -> Self {
        self.rectify.light_touch.extra_directive = None;
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
/// vendor's (ADR-0011).
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
    extra_body: Option<serde_json::Map<String, Value>>,
    deepseek: Option<VendorKeysOverlay>,
    volcengine: Option<VendorKeysOverlay>,
    qwen: Option<VendorKeysOverlay>,
    openai: Option<VendorKeysOverlay>,
}

#[derive(Debug, Default, Deserialize)]
struct VendorKeysOverlay {
    api_key: Option<String>,
    api_key_env: Option<String>,
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
        }
    }

    /// Whether any vendor's sub-section carries a non-empty key.
    fn any_slot_key(&self) -> bool {
        Vendor::ALL.iter().any(|vendor| {
            self.slot(*vendor)
                .is_some_and(|o| o.api_key.as_deref().is_some_and(|k| !k.is_empty()))
        })
    }
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
    // Replaced wholesale: a local override redefines the extra body.
    if let Some(v) = llm.extra_body {
        config.model.extra_body = Some(v);
    }
    for (vendor, overlay) in [
        (Vendor::DeepSeek, llm.deepseek),
        (Vendor::Volcengine, llm.volcengine),
        (Vendor::Qwen, llm.qwen),
        (Vendor::OpenAi, llm.openai),
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
    let rectify_layers = load_rectify_layers(dirs)?;
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
    // A blank extra directive is no directive (ADR-0016) — folded last
    // so a local blank still overrides a shared text into nothing.
    config.rectify.light_touch.extra_directive = config
        .rectify
        .light_touch
        .extra_directive
        .take()
        .filter(|text| !text.trim().is_empty());
    // The save path's migration input: the flat pair as left behind.
    config.legacy_flat = flat;
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

/// Fold one validated `[rectify]` overlay onto the config, field by
/// field — the two tiers never touch each other (ADR-0015).
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
}

/// The strict `[rectify]` read (ADR-0015/0016): the section allows only
/// `full` / `light_touch`, each sub-section only its listed keys, and
/// every value must be exactly its type — `thinking_policy` the three
/// lowercase strings (never a bool), `max_chars` an integer ≥ 1,
/// `enabled` / `prefill` booleans, `extra_directive` a string. Anything
/// else fails the whole load, naming the file and the section. The
/// section is loaded raw and validated here (not by serde) so the error
/// can name the offending sub-section.
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
            other => return Err(unknown_key(file, "rectify", other, "`full`, `light_touch`")),
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
#[derive(Debug, Clone, PartialEq)]
pub struct LlmConnectionEdit {
    pub vendor: Vendor,
    pub base_url: String,
    pub model: String,
    pub api_key: KeyEdit,
}

/// The sub-section a vendor's key slot lives in (`[llm.deepseek]`, …).
fn slot_section(vendor: Vendor) -> String {
    format!("llm.{}", vendor.as_str())
}

/// Write the connection editor's model back into the layer files. The
/// endpoint fields land in the layer that owns `[llm]` (section-
/// preserving); the key edit lands in THE EDIT'S VENDOR's sub-section of
/// the local file only — never the committable shared file, whose loader
/// rejects a key outright (the layering ironclad, ADR-0008; per-vendor
/// slots per ADR-0011).
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
    // The migration needs to know which vendor the flat pair
    // authenticated; a malformed layer refuses the whole save, exactly
    // like the write path below.
    let current = load_llm_config(dirs)?;
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
    let fields = vec![
        SectionField::str("vendor", edit.vendor.as_str()),
        SectionField::str("base_url", base_url),
        SectionField::str("model", model),
        // The flat pair is parked above; the fields themselves go.
        SectionField::reset("api_key"),
        SectionField::reset("api_key_env"),
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
        .write_to_local(dirs, &slot_section(edit.vendor), "api_key")
        .map_err(|err| ConfigError(err.0))?;
    Ok(())
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

/// What the rectify editor writes back: the whole `[rectify]` model —
/// both tiers, the gate, and the extra directive. Saving writes exactly
/// this, so the next load returns what the user saw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RectifyBehaviorEdit {
    pub full: TierEdit,
    pub light_touch: LightTouchEdit,
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
/// (the shared file when none does); the extra directive's blank form
/// removes the key.
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
    let extra = edit
        .light_touch
        .extra_directive
        .as_deref()
        .filter(|text| !text.trim().is_empty());
    let extra_field = match extra {
        Some(text) => SectionField::str("extra_directive", text),
        None => SectionField::reset("extra_directive"),
    };
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
            extra_field,
        ],
        WriteLayer::Owning,
    )
    .map_err(|err| ConfigError(err.0))?;
    Ok(())
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

    /// The eval copy never carries the user's directive text (ADR-0016).
    #[test]
    fn for_eval_strips_the_extra_directive() {
        let mut config = LlmConfig::defaults();
        config.rectify.light_touch.extra_directive = Some("用户的私货".into());
        let eval = config.clone().for_eval();
        assert_eq!(eval.rectify.light_touch.extra_directive, None);
        // The source config is untouched.
        assert_eq!(
            config.rectify.light_touch.extra_directive.as_deref(),
            Some("用户的私货")
        );
    }

    // -- the rectify editor's write path (ticket 13) ----------------------

    use super::{LightTouchEdit, RectifyBehaviorEdit, TierEdit, save_rectify_behavior};

    fn behavior_edit() -> RectifyBehaviorEdit {
        RectifyBehaviorEdit {
            full: TierEdit {
                thinking_policy: ThinkingPolicy::Always,
                prefill: true,
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
        assert!(
            !shared.contains("[rectify"),
            "local values promoted into shared: {shared}"
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
        ] {
            assert_eq!(
                config.resolved_keys(vendor).api_key_env.as_deref(),
                Some(env)
            );
        }
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
