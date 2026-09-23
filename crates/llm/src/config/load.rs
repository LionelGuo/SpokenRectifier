//! The layered read: defaults, then `spokenrectifier.toml`, then
//! `spokenrectifier.local.toml` — plus the strict `[rectify]` shape and
//! the grandfather/ratchet migrations (ADR-0015/0019).

use std::path::PathBuf;

use serde::Deserialize;
use serde_json::{Map, Value};
use spokenrectifier_config::LayerSource;
use spokenrectifier_config::load_section_layers;

use crate::format::Format;
use crate::presets;
use crate::vendor::Vendor;

use super::shape::{
    ConfigError, ConnectionThinking, LlmConfig, Overlays, RectifyConfig, ThinkingPolicy,
    ThinkingState, VendorKeys,
};

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
pub(super) struct LlmSection {
    pub(super) thinking: Option<bool>,
    pub(super) prefill: Option<bool>,
    pub(super) light_touch_max_chars: Option<usize>,
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
pub(super) struct RectifyOverlay {
    pub(super) full: TierOverlay,
    pub(super) light_touch: LightTouchOverlay,
    quick: QuickOverlay,
}

#[derive(Debug, Default)]
pub(super) struct TierOverlay {
    pub(super) thinking_policy: Option<ThinkingPolicy>,
    pub(super) prefill: Option<bool>,
}

#[derive(Debug, Default)]
pub(super) struct LightTouchOverlay {
    enabled: Option<bool>,
    pub(super) max_chars: Option<usize>,
    pub(super) tier: TierOverlay,
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
pub(super) fn load_rectify_layers(
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::testutil::{bodies, json_skeleton, scratch};
    use serde_json::json;
    use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

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
    /// pre-0019 ones, under both thinking policies. One deliberate
    /// departure since absorb-clock 05: deepseek's on-share effort is
    /// "low", not the pre-0019 "medium" (the probe's clock/token
    /// ruling); the shapes and every other byte stay pinned.
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
                        "reasoning_effort": "low", "thinking": {"type": "enabled"}
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
                    "deepseek-flash",
                    json!({
                        "reasoning_effort": "low", "thinking": {"type": "enabled"}, "top_p": 0.9
                    }),
                ),
                off: json_skeleton(
                    "deepseek-flash",
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
}
