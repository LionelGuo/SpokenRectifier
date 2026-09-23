//! The settings editors' write paths: the connection card's ratcheting
//! save and the rectify card's whole-model save.

use std::path::PathBuf;

use serde_json::{Map, Value};
use spokenrectifier_config::LayerSource;
use spokenrectifier_config::load_section_layers;
use spokenrectifier_config::section_write::{
    KeyEdit, SectionField, WriteLayer, owning_layer, validate_json_table_shape,
    write_section_fields,
};

use crate::format::Format;
use crate::vendor::Vendor;

use super::load::{LlmSection, load_llm_config, load_rectify_layers};
use super::shape::{ConfigError, Overlays, ThinkingPolicy, ThinkingState};

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
    use crate::config::LlmConfig;
    use crate::config::testutil::{bodies, scratch};
    use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

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
}
