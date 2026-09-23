//! The library domain: the scenario library (场景库), the hotword
//! dictionary (术语), and the global directive (全局指令).

use anyhow::anyhow;

use super::state::global;

/// Dart-side mirror of one scenario (场景): a user-named style directive
/// from the scenario library. `id` carries the table row's identity —
/// `None` only on an entry the editor has not saved yet — so a rename
/// keeps it and the history rows referencing the scenario with it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeScenario {
    pub id: Option<i64>,
    pub name: String,
    pub directive: String,
}

impl From<spokenrectifier_store::Scenario> for BridgeScenario {
    fn from(value: spokenrectifier_store::Scenario) -> Self {
        BridgeScenario {
            id: Some(value.id),
            name: value.name,
            directive: value.directive,
        }
    }
}

/// The hotword dictionary as it stands now, in stored order — the quick
/// panel's term chips. Store-level, engine-independent (the engine
/// re-reads the table when the next session opens, which is what makes a
/// quick-added term live for that session).
pub fn terms_list() -> anyhow::Result<Vec<String>> {
    Ok(global()?.store.list_terms())
}

/// Quick-add one term to the dictionary (idempotent; blank rejected;
/// appended at the end of the order).
pub fn append_term(term: String) -> anyhow::Result<()> {
    global()?
        .store
        .append_term(&term)
        .map_err(|err| anyhow!("cannot add the term: {err}"))
}

/// Remove a term from the dictionary (a no-op when absent; the positions
/// close the gap inside the same transaction).
pub fn remove_term(term: String) -> anyhow::Result<()> {
    global()?
        .store
        .remove_term(&term)
        .map_err(|err| anyhow!("cannot remove the term: {err}"))
}

/// The scenario library (场景库): user-named style directives from the
/// store, in editor order. The shell paints its pickers from the list
/// and resolves the selected entry's directive text itself (selection
/// lives app-side, never persisted; ADR-0004).
pub fn scenarios() -> anyhow::Result<Vec<BridgeScenario>> {
    Ok(global()?
        .store
        .list_scenarios()
        .into_iter()
        .map(BridgeScenario::from)
        .collect())
}

/// Save the whole scenario library — the settings editor's model,
/// wholesale — into the store: one transaction that updates identified
/// rows in place (a rename keeps its identity and its history
/// references), inserts the new ones, deletes the rest. Store-level and
/// engine-independent like [`scenarios`]: the pickers re-read the
/// library after a save; the selected scenario's directive rides the
/// next `SetStyleDirective` as usual. Only ever runs on a user action
/// (the editor's add/edit/delete), never on load.
pub fn save_scenarios(scenarios: Vec<BridgeScenario>) -> anyhow::Result<()> {
    let entries: Vec<spokenrectifier_store::ScenarioInput> = scenarios
        .into_iter()
        .map(|scenario| spokenrectifier_store::ScenarioInput {
            id: scenario.id,
            name: scenario.name,
            directive: scenario.directive,
        })
        .collect();
    global()?
        .store
        .save_scenarios(&entries)
        .map_err(|err| anyhow!("cannot save the scenario library: {err}"))
}

/// The global directive (全局指令, ticket 22): the single `directive` key
/// from the app-owned `spokenrectifier-global.toml` — a companion file of
/// the scenario library's, so a library rewrite cannot lose it. A
/// missing, corrupt, or blank file reads as `None` (unset); this never
/// errors and never writes. The shell pushes the text at the engine via
/// `SetGlobalDirective` and repaints its preview from this same read.
pub fn global_directive() -> anyhow::Result<Option<String>> {
    let dirs = spokenrectifier_config::search_dirs();
    Ok(spokenrectifier_config::global::load_global_directive(&dirs))
}

/// Save the global directive into the file the loader resolves (created
/// in the app's settings home when none exists yet). `None` and blank
/// text both write the canonical unset form — clearing the field and
/// saving is the off switch. File-level and engine-independent like
/// [`global_directive`]: the main window re-reads the file and pushes the
/// fresh text at the engine (`SetGlobalDirective`) on the
/// global-changed event. Only ever runs on a user action.
pub fn save_global_directive(directive: Option<String>) -> anyhow::Result<()> {
    let dirs = spokenrectifier_config::search_dirs();
    spokenrectifier_config::global::save_global_directive(&dirs, directive.as_deref())
        .map_err(|err| anyhow!("cannot save the global directive: {err}"))
}

/// Rename a term in the dictionary, in place (the settings editor's 改;
/// the quick panel's quick-add and quick-remove stay the same calls).
/// Renaming onto a held spelling is refused.
pub fn update_term(old: String, new: String) -> anyhow::Result<()> {
    global()?
        .store
        .update_term(&old, &new)
        .map_err(|err| anyhow!("cannot rename the term: {err}"))
}
