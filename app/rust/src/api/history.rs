//! The history domain: the stored-session list the panels read and the
//! `[history]` settings the pane paints and saves.

use anyhow::anyhow;

use spokenrectifier_store::{HistoryConfig, HistoryEntry, ScenarioFilter};

use super::state::global;

/// Dart-side mirror of the history store's row: one stored session.
/// `scenario_id` is the row's scenario (`None` = 未选场景, the default
/// register).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeHistoryEntry {
    pub id: i64,
    /// Unix-epoch milliseconds, for the panel's timestamps.
    pub created_at_ms: u64,
    pub raw_transcript: String,
    pub rectified_text: String,
    pub scenario_id: Option<i64>,
}

impl From<HistoryEntry> for BridgeHistoryEntry {
    fn from(value: HistoryEntry) -> Self {
        BridgeHistoryEntry {
            id: value.id,
            created_at_ms: value.created_at_ms,
            raw_transcript: value.raw_transcript,
            rectified_text: value.rectified_text,
            scenario_id: value.scenario_id,
        }
    }
}

/// Dart-side mirror of [`ScenarioFilter`]: the settings pane's history
/// chip row — all sessions, the default register's (未选场景), or one
/// scenario's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeHistoryFilter {
    All,
    DefaultRegister,
    Scenario(i64),
}

impl From<BridgeHistoryFilter> for ScenarioFilter {
    fn from(value: BridgeHistoryFilter) -> Self {
        match value {
            BridgeHistoryFilter::All => ScenarioFilter::All,
            BridgeHistoryFilter::DefaultRegister => ScenarioFilter::DefaultRegister,
            BridgeHistoryFilter::Scenario(id) => ScenarioFilter::Scenario(id),
        }
    }
}

/// How many sessions the history panel lists per fetch.
const HISTORY_PANEL_LIMIT: usize = 200;

/// The most recent stored sessions, newest first — the history panel's
/// content, read through the sessions⋈scenarios view with the scenario
/// scope the settings pane's chip row selects (the quick panel's slice
/// always asks for [`BridgeHistoryFilter::All`]). Empty in the
/// keep-nothing mode (and on the fake engine's ephemeral store).
pub fn history_list(filter: BridgeHistoryFilter) -> anyhow::Result<Vec<BridgeHistoryEntry>> {
    Ok(global()?
        .store
        .list(HISTORY_PANEL_LIMIT, filter.into())
        .into_iter()
        .map(BridgeHistoryEntry::from)
        .collect())
}

/// Remove every stored session — the tray's one-click clear (the
/// placeholders go with them, by CASCADE). A no-op in the keep-nothing
/// mode.
pub fn history_clear() -> anyhow::Result<()> {
    global()?.store.clear();
    Ok(())
}

/// Dart-side mirror of the `[history]` settings (保留期 / 不留存).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BridgeHistoryConfig {
    pub enabled: bool,
    pub retention_days: u64,
}

impl From<HistoryConfig> for BridgeHistoryConfig {
    fn from(value: HistoryConfig) -> Self {
        BridgeHistoryConfig {
            enabled: value.enabled,
            retention_days: value.retention_days,
        }
    }
}

/// The `[history]` config errors share one shape across the pair.
fn history_config_err(err: spokenrectifier_store::HistoryConfigError) -> anyhow::Error {
    anyhow!("history {}", err.0)
}

/// The effective `[history]` settings from the layer files — the
/// settings window's history pane initial paint.
pub fn history_config() -> anyhow::Result<BridgeHistoryConfig> {
    let dirs = spokenrectifier_config::search_dirs();
    spokenrectifier_store::load_history_config(&dirs)
        .map(BridgeHistoryConfig::from)
        .map_err(history_config_err)
}

/// Write new `[history]` settings and apply them to the live store at
/// once (the settings window's 保留期 / 不留存 controls): the file edit
/// is section-preserving in the layer that owns the effective values,
/// and the store adopts the new config immediately — a tightened
/// retention sweeps at once, keep-nothing clears the sessions rows (the
/// database itself stays, as the scenarios' and terms' home), and
/// turning it back on resumes recording. Returns the re-read effective
/// config.
pub fn set_history_config(
    enabled: bool,
    retention_days: u64,
) -> anyhow::Result<BridgeHistoryConfig> {
    let dirs = spokenrectifier_config::search_dirs();
    let config = HistoryConfig {
        enabled,
        retention_days,
    };
    spokenrectifier_store::save_history_config(&dirs, &config).map_err(history_config_err)?;
    global()?
        .store
        .apply_config(config)
        .map_err(|err| anyhow!("history {}", err.0))?;
    history_config()
}
