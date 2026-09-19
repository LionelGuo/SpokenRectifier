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
    show
        BridgeEvent,
        BridgeHistoryEntry,
        BridgePrefillRow,
        BridgeScenario,
        BridgeSessionState;
import 'package:spokenrectifier_app/src/settings/settings_domain.dart';
import 'package:spokenrectifier_app/src/shell/history_retrieval.dart'
    show DefaultRegisterPick, NamedScenarioPick;
import 'package:spokenrectifier_app/src/shell/orb_button.dart';
import 'package:spokenrectifier_app/src/session/session_panel.dart';
import 'package:spokenrectifier_app/src/shell/quick_panel.dart'
    show QuickPanel, formatHistoryStamp;
import 'package:spokenrectifier_app/src/shell/session_flow.dart' show StageKind;
import 'package:spokenrectifier_app/src/shell/window_stage.dart'
    as stage
    show GrowthDirection, GrowthDirectionX, StageWindow, stageBounds;
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

  /// Widget tests advance the fake clock; a non-zero delay lets a
  /// burst of drag updates land while a setBounds is still in flight
  /// (the production flicker: stale SetWindowPos completing late).
  Duration setBoundsDelay = Duration.zero;

  /// The work areas the expand chooser and the clamps see; tests pin it
  /// to place the orb in a quadrant or squeeze a fit. (Named `screens` —
  /// a field cannot share the interface method's name.)
  List<Rect> screens = const [Rect.fromLTWH(0, 0, 1920, 1080)];

  /// How many times the window was asked to take the foreground.
  int focuses = 0;

  /// The window regions pushed while panels open (ADR 0017 ceiling
  /// window; the region hugs the card slot, null = the whole window --
  /// the orb stage and a live resize whose card must paint unclipped).
  final regions = <Rect?>[];

  @override
  Future<Offset> getPosition() async => position;

  @override
  Future<Size> getSize() async => size;

  @override
  Future<void> setBounds(Rect bounds) async {
    if (setBoundsDelay > Duration.zero) {
      await Future<void>.delayed(setBoundsDelay);
    }
    this.bounds.add(bounds);
    position = bounds.topLeft;
    size = bounds.size;
  }

  @override
  Future<void> setCardRegion(Rect? windowRect) async => regions.add(windowRect);

  @override
  Future<List<Rect>> workAreas() async => screens;

  /// When set, the host tracks this as the screen cursor (production
  /// path). Null keeps the test-view's `PointerEvent.position` as the
  /// screen-stable stand-in — `setBounds` never moves the test view.
  Offset? Function()? screenPointer;

  @override
  Offset? pointerOnScreen() => screenPointer?.call();

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

    // The window jumped to the panel growth CEILING in one atomic call,
    // pinning the bottom-right corner (upLeft growth, 96 -> 1096x596 —
    // the anchor's span caps tighter than 70%; the card renders in the
    // slot at 420x560, ADR 0017).
    expect(window.bounds, [const Rect.fromLTRB(0, 0, 1096, 596)]);

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
      // The raw provider string never reaches the screen — only the
      // classified short sentence (this one falls to the other bucket).
      expect(controller.lastError, '服务出错，请重试');

      // A start click against the dead engine stays idle and keeps the
      // root cause — the generic "engine not created" must not mask it.
      gateway.failNextStart = StateError('engine not created yet');
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await tester.pump();
      expect(controller.stage, StageKind.orb);
      expect(controller.lastError, '服务出错，请重试');
      expect(find.byKey(const Key('orb-error-badge')), findsOneWidget);

      // Without any error the orb rests bare (no idle badge).
      controller.lastError = null;
      controller.notifyListeners();
      await tester.pump();
      expect(find.byKey(const Key('orb-error-badge')), findsNothing);
    },
  );

  testWidgets('the quick panel toasts a pending error as a short sentence', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    // A startup refusal parks a long raw message: the orb tooltip
    // used to wrap it, the panel used to paint an inline card. Both
    // now show the classified short sentence; the raw text stays in
    // the console.
    controller.reportStartupError(
      '初始化失败:ASR handshake rejected: HTTP 400: '
      '{"error":"resourceId volc.seedasr.sauc.duration is not allowed"}',
    );
    await tester.pump();
    controller.orbSecondary();
    // Two 350ms pumps: the stage expand + the panel's post-frame toast.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byKey(const Key('quick-error')), findsNothing);
    expect(textOf(tester, const Key('sr-toast')), '服务出错，请重试');
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
    expect(controller.lastError, '音频设备异常，请检查麦克风');
    // No panel is open; the resting orb carries the classified short
    // sentence on its tooltip until the next interaction.
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '') == '音频设备异常，请检查麦克风',
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
    expect(find.byKey(const Key('session-error')), findsNothing);
    expect(textOf(tester, const Key('sr-toast')), '凭据无效，请检查密钥');
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

  testWidgets(
    'the preview footer fits the panel footprint — nothing hides under the ball',
    (tester) async {
      // The real window is the panel footprint (420x560 logical); the test
      // surface defaults to 800x600, which is why the footer's overflow
      // only ever showed on the device (the red debug stripe painted under
      // the ball). Pin the real size before pumping.
      tester.view.physicalSize = SrGeometry.panelSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final gateway = FakeGateway();
      final controller = await pumpController(tester, gateway);
      await pumpToPreview(tester, controller, gateway);

      // The full preview footer (对照原文 / 重新生成 / 取消 Esc) laid out at
      // the real width overflows nothing.
      expect(tester.takeException(), isNull);

      // The last capsule also stays clear of the ball's left edge
      // (anchorInset + orbBall/2 from the window's right).
      final ballLeft =
          SrGeometry.panelSize.width -
          SrGeometry.anchorInset -
          SrGeometry.orbBall / 2;
      expect(
        tester.getTopRight(find.byKey(const Key('session-cancel'))).dx,
        lessThanOrEqualTo(ballLeft),
      );
      await windDown(tester, controller);
    },
  );

  testWidgets(
    'the preview footer clips at the resize floor — no overflow stripe',
    (tester) async {
      // Ticket 01 pinned the default 420-wide footprint. Reshape can shrink
      // the shared footprint to panelMinSize (360×440); the three preview
      // capsules no longer fit, and the debug stripe comes back unless the
      // row clips instead of overflowing. Icon-only shrinking is a later
      // change — this only kills the RenderFlex report.
      tester.view.physicalSize = SrGeometry.panelMinSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final gateway = FakeGateway();
      final controller = await pumpController(tester, gateway);
      await pumpToPreview(tester, controller, gateway);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('session-raw-toggle')), findsOneWidget);
      expect(find.byKey(const Key('session-reroll')), findsOneWidget);
      expect(find.byKey(const Key('session-cancel')), findsOneWidget);
      await windDown(tester, controller);
    },
  );

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
    'confirming within a slot-edit debounce flushes the substituted text',
    (tester) async {
      // A pinned session (ticket 23): the slot's prefill substitutes at
      // entry, a value edit inside the debounce window substitutes too,
      // and the confirm flushes exactly that — the sentinel never rides
      // to the engine on any path.
      final gateway = FakeGateway();
      final controller = await pumpController(tester, gateway);
      await pumpToRecording(tester, controller);
      await gateway.pinPlaceholder();
      await tester.pump();
      await controller.stopSession();
      await tester.pump(const Duration(milliseconds: 350));

      gateway.emit(const BridgeEvent.rectifiedTextChunk(delta: '发给‡1‡一下'));
      gateway.emit(
        const BridgeEvent.previewPrefills(
          prefills: [BridgePrefillRow(number: 1, value: '张三')],
        ),
      );
      gateway.emit(
        const BridgeEvent.sessionStateChanged(
          from: BridgeSessionState.rectifying,
          to: BridgeSessionState.preview,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // Entry adopted the substitution right away (无钉零影响的反面:
      // 有钉即推).
      expect(gateway.commands, contains('updatePreviewText:发给张三一下'));

      // Step into the capsule (arrive parks the caret at the body's
      // start; the walk is outside-0 → outside-1 → the capsule's
      // outside-left dock → the value's first dock) and type — still
      // inside the debounce window when the confirm fires.
      for (final _ in '123'.split('')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await typeAtCaret(tester, '李');
      await controller.hotkeyToggle();
      await tester.pump(const Duration(milliseconds: 350));

      final commands = gateway.commands;
      final editAt = commands.lastIndexOf('updatePreviewText:发给李张三一下');
      final confirmAt = commands.indexOf('confirmInsert');
      expect(editAt, greaterThanOrEqualTo(0));
      expect(confirmAt, greaterThan(editAt));
      expect(
        commands
            .where((c) => c.startsWith('updatePreviewText'))
            .every((c) => !c.contains('‡')),
        isTrue,
        reason: 'the engine only ever sees the substituted text',
      );
      expect(controller.phase, BridgeSessionState.idle);
      await windDown(tester, controller);
    },
  );

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
    // said out loud as a toast, not swallowed.
    expect(controller.selectedScenario, '正式文档');
    expect(find.byKey(const Key('session-error')), findsNothing);
    expect(controller.lastError, '切换失败');
    expect(textOf(tester, const Key('sr-toast')), '切换失败');
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

  testWidgets('a hidden orb renders nothing at rest, and persists', (
    tester,
  ) async {
    // Sync IO: async dart:io futures never complete inside the widget-test
    // zone on this host (WSL quirk, probed and confirmed).
    final dir = Directory.systemTemp.createTempSync('sr-ui-prefs-widget-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final gateway = FakeGateway();
    final controller = SpeechController(
      gateway: gateway,
      scriptedPhrases: const [],
      themeMode: ThemeMode.dark,
      uiPrefsDirs: [dir.path],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      SpokenRectifierApp(controller: controller, stageWindow: null),
    );

    await controller.setOrbVisible(false);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
    // The toggle persisted at once (the read/write loop).
    expect(
      File('${dir.path}/$uiPrefsFile').readAsStringSync(),
      'orb_visible = false\n',
    );
    // A restart reads the same file back.
    expect(loadUiOrbVisible([dir.path]), isFalse);
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
      expect(find.text('术语'), findsOneWidget);
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
      // Same ceiling as the session window (ADR 0017), corner still
      // pinned; the card renders in the slot at the shared footprint.
      expect(window.bounds.last.size, const Size(1096, 596));
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

    // 打开设置 lands on 通用, the sidebar's first domain — the same
    // target unknown domain names fall back to.
    expect(opened, [
      SettingsDomain.scenarios,
      SettingsDomain.history,
      SettingsDomain.general,
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
      expect(find.byKey(const Key('quick-global-preview')), findsOneWidget);
    },
  );

  testWidgets(
    'the preview row shows with an empty library, hides while unset',
    (tester) async {
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
    },
  );

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
              find.byKey(
                const Key('quick-history-scenario-item-builtin-default'),
              ),
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
    await controller.rerectifyHistory('旧话', style: const DefaultRegisterPick());
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

      expect(controller.lastError, '重新修正失败');
      expect(textOf(tester, const Key('sr-toast')), '重新修正失败');
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
      expect(controller.lastError, '切换失败');
      expect(textOf(tester, const Key('sr-toast')), '切换失败');
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
    // session window (修正≡预览同形). The window stays at its ceiling
    // (ADR 0017); the CARD keeps its footprint — the pushed hit rect.
    expect(window.bounds, hasLength(1));
    expect(window.bounds.last, const Rect.fromLTRB(0, 0, 1096, 596));
    expect(window.regions.last, const Rect.fromLTRB(676, 36, 1096, 596));
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

  // -- ticket 20: orb drag, panel move, resize, persistence ---------------

  group('geometry gestures', () {
    /// Pumps the shell with a recording window and a scratch prefs dir
    /// (the gestures persist synchronously — same sync-IO note as the
    /// theme test above). One extra pump primes the stage host's
    /// geometry cache before any gesture runs.
    Future<SpeechController> pumpGeometry(
      WidgetTester tester, {
      required RecordingStageWindow window,
      required Directory dir,
    }) async {
      final controller = SpeechController(
        gateway: FakeGateway(),
        scriptedPhrases: const [],
        uiPrefsDirs: [dir.path],
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        SpokenRectifierApp(controller: controller, stageWindow: window),
      );
      await tester.pump();
      return controller;
    }

    Directory scratch() {
      final d = Directory.systemTemp.createTempSync('sr-geo-widget-');
      addTearDown(() => d.deleteSync(recursive: true));
      return d;
    }

    testWidgets(
      'an idle drag tracks the screen cursor 1:1, not the view-relative delta',
      (tester) async {
        // Production: PointerEvent.position is view-relative, so moving the
        // window under a still mouse shrinks the next delta (often ~half)
        // and can reverse it — the orb lags and flickers. The host must
        // follow pointerOnScreen (GetCursorPos) instead.
        final window = RecordingStageWindow();
        // Down is on the ball center: default window (1000, 500) + inset.
        var screen = const Offset(1048, 548);
        window.screenPointer = () => screen;
        final dir = scratch();
        await pumpGeometry(tester, window: window, dir: dir);

        final center = tester.getCenter(find.byIcon(Icons.mic_none_rounded));
        final g = await tester.startGesture(center);
        // Arming move: screen and view still agree (window has not jumped).
        screen = const Offset(1048 + 20, 548);
        await g.moveBy(const Offset(20, 0));
        // Production shrink: the window already chased ~half the pointer,
        // so the view-relative event is only +40 while the mouse moved +80.
        screen = const Offset(1048 + 100, 548);
        await g.moveBy(const Offset(40, 0));
        await g.up();
        await tester.pump();

        // 1:1 with the screen cursor: anchor 1148 → footprint origin 1100.
        expect(window.position, const Offset(1100, 500));
        expect(window.size, SrGeometry.orbFootprint);
      },
    );

    testWidgets('in-flight setBounds coalesces; the window never jumps back', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      window.setBoundsDelay = const Duration(milliseconds: 40);
      var screen = const Offset(1048, 548);
      window.screenPointer = () => screen;
      final dir = scratch();
      await pumpGeometry(tester, window: window, dir: dir);

      final center = tester.getCenter(find.byIcon(Icons.mic_none_rounded));
      final g = await tester.startGesture(center);
      screen = const Offset(1048 + 20, 548);
      await g.moveBy(const Offset(20, 0));
      screen = const Offset(1048 + 60, 548);
      await g.moveBy(const Offset(8, 0));
      screen = const Offset(1048 + 100, 548);
      await g.moveBy(const Offset(8, 0));
      await tester.pump(const Duration(milliseconds: 160));
      await g.up();
      await tester.pump(const Duration(milliseconds: 80));

      expect(window.position, const Offset(1100, 500));
      final xs = window.bounds.map((b) => b.left).toList();
      for (var i = 1; i < xs.length; i++) {
        expect(
          xs[i],
          greaterThanOrEqualTo(xs[i - 1]),
          reason: 'a late setBounds must not pull the orb backwards ($xs)',
        );
      }
    });

    testWidgets('an idle drag moves the orb clamped and persists the anchor', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);

      final center = tester.getCenter(find.byIcon(Icons.mic_none_rounded));
      final g = await tester.startGesture(center);
      await g.moveBy(const Offset(20, 10)); // arms the drag (8px slop)
      await g.moveBy(const Offset(15, 5));
      await g.up();
      await tester.pump();

      // Anchor (1048, 548) -> (1083, 563): the orb footprint follows,
      // still orb-shaped.
      expect(window.size, SrGeometry.orbFootprint);
      expect(window.position, const Offset(1035, 515));
      // 松手即写: the anchor landed in the file at gesture end.
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('orb_position = [1083, 563]'),
      );
      expect(controller.orbAnchor, const Offset(1083, 563));
      expect(controller.phase, BridgeSessionState.idle);
    });

    testWidgets('a drag into the work-area edge lands flush, not past it', (
      tester,
    ) async {
      // Window near the bottom-right corner of the (0,0,1920,1080) area:
      // anchor (1898, 1048) is already past the flush limit (1872, 1032).
      final window = RecordingStageWindow(const Offset(1850, 1000));
      final dir = scratch();
      await pumpGeometry(tester, window: window, dir: dir);

      final center = tester.getCenter(find.byIcon(Icons.mic_none_rounded));
      final g = await tester.startGesture(center);
      await g.moveBy(const Offset(200, 200));
      await g.up();
      await tester.pump();

      // Flush: footprint exactly on the work-area corner.
      expect(window.position, const Offset(1824, 984));
      expect(window.bounds.last, Rect.fromLTRB(1824, 984, 1920, 1080));
    });

    testWidgets('a sub-threshold wiggle stays a click — the session starts', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);

      final center = tester.getCenter(find.byIcon(Icons.mic_none_rounded));
      final g = await tester.startGesture(center);
      await g.moveBy(const Offset(4, 3)); // inside the 8px slop
      await g.up();
      await tester.pump(const Duration(milliseconds: 350));

      expect(controller.phase, BridgeSessionState.recording);
      // The first (and so far only) bounds call is the panel expand to
      // its growth ceiling (ADR 0017) — no drag ever moved the orb
      // window, and no resize ran.
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1096, 596));
      await windDown(tester, controller);
    });

    testWidgets('dragging the header moves the whole window, orb riding', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpQuickOpen(tester, controller);

      // Ceiling window at the default anchor (1048, 548): LTRB
      // (0, 0, 1096, 596) (ADR 0017). Drag the header row by (30, -20).
      final header = tester.getCenter(find.text('快捷设置'));
      final g = await tester.startGesture(header);
      await g.moveBy(const Offset(30, -20));
      await g.up();
      await tester.pump();

      expect(window.bounds.last, Rect.fromLTRB(30, 0, 1126, 596));
      // The new anchor persisted (球的新位置成为新锚点).
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('orb_position = [1078, 548]'),
      );
      // The orb anchor button moved with the window and stayed socketed:
      // closing collapses onto the same anchor.
      controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 350));
      expect(window.position, const Offset(1030, 500));
      expect(window.size, SrGeometry.orbFootprint);
    });

    testWidgets('the corner handle grows the panel away from the orb', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpQuickOpen(tester, controller);

      // Default upLeft: the free corner is the panel's top-left. Drag
      // it out by (60, 80) — the anchor corner (1096, 596) must not
      // move. Height fit-caps at anchor.dy + 48 = 596 (70% of 1080 is
      // looser), so 560 + 80 → 596; width 420 + 60 = 480 fits.
      final corner = tester.getCenter(
        find.byKey(const Key('panel-resize-corner')),
      );
      final g = await tester.startGesture(corner);
      await g.moveBy(const Offset(-60, -80));
      await g.up();
      await tester.pump();

      // The window never moved (ADR 0017): the card's new size lives in
      // the controller and the pushed hit-through region.
      expect(window.bounds, hasLength(1));
      expect(controller.panelFootprint, const Size(480, 596));
      expect(window.regions.last, const Rect.fromLTRB(616, 0, 1096, 596));
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('panel_size = [480, 596]'),
      );
      // The shared footprint: the next open (after a close) keeps it.
      controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 350));
      controller.orbSecondary();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      expect(window.regions.last, const Rect.fromLTRB(616, 0, 1096, 596));
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 350));
    });

    testWidgets('the resize floor holds: shrinking stops at 360x440', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpQuickOpen(tester, controller);

      // Drag the corner handle toward the orb by (100, 100): intent
      // 320x460, the floor holds the width at 360 (height 460 passes).
      final corner = tester.getCenter(
        find.byKey(const Key('panel-resize-corner')),
      );
      final g = await tester.startGesture(corner);
      await g.moveBy(const Offset(100, 100));
      await g.up();
      await tester.pump();

      expect(window.bounds, hasLength(1)); // zero HWND churn (ADR 0017)
      expect(controller.panelFootprint, const Size(360, 460));
      expect(window.regions.last, const Rect.fromLTRB(736, 136, 1096, 596));
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 350));
    });

    testWidgets(
      'a resize gesture never touches the HWND (the window sits at its ceiling)',
      (tester) async {
        // ADR 0017: the expand already jumped the window to the growth
        // ceiling, so a resize is pure Flutter layout — zero setBounds
        // across the whole gesture. A mid-gesture HWND size change
        // flashes even as a single jump: the stale child surface
        // composites top-left-aligned for one DWM frame when the engine
        // loses the present race (probe evidence, report section 0.1).
        final window = RecordingStageWindow();
        final dir = scratch();
        final controller = await pumpGeometry(tester, window: window, dir: dir);
        await pumpQuickOpen(tester, controller);
        expect(window.bounds, hasLength(1)); // the expand jump only
        // The ceiling at this anchor (1048, 548): the anchor's own span
        // (1096x596) caps tighter than the 70% of 1920x1080.
        expect(window.bounds.last, Rect.fromLTRB(0, 0, 1096, 596));

        final corner = tester.getCenter(
          find.byKey(const Key('panel-resize-corner')),
        );
        final g = await tester.startGesture(corner);
        await tester.pump();
        await g.moveBy(const Offset(-60, -80));
        await tester.pump();
        await g.moveBy(const Offset(-30, 0));
        await tester.pump();
        await g.up();
        await tester.pump();

        // Zero bounds calls for the whole gesture...
        expect(window.bounds, hasLength(1));
        expect(controller.panelFootprint, const Size(510, 596));
        // ...the card itself took the growth inside the ceiling window.
        expect(tester.getSize(find.byType(QuickPanel)), const Size(510, 596));
        // The hit-through region caught up to the final slot.
        expect(window.regions.last, Rect.fromLTRB(586, 0, 1096, 596));
        await controller.closeQuick();
        await tester.pump(const Duration(milliseconds: 350));
        // Back to the orb: whole-window hit testing again.
        expect(window.regions.last, isNull);
      },
    );

    testWidgets('a resize gesture does not rebuild the panel (layout only)', (
      tester,
    ) async {
      // H3: StageHost.setState on every pointer move rebuilt QuickPanel /
      // SessionPanel (and SlotSurface re-measured) even though the HWND is
      // frozen. The slot's Positioned is the only thing that should update.
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpQuickOpen(tester, controller);

      final before = tester.widget(find.byType(QuickPanel));
      final corner = tester.getCenter(
        find.byKey(const Key('panel-resize-corner')),
      );
      final g = await tester.startGesture(corner);
      await tester.pump();
      await g.moveBy(const Offset(-60, -80));
      await tester.pump();
      await g.moveBy(const Offset(-30, 0));
      await tester.pump();

      expect(
        identical(tester.widget(find.byType(QuickPanel)), before),
        isTrue,
        reason:
            'resize must not rebuild the panel; only the slot Positioned moves',
      );
      expect(tester.getSize(find.byType(QuickPanel)), const Size(510, 596));
      await g.up();
      await tester.pump();
      expect(identical(tester.widget(find.byType(QuickPanel)), before), isTrue);
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 350));
    });

    testWidgets('a resize during a session does not rebuild SessionPanel', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await controller.startSession();
      await tester.pump(const Duration(milliseconds: 350));

      final before = tester.widget(find.byType(SessionPanel));
      final corner = tester.getCenter(
        find.byKey(const Key('panel-resize-corner')),
      );
      final g = await tester.startGesture(corner);
      await tester.pump();
      await g.moveBy(const Offset(-40, 0));
      await tester.pump();

      expect(
        identical(tester.widget(find.byType(SessionPanel)), before),
        isTrue,
        reason: 'session-panel rebuild is the SlotSurface remeasure tax',
      );
      await g.up();
      await tester.pump();
      await windDown(tester, controller);
    });

    testWidgets('the expand direction follows the anchor\'s quadrant', (
      tester,
    ) async {
      // Each quadrant opens once: the window grows away from the ball
      // (ticket checklist, widget-level) and the orb mirrors to the
      // growth corner. Anchors sit flush inside the (0,0,1920,1080)
      // area, as a clamped drag would leave them. ADR 0017: the jump
      // lands at the growth CEILING, so each rect below is the ceiling
      // (70% of the work area caps below the anchor's span on the roomy
      // axes: 1344x756).
      for (final (pos, expectRect, expectOrbAtOrigin) in [
        // Bottom-right anchor (default): grows up-left, orb bottom-right.
        (Offset(1824, 936), Rect.fromLTRB(576, 276, 1920, 1032), false),
        // Bottom-left: grows up-right.
        (Offset(30, 936), Rect.fromLTRB(30, 276, 1374, 1032), false),
        // Top-left: grows down-right, orb mirrors to the top-left corner.
        (Offset(30, 40), Rect.fromLTRB(30, 40, 1374, 796), true),
        // Top-right: grows down-left, orb mirrors up.
        (Offset(1824, 40), Rect.fromLTRB(576, 40, 1920, 796), true),
      ]) {
        final window = RecordingStageWindow(pos);
        final dir = scratch();
        final controller = await pumpGeometry(tester, window: window, dir: dir);
        await pumpQuickOpen(tester, controller);

        expect(window.bounds.last, expectRect, reason: 'anchor at $pos');
        // The orb sockets into the corner the panel grew from: at the
        // stack's origin only for the two top-corner anchors.
        final orbTopLeft = tester.getTopLeft(find.byType(OrbButton));
        expect(
          orbTopLeft.dy,
          expectOrbAtOrigin ? 0 : greaterThan(0),
          reason: 'anchor at $pos',
        );
        await controller.closeQuick();
        await tester.pump(const Duration(milliseconds: 350));
      }
    });
  });

  // -- ticket 29: the four-way panel chrome contract ------------------------

  group('four-way panel chrome contract', () {
    /// The orb's VISIBLE extent: the ball core, radially inflated by the
    /// recording ring's reach when one paints. The contract's reserve
    /// math (header 56 / footer 48) deliberately lands content a few px
    /// inside the 96px footprint's transparent bleed ring — what chrome
    /// must never touch is the ball itself (plus its ring on the
    /// recording header row).
    Rect orbCoreInView(WidgetTester tester, {double inflate = 0}) {
      final foot = tester.getRect(find.byType(OrbButton));
      return Rect.fromCenter(
        center: foot.center,
        width: SrGeometry.orbBall + inflate * 2,
        height: SrGeometry.orbBall + inflate * 2,
      );
    }

    void expectClearOfOrb(
      WidgetTester tester,
      Finder finder,
      Rect orb,
      String what,
    ) {
      // Rect.intersect does NOT return Rect.zero for disjoint rects —
      // it clamps each edge independently and yields a degenerate
      // (left > right) rect; emptiness is the disjointness test.
      expect(
        tester.getRect(finder).intersect(orb).isEmpty,
        isTrue,
        reason:
            '$what must stay clear of the orb core $orb '
            '(found at ${tester.getRect(finder)})',
      );
    }

    /// Pumps the shell with the orb anchored in [dir]'s quadrant of the
    /// default (0,0,1920,1080) work area, so the first expand grows that
    /// way (the direction is derived at expand, ticket 20).
    Future<SpeechController> pumpAtQuadrant(
      WidgetTester tester, {
      required stage.GrowthDirection dir,
      FakeGateway? gateway,
    }) async {
      final anchor = switch (dir) {
        stage.GrowthDirection.upLeft => const Offset(1500, 900),
        stage.GrowthDirection.upRight => const Offset(400, 900),
        stage.GrowthDirection.downLeft => const Offset(1500, 200),
        stage.GrowthDirection.downRight => const Offset(400, 200),
      };
      final window = RecordingStageWindow(anchor - const Offset(48, 48));
      final controller = await pumpController(
        tester,
        gateway ?? FakeGateway(),
        stageWindow: window,
      );
      if (gateway != null) {
        await controller.loadScenarios();
        await tester.pump();
      }
      return controller;
    }

    for (final dir in stage.GrowthDirection.values) {
      testWidgets('session chrome clears the orb (${dir.name})', (
        tester,
      ) async {
        // The scenario chip needs a library; the recording header is the
        // worst case (phase word + timer + chip + ring-bearing ball).
        final gateway = FakeGateway()
          ..scenarioLibrary.add(
            const BridgeScenario(name: '正式文档', directive: '正式书面语体'),
          );
        final controller = await pumpAtQuadrant(
          tester,
          dir: dir,
          gateway: gateway,
        );
        await pumpToRecording(tester, controller);

        // The header row: the ring can be at full glow, so the guard is
        // the ring's reach (ball + 6), not the bare core.
        final orb = orbCoreInView(tester, inflate: 6);
        expectClearOfOrb(tester, find.text('聆听中'), orb, 'the phase word');
        expectClearOfOrb(
          tester,
          find.byKey(const Key('scenario-chip')),
          orb,
          'the scenario chip',
        );
        // The body's fade + padding pair rides the anchor's edge only
        // (义务随锚点角走): top pair exactly while the orb shares the
        // header row, never while it sits on the footer's edge.
        expect(
          find.byKey(const Key('session-top-fade')),
          dir.growUp ? findsNothing : findsOneWidget,
        );
        if (!dir.growUp) {
          // At rest the first body line (the placeholder paints while
          // nothing is dictated) must sit below the fade's lower edge,
          // clear of the ball.
          expectClearOfOrb(
            tester,
            find.text('开始说话…'),
            orbCoreInView(tester),
            'the body\'s first line',
          );
        }
        await windDown(tester, controller);
      });

      testWidgets('session footer clears the orb (${dir.name})', (
        tester,
      ) async {
        final gateway = FakeGateway();
        final controller = await pumpAtQuadrant(
          tester,
          dir: dir,
          gateway: gateway,
        );
        await pumpToPreview(tester, controller, gateway);

        // Preview is the widest footer (three capsules); no ring paints
        // outside recording, so the bare core is the guard.
        final orb = orbCoreInView(tester);
        for (final key in [
          const Key('session-raw-toggle'),
          const Key('session-reroll'),
          const Key('session-cancel'),
        ]) {
          expectClearOfOrb(tester, find.byKey(key), orb, 'the footer ($key)');
        }
        // 钮序四向冻结: 对照原文 → 重新生成 → 取消, whatever side the
        // group hugs.
        final raw = tester.getRect(find.byKey(const Key('session-raw-toggle')));
        final reroll = tester.getRect(find.byKey(const Key('session-reroll')));
        final cancel = tester.getRect(find.byKey(const Key('session-cancel')));
        expect(raw.left, lessThan(reroll.left));
        expect(reroll.left, lessThan(cancel.left));

        // 仅左底栏钮组右对齐: the orb holds the row's start there, so the
        // group yields to the far side — flush with the card's inner
        // right edge. Every other quadrant hugs the row's start corner
        // inset instead. Both measured against the CARD (the slot pins
        // it to the anchor corner of the 800x600 view, wherever that is).
        final slot = tester.getRect(find.byType(SessionPanel));
        final rowStart =
            slot.left + SrGeometry.cardMargin + SrSpace.cornerInset;
        final rowEnd = slot.right - SrGeometry.cardMargin - SrSpace.cornerInset;
        if (dir == stage.GrowthDirection.upRight) {
          expect(cancel.right, closeTo(rowEnd, 1), reason: '左下右对齐');
        } else {
          expect(raw.left, closeTo(rowStart, 1), reason: 'row-start aligned');
        }
        await windDown(tester, controller);
      });

      testWidgets('quick panel chrome clears the orb (${dir.name})', (
        tester,
      ) async {
        final controller = await pumpAtQuadrant(tester, dir: dir);
        await pumpQuickOpen(tester, controller);

        // The idle orb (✕) paints no ring: the bare core is the guard.
        final orb = orbCoreInView(tester);
        expectClearOfOrb(tester, find.text('快捷设置'), orb, 'the title');
        // The list's head content: while the orb anchors the top edge,
        // the 48 padding parks the first section below the fade.
        if (!dir.growUp) {
          expectClearOfOrb(
            tester,
            find.text('场景'),
            orb,
            'the first section label',
          );
        }
        // The fades ride the anchor's edge only, at the contract's
        // heights (bottom 96 = 2x anchorInset, top 48 = 1x).
        expect(
          find.byKey(const Key('quick-bottom-fade')),
          dir.growUp ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('quick-top-fade')),
          dir.growUp ? findsNothing : findsOneWidget,
        );
        await controller.closeQuick();
        await tester.pump(const Duration(milliseconds: 350));
      });
    }
  });
}

String textOf(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data!;
