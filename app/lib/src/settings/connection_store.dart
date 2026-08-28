/// The settings window's connection seam: the effective `[asr]` / `[llm]`
/// sections from the layer files, read and written directly through the
/// Rust bridge. The stored api_key never rides this seam — only its
/// placement ([KeyInfo]) and the edit the user asks for ([ApiKeyEdit]):
/// the key's only legal home is the git-ignored local layer, and the
/// write path enforces that (ticket 19's 定案; the shared file's
/// key-rejection guard stays untouched and tested).
///
/// File-level and engine-independent: the engine adopts the config at
/// its creation, so a save here applies from the next launch on (the
/// pane says so). Injectable so widget tests run with an in-memory
/// model and no Rust dylib.

library;

import '../rust/api.dart' as rust
    show BridgeKeyEdit, connectionConfig, setAsrConnection, setLlmConnection;
import '../rust/api.dart'
    show
        BridgeAsrConnection,
        BridgeKeyStatus,
        BridgeKeyStatus_FromEnv,
        BridgeKeyStatus_InLocalFile,
        BridgeKeyStatus_Unset,
        BridgeLlmConnection;

/// A secret's placement for display — never the secret itself.
class KeyInfo {
  const KeyInfo({required this.status, this.envName});

  final KeyPlacement status;

  /// The environment variable name when [status] is fromEnv.
  final String? envName;

  /// The one-line status caption the pane paints.
  String get label => switch (status) {
    KeyPlacement.unset => '未配置',
    KeyPlacement.inLocalFile => '已保存在本机 local 文件',
    KeyPlacement.fromEnv => '取自环境变量 $envName',
  };

  @override
  bool operator ==(Object other) =>
      other is KeyInfo && other.status == status && other.envName == envName;

  @override
  int get hashCode => Object.hash(status, envName);
}

enum KeyPlacement { unset, inLocalFile, fromEnv }

/// What a save does to the api_key: the field paints empty, so "keep"
/// is the default action; the clear button clears.
sealed class ApiKeyEdit {
  const ApiKeyEdit();
}

class ApiKeyKeep extends ApiKeyEdit {
  const ApiKeyKeep();
}

class ApiKeyClear extends ApiKeyEdit {
  const ApiKeyClear();
}

class ApiKeySet extends ApiKeyEdit {
  const ApiKeySet(this.key);

  final String key;
}

/// The effective `[asr]` connection as the pane paints it (plain Dart
/// optionals; the wire's shapes convert here).
class AsrConnection {
  const AsrConnection({
    required this.model,
    required this.language,
    required this.workspaceId,
    required this.region,
    required this.baseUrl,
    required this.endpoint,
    required this.key,
  });

  final String model;
  final String language;
  final String? workspaceId;
  final String region;
  final String? baseUrl;

  /// The WebSocket URL the current fields resolve to (read-only preview).
  final String endpoint;
  final KeyInfo key;

  @override
  bool operator ==(Object other) =>
      other is AsrConnection &&
      other.model == model &&
      other.language == language &&
      other.workspaceId == workspaceId &&
      other.region == region &&
      other.baseUrl == baseUrl &&
      other.key == key;

  @override
  int get hashCode =>
      Object.hash(model, language, workspaceId, region, baseUrl, key);
}

/// The effective `[llm]` connection as the pane paints it.
class LlmConnection {
  const LlmConnection({
    required this.vendor,
    required this.baseUrl,
    required this.model,
    required this.key,
  });

  final String vendor;
  final String baseUrl;
  final String model;
  final KeyInfo key;

  @override
  bool operator ==(Object other) =>
      other is LlmConnection &&
      other.vendor == vendor &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.key == key;

  @override
  int get hashCode => Object.hash(vendor, baseUrl, model, key);
}

/// Connection persistence as the connection domain needs it.
abstract class ConnectionStore {
  /// The effective `[asr]` and `[llm]` connections from the layer files.
  Future<({AsrConnection asr, LlmConnection llm})> load();

  /// Write the editor's `[asr]` model; returns the re-read view (the
  /// file's truth, not the ask).
  Future<AsrConnection> saveAsr({
    required String model,
    required String language,
    required String? workspaceId,
    required String region,
    required String? baseUrl,
    required ApiKeyEdit apiKey,
  });

  /// Write the editor's `[llm]` model; returns the re-read view.
  Future<LlmConnection> saveLlm({
    required String vendor,
    required String baseUrl,
    required String model,
    required ApiKeyEdit apiKey,
  });
}

/// The production store over the flutter_rust_bridge calls.
class RustConnectionStore implements ConnectionStore {
  const RustConnectionStore();

  @override
  Future<({AsrConnection asr, LlmConnection llm})> load() async {
    final config = await rust.connectionConfig();
    return (asr: _asrFromWire(config.asr), llm: _llmFromWire(config.llm));
  }

  @override
  Future<AsrConnection> saveAsr({
    required String model,
    required String language,
    required String? workspaceId,
    required String region,
    required String? baseUrl,
    required ApiKeyEdit apiKey,
  }) =>
      rust
          .setAsrConnection(
            model: model,
            language: language,
            workspaceId: workspaceId,
            region: region,
            baseUrl: baseUrl,
            apiKey: _keyToWire(apiKey),
          )
          .then(_asrFromWire);

  @override
  Future<LlmConnection> saveLlm({
    required String vendor,
    required String baseUrl,
    required String model,
    required ApiKeyEdit apiKey,
  }) =>
      rust
          .setLlmConnection(
            vendor: vendor,
            baseUrl: baseUrl,
            model: model,
            apiKey: _keyToWire(apiKey),
          )
          .then(_llmFromWire);

  static rust.BridgeKeyEdit _keyToWire(ApiKeyEdit edit) => switch (edit) {
    ApiKeyKeep() => const rust.BridgeKeyEdit.keep(),
    ApiKeyClear() => const rust.BridgeKeyEdit.clear(),
    ApiKeySet(:final key) => rust.BridgeKeyEdit.set_(key),
  };

  static KeyInfo _keyFromWire(BridgeKeyStatus status) => switch (status) {
    BridgeKeyStatus_Unset() => const KeyInfo(status: KeyPlacement.unset),
    BridgeKeyStatus_InLocalFile() => const KeyInfo(
      status: KeyPlacement.inLocalFile,
    ),
    BridgeKeyStatus_FromEnv(:final field0) => KeyInfo(
      status: KeyPlacement.fromEnv,
      envName: field0,
    ),
  };

  static AsrConnection _asrFromWire(BridgeAsrConnection asr) => AsrConnection(
    model: asr.model,
    language: asr.language,
    workspaceId: asr.workspaceId,
    region: asr.region,
    baseUrl: asr.baseUrl,
    endpoint: asr.endpoint,
    key: _keyFromWire(asr.key),
  );

  static LlmConnection _llmFromWire(BridgeLlmConnection llm) => LlmConnection(
    vendor: llm.vendor,
    baseUrl: llm.baseUrl,
    model: llm.model,
    key: _keyFromWire(llm.key),
  );
}
