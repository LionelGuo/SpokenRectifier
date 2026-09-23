/// The settings window's connection seam: the effective `[asr]` / `[llm]`
/// sections from the layer files, read and written directly through the
/// Rust bridge. The stored api_key rides this seam only when it lives in
/// the git-ignored local layer ([KeyInfo.storedKey], for the diff-echo
/// field — masked by default in the pane); an environment key never
/// echoes a value. The write path still enforces the key's only legal
/// home (ticket 19's 定案, ADR-0008 revised 2026-08-28; the shared
/// file's key-rejection guard stays untouched and tested — extended to
/// the ASR sub-section secrets by ADR-0009 / ticket 24).
///
/// The `[asr]` card is one COMMON segment (provider / model / language /
/// api_key / base_url) plus one sub-section per vendor, switched by
/// provider — the UI is isomorphic to the schema (ADR-0009): switching
/// the provider repaints the sub-fields but never clears another
/// vendor's configuration.
///
/// File-level, with a runtime re-adoption seam: the engine adopts the
/// config at its creation, and every save re-adopts it at once
/// ([ConnectionStore.applyConnections], ADR-0010) — the next session
/// runs with the new ASR provider, the next rectify attempt with the new
/// LLM, no restart. A refused adoption (incomplete target config,
/// unadapted provider) throws while the files stay saved and the engine
/// keeps the previous providers. Injectable so widget tests run with an
/// in-memory model and no Rust dylib.

library;

import 'package:collection/collection.dart' show MapEquality;

import '../rust/api/connection.dart' as rust;

/// A key's state for the diff-echo field: its placement, plus the stored
/// value when (and only when) it lives in the local layer.
class KeyInfo {
  const KeyInfo({required this.status, this.envName, this.storedKey});

  final KeyPlacement status;

  /// The environment variable name when [status] is fromEnv.
  final String? envName;

  /// The stored key when [status] is inLocalFile — the value the field
  /// echoes (masked) and a save diffs against. Never set for an
  /// environment key: no env value ever crosses this seam.
  final String? storedKey;

  /// The one-line status caption the pane paints.
  String get label => switch (status) {
    KeyPlacement.unset => '未配置',
    KeyPlacement.inLocalFile => '已保存于本机',
    KeyPlacement.fromEnv => '取自环境变量 $envName',
  };

  @override
  bool operator ==(Object other) =>
      other is KeyInfo &&
      other.status == status &&
      other.envName == envName &&
      other.storedKey == storedKey;

  @override
  int get hashCode => Object.hash(status, envName, storedKey);
}

enum KeyPlacement { unset, inLocalFile, fromEnv }

/// What a save does to a secret field: the field echoes the stored local
/// key, so a save DIFFS the field against it — keep the stored one,
/// replace it, or clear it (one confirm in the pane).
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

/// `[asr.aliyun]` as the pane paints it.
class AsrAliyun {
  const AsrAliyun({required this.workspaceId, required this.region});

  final String? workspaceId;
  final String region;

  @override
  bool operator ==(Object other) =>
      other is AsrAliyun &&
      other.workspaceId == workspaceId &&
      other.region == region;

  @override
  int get hashCode => Object.hash(workspaceId, region);
}

/// `[asr.volcengine]` as the pane paints it.
class AsrVolcengine {
  const AsrVolcengine({
    required this.appId,
    required this.resourceId,
    required this.accessKey,
  });

  final String? appId;
  final String resourceId;
  final KeyInfo accessKey;

  @override
  bool operator ==(Object other) =>
      other is AsrVolcengine &&
      other.appId == appId &&
      other.resourceId == resourceId &&
      other.accessKey == accessKey;

  @override
  int get hashCode => Object.hash(appId, resourceId, accessKey);
}

/// `[asr.tencent]` as the pane paints it (adapter: ticket 25).
class AsrTencent {
  const AsrTencent({
    required this.appId,
    required this.secretId,
    required this.secretKey,
  });

  final String? appId;
  final KeyInfo secretId;
  final KeyInfo secretKey;

  @override
  bool operator ==(Object other) =>
      other is AsrTencent &&
      other.appId == appId &&
      other.secretId == secretId &&
      other.secretKey == secretKey;

  @override
  int get hashCode => Object.hash(appId, secretId, secretKey);
}

/// `[asr.azure]` as the pane paints it (adapter not scheduled).
class AsrAzure {
  const AsrAzure({required this.region, required this.endpointId});

  final String? region;
  final String? endpointId;

  @override
  bool operator ==(Object other) =>
      other is AsrAzure &&
      other.region == region &&
      other.endpointId == endpointId;

  @override
  int get hashCode => Object.hash(region, endpointId);
}

/// The effective `[asr]` connection as the pane paints it (plain Dart
/// optionals; the wire's shapes convert here).
class AsrConnection {
  const AsrConnection({
    required this.provider,
    required this.model,
    required this.language,
    required this.baseUrl,
    required this.endpoint,
    required this.key,
    required this.aliyun,
    required this.volcengine,
    required this.tencent,
    required this.azure,
  });

  /// `aliyun` / `volcengine` / `tencent` / `openai` / `azure`.
  final String provider;
  final String model;
  final String language;
  final String? baseUrl;

  /// The WebSocket URL the current fields resolve to (read-only
  /// preview); null for providers without an adapter yet.
  final String? endpoint;

  /// The common Bearer key pair (the active provider's when its family
  /// is the Bearer one: aliyun / openai / azure).
  final KeyInfo key;
  final AsrAliyun aliyun;
  final AsrVolcengine volcengine;
  final AsrTencent tencent;
  final AsrAzure azure;

  @override
  bool operator ==(Object other) =>
      other is AsrConnection &&
      other.provider == provider &&
      other.model == model &&
      other.language == language &&
      other.baseUrl == baseUrl &&
      other.key == key &&
      other.aliyun == aliyun &&
      other.volcengine == volcengine &&
      other.tencent == tencent &&
      other.azure == azure;

  @override
  int get hashCode => Object.hash(
    provider,
    model,
    language,
    baseUrl,
    key,
    aliyun,
    volcengine,
    tencent,
    azure,
  );
}

/// The editor's whole `[asr]` card: the common fields plus every
/// vendor's sub-section (saving writes them all; a provider switch
/// never clears another vendor's fields).
class AsrEdit {
  const AsrEdit({
    required this.provider,
    required this.model,
    required this.language,
    required this.baseUrl,
    required this.apiKey,
    required this.aliyun,
    required this.volcengine,
    required this.tencent,
    required this.azure,
  });

  final String provider;
  final String model;
  final String language;
  final String? baseUrl;
  final ApiKeyEdit apiKey;
  final AsrAliyunEdit aliyun;
  final AsrVolcengineEdit volcengine;
  final AsrTencentEdit tencent;
  final AsrAzureEdit azure;
}

class AsrAliyunEdit {
  const AsrAliyunEdit({required this.workspaceId, required this.region});

  final String? workspaceId;
  final String region;
}

class AsrVolcengineEdit {
  const AsrVolcengineEdit({
    required this.appId,
    required this.resourceId,
    required this.accessKey,
  });

  final String? appId;
  final String resourceId;
  final ApiKeyEdit accessKey;
}

class AsrTencentEdit {
  const AsrTencentEdit({
    required this.appId,
    required this.secretId,
    required this.secretKey,
  });

  final String? appId;
  final ApiKeyEdit secretId;
  final ApiKeyEdit secretKey;
}

class AsrAzureEdit {
  const AsrAzureEdit({required this.region, required this.endpointId});

  final String? region;
  final String? endpointId;
}

/// One preset chip's fill, read from the engine-side single source
/// (`crates/llm::presets` behind the bridge's read-only port): the
/// pane never copies the table (ADR-0019 item 5). The blank 自定义
/// chip is the pane's own — it names no preset.
class LlmPreset {
  const LlmPreset({
    required this.name,
    required this.format,
    required this.baseUrl,
    required this.model,
    required this.thinkingFields,
    required this.thinkingOnJson,
    required this.thinkingOffJson,
  });

  /// The chip's wire name — also the vendor slot it names.
  final String name;
  final String format;
  final String baseUrl;
  final String model;

  /// The 「设置思考字段」 switch the chip stamps.
  final bool thinkingFields;
  final String thinkingOnJson;
  final String thinkingOffJson;

  @override
  bool operator ==(Object other) =>
      other is LlmPreset &&
      other.name == name &&
      other.format == format &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.thinkingFields == thinkingFields &&
      other.thinkingOnJson == thinkingOnJson &&
      other.thinkingOffJson == thinkingOffJson;

  @override
  int get hashCode => Object.hash(
    name,
    format,
    baseUrl,
    model,
    thinkingFields,
    thinkingOnJson,
    thinkingOffJson,
  );
}

/// The effective `[llm]` connection as the pane paints it. [key] is the
/// ACTIVE vendor's resolved pair; [keys] carries every vendor's — a key
/// authenticates exactly one vendor, so the pane re-binds its key block
/// per vendor chip and a switch never shows another vendor's key
/// (ADR-0011).
///
/// The open shape (ADR-0019): [format] is the one behavioral axis, the
/// thinking group rides as its four-state reading plus the three
/// overlays' JSON text, and the vendor is only the active slot + last
/// clicked preset pointer.
class LlmConnection {
  const LlmConnection({
    required this.vendor,
    required this.baseUrl,
    required this.model,
    required this.format,
    required this.key,
    required this.keys,
    required this.thinkingState,
    this.thinkingDetail,
    this.bodyJson,
    this.thinkingOnJson,
    this.thinkingOffJson,
  });

  final String vendor;
  final String baseUrl;
  final String model;

  /// `openai_chat` / `anthropic` / `gemini`.
  final String format;
  final KeyInfo key;

  /// Every vendor's resolved key pair, keyed by vendor name.
  final Map<String, KeyInfo> keys;

  /// `on` / `off` / `unconfigured` / `broken` — the thinking group's
  /// reading. Only `on` is the switch's painted state (ADR-0019 item 3).
  final String thinkingState;

  /// The broken branch's file-and-key detail, for the card's warning.
  final String? thinkingDetail;

  /// The three overlays as the JSON text the boxes hold; null unset.
  final String? bodyJson;
  final String? thinkingOnJson;
  final String? thinkingOffJson;

  /// The switch as painted: only `on` turns the fields on.
  bool get thinkingFields => thinkingState == 'on';

  /// The disable condition off, unconfigured, and broken share — what
  /// the rectify cards read (ADR-0019 item 3, design-spec §4.4).
  bool get thinkingDisabled => thinkingState != 'on';

  /// A malformed group: the connection domain refuses every save until
  /// the file is hand-fixed (the ratchet cannot rewrite a group it
  /// cannot read — 01's bad-file boundary).
  bool get thinkingBroken => thinkingState == 'broken';

  @override
  bool operator ==(Object other) =>
      other is LlmConnection &&
      other.vendor == vendor &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.format == format &&
      other.key == key &&
      MapEquality().equals(other.keys, keys) &&
      other.thinkingState == thinkingState &&
      other.thinkingDetail == thinkingDetail &&
      other.bodyJson == bodyJson &&
      other.thinkingOnJson == thinkingOnJson &&
      other.thinkingOffJson == thinkingOffJson;

  @override
  int get hashCode => Object.hash(
    vendor,
    baseUrl,
    model,
    format,
    key,
    keys.length,
    thinkingState,
    thinkingDetail,
    bodyJson,
    thinkingOnJson,
    thinkingOffJson,
  );
}

/// The editor's whole `[llm]` card: the endpoint fields, the format
/// axis, the thinking switch, and the three overlay boxes as the JSON
/// text they hold (blank or `{}` = that share unset). Saving writes
/// exactly this model; the Rust side refuses a bad box or an on switch
/// whose on-share is empty before a single file is touched.
class LlmEdit {
  const LlmEdit({
    required this.vendor,
    required this.baseUrl,
    required this.model,
    required this.format,
    required this.thinkingFields,
    this.bodyJson,
    this.thinkingOnJson,
    this.thinkingOffJson,
    required this.apiKey,
  });

  final String vendor;
  final String baseUrl;
  final String model;
  final String format;
  final bool thinkingFields;
  final String? bodyJson;
  final String? thinkingOnJson;
  final String? thinkingOffJson;
  final ApiKeyEdit apiKey;
}

/// Connection persistence as the connection domain needs it.
abstract class ConnectionStore {
  /// The effective `[asr]` and `[llm]` connections from the layer files.
  Future<({AsrConnection asr, LlmConnection llm})> load();

  /// Write the editor's whole `[asr]` card; returns the re-read view
  /// (the file's truth, not the ask).
  Future<AsrConnection> saveAsr({required AsrEdit edit});

  /// The live endpoint preview for the form's current fields — the
  /// same derivation the loaded view carries, recomputed on every
  /// edit and provider switch (never only on save).
  Future<String?> asrEndpoint({
    required String provider,
    required String model,
    String? baseUrl,
    String? workspaceId,
    required String region,
    String? appId,
  });

  /// The preset chip row, from the engine-side single source (ADR-0019
  /// item 5) — read once, never copied into Dart.
  Future<List<LlmPreset>> presets();

  /// Write the editor's whole `[llm]` card; returns the re-read view
  /// (the file's truth, not the ask).
  Future<LlmConnection> saveLlm({required LlmEdit edit});

  /// Adopt the saved connections into the live engine at once
  /// (ADR-0010): the next session opens with the saved ASR provider,
  /// the next rectify attempt with the saved LLM. Throws when the
  /// engine refuses the adoption (incomplete target config, an
  /// unadapted provider): the files stay saved, and the previous
  /// providers keep running — the pane shows the message.
  Future<void> applyConnections();
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
  Future<AsrConnection> saveAsr({required AsrEdit edit}) =>
      rust.setAsrConnection(edit: _asrEditToWire(edit)).then(_asrFromWire);

  @override
  Future<String?> asrEndpoint({
    required String provider,
    required String model,
    String? baseUrl,
    String? workspaceId,
    required String region,
    String? appId,
  }) => rust.asrEndpointPreview(
    provider: provider,
    model: model,
    baseUrl: baseUrl,
    workspaceId: workspaceId,
    region: region,
    appId: appId,
  );

  @override
  Future<List<LlmPreset>> presets() => rust.llmPresets().then(
    (rows) => rows
        .map(
          (row) => LlmPreset(
            name: row.name,
            format: row.format,
            baseUrl: row.baseUrl,
            model: row.model,
            thinkingFields: row.thinkingFields,
            thinkingOnJson: row.thinkingOnJson,
            thinkingOffJson: row.thinkingOffJson,
          ),
        )
        .toList(),
  );

  @override
  Future<LlmConnection> saveLlm({required LlmEdit edit}) => rust
      .setLlmConnection(
        edit: rust.BridgeLlmEdit(
          vendor: edit.vendor,
          baseUrl: edit.baseUrl,
          model: edit.model,
          format: edit.format,
          thinkingFields: edit.thinkingFields,
          bodyJson: edit.bodyJson,
          thinkingOnJson: edit.thinkingOnJson,
          thinkingOffJson: edit.thinkingOffJson,
          apiKey: _keyToWire(edit.apiKey),
        ),
      )
      .then(_llmFromWire);

  @override
  Future<void> applyConnections() => rust.applyConnectionConfigs();

  static rust.BridgeKeyEdit _keyToWire(ApiKeyEdit edit) => switch (edit) {
    ApiKeyKeep() => const rust.BridgeKeyEdit.keep(),
    ApiKeyClear() => const rust.BridgeKeyEdit.clear(),
    ApiKeySet(:final key) => rust.BridgeKeyEdit.set_(key),
  };

  static KeyInfo _keyFromWire(rust.BridgeKeyStatus status) => switch (status) {
    rust.BridgeKeyStatus_Unset() => const KeyInfo(status: KeyPlacement.unset),
    rust.BridgeKeyStatus_InLocalFile(:final field0) => KeyInfo(
      status: KeyPlacement.inLocalFile,
      storedKey: field0,
    ),
    rust.BridgeKeyStatus_FromEnv(:final field0) => KeyInfo(
      status: KeyPlacement.fromEnv,
      envName: field0,
    ),
  };

  static rust.BridgeAsrEdit _asrEditToWire(AsrEdit edit) => rust.BridgeAsrEdit(
    provider: edit.provider,
    model: edit.model,
    language: edit.language,
    baseUrl: edit.baseUrl,
    apiKey: _keyToWire(edit.apiKey),
    aliyun: rust.BridgeAsrAliyunEdit(
      workspaceId: edit.aliyun.workspaceId,
      region: edit.aliyun.region,
    ),
    volcengine: rust.BridgeAsrVolcengineEdit(
      appId: edit.volcengine.appId,
      resourceId: edit.volcengine.resourceId,
      accessKey: _keyToWire(edit.volcengine.accessKey),
    ),
    tencent: rust.BridgeAsrTencentEdit(
      appId: edit.tencent.appId,
      secretId: _keyToWire(edit.tencent.secretId),
      secretKey: _keyToWire(edit.tencent.secretKey),
    ),
    azure: rust.BridgeAsrAzureEdit(
      region: edit.azure.region,
      endpointId: edit.azure.endpointId,
    ),
  );

  static AsrConnection _asrFromWire(rust.BridgeAsrConnection asr) =>
      AsrConnection(
        provider: asr.provider,
        model: asr.model,
        language: asr.language,
        baseUrl: asr.baseUrl,
        endpoint: asr.endpoint,
        key: _keyFromWire(asr.key),
        aliyun: AsrAliyun(
          workspaceId: asr.aliyun.workspaceId,
          region: asr.aliyun.region,
        ),
        volcengine: AsrVolcengine(
          appId: asr.volcengine.appId,
          resourceId: asr.volcengine.resourceId,
          accessKey: _keyFromWire(asr.volcengine.accessKey),
        ),
        tencent: AsrTencent(
          appId: asr.tencent.appId,
          secretId: _keyFromWire(asr.tencent.secretId),
          secretKey: _keyFromWire(asr.tencent.secretKey),
        ),
        azure: AsrAzure(
          region: asr.azure.region,
          endpointId: asr.azure.endpointId,
        ),
      );

  static LlmConnection _llmFromWire(rust.BridgeLlmConnection llm) =>
      LlmConnection(
        vendor: llm.vendor,
        baseUrl: llm.baseUrl,
        model: llm.model,
        format: llm.format,
        key: _keyFromWire(llm.key),
        keys: {
          for (final entry in llm.keys) entry.vendor: _keyFromWire(entry.key),
        },
        thinkingState: llm.thinkingState,
        thinkingDetail: llm.thinkingDetail,
        bodyJson: llm.bodyJson,
        thinkingOnJson: llm.thinkingOnJson,
        thinkingOffJson: llm.thinkingOffJson,
      );
}
