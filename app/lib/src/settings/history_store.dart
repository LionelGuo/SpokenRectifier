/// The settings window's history seam: the `[history]` config (保留期 /
/// 不留存) and the stored sessions, read and written directly through
/// the Rust bridge — file-level like the scenario store, so the
/// settings engine never mirrors state across windows. Injectable so
/// widget tests run with an in-memory fake and no Rust dylib.

library;

import '../rust/api.dart' as rust
    show BridgeHistoryConfig, historyClear, historyConfig, historyList, setHistoryConfig;
import '../rust/api.dart' show BridgeHistoryEntry;

/// The `[history]` settings as the pane paints them — plain Dart ints
/// (the wire's u64 arrives as BigInt; the seam converts).
class HistorySettings {
  const HistorySettings({required this.enabled, required this.retentionDays});

  final bool enabled;
  final int retentionDays;

  HistorySettings copyWith({bool? enabled, int? retentionDays}) => HistorySettings(
    enabled: enabled ?? this.enabled,
    retentionDays: retentionDays ?? this.retentionDays,
  );

  @override
  bool operator ==(Object other) =>
      other is HistorySettings &&
      other.enabled == enabled &&
      other.retentionDays == retentionDays;

  @override
  int get hashCode => Object.hash(enabled, retentionDays);
}

/// History persistence and config as the history domain needs it.
abstract class HistorySettingsStore {
  /// The effective `[history]` settings from the layer files.
  Future<HistorySettings> loadConfig();

  /// Write both settings and apply them to the live store; returns the
  /// re-read effective config (the file's truth, not the ask).
  Future<HistorySettings> saveConfig(HistorySettings settings);

  /// The most recent stored sessions, newest first.
  Future<List<BridgeHistoryEntry>> list();

  /// Remove every stored session (the tray's one-click clear, same
  /// bridge call).
  Future<void> clear();
}

/// The production store over the flutter_rust_bridge calls.
class RustHistorySettingsStore implements HistorySettingsStore {
  const RustHistorySettingsStore();

  @override
  Future<HistorySettings> loadConfig() async =>
      _fromWire(await rust.historyConfig());

  @override
  Future<HistorySettings> saveConfig(HistorySettings settings) async =>
      _fromWire(
        await rust.setHistoryConfig(
          enabled: settings.enabled,
          retentionDays: BigInt.from(settings.retentionDays),
        ),
      );

  @override
  Future<List<BridgeHistoryEntry>> list() => rust.historyList();

  @override
  Future<void> clear() => rust.historyClear();

  static HistorySettings _fromWire(rust.BridgeHistoryConfig config) =>
      HistorySettings(
        enabled: config.enabled,
        retentionDays: config.retentionDays.toInt(),
      );
}
