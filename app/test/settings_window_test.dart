/// Widget tests for the settings window: the seven-domain shell, the
/// scenario library editor (add/edit/delete/select through one dialog),
/// the cross-window channel contract, and the main-window controller's
/// library-change reactions. Everything rides pure-Dart fakes — no Rust
/// dylib, no second engine.

library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart'
    show SrMotion, SrPalette;
import 'package:spokenrectifier_app/src/rust/api.dart' show BridgeScenario;
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

/// Records every outbound event; inbound pushes are invoked by the test
/// through the exposed handlers.
class FakeSettingsChannel implements SettingsChannel {
  final libraryChanged = <({String? from, String? to})>[];
  final selections = <String?>[];

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
}

const _seeded = [
  BridgeScenario(name: '论文', directive: '学术书面语:客观严谨'),
  BridgeScenario(name: '聊天', directive: '轻松自然:保留语气'),
];

Future<void> pumpSettings(
  WidgetTester tester, {
  FakeScenarioStore? store,
  FakeSettingsChannel? channel,
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

  testWidgets('sidebar lists every domain; placeholders say their ticket', (
    tester,
  ) async {
    final channel = FakeSettingsChannel();
    await pumpSettings(tester, channel: channel);

    for (final domain in SettingsDomain.values) {
      // 场景库 paints twice by design: sidebar entry + pane title.
      expect(find.text(domain.label), findsWidgets);
    }

    // Navigating to a placeholder paints its empty state.
    await tester.tap(find.text('保真评测'));
    await tester.pump();
    expect(find.text('保真评测域'), findsOneWidget);
    expect(find.text('设计稿占位 · 工单 18 填充'), findsOneWidget);

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
