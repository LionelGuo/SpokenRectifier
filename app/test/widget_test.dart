/// Widget tests for the shell: the orb-position surfaces (orb, session
/// window, quick panel placeholder) and the window choreography ride a
/// pure-Dart fake gateway and a recording stage window — no Rust dylib,
/// no platform channels.

library;

import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart';
import 'package:spokenrectifier_app/src/preview/slot_surface.dart';
import 'package:spokenrectifier_app/src/rust/api.dart'
    show BridgeEvent, BridgeHistoryEntry, BridgeScenario, BridgeSessionState;
import 'package:spokenrectifier_app/src/settings/settings_domain.dart';
import 'package:spokenrectifier_app/src/shell/history_retrieval.dart'
    show DefaultRegisterPick, NamedScenarioPick;
import 'package:spokenrectifier_app/src/shell/quick_panel.dart'
    show formatHistoryStamp;
import 'package:spokenrectifier_app/src/shell/session_flow.dart' show StageKind;
import 'package:spokenrectifier_app/src/shell/window_stage.dart'
    as stage
    show GrowthDirection, StageWindow, stageBounds;
import 'package:spokenrectifier_app/ui_prefs.dart';

import 'fake_gateway.dart';

/// The session field's editable core: the self-drawn slot surface
/// (ticket 22). The Key sits on the SlotSurface itself.
SlotSurfaceState sessionSurface(WidgetTester tester) =>
    tester.state(find.byKey(const Key('session-text'))) as SlotSurfaceState;

/// Types [text] into the session surface exactly the way the platform
/// delivers it: an editing-value update against the surface's own IME
/// shadow (never a key event — printable keys feed the text input).
Future<void> typeAtCaret(WidgetTester tester, String text) async {
  final surface = sessionSurface(tester);
  final value = surface.currentTextEditingValue!;
  final caret = value.selection.baseOffset;
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value.text.replaceRange(caret, caret, text),
      selection: TextSelection.collapsed(offset: caret + text.length),
    ),
  );
  await tester.pump();
}

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
  void Function(SettingsDomain domain)? onOpenSettings,
}) async {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
    themeMode: themeMode,
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    SpokenRectifierApp(
      controller: controller,
      stageWindow: stageWindow,
      onOpenSettings: onOpenSettings,
    ),
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

  testWidgets(
    'a startup refusal pins the orb and is not masked by a start click',
    (tester) async {
      final gateway = FakeGateway();
      final controller = await pumpController(tester, gateway);

      // The engine refused to assemble (e.g. tencent with credentials):
      // the orb rests with the error pending.
      controller.reportStartupError('初始化失败:ASR provider "tencent"');
      await tester.pump();
      expect(controller.orbErrorPending, isTrue);
      expect(find.byKey(const Key('orb-error-badge')), findsOneWidget);

      // A start click against the dead engine stays idle and keeps the
      // root cause — the generic "engine not created" must not mask it.
      gateway.failNextStart = StateError('engine not created yet');
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await tester.pump();
      expect(controller.stage, StageKind.orb);
      expect(controller.lastError, '初始化失败:ASR provider "tencent"');
      expect(find.byKey(const Key('orb-error-badge')), findsOneWidget);

      // Without any error the orb rests bare (no idle badge).
      controller.lastError = null;
      controller.notifyListeners();
      await tester.pump();
      expect(find.byKey(const Key('orb-error-badge')), findsNothing);
    },
  );

  testWidgets('the quick panel carries the pending error in full', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    // A startup refusal (or a failed session) parks a long message —
    // the orb tooltip clips it to the 96 px window; the panel wraps it.
    controller.reportStartupError(
      '初始化失败:ASR handshake rejected: HTTP 400: '
      '{"error":"resourceId volc.seedasr.sauc.duration is not allowed"}',
    );
    await tester.pump();
    controller.orbSecondary();
    await tester.pump();

    final row = find.byKey(const Key('quick-error'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.textContaining('not allowed')),
      findsOneWidget,
    );
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

  testWidgets('stop streams chunks into preview; confirm via the hotkey', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final window = RecordingStageWindow();
    final controller = await pumpController(
      tester,
      gateway,
      stageWindow: window,
    );

    await pumpToPreview(tester, controller, gateway, chunks: ['修正', '后的文本']);

    // The session surface holds the joined chunks, editable in preview.
    expect(sessionSurface(tester).flatBaseText, '修正后的文本');
    // Preview entry re-guarantees the keyboard after the expand focus.
    expect(window.focuses, greaterThanOrEqualTo(2));

    // Enter in the surface is a newline now, not a confirm (槽内 Enter
    // 是换行,08 号票 — the field's chat-input confirm is retired).
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.phase, BridgeSessionState.preview);
    expect(gateway.commands, isNot(contains('confirmInsert')));

    // The hotkey (the table's primary) confirms what is on screen.
    await controller.hotkeyToggle();
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

    // Preview hands the keyboard to the editing surface (its own
    // re-claim on entry): edits, IME, and Enter live there.
    await pumpToPreview(tester, controller, gateway);
    expect(sessionSurface(tester).widget.focusNode!.hasFocus, isTrue);

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

  testWidgets('reroll restarts chunk accumulation instead of concatenating', (
    tester,
  ) async {
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
    expect(sessionSurface(tester).flatBaseText, '第二版');
    await windDown(tester, controller);
  });

  testWidgets('editing the preview pushes updates after the debounce', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway, chunks: ['初稿']);

    // Move to the end (arrive parks the caret at the body's start), then
    // type the way the platform delivers it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    for (final _ in '初稿'.split('')) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await typeAtCaret(tester, '改过的');
    expect(
      gateway.commands.where((c) => c.startsWith('updatePreviewText')),
      isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(gateway.commands.where((c) => c.startsWith('updatePreviewText')), [
      'updatePreviewText:初稿改过的',
    ]);
    expect(controller.previewText, '初稿改过的');
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
    await typeAtCaret(tester, '改了一半');
    await controller.reroll();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      gateway.commands.where((c) => c.startsWith('updatePreviewText')),
      isEmpty,
    );
    await windDown(tester, controller);
  });

  testWidgets('the hotkey within the edit debounce inserts what is on screen', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToPreview(tester, controller, gateway, chunks: ['初稿']);

    // Type (the caret parks at the body's start on arrival), then the
    // hotkey fires immediately — inside the 350 ms debounce window. The
    // confirm must flush the on-screen text to the engine first, not
    // insert the pre-edit snapshot.
    await typeAtCaret(tester, '改完的终稿');
    await controller.hotkeyToggle();
    await tester.pump(const Duration(milliseconds: 350));

    final commands = gateway.commands;
    final editAt = commands.indexOf('updatePreviewText:改完的终稿初稿');
    final confirmAt = commands.indexOf('confirmInsert');
    expect(editAt, greaterThanOrEqualTo(0));
    expect(confirmAt, greaterThan(editAt));
    expect(controller.phase, BridgeSessionState.idle);
    await windDown(tester, controller);
  });

  testWidgets(
    'the raw transcript comparison expands under the rectified text',
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
    },
  );

  testWidgets('the scenario chip mirrors the selection from the tray entry', (
    tester,
  ) async {
    final gateway = FakeGateway()
      ..scenarioLibrary.add(
        const BridgeScenario(
          name: 'Prompt 工程',
          directive: '输出将直接用作 AI 提示词,可分点分行',
        ),
      );
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
      ..scenarioLibrary.add(
        const BridgeScenario(name: '正式文档', directive: '严谨规范'),
      )
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

  testWidgets(
    'the quick panel opens from an idle right-click with its sections',
    (tester) async {
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
      // The sections paint: terms, passage, theme. The scenario picker
      // row hides with an empty library, but the section keeps its
      // editor entry (the creation path into the settings window);
      // history shows its empty hint.
      expect(find.text('术语速加'), findsOneWidget);
      expect(find.text('历史'), findsOneWidget);
      expect(find.byKey(const Key('quick-history-empty')), findsOneWidget);
      expect(find.text('输入'), findsOneWidget);
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('场景'), findsOneWidget);
      expect(
        find.byKey(const Key('quick-open-settings:scenarios')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('quick-scenario-default')), findsNothing);
      // The anchor-zone bottom fade is part of the panel's shape.
      expect(find.byKey(const Key('quick-bottom-fade')), findsOneWidget);
      // Opening refreshed the panel's lists.
      expect(gateway.commands, containsAll(['termsList', 'historyList']));
      // Same footprint as the session window, corner still pinned.
      expect(window.bounds.last.size, SrGeometry.panelSize);
      // The quick panel's Esc-to-close affordance needs the keyboard too.
      expect(window.focuses, greaterThanOrEqualTo(1));
      // The orb is now the close button.
      expect(find.byIcon(Icons.close), findsOneWidget);

      // The orb-as-close collapses back to the orb footprint — and hands
      // the keyboard back to the remembered target (挂账 from ticket 15).
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.stage, StageKind.orb);
      expect(window.bounds.last.size, SrGeometry.orbFootprint);
      expect(gateway.commands, contains('restoreFocus'));
    },
  );

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

  testWidgets('the management entries open the settings window on domain', (
    tester,
  ) async {
    final gateway = FakeGateway()
      ..scenarioLibrary.add(
        const BridgeScenario(name: '论文', directive: '学术书面语'),
      );
    final opened = <SettingsDomain>[];
    final controller = await pumpController(
      tester,
      gateway,
      onOpenSettings: opened.add,
    );

    // Right click the idle orb, then walk the three entry rows.
    await tester.tap(
      find.byIcon(Icons.mic_none_rounded),
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const Key('quick-open-settings:scenarios')));
    await tester.tap(find.byKey(const Key('quick-open-settings:history')));
    await tester.tap(find.byKey(const Key('quick-open-settings:general')));
    await tester.pump();

    // 全面配置 lands on the first domain (the settings window's default).
    expect(opened, [
      SettingsDomain.scenarios,
      SettingsDomain.history,
      SettingsDomain.scenarios,
    ]);
    // Opening settings leaves the quick panel open (its own window).
    expect(controller.stage, StageKind.quick);
    expect(gateway.commands, isNot(contains('restoreFocus')));
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

  // -- the quick panel's sections (ticket 16) -------------------------------

  /// Opens the quick panel and lets the refreshed lists land.
  Future<void> pumpQuickOpen(WidgetTester tester, SpeechController c) async {
    c.orbSecondary();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Hovers the mouse over `finder` and lets the hover fades land (the
  /// reveals are animated, so affordances need the frames before taps;
  /// the surface fade outlasts the micro one).
  Future<void> hoverOver(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(finder));
    addTearDown(gesture.removePointer);
    await tester.pump();
    await tester.pump(SrMotion.fade);
  }

  testWidgets('quick scenario chips are the third selector of the same pick', (
    tester,
  ) async {
    final gateway = FakeGateway()
      ..scenarioLibrary.add(
        const BridgeScenario(name: 'Prompt 工程', directive: '输出将直接用作 AI 提示词'),
      );
    final controller = await pumpController(tester, gateway);
    await controller.loadScenarios();
    await pumpQuickOpen(tester, controller);

    // The section paints with the library: 默认 plus every entry.
    expect(find.text('场景'), findsOneWidget);
    expect(find.byKey(const Key('quick-scenario-default')), findsOneWidget);
    expect(find.byKey(const Key('quick-scenario:Prompt 工程')), findsOneWidget);

    // Picking here is the same shared entry the chip and the tray use:
    // the directive goes to the engine, the session chip would follow.
    await tester.tap(find.byKey(const Key('quick-scenario:Prompt 工程')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.selectedScenario, 'Prompt 工程');
    expect(gateway.commands, contains('setStyleDirective:输出将直接用作 AI 提示词'));

    await tester.tap(find.byKey(const Key('quick-scenario-default')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.selectedScenario, isNull);
    expect(gateway.commands, contains('setStyleDirective:null'));
  });

  // -- the global directive's preview row (ticket 22) ----------------------

  testWidgets(
    'loadGlobalDirective pushes the engine and paints the preview row',
    (tester) async {
      final gateway = FakeGateway()..global = '全部输出用简体中文书写';
      final controller = await pumpController(tester, gateway);
      await pumpQuickOpen(tester, controller);

      // Unset until loaded: the panel carries no trace of the row.
      expect(find.byKey(const Key('quick-global-preview')), findsNothing);

      await controller.loadGlobalDirective();
      await tester.pump(const Duration(milliseconds: 350));

      // The file's text went to the engine (every rectify runs with it)
      // and the row paints one truncated line of it.
      expect(gateway.commands, contains('globalDirective'));
      expect(gateway.commands, contains('setGlobalDirective:全部输出用简体中文书写'));
      expect(
        find.byKey(const Key('quick-global-preview')),
        findsOneWidget,
      );
    },
  );

  testWidgets('the preview row shows with an empty library, hides while unset', (
    tester,
  ) async {
    final gateway = FakeGateway()..global = '恒常生效的指令';
    final controller = await pumpController(tester, gateway);
    await controller.loadGlobalDirective();
    await pumpQuickOpen(tester, controller);

    // An empty library hides the picker chips but not the global row: the
    // directive is not one scenario among others.
    expect(find.byKey(const Key('quick-scenario-default')), findsNothing);
    expect(find.byKey(const Key('quick-global-preview')), findsOneWidget);

    // Unset: the whole row goes away — the panel is as before.
    gateway.global = null;
    await controller.onGlobalDirectiveChanged();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('quick-global-preview')), findsNothing);
  });

  testWidgets('the preview row jump lands on the scenario domain', (
    tester,
  ) async {
    final gateway = FakeGateway()..global = '恒常生效的指令';
    final opened = <SettingsDomain>[];
    final controller = await pumpController(
      tester,
      gateway,
      onOpenSettings: opened.add,
    );
    await controller.loadGlobalDirective();
    await pumpQuickOpen(tester, controller);

    await tester.tap(find.byKey(const Key('quick-global-open')));
    await tester.pump();
    expect(opened, [SettingsDomain.scenarios]);
  });

  testWidgets(
    'a global-changed reaction re-reads the file and re-pushes the engine',
    (tester) async {
      final gateway = FakeGateway()..global = '第一版指令';
      final controller = await pumpController(tester, gateway);
      await controller.loadGlobalDirective();
      expect(gateway.commands, contains('setGlobalDirective:第一版指令'));

      // The settings window saved a new text: the reaction re-reads the
      // file (the truth) and pushes the fresh value — the engine's live
      // read applies it to the very next attempt, rerolls included.
      gateway.global = '第二版指令';
      await controller.onGlobalDirectiveChanged();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.globalDirective, '第二版指令');
      expect(gateway.commands, contains('setGlobalDirective:第二版指令'));
    },
  );

  testWidgets('quick terms add via Enter and the button, remove via the chip', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpQuickOpen(tester, controller);

    // Enter commits the field's text as a term (IME composition commits
    // instead — the field's default semantics).
    await tester.enterText(find.byKey(const Key('quick-term-field')), '新术语');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands, contains('appendTerm:新术语'));
    expect(find.text('新术语'), findsOneWidget); // the chip landed

    // The add button walks the same path.
    await tester.enterText(find.byKey(const Key('quick-term-field')), '术语乙');
    await tester.tap(find.byKey(const Key('quick-term-add')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands, contains('appendTerm:术语乙'));

    // Blank input adds nothing.
    await tester.enterText(find.byKey(const Key('quick-term-field')), '   ');
    await tester.tap(find.byKey(const Key('quick-term-add')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      gateway.commands.where((c) => c.startsWith('appendTerm:')),
      hasLength(2),
    );

    // The chip's ✕ removes the line from the dictionary.
    await tester.tap(find.byKey(const Key('quick-term-remove:新术语')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands, contains('removeTerm:新术语'));
    expect(find.text('新术语'), findsNothing);
  });

  testWidgets(
    'history rows show the rectified text; copy and scenario re-rectify ride it',
    (tester) async {
      final gateway = FakeGateway()
        ..scenarioLibrary.add(
          const BridgeScenario(name: '论文', directive: '学术书面语'),
        );
      for (var i = 1; i <= 4; i++) {
        gateway.historyEntries.add(
          BridgeHistoryEntry(
            id: i,
            createdAtMs: BigInt.from(i),
            rawTranscript: '第$i句原话',
            rectifiedText: '第$i句修正',
          ),
        );
      }
      final controller = await pumpController(tester, gateway);
      await controller.loadScenarios(); // 论文 is on the pickers
      await pumpQuickOpen(tester, controller);

      // Three rows of the rectified text (ticket 23: 所见即所复制) — the
      // fourth stays in the store, not the panel.
      expect(find.textContaining('句修正'), findsNWidgets(3));

      // The actions ride every row but stay faded out until hover
      // (悬停显复制/重修) — one animated reveal, no layout pop.
      final row = find.text('第1句修正');
      double actionsFade() => (tester.widget(
        find.byKey(const Key('quick-history-actions:1')),
      ) as AnimatedOpacity).opacity;
      expect(actionsFade(), 0);
      await hoverOver(tester, row);
      expect(actionsFade(), 1);
      expect(find.byKey(const Key('quick-history-copy:1')), findsOneWidget);
      expect(
        find.byKey(const Key('quick-history-rerectify-scenario:1')),
        findsOneWidget,
      );

      // Copy puts exactly what the row shows on the clipboard.
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
      await tester.tap(find.byKey(const Key('quick-history-copy:1')));
      await tester.pump();
      expect(copied, '第1句修正');

      // 指定场景重新修正 opens the same menu the settings window's rows
      // use — 默认 first, then the library (ticket 28); the pick runs
      // the utterance under that scenario for this one session, and the
      // session window takes over from the panel.
      await tester.tap(
        find.byKey(const Key('quick-history-rerectify-scenario:1')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('quick-history-scenario-item-builtin-default')),
        findsOneWidget,
      );
      // 居首: the built-in item paints above the first scenario item.
      expect(
        tester
            .getTopLeft(
              find.byKey(const Key('quick-history-scenario-item-builtin-default')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const Key('quick-history-scenario-item:论文')),
              )
              .dy,
        ),
      );
      // The menu item by key: the panel's scenario chip carries the same
      // name, so a text finder would be ambiguous.
      await tester.tap(find.byKey(const Key('quick-history-scenario-item:论文')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(gateway.commands, contains('rectifyText:第1句原话@学术书面语'));
      expect(controller.oneTimeStyle, const NamedScenarioPick('论文'));
      expect(controller.phase, BridgeSessionState.preview);
      expect(controller.stage, StageKind.session);
      expect(controller.quickOpen, isFalse);

      // And when that session ends, the orb rests — the panel does not
      // resurrect from the stale flag.
      await controller.cancelSession();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(controller.stage, StageKind.orb);
    },
  );

  testWidgets('a one-time scenario pins the re-rectify session, then clears', (
    tester,
  ) async {
    final gateway = FakeGateway()
      ..scenarioLibrary.add(
        const BridgeScenario(name: '论文', directive: '学术书面语'),
      )
      ..historyEntries.add(
        BridgeHistoryEntry(
          id: 1,
          createdAtMs: BigInt.one,
          rawTranscript: '旧话',
          rectifiedText: '旧成文',
        ),
      );
    final controller = await pumpController(tester, gateway);
    await controller.loadScenarios(); // 论文 is on the pickers

    // The 指定场景 key routes here (both surfaces — the quick panel
    // directly, the settings window over the cross-window channel): the
    // session runs under the scenario for this one session, the
    // selection never moves (ticket 23).
    await controller.rerectifyHistory(
      '旧话',
      style: const NamedScenarioPick('论文'),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands, contains('rectifyText:旧话@学术书面语'));
    expect(controller.oneTimeStyle, const NamedScenarioPick('论文'));
    expect(controller.selectedScenario, isNull);
    // The chip paints the standard format with the session's scenario.
    expect(find.text('场景 · 论文'), findsOneWidget);

    // The session ends: the pin and the name die with it, and the
    // next plain retrieval runs under the live selection again.
    await controller.cancelSession();
    await tester.pump(const Duration(milliseconds: 1200));
    expect(controller.oneTimeStyle, isNull);

    // The built-in 默认 pick (ticket 28): with a scenario selected, the
    // session still runs under the default register — the chip paints
    // 默认 rather than masquerading as the selection, and the selection
    // itself never moves.
    await controller.selectScenario('论文');
    await controller.rerectifyHistory(
      '旧话',
      style: const DefaultRegisterPick(),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands.last, 'rectifyText:旧话@默认');
    expect(controller.oneTimeStyle, const DefaultRegisterPick());
    expect(controller.selectedScenario, '论文');
    expect(find.text('场景 · 默认'), findsOneWidget);

    // A name the library no longer holds reads as no scenario: the
    // retrieval still runs, under the live selection.
    await controller.cancelSession();
    await tester.pump(const Duration(milliseconds: 1200));
    await controller.rerectifyHistory(
      '旧话',
      style: const NamedScenarioPick('已删除的'),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands.last, 'rectifyText:旧话');
    expect(controller.oneTimeStyle, isNull);
  });

  testWidgets(
    'a failed re-rectify surfaces on the panel instead of vanishing',
    (tester) async {
      final gateway = FakeGateway()
        ..scenarioLibrary.add(
          const BridgeScenario(name: '论文', directive: '学术书面语'),
        )
        ..historyEntries.add(
          BridgeHistoryEntry(
            id: 1,
            createdAtMs: BigInt.one,
            rawTranscript: '原话',
            rectifiedText: '成文',
          ),
        )
        ..failNextRectifyText = StateError('engine gone');
      final controller = await pumpController(tester, gateway);
      await controller.loadScenarios();
      await pumpQuickOpen(tester, controller);

      await hoverOver(tester, find.text('成文'));
      await tester.tap(
        find.byKey(const Key('quick-history-rerectify-scenario:1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quick-history-scenario-item:论文')));
      await tester.pump(const Duration(milliseconds: 350));

      expect(controller.lastError, contains('重新修正失败'));
      expect(controller.stage, StageKind.quick); // the panel is still up
    },
  );

  testWidgets('the passage switch toggles the engine flag', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await controller.loadPassageMode(); // engine says on
    await pumpQuickOpen(tester, controller);

    expect(
      (tester.widget(find.byKey(const Key('quick-passage'))) as Switch).value,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('quick-passage')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands, contains('setPassageMode:false'));
    expect(controller.passageMode, isFalse);

    await tester.tap(find.byKey(const Key('quick-passage')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands, contains('setPassageMode:true'));
    expect(controller.passageMode, isTrue);
  });

  testWidgets(
    'a failed passage switch rolls the toggle back to the engine truth',
    (tester) async {
      final gateway = FakeGateway()
        ..failNextSetPassageMode = StateError('engine gone');
      final controller = await pumpController(tester, gateway);
      await pumpQuickOpen(tester, controller);

      await tester.tap(find.byKey(const Key('quick-passage')));
      await tester.pump(const Duration(milliseconds: 350));

      // The toggle mirrors engine state the next session runs with: a
      // rejected switch must not paint a mode the engine never adopted.
      expect(controller.passageMode, isTrue);
      expect(gateway.passage, isTrue);
      expect(controller.lastError, contains('篇章模式切换失败'));
      // The switch still paints the truth.
      expect(
        (tester.widget(find.byKey(const Key('quick-passage'))) as Switch).value,
        isTrue,
      );
    },
  );

  testWidgets(
    'the theme tri-state repaints at once and persists for restarts',
    (tester) async {
      // Sync IO: async dart:io futures never complete inside the widget-test
      // zone on this host (WSL quirk, probed and confirmed).
      final dir = Directory.systemTemp.createTempSync('sr-ui-prefs-widget-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gateway = FakeGateway();
      final controller = SpeechController(
        gateway: gateway,
        scriptedPhrases: const [],
        uiPrefsDirs: [dir.path],
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        SpokenRectifierApp(controller: controller, stageWindow: null),
      );
      await pumpQuickOpen(tester, controller);

      // The 外观 section sits below the fold of the scrollable list:
      // bring it into view before tapping its segments.
      await tester.dragUntilVisible(
        find.byKey(const Key('quick-theme-dark')),
        find.byType(Scrollable),
        const Offset(0, -40),
      );
      await tester.pumpAndSettle();

      // Dark: the surfaces repaint immediately and the file says so.
      // (A plain frame first — the theme-mode swap lands on the frame
      // after the rebuild in the test scheduler; sync IO throughout, see
      // the temp-dir note above.)
      await tester.tap(find.byKey(const Key('quick-theme-dark')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.themeMode, ThemeMode.dark);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == SrPalette.dark.surface,
        ),
        findsOneWidget,
      );
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        'theme = "dark"\n',
      );

      // Light: the write replaces the key in place, not a second file.
      await tester.tap(find.byKey(const Key('quick-theme-light')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.themeMode, ThemeMode.light);
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        'theme = "light"\n',
      );

      // A fresh controller reads the same file back (restart persistence).
      expect(loadUiThemeMode([dir.path]), ThemeMode.light);
    },
  );

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

  group('history row stamps', () {
    final now = DateTime(2026, 8, 28, 15, 0);

    test('today shows the clock', () {
      expect(
        formatHistoryStamp(at: DateTime(2026, 8, 28, 9, 5), now: now),
        '09:05',
      );
    });

    test('yesterday says so', () {
      expect(
        formatHistoryStamp(at: DateTime(2026, 8, 27, 21, 4), now: now),
        '昨天 21:04',
      );
    });

    test('same year carries the date without the year', () {
      expect(
        formatHistoryStamp(at: DateTime(2026, 3, 2, 8, 30), now: now),
        '3月2日 08:30',
      );
    });

    test('another year carries the year too', () {
      expect(
        formatHistoryStamp(at: DateTime(2025, 12, 31, 23, 59), now: now),
        '2025年12月31日 23:59',
      );
    });
  });
}
