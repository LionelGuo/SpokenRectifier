/// Widget tests for the settings window: the nine-domain shell, the
/// general domain (the theme tri-state mirror and the orb's visibility
/// switch), the scenario library editor (add/edit/delete/select through
/// one dialog), the fidelity-eval domain (run states through the
/// controller), the history domain (browse/retrieve/retention/
/// keep-nothing/clear), the terms domain (add/rename/remove over the
/// same dictionary file), the rectify domain (the three behavior cards,
/// pick-to-save whole-model writes, the combination warning), the
/// connection domain (the two endpoint forms, preset chips, the
/// diff-echo key block), the advanced domain (the editable timing form
/// + the file escape hatch), the about domain (version/license/
/// open-config), the cross-window channel contract, and the main-window
/// controller's library-change reactions. Everything rides pure-Dart
/// fakes — no Rust dylib, no second engine.

library;

import 'dart:async' show StreamController;
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, SystemChannels;
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/hotkey_binding.dart';
import 'package:spokenrectifier_app/src/design/controls.dart' show SrButton;
import 'package:spokenrectifier_app/src/design/tokens.dart'
    show SrMotion, SrPalette;
import 'package:spokenrectifier_app/src/settings/settings_fidelity_pane.dart'
    show SettingsFidelityPane;
import 'package:spokenrectifier_app/src/rust/api.dart'
    show
        BridgeEvalCaseDetail,
        BridgeEvalCategory,
        BridgeEvalEvent,
        BridgeEvalSummary,
        BridgeHistoryEntry,
        BridgeScenario;
import 'package:spokenrectifier_app/src/settings/connection_store.dart';
import 'package:spokenrectifier_app/src/settings/fidelity_eval.dart';
import 'package:spokenrectifier_app/src/settings/history_store.dart';
import 'package:spokenrectifier_app/src/settings/rectify_store.dart';
import 'package:spokenrectifier_app/src/settings/settings_rectify_pane.dart';
import 'package:spokenrectifier_app/src/shell/history_retrieval.dart'
    show DefaultRegisterPick, NamedScenarioPick, ScenarioPick;
import 'package:spokenrectifier_app/src/settings/settings_channel.dart';
import 'package:spokenrectifier_app/src/settings/settings_domain.dart';
import 'package:spokenrectifier_app/src/settings/settings_store.dart';
import 'package:spokenrectifier_app/src/settings/settings_window.dart';
import 'package:spokenrectifier_app/src/settings/system_store.dart';
import 'package:spokenrectifier_app/src/settings/terms_store.dart';

import 'fake_gateway.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class FakeScenarioStore implements ScenarioStore {
  FakeScenarioStore([List<BridgeScenario> initial = const []])
    : library = List.of(initial);

  List<BridgeScenario> library;

  /// What the editor persisted, one snapshot per save.
  final saves = <List<BridgeScenario>>[];

  /// When set, the next save throws (a full disk, say).
  Object? failNextSave;

  @override
  Future<List<BridgeScenario>> load() async => List.of(library);

  @override
  Future<void> save(List<BridgeScenario> scenarios) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    saves.add(List.of(scenarios));
    library = List.of(scenarios);
  }
}

/// The global directive's fake (ticket 22): the value in memory, one
/// snapshot per save.
class FakeGlobalDirectiveStore implements GlobalDirectiveStore {
  FakeGlobalDirectiveStore([this.directive]);

  String? directive;

  final saves = <String?>[];

  /// When set, the next save throws.
  Object? failNextSave;

  @override
  Future<String?> load() async => directive;

  @override
  Future<void> save(String? value) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    saves.add(value);
    directive = value;
  }
}

/// The history domain's fake: config + entries in memory, mirroring the
/// keep-nothing semantics (saving it empties what a list would show).
class FakeHistorySettingsStore implements HistorySettingsStore {
  FakeHistorySettingsStore({
    HistorySettings config = const HistorySettings(
      enabled: true,
      retentionDays: 30,
    ),
    List<BridgeHistoryEntry> entries = const [],
  }) : this._(config, List.of(entries));

  FakeHistorySettingsStore._(this._config, this._entries);

  HistorySettings _config;
  List<BridgeHistoryEntry> _entries;

  final saves = <HistorySettings>[];
  int clears = 0;

  /// When set, the next saveConfig throws (an unwritable config file).
  Object? failNextSave;

  @override
  Future<HistorySettings> loadConfig() async => _config;

  @override
  Future<HistorySettings> saveConfig(HistorySettings settings) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    saves.add(settings);
    _config = settings;
    if (!settings.enabled) _entries = const [];
    return settings;
  }

  @override
  Future<List<BridgeHistoryEntry>> list() async => List.of(_entries);

  @override
  Future<void> clear() async {
    clears++;
    _entries = const [];
  }
}

/// Drives the eval run by hand: the pane subscribes, the test emits.
class FakeFidelityEvalRunner implements FidelityEvalRunner {
  final _events = StreamController<BridgeEvalEvent>.broadcast();
  int startCount = 0;

  @override
  Stream<BridgeEvalEvent> start() {
    startCount++;
    return _events.stream;
  }

  void emit(BridgeEvalEvent event) => _events.add(event);

  void close() => _events.close();
}

/// The terms domain's fake: the dictionary in memory, mutating like the
/// file does (append idempotent, rename refuses collisions and misses).
class FakeTermsStore implements TermsStore {
  FakeTermsStore([List<String> initial = const []]) : terms = List.of(initial);

  List<String> terms;
  int loads = 0;

  @override
  Future<List<String>> load() async {
    loads++;
    return List.of(terms);
  }

  @override
  Future<void> add(String term) async {
    if (!terms.contains(term)) terms.add(term);
  }

  @override
  Future<void> update(String oldTerm, String newTerm) async {
    if (terms.contains(newTerm)) {
      throw StateError('the dictionary already holds "$newTerm"');
    }
    final index = terms.indexOf(oldTerm);
    if (index < 0) throw StateError('"$oldTerm" is not in the dictionary');
    terms[index] = newTerm;
  }

  @override
  Future<void> remove(String term) async => terms.remove(term);
}

/// The rectify domain's fake: the behavior in memory; a save records
/// the ask and returns it as the re-read truth; the post-save engine
/// adoption ([applyCalls]) is recorded and can be refused
/// ([FakeRectifyBehaviorStore.failNextApply]).
class FakeRectifyBehaviorStore implements RectifyBehaviorStore {
  FakeRectifyBehaviorStore([
    this.behavior = const RectifyBehavior(
      fullThinkingPolicy: 'always',
      fullPrefill: true,
      lightTouchEnabled: true,
      lightTouchMaxChars: 40,
      lightTouchThinkingPolicy: 'always',
      lightTouchPrefill: true,
    ),
  ]);

  /// Today's defaults (ADR-0015: a missing section reads as the
  /// always-on, prefill-on behavior).
  RectifyBehavior behavior;

  final saves = <RectifyBehavior>[];

  /// When set, the next save throws (an unwritable layer file).
  Object? failNextSave;

  /// How many saves handed the files to the live engine afterwards.
  int applyCalls = 0;

  /// When set, the next apply throws (the engine refused the adoption).
  Object? failNextApply;

  @override
  Future<RectifyBehavior> load() async => behavior;

  @override
  Future<RectifyBehavior> save(RectifyBehavior next) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    saves.add(next);
    behavior = next;
    return next;
  }

  @override
  Future<void> applyConnections() async {
    if (failNextApply != null) {
      final failure = failNextApply;
      failNextApply = null;
      throw failure!;
    }
    applyCalls++;
  }
}

/// Every vendor slot unset — the key map's floor for the view helpers.
const _noKeys = <String, KeyInfo>{
  'deepseek': KeyInfo(status: KeyPlacement.unset),
  'volcengine': KeyInfo(status: KeyPlacement.unset),
  'qwen': KeyInfo(status: KeyPlacement.unset),
  'openai': KeyInfo(status: KeyPlacement.unset),
  'anthropic': KeyInfo(status: KeyPlacement.unset),
  'gemini': KeyInfo(status: KeyPlacement.unset),
  'custom': KeyInfo(status: KeyPlacement.unset),
};

/// A connection view for the card tests: the default endpoint over the
/// named slots, the thinking group's reading, and the three boxes'
/// text. [keys] merges over [_noKeys].
LlmConnection fakeLlm({
  String vendor = 'deepseek',
  String baseUrl = 'https://api.deepseek.com',
  String model = 'deepseek-flash',
  String format = 'openai_chat',
  KeyInfo? key,
  Map<String, KeyInfo> keys = const {},
  String thinkingState = 'on',
  String? thinkingDetail,
  String? bodyJson,
  String? thinkingOnJson,
  String? thinkingOffJson,
}) {
  final merged = {..._noKeys, ...keys};
  return LlmConnection(
    vendor: vendor,
    baseUrl: baseUrl,
    model: model,
    format: format,
    key: key ?? merged[vendor] ?? const KeyInfo(status: KeyPlacement.unset),
    keys: merged,
    thinkingState: thinkingState,
    thinkingDetail: thinkingDetail,
    bodyJson: bodyJson,
    thinkingOnJson: thinkingOnJson,
    thinkingOffJson: thinkingOffJson,
  );
}

/// The bridge's preset port mirrored for the fakes (the same six rows
/// `crates/llm::presets` carries; the pane copies nothing, so the tests
/// hand it the list the Rust port would).
const fakeLlmPresets = <LlmPreset>[
  LlmPreset(
    name: 'deepseek',
    format: 'openai_chat',
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
    thinkingFields: true,
    thinkingOnJson: '{"thinking": {"type": "enabled"}}',
    thinkingOffJson: '{"thinking": {"type": "disabled"}}',
  ),
  LlmPreset(
    name: 'volcengine',
    format: 'openai_chat',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    model: 'doubao-seed-2.0-lite',
    thinkingFields: true,
    thinkingOnJson: '{"thinking": {"type": "enabled"}}',
    thinkingOffJson: '{"thinking": {"type": "disabled"}}',
  ),
  LlmPreset(
    name: 'qwen',
    format: 'openai_chat',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen3.8-flash',
    thinkingFields: true,
    thinkingOnJson: '{"enable_thinking": true}',
    thinkingOffJson: '{"enable_thinking": false}',
  ),
  LlmPreset(
    name: 'openai',
    format: 'openai_chat',
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-5.6-terra',
    thinkingFields: true,
    thinkingOnJson: '{"reasoning_effort": "medium"}',
    thinkingOffJson: '{"reasoning_effort": "none"}',
  ),
  LlmPreset(
    name: 'anthropic',
    format: 'anthropic',
    baseUrl: 'https://api.anthropic.com',
    model: 'claude-sonnet-5',
    thinkingFields: true,
    thinkingOnJson: '{"thinking": {"type": "adaptive"}}',
    thinkingOffJson: '{"thinking": {"type": "disabled"}}',
  ),
  LlmPreset(
    name: 'gemini',
    format: 'gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    model: 'gemini-3.8-flash',
    thinkingFields: true,
    thinkingOnJson:
        '{"generationConfig": {"thinkingConfig": {"includeThoughts": true}}}',
    thinkingOffJson: '{"generationConfig": {"thinkingConfig": {}}}',
  ),
];

/// The connection domain's fake: the two views in memory; a save
/// records the ask and returns it as the re-read truth; the post-save
/// engine adoption ([applyCalls]) is recorded and can be refused
/// ([FakeConnectionStore.failNextApply]).
class FakeConnectionStore implements ConnectionStore {
  FakeConnectionStore({
    AsrConnection? asr,
    LlmConnection? llm,
    List<LlmPreset>? presets,
  }) : asr = asr ?? _defaultAsr,
       llm = llm ?? fakeLlm(),
       presetRows = presets ?? fakeLlmPresets;

  /// The port's answer; a test may hand the pane a different table.
  List<LlmPreset> presetRows;

  static const _defaultAsr = AsrConnection(
    provider: 'aliyun',
    model: 'qwen3-asr-flash-realtime',
    language: 'zh',
    baseUrl: null,
    endpoint: 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime',
    key: KeyInfo(status: KeyPlacement.unset),
    aliyun: AsrAliyun(workspaceId: null, region: 'cn-beijing'),
    volcengine: AsrVolcengine(
      appId: null,
      resourceId: 'volc.seedasr.sauc.duration',
      accessKey: KeyInfo(status: KeyPlacement.unset),
    ),
    tencent: AsrTencent(
      appId: null,
      secretId: KeyInfo(status: KeyPlacement.unset),
      secretKey: KeyInfo(status: KeyPlacement.unset),
    ),
    azure: AsrAzure(region: null, endpointId: null),
  );

  AsrConnection asr;
  LlmConnection llm;

  final llmSaves = <LlmEdit>[];
  final asrSaves = <AsrEdit>[];

  /// When set, the next save throws (an unwritable layer file).
  Object? failNextSave;

  /// How many saves handed the files to the live engine afterwards.
  int applyCalls = 0;

  /// When set, the next apply throws (the engine refused the adoption).
  Object? failNextApply;

  @override
  Future<({AsrConnection asr, LlmConnection llm})> load() async =>
      (asr: asr, llm: llm);

  @override
  Future<List<LlmPreset>> presets() async => presetRows;

  @override
  Future<LlmConnection> saveLlm({required LlmEdit edit}) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    llmSaves.add(edit);
    // Only the saved vendor's slot moves; every other vendor's key pair
    // survives the save untouched (ADR-0011).
    final keys = Map.of(llm.keys);
    keys[edit.vendor] = switch (edit.apiKey) {
      ApiKeySet(:final key) => KeyInfo(
        status: KeyPlacement.inLocalFile,
        storedKey: key,
      ),
      ApiKeyClear() => const KeyInfo(status: KeyPlacement.unset),
      ApiKeyKeep() =>
        keys[edit.vendor] ?? const KeyInfo(status: KeyPlacement.unset),
    };
    // Blank and `{}` are the off form, exactly as the Rust save reads
    // them.
    String? box(String? text) {
      final trimmed = (text ?? '').trim();
      return trimmed.isEmpty || trimmed == '{}' ? null : text;
    }

    llm = LlmConnection(
      vendor: edit.vendor,
      baseUrl: edit.baseUrl,
      model: edit.model,
      format: edit.format,
      key: keys[edit.vendor]!,
      keys: keys,
      thinkingState: edit.thinkingFields ? 'on' : 'off',
      bodyJson: box(edit.bodyJson),
      thinkingOnJson: box(edit.thinkingOnJson),
      thinkingOffJson: box(edit.thinkingOffJson),
    );
    return llm;
  }

  @override
  Future<String?> asrEndpoint({
    required String provider,
    required String model,
    String? baseUrl,
    String? workspaceId,
    required String region,
    String? appId,
  }) async => fakeAsrEndpoint(
    provider: provider,
    model: model,
    baseUrl: baseUrl,
    appId: appId,
  );

  @override
  Future<AsrConnection> saveAsr({required AsrEdit edit}) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    asrSaves.add(edit);
    KeyInfo resolved(ApiKeyEdit ask, KeyInfo loaded) => switch (ask) {
      ApiKeySet(:final key) => KeyInfo(
        status: KeyPlacement.inLocalFile,
        storedKey: key,
      ),
      ApiKeyClear() => const KeyInfo(status: KeyPlacement.unset),
      ApiKeyKeep() => loaded,
    };
    asr = AsrConnection(
      provider: edit.provider,
      model: edit.model,
      language: edit.language,
      baseUrl: edit.baseUrl,
      endpoint: fakeAsrEndpoint(
        provider: edit.provider,
        model: edit.model,
        baseUrl: edit.baseUrl,
      ),
      key: resolved(edit.apiKey, asr.key),
      aliyun: AsrAliyun(
        workspaceId: edit.aliyun.workspaceId,
        region: edit.aliyun.region,
      ),
      volcengine: AsrVolcengine(
        appId: edit.volcengine.appId,
        resourceId: edit.volcengine.resourceId,
        accessKey: resolved(
          edit.volcengine.accessKey,
          asr.volcengine.accessKey,
        ),
      ),
      tencent: AsrTencent(
        appId: edit.tencent.appId,
        secretId: resolved(edit.tencent.secretId, asr.tencent.secretId),
        secretKey: resolved(edit.tencent.secretKey, asr.tencent.secretKey),
      ),
      azure: AsrAzure(
        region: edit.azure.region,
        endpointId: edit.azure.endpointId,
      ),
    );
    return asr;
  }

  @override
  Future<void> applyConnections() async {
    if (failNextApply != null) {
      final failure = failNextApply;
      failNextApply = null;
      throw failure!;
    }
    applyCalls++;
  }
}

/// The fake's mirror of the Rust endpoint derivation (the adapted
/// providers' default hosts with a base_url override; the single real
/// source is `AsrConfig::endpoint` behind the bridge).
String? fakeAsrEndpoint({
  required String provider,
  required String model,
  String? baseUrl,
  String? appId,
}) {
  String host(String fallback) {
    final text = baseUrl?.trim() ?? '';
    return text.isEmpty ? fallback : text.replaceAll(RegExp(r'/+$'), '');
  }

  switch (provider) {
    case 'aliyun':
      return '${host('wss://dashscope.aliyuncs.com')}/api-ws/v1/realtime?model=$model';
    case 'volcengine':
      return '${host('wss://openspeech.bytedance.com')}/api/v3/sauc/bigmodel';
    case 'tencent':
      return '${host('wss://asr.cloud.tencent.com')}/asr/v2/${appId?.trim() ?? ''}';
    default:
      return null;
  }
}

/// The advanced/about fake: timings in memory (a save mutates them,
/// mirroring the file write + live apply); an open-config call is
/// recorded (the same entry the tray makes).
class FakeSystemStore implements SystemStore {
  FakeSystemStore({
    this.engine = const EngineTiming(
      passageMode: true,
      paragraphSilenceMs: 1200,
      sessionEndSilenceMs: 3000,
      rectifyTimeoutMs: 25000,
    ),
    this.insertion = const InsertionTiming(
      mode: 'paste',
      focusSettleMs: 50,
      pasteSettleMs: 250,
      typingDelayMs: 8,
    ),
    this.about = const AboutInfo(version: '1.0.0', license: 'Apache-2.0'),
  });

  EngineTiming engine;
  InsertionTiming insertion;
  AboutInfo about;
  int openConfigCalls = 0;
  final engineSaves =
      <({bool passage, int paragraph, int sessionEnd, int timeout})>[];
  final insertionSaves = <({String mode, int focus, int paste, int typing})>[];

  /// When set, the next save throws (an unwritable layer file).
  Object? failNextSave;

  @override
  Future<({EngineTiming engine, InsertionTiming insertion})>
  loadAdvanced() async => (engine: engine, insertion: insertion);

  @override
  Future<EngineTiming> saveEngineSettings({
    required bool passageMode,
    required int paragraphSilenceMs,
    required int sessionEndSilenceMs,
    required int rectifyTimeoutMs,
  }) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    engineSaves.add((
      passage: passageMode,
      paragraph: paragraphSilenceMs,
      sessionEnd: sessionEndSilenceMs,
      timeout: rectifyTimeoutMs,
    ));
    engine = EngineTiming(
      passageMode: passageMode,
      paragraphSilenceMs: paragraphSilenceMs,
      sessionEndSilenceMs: sessionEndSilenceMs,
      rectifyTimeoutMs: rectifyTimeoutMs,
    );
    return engine;
  }

  @override
  Future<InsertionTiming> saveInsertionTiming({
    required String mode,
    required int focusSettleMs,
    required int pasteSettleMs,
    required int typingDelayMs,
  }) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    insertionSaves.add((
      mode: mode,
      focus: focusSettleMs,
      paste: pasteSettleMs,
      typing: typingDelayMs,
    ));
    insertion = InsertionTiming(
      mode: mode,
      focusSettleMs: focusSettleMs,
      pasteSettleMs: pasteSettleMs,
      typingDelayMs: typingDelayMs,
    );
    return insertion;
  }

  @override
  Future<AboutInfo> loadAbout() async => about;

  @override
  Future<String> openConfigFile() async {
    openConfigCalls++;
    return '/fake/spokenrectifier.toml';
  }
}

/// Records every outbound event; inbound pushes are invoked by the test
/// through the exposed handlers.
class FakeSettingsChannel implements SettingsChannel {
  final libraryChanged = <({String? from, String? to})>[];
  final selections = <String?>[];
  final themePicks = <ThemeMode>[];
  final orbFlips = <bool>[];
  int hotkeysChanged = 0;
  final hotkeysPaused = <bool>[];
  int historyChanged = 0;
  final rerectifies = <({String raw, ScenarioPick style})>[];
  int termsChanged = 0;
  int globalChanged = 0;

  void Function(ThemeMode mode)? themeHandler;
  void Function(String? name)? selectionHandler;
  void Function(SettingsDomain domain)? navigateHandler;
  void Function(bool visible)? orbVisibleHandler;
  bool attached = false;

  @override
  set onTheme(void Function(ThemeMode mode) handler) => themeHandler = handler;

  @override
  set onSelection(void Function(String? name) handler) =>
      selectionHandler = handler;

  @override
  set onOrbVisible(void Function(bool visible) handler) =>
      orbVisibleHandler = handler;

  @override
  set onNavigate(void Function(SettingsDomain domain) handler) =>
      navigateHandler = handler;

  @override
  Future<void> attach() async => attached = true;

  @override
  Future<void> sendScenariosChanged({
    String? renamedFrom,
    String? renamedTo,
  }) async => libraryChanged.add((from: renamedFrom, to: renamedTo));

  @override
  Future<void> sendGlobalChanged() async => globalChanged++;

  @override
  Future<void> sendScenarioSelected(String? name) async => selections.add(name);

  @override
  Future<void> sendThemePicked(ThemeMode mode) async => themePicks.add(mode);

  @override
  Future<void> sendOrbVisible(bool visible) async => orbFlips.add(visible);

  @override
  Future<void> sendHotkeysChanged() async => hotkeysChanged++;

  @override
  Future<void> sendHotkeysPaused(bool paused) async =>
      hotkeysPaused.add(paused);

  @override
  Future<void> sendHistoryChanged() async => historyChanged++;

  @override
  Future<void> sendHistoryRerectify(
    String rawTranscript, {
    required ScenarioPick style,
  }) async => rerectifies.add((raw: rawTranscript, style: style));

  @override
  Future<void> sendTermsChanged() async => termsChanged++;
}

const _seeded = [
  BridgeScenario(name: '论文', directive: '学术书面语:客观严谨'),
  BridgeScenario(name: '聊天', directive: '轻松自然:保留语气'),
];

/// Two history rows the panes and tests share.
final _historyEntries = [
  BridgeHistoryEntry(
    id: 2,
    createdAtMs: BigInt.from(1_758_900_000_000),
    rawTranscript: '第二句的原话',
    rectifiedText: '第二句的成文',
  ),
  BridgeHistoryEntry(
    id: 1,
    createdAtMs: BigInt.from(1_758_800_000_000),
    rawTranscript: '第一句的原话',
    rectifiedText: '第一句的成文',
  ),
];

const _evalSummary = BridgeEvalSummary(
  total: 23,
  passed: 20,
  failed: 3,
  execFailed: 1,
  ratePercent: 87.0,
  baselinePercent: 87.0,
  model: 'deepseek-v4-flash',
  categories: [
    BridgeEvalCategory(label: '捏造', count: 0),
    BridgeEvalCategory(label: '丢失', count: 1),
    BridgeEvalCategory(label: '残留', count: 1),
  ],
  failedCases: [],
);

/// A finished summary whose failed cases mix shapes — a short verdict, a
/// long one, and an execution failure — in wire order that is
/// deliberately not alphabetical: the pane must paint suite order (the
/// wire order), never re-sort by id or category (ticket 21).
const _evalSummaryWithFailures = BridgeEvalSummary(
  total: 23,
  passed: 20,
  failed: 3,
  execFailed: 1,
  ratePercent: 87.0,
  baselinePercent: 87.0,
  model: 'deepseek-v4-flash',
  categories: [
    BridgeEvalCategory(label: '捏造', count: 0),
    BridgeEvalCategory(label: '丢失', count: 1),
    BridgeEvalCategory(label: '残留', count: 1),
  ],
  failedCases: [
    BridgeEvalCaseDetail(id: 'manner-07', failures: ['[残留] 输出仍含口头填充词']),
    BridgeEvalCaseDetail(
      id: 'correction-02',
      failures: ['[丢失] 术语「等宽有序的失败明细卡片列」未逐字保留,机器判定文本写得足够长,恰好用来证明卡片的宽不由内容决定'],
    ),
    BridgeEvalCaseDetail(
      id: 'term-keep-15',
      error: '引擎返回 429:rate limited',
      failures: [],
    ),
  ],
);

Future<void> pumpSettings(
  WidgetTester tester, {
  FakeScenarioStore? store,
  FakeSettingsChannel? channel,
  FakeGlobalDirectiveStore? globalStore,
  FakeHistorySettingsStore? historyStore,
  FakeFidelityEvalRunner? evalRunner,
  FakeTermsStore? termsStore,
  FakeConnectionStore? connectionStore,
  FakeRectifyBehaviorStore? rectifyStore,
  FakeSystemStore? systemStore,
  SettingsDomain domain = SettingsDomain.scenarios,
  ThemeMode initialTheme = ThemeMode.system,
  bool initialOrbVisible = true,
  HotkeyBinding initialPrimary = HotkeyBinding.primaryDefault,
  HotkeyBinding initialPin = HotkeyBinding.pinDefault,
  List<String>? uiPrefsDirs,
  String? selected,
  void Function(Brightness brightness)? captionTheme,
}) async {
  // A taller surface than the default 800×600: the connection card's
  // open shape (format row, three JSON boxes, the thinking switch) is
  // taller than that, and the panes' lazy lists never build what sits
  // below the fold — the ASR card would stop existing for the finders.
  // The real window is 920×640 and scrolls; scrolling is not what these
  // tests are about.
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    SettingsWindowApp(
      store: store ?? FakeScenarioStore(_seeded),
      channel: channel ?? FakeSettingsChannel(),
      globalStore: globalStore ?? FakeGlobalDirectiveStore(),
      initialDomain: domain,
      initialTheme: initialTheme,
      initialOrbVisible: initialOrbVisible,
      initialPrimary: initialPrimary,
      initialPin: initialPin,
      uiPrefsDirs: uiPrefsDirs,
      initialSelection: selected,
      historyStore: historyStore ?? FakeHistorySettingsStore(),
      evalRunner: evalRunner ?? FakeFidelityEvalRunner(),
      termsStore: termsStore ?? FakeTermsStore(),
      connectionStore: connectionStore ?? FakeConnectionStore(),
      rectifyStore: rectifyStore ?? FakeRectifyBehaviorStore(),
      systemStore: systemStore ?? FakeSystemStore(),
      captionTheme: captionTheme ?? (_) {},
    ),
  );
  await tester.pump(); // the library load lands
}

/// Hover the card so its hover-only actions exist, then tap the icon.
Future<void> hoverCardAction(
  WidgetTester tester,
  String scenarioName,
  IconData icon,
) async {
  final card = find.byKey(Key('settings-scenario-card:$scenarioName'));
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(card));
  await tester.pump(SrMotion.fade);
  await tester.tap(find.descendant(of: card, matching: find.byIcon(icon)));
}

/// Hover an entry row by key, then tap its action icon. The gesture is
/// removed at the end so a second hover in the same test starts clean
/// (the mouse tracker refuses a second add while one pointer lives).
Future<void> hoverRowAction(WidgetTester tester, Key row, IconData icon) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: tester.getCenter(find.byKey(row)));
  await tester.pump(SrMotion.fade);
  await tester.tap(
    find.descendant(of: find.byKey(row), matching: find.byIcon(icon)),
  );
  await gesture.removePointer();
  await tester.pump();
}

/// A text field's current text, by its key (SrField carries the key;
/// the TextField hides one level inside).
String fieldText(WidgetTester tester, Key key) => tester
    .widget<TextField>(
      find.descendant(of: find.byKey(key), matching: find.byType(TextField)),
    )
    .controller!
    .text;

/// The global directive card's field text (the key sits on the TextField
/// itself there, not on an ancestor wrapper).
String globalFieldText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('settings-global-field')))
    .controller!
    .text;

/// A Text widget's painted data, by its key.
String textOf(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data!;

/// The rectify pane's lazy-ListView scroller: rows outside the viewport
/// don't exist in a lazy ListView, so a `find.byKey` on an off-screen
/// row needs the scroll, not `ensureVisible` (which requires an element
/// already; the light card's tail sits below the fold).
Future<void> scrollRectifyTo(WidgetTester tester, Key key) =>
    tester.dragUntilVisible(
      find.byKey(key),
      find
          .descendant(
            of: find.byType(SettingsRectifyPane),
            matching: find.byType(ListView),
          )
          .first,
      const Offset(0, 200),
    );

// ---------------------------------------------------------------------------
// The shell
// ---------------------------------------------------------------------------

void main() {
  test('the domain list is the nine-entry sidebar IA order', () {
    expect(SettingsDomain.values, [
      SettingsDomain.general,
      SettingsDomain.scenarios,
      SettingsDomain.rectify,
      SettingsDomain.history,
      SettingsDomain.terms,
      SettingsDomain.connection,
      SettingsDomain.fidelity,
      SettingsDomain.advanced,
      SettingsDomain.about,
    ]);
    expect(SettingsDomain.rectify.label, '修正');
    // Unknown names fall back to 通用, the sidebar's first domain (the
    // same target the quick panel's 打开设置 lands on); 修正 now carries
    // its own pane (it was the fallback target before its ticket landed).
    expect(settingsDomainFromName('rectify'), SettingsDomain.rectify);
    expect(settingsDomainFromName('nope'), SettingsDomain.general);
    expect(settingsDomainFromName(null), SettingsDomain.general);
    expect(settingsDomainFromName('fidelity'), SettingsDomain.fidelity);
  });

  testWidgets('sidebar lists every domain; all nine are real panes', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, channel: channel);

    for (final domain in SettingsDomain.values) {
      // 场景 paints twice by design: sidebar entry + pane title (页标题
      // 仍写「场景库」; 侧栏是「场景」). 评测 likewise: 侧栏「评测」、页标题
      // 「保真评测」. Every other domain's label is the same in both.
      expect(find.text(domain.label), findsWidgets);
    }

    // Every domain paints its real content — no placeholder pane
    // survives. 通用 (the launch default's fallback target) first.
    await tester.tap(find.text('通用'));
    await tester.pump();
    expect(find.byKey(const Key('settings-theme-light')), findsOneWidget);
    expect(find.byKey(const Key('settings-orb-visible')), findsOneWidget);
    expect(find.byKey(const Key('settings-hotkey-primary')), findsOneWidget);
    expect(find.byKey(const Key('settings-hotkey-pin')), findsOneWidget);
    await tester.tap(find.text('修正'));
    await tester.pump();
    await tester.pump(); // the behavior load lands
    expect(find.text('全量模式'), findsOneWidget);
    expect(find.text('轻修模式'), findsOneWidget);
    await tester.tap(find.text('评测'));
    await tester.pump();
    expect(find.text('开始评测'), findsOneWidget);

    await tester.tap(find.text('历史'));
    await tester.pump();
    await tester.pump(); // the config load lands (two chained awaits)
    expect(find.text('不留存输入历史'), findsOneWidget);

    await tester.tap(find.text('术语'));
    await tester.pump();
    await tester.pump(); // the dictionary load lands
    expect(find.byKey(const Key('settings-terms-field')), findsOneWidget);

    await tester.tap(find.text('模型与连接'));
    await tester.pump();
    await tester.pump(); // the connection load lands
    expect(find.text('修正模型'), findsOneWidget);
    expect(find.text('语音识别'), findsOneWidget);

    await tester.tap(find.text('高级'));
    await tester.pump();
    await tester.pump(); // the timings load lands
    expect(
      find.byKey(const Key('settings-advanced-open-config')),
      findsOneWidget,
    );

    await tester.tap(find.text('关于'));
    await tester.pump();
    await tester.pump(); // the about load lands
    expect(find.byKey(const Key('settings-about-open-config')), findsOneWidget);

    // The inbound navigate push switches domains too (the entry rows).
    channel.navigateHandler?.call(SettingsDomain.scenarios);
    await tester.pump();
    expect(find.text('场景库域'), findsNothing); // real pane, not placeholder
    expect(find.byKey(const Key('settings-scenario-card:论文')), findsOneWidget);
  });

  testWidgets('an empty library paints the empty state and the create button', (
    tester,
  ) async {
    await pumpSettings(tester, store: FakeScenarioStore());
    expect(find.byKey(const Key('settings-scenario-empty')), findsOneWidget);
    expect(find.byKey(const Key('settings-scenario-new')), findsOneWidget);
  });

  // -----------------------------------------------------------------------
  // The general domain (通用)
  // -----------------------------------------------------------------------

  Switch orbSwitch(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('settings-orb-visible')));

  testWidgets(
    'a theme pick paints at once and rides the channel to the single entry',
    (tester) async {
      final channel = FakeSettingsChannel();
      await pumpSettings(
        tester,
        channel: channel,
        domain: SettingsDomain.general,
      );

      await tester.tap(find.byKey(const Key('settings-theme-dark')));
      await tester.pump();

      // The pick adopts locally at once (the whole app repaints), and
      // the event goes out to the main controller's setThemeMode — the
      // same entry the quick panel's switcher takes.
      expect(channel.themePicks, [ThemeMode.dark]);
      expect(
        (tester.widget(find.byType(MaterialApp)) as MaterialApp).themeMode,
        ThemeMode.dark,
      );
    },
  );

  testWidgets('an orb flip paints at once and rides the channel', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    await pumpSettings(
      tester,
      channel: channel,
      domain: SettingsDomain.general,
    );

    expect(orbSwitch(tester).value, isTrue);

    await tester.tap(find.byKey(const Key('settings-orb-visible')));
    await tester.pump();

    // Painted at once; the flip goes out to the main controller's
    // setOrbVisible (the tray checkbox's entry) — the write and any
    // failure banner live there.
    expect(orbSwitch(tester).value, isFalse);
    expect(channel.orbFlips, [false]);
  });

  testWidgets('the orb switch follows tray toggles live', (tester) async {
    final channel = FakeSettingsChannel();
    await pumpSettings(
      tester,
      channel: channel,
      domain: SettingsDomain.general,
    );

    // A tray toggle while the window is open: the orb-follow push
    // repaints the switch without a local edit.
    channel.orbVisibleHandler?.call(false);
    await tester.pump();
    expect(orbSwitch(tester).value, isFalse);
    expect(channel.orbFlips, isEmpty);
  });

  testWidgets('the orb switch seeds from the launch arguments', (tester) async {
    await pumpSettings(
      tester,
      domain: SettingsDomain.general,
      initialOrbVisible: false,
    );
    expect(orbSwitch(tester).value, isFalse);
  });

  testWidgets('the hotkey rows seed from the launch arguments', (tester) async {
    await pumpSettings(
      tester,
      domain: SettingsDomain.general,
      initialPrimary: const HotkeyBinding.none(),
      initialPin: HotkeyBinding.tryParse('Ctrl+Q')!,
    );
    expect(find.text('未绑定'), findsOneWidget);
    expect(find.text('Ctrl+Q'), findsOneWidget);
    expect(find.byKey(const Key('settings-hotkey-primary')), findsOneWidget);
  });

  testWidgets('capturing a legal chord writes the file and notifies main', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('sr-hotkey-settings-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final channel = FakeSettingsChannel();
    await pumpSettings(
      tester,
      channel: channel,
      domain: SettingsDomain.general,
      uiPrefsDirs: [dir.path],
    );

    await tester.tap(find.byKey(const Key('settings-hotkey-primary')));
    await tester.pump();
    expect(channel.hotkeysPaused, [true]);
    expect(find.text('按下组合键录制'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
    await tester.pump();

    expect(find.text('Alt+Q'), findsOneWidget);
    expect(channel.hotkeysChanged, 1);
    expect(channel.hotkeysPaused.last, isFalse);
    expect(
      File('${dir.path}/spokenrectifier-ui.toml').readAsStringSync(),
      contains('primary_hotkey = "Alt+Q"'),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  });

  testWidgets('an illegal or colliding press does not finish the capture', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('sr-hotkey-collide-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final channel = FakeSettingsChannel();
    await pumpSettings(
      tester,
      channel: channel,
      domain: SettingsDomain.general,
      uiPrefsDirs: [dir.path],
    );

    await tester.tap(find.byKey(const Key('settings-hotkey-primary')));
    await tester.pump();
    // A bare key is not a completing press.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
    await tester.pump();
    expect(find.text('按下组合键录制'), findsOneWidget);
    expect(channel.hotkeysChanged, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);

    // The pin's current chord (Alt+B) is a collision; keep waiting.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await tester.pump();
    expect(find.text('按下组合键录制'), findsOneWidget);
    expect(channel.hotkeysChanged, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

    // Clicking the same row again abandons the capture.
    await tester.tap(find.byKey(const Key('settings-hotkey-primary')));
    await tester.pump();
    expect(find.text('Ctrl+Alt+V'), findsOneWidget);
    expect(channel.hotkeysPaused.last, isFalse);
  });

  testWidgets('clear writes none; restore writes the slot default', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('sr-hotkey-clear-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final channel = FakeSettingsChannel();
    await pumpSettings(
      tester,
      channel: channel,
      domain: SettingsDomain.general,
      uiPrefsDirs: [dir.path],
    );

    await tester.tap(find.byKey(const Key('settings-hotkey-pin-clear')));
    await tester.pump();
    expect(find.text('未绑定'), findsOneWidget);
    expect(channel.hotkeysChanged, 1);
    expect(
      File('${dir.path}/spokenrectifier-ui.toml').readAsStringSync(),
      contains('pin_hotkey = "none"'),
    );

    await tester.tap(find.byKey(const Key('settings-hotkey-pin-restore')));
    await tester.pump();
    expect(find.text('Alt+B'), findsOneWidget);
    expect(channel.hotkeysChanged, 2);
  });

  testWidgets('restore refuses a default that collides with the other slot', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('sr-hotkey-restore-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final channel = FakeSettingsChannel();
    await pumpSettings(
      tester,
      channel: channel,
      domain: SettingsDomain.general,
      initialPrimary: HotkeyBinding.pinDefault,
      uiPrefsDirs: [dir.path],
    );

    await tester.tap(find.byKey(const Key('settings-hotkey-pin-restore')));
    await tester.pump();
    // Pin stays Alt+B (already the default) — but wait, primary is also
    // Alt+B, so restoring pin to Alt+B collides with primary. The pin
    // row still paints Alt+B (it started there); no write went out.
    expect(channel.hotkeysChanged, 0);
    expect(File('${dir.path}/spokenrectifier-ui.toml').existsSync(), isFalse);
  });

  // -----------------------------------------------------------------------
  // The fidelity-eval domain (保真评测)
  // -----------------------------------------------------------------------

  testWidgets('the eval entry notes no scenario or global directive applies', (
    tester,
  ) async {
    await pumpSettings(tester, domain: SettingsDomain.fidelity);
    // The isolation is by construction (the runner's own engine instance
    // never receives a directive); the copy states the contract.
    expect(find.textContaining('也不使用场景或全局指令'), findsOneWidget);
    expect(find.textContaining('用内置样例检查修正是否忠实于原意'), findsNothing);
    expect(
      find.byKey(const Key('settings-eval-connection-inherited')),
      findsNothing,
    );
  });

  testWidgets('a run walks idle → running → finished with the summary', (
    tester,
  ) async {
    final runner = FakeFidelityEvalRunner();
    await pumpSettings(
      tester,
      evalRunner: runner,
      domain: SettingsDomain.fidelity,
    );

    // Idle: the manual entry explains itself (real LLM, no side effects).
    expect(find.text('开始评测'), findsOneWidget);
    await tester.tap(find.text('开始评测'));
    await tester.pump();
    expect(runner.startCount, 1);
    expect(find.byKey(const Key('settings-eval-spinner')), findsOneWidget);

    runner.emit(const BridgeEvalEvent.started(total: 23));
    await tester.pump();
    expect(find.text('0 / 23'), findsOneWidget);

    runner.emit(
      const BridgeEvalEvent.caseStarted(
        index: 1,
        total: 23,
        id: 'correction-01',
      ),
    );
    runner.emit(
      const BridgeEvalEvent.caseFinished(
        index: 1,
        id: 'correction-01',
        passed: true,
      ),
    );
    await tester.pump();
    expect(find.text('1 / 23'), findsOneWidget);
    expect(find.text('correction-01'), findsOneWidget);

    runner.emit(const BridgeEvalEvent.finished(summary: _evalSummary));
    await tester.pump();
    expect(find.byKey(const Key('settings-eval-rate')), findsOneWidget);
    expect(find.text('87.0%'), findsOneWidget);
    expect(find.text('与基线持平'), findsOneWidget);
    expect(find.byKey(const Key('settings-eval-category:捏造')), findsOneWidget);
    expect(
      find.text('通过 20 / 23 · 执行失败 1 · 基线 87.0% · deepseek-v4-flash'),
      findsOneWidget,
    );
  });

  testWidgets('failed-case cards are uniform, full-width, in suite order', (
    tester,
  ) async {
    // One tall surface so the lazy ListView builds every card at once —
    // off-screen rows have no elements to measure.
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final runner = FakeFidelityEvalRunner();
    await pumpSettings(
      tester,
      evalRunner: runner,
      domain: SettingsDomain.fidelity,
    );
    await tester.tap(find.text('开始评测'));
    await tester.pump();
    runner.emit(
      const BridgeEvalEvent.finished(summary: _evalSummaryWithFailures),
    );
    await tester.pump();

    // Every card fills the pane width minus the ListView's own padding
    // (2 × EdgeInsets.all(24)), whatever its text length — so left and
    // right edges align across the column, the history domain's
    // entry-row look.
    const panePadding = 24 * 2;
    final paneWidth =
        tester.getSize(find.byType(SettingsFidelityPane)).width - panePadding;
    const ids = ['manner-07', 'correction-02', 'term-keep-15'];
    final firstLeft = tester
        .getTopLeft(find.byKey(Key('settings-eval-failed:${ids.first}')))
        .dx;
    final tops = <double>[];
    for (final id in ids) {
      final card = find.byKey(Key('settings-eval-failed:$id'));
      expect(
        tester.getSize(card).width,
        moreOrLessEquals(paneWidth, epsilon: 0.5),
        reason: 'card $id must fill the pane width',
      );
      final topLeft = tester.getTopLeft(card);
      expect(
        topLeft.dx,
        moreOrLessEquals(firstLeft, epsilon: 0.5),
        reason: 'card $id must share the column left edge',
      );
      tops.add(topLeft.dy);
    }
    // Suite order — the wire order of the fixture, which is deliberately
    // non-alphabetical; painting must not re-sort.
    for (var i = 1; i < ids.length; i++) {
      expect(
        tops[i],
        greaterThan(tops[i - 1]),
        reason: '${ids[i]} must paint below ${ids[i - 1]}',
      );
    }

    // The execution failure keeps carrying the engine's own message.
    expect(find.text('执行失败，详情请见日志'), findsOneWidget);
  });

  testWidgets('an all-pass summary keeps the empty state, no detail cards', (
    tester,
  ) async {
    const allPassed = BridgeEvalSummary(
      total: 23,
      passed: 23,
      failed: 0,
      execFailed: 0,
      ratePercent: 100.0,
      baselinePercent: 87.0,
      model: 'deepseek-v4-flash',
      categories: [
        BridgeEvalCategory(label: '捏造', count: 0),
        BridgeEvalCategory(label: '丢失', count: 0),
        BridgeEvalCategory(label: '残留', count: 0),
      ],
      failedCases: [],
    );
    final runner = FakeFidelityEvalRunner();
    await pumpSettings(
      tester,
      evalRunner: runner,
      domain: SettingsDomain.fidelity,
    );
    await tester.tap(find.text('开始评测'));
    await tester.pump();
    runner.emit(const BridgeEvalEvent.finished(summary: allPassed));
    await tester.pump();

    expect(find.text('100.0%'), findsOneWidget);
    expect(find.byKey(const Key('settings-eval-category:捏造')), findsOneWidget);
    expect(find.text('全部样例通过。'), findsOneWidget);
    expect(find.text('失败明细'), findsNothing);
  });

  testWidgets('a failed run paints its message and offers a retry', (
    tester,
  ) async {
    final runner = FakeFidelityEvalRunner();
    await pumpSettings(
      tester,
      evalRunner: runner,
      domain: SettingsDomain.fidelity,
    );

    await tester.tap(find.text('开始评测'));
    await tester.pump();
    runner.emit(const BridgeEvalEvent.failed(message: '评测需要真实 LLM 连接'));
    await tester.pump();
    expect(find.text('评测未能完成'), findsOneWidget);
    expect(find.text('服务出错，请重试'), findsOneWidget);

    // The retry starts a fresh run.
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(runner.startCount, 2);
  });

  testWidgets('cancel stops the run; switching domains does not', (
    tester,
  ) async {
    final runner = FakeFidelityEvalRunner();
    await pumpSettings(
      tester,
      evalRunner: runner,
      domain: SettingsDomain.fidelity,
    );

    await tester.tap(find.text('开始评测'));
    await tester.pump();
    runner.emit(const BridgeEvalEvent.started(total: 23));
    await tester.pump();

    // The run outlives the pane: switch away and back, still running.
    await tester.tap(find.text('场景'));
    await tester.pump();
    await tester.tap(find.text('评测'));
    await tester.pump();
    expect(find.byKey(const Key('settings-eval-spinner')), findsOneWidget);

    // Cancel returns to idle, and a fresh start works right away.
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.text('开始评测'), findsOneWidget);
    await tester.tap(find.text('开始评测'));
    await tester.pump();
    expect(runner.startCount, 2);
    expect(find.text('取消'), findsOneWidget); // the fresh run is live

    // Cancelling drops the listener: later events land nowhere.
    await tester.tap(find.text('取消'));
    await tester.pump();
    runner.emit(const BridgeEvalEvent.started(total: 23));
    await tester.pump();
    expect(find.byKey(const Key('settings-eval-spinner')), findsNothing);
  });

  // -----------------------------------------------------------------------
  // The history domain (历史)
  // -----------------------------------------------------------------------

  testWidgets('entries paint with both texts; retrieval is same-source', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    final store = FakeHistorySettingsStore(entries: _historyEntries);
    await pumpSettings(
      tester,
      channel: channel,
      historyStore: store,
      domain: SettingsDomain.history,
    );

    // Both texts per row (the quick panel shows the rectified one only).
    expect(find.text('第二句的原话'), findsOneWidget);
    expect(
      find.byKey(const Key('settings-history-rectified:2')),
      findsOneWidget,
    );

    // Both copies land on the clipboard (same mock recipe: record the
    // Clipboard.setData call).
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await hoverRowAction(
      tester,
      const Key('settings-history-copy-raw:2'),
      Icons.format_quote_rounded,
    );
    await tester.pump();
    expect(copied, '第二句的原话');
    await hoverRowAction(
      tester,
      const Key('settings-history-copy-rectified:2'),
      Icons.copy_rounded,
    );
    await tester.pump();
    expect(copied, '第二句的成文');

    // 指定场景重新修正: the menu lists 默认 plus the same library the
    // 场景库 domain paints; the pick routes to the main window with the
    // scenario named — the session runs under it for that one session.
    // A tall viewport builds every lazy row at once and keeps the menu
    // it opens fully on-screen (the ticket-21 recipe).
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pump();
    await hoverRowAction(
      tester,
      const Key('settings-history-rerectify-scenario:1'),
      Icons.style_rounded,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('settings-history-scenario-item-builtin-default')),
      findsOneWidget,
    );
    await tester.tap(find.text('论文'));
    await tester.pumpAndSettle();
    expect(channel.rerectifies, [
      (raw: '第一句的原话', style: const NamedScenarioPick('论文')),
    ]);
  });

  testWidgets('an empty library keeps the scenario rerectify key on 默认', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    final store = FakeHistorySettingsStore(entries: _historyEntries);
    await pumpSettings(
      tester,
      store: FakeScenarioStore(const []),
      channel: channel,
      historyStore: store,
      domain: SettingsDomain.history,
    );

    // The key stays live over an empty library (ticket 28's ruling:
    // retrieval must not die with the library); the menu lists 默认
    // alone, and the pick routes to the main window as the explicit
    // default register. A tall viewport keeps the menu fully on-screen
    // (the ticket-21 recipe).
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pump();
    await hoverRowAction(
      tester,
      const Key('settings-history-rerectify-scenario:1'),
      Icons.style_rounded,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('settings-history-scenario-item:论文')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const Key('settings-history-scenario-item-builtin-default')),
    );
    await tester.pumpAndSettle();
    expect(channel.rerectifies, [
      (raw: '第一句的原话', style: const DefaultRegisterPick()),
    ]);
  });

  testWidgets('a scenario literally named 默认 stays distinct from the builtin', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    final store = FakeHistorySettingsStore(entries: _historyEntries);
    await pumpSettings(
      tester,
      store: FakeScenarioStore(const [
        BridgeScenario(name: '默认', directive: '默认场景的指令'),
      ]),
      channel: channel,
      historyStore: store,
      domain: SettingsDomain.history,
    );

    // Both items coexist — the reserved key and the sealed pick keep
    // the builtin 默认 and a same-named scenario distinct. The builtin
    // routes the default register; the named one routes the scenario.
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pump();
    await hoverRowAction(
      tester,
      const Key('settings-history-rerectify-scenario:1'),
      Icons.style_rounded,
    );
    await tester.pumpAndSettle();
    expect(find.text('默认'), findsNWidgets(2));
    await tester.tap(
      find.byKey(const Key('settings-history-scenario-item-builtin-default')),
    );
    await tester.pumpAndSettle();
    expect(channel.rerectifies.last, (
      raw: '第一句的原话',
      style: const DefaultRegisterPick(),
    ));

    await hoverRowAction(
      tester,
      const Key('settings-history-rerectify-scenario:1'),
      Icons.style_rounded,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('settings-history-scenario-item:默认')),
    );
    await tester.pumpAndSettle();
    expect(channel.rerectifies.last, (
      raw: '第一句的原话',
      style: const NamedScenarioPick('默认'),
    ));
  });

  testWidgets('a retention pick saves and reports the change', (tester) async {
    final channel = FakeSettingsChannel();
    final store = FakeHistorySettingsStore(entries: _historyEntries);
    await pumpSettings(
      tester,
      channel: channel,
      historyStore: store,
      domain: SettingsDomain.history,
    );

    // Every preset paints — the current value (30 天, a preset) must not
    // vanish from its own chip set.
    expect(
      find.byKey(const Key('settings-history-retention:30')),
      findsOneWidget,
    );
    expect(find.text('30 天'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-history-retention:7')));
    await tester.pump();

    expect(
      store.saves.single,
      const HistorySettings(enabled: true, retentionDays: 7),
    );
    expect(channel.historyChanged, 1);
    // The set still offers 30 天 after the switch.
    expect(find.text('30 天'), findsOneWidget);
  });

  testWidgets('a hand-edited retention value paints as its own chip', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      historyStore: FakeHistorySettingsStore(
        config: const HistorySettings(enabled: true, retentionDays: 45),
      ),
      domain: SettingsDomain.history,
    );
    expect(find.text('45 天'), findsOneWidget);
    expect(find.text('30 天'), findsOneWidget);
  });

  testWidgets('enabling keep-nothing confirms, then clears everything', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    final store = FakeHistorySettingsStore(entries: _historyEntries);
    await pumpSettings(
      tester,
      channel: channel,
      historyStore: store,
      domain: SettingsDomain.history,
    );

    // The switch's enable is destructive: confirm first.
    await tester.tap(find.byKey(const Key('settings-history-keep-nothing')));
    await tester.pump();
    expect(find.text('开启不留存模式？'), findsOneWidget);
    expect(find.text('2 条历史将被永久删除，新会话将不再保留历史。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-history-confirm-cancel')));
    await tester.pump();
    expect(store.saves, isEmpty); // cancelled: nothing written

    // Confirming empties the pane and stops recording.
    await tester.tap(find.byKey(const Key('settings-history-keep-nothing')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-history-confirm-ok')));
    await tester.pump();
    expect(store.saves.single.enabled, false);
    expect(channel.historyChanged, 1);
    expect(
      find.byKey(const Key('settings-history-keep-nothing-note')),
      findsOneWidget,
    );
    expect(find.text('第二句的原话'), findsNothing);

    // Turning it back off resumes: no dialog (nothing to destroy), the
    // empty state paints instead.
    await tester.tap(find.byKey(const Key('settings-history-keep-nothing')));
    await tester.pump();
    expect(store.saves.last.enabled, true);
    expect(find.byKey(const Key('settings-history-empty')), findsOneWidget);
  });

  testWidgets('the one-click clear confirms, then clears and reports', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    final store = FakeHistorySettingsStore(entries: _historyEntries);
    await pumpSettings(
      tester,
      channel: channel,
      historyStore: store,
      domain: SettingsDomain.history,
    );

    await tester.tap(find.byKey(const Key('settings-history-clear')));
    await tester.pump();
    expect(find.text('清空全部历史？'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-history-confirm-ok')));
    await tester.pump();
    expect(store.clears, 1);
    expect(channel.historyChanged, 1);
    expect(find.byKey(const Key('settings-history-empty')), findsOneWidget);
  });

  testWidgets('an empty history paints the empty state; clear is inert', (
    tester,
  ) async {
    final store = FakeHistorySettingsStore();
    await pumpSettings(
      tester,
      historyStore: store,
      domain: SettingsDomain.history,
    );

    expect(find.byKey(const Key('settings-history-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-history-clear')));
    await tester.pump();
    expect(store.clears, 0); // nothing to clear, nothing confirmed
    expect(find.text('清空全部历史？'), findsNothing);
  });

  testWidgets('a failed save surfaces the error and keeps the pane honest', (
    tester,
  ) async {
    final store = FakeHistorySettingsStore(entries: _historyEntries)
      ..failNextSave = StateError('locked');
    await pumpSettings(
      tester,
      historyStore: store,
      domain: SettingsDomain.history,
    );

    await tester.tap(find.byKey(const Key('settings-history-retention:7')));
    await tester.pump();
    expect(textOf(tester, const Key('sr-toast')), '保存失败');
    // The rows survived.
    expect(find.text('第二句的原话'), findsOneWidget);
  });

  // -----------------------------------------------------------------------
  // The terms domain (术语)
  // -----------------------------------------------------------------------

  testWidgets('a term adds through the field, lands, and reports the change', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    final store = FakeTermsStore(['既有术语']);
    await pumpSettings(
      tester,
      channel: channel,
      termsStore: store,
      domain: SettingsDomain.terms,
    );

    await tester.enterText(
      find.byKey(const Key('settings-terms-field')),
      'EGFR抑制剂',
    );
    await tester.tap(find.byKey(const Key('settings-terms-add')));
    await tester.pump();

    expect(store.terms, ['既有术语', 'EGFR抑制剂']);
    expect(find.byKey(const Key('settings-terms-row:EGFR抑制剂')), findsOneWidget);
    expect(channel.termsChanged, 1);

    // Blank input adds nothing and reports nothing.
    await tester.enterText(find.byKey(const Key('settings-terms-field')), '  ');
    await tester.tap(find.byKey(const Key('settings-terms-add')));
    await tester.pump();
    expect(store.terms.length, 2);
    expect(channel.termsChanged, 1);
  });

  testWidgets('a rename edits the row in place and refuses collisions', (
    tester,
  ) async {
    final store = FakeTermsStore(['甲', '乙']);
    await pumpSettings(tester, termsStore: store, domain: SettingsDomain.terms);

    await hoverRowAction(
      tester,
      const Key('settings-terms-rename:甲'),
      Icons.edit_outlined,
    );
    await tester.pump();

    // Renaming onto the other entry is refused; nothing was written.
    await tester.enterText(
      find.byKey(const Key('settings-terms-rename-field')),
      '乙',
    );
    await tester.tap(find.byKey(const Key('settings-terms-rename-save')));
    await tester.pump();
    expect(find.byKey(const Key('settings-terms-form-error')), findsOneWidget);
    expect(store.terms, ['甲', '乙']);

    // A real rename replaces the row where it sits.
    await tester.enterText(
      find.byKey(const Key('settings-terms-rename-field')),
      '丙',
    );
    await tester.tap(find.byKey(const Key('settings-terms-rename-save')));
    await tester.pump();
    expect(store.terms, ['丙', '乙']);
    expect(find.byKey(const Key('settings-terms-row:甲')), findsNothing);
    expect(find.byKey(const Key('settings-terms-row:丙')), findsOneWidget);
    expect(find.byKey(const Key('settings-terms-row:乙')), findsOneWidget);
  });

  testWidgets('a remove deletes the row and reports the change', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    final store = FakeTermsStore(['甲']);
    await pumpSettings(
      tester,
      channel: channel,
      termsStore: store,
      domain: SettingsDomain.terms,
    );

    await hoverRowAction(
      tester,
      const Key('settings-terms-remove:甲'),
      Icons.delete_outline_rounded,
    );
    await tester.pump();

    expect(store.terms, isEmpty);
    expect(find.byKey(const Key('settings-terms-empty')), findsOneWidget);
    expect(channel.termsChanged, 1);
  });

  testWidgets('a failed mutation surfaces the error and keeps the list', (
    tester,
  ) async {
    final store = FakeTermsStore(['甲']);
    await pumpSettings(tester, termsStore: store, domain: SettingsDomain.terms);

    // The dictionary moved underneath the editor (a stale model): the
    // rename throws and the pane says so, rows intact.
    await hoverRowAction(
      tester,
      const Key('settings-terms-rename:甲'),
      Icons.edit_outlined,
    );
    await tester.pump();
    store.terms.clear(); // the file changed since the dialog opened
    await tester.enterText(
      find.byKey(const Key('settings-terms-rename-field')),
      '新名',
    );
    await tester.tap(find.byKey(const Key('settings-terms-rename-save')));
    await tester.pump();
    expect(textOf(tester, const Key('sr-toast')), '操作失败');
  });

  // -----------------------------------------------------------------------
  // The rectify domain (修正)
  // -----------------------------------------------------------------------

  /// A tall surface so the three cards (and the light / quick tails)
  /// build at once — a lazy ListView drops off-screen rows, and the
  /// default 800×600 test window clips the extra-directive fields.
  void tallRectifySurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('the two cards paint; a pick commits the whole model at once', (
    tester,
  ) async {
    tallRectifySurface(tester);
    final store = FakeRectifyBehaviorStore();
    await pumpSettings(
      tester,
      rectifyStore: store,
      domain: SettingsDomain.rectify,
    );
    await tester.pump(); // the behavior load lands

    // The section-named card headers (full on top — the default
    // path), the inputs seeded from the committed truth.
    expect(find.text('全量模式'), findsOneWidget);
    expect(find.text('轻修模式'), findsOneWidget);
    expect(
      fieldText(tester, const Key('settings-rectify-light-threshold')),
      '40',
    );

    // A chip click commits at once: the whole model, every other
    // pick and both inputs as committed, and the files go to the
    // live engine right after (ADR-0010's adoption).
    await tester.tap(find.byKey(const Key('settings-rectify-full-policy:off')));
    await tester.pump();
    final pick = store.saves.single;
    expect(pick.fullThinkingPolicy, 'off');
    expect(pick.fullPrefill, isTrue); // untouched picks ride
    expect(pick.lightTouchMaxChars, 40); // the committed input rides
    expect(store.applyCalls, 1);
    expect(textOf(tester, const Key('sr-toast')), '已保存');

    // The dirty-state warning lights with the pick itself (off ×
    // prefill-on), and dies when the switch flips it off.
    expect(
      find.byKey(const Key('settings-rectify-full-warning')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('settings-rectify-full-prefill')));
    await tester.pump();
    expect(store.saves.last.fullPrefill, isFalse);
    expect(
      find.byKey(const Key('settings-rectify-full-warning')),
      findsNothing,
    );

    // A draft input is never swept along by a pick: the threshold
    // field holds 25, but the master-switch flip commits the
    // committed 40 — and the field keeps its draft.
    await scrollRectifyTo(
      tester,
      const Key('settings-rectify-light-threshold'),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-rectify-light-threshold')),
      '25',
    );
    await tester.pump();
    expect(
      fieldText(tester, const Key('settings-rectify-light-threshold')),
      '25',
    );
    await tester.ensureVisible(
      find.byKey(const Key('settings-rectify-light-enabled')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-rectify-light-enabled')));
    await tester.pump();
    expect(store.saves.last.lightTouchEnabled, isFalse);
    expect(store.saves.last.lightTouchMaxChars, 40); // not the draft

    // Disabled is not hidden: the tail still paints, but its controls
    // are shielded — a tap on the light prefill switch saves nothing.
    await scrollRectifyTo(tester, const Key('settings-rectify-light-prefill'));
    await tester.pump();
    // AbsorbPointer owns the hit (the tail is disabled in place, never
    // hidden): the tap must miss the switch, and the store stays at
    // three saves. Silence the miss-hit warning — that miss is the
    // assertion.
    await tester.tap(
      find.byKey(const Key('settings-rectify-light-prefill')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(store.saves, hasLength(3)); // the two picks + the flip only
  });

  testWidgets(
    'a loaded combo lights its own tier only; a disabled tier stays silent',
    (tester) async {
      tallRectifySurface(tester);
      // A legacy combination that loaded this way from the files: the
      // light tier is 思考关 × 预填开 — but its master switch is off, so
      // it consumes nothing; full is clean.
      final store = FakeRectifyBehaviorStore(
        const RectifyBehavior(
          fullThinkingPolicy: 'always',
          fullPrefill: true,
          lightTouchEnabled: false,
          lightTouchMaxChars: 40,
          lightTouchThinkingPolicy: 'off',
          lightTouchPrefill: true,
        ),
      );
      await pumpSettings(
        tester,
        rectifyStore: store,
        domain: SettingsDomain.rectify,
      );
      await tester.pump();

      // 存量组合也亮 — per tier: the full tier is clean, the disabled
      // light tier's combo stays silent (its warning rides the shield).
      expect(
        find.byKey(const Key('settings-rectify-full-warning')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('settings-rectify-light-warning')),
        findsNothing,
      );

      // Flipping the master on makes the tier consume its combo again:
      // the pick commits and the warning lights with the same save.
      await tester.tap(find.byKey(const Key('settings-rectify-light-enabled')));
      await tester.pump();
      expect(store.saves.single.lightTouchEnabled, isTrue);
      expect(store.saves.single.lightTouchMaxChars, 40);
      expect(
        find.byKey(const Key('settings-rectify-light-warning')),
        findsOneWidget,
      );

      // And the light tier's own chip now lights it live too.
      await scrollRectifyTo(
        tester,
        const Key('settings-rectify-light-policy:off'),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('settings-rectify-light-policy:always')),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('settings-rectify-light-warning')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'an inert connection locks both thinking chip rows and silences both warnings',
    (tester) async {
      tallRectifySurface(tester);
      // Both tiers carry the 思考关 × 预填开 combination and the light
      // master is on, so both warnings would light — but the connection
      // domain's thinking fields are off, so neither does (ADR-0019
      // item 3: 开关关 / 未配置 / 坏配置 are one semantic for the
      // rectify domain).
      for (final state in ['off', 'unconfigured', 'broken']) {
        final store = FakeRectifyBehaviorStore(
          RectifyBehavior(
            fullThinkingPolicy: 'off',
            fullPrefill: true,
            lightTouchEnabled: true,
            lightTouchMaxChars: 40,
            lightTouchThinkingPolicy: 'off',
            lightTouchPrefill: true,
            connectionThinking: state,
          ),
        );
        await pumpSettings(
          tester,
          rectifyStore: store,
          domain: SettingsDomain.rectify,
        );
        await tester.pump();

        expect(
          find.byKey(const Key('settings-rectify-full-warning')),
          findsNothing,
          reason: '$state: the full warning must stay silent',
        );
        expect(
          find.byKey(const Key('settings-rectify-light-warning')),
          findsNothing,
          reason: '$state: the light warning must stay silent',
        );
        expect(
          textOf(tester, const Key('settings-rectify-full-thinking-off')),
          contains('「模型与连接」'),
          reason: '$state: the full card must say where recovery lives',
        );
        expect(
          textOf(tester, const Key('settings-rectify-light-thinking-off')),
          contains('暂不可选'),
          reason: '$state: the light card must say the same',
        );

        // The chips answer no tap: the model never moves.
        await tester.tap(
          find.byKey(const Key('settings-rectify-full-policy:always')),
        );
        await tester.pump();
        expect(
          store.saves,
          isEmpty,
          reason: '$state: a disabled chip must not commit',
        );
      }
    },
  );

  testWidgets('a live connection leaves both chip rows and warnings alone', (
    tester,
  ) async {
    tallRectifySurface(tester);
    // The same combination with the connection's fields live: the chips
    // answer and the warning lights — recovery is exactly this state.
    final store = FakeRectifyBehaviorStore(
      const RectifyBehavior(
        fullThinkingPolicy: 'off',
        fullPrefill: true,
        lightTouchEnabled: true,
        lightTouchMaxChars: 40,
        lightTouchThinkingPolicy: 'off',
        lightTouchPrefill: true,
      ),
    );
    await pumpSettings(
      tester,
      rectifyStore: store,
      domain: SettingsDomain.rectify,
    );
    await tester.pump();

    expect(
      find.byKey(const Key('settings-rectify-full-thinking-off')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('settings-rectify-full-warning')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('settings-rectify-full-policy:always')),
    );
    await tester.pump();
    expect(store.saves.single.fullThinkingPolicy, 'always');
  });

  testWidgets(
    "the light card's one button commits both inputs; blank unsets the directive",
    (tester) async {
      tallRectifySurface(tester);
      final store = FakeRectifyBehaviorStore();
      await pumpSettings(
        tester,
        rectifyStore: store,
        domain: SettingsDomain.rectify,
      );
      await tester.pump();

      // Quiet at rest: no change, no commit.
      expect(
        tester
            .widget<SrButton>(
              find.byKey(const Key('settings-rectify-light-save')),
            )
            .onTap,
        isNull,
      );

      await scrollRectifyTo(
        tester,
        const Key('settings-rectify-light-threshold'),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('settings-rectify-light-threshold')),
        '60',
      );
      await scrollRectifyTo(tester, const Key('settings-rectify-light-extra'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('settings-rectify-light-extra')),
        '  保持短句  ',
      );
      await scrollRectifyTo(tester, const Key('settings-rectify-light-save'));
      await tester.pump();
      // Dirty now: the button is live.
      expect(
        tester
            .widget<SrButton>(
              find.byKey(const Key('settings-rectify-light-save')),
            )
            .onTap,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('settings-rectify-light-save')));
      await tester.pump();

      // One write for both inputs, the picks riding as they stand.
      final save = store.saves.single;
      expect(save.lightTouchMaxChars, 60);
      expect(save.lightTouchExtraDirective, '保持短句');
      expect(save.fullThinkingPolicy, 'always'); // untouched picks ride
      expect(store.applyCalls, 1);

      // The save re-baselined the fields: the drafts became the
      // committed truth and the button is quiet again.
      expect(
        fieldText(tester, const Key('settings-rectify-light-threshold')),
        '60',
      );
      expect(
        fieldText(tester, const Key('settings-rectify-light-extra')),
        '保持短句',
      );
      expect(
        tester
            .widget<SrButton>(
              find.byKey(const Key('settings-rectify-light-save')),
            )
            .onTap,
        isNull,
      );

      // Blanking the directive is the off switch: the next commit
      // writes the unset form (the key is removed from the file).
      await tester.enterText(
        find.byKey(const Key('settings-rectify-light-extra')),
        '   ',
      );
      await tester.pump();
      await scrollRectifyTo(tester, const Key('settings-rectify-light-save'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-rectify-light-save')));
      await tester.pump();
      expect(store.saves.last.lightTouchExtraDirective, isNull);
      expect(store.saves.last.lightTouchMaxChars, 60);
    },
  );

  testWidgets('a bad threshold refuses the save with a visible error', (
    tester,
  ) async {
    tallRectifySurface(tester);
    final store = FakeRectifyBehaviorStore();
    await pumpSettings(
      tester,
      rectifyStore: store,
      domain: SettingsDomain.rectify,
    );
    await tester.pump();

    await scrollRectifyTo(
      tester,
      const Key('settings-rectify-light-threshold'),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-rectify-light-threshold')),
      'soon',
    );
    await scrollRectifyTo(tester, const Key('settings-rectify-light-save'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-rectify-light-save')));
    await tester.pump();
    expect(textOf(tester, const Key('sr-toast')), '阈值需为大于 0 的整数');
    expect(store.saves, isEmpty); // refused before any write
    expect(store.applyCalls, 0);

    // Zero is as wrong as text; the field keeps the draft for a fix.
    await tester.enterText(
      find.byKey(const Key('settings-rectify-light-threshold')),
      '0',
    );
    await tester.pump();
    await scrollRectifyTo(tester, const Key('settings-rectify-light-save'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-rectify-light-save')));
    await tester.pump();
    expect(store.saves, isEmpty);
  });

  testWidgets(
    'a failed save keeps the picks; a refused adoption keeps the banner contract',
    (tester) async {
      tallRectifySurface(tester);
      final store = FakeRectifyBehaviorStore()
        ..failNextSave = StateError('locked');
      await pumpSettings(
        tester,
        rectifyStore: store,
        domain: SettingsDomain.rectify,
      );
      await tester.pump();

      // The file refused the write: the error says so, nothing was
      // adopted, and a re-tap is the retry.
      await tester.tap(
        find.byKey(const Key('settings-rectify-full-policy:off')),
      );
      await tester.pump();
      expect(textOf(tester, const Key('sr-toast')), '保存失败');
      expect(store.saves, isEmpty);
      expect(store.applyCalls, 0);

      await tester.tap(
        find.byKey(const Key('settings-rectify-full-policy:off')),
      );
      await tester.pump();
      expect(store.saves.single.fullThinkingPolicy, 'off');
      expect(store.applyCalls, 1);

      // Saved but not adopted: two states, never one masquerading as
      // the other — the connection domain's banner, verbatim.
      store.failNextApply = 'no adapter yet';
      await tester.tap(find.byKey(const Key('settings-rectify-full-prefill')));
      await tester.pump();
      expect(store.saves.last.fullPrefill, isFalse);
      expect(textOf(tester, const Key('sr-toast')), '已保存');
      expect(store.applyCalls, 1); // the refusal was not an adoption
    },
  );

  testWidgets(
    'the quick card paints disabled-not-hidden; a master pick commits the whole model',
    (tester) async {
      tallRectifySurface(tester);
      final store = FakeRectifyBehaviorStore();
      await pumpSettings(
        tester,
        rectifyStore: store,
        domain: SettingsDomain.rectify,
      );
      await tester.pump();

      expect(find.text('快速模式'), findsOneWidget);
      expect(
        tester
            .widget<Switch>(
              find.byKey(const Key('settings-rectify-quick-enabled')),
            )
            .value,
        isFalse,
      );

      // Default master-off: the tail still paints, but its controls are
      // shielded — a tap on 启用修正 or the save saves nothing.
      await scrollRectifyTo(
        tester,
        const Key('settings-rectify-quick-rectify'),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('settings-rectify-quick-rectify')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('settings-rectify-quick-rectify')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(store.saves, isEmpty);

      await scrollRectifyTo(tester, const Key('settings-rectify-quick-extra'));
      await tester.pump();
      expect(
        find.byKey(const Key('settings-rectify-quick-extra')),
        findsOneWidget,
      );
      await scrollRectifyTo(tester, const Key('settings-rectify-quick-save'));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('settings-rectify-quick-save')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(store.saves, isEmpty);

      // A draft extra is never swept along by a pick: the field holds
      // text, but flipping the master commits the committed (null) extra.
      await tester.enterText(
        find.byKey(const Key('settings-rectify-quick-extra')),
        '短句节奏',
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const Key('settings-rectify-quick-enabled')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-rectify-quick-enabled')));
      await tester.pump();
      final pick = store.saves.single;
      expect(pick.quickEnabled, isTrue);
      expect(pick.quickRectify, isTrue); // default rides
      expect(pick.quickExtraDirective, isNull); // not the draft
      expect(pick.fullThinkingPolicy, 'always');
      expect(pick.lightTouchMaxChars, 40);
      expect(store.applyCalls, 1);
    },
  );

  testWidgets(
    "the quick card's rectify switch shields the extra; its save blanks to unset",
    (tester) async {
      tallRectifySurface(tester);
      final store = FakeRectifyBehaviorStore(
        const RectifyBehavior(
          fullThinkingPolicy: 'always',
          fullPrefill: true,
          lightTouchEnabled: true,
          lightTouchMaxChars: 40,
          lightTouchThinkingPolicy: 'always',
          lightTouchPrefill: true,
          quickEnabled: true,
        ),
      );
      await pumpSettings(
        tester,
        rectifyStore: store,
        domain: SettingsDomain.rectify,
      );
      await tester.pump();

      // Quiet at rest: no change, no commit.
      await scrollRectifyTo(tester, const Key('settings-rectify-quick-save'));
      await tester.pump();
      expect(
        tester
            .widget<SrButton>(
              find.byKey(const Key('settings-rectify-quick-save')),
            )
            .onTap,
        isNull,
      );

      await scrollRectifyTo(tester, const Key('settings-rectify-quick-extra'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('settings-rectify-quick-extra')),
        '  保持短句  ',
      );
      await scrollRectifyTo(tester, const Key('settings-rectify-quick-save'));
      await tester.pump();
      expect(
        tester
            .widget<SrButton>(
              find.byKey(const Key('settings-rectify-quick-save')),
            )
            .onTap,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('settings-rectify-quick-save')));
      await tester.pump();

      final save = store.saves.single;
      expect(save.quickExtraDirective, '保持短句');
      expect(save.quickEnabled, isTrue);
      expect(save.lightTouchExtraDirective, isNull); // the other extra rides
      expect(store.applyCalls, 1);
      expect(
        fieldText(tester, const Key('settings-rectify-quick-extra')),
        '保持短句',
      );
      expect(
        tester
            .widget<SrButton>(
              find.byKey(const Key('settings-rectify-quick-save')),
            )
            .onTap,
        isNull,
      );

      // Blanking the directive is the off switch.
      await tester.enterText(
        find.byKey(const Key('settings-rectify-quick-extra')),
        '   ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-rectify-quick-save')));
      await tester.pump();
      expect(store.saves.last.quickExtraDirective, isNull);

      // 启用修正 off: the extra still paints, but its controls are
      // shielded — a tap on the save saves nothing further.
      await tester.ensureVisible(
        find.byKey(const Key('settings-rectify-quick-rectify')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-rectify-quick-rectify')));
      await tester.pump();
      expect(store.saves.last.quickRectify, isFalse);
      final afterFlip = store.saves.length;
      await tester.enterText(
        find.byKey(const Key('settings-rectify-quick-extra')),
        '不该落盘',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('settings-rectify-quick-save')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(store.saves, hasLength(afterFlip));
      expect(
        find.byKey(const Key('settings-rectify-quick-extra')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a light pick never consumes a quick extra draft, and the reverse',
    (tester) async {
      tallRectifySurface(tester);
      final store = FakeRectifyBehaviorStore(
        const RectifyBehavior(
          fullThinkingPolicy: 'always',
          fullPrefill: true,
          lightTouchEnabled: true,
          lightTouchMaxChars: 40,
          lightTouchThinkingPolicy: 'always',
          lightTouchPrefill: true,
          quickEnabled: true,
        ),
      );
      await pumpSettings(
        tester,
        rectifyStore: store,
        domain: SettingsDomain.rectify,
      );
      await tester.pump();

      // Dirty the light extra, then flip the quick master: the light
      // draft stays out of that write.
      await scrollRectifyTo(tester, const Key('settings-rectify-light-extra'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('settings-rectify-light-extra')),
        '轻修草稿',
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const Key('settings-rectify-quick-enabled')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-rectify-quick-enabled')));
      await tester.pump();
      expect(store.saves.single.lightTouchExtraDirective, isNull);
      expect(store.saves.single.quickEnabled, isFalse);

      // Dirty the quick extra, then flip the light master: the quick
      // draft stays out of that write.
      await tester.tap(find.byKey(const Key('settings-rectify-quick-enabled')));
      await tester.pump();
      await scrollRectifyTo(tester, const Key('settings-rectify-quick-extra'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('settings-rectify-quick-extra')),
        '快速草稿',
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const Key('settings-rectify-light-enabled')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-rectify-light-enabled')));
      await tester.pump();
      expect(store.saves.last.quickExtraDirective, isNull);
      expect(store.saves.last.lightTouchEnabled, isFalse);
    },
  );

  // -----------------------------------------------------------------------
  // The connection domain (模型与连接)
  // -----------------------------------------------------------------------

  testWidgets('the two cards paint the config; a local key echoes masked', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      llm: fakeLlm(
        keys: const {
          'deepseek': KeyInfo(
            status: KeyPlacement.inLocalFile,
            storedKey: 'sk-stored',
          ),
          'volcengine': KeyInfo(
            status: KeyPlacement.inLocalFile,
            storedKey: 'ark-stored',
          ),
        },
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // The stored local-file key echoes into the field, masked by
    // default; the eye toggles plain text (ADR-0008 revision).
    expect(fieldText(tester, const Key('settings-conn-llm-key')), 'sk-stored');
    TextField keyField() => tester.widget<TextField>(
      find
          .descendant(
            of: find.byKey(const Key('settings-conn-llm-key')),
            matching: find.byType(TextField),
          )
          .first,
    );
    expect(keyField().obscureText, isTrue);
    await tester.tap(find.byKey(const Key('settings-conn-key-eye:llm')));
    await tester.pump();
    expect(keyField().obscureText, isFalse);
    // No standalone clear button anywhere: clearing rides the save.
    expect(find.byKey(const Key('settings-conn-key-clear:llm')), findsNothing);
    expect(find.byKey(const Key('settings-conn-asr-endpoint')), findsOneWidget);
    // The header caption is retired (copy.md conn-02); the adoption
    // semantics live in the spec, not on the page.
    expect(
      find.byKey(const Key('settings-conn-effective-note')),
      findsNothing,
    );
  });

  testWidgets('an env key never echoes; no status line paints', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      llm: fakeLlm(
        keys: const {
          'deepseek': KeyInfo(
            status: KeyPlacement.fromEnv,
            envName: 'DEEPSEEK_API_KEY',
          ),
        },
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    expect(fieldText(tester, const Key('settings-conn-llm-key')), isEmpty);
    // The key block's status line is retired (copy.md conn-20/21).
    expect(
      find.byKey(const Key('settings-conn-key-status:llm')),
      findsNothing,
    );
    expect(find.textContaining('输入即另存本机'), findsNothing);
  });

  testWidgets('a chip click prefills the vendor endpoint and model', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // The painted model is the v1 default, `deepseek-flash` — which is
    // also the deepseek preset's own model name, so the chip carries it
    // to the new vendor's model like any other preset name (ADR-0019
    // item 5 spares only names no preset claims; the hand-typed leg
    // below is the survival case).
    await tester.tap(
      find.byKey(const Key('settings-conn-llm-vendors:volcengine')),
    );
    await tester.pump();
    expect(
      fieldText(tester, const Key('settings-conn-llm-baseurl')),
      'https://ark.cn-beijing.volces.com/api/v3',
    );
    expect(
      fieldText(tester, const Key('settings-conn-llm-model')),
      'doubao-seed-2.0-lite',
    );

    // A model that IS some preset's name is freely replaced.
    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-model')),
      'claude-sonnet-5',
    );
    await tester.tap(find.byKey(const Key('settings-conn-llm-vendors:qwen')));
    await tester.pump();
    expect(
      fieldText(tester, const Key('settings-conn-llm-baseurl')),
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
    );
    expect(
      fieldText(tester, const Key('settings-conn-llm-model')),
      'qwen3.8-flash',
    );

    // A hand-typed name survives the next chip click; the endpoint
    // switches unconditionally (that is the point of the click).
    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-model')),
      'my-own-model',
    );
    await tester.tap(find.byKey(const Key('settings-conn-llm-vendors:openai')));
    await tester.pump();
    expect(
      fieldText(tester, const Key('settings-conn-llm-baseurl')),
      'https://api.openai.com/v1',
    );
    expect(
      fieldText(tester, const Key('settings-conn-llm-model')),
      'my-own-model',
    );

    // An empty field is filled.
    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-model')),
      '',
    );
    await tester.tap(
      find.byKey(const Key('settings-conn-llm-vendors:deepseek')),
    );
    await tester.pump();
    expect(
      fieldText(tester, const Key('settings-conn-llm-model')),
      'deepseek-flash',
    );
  });

  testWidgets('a vendor chip click re-binds the key block to that vendor', (
    tester,
  ) async {
    // Ticket 26's acceptance defect: one shared key field carried the
    // previous vendor's key across a chip click. Each vendor now binds
    // its own pair (ADR-0011) — a stored key shows its own, a vendor
    // without one shows empty, and a round trip loses nothing.
    final store = FakeConnectionStore(
      llm: fakeLlm(
        keys: const {
          'deepseek': KeyInfo(
            status: KeyPlacement.inLocalFile,
            storedKey: 'sk-stored',
          ),
          'volcengine': KeyInfo(
            status: KeyPlacement.inLocalFile,
            storedKey: 'ark-stored',
          ),
        },
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    expect(fieldText(tester, const Key('settings-conn-llm-key')), 'sk-stored');

    // Volcengine has its own stored key: the field shows THAT, never
    // deepseek's.
    await tester.tap(
      find.byKey(const Key('settings-conn-llm-vendors:volcengine')),
    );
    await tester.pump();
    expect(fieldText(tester, const Key('settings-conn-llm-key')), 'ark-stored');

    // Qwen stored nothing: the field is empty, not a borrowed key.
    await tester.tap(find.byKey(const Key('settings-conn-llm-vendors:qwen')));
    await tester.pump();
    expect(fieldText(tester, const Key('settings-conn-llm-key')), isEmpty);

    // Back to deepseek: its pair is where it was.
    await tester.tap(
      find.byKey(const Key('settings-conn-llm-vendors:deepseek')),
    );
    await tester.pump();
    expect(fieldText(tester, const Key('settings-conn-llm-key')), 'sk-stored');
  });

  testWidgets('a vendor-switch save keeps every other vendor key', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      llm: fakeLlm(
        keys: const {
          'deepseek': KeyInfo(
            status: KeyPlacement.inLocalFile,
            storedKey: 'sk-stored',
          ),
        },
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    await tester.tap(
      find.byKey(const Key('settings-conn-llm-vendors:volcengine')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-key')),
      'ark-new',
    );
    // Center the button: the default edge alignment leaves its center
    // clipped by the viewport top after the field's auto-scroll.
    Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('settings-conn-llm-save'))),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();

    final save = store.llmSaves.single;
    expect(save.vendor, 'volcengine');
    expect(
      save.apiKey,
      isA<ApiKeySet>().having((k) => k.key, 'key', 'ark-new'),
    );
    // The re-read truth: volcengine's slot moves, deepseek's survives.
    expect(store.llm.keys['volcengine']!.storedKey, 'ark-new');
    expect(store.llm.keys['deepseek']!.storedKey, 'sk-stored');
  });

  testWidgets('an llm save writes the form; an untouched key keeps', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-model')),
      'deepseek-v4-pro',
    );
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();

    final save = store.llmSaves.single;
    expect(save.vendor, 'deepseek');
    expect(save.model, 'deepseek-v4-pro');
    expect(save.baseUrl, 'https://api.deepseek.com'); // untouched field rides
    expect(save.apiKey, isA<ApiKeyKeep>()); // the echoed key, unchanged
    // The save note is the window toast now (top-center overlay).
    expect(textOf(tester, const Key('sr-toast')), '已保存');
  });

  // -- the open shape: format, boxes, the blank custom chip (ADR-0019) --

  testWidgets('the card paints the format trio and the three boxes', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // The format chips over the three wire names, the loaded one selected.
    for (final format in ['openai_chat', 'anthropic', 'gemini']) {
      expect(
        find.byKey(Key('settings-conn-llm-format:$format')),
        findsOneWidget,
      );
    }
    // The boxes: the resident one, and the thinking pair under the switch.
    expect(find.byKey(const Key('settings-conn-llm-body')), findsOneWidget);
    expect(
      find.byKey(const Key('settings-conn-llm-thinking-on')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings-conn-llm-thinking-off')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings-conn-llm-thinking-fields')),
      findsOneWidget,
    );
    // The preset chip row is the port's — six presets plus 自定义.
    expect(
      find.byKey(const Key('settings-conn-llm-vendors:custom')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings-conn-llm-vendors:anthropic')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings-conn-llm-vendors:gemini')),
      findsOneWidget,
    );
  });

  testWidgets('a preset chip stamps format, endpoint, model, and both shares', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // The harness paints nothing yet (the fake's view carries no shares),
    // so a chip click is what fills the boxes. The endpoint's model is
    // cleared first: the painted v1 default is not a preset name, so the
    // chip would keep it (ADR-0019 item 5).
    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-model')),
      '',
    );
    await tester.tap(
      find.byKey(const Key('settings-conn-llm-vendors:anthropic')),
    );
    await tester.pump();

    expect(
      fieldText(tester, const Key('settings-conn-llm-baseurl')),
      'https://api.anthropic.com',
    );
    expect(
      fieldText(tester, const Key('settings-conn-llm-model')),
      'claude-sonnet-5',
    );
    expect(
      fieldText(tester, const Key('settings-conn-llm-thinking-on')),
      contains('adaptive'),
    );
    expect(
      fieldText(tester, const Key('settings-conn-llm-thinking-off')),
      contains('disabled'),
    );

    // The stamp rides the save whole: format, switch, and the shares.
    Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('settings-conn-llm-save'))),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();

    final save = store.llmSaves.single;
    expect(save.vendor, 'anthropic');
    expect(save.format, 'anthropic');
    expect(save.thinkingFields, isTrue);
    expect(save.thinkingOnJson, contains('adaptive'));
    expect(save.thinkingOffJson, contains('disabled'));
  });

  testWidgets('the format chips switch the axis without touching the boxes', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-body')),
      '{"temperature": 0.1}',
    );
    await tester.tap(find.byKey(const Key('settings-conn-llm-format:gemini')));
    await tester.pump();

    Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('settings-conn-llm-save'))),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();

    final save = store.llmSaves.single;
    expect(save.format, 'gemini');
    // The resident box is the user's own text, not a preset field.
    expect(save.bodyJson, '{"temperature": 0.1}');
  });

  testWidgets(
    'the custom chip is the blank preset: it clears and keeps the format',
    (tester) async {
      final store = FakeConnectionStore();
      await pumpSettings(
        tester,
        connectionStore: store,
        domain: SettingsDomain.connection,
      );

      // Start from a painted preset, then blank it.
      await tester.tap(
        find.byKey(const Key('settings-conn-llm-vendors:gemini')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('settings-conn-llm-body')),
        '{"top_p": 0.9}',
      );
      await tester.tap(
        find.byKey(const Key('settings-conn-llm-vendors:custom')),
      );
      await tester.pump();

      expect(find.text('自定义'), findsOneWidget);
      expect(
        fieldText(tester, const Key('settings-conn-llm-baseurl')),
        isEmpty,
      );
      expect(fieldText(tester, const Key('settings-conn-llm-model')), isEmpty);
      expect(
        fieldText(tester, const Key('settings-conn-llm-thinking-on')),
        isEmpty,
      );
      expect(
        fieldText(tester, const Key('settings-conn-llm-thinking-off')),
        isEmpty,
      );
      // The format keeps the current 档 and the resident box is untouched.
      expect(
        tester
            .widget<Switch>(
              find.byKey(const Key('settings-conn-llm-thinking-fields')),
            )
            .value,
        isFalse,
      );

      Scrollable.ensureVisible(
        tester.element(find.byKey(const Key('settings-conn-llm-save'))),
        alignment: 0.5,
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('settings-conn-llm-baseurl')),
        'https://my.example',
      );
      await tester.enterText(
        find.byKey(const Key('settings-conn-llm-model')),
        'my-model',
      );
      await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
      await tester.pump();

      final save = store.llmSaves.single;
      expect(save.vendor, 'custom');
      expect(save.format, 'gemini'); // the current 档 survives the blank
      expect(save.thinkingFields, isFalse);
      expect(save.thinkingOnJson, isNull);
      expect(save.bodyJson, '{"top_p": 0.9}'); // never a preset field
    },
  );

  testWidgets('the switch governs the two boxes but both still ride the save', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      llm: fakeLlm(
        thinkingState: 'off',
        thinkingOnJson: '{"thinking": {"type": "adaptive"}}',
        thinkingOffJson: '{"thinking": {"type": "disabled"}}',
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // An off switch paints off; the note is one static caption now
    // (copy.md conn-13..15), the same line for every state.
    expect(
      tester
          .widget<Switch>(
            find.byKey(const Key('settings-conn-llm-thinking-fields')),
          )
          .value,
      isFalse,
    );
    expect(
      textOf(tester, const Key('settings-conn-llm-thinking-note')),
      '编辑模型供应商的模型思考配置字段',
    );

    // Flipping it on turns the fields live; both boxes keep their text.
    await tester.tap(
      find.byKey(const Key('settings-conn-llm-thinking-fields')),
    );
    await tester.pump();
    expect(
      textOf(tester, const Key('settings-conn-llm-thinking-note')),
      '编辑模型供应商的模型思考配置字段',
    );

    Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('settings-conn-llm-save'))),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();

    // Off is a stance, not a deletion: both shares ride the save.
    final save = store.llmSaves.single;
    expect(save.thinkingFields, isTrue);
    expect(save.thinkingOnJson, contains('adaptive'));
    expect(save.thinkingOffJson, contains('disabled'));
  });

  testWidgets('an unconfigured group paints off with the shared caption', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      llm: fakeLlm(thinkingState: 'unconfigured'),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    expect(
      textOf(tester, const Key('settings-conn-llm-thinking-note')),
      '编辑模型供应商的模型思考配置字段',
    );
  });

  testWidgets('a broken group paints its detail and holds the save', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      llm: fakeLlm(
        thinkingState: 'broken',
        thinkingDetail:
            'spokenrectifier.toml: [llm]: thinking_fields must be a boolean',
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    expect(
      textOf(tester, const Key('settings-conn-llm-thinking-broken')),
      '思考字段配置有误',
    );
    // The break's detail lives in the file the user is about to
    // hand-fix, never on the card (copy.md conn-12).
    expect(find.textContaining('must be a boolean'), findsNothing);
    // The save button is disabled, never a click certain to fail.
    expect(
      tester
          .widget<SrButton>(find.byKey(const Key('settings-conn-llm-save')))
          .onTap,
      isNull,
    );
  });

  testWidgets('a refused save relays the error and adopts nothing', (
    tester,
  ) async {
    final store = FakeConnectionStore()
      ..failNextSave = Exception(
        '[llm.overlays] thinking_on is not valid JSON: expected value',
      );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-baseurl')),
      'https://my.example',
    );
    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-thinking-on')),
      '{"thinking": ',
    );
    Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('settings-conn-llm-save'))),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pumpAndSettle();
    // A refused save is the window toast's short sentence; the raw JSON
    // complaint never reaches the screen (it goes to the log).
    expect(textOf(tester, const Key('sr-toast')), '保存失败');
    expect(find.textContaining('thinking_on is not valid JSON'), findsNothing);
    expect(store.applyCalls, 0); // no adoption after a refused save
  });

  testWidgets('a typed key replaces; emptying one confirms then clears', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // Typed text = Set; the re-read view echoes the new key back.
    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-key')),
      'sk-new',
    );
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();
    final set = store.llmSaves.single;
    expect(set.apiKey, isA<ApiKeySet>());
    expect((set.apiKey as ApiKeySet).key, 'sk-new');
    // The status line is retired (copy.md conn-20/21); the echo in the
    // field below is the only paint of the stored key.
    expect(
      find.byKey(const Key('settings-conn-key-status:llm')),
      findsNothing,
    );
    expect(fieldText(tester, const Key('settings-conn-llm-key')), 'sk-new');

    // Emptying the echoed key and saving asks one confirm; cancelling
    // writes nothing at all.
    await tester.enterText(find.byKey(const Key('settings-conn-llm-key')), '');
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();
    expect(find.text('清除密钥？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-conn-clear-cancel')));
    await tester.pump();
    expect(store.llmSaves.length, 1);

    // Confirming saves with an explicit Clear (the field is empty again).
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-clear-ok')));
    await tester.pump();
    final clear = store.llmSaves.last;
    expect(clear.apiKey, isA<ApiKeyClear>());
    expect(fieldText(tester, const Key('settings-conn-llm-key')), isEmpty);
  });

  testWidgets('an asr save turns blank optional fields into resets', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      asr: const AsrConnection(
        provider: 'aliyun',
        model: 'qwen3-asr-flash-realtime',
        language: 'zh',
        baseUrl: null,
        endpoint: 'wss://llm-abc.cn-beijing.maas.aliyuncs.com/x',
        key: KeyInfo(status: KeyPlacement.unset),
        aliyun: AsrAliyun(workspaceId: 'llm-abc', region: 'cn-beijing'),
        volcengine: AsrVolcengine(
          appId: null,
          resourceId: 'volc.seedasr.sauc.duration',
          accessKey: KeyInfo(status: KeyPlacement.unset),
        ),
        tencent: AsrTencent(
          appId: null,
          secretId: KeyInfo(status: KeyPlacement.unset),
          secretKey: KeyInfo(status: KeyPlacement.unset),
        ),
        azure: AsrAzure(region: null, endpointId: null),
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // Clearing the workspace field saves None (the field's reset). The
    // ASR card starts below the fold; scroll it into view first.
    await tester.ensureVisible(
      find.byKey(const Key('settings-conn-asr-workspace')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-conn-asr-workspace')),
      '',
    );
    await tester.ensureVisible(find.byKey(const Key('settings-conn-asr-save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-asr-save')));
    await tester.pump();

    final save = store.asrSaves.single;
    expect(save.provider, 'aliyun');
    expect(save.aliyun.workspaceId, isNull);
    expect(save.aliyun.region, 'cn-beijing');
    expect(save.apiKey, isA<ApiKeyKeep>());
  });

  testWidgets(
    'the asr provider chip switches sub-fields and prefills the model',
    (tester) async {
      final store = FakeConnectionStore();
      await pumpSettings(
        tester,
        connectionStore: store,
        domain: SettingsDomain.connection,
      );

      // aliyun paints its own sub-section only.
      await tester.ensureVisible(
        find.byKey(const Key('settings-conn-asr-workspace')),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('settings-conn-asr-volc-appid')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('settings-conn-asr-unadapted')),
        findsNothing,
      );

      // Switching to volcengine repaints the sub-fields and prefills the
      // model (the field holds aliyun's default, a preset value).
      await tester.ensureVisible(
        find.byKey(const Key('settings-conn-asr-providers:volcengine')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('settings-conn-asr-providers:volcengine')),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('settings-conn-asr-workspace')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('settings-conn-asr-volc-appid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings-conn-asr-volc-resource')),
        findsOneWidget,
      );
      expect(
        fieldText(tester, const Key('settings-conn-asr-model')),
        'volc.seedasr.sauc.duration',
      );
      // The volcengine access token is its own diff-echo block; the common
      // api_key block is gone (volcengine keeps credentials in its
      // sub-section).
      expect(
        find.byKey(const Key('settings-conn-asr-volc-key')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings-conn-asr-key')), findsNothing);

      // A customized model survives a provider switch.
      await tester.enterText(
        find.byKey(const Key('settings-conn-asr-model')),
        'my-own-engine',
      );
      await tester.ensureVisible(
        find.byKey(const Key('settings-conn-asr-providers:tencent')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('settings-conn-asr-providers:tencent')),
      );
      await tester.pump();
      expect(
        fieldText(tester, const Key('settings-conn-asr-model')),
        'my-own-engine',
      );
      // Tencent is adapted: no unadapted caption, the sub-section's
      // own fields, and the direct-connection hint ride instead.
      expect(
        find.byKey(const Key('settings-conn-asr-unadapted')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('settings-conn-asr-tencent-appid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings-conn-asr-tencent-id-key')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings-conn-asr-tencent-key-key')),
        findsOneWidget,
      );
      // The 6001 direct-connect hint is retired (copy.md conn-43).
      expect(
        find.byKey(const Key('settings-conn-asr-tencent-direct')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'a volcengine save carries its sub-section and keeps the others',
    (tester) async {
      final store = FakeConnectionStore();
      await pumpSettings(
        tester,
        connectionStore: store,
        domain: SettingsDomain.connection,
      );

      await tester.ensureVisible(
        find.byKey(const Key('settings-conn-asr-providers:volcengine')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('settings-conn-asr-providers:volcengine')),
      );
      await tester.pump();

      // Fill the volcengine triple; the access token is a Set.
      await tester.enterText(
        find.byKey(const Key('settings-conn-asr-volc-appid')),
        '42',
      );
      await tester.enterText(
        find.byKey(const Key('settings-conn-asr-volc-key')),
        'volc-token',
      );
      await tester.ensureVisible(
        find.byKey(const Key('settings-conn-asr-save')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-conn-asr-save')));
      await tester.pump();

      final save = store.asrSaves.single;
      expect(save.provider, 'volcengine');
      expect(save.volcengine.appId, '42');
      expect(save.volcengine.resourceId, 'volc.seedasr.sauc.duration');
      expect(save.volcengine.accessKey, isA<ApiKeySet>());
      expect((save.volcengine.accessKey as ApiKeySet).key, 'volc-token');
      // The hidden vendors' fields ride along untouched (aliyun's region,
      // the cleared workspace id from the default view).
      expect(save.aliyun.region, 'cn-beijing');
      expect(save.aliyun.workspaceId, isNull);
      expect(save.apiKey, isA<ApiKeyKeep>());
      // The re-read view echoes the new access token back, masked.
      expect(
        fieldText(tester, const Key('settings-conn-asr-volc-key')),
        'volc-token',
      );
      expect(
        find.byKey(const Key('settings-conn-key-status:asr-volc')),
        findsNothing,
      );
    },
  );

  testWidgets('a tencent save carries its triple; no direct hint', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    await tester.ensureVisible(
      find.byKey(const Key('settings-conn-asr-providers:tencent')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('settings-conn-asr-providers:tencent')),
    );
    await tester.pump();

    // The chip prefills the engine (the field held aliyun's default).
    expect(
      fieldText(tester, const Key('settings-conn-asr-model')),
      '16k_zh_en',
    );
    // The 6001 direct-connect hint is retired (copy.md conn-43).
    expect(
      find.byKey(const Key('settings-conn-asr-tencent-direct')),
      findsNothing,
    );

    // Fill the triple; both account credentials are Sets.
    await tester.enterText(
      find.byKey(const Key('settings-conn-asr-tencent-appid')),
      '1250012548',
    );
    await tester.enterText(
      find.byKey(const Key('settings-conn-asr-tencent-id-key')),
      'AKIDz',
    );
    await tester.enterText(
      find.byKey(const Key('settings-conn-asr-tencent-key-key')),
      'signing-secret',
    );
    await tester.ensureVisible(find.byKey(const Key('settings-conn-asr-save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-asr-save')));
    await tester.pump();

    final save = store.asrSaves.single;
    expect(save.provider, 'tencent');
    expect(save.model, '16k_zh_en');
    expect(save.tencent.appId, '1250012548');
    expect(save.tencent.secretId, isA<ApiKeySet>());
    expect((save.tencent.secretId as ApiKeySet).key, 'AKIDz');
    expect(save.tencent.secretKey, isA<ApiKeySet>());
    expect((save.tencent.secretKey as ApiKeySet).key, 'signing-secret');
    // The Bearer-family key never paints for tencent — it rides as Keep.
    expect(save.apiKey, isA<ApiKeyKeep>());

    // The re-read view echoes both secrets back, masked.
    expect(
      fieldText(tester, const Key('settings-conn-asr-tencent-id-key')),
      'AKIDz',
    );
    expect(
      fieldText(tester, const Key('settings-conn-asr-tencent-key-key')),
      'signing-secret',
    );
  });

  testWidgets('the tencent endpoint preview follows the typed app id', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    await tester.ensureVisible(
      find.byKey(const Key('settings-conn-asr-providers:tencent')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('settings-conn-asr-providers:tencent')),
    );
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('settings-conn-asr-tencent-appid')),
    );
    await tester.pump();

    // No app id yet: the path sits open after the v2 prefix.
    expect(
      find.textContaining('当前端点：wss://asr.cloud.tencent.com/asr/v2/'),
      findsOneWidget,
    );

    // Typing the app id repaints immediately — no save.
    await tester.enterText(
      find.byKey(const Key('settings-conn-asr-tencent-appid')),
      '1250012548',
    );
    await tester.pump();
    expect(
      find.textContaining('当前端点：wss://asr.cloud.tencent.com/asr/v2/1250012548'),
      findsOneWidget,
    );
    expect(store.asrSaves, isEmpty);
  });

  testWidgets('the stored common asr key echoes; an untouched save keeps it', (
    tester,
  ) async {
    // The A-round regression: the common key never echoed into the
    // field, so every Bearer-family save diffed an empty field against
    // the stored key, offered the clear confirm, and one confirmed
    // save wiped the key from the local file.
    final store = FakeConnectionStore(
      asr: const AsrConnection(
        provider: 'aliyun',
        model: 'qwen3-asr-flash-realtime',
        language: 'zh',
        baseUrl: null,
        endpoint: 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime',
        key: KeyInfo(
          status: KeyPlacement.inLocalFile,
          storedKey: 'sk-asr-stored',
        ),
        aliyun: AsrAliyun(workspaceId: null, region: 'cn-beijing'),
        volcengine: AsrVolcengine(
          appId: null,
          resourceId: 'volc.seedasr.sauc.duration',
          accessKey: KeyInfo(status: KeyPlacement.unset),
        ),
        tencent: AsrTencent(
          appId: null,
          secretId: KeyInfo(status: KeyPlacement.unset),
          secretKey: KeyInfo(status: KeyPlacement.unset),
        ),
        azure: AsrAzure(region: null, endpointId: null),
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // The stored local-file key echoes into the field, masked.
    expect(
      fieldText(tester, const Key('settings-conn-asr-key')),
      'sk-asr-stored',
    );

    // Saving without touching the field is a Keep — never a spurious
    // clear confirm against the stored key.
    await tester.ensureVisible(find.byKey(const Key('settings-conn-asr-save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-asr-save')));
    await tester.pump();
    final save = store.asrSaves.single;
    expect(save.apiKey, isA<ApiKeyKeep>());
    expect(
      fieldText(tester, const Key('settings-conn-asr-key')),
      'sk-asr-stored',
    );
  });

  testWidgets('each save hands the files to the live engine afterwards', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // An untouched LLM save adopts the saved files at once (ADR-0010):
    // the next session opens with them, no restart.
    await tester.ensureVisible(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();
    expect(store.applyCalls, 1);
    // The save note is the window toast now — a top-center overlay, no
    // scrolling back to reach it.
    expect(textOf(tester, const Key('sr-toast')), '已保存');
    expect(find.byKey(const Key('settings-conn-error')), findsNothing);

    // Same for the ASR card, one adoption per save.
    await tester.ensureVisible(find.byKey(const Key('settings-conn-asr-save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-asr-save')));
    await tester.pump();
    expect(store.applyCalls, 2);
    expect(textOf(tester, const Key('sr-toast')), '已保存');
  });

  testWidgets(
    'a refused adoption keeps the save and flags the engine kept the old providers',
    (tester) async {
      final store = FakeConnectionStore()..failNextApply = 'no adapter yet';
      await pumpSettings(
        tester,
        connectionStore: store,
        domain: SettingsDomain.connection,
      );

      await tester.ensureVisible(
        find.byKey(const Key('settings-conn-asr-save')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-conn-asr-save')));
      await tester.pump();

      // The file is saved and its note painted; the refusal is visible
      // without masquerading as a save failure — the previous providers
      // keep running (ADR-0010's failure-keeps-old).
      expect(store.asrSaves, hasLength(1));
      // Saved-but-not-adopted is the same 「已保存」 in the error tone;
      // the refusal's raw text goes to the log, never the screen.
      expect(textOf(tester, const Key('sr-toast')), '已保存');
      expect(find.textContaining('沿用上一配置'), findsNothing);
      expect(find.textContaining('no adapter yet'), findsNothing);
    },
  );

  testWidgets('the endpoint preview recomputes live, never only on save', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // The load paints the default aliyun URL.
    expect(
      find.textContaining(
        '当前端点：wss://dashscope.aliyuncs.com/api-ws/v1/realtime',
      ),
      findsOneWidget,
    );

    // Typing a base_url override repaints immediately — no save.
    await tester.enterText(
      find.byKey(const Key('settings-conn-asr-baseurl')),
      'wss://proxy.example.com',
    );
    await tester.pump();
    expect(
      find.textContaining(
        '当前端点：wss://proxy.example.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime',
      ),
      findsOneWidget,
    );

    // A provider chip click repaints without a save too — and the
    // base_url override is a common field, so it follows the switch.
    await tester.ensureVisible(
      find.byKey(const Key('settings-conn-asr-providers:volcengine')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('settings-conn-asr-providers:volcengine')),
    );
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('settings-conn-asr-endpoint')),
    );
    await tester.pump();
    expect(
      find.textContaining('当前端点：wss://proxy.example.com/api/v3/sauc/bigmodel'),
      findsOneWidget,
    );
    expect(store.asrSaves, isEmpty); // nothing was saved along the way
  });

  testWidgets('a failed save surfaces the error and keeps the form', (
    tester,
  ) async {
    final store = FakeConnectionStore()..failNextSave = StateError('locked');
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();
    expect(textOf(tester, const Key('sr-toast')), '保存失败');
    expect(find.textContaining('locked'), findsNothing);
    // The form keeps what the user typed; nothing was adopted.
    expect(
      fieldText(tester, const Key('settings-conn-llm-model')),
      'deepseek-flash',
    );
  });

  // -----------------------------------------------------------------------
  // The advanced domain (高级) — editable form, ADR-0007 revised
  // -----------------------------------------------------------------------

  testWidgets('the timings paint as an editable form; a passage switch', (
    tester,
  ) async {
    final store = FakeSystemStore();
    await pumpSettings(
      tester,
      systemStore: store,
      domain: SettingsDomain.advanced,
    );

    // The switch seeds from the file's truth (true by the fake's
    // default), alongside the loaded field values.
    Switch passageSwitch() =>
        tester.widget(find.byKey(const Key('settings-advanced-passage')));
    expect(passageSwitch().value, isTrue);
    expect(
      fieldText(tester, const Key('settings-advanced-paragraph-silence')),
      '1200',
    );
    expect(fieldText(tester, const Key('settings-advanced-typing-delay')), '8');
    // The insertion mode is a chip pair, not free text.
    expect(
      find.byKey(const Key('settings-advanced-insertion-mode:paste')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const Key('settings-advanced-open-config')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-advanced-open-config')));
    await tester.pump();
    expect(store.openConfigCalls, 1);
  });

  testWidgets('an engine save records the form; the note says next session', (
    tester,
  ) async {
    final store = FakeSystemStore();
    await pumpSettings(
      tester,
      systemStore: store,
      domain: SettingsDomain.advanced,
    );

    await tester.tap(find.byKey(const Key('settings-advanced-passage')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-advanced-paragraph-silence')),
      '1500',
    );
    await tester.enterText(
      find.byKey(const Key('settings-advanced-session-end-silence')),
      '2500',
    );
    await tester.tap(find.byKey(const Key('settings-advanced-engine-save')));
    await tester.pump();

    final save = store.engineSaves.single;
    expect(save.passage, isFalse); // the flipped switch rides the save
    expect(save.paragraph, 1500);
    expect(save.sessionEnd, 2500);
    expect(save.timeout, 25000); // untouched field rides
    expect(textOf(tester, const Key('sr-toast')), '已保存');
    expect(store.insertionSaves, isEmpty); // one card, one save
  });

  testWidgets('an insertion save records mode and pacing; instant note', (
    tester,
  ) async {
    final store = FakeSystemStore();
    await pumpSettings(
      tester,
      systemStore: store,
      domain: SettingsDomain.advanced,
    );

    await tester.tap(
      find.byKey(const Key('settings-advanced-insertion-mode:typing')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-advanced-typing-delay')),
      '15',
    );
    await tester.tap(find.byKey(const Key('settings-advanced-insertion-save')));
    await tester.pump();

    final save = store.insertionSaves.single;
    expect(save.mode, 'typing');
    expect(save.typing, 15);
    expect(save.focus, 50); // untouched fields ride
    expect(textOf(tester, const Key('sr-toast')), '已保存');
    expect(store.engineSaves, isEmpty);
  });

  testWidgets('a non-numeric field refuses the save with a visible error', (
    tester,
  ) async {
    final store = FakeSystemStore();
    await pumpSettings(
      tester,
      systemStore: store,
      domain: SettingsDomain.advanced,
    );

    await tester.enterText(
      find.byKey(const Key('settings-advanced-rectify-timeout')),
      'soon',
    );
    await tester.tap(find.byKey(const Key('settings-advanced-engine-save')));
    await tester.pump();
    expect(textOf(tester, const Key('sr-toast')), '格式不正确');
    expect(store.engineSaves, isEmpty);
  });

  // -----------------------------------------------------------------------
  // The about domain (关于)
  // -----------------------------------------------------------------------

  testWidgets(
    'about paints version and license; open-config rides the same seam',
    (tester) async {
      final store = FakeSystemStore();
      await pumpSettings(
        tester,
        systemStore: store,
        domain: SettingsDomain.about,
      );

      expect(find.byKey(const Key('settings-about-version')), findsOneWidget);
      expect(find.text('v1.0.0'), findsOneWidget);
      expect(find.text('Apache-2.0'), findsOneWidget);
      expect(find.text('随开源发布公布'), findsOneWidget);

      // The tray entry's own bridge call, same source.
      await tester.tap(find.byKey(const Key('settings-about-open-config')));
      await tester.pump();
      expect(store.openConfigCalls, 1);
    },
  );

  // -----------------------------------------------------------------------
  // The editor
  // -----------------------------------------------------------------------

  testWidgets('add persists the new scenario and notifies the main window', (
    tester,
  ) async {
    final store = FakeScenarioStore(_seeded);
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, store: store, channel: channel);

    await tester.tap(find.byKey(const Key('settings-scenario-new')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-scenario-name-field')),
      '代码注释',
    );
    await tester.enterText(
      find.byKey(const Key('settings-scenario-directive-field')),
      '  技术文档:精炼陈述句  ',
    );
    await tester.tap(find.byKey(const Key('settings-scenario-save')));
    await tester.pump();

    // The card landed (appended after the seeds) and the store persisted
    // exactly that library.
    expect(
      find.byKey(const Key('settings-scenario-card:代码注释')),
      findsOneWidget,
    );
    expect(store.saves.single.last.name, '代码注释');
    // Trailing whitespace is normalized away (the loader's rule).
    expect(store.saves.single.last.directive, '技术文档:精炼陈述句');
    expect(channel.libraryChanged, [(from: null, to: null)]);
  });

  testWidgets('the dialog refuses blank fields and duplicate names', (
    tester,
  ) async {
    final store = FakeScenarioStore(_seeded);
    await pumpSettings(tester, store: store);

    await tester.tap(find.byKey(const Key('settings-scenario-new')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-scenario-name-field')),
      '论文',
    );
    await tester.enterText(
      find.byKey(const Key('settings-scenario-directive-field')),
      '同名即重复',
    );
    await tester.tap(find.byKey(const Key('settings-scenario-save')));
    await tester.pump();
    expect(
      find.byKey(const Key('settings-scenario-form-error')),
      findsOneWidget,
    );
    expect(find.text('已存在同名场景'), findsOneWidget);

    // Blank directive is refused too, and nothing was written.
    await tester.enterText(
      find.byKey(const Key('settings-scenario-directive-field')),
      '   ',
    );
    await tester.tap(find.byKey(const Key('settings-scenario-save')));
    await tester.pump();
    expect(find.text('名称与风格指令都不能为空'), findsOneWidget);
    expect(store.saves, isEmpty);

    // Cancel leaves the library untouched.
    await tester.tap(find.byKey(const Key('settings-scenario-cancel')));
    await tester.pump();
    expect(store.saves, isEmpty);
    expect(find.byKey(const Key('settings-scenario-card:论文')), findsOneWidget);
  });

  testWidgets('edit renames in place and reports the rename', (tester) async {
    final store = FakeScenarioStore(_seeded);
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, store: store, channel: channel);

    await hoverCardAction(tester, '聊天', Icons.edit_outlined);
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-scenario-name-field')),
      '闲聊',
    );
    await tester.tap(find.byKey(const Key('settings-scenario-save')));
    await tester.pump();

    // Position preserved: the renamed entry still sits second.
    expect(find.byKey(const Key('settings-scenario-card:聊天')), findsNothing);
    expect(find.byKey(const Key('settings-scenario-card:闲聊')), findsOneWidget);
    expect(store.saves.single[1].name, '闲聊');
    expect(channel.libraryChanged, [(from: '聊天', to: '闲聊')]);
  });

  testWidgets('delete removes the card and resets a selection sitting on it', (
    tester,
  ) async {
    final store = FakeScenarioStore(_seeded);
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, store: store, channel: channel, selected: '论文');

    await hoverCardAction(tester, '论文', Icons.delete_outline_rounded);
    await tester.pump();

    expect(find.byKey(const Key('settings-scenario-card:论文')), findsNothing);
    expect(store.saves.single.map((s) => s.name), ['聊天']);
    expect(channel.selections, [null]); // back to the default register
  });

  testWidgets('a failed save keeps the library and surfaces the error', (
    tester,
  ) async {
    final store = FakeScenarioStore(_seeded)..failNextSave = StateError('disk');
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, store: store, channel: channel);

    await hoverCardAction(tester, '聊天', Icons.delete_outline_rounded);
    await tester.pump();

    // The card survives (the file refused the write), the error shows.
    expect(find.byKey(const Key('settings-scenario-card:聊天')), findsOneWidget);
    expect(textOf(tester, const Key('sr-toast')), '保存失败');
    expect(channel.libraryChanged, isEmpty);
  });

  // -----------------------------------------------------------------------
  // The global directive's inline card (ticket 22)
  // -----------------------------------------------------------------------

  testWidgets(
    'the global card saves on demand only, trimmed, and notifies the window',
    (tester) async {
      final store = FakeGlobalDirectiveStore('全部输出用简体中文书写');
      final channel = FakeSettingsChannel();
      await pumpSettings(tester, globalStore: store, channel: channel);

      // The card is resident at the top of the pane, seeded from the file.
      expect(find.byKey(const Key('settings-global-card')), findsOneWidget);
      expect(globalFieldText(tester), '全部输出用简体中文书写');

      // No change, no save: the explicit button is the only write path.
      await tester.tap(find.byKey(const Key('settings-global-save')));
      await tester.pump();
      expect(store.saves, isEmpty);
      expect(channel.globalChanged, 0);

      // An edit saves the trimmed text and tells the main window.
      await tester.enterText(
        find.byKey(const Key('settings-global-field')),
        '  语气克制,不用流行语  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-global-save')));
      await tester.pump();
      expect(store.saves, ['语气克制,不用流行语']);
      expect(channel.globalChanged, 1);

      // The save reset the baseline: a re-tap without edits writes nothing.
      await tester.tap(find.byKey(const Key('settings-global-save')));
      await tester.pump();
      expect(store.saves, ['语气克制,不用流行语']);
      expect(channel.globalChanged, 1);
    },
  );

  testWidgets('saving blank text unsets the directive', (tester) async {
    final store = FakeGlobalDirectiveStore('旧的全局指令');
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, globalStore: store, channel: channel);

    // Clearing the field and saving is the off switch — no separate
    // clear action, no refusal for empty text.
    await tester.enterText(
      find.byKey(const Key('settings-global-field')),
      '   ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-global-save')));
    await tester.pump();
    expect(store.saves, [null]);
    expect(store.directive, isNull);
    expect(channel.globalChanged, 1);
  });

  testWidgets('a failed global save surfaces the error and keeps the file', (
    tester,
  ) async {
    final store = FakeGlobalDirectiveStore('旧的全局指令')
      ..failNextSave = StateError('disk');
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, globalStore: store, channel: channel);

    await tester.enterText(
      find.byKey(const Key('settings-global-field')),
      '新的全局指令',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-global-save')));
    await tester.pump();

    // The file refused the write: the error shows, no event went out, and
    // the card keeps the unsaved text for a retry.
    expect(textOf(tester, const Key('sr-toast')), '保存失败');
    expect(channel.globalChanged, 0);
    expect(store.directive, '旧的全局指令');
    expect(globalFieldText(tester), '新的全局指令');
  });

  testWidgets('the global card stays with an empty library', (tester) async {
    await pumpSettings(
      tester,
      store: FakeScenarioStore(),
      globalStore: FakeGlobalDirectiveStore('恒常生效的指令'),
    );

    // Empty library or not, the card is resident above the empty state.
    expect(find.byKey(const Key('settings-global-card')), findsOneWidget);
    expect(find.byKey(const Key('settings-scenario-empty')), findsOneWidget);
  });

  // -----------------------------------------------------------------------
  // The fourth picker
  // -----------------------------------------------------------------------

  testWidgets(
    'tapping a card selects it; tapping it again returns to default',
    (tester) async {
      final channel = FakeSettingsChannel();
      await pumpSettings(tester, channel: channel);

      await tester.tap(find.byKey(const Key('settings-scenario-card:论文')));
      await tester.pump();
      expect(channel.selections, ['论文']);

      // The selected card paints its leading check.
      final card = find.byKey(const Key('settings-scenario-card:论文'));
      expect(
        find.descendant(
          of: card,
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('settings-scenario-card:论文')));
      await tester.pump();
      expect(channel.selections, ['论文', null]);
    },
  );

  testWidgets('the initial selection paints; inbound pushes repaint both', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, channel: channel, selected: '聊天');
    final card = find.byKey(const Key('settings-scenario-card:聊天'));
    expect(
      find.descendant(
        of: card,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );

    // The main window's pickers changed the selection: the push repaints.
    channel.selectionHandler?.call('论文');
    await tester.pump();
    final newCard = find.byKey(const Key('settings-scenario-card:论文'));
    expect(
      find.descendant(
        of: newCard,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );

    // Theme follow: the app repaints under the pushed mode.
    channel.themeHandler?.call(ThemeMode.dark);
    await tester.pump();
    expect(
      (tester.widget(find.byType(MaterialApp)) as MaterialApp).themeMode,
      ThemeMode.dark,
    );
  });

  // D16 regression: the scaffold background and the divider resolved
  // their palette with the state's own context (above MaterialApp, where
  // Theme.of silently falls back to the light fallback theme), so dark
  // mode left the window chrome light while the cards went dark.
  testWidgets(
    'a theme switch repaints the scaffold chrome, not just the cards',
    (tester) async {
      final channel = FakeSettingsChannel();
      await pumpSettings(tester, channel: channel);

      Scaffold scaffold() => tester.widget(find.byType(Scaffold));
      VerticalDivider divider() => tester.widget(find.byType(VerticalDivider));

      // Light start (the test platform brightness is light).
      expect(scaffold().backgroundColor, SrPalette.light.surface);
      expect(divider().color, SrPalette.light.hairline);

      channel.themeHandler?.call(ThemeMode.dark);
      // MaterialApp morphs between themes (AnimatedTheme): the chrome only
      // lands on the dark palette once the transition has run.
      await tester.pumpAndSettle();
      expect(scaffold().backgroundColor, SrPalette.dark.surface);
      expect(divider().color, SrPalette.dark.hairline);
    },
  );

  // The OS caption (title bar) follows the same theme tri-state: seeded
  // at startup, re-applied on every push, and re-applied when the system
  // brightness flips under 跟随 mode.
  testWidgets('the caption theme follows the effective brightness', (
    tester,
  ) async {
    final applied = <Brightness>[];
    final channel = FakeSettingsChannel();
    await pumpSettings(
      tester,
      channel: channel,
      initialTheme: ThemeMode.dark,
      captionTheme: applied.add,
    );
    expect(applied, [Brightness.dark]);

    channel.themeHandler?.call(ThemeMode.light);
    await tester.pump();
    expect(applied.last, Brightness.light);

    // System mode hands the decision to the platform brightness.
    channel.themeHandler?.call(ThemeMode.system);
    await tester.pump();
    expect(applied.last, Brightness.light); // test platform starts light
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(applied.last, Brightness.dark);
  });

  testWidgets('an edit keeps a selection it renames', (tester) async {
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, channel: channel, selected: '聊天');

    await hoverCardAction(tester, '聊天', Icons.edit_outlined);
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('settings-scenario-name-field')),
      '闲聊',
    );
    await tester.tap(find.byKey(const Key('settings-scenario-save')));
    await tester.pump();

    final card = find.byKey(const Key('settings-scenario-card:闲聊'));
    expect(
      find.descendant(
        of: card,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
  });

  // -----------------------------------------------------------------------
  // The main-window controller's library-change reactions (the sync the
  // tray, the quick panel and the session chip all paint from)
  // -----------------------------------------------------------------------

  test('a settings edit reloads the library and repaints', () async {
    final gateway = FakeGateway()..scenarioLibrary.addAll(_seeded);
    final controller = SpeechController(gateway: gateway);
    await controller.loadScenarios();
    expect(controller.scenarios.length, 2);

    gateway.scenarioLibrary.add(
      const BridgeScenario(name: '代码注释', directive: '技术文档'),
    );
    await controller.onScenariosLibraryChanged();
    expect(controller.scenarios.length, 3);
    // An untouched selection stays.
    expect(controller.selectedScenario, isNull);
    controller.dispose();
  });

  test('a rename the selection sits on carries it across', () async {
    final gateway = FakeGateway()..scenarioLibrary.addAll(_seeded);
    final controller = SpeechController(gateway: gateway);
    await controller.loadScenarios();
    await controller.selectScenario('聊天');

    gateway.scenarioLibrary
      ..clear()
      ..addAll(_seeded)
      ..[1] = const BridgeScenario(name: '闲聊', directive: '轻松自然:保留语气');
    await controller.onScenariosLibraryChanged(
      renamedFrom: '聊天',
      renamedTo: '闲聊',
    );

    expect(controller.selectedScenario, '闲聊');
    // The engine adopted the renamed entry's directive text.
    expect(gateway.commands, contains('setStyleDirective:轻松自然:保留语气'));
    controller.dispose();
  });

  test(
    'a selection whose entry vanished falls back to the default register',
    () async {
      final gateway = FakeGateway()..scenarioLibrary.addAll(_seeded);
      final controller = SpeechController(gateway: gateway);
      await controller.loadScenarios();
      await controller.selectScenario('论文');

      gateway.scenarioLibrary.removeAt(0);
      await controller.onScenariosLibraryChanged();

      expect(controller.selectedScenario, isNull);
      expect(gateway.commands, contains('setStyleDirective:null'));
      controller.dispose();
    },
  );

  test('an unreadable library keeps the last painted one', () async {
    final gateway = FakeGateway()..scenarioLibrary.addAll(_seeded);
    final controller = SpeechController(gateway: gateway);
    await controller.loadScenarios();

    gateway.failNextScenarios = StateError('locked');
    await controller.onScenariosLibraryChanged();
    expect(controller.scenarios.length, 2);
    controller.dispose();
  });
}
