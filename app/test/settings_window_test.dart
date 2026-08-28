/// Widget tests for the settings window: the seven-domain shell, the
/// scenario library editor (add/edit/delete/select through one dialog),
/// the fidelity-eval domain (run states through the controller), the
/// history domain (browse/retrieve/retention/keep-nothing/clear), the
/// cross-window channel contract, and the main-window controller's
/// library-change reactions. Everything rides pure-Dart fakes — no Rust
/// dylib, no second engine.

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
    show BridgeEvalCategory, BridgeEvalEvent, BridgeEvalSummary, BridgeHistoryEntry, BridgeScenario;
import 'package:spokenrectifier_app/src/settings/fidelity_eval.dart';
import 'package:spokenrectifier_app/src/settings/history_store.dart';
import 'package:spokenrectifier_app/src/settings/settings_channel.dart';
import 'package:spokenrectifier_app/src/settings/settings_domain.dart';
import 'package:spokenrectifier_app/src/settings/settings_store.dart';
import 'package:spokenrectifier_app/src/settings/settings_window.dart';

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

/// Records every outbound event; inbound pushes are invoked by the test
/// through the exposed handlers.
class FakeSettingsChannel implements SettingsChannel {
  final libraryChanged = <({String? from, String? to})>[];
  final selections = <String?>[];
  int historyChanged = 0;
  final rerectifies = <String>[];

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

  testWidgets('sidebar lists every domain; ticket-19 domains stay placeholders', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, channel: channel);

    for (final domain in SettingsDomain.values) {
      // 场景库 paints twice by design: sidebar entry + pane title.
      expect(find.text(domain.label), findsWidgets);
    }

    // Ticket 18's two domains are real panes now: the eval offers its
    // manual entry, the history domain paints its config card.
    await tester.tap(find.text('保真评测'));
    await tester.pump();
    expect(find.text('开始评测'), findsOneWidget);

    await tester.tap(find.text('历史'));
    await tester.pump();
    await tester.pump(); // the config load lands (two chained awaits)
    expect(find.text('不留存'), findsOneWidget);

    await tester.tap(find.text('术语'));
    await tester.pump();
    expect(find.text('术语域'), findsOneWidget);
    expect(find.text('设计稿占位 · 工单 19 填充'), findsOneWidget);

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
      const BridgeEvalEvent.caseStarted(index: 1, total: 23, id: 'correction-01'),
    );
    runner.emit(
      const BridgeEvalEvent.caseFinished(index: 1, id: 'correction-01', passed: true),
    );
    await tester.pump();
    expect(find.text('1 / 23'), findsOneWidget);
    expect(find.text('correction-01'), findsOneWidget);

    runner.emit(const BridgeEvalEvent.finished(summary: _evalSummary));
    await tester.pump();
    expect(find.byKey(const Key('settings-eval-rate')), findsOneWidget);
    expect(find.text('87.0%'), findsOneWidget);
    expect(find.text('与基线持平'), findsOneWidget);
    expect(
      find.byKey(const Key('settings-eval-category:捏造')),
      findsOneWidget,
    );
    expect(find.text('通过 20 / 23 · 执行失败 1 · 基线 87.0% · deepseek-v4-flash'), findsOneWidget);
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
    runner.emit(
      const BridgeEvalEvent.failed(message: '评测需要真实 LLM 连接'),
    );
    await tester.pump();
    expect(find.text('评测未能完成'), findsOneWidget);
    expect(find.text('评测需要真实 LLM 连接'), findsOneWidget);

    // The retry starts a fresh run.
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(runner.startCount, 2);
  });

  testWidgets('cancel stops the run; switching domains does not', (tester) async {
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
    expect(find.byKey(const Key('settings-history-rectified:2')), findsOneWidget);

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
    expect(find.byKey(const Key('settings-history-retention:30')), findsOneWidget);
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
    await pumpSettings(tester, historyStore: store, domain: SettingsDomain.history);

    await tester.tap(find.byKey(const Key('settings-history-retention:7')));
    await tester.pump();
    expect(find.byKey(const Key('settings-history-error')), findsOneWidget);
    // The rows survived.
    expect(find.text('第二句的原话'), findsOneWidget);
  });

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
