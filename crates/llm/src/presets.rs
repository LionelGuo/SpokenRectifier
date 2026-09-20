//! The single source of preset truth (ADR-0019 item 5): one table, two
//! uses. Forward, the seven-chip row the settings pane paints (custom,
//! the blank preset, is the pane's own last slot — it has no constants
//! here). Backward, the legacy migration dictionary: the pre-0019
//! thinking dialects expanded into the new `[llm] format` +
//! `[llm.overlays]` keys, byte for byte.
//!
//! Preset model names drift with every provider generation and are
//! never liveness-tested — the open shape is freely editable, a preset
//! is only a starting point, and a stale name is the user's one-field
//! fix.

use serde_json::{Map, Value};

use crate::format::Format;
use crate::vendor::Vendor;

/// One chip's fill (ADR-0019): what a click stamps onto the connection
/// card. URL overwrites unconditionally; the pane's model rule (only
/// when empty or still a preset name) and the custom blank preset live
/// in the pane, not here.
#[derive(Debug, Clone, PartialEq)]
pub struct Preset {
    pub name: &'static str,
    pub format: Format,
    pub base_url: &'static str,
    pub model: &'static str,
    /// The 「设置思考字段」 switch the chip sets.
    pub thinking_fields: bool,
    pub thinking_on: Map<String, Value>,
    pub thinking_off: Map<String, Value>,
}

/// Every named preset, chip order (custom, the blank seventh, is not a
/// row here — it holds the current format and blanks every field).
pub fn all() -> Vec<Preset> {
    vec![
        preset(
            "deepseek",
            Format::OpenaiChat,
            "https://api.deepseek.com",
            "deepseek-flash",
            // absorb-clock 05: the effort companion rides the chip too,
            // so a preset save cannot revert the default to the
            // endpoint's high.
            r#"{"thinking":{"type":"enabled"},"reasoning_effort":"low"}"#,
            r#"{"thinking":{"type":"disabled"}}"#,
        ),
        preset(
            "volcengine",
            Format::OpenaiChat,
            "https://ark.cn-beijing.volces.com/api/v3",
            // The one row the spec flags for a console re-check
            // (design-spec §4.4, 2026-09-17 table).
            "doubao-seed-2.0-lite",
            r#"{"thinking":{"type":"enabled"}}"#,
            r#"{"thinking":{"type":"disabled"}}"#,
        ),
        preset(
            "qwen",
            Format::OpenaiChat,
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "qwen3.8-flash",
            r#"{"enable_thinking":true}"#,
            r#"{"enable_thinking":false}"#,
        ),
        // The off share is explicit — "none", not omitted: on the new
        // OpenAI generation an omission is not off but the adaptive
        // default, and DeepSeek's default has already flipped to on
        // (ADR-0019 item 2).
        preset(
            "openai",
            Format::OpenaiChat,
            "https://api.openai.com/v1",
            "gpt-5.6-terra",
            r#"{"reasoning_effort":"medium"}"#,
            r#"{"reasoning_effort":"none"}"#,
        ),
        preset(
            "anthropic",
            Format::Anthropic,
            "https://api.anthropic.com",
            "claude-sonnet-5",
            r#"{"thinking":{"type":"adaptive"}}"#,
            r#"{"thinking":{"type":"disabled"}}"#,
        ),
        preset(
            "gemini",
            Format::Gemini,
            "https://generativelanguage.googleapis.com/v1beta",
            "gemini-3.8-flash",
            // Only includeThoughts opens the thinking channel; "low" is
            // as low as the level goes — 3.x cannot be turned off.
            r#"{"generationConfig":{"thinkingConfig":{"thinkingLevel":"medium","includeThoughts":true}}}"#,
            r#"{"generationConfig":{"thinkingConfig":{"thinkingLevel":"low"}}}"#,
        ),
    ]
}

/// One preset by its file name (also the chip's wire name).
pub fn by_name(name: &str) -> Option<Preset> {
    all().into_iter().find(|preset| preset.name == name)
}

fn preset(
    name: &'static str,
    format: Format,
    base_url: &'static str,
    model: &'static str,
    thinking_on: &str,
    thinking_off: &str,
) -> Preset {
    Preset {
        name,
        format,
        base_url,
        model,
        thinking_fields: true,
        thinking_on: object(thinking_on),
        thinking_off: object(thinking_off),
    }
}

/// A known-good JSON object literal into its map.
fn object(text: &str) -> Map<String, Value> {
    serde_json::from_str::<Value>(text)
        .expect("preset literals are valid JSON")
        .as_object()
        .expect("preset literals are JSON objects")
        .clone()
}

// -- the legacy migration dictionary (ADR-0019 item 4) ------------------------

/// One pre-0019 thinking dialect's two shares — built FROM
/// `Vendor::thinking_fields`, so the two faces hold by construction and
/// the legacy pair list stays the one source. Since absorb-clock 05 the
/// deepseek on share carries `reasoning_effort: "low"` on BOTH faces
/// (the probe's clock/token ruling — "medium" was a no-op that mapped
/// up to high). The one deliberate difference left from the new presets
/// is plain openai's off share, empty here (it sent nothing), where the
/// new openai preset writes an explicit `"none"`.
pub fn legacy_shares(dialect: Vendor) -> (Map<String, Value>, Map<String, Value>) {
    let mut on = Map::new();
    for (field, value) in dialect.thinking_fields(true) {
        on.insert(field.into(), value);
    }
    let mut off = Map::new();
    for (field, value) in dialect.thinking_fields(false) {
        off.insert(field.into(), value);
    }
    (on, off)
}

/// The read-time grandfather's expansion (ADR-0019 item 4): one legacy
/// endpoint's dialect, custom overlay, and `[llm.extra_body]` hold,
/// folded into the new keys. The two shares compose in the pre-0019
/// merge precedence — dialect fields, then the custom overlay, then the
/// hold — so an upgraded build, before any save touches the files,
/// sends byte-identical requests.
pub fn grandfather(
    dialect: Vendor,
    custom_extra: Option<&Map<String, Value>>,
    hold: Option<&Map<String, Value>>,
) -> Grandfathered {
    let (format, mut on, mut off) = match dialect {
        Vendor::DeepSeek | Vendor::Volcengine | Vendor::Qwen | Vendor::OpenAi | Vendor::Custom => {
            // Custom never reaches here as a dialect (the caller passes
            // the slot's stored dialect); its safety default is the
            // openai shape, same as the dialect parser's.
            let (on, off) = legacy_shares(dialect);
            (Format::OpenaiChat, on, off)
        }
        Vendor::Anthropic | Vendor::Gemini => {
            // A slot the pre-0019 world never had: its only coherent
            // grandfather is its own preset.
            let preset = by_name(dialect.as_str()).expect("anthropic and gemini have presets");
            (
                preset.format,
                preset.thinking_on.clone(),
                preset.thinking_off.clone(),
            )
        }
    };
    for extra in [custom_extra, hold].into_iter().flatten() {
        for (field, value) in extra {
            on.insert(field.clone(), value.clone());
            off.insert(field.clone(), value.clone());
        }
    }
    Grandfathered {
        format,
        thinking_fields: true,
        thinking_on: on,
        thinking_off: off,
    }
}

/// The grandfather's whole new-key fill.
pub struct Grandfathered {
    pub format: Format,
    pub thinking_fields: bool,
    pub thinking_on: Map<String, Value>,
    pub thinking_off: Map<String, Value>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The single source matches the spec's preset table (design-spec
    /// §4.4, the 04-research table) row for row.
    #[test]
    fn the_preset_table_matches_the_spec() {
        let presets = all();
        assert_eq!(
            presets.len(),
            6,
            "six named presets, custom rides separately"
        );
        let row = |name: &str| {
            presets
                .iter()
                .find(|preset| preset.name == name)
                .unwrap_or_else(|| panic!("{name} missing"))
        };
        assert_eq!(row("deepseek").model, "deepseek-flash");
        // absorb-clock 05: the chip's on share carries the effort too, so
        // a preset save cannot revert the default to the endpoint's high.
        assert_eq!(
            row("deepseek").thinking_on["reasoning_effort"],
            json!("low")
        );
        let volcengine = row("volcengine");
        assert_eq!(
            volcengine.base_url,
            "https://ark.cn-beijing.volces.com/api/v3"
        );
        assert_eq!(volcengine.model, "doubao-seed-2.0-lite");
        let qwen = row("qwen");
        assert_eq!(
            qwen.base_url,
            "https://dashscope.aliyuncs.com/compatible-mode/v1"
        );
        assert_eq!(qwen.thinking_off["enable_thinking"], json!(false));
        let openai = row("openai");
        assert_eq!(openai.thinking_on["reasoning_effort"], json!("medium"));
        // Off is explicit, never omitted.
        assert_eq!(openai.thinking_off["reasoning_effort"], json!("none"));
        assert_eq!(row("anthropic").format, Format::Anthropic);
        assert_eq!(row("anthropic").base_url, "https://api.anthropic.com");
        let gemini = row("gemini");
        assert_eq!(gemini.format, Format::Gemini);
        assert_eq!(
            gemini.thinking_on["generationConfig"]["thinkingConfig"]["includeThoughts"],
            json!(true)
        );
        // Every named preset switches thinking on.
        assert!(presets.iter().all(|preset| preset.thinking_fields));
        // The names are the vendor slot names, so a chip click names a
        // slot and a preset at once.
        for preset in &presets {
            assert!(Vendor::from_str_name(preset.name).is_some());
            assert!(by_name(preset.name).is_some());
        }
    }

    /// The migration dictionary preserves the pre-0019 pair shapes:
    /// deepseek's on share keeps the effort companion (at "low" since
    /// absorb-clock 05, not the pre-0019 "medium"), openai's off share
    /// stays empty.
    #[test]
    fn the_legacy_dictionary_preserves_the_old_pairs() {
        let (on, off) = legacy_shares(Vendor::DeepSeek);
        assert_eq!(
            Value::Object(on),
            json!({"thinking": {"type": "enabled"}, "reasoning_effort": "low"})
        );
        assert_eq!(
            Value::Object(off),
            json!({"thinking": {"type": "disabled"}})
        );
        let (on, off) = legacy_shares(Vendor::OpenAi);
        assert_eq!(Value::Object(on), json!({"reasoning_effort": "medium"}));
        assert!(off.is_empty(), "the old openai off sent nothing: {off:?}");
        let (_, off) = legacy_shares(Vendor::Qwen);
        assert_eq!(Value::Object(off), json!({"enable_thinking": false}));
    }

    /// The grandfather composes in the pre-0019 precedence: dialect
    /// fields first, then the custom overlay, then the hold — a key the
    /// hold also names is the hold's.
    #[test]
    fn the_grandfather_folds_the_overlays_in_the_old_precedence() {
        let custom = object(r#"{"thinking": {"type": "enabled"}, "top_p": 0.9}"#);
        let hold = object(r#"{"top_p": 0.5}"#);
        let folded = grandfather(Vendor::Volcengine, Some(&custom), Some(&hold));
        assert_eq!(folded.format, Format::OpenaiChat);
        assert!(folded.thinking_fields);
        assert_eq!(
            Value::Object(folded.thinking_on),
            json!({"thinking": {"type": "enabled"}, "top_p": 0.5})
        );
        // The off share folds the same way, from the dialect's off pair —
        // and the custom overlay's enabled overrides the dialect's
        // disabled exactly as the old body's merge order did.
        assert_eq!(
            Value::Object(folded.thinking_off),
            json!({"thinking": {"type": "enabled"}, "top_p": 0.5})
        );
    }

    /// Without legacy overlays the grandfather is the bare dictionary —
    /// the default deepseek endpoint's shares, byte for byte.
    #[test]
    fn the_grandfather_without_legacy_overlays_is_the_dictionary() {
        let folded = grandfather(Vendor::DeepSeek, None, None);
        let (on, off) = legacy_shares(Vendor::DeepSeek);
        assert_eq!(folded.thinking_on, on);
        assert_eq!(folded.thinking_off, off);
    }

    /// The two never-dialect slots grandfather to their own presets.
    #[test]
    fn the_new_slots_grandfather_to_their_presets() {
        for name in ["anthropic", "gemini"] {
            let dialect = Vendor::from_str_name(name).unwrap();
            let folded = grandfather(dialect, None, None);
            let preset = by_name(name).unwrap();
            assert_eq!(folded.format, preset.format);
            assert_eq!(folded.thinking_on, preset.thinking_on);
            assert_eq!(folded.thinking_off, preset.thinking_off);
        }
    }
}
