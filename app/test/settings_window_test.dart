/// Widget tests for the settings window: the seven-domain shell, the
/// scenario library editor (add/edit/delete/select through one dialog),
/// the fidelity-eval domain (run states through the controller), the
/// history domain (browse/retrieve/retention/keep-nothing/clear), the
/// terms domain (add/rename/remove over the same dictionary file), the
/// connection domain (the two endpoint forms, preset chips, the
/// diff-echo key block), the advanced domain (the editable timing form
/// + the file escape hatch), the
/// about domain (version/license/open-config), the cross-window channel
/// contract, and the main-window controller's library-change reactions.
/// Everything rides pure-Dart fakes — no Rust dylib, no second engine.

library;

import 'dart:async' show StreamController;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart'
    show SrMotion, SrPalette;
import 'package:spokenrectifier_app/src/rust/api.dart'
    show
        BridgeEvalCategory,
        BridgeEvalEvent,
        BridgeEvalSummary,
        BridgeHistoryEntry,
        BridgeScenario;
import 'package:spokenrectifier_app/src/settings/connection_store.dart';
import 'package:spokenrectifier_app/src/settings/fidelity_eval.dart';
import 'package:spokenrectifier_app/src/settings/history_store.dart';
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

/// The connection domain's fake: the two views in memory; a save
/// records the ask and returns it as the re-read truth.
class FakeConnectionStore implements ConnectionStore {
  FakeConnectionStore({AsrConnection? asr, LlmConnection? llm})
    : asr = asr ?? _defaultAsr,
      llm =
          llm ??
          const LlmConnection(
            vendor: 'deepseek',
            baseUrl: 'https://api.deepseek.com',
            model: 'deepseek-v4-flash',
            key: KeyInfo(status: KeyPlacement.unset),
          );

  static const _defaultAsr = AsrConnection(
    provider: 'aliyun',
    model: 'qwen3-asr-flash-realtime',
    language: 'zh',
    baseUrl: null,
    endpoint:
        'wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime',
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

  final llmSaves =
      <({String vendor, String baseUrl, String model, ApiKeyEdit key})>[];
  final asrSaves = <AsrEdit>[];

  /// When set, the next save throws (an unwritable layer file).
  Object? failNextSave;

  @override
  Future<({AsrConnection asr, LlmConnection llm})> load() async =>
      (asr: asr, llm: llm);

  @override
  Future<LlmConnection> saveLlm({
    required String vendor,
    required String baseUrl,
    required String model,
    required ApiKeyEdit apiKey,
  }) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    llmSaves.add((vendor: vendor, baseUrl: baseUrl, model: model, key: apiKey));
    llm = LlmConnection(
      vendor: vendor,
      baseUrl: baseUrl,
      model: model,
      key: switch (apiKey) {
        ApiKeySet(:final key) => KeyInfo(
          status: KeyPlacement.inLocalFile,
          storedKey: key,
        ),
        ApiKeyClear() => const KeyInfo(status: KeyPlacement.unset),
        ApiKeyKeep() => llm.key,
      },
    );
    return llm;
  }

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
      endpoint: 'wss://resolved.example/…?model=${edit.model}',
      key: resolved(edit.apiKey, asr.key),
      aliyun: AsrAliyun(
        workspaceId: edit.aliyun.workspaceId,
        region: edit.aliyun.region,
      ),
      volcengine: AsrVolcengine(
        appId: edit.volcengine.appId,
        resourceId: edit.volcengine.resourceId,
        accessKey: resolved(edit.volcengine.accessKey, asr.volcengine.accessKey),
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
  final insertionSaves =
      <({String mode, int focus, int paste, int typing})>[];

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
  int historyChanged = 0;
  final rerectifies = <String>[];
  int termsChanged = 0;

  void Function(ThemeMode mode)? themeHandler;
  void Function(String? name)? selectionHandler;
  void Function(SettingsDomain domain)? navigateHandler;
  bool attached = false;

  @override
  set onTheme(void Function(ThemeMode mode) handler) => themeHandler = handler;

  @override
  set onSelection(void Function(String? name) handler) =>
      selectionHandler = handler;

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
  Future<void> sendScenarioSelected(String? name) async => selections.add(name);

  @override
  Future<void> sendHistoryChanged() async => historyChanged++;

  @override
  Future<void> sendHistoryRerectify(String rawTranscript) async =>
      rerectifies.add(rawTranscript);

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

Future<void> pumpSettings(
  WidgetTester tester, {
  FakeScenarioStore? store,
  FakeSettingsChannel? channel,
  FakeHistorySettingsStore? historyStore,
  FakeFidelityEvalRunner? evalRunner,
  FakeTermsStore? termsStore,
  FakeConnectionStore? connectionStore,
  FakeSystemStore? systemStore,
  SettingsDomain domain = SettingsDomain.scenarios,
  ThemeMode initialTheme = ThemeMode.system,
  String? selected,
  void Function(Brightness brightness)? captionTheme,
}) async {
  await tester.pumpWidget(
    SettingsWindowApp(
      store: store ?? FakeScenarioStore(_seeded),
      channel: channel ?? FakeSettingsChannel(),
      initialDomain: domain,
      initialTheme: initialTheme,
      initialSelection: selected,
      historyStore: historyStore ?? FakeHistorySettingsStore(),
      evalRunner: evalRunner ?? FakeFidelityEvalRunner(),
      termsStore: termsStore ?? FakeTermsStore(),
      connectionStore: connectionStore ?? FakeConnectionStore(),
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

// ---------------------------------------------------------------------------
// The shell
// ---------------------------------------------------------------------------

void main() {
  test('the domain list is the seven-entry union of tickets and spec', () {
    expect(SettingsDomain.values.length, 7);
    expect(SettingsDomain.values.first, SettingsDomain.scenarios);
    expect(SettingsDomain.values.last, SettingsDomain.about);
    expect(SettingsDomain.fidelity.label, '保真评测');
  });

  testWidgets('sidebar lists every domain; all seven are real panes', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, channel: channel);

    for (final domain in SettingsDomain.values) {
      // 场景库 paints twice by design: sidebar entry + pane title.
      expect(find.text(domain.label), findsWidgets);
    }

    // Every ticket-18/19 domain paints its real content — no
    // placeholder pane survives.
    await tester.tap(find.text('保真评测'));
    await tester.pump();
    expect(find.text('开始评测'), findsOneWidget);

    await tester.tap(find.text('历史'));
    await tester.pump();
    await tester.pump(); // the config load lands (two chained awaits)
    expect(find.text('不留存'), findsOneWidget);

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
  // The fidelity-eval domain (保真评测)
  // -----------------------------------------------------------------------

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
    expect(find.text('评测需要真实 LLM 连接'), findsOneWidget);

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
    await tester.tap(find.text('场景库'));
    await tester.pump();
    await tester.tap(find.text('保真评测'));
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

    // Both texts per row (the quick panel shows raw only).
    expect(find.text('第二句的原话'), findsOneWidget);
    expect(
      find.byKey(const Key('settings-history-rectified:2')),
      findsOneWidget,
    );

    // 复制原文 lands on the clipboard, like the quick panel's rows
    // (same mock recipe: record the Clipboard.setData call).
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
      const Key('settings-history-copy:2'),
      Icons.copy_rounded,
    );
    await tester.pump();
    expect(copied, '第二句的原话');

    // 重新修正 routes to the main window (the quick panel's controller
    // path), never to a local session.
    await hoverRowAction(
      tester,
      const Key('settings-history-rerectify:1'),
      Icons.refresh_rounded,
    );
    await tester.pump();
    expect(channel.rerectifies, ['第一句的原话']);
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
    expect(find.text('开启不留存?'), findsOneWidget);
    expect(find.text('将立即清空全部 2 条既有历史,且不再记录新会话。'), findsOneWidget);

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
    expect(find.text('清空全部历史?'), findsOneWidget);

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
    expect(find.text('清空全部历史?'), findsNothing);
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
    expect(find.byKey(const Key('settings-history-error')), findsOneWidget);
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
    expect(find.byKey(const Key('settings-terms-error')), findsOneWidget);
  });

  // -----------------------------------------------------------------------
  // The connection domain (模型与连接)
  // -----------------------------------------------------------------------

  testWidgets('the two cards paint the config; a local key echoes masked', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      llm: const LlmConnection(
        vendor: 'deepseek',
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-v4-flash',
        key: KeyInfo(
          status: KeyPlacement.inLocalFile,
          storedKey: 'sk-stored',
        ),
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    // The stored local-file key echoes into the field, masked by
    // default; the eye toggles plain text (ADR-0008 revision).
    expect(
      fieldText(tester, const Key('settings-conn-llm-key')),
      'sk-stored',
    );
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
    expect(find.byKey(const Key('settings-conn-restart-note')), findsOneWidget);
  });

  testWidgets('an env key never echoes; the status line names it', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      llm: const LlmConnection(
        vendor: 'deepseek',
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-v4-flash',
        key: KeyInfo(status: KeyPlacement.fromEnv, envName: 'DEEPSEEK_API_KEY'),
      ),
    );
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    expect(fieldText(tester, const Key('settings-conn-llm-key')), isEmpty);
    expect(find.textContaining('取自环境变量 DEEPSEEK_API_KEY'), findsOneWidget);
    // The status line itself carries the ADR's 「输入即另存本机」 wording.
    expect(find.textContaining('输入即另存本机'), findsOneWidget);
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

    // The model holds deepseek's default, so the volcengine chip may
    // switch both it and the endpoint.
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

    // A customized model survives a chip click; the endpoint switches
    // unconditionally (that is the point of the click).
    await tester.enterText(
      find.byKey(const Key('settings-conn-llm-model')),
      'my-own-model',
    );
    await tester.tap(find.byKey(const Key('settings-conn-llm-vendors:qwen')));
    await tester.pump();
    expect(
      fieldText(tester, const Key('settings-conn-llm-baseurl')),
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
    );
    expect(
      fieldText(tester, const Key('settings-conn-llm-model')),
      'my-own-model',
    );
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
    expect(save.key, isA<ApiKeyKeep>()); // the echoed key, unchanged
    expect(find.byKey(const Key('settings-conn-saved')), findsOneWidget);
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
    expect(set.key, isA<ApiKeySet>());
    expect((set.key as ApiKeySet).key, 'sk-new');
    expect(find.textContaining('已保存在本机 local 文件'), findsOneWidget);
    expect(fieldText(tester, const Key('settings-conn-llm-key')), 'sk-new');

    // Emptying the echoed key and saving asks one confirm; cancelling
    // writes nothing at all.
    await tester.enterText(find.byKey(const Key('settings-conn-llm-key')), '');
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();
    expect(find.text('清除密钥?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-conn-clear-cancel')));
    await tester.pump();
    expect(store.llmSaves.length, 1);

    // Confirming saves with an explicit Clear (the field is empty again).
    await tester.tap(find.byKey(const Key('settings-conn-llm-save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-conn-clear-ok')));
    await tester.pump();
    final clear = store.llmSaves.last;
    expect(clear.key, isA<ApiKeyClear>());
    expect(fieldText(tester, const Key('settings-conn-llm-key')), isEmpty);
    expect(find.textContaining('已保存在本机 local 文件'), findsNothing);
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

  testWidgets('the asr provider chip switches sub-fields and prefills the model', (
    tester,
  ) async {
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
    expect(
      find.byKey(const Key('settings-conn-asr-volc-appid')),
      findsNothing,
    );
    expect(find.byKey(const Key('settings-conn-asr-unadapted')), findsNothing);

    // Switching to volcengine repaints the sub-fields and prefills the
    // model (the field holds aliyun's default, a preset value).
    await tester.ensureVisible(
      find.byKey(const Key('settings-conn-asr-providers:volcengine')),
    );
    await tester.tap(find.byKey(const Key('settings-conn-asr-providers:volcengine')));
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
    expect(find.byKey(const Key('settings-conn-asr-volc-key')), findsOneWidget);
    expect(find.byKey(const Key('settings-conn-asr-key')), findsNothing);

    // A customized model survives a provider switch.
    await tester.enterText(
      find.byKey(const Key('settings-conn-asr-model')),
      'my-own-engine',
    );
    await tester.ensureVisible(
      find.byKey(const Key('settings-conn-asr-providers:tencent')),
    );
    await tester.tap(find.byKey(const Key('settings-conn-asr-providers:tencent')));
    await tester.pump();
    expect(
      fieldText(tester, const Key('settings-conn-asr-model')),
      'my-own-engine',
    );
    // The unadapted caption names the gap.
    expect(find.byKey(const Key('settings-conn-asr-unadapted')), findsOneWidget);
    expect(find.byKey(const Key('settings-conn-asr-tencent-id-key')), findsOneWidget);
    expect(find.byKey(const Key('settings-conn-asr-tencent-key-key')), findsOneWidget);
  });

  testWidgets('a volcengine save carries its sub-section and keeps the others', (
    tester,
  ) async {
    final store = FakeConnectionStore();
    await pumpSettings(
      tester,
      connectionStore: store,
      domain: SettingsDomain.connection,
    );

    await tester.ensureVisible(
      find.byKey(const Key('settings-conn-asr-providers:volcengine')),
    );
    await tester.tap(find.byKey(const Key('settings-conn-asr-providers:volcengine')));
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
    await tester.ensureVisible(find.byKey(const Key('settings-conn-asr-save')));
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
    expect(find.textContaining('已保存在本机 local 文件'), findsOneWidget);
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
    expect(find.byKey(const Key('settings-conn-error')), findsOneWidget);
    // The form keeps what the user typed; nothing was adopted.
    expect(
      fieldText(tester, const Key('settings-conn-llm-model')),
      'deepseek-v4-flash',
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
    expect(
      fieldText(tester, const Key('settings-advanced-typing-delay')),
      '8',
    );
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
    expect(find.text('会话参数已保存,下一会话生效'), findsOneWidget);
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
    await tester.tap(
      find.byKey(const Key('settings-advanced-insertion-save')),
    );
    await tester.pump();

    final save = store.insertionSaves.single;
    expect(save.mode, 'typing');
    expect(save.typing, 15);
    expect(save.focus, 50); // untouched fields ride
    expect(find.text('插入参数已保存,即时生效'), findsOneWidget);
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
    expect(find.byKey(const Key('settings-advanced-error')), findsOneWidget);
    expect(find.textContaining('需为非负整数'), findsOneWidget);
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
    expect(find.text('已有同名场景'), findsOneWidget);

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
    expect(find.byKey(const Key('settings-scenario-error')), findsOneWidget);
    expect(channel.libraryChanged, isEmpty);
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
