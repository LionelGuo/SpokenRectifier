//! The folded `[llm]`/`[rectify]` types and their defaults.

use std::collections::BTreeMap;

use serde_json::{Map, Value};
use spokenrectifier_config::section_write::KeyStatus;

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
    pub(super) fn from_legacy_bool(on: bool) -> Self {
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
    /// The v1 default: DeepSeek's flash model (`deepseek-flash`; the
    /// provider renamed it from `deepseek-v4-flash`, which still
    /// resolves) over today's rectify behavior (thinking always, prefill
    /// on, light-touch gate open at 40 characters, no extra directive).
    /// Every vendor's key slot starts empty (the conventional environment
    /// names apply at resolution).
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
                model: "deepseek-flash".into(),
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
        assert_eq!(config.model.model, "deepseek-flash");
        assert_eq!(config.model.vendor, Vendor::DeepSeek);
        assert_eq!(
            config.model.api_key_env.as_deref(),
            Some("DEEPSEEK_API_KEY")
        );
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
