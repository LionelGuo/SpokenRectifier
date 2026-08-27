/// Widget tests for the shell: the orb-position surfaces (orb, session
/// window, quick panel placeholder) and the window choreography ride a
/// pure-Dart fake gateway and a recording stage window — no Rust dylib,
/// no platform channels.

library;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart';
import 'package:spokenrectifier_app/src/rust/api.dart'
    show BridgeEvent, BridgeScenario, BridgeSessionState;
import 'package:spokenrectifier_app/src/shell/session_flow.dart'
    show StageKind;
import 'package:spokenrectifier_app/src/shell/window_stage.dart' as stage
    show GrowthDirection, StageWindow, stageBounds;

import 'fake_gateway.dart';

/// The session field's editable core (the Key sits on the TextField).
Finder findSessionField() => find.descendant(
  of: find.byKey(const Key('session-text')),
  matching: find.byType(EditableText),
);

/// A stage window that records every bounds jump, so tests can assert
/// the choreography (one atomic setBounds per transition, anchor corner
/// pinned) without platform channels.
class RecordingStageWindow implements stage.StageWindow {
  RecordingStageWindow([this.position = const Offset(1000, 500)]);

  Offset position;
  Size size = SrGeometry.orbFootprint;
  final bounds = <Rect>[];

  /// How many times the window was asked to take the foreground.
  int focuses = 0;

  @override
  Future<Offset> getPosition() async => position;

  @override
  Future<Size> getSize() async => size;

  @override
  Future<void> setBounds(Rect bounds) async {
    this.bounds.add(bounds);
    position = bounds.topLeft;
    size = bounds.size;
  }

  @override
  Future<void> focus() async => focuses += 1;
}

Future<SpeechController> pumpController(
  WidgetTester tester,
  FakeGateway gateway, {
  ThemeMode themeMode = ThemeMode.dark,
  stage.StageWindow? stageWindow,
}) async {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
    themeMode: themeMode,
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    SpokenRectifierApp(controller: controller, stageWindow: stageWindow),
  );
  return controller;
}

Future<void> pumpToRecording(
  WidgetTester tester,
  SpeechController controller,
) async {
  await controller.startSession();
  await tester.pump(const Duration(milliseconds: 350));
}

/// Ends whatever session is running and pumps past every trailing span
/// (mic breath, collapse choreography, the 900 ms receipt flash) so the
/// test closes with zero pending timers — the test framework checks
/// invariants before teardown disposals.
Future<void> windDown(WidgetTester tester, SpeechController controller) async {
  if (controller.phase != BridgeSessionState.idle) {
    await controller.cancelSession();
  }
  await tester.pump(const Duration(milliseconds: 1200));
}

Future<void> pumpToPreview(
  WidgetTester tester,
  SpeechController controller,
  FakeGateway gateway, {
  List<String> chunks = const ['待确认文本'],
}) async {
  await pumpToRecording(tester, controller);
  await controller.stopSession();
  await tester.pump(const Duration(milliseconds: 350));
  gateway.streamRectify(chunks);
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('idle orb tap starts a session and grows the window', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final window = RecordingStageWindow();
    final controller = await pumpController(
      tester,
      gateway,
      stageWindow: window,
    );

    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic_none_rounded));
    await tester.pump(const Duration(milliseconds: 350));

    // No scripted phrases: the mic-mode engine needs no fake session armed.
    expect(gateway.commands, ['startSession']);
    expect(controller.phase, BridgeSessionState.recording);
    expect(controller.stage, StageKind.session);

    // The window jumped to the panel footprint in one atomic call,
    // pinning the bottom-right corner (upLeft growth, 96 -> 420x560).
    expect(window.bounds, [
      const Rect.fromLTRB(1000 + 96 - 420, 500 + 96 - 560, 1096, 596),
    ]);

    // The session window shows the live phase; the anchor is a stop orb.
    expect(find.text('聆听中'), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    // Expanding a panel takes the foreground: its Esc affordance is live
    // even after a hotkey start (whose focus never left the document).
    expect(window.focuses, greaterThanOrEqualTo(1));
    await windDown(tester, controller);
  });

  testWidgets('live transcript streams into the session text area', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToRecording(tester, controller);

    gateway.emit(const BridgeEvent.liveTranscriptUpdated(text: '你好\n世界'));
    await tester.pump();
    expect(find.text('你好\n世界'), findsOneWidget);
    await windDown(tester, controller);
  });

  testWidgets('speech activity breathes the mic level while recording', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToRecording(tester, controller);
    expect(controller.speaking, isFalse);

    gateway.emit(const BridgeEvent.speechActivityChanged(speaking: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.speaking, isTrue);
    // The synthesized loudness rose off its silent floor.
    expect(controller.micLevel, greaterThan(0.2));

    gateway.emit(const BridgeEvent.speechActivityChanged(speaking: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.speaking, isFalse);
    expect(controller.micLevel, lessThan(0.15));
    await windDown(tester, controller);
  });

  testWidgets('a failed start surfaces the error on the orb and stays idle', (
    tester,
  ) async {
    final gateway = FakeGateway()
      ..failNextStart = Exception('no default input device');
    final controller = await pumpController(tester, gateway);

    await controller.startSession();
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.phase, BridgeSessionState.idle);
    expect(controller.lastError, contains('no default input device'));
    // No panel is open; the resting orb carries the failure on its
    // tooltip until the next interaction.
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').contains('no default input'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a new session resets the speaking flag', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    gateway.emit(const BridgeEvent.speechActivityChanged(speaking: true));
    await tester.pump();
    expect(controller.speaking, isTrue);

    await controller.cancelSession();
    await tester.pump(const Duration(milliseconds: 350));
    await controller.startSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.speaking, isFalse);
    await windDown(tester, controller);
  });

  testWidgets('engine errors surface on the open session panel', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToRecording(tester, controller);

    gateway.emit(const BridgeEvent.error(message: '修正失败:没有 API key'));
    await tester.pump();
    expect(find.byKey(const Key('session-error')), findsOneWidget);
    expect(find.textContaining('没有 API key'), findsOneWidget);
    await windDown(tester, controller);
  });

  testWidgets('stop streams chunks into preview, Enter confirms, back to orb', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final window = RecordingStageWindow();
    final controller = await pumpController(
      tester,
      gateway,
      stageWindow: window,
    );

    await pumpToPreview(tester, controller, gateway,
        chunks: ['修正', '后的文本']);

    // The session field holds the joined chunks, editable in preview.
    final field = tester.widget<EditableText>(findSessionField());
    expect(field.controller.text, '修正后的文本');
    expect(field.readOnly, isFalse);
    // Preview entry re-guarantees the keyboard after the expand focus.
    expect(window.focuses, greaterThanOrEqualTo(2));

    // Enter (the field holds focus in preview; chat-input semantics)
    // confirms what is on screen.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.commands, contains('confirmInsert'));
    expect(controller.phase, BridgeSessionState.idle);

    // Collapse: after the exit animation the window shrank back to the
    // orb footprint at the same pinned corner.
    expect(window.bounds.last, const Rect.fromLTRB(1000, 500, 1096, 596));
    expect(window.bounds.last.size, SrGeometry.orbFootprint);
    await windDown(tester, controller);
  });

  testWidgets('the receipt flash shows on the orb, then rests', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway);

    await controller.confirmWhatYouSee();
    await tester.pump(const Duration(milliseconds: 350));

    // Inserted: green check flash while the window is already collapsing.
    expect(controller.orbFlash, OrbFlash.inserted);

    // After the token feedback span the ball rests back to idle.
    await tester.pump(const Duration(milliseconds: 900));
    expect(controller.orbFlash, OrbFlash.none);
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
  });

  testWidgets('Esc cancels from preview', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.commands, contains('cancelSession'));
    expect(controller.phase, BridgeSessionState.idle);
    expect(controller.orbFlash, OrbFlash.cancelled);
    await windDown(tester, controller);
  });

  testWidgets('Esc cancels during recording — the extension lands', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToRecording(tester, controller);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.commands, contains('cancelSession'));
    expect(controller.phase, BridgeSessionState.idle);
    await windDown(tester, controller);
  });

  testWidgets('Esc still cancels recording in a session after a previous one', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    // A first full session: its preview hands primary focus to the field,
    // and its exit unfocuses to the enclosing scope. Without a re-claim,
    // every later recording dispatches keys from the scope and the stage
    // never sees them (real-machine round 3: Esc worked exactly once).
    await pumpToPreview(tester, controller, gateway);
    await controller.cancelSession();
    await tester.pump(const Duration(milliseconds: 1200));

    await pumpToRecording(tester, controller);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.commands, contains('cancelSession'));
    expect(controller.phase, BridgeSessionState.idle);
    await windDown(tester, controller);
  });

  testWidgets('the stage owns the keyboard through the session phases', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    // Recording and rectifying: the stage node is the primary focus, so
    // Esc reaches the stage handler wherever the field left it.
    await pumpToRecording(tester, controller);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'stage-keyboard');

    // Preview hands the keyboard to the editable field (its own re-claim
    // on entry): edits, IME, and Enter live there.
    await pumpToPreview(tester, controller, gateway);
    expect(tester.widget<EditableText>(findSessionField()).focusNode.hasFocus, isTrue);

    // Reroll returns to rectifying: the field is read-only again, the
    // stage node takes the keyboard back.
    await tester.tap(find.byKey(const Key('session-reroll')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'stage-keyboard');
    await windDown(tester, controller);
  });

  testWidgets('the quick panel takes the keyboard when it opens', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    controller.orbSecondary();
    await tester.pump(const Duration(milliseconds: 350));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'stage-keyboard');

    // Esc closes the quick panel through the same stage handler.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.quickOpen, isFalse);
    await windDown(tester, controller);
  });

  testWidgets('the footer cancel button cancels during recording too', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToRecording(tester, controller);

    await tester.tap(find.byKey(const Key('session-cancel')));
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.commands, contains('cancelSession'));
    expect(controller.phase, BridgeSessionState.idle);
    await windDown(tester, controller);
  });

  testWidgets('reroll button asks the engine again', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway);

    await tester.tap(find.byKey(const Key('session-reroll')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands, contains('reroll'));
    expect(controller.phase, BridgeSessionState.rectifying);
    await windDown(tester, controller);
  });

  testWidgets('reroll restarts chunk accumulation instead of concatenating',
      (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway, chunks: ['第一版']);
    expect(controller.previewText, '第一版');

    // Reroll and stream a second attempt.
    await controller.reroll();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['第二版']);
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.previewText, '第二版');
    final field = tester.widget<EditableText>(findSessionField());
    expect(field.controller.text, '第二版');
    await windDown(tester, controller);
  });

  testWidgets('editing the preview pushes updates after the debounce', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway, chunks: ['初稿']);

    await tester.enterText(find.byKey(const Key('session-text')), '改过的初稿');
    expect(
      gateway.commands.where((c) => c.startsWith('updatePreviewText')),
      isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(gateway.commands.where((c) => c.startsWith('updatePreviewText')), [
      'updatePreviewText:改过的初稿',
    ]);
    expect(controller.previewText, '改过的初稿');
    await windDown(tester, controller);
  });

  testWidgets('an edit racing a reroll is dropped, not pushed stale', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway, chunks: ['初稿']);

    // Edit, then immediately reroll before the debounce fires: once
    // rectifying starts, that edit is stale and must not be pushed.
    await tester.enterText(find.byKey(const Key('session-text')), '改了一半');
    await controller.reroll();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      gateway.commands.where((c) => c.startsWith('updatePreviewText')),
      isEmpty,
    );
    await windDown(tester, controller);
  });

  testWidgets('Enter within the debounce window inserts the edited text',
      (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway, chunks: ['初稿']);

    // Edit and press Enter immediately — well inside the 350 ms debounce.
    await tester.enterText(find.byKey(const Key('session-text')), '改完的终稿');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 350));

    // The edit reached the engine before the confirm, not after it.
    final commands = gateway.commands;
    final editAt = commands.indexOf('updatePreviewText:改完的终稿');
    final confirmAt = commands.indexOf('confirmInsert');
    expect(editAt, greaterThanOrEqualTo(0));
    expect(confirmAt, greaterThan(editAt));
    expect(controller.phase, BridgeSessionState.idle);
    await windDown(tester, controller);
  });

  testWidgets('the hotkey within the edit debounce inserts what is on screen',
      (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway, chunks: ['初稿']);

    // Edit, then the hotkey fires immediately — inside the 350 ms
    // debounce window. The confirm must flush the on-screen text to the
    // engine first, not insert the pre-edit snapshot.
    await tester.enterText(find.byKey(const Key('session-text')), '改完的终稿');
    await controller.hotkeyToggle();
    await tester.pump(const Duration(milliseconds: 350));

    final commands = gateway.commands;
    final editAt = commands.indexOf('updatePreviewText:改完的终稿');
    final confirmAt = commands.indexOf('confirmInsert');
    expect(editAt, greaterThanOrEqualTo(0));
    expect(confirmAt, greaterThan(editAt));
    expect(controller.phase, BridgeSessionState.idle);
    await windDown(tester, controller);
  });

  testWidgets('the raw transcript comparison expands under the rectified text',
      (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToRecording(tester, controller);
    gateway.emit(const BridgeEvent.liveTranscriptUpdated(text: '嗯那个\n原话'));
    await tester.pump();
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['整理好的书面文本']);
    await tester.pump(const Duration(milliseconds: 350));

    // Hidden until asked; the session field is always there.
    expect(find.byKey(const Key('session-raw')), findsNothing);
    expect(find.byKey(const Key('session-text')), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-raw-toggle')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('session-text')), findsOneWidget);
    expect(find.text('原始转写'), findsOneWidget);
    expect(find.text('嗯那个\n原话'), findsOneWidget);

    // Toggling again hides the comparison; the edit flow is unaffected.
    await tester.tap(find.byKey(const Key('session-raw-toggle')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('session-raw')), findsNothing);
    expect(controller.previewText, '整理好的书面文本');
    await windDown(tester, controller);
  });

  testWidgets('the scenario chip mirrors the selection from the tray entry', (
    tester,
  ) async {
    final gateway = FakeGateway()
      ..scenarioLibrary.add(const BridgeScenario(
        name: 'Prompt 工程',
        directive: '输出将直接用作 AI 提示词,可分点分行',
      ));
    final controller = await pumpController(tester, gateway);
    await controller.loadScenarios();
    await pumpToRecording(tester, controller);

    // Default register: 默认 on the chip.
    expect(find.text('场景 · 默认'), findsOneWidget);

    // The tray submenu's selection entry is controller.selectScenario;
    // the chip follows at once, and the engine heard the directive text.
    await controller.selectScenario('Prompt 工程');
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('场景 · Prompt 工程'), findsOneWidget);
    expect(
      gateway.commands,
      contains('setStyleDirective:输出将直接用作 AI 提示词,可分点分行'),
    );

    // Back to 默认: the engine hears the reset.
    await controller.selectScenario(null);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('场景 · 默认'), findsOneWidget);
    expect(gateway.commands, contains('setStyleDirective:null'));
    await windDown(tester, controller);
  });

  testWidgets('a failed scenario switch surfaces on the error row', (
    tester,
  ) async {
    final gateway = FakeGateway()
      ..scenarioLibrary.add(const BridgeScenario(
        name: '正式文档',
        directive: '严谨规范',
      ))
      ..failNextSetStyleDirective = StateError('engine gone');
    final controller = await pumpController(tester, gateway);
    await controller.loadScenarios();
    await tester.pump(const Duration(milliseconds: 350));
    await pumpToRecording(tester, controller);

    await controller.selectScenario('正式文档');
    await tester.pump(const Duration(milliseconds: 350));

    // The pick stays (the chip keeps painting it) but the failure is
    // said out loud on the open panel, not swallowed.
    expect(controller.selectedScenario, '正式文档');
    expect(find.byKey(const Key('session-error')), findsOneWidget);
    expect(controller.lastError, contains('场景切换失败'));
    await windDown(tester, controller);
  });

  testWidgets('a loadScenarios against a dead engine keeps the empty library', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    gateway.failNextScenarios = StateError('engine not created yet');

    await controller.loadScenarios();
    await tester.pump(const Duration(milliseconds: 350));

    // The library is decorative: degrade to empty, stay paintable.
    expect(controller.scenarios, isEmpty);
    expect(controller.selectedScenario, isNull);
  });

  testWidgets('openConfigFile goes through the gateway', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await controller.openConfigFile();
    expect(gateway.commands, contains('openConfigFile'));
  });

  testWidgets('tray clear wipes the engine history through the gateway', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await controller.clearHistory();
    expect(gateway.commands, contains('historyClear'));
  });

  testWidgets('a hidden orb renders nothing at rest', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    controller.setOrbVisible(false);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
  });

  testWidgets('the quick panel placeholder opens from an idle right-click', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final window = RecordingStageWindow();
    final controller = await pumpController(
      tester,
      gateway,
      stageWindow: window,
    );

    // Right click the idle orb (会话期无右键: idle only).
    await tester.tap(
      find.byIcon(Icons.mic_none_rounded),
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.stage, StageKind.quick);
    expect(find.text('快捷设置'), findsOneWidget);
    expect(find.byKey(const Key('quick-placeholder')), findsOneWidget);
    // Same footprint as the session window, corner still pinned.
    expect(window.bounds.last.size, SrGeometry.panelSize);
    // The quick panel's Esc-to-close affordance needs the keyboard too.
    expect(window.focuses, greaterThanOrEqualTo(1));
    // The orb is now the close button.
    expect(find.byIcon(Icons.close), findsOneWidget);

    // The orb-as-close collapses back to the orb footprint.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.stage, StageKind.orb);
    expect(window.bounds.last.size, SrGeometry.orbFootprint);
  });

  testWidgets('Esc closes the quick panel without touching the session', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    controller.orbSecondary();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.stage, StageKind.orb);
    expect(gateway.commands, isNot(contains('cancelSession')));
    expect(controller.phase, BridgeSessionState.idle);
  });

  testWidgets('a session start force-closes the quick panel', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    controller.orbSecondary();
    await tester.pump(const Duration(milliseconds: 350));
    await controller.hotkeyToggle();
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.phase, BridgeSessionState.recording);
    expect(controller.stage, StageKind.session);
    expect(find.text('聆听中'), findsOneWidget);
    await windDown(tester, controller);
  });

  testWidgets('rectifying keeps the panel footprint — reroll never resizes', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final window = RecordingStageWindow();
    final controller = await pumpController(
      tester,
      gateway,
      stageWindow: window,
    );

    await pumpToPreview(tester, controller, gateway);
    await controller.reroll();
    await tester.pump(const Duration(milliseconds: 350));

    // One expand for the whole session: rectifying and preview share the
    // session window (修正≡预览同形).
    expect(window.bounds, hasLength(1));
    expect(window.bounds.last.size, SrGeometry.panelSize);
    await windDown(tester, controller);
  });

  group('both palettes paint the surfaces', () {
    testWidgets('dark palette', (tester) async {
      final gateway = FakeGateway();
      final controller = await pumpController(
        tester,
        gateway,
        themeMode: ThemeMode.dark,
      );
      await pumpToRecording(tester, controller);

      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == SrPalette.dark.surface,
        ),
        findsOneWidget,
      );
      await windDown(tester, controller);
    });

    testWidgets('light palette', (tester) async {
      final gateway = FakeGateway();
      final controller = await pumpController(
        tester,
        gateway,
        themeMode: ThemeMode.light,
      );
      await pumpToRecording(tester, controller);

      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == SrPalette.light.surface,
        ),
        findsOneWidget,
      );
      await windDown(tester, controller);
    });
  });

  test('hotkey presses map through the same table as the orb', () async {
    final gateway = FakeGateway();
    final controller = SpeechController(
      gateway: gateway,
      scriptedPhrases: const [],
    );
    addTearDown(controller.dispose);

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('startSession'));

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('stopSession'));
  });

  test('scripted speech feeds phrases and paragraph silences', () async {
    final gateway = FakeGateway();
    final controller = SpeechController(
      gateway: gateway,
      scriptedPhrases: const ['一', '二', '三'],
      speechInterval: const Duration(milliseconds: 1),
    );
    addTearDown(controller.dispose);

    await controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(gateway.said.length, greaterThanOrEqualTo(3));
    expect(
      gateway.commands.where((c) => c.startsWith('fakeSilence:1300')).length,
      greaterThanOrEqualTo(1),
    );
    await controller.cancelSession();
  });

  group('choreography geometry is parameterized', () {
    Future<RecordingStageWindow> grown(stage.GrowthDirection dir) async {
      final w = RecordingStageWindow(const Offset(100, 200));
      await w.setBounds(const Rect.fromLTWH(100, 200, 96, 96));
      await stage.stageBounds(w, SrGeometry.panelSize, dir: dir);
      return w;
    }

    test('every growth direction pins its own corner', () async {
      // upLeft (v1 default): bottom-right corner stays put.
      expect(
        (await grown(stage.GrowthDirection.upLeft)).bounds.last,
        const Rect.fromLTRB(100 - 324, 200 - 464, 196, 296),
      );
      // upRight: bottom-left corner stays put.
      expect(
        (await grown(stage.GrowthDirection.upRight)).bounds.last,
        const Rect.fromLTRB(100, 200 - 464, 520, 296),
      );
      // downLeft: top-right corner stays put.
      expect(
        (await grown(stage.GrowthDirection.downLeft)).bounds.last,
        const Rect.fromLTRB(100 - 324, 200, 196, 760),
      );
      // downRight: top-left corner stays put.
      expect(
        (await grown(stage.GrowthDirection.downRight)).bounds.last,
        const Rect.fromLTRB(100, 200, 520, 760),
      );
    });
  });
}
