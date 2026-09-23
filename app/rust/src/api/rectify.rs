//! The rectify domain (修正, ticket 13): the `[rectify]` behavior the
//! pane paints and saves, both tiers plus the quick-mode sub-section.

use anyhow::anyhow;

use spokenrectifier_engine::Command;

use super::state::global;

/// The `[rectify]` behavior as the settings pane paints and saves it:
/// both tiers' thinking policy and prefill, the light-touch master
/// switch, threshold, and extra directive (ADR-0015/0016), plus the
/// quick-mode sub-section (ADR-0020). One struct both ways — the read
/// paints the initial form, the save writes exactly the model it
/// receives. The thinking policy rides the wire as its lowercase string;
/// `light_touch_extra_directive` and `quick_extra_directive` are `None`
/// when unset (empty saves remove the key).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeRectifyBehavior {
    /// `always` | `placeholders` | `off` (ADR-0015).
    pub full_thinking_policy: String,
    pub full_prefill: bool,
    pub light_touch_enabled: bool,
    pub light_touch_max_chars: u64,
    pub light_touch_thinking_policy: String,
    pub light_touch_prefill: bool,
    pub light_touch_extra_directive: Option<String>,
    /// `[rectify.quick]` (ADR-0020): holding the main hotkey past the
    /// threshold upgrades the session, which then skips preview and
    /// pastes on its own. `quick_enabled` is the master switch (off by
    /// default: no hold upgrades anything), `quick_rectify` whether the
    /// session still rectifies (off = paste the raw transcript),
    /// `quick_extra_directive` the quick-mode-only directive (`None` =
    /// unset; an empty save removes the key).
    pub quick_enabled: bool,
    pub quick_rectify: bool,
    pub quick_extra_directive: Option<String>,
    /// The CONNECTION domain's thinking reading (`on` / `off` /
    /// `unconfigured` / `broken`): the two cards' thinking-policy chips
    /// are disabled and the combination warning silenced while the
    /// connection's fields are inert (ADR-0019 item 3; design-spec
    /// §4.4's 修正 section). Carried on this read because the cards
    /// paint from it and nothing else — one round trip, and a chip
    /// click's re-read keeps the disable state fresh.
    pub connection_thinking: String,
}

pub(crate) fn rectify_view(config: &spokenrectifier_llm::LlmConfig) -> BridgeRectifyBehavior {
    let rectify = &config.rectify;
    BridgeRectifyBehavior {
        full_thinking_policy: rectify.full.thinking_policy.as_str().to_string(),
        full_prefill: rectify.full.prefill,
        light_touch_enabled: rectify.light_touch.enabled,
        light_touch_max_chars: rectify.light_touch.max_chars as u64,
        light_touch_thinking_policy: rectify
            .light_touch
            .tier
            .thinking_policy
            .as_str()
            .to_string(),
        light_touch_prefill: rectify.light_touch.tier.prefill,
        light_touch_extra_directive: rectify.light_touch.extra_directive.clone(),
        quick_enabled: rectify.quick.enabled,
        quick_rectify: rectify.quick.rectify,
        quick_extra_directive: rectify.quick.extra_directive.clone(),
        connection_thinking: config.model.thinking.state.as_str().to_string(),
    }
}

pub(crate) fn parse_policy(
    section: &str,
    name: &str,
) -> anyhow::Result<spokenrectifier_llm::ThinkingPolicy> {
    spokenrectifier_llm::ThinkingPolicy::from_str_name(name).ok_or_else(|| {
        anyhow!(
            "[{section}] thinking_policy \"{name}\" is unknown: pick one of \
             \"always\", \"placeholders\", \"off\""
        )
    })
}

/// The effective `[rectify]` behavior from the layer files — the
/// rectify pane's initial paint, legacy `[llm]` keys already folded in
/// through the grandfather (ADR-0015). File-level and
/// engine-independent: the client adopts the keys at its (re)build, and
/// the window's save re-adopts at once via [`apply_connection_configs`].
pub fn rectify_behavior() -> anyhow::Result<BridgeRectifyBehavior> {
    let dirs = spokenrectifier_config::search_dirs();
    let config =
        spokenrectifier_llm::load_llm_config(&dirs).map_err(|err| anyhow!("LLM {}", err.0))?;
    Ok(rectify_view(&config))
}

/// Write the rectify editor's whole model back into the layer files (see
/// `save_rectify_behavior`: the owning layers, the per-layer legacy-key
/// translation on the first save, the extra directive's blank-removal)
/// and return the re-read view — the files' truth, not the ask. No
/// combination validation rides this path: a thinking-off × prefill-on
/// tier saves fine, the pane's live warning is presentation only
/// (`.scratch/settings-window/issues/08`, ruling 4). The window calls
/// [`apply_connection_configs`] right after — the next attempt runs the
/// new behavior.
pub fn set_rectify_behavior(edit: BridgeRectifyBehavior) -> anyhow::Result<BridgeRectifyBehavior> {
    let dirs = spokenrectifier_config::search_dirs();
    let full = spokenrectifier_llm::TierEdit {
        thinking_policy: parse_policy("rectify.full", &edit.full_thinking_policy)?,
        prefill: edit.full_prefill,
    };
    let light = spokenrectifier_llm::LightTouchEdit {
        enabled: edit.light_touch_enabled,
        max_chars: usize::try_from(edit.light_touch_max_chars).map_err(|_| {
            anyhow!(
                "[rectify.light_touch] max_chars {} is out of range",
                edit.light_touch_max_chars
            )
        })?,
        tier: spokenrectifier_llm::TierEdit {
            thinking_policy: parse_policy(
                "rectify.light_touch",
                &edit.light_touch_thinking_policy,
            )?,
            prefill: edit.light_touch_prefill,
        },
        extra_directive: edit.light_touch_extra_directive,
    };
    let quick = spokenrectifier_llm::QuickEdit {
        enabled: edit.quick_enabled,
        rectify: edit.quick_rectify,
        extra_directive: edit.quick_extra_directive,
    };
    spokenrectifier_llm::save_rectify_behavior(
        &dirs,
        &spokenrectifier_llm::RectifyBehaviorEdit {
            full,
            light_touch: light,
            quick,
        },
    )
    .map_err(|err| anyhow!("LLM {}", err.0))?;
    let saved = rectify_behavior()?;
    // The live engine adopts the quick switches at once, exactly like the
    // advanced form's timings: `enabled` gates the next hold, `rectify`
    // the next session's snapshot. Internal to the save — no Dart-facing
    // command, because the save itself is one bridge call.
    let g = global()?;
    g.rt.block_on(g.engine.execute(Command::SetQuickMode {
        enabled: saved.quick_enabled,
        rectify: saved.quick_rectify,
    }))?;
    Ok(saved)
}
