/// The settings window's data seam: the scenario library file, read and
/// written directly through the Rust bridge (ADR: the file is the single
/// source — the settings engine never mirrors library state across
/// windows, it re-reads after every change). Injectable so widget tests
/// run against an in-memory library with no Rust dylib.

library;

import '../rust/api.dart' as rust show saveScenarios, scenarios;
import '../rust/api.dart' show BridgeScenario;

/// Scenario-library persistence as the settings window needs it.
abstract class ScenarioStore {
  /// The library as the loader reads it (missing/corrupt file = empty).
  Future<List<BridgeScenario>> load();

  /// Persist the editor's whole model, wholesale (see the Rust
  /// `save_scenarios` for the placement and tolerance rules).
  Future<void> save(List<BridgeScenario> scenarios);
}

/// The production store over the flutter_rust_bridge calls.
class RustScenarioStore implements ScenarioStore {
  const RustScenarioStore();

  @override
  Future<List<BridgeScenario>> load() => rust.scenarios();

  @override
  Future<void> save(List<BridgeScenario> scenarios) =>
      rust.saveScenarios(scenarios: scenarios);
}
