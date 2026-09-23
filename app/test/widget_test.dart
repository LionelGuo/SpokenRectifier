/// Widget tests for the shell: the orb-position surfaces (orb, session
/// window, quick panel placeholder) and the window choreography ride a
/// pure-Dart fake gateway and a recording stage window — no Rust dylib,
/// no platform channels.

library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryButton, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart';
import 'package:spokenrectifier_app/src/preview/slot_surface.dart';
import 'package:spokenrectifier_app/src/rust/api/engine.dart'
    show BridgeEvent,
        BridgePlaceholderFill,
        BridgePrefillRow,
        BridgeSessionState;
import 'package:spokenrectifier_app/src/rust/api/history.dart'
    show BridgeHistoryEntry;
import 'package:spokenrectifier_app/src/rust/api/library.dart'
    show BridgeScenario;
import 'package:spokenrectifier_app/src/settings/rectify_store.dart';
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
    show GrowthDirection, GrowthDirectionX, StageWindow, WorkAreas;
import 'package:spokenrectifier_app/ui_prefs.dart';

import 'fake_gateway.dart';
import 'fake_rectify_store.dart';

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

/// A stage window that records every seating and region push, so tests
/// can assert the choreography (the permanent work-area window is
/// seated once at startup — in PHYSICAL pixels, 17 号票; expand/collapse
/// ride regions only, ADR-0022) without platform channels.
class RecordingStageWindow implements stage.StageWindow {
  RecordingStageWindow([this.position = const Offset(1000, 500)]);

  Offset position;
  Size size = SrGeometry.orbFootprint;

  /// The PHYSICAL rects every seating commanded (the OS move's own
  /// units — a mixed-DPI test distinguishes them from the logical list).
  final bounds = <Rect>[];

  /// The work areas the expand chooser and the clamps see; tests pin it
  /// to place the orb in a quadrant or squeeze a fit. (Named `screens` —
  /// a field cannot share the interface method's name.) The physical
  /// twins default to the same rects (dpr-1 world); a mixed-DPI test
  /// pins [screensPhysical], and [screenFactors] feeds the persisted
  /// anchor's revival.
  List<Rect> screens = const [Rect.fromLTWH(0, 0, 1920, 1080)];
  List<Rect> screensPhysical = const [];
  List<double> screenFactors = const [];

  /// The landed rect a seating reports (the post-move truth the host
  /// adopts, 17 号票 — production derives it from the post-move dpr).
  /// Null → the physical rect itself (the dpr-1 identity).
  Rect? Function(Rect physical)? landedFor;

  /// How many times the window was asked to take the foreground.
  int focuses = 0;

  /// The window regions pushed while panels open (ADR 0017 ceiling
  /// window; the region hugs the card slot, null = the whole window --
  /// the orb stage and a live resize whose card must paint unclipped).
  /// LOGICAL window coordinates since 17 号票.
  final regions = <Rect?>[];

  stage.WorkAreas get _areas => stage.WorkAreas(
    logical: screens,
    physical: screensPhysical.isEmpty ? screens : screensPhysical,
    factors: screenFactors,
  );

  @override
  Future<Offset> getPosition() async => position;

  @override
  Future<Size> getSize() async => size;

  @override
  Future<Rect> seatBoundsPhysical(Rect physical) async {
    bounds.add(physical);
    final landed = landedFor?.call(physical) ?? physical;
    position = landed.topLeft;
    size = landed.size;
    return landed;
  }

  @override
  Future<void> setCardRegion(Rect? windowRect) async => regions.add(windowRect);

  @override
  Future<stage.WorkAreas> workAreas() async => _areas;

  /// When set, the host tracks this as the screen cursor (production
  /// path). Null keeps the test-view's `PointerEvent.position` as the
  /// screen-stable stand-in — a seating never moves the test view.
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
  FakeRectifyBehaviorStore? rectifyStore,
}) async {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
    themeMode: themeMode,
  );
  addTearDown(controller.dispose);
  if (stageWindow != null) {
    // The panel-period window is the whole work area (02 号票) — pin the
    // view to it so view coordinates match window coordinates.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    SpokenRectifierApp(
      controller: controller,
      stageWindow: stageWindow,
      onOpenSettings: onOpenSettings,
      rectifyStore: rectifyStore ?? FakeRectifyBehaviorStore(),
    ),
  );
  return controller;
}

/// The panel's own vertical list scrollable — the term field's inline
/// horizontal Scrollable must never match a panel drag.
Finder panelScrollable() => find.byWidgetPredicate(
  (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
);

/// A rectify switch row's inner Switch — the row key sits on the row
/// itself and the row's center is empty space (the label-Spacer-switch
/// layout), so taps and value reads must target the Switch inside.
Finder rowSwitch(String key) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(Switch));

Future<void> pumpToRecording(
  WidgetTester tester,
  SpeechController controller,
) async {
  await controller.startSession();
  // Past the grow choreography (SrMotion.grow): the panel mounts on
  // the FIRST frame (its controller's clock starts at zero there), so
  // the clock must advance on a SECOND frame before interactions can
  // tap the card at rest.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

/// Ends whatever session is running and pumps past every trailing span
/// (mic breath, the 670 ms collapse choreography, the 900 ms receipt
/// flash) so the test closes with zero pending timers — the test
/// framework checks invariants before teardown disposals.
Future<void> windDown(WidgetTester tester, SpeechController controller) async {
  if (controller.phase != BridgeSessionState.idle) {
    await controller.cancelSession();
  }
  await tester.pump(const Duration(milliseconds: 1700));
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

    // The window sits on the WHOLE WORK AREA (ADR-0022: seated once at
    // startup, hidden — expand and collapse never touch the HWND); the
    // card renders in the slot at its anchor-derived rect (420x540 —
    // the height caps at half the 1080 work area), hit region narrowed
    // to it (ADR 0017).
    expect(window.bounds, [const Rect.fromLTRB(0, 0, 1920, 1080)]);
    expect(window.regions.last, const Rect.fromLTRB(676, 56, 1096, 596));

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
    await tester.pump(const Duration(milliseconds: 700));

    expect(gateway.commands, contains('confirmInsert'));
    expect(controller.phase, BridgeSessionState.idle);

    // Collapse: after the grow-back the region narrowed to the orb
    // footprint — the window itself NEVER changed (ADR-0022: no size
    // change, no present race, no ghost).
    expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
    expect(window.regions.last, const Rect.fromLTRB(1000, 500, 1096, 596));
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
    'the footer folds to circles at the resize floor — no overflow stripe',
    (tester) async {
      // 13 号票: 小修 10's permanent hard clip is retired — at the floor
      // the group crosses the guard line and morphs to icon-only circles
      // instead. The buttons stay mounted and tappable; the labels fold
      // away (they live on in the circle state's tooltip).
      tester.view.physicalSize = SrGeometry.panelMinSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final gateway = FakeGateway();
      final controller = await pumpController(tester, gateway);
      await pumpToPreview(tester, controller, gateway);
      // The preview entry swaps the recording set for the wide three —
      // the flip starts at that frame's end and lands on [SrMotion
      // .emphasize]; a frame to arm the ticker, then the flight.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      // The resting state is the circle: every button as wide as it is
      // tall (the height ≈29 is the diameter), labels unmounted.
      expect(find.text('对照原文'), findsNothing);
      expect(find.text('重新生成'), findsNothing);
      expect(find.text('取消'), findsNothing);
      for (final key in [
        const Key('session-raw-toggle'),
        const Key('session-reroll'),
        const Key('session-cancel'),
      ]) {
        expect(find.byKey(key), findsOneWidget);
        final size = tester.getSize(find.byKey(key));
        expect(size.width, closeTo(size.height, 0.5));
      }
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
    // A pin-less confirm carries an empty slot table.
    expect(gateway.lastPlaceholderFills, isEmpty);
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

  testWidgets('the confirm rides the slot table to the store (占位符钉入入库)', (
    tester,
  ) async {
    // A pinned session's confirm carries one row per live slot —
    // number, prefill, and the value actually substituted — beside
    // the insert; the store writes them as placeholders rows.
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

    // Step into the capsule (the same outside-0 → outside-1 →
    // outside-left dock walk) and type, so the confirmed value is an
    // edited one — not just the prefill echoing back.
    for (final _ in '123'.split('')) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await typeAtCaret(tester, '李');
    await controller.hotkeyToggle();
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.lastPlaceholderFills, const [
      BridgePlaceholderFill(number: 1, prefill: '张三', value: '李张三'),
    ]);
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

  testWidgets('long text fills the whole body — no half-card blank', (
    tester,
  ) async {
    // The raw fold used to be the body column's loose-flexible sibling,
    // and the flex economy splits by SHARES: the Expanded text area was
    // hard-clamped to its half of the column, so long text only ever
    // showed in the card's upper half with bare surface below (latent
    // since the 15/16 号票 shell; surfaced on device once sessions grew
    // long text). The fold is a pinned chrome band now — the body is
    // the true remainder.
    final gateway = FakeGateway();
    final window = RecordingStageWindow();
    final controller = await pumpController(
      tester,
      gateway,
      stageWindow: window,
    );
    await pumpToRecording(tester, controller);

    gateway.emit(
      BridgeEvent.liveTranscriptUpdated(
        text: List<String>.filled(30, '这是一行比较长的转写文本\n').join(),
      ),
    );
    await tester.pump();

    // The stream viewport spans the body slot's FULL height (小修 13
    // 修订: the vertical padding rides INSIDE the scroll, so scrolling
    // text actually crosses the edge fades — an outer Padding would
    // pin the clip line at the padding's edge and leave the fades
    // painting over clipped-out dead space), down to the footer's band.
    final footerTop = tester
        .getTopLeft(find.byKey(const Key('panel-chrome-footer')))
        .dy;
    final headerBottom = tester
        .getBottomRight(find.byKey(const Key('panel-chrome-header')))
        .dy;
    final streamViewport = tester.getRect(
      find
          .ancestor(
            of: find.byKey(const Key('session-stream')).last,
            matching: panelScrollable(),
          )
          .first,
    );
    expect(
      streamViewport.top,
      closeTo(headerBottom, 1),
      reason:
          'the viewport tops out at the header band — the top pad '
          'is in-scroll, not a clip inset',
    );
    expect(
      streamViewport.bottom,
      closeTo(footerTop, 1),
      reason: 'the body is the true remainder above the footer',
    );
    expect(streamViewport.height, greaterThan(350));

    // The OPEN fold caps itself at its 140 box and the text yields
    // exactly its height — the band, not a flex share.
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['修正后的正文']);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const Key('session-raw-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final raw = tester.getRect(find.byKey(const Key('session-raw')));
    expect(
      raw.height,
      allOf(greaterThan(50), lessThanOrEqualTo(140)),
      reason: 'the fold sizes within its capped box',
    );
    expect(
      raw.bottom,
      closeTo(footerTop, 1),
      reason: 'the band sits flush above the footer band',
    );
    await windDown(tester, controller);
  });

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
      SpokenRectifierApp(
        controller: controller,
        stageWindow: null,
        rectifyStore: FakeRectifyBehaviorStore(),
      ),
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(controller.stage, StageKind.quick);
      expect(find.text('快捷设置'), findsOneWidget);
      // The sections paint: terms, the three rectify tiers, theme. The
      // scenario picker row hides with an empty library, but the
      // section keeps its editor entry (the creation path into the
      // settings window); history shows its empty hint. The 输入
      // (passage) section is gone — the settings window's 高级 domain
      // is the switch's one home now.
      expect(find.text('术语速加'), findsOneWidget);
      expect(find.text('历史'), findsOneWidget);
      expect(find.byKey(const Key('quick-history-empty')), findsOneWidget);
      expect(find.text('场景'), findsOneWidget);
      expect(
        find.byKey(const Key('quick-open-settings:scenarios')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('quick-scenario-default')), findsNothing);
      expect(find.text('输入'), findsNothing);
      expect(find.byKey(const Key('quick-passage')), findsNothing);
      // The rectify mirror sits below the fold of the scrollable list:
      // scroll each tier into view before asserting it.
      await tester.dragUntilVisible(
        find.text('全量修正模式'),
        panelScrollable(),
        const Offset(0, -40),
      );
      expect(find.text('全量修正模式'), findsOneWidget);
      expect(
        find.byKey(const Key('quick-rectify-full-prefill')),
        findsOneWidget,
      );
      expect(find.text('开启思考'), findsOneWidget); // the panel copy
      await tester.dragUntilVisible(
        find.text('快速模式'),
        panelScrollable(),
        const Offset(0, -40),
      );
      expect(find.text('轻修模式'), findsOneWidget);
      expect(find.text('快速模式'), findsOneWidget);
      expect(find.text('外观'), findsOneWidget);
      // The anchor-zone bottom fade is part of the panel's shape.
      expect(find.byKey(const Key('quick-bottom-fade')), findsOneWidget);
      // Opening refreshed the panel's lists.
      expect(gateway.commands, containsAll(['termsList', 'historyList']));
      // Same work-area window as the session window (02 号票/ADR 0017);
      // the card renders in the slot at the shared footprint.
      expect(window.bounds.last.size, const Size(1920, 1080));
      // The quick panel's Esc-to-close affordance needs the keyboard too.
      expect(window.focuses, greaterThanOrEqualTo(1));
      // The orb is now the close button.
      expect(find.byIcon(Icons.close), findsOneWidget);

      // The orb-as-close collapses back — the window NEVER shrank, the
      // region narrowed to the orb footprint (ADR-0022) — and hands the
      // keyboard back to the remembered target (挂账 from ticket 15).
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(milliseconds: 700));
      expect(controller.stage, StageKind.orb);
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions.last, const Rect.fromLTRB(1000, 500, 1096, 596));
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
    await tester.pump(const Duration(milliseconds: 700));

    expect(controller.stage, StageKind.orb);
    expect(gateway.commands, isNot(contains('cancelSession')));
    expect(controller.phase, BridgeSessionState.idle);
  });

  testWidgets(
    'the management entries collapse the panel into the settings window',
    (tester) async {
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

      // 小修 17: every entry row OPENS the settings window AND collapses
      // the panel — the click's destination is the settings window, so the
      // collapse is quiet: no foreground hand-back to the insertion target
      // racing the window the user just asked for.
      Future<void> openPanelAndTap(Finder entry) async {
        await tester.tap(
          find.byIcon(Icons.mic_none_rounded),
          buttons: kSecondaryButton,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        await tester.tap(entry);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(controller.stage, StageKind.orb, reason: 'the panel collapsed');
      }

      await openPanelAndTap(
        find.byKey(const Key('quick-open-settings:scenarios')),
      );
      await openPanelAndTap(
        find.byKey(const Key('quick-open-settings:history')),
      );

      // The 设置入口 row sits below the fold of the grown list; scroll it
      // into view before the tap.
      await tester.tap(
        find.byIcon(Icons.mic_none_rounded),
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.dragUntilVisible(
        find.byKey(const Key('quick-open-settings:general')),
        panelScrollable(),
        const Offset(0, -40),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quick-open-settings:general')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(controller.stage, StageKind.orb, reason: 'the panel collapsed');

      // 打开设置 lands on 通用, the sidebar's first domain — the same
      // target unknown domain names fall back to.
      expect(opened, [
        SettingsDomain.scenarios,
        SettingsDomain.history,
        SettingsDomain.general,
      ]);
      // The settings-open collapse restores the foreground to NOTHING:
      // the settings window claims it, never the remembered insertion
      // target.
      expect(gateway.commands, isNot(contains('restoreFocus')));
    },
  );

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

  /// Opens the quick panel and lets the refreshed lists land — past the
  /// grow choreography (SrMotion.grow) so hovers and taps hit the card
  /// at rest (the panel mounts on the first frame; the clock advances
  /// on the second, so 700ms there completes the 640ms growth).
  Future<void> pumpQuickOpen(WidgetTester tester, SpeechController c) async {
    c.orbSecondary();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 700));
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
    await tester.pump(const Duration(milliseconds: 700));
    expect(opened, [SettingsDomain.scenarios]);
    // 小修 17: the jump's destination is the settings window — the
    // panel collapses behind it (quietly; no restoreFocus fires).
    expect(controller.stage, StageKind.orb);
    expect(gateway.commands, isNot(contains('restoreFocus')));
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

  testWidgets('the rectify chips carry the panel copy, not the settings one', (
    tester,
  ) async {
    final controller = await pumpController(tester, FakeGateway());
    await pumpQuickOpen(tester, controller);

    // Rounds 3+4: bare chips (no 思考策略 field label), panel-side copy
    // 开启思考 / 仅含占位图钉时思考 / 关闭思考 — the settings window's
    // 始终开启… wording never leaks in here, and no micro label reads
    // as another section title.
    await tester.dragUntilVisible(
      find.byKey(const Key('quick-rectify-full-policy:off')),
      panelScrollable(),
      const Offset(0, -40),
    );
    await tester.drag(panelScrollable(), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text('思考策略'), findsNothing);
    expect(find.text('始终开启'), findsNothing);
    expect(find.text('开启思考'), findsOneWidget);
    expect(find.text('仅含占位图钉时思考'), findsOneWidget);
    expect(find.text('关闭思考'), findsOneWidget);
  });

  testWidgets('a rectify point-select saves the whole model and adopts it', (
    tester,
  ) async {
    final store = FakeRectifyBehaviorStore();
    final controller = await pumpController(
      tester,
      FakeGateway(),
      rectifyStore: store,
    );
    await pumpQuickOpen(tester, controller);

    await tester.dragUntilVisible(
      find.byKey(const Key('quick-rectify-full-policy:off')),
      panelScrollable(),
      const Offset(0, -40),
    );
    await tester.tap(find.byKey(const Key('quick-rectify-full-policy:off')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Theme-caliber semantics: one tap writes the whole model with the
    // one field moved, and the save hands the files to the live engine
    // (the next rectify attempt — reroll included — runs it).
    expect(store.saves, hasLength(1));
    expect(store.saves.single.fullThinkingPolicy, 'off');
    expect(store.saves.single.fullPrefill, isTrue); // untouched fields ride
    expect(store.saves.single.lightTouchEnabled, isTrue);
    expect(store.applyCalls, 1);
    // The receipt repaints: the picked switch keeps painting the truth.
    expect(
      tester.widget<Switch>(rowSwitch('quick-rectify-full-prefill')).value,
      isTrue,
    );
  });

  testWidgets(
    'a point-select re-reads first — a concurrent settings edit survives',
    (tester) async {
      final store = FakeRectifyBehaviorStore();
      final controller = await pumpController(
        tester,
        FakeGateway(),
        rectifyStore: store,
      );
      await pumpQuickOpen(tester, controller);

      // A settings window open beside the panel commits its own edit
      // after this panel's load (channel (b): the pick must commit over
      // a FRESH read, never clobber the file with the stale snapshot).
      store.behavior = store.behavior.copyWith(
        lightTouchMaxChars: 99,
        quickExtraDirective: '只改错别字',
      );

      await tester.dragUntilVisible(
        find.byKey(const Key('quick-rectify-full-prefill')),
        panelScrollable(),
        const Offset(0, -40),
      );
      await tester.tap(rowSwitch('quick-rectify-full-prefill'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(store.saves.single.fullPrefill, isFalse); // the pick
      expect(store.saves.single.lightTouchMaxChars, 99); // the fresh read
      expect(store.saves.single.quickExtraDirective, '只改错别字');
    },
  );

  testWidgets('the §4.4 cascades disable in place, never hide', (tester) async {
    final store = FakeRectifyBehaviorStore();
    final controller = await pumpController(
      tester,
      FakeGateway(),
      rectifyStore: store,
    );
    await pumpQuickOpen(tester, controller);
    await tester.dragUntilVisible(
      find.byKey(const Key('quick-rectify-light-enabled')),
      panelScrollable(),
      const Offset(0, -40),
    );
    await tester.drag(panelScrollable(), const Offset(0, -120));
    await tester.pumpAndSettle();

    // 轻修 master off = the tail is disabled, not hidden: the rows
    // stay painted and swallow hits.
    await tester.tap(rowSwitch('quick-rectify-light-enabled'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byKey(const Key('quick-rectify-light-prefill')),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
    );
    final savesBefore = store.saves.length;
    await tester.tap(rowSwitch('quick-rectify-light-prefill'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(store.saves, hasLength(savesBefore)); // swallowed

    // 快速 master off (the file default) = the whole section's tail
    // is disabled the same way.
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byKey(const Key('quick-rectify-quick-rectify')),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
    );
    await tester.tap(rowSwitch('quick-rectify-quick-rectify'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(store.saves, hasLength(savesBefore));
  });

  testWidgets('an inert connection thinking state unselects both chip rows', (
    tester,
  ) async {
    final store = FakeRectifyBehaviorStore(
      const RectifyBehavior(
        fullThinkingPolicy: 'always',
        fullPrefill: true,
        lightTouchEnabled: true,
        lightTouchMaxChars: 40,
        lightTouchThinkingPolicy: 'always',
        lightTouchPrefill: true,
        connectionThinking: 'off',
      ),
    );
    final controller = await pumpController(
      tester,
      FakeGateway(),
      rectifyStore: store,
    );
    await pumpQuickOpen(tester, controller);
    await tester.dragUntilVisible(
      find.byKey(const Key('quick-rectify-full-policy:off')),
      panelScrollable(),
      const Offset(0, -40),
    );

    // §4.4 / ADR-0019 item 3: while the connection's thinking fields
    // are inert, both tiers' chips dim and swallow hits — recovery
    // lives in 模型与连接, nothing on this panel. (The dimmer/pointer
    // shield lives INSIDE the chip's build, so the probe reads the
    // chip's own AnimatedOpacity target.)
    expect(
      tester
          .widget<AnimatedOpacity>(
            find
                .descendant(
                  of: find.byKey(const Key('quick-rectify-full-policy:off')),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity,
      0.45,
    );
    await tester.tap(find.byKey(const Key('quick-rectify-full-policy:off')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(store.saves, isEmpty);
  });

  testWidgets(
    'the directive preview rows hide when unset and land on the rectify domain',
    (tester) async {
      final opened = <SettingsDomain>[];
      final controller = await pumpController(
        tester,
        FakeGateway(),
        // The default 800x600 test view is too small for the grown
        // list's deep rows (they land outside the root) — pin the
        // work-area view like the geometry tests.
        stageWindow: RecordingStageWindow(),
        onOpenSettings: opened.add,
        rectifyStore: FakeRectifyBehaviorStore(
          const RectifyBehavior(
            fullThinkingPolicy: 'always',
            fullPrefill: true,
            lightTouchEnabled: true,
            lightTouchMaxChars: 40,
            lightTouchThinkingPolicy: 'always',
            lightTouchPrefill: true,
            lightTouchExtraDirective: '保留技术术语原文',
            quickEnabled: true,
            quickRectify: true,
            quickExtraDirective: '只改错别字和标点',
          ),
        ),
      );
      await pumpQuickOpen(tester, controller);
      await tester.dragUntilVisible(
        find.byKey(const Key('quick-rectify-quick-preview')),
        panelScrollable(),
        const Offset(0, -40),
      );
      // Clear the anchor (orb) zone: the ball pins the card's anchor
      // corner and swallows taps over its footprint.
      await tester.drag(panelScrollable(), const Offset(0, -120));
      await tester.pumpAndSettle();

      // The global preview row's shape: one truncated line, the
      // settings jump on its right, one button PER ROW.
      expect(
        find.byKey(const Key('quick-rectify-light-preview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('quick-rectify-quick-preview')),
        findsOneWidget,
      );
      // Each jump opens the rectify domain AND collapses the panel
      // (小修 17) — so the rows are tapped one panel-life at a time.
      Future<void> jump(Finder button) async {
        await tester.tap(button);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(opened, contains(SettingsDomain.rectify));
        expect(controller.stage, StageKind.orb);
      }

      await jump(find.byKey(const Key('quick-rectify-light-open')));

      // Reopen, scroll back to the quick row, clear the anchor zone.
      await pumpQuickOpen(tester, controller);
      await tester.dragUntilVisible(
        find.byKey(const Key('quick-rectify-quick-preview')),
        panelScrollable(),
        const Offset(0, -40),
      );
      await tester.drag(panelScrollable(), const Offset(0, -120));
      await tester.pumpAndSettle();
      await jump(find.byKey(const Key('quick-rectify-quick-open')));
      expect(opened, [SettingsDomain.rectify, SettingsDomain.rectify]);

      // Unset = hidden entirely (a fresh store, no directives).
      final bare = await pumpController(
        tester,
        FakeGateway(),
        rectifyStore: FakeRectifyBehaviorStore(),
      );
      await pumpQuickOpen(tester, bare);
      await tester.dragUntilVisible(
        find.text('快速模式'),
        panelScrollable(),
        const Offset(0, -40),
      );
      expect(
        find.byKey(const Key('quick-rectify-light-preview')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('quick-rectify-quick-preview')),
        findsNothing,
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
        SpokenRectifierApp(
          controller: controller,
          stageWindow: null,
          rectifyStore: FakeRectifyBehaviorStore(),
        ),
      );
      await pumpQuickOpen(tester, controller);

      // The 外观 section sits below the fold of the scrollable list:
      // bring it into view before tapping its segments.
      await tester.dragUntilVisible(
        find.byKey(const Key('quick-theme-dark')),
        panelScrollable(),
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
              w is DecoratedBox &&
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
    // session window (修正≡预览同形). The window stays at the work area
    // (ADR-0022 — the one bounds call is the startup seating); the CARD
    // keeps its footprint — the pushed hit rect (420x540 — half the
    // 1080 work area caps the height).
    expect(window.bounds, hasLength(1));
    expect(window.bounds.last, const Rect.fromLTRB(0, 0, 1920, 1080));
    expect(window.regions.last, const Rect.fromLTRB(676, 56, 1096, 596));
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
              w is DecoratedBox &&
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
              w is DecoratedBox &&
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
    /// geometry cache before any gesture runs. The view is pinned to
    /// the work-area window (02 号票) so view coordinates match window
    /// coordinates.
    Future<SpeechController> pumpGeometry(
      WidgetTester tester, {
      required RecordingStageWindow window,
      required Directory dir,
      FakeGateway? gateway,
    }) async {
      final controller = SpeechController(
        gateway: gateway ?? FakeGateway(),
        scriptedPhrases: const [],
        uiPrefsDirs: [dir.path],
      );
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        SpokenRectifierApp(
          controller: controller,
          stageWindow: window,
          rectifyStore: FakeRectifyBehaviorStore(),
        ),
      );
      await tester.pump();
      return controller;
    }

    Directory scratch() {
      final d = Directory.systemTemp.createTempSync('sr-geo-widget-');
      addTearDown(() => d.deleteSync(recursive: true));
      return d;
    }

    testWidgets('an idle drag moves anchor content, never the window', (
      tester,
    ) async {
      // The permanent work-area window (ADR-0022): an idle drag is
      // the SAME in-window anchor drag as the panel one — the orb
      // follows the screen cursor by layout, the HWND stands still,
      // and the region rides null for the gesture then re-pins to
      // the moved footprint on release. (The old flow dragged the
      // 96×96 footprint HWND per frame; view-relative deltas could
      // not mislead anymore because the view never moves.)
      final window = RecordingStageWindow();
      var screen = const Offset(1048, 548);
      window.screenPointer = () => screen;
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));

      final center = tester.getCenter(find.byIcon(Icons.mic_none_rounded));
      final g = await tester.startGesture(center);
      screen = const Offset(1148, 548);
      await g.moveBy(const Offset(100, 0));
      await tester.pump();
      // 1:1 with the screen cursor — and the window never moved.
      expect(
        tester.getRect(find.byType(OrbButton)).center,
        const Offset(1148, 548),
      );
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      // The press unclipped the region for the gesture.
      expect(window.regions.last, isNull);
      await g.up();
      await tester.pump();

      // Release: the footprint region lands on the moved anchor, and
      // the anchor is what persists (松手即写).
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions.last, const Rect.fromLTRB(1100, 500, 1196, 596));
      expect(controller.orbAnchor, const Offset(1148, 548));
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('orb_position = [1148, 548]'),
      );
    });

    testWidgets('a full expand/collapse cycle never touches the HWND', (
      tester,
    ) async {
      // ADR-0022's regression lock: every VISIBLE HWND size change races
      // the engine's next present — the stale surface composites
      // top-left-aligned for one DWM frame (the ghost orb at the screen
      // corner, and the orb's blink-at-rest, that the 10/11/12 device
      // check caught). The window is seated once at startup; expand and
      // collapse are region + Flutter layout ONLY.
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpToRecording(tester, controller);
      // Expanded: card region, still the one startup bounds call.
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions.last, const Rect.fromLTRB(676, 56, 1096, 596));

      await controller.cancelSession();
      await tester.pump(const Duration(milliseconds: 1700));
      // Collapsed: footprint region, STILL the same single bounds call.
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions.last, const Rect.fromLTRB(1000, 500, 1096, 596));

      // A second cycle (the quick panel this time) adds nothing either.
      controller.orbSecondary();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 700));
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 700));
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions.last, const Rect.fromLTRB(1000, 500, 1096, 596));
    });

    testWidgets('a collapse that lands mid-drag never re-clips the orb', (
      tester,
    ) async {
      // 小修 12: the collapse's tail region push used to fire
      // unconditionally — a press inside the 670 ms exit window unclips
      // the region for the drag, and the tail then pinned the 96×96
      // footprint at wherever the ball happened to be that instant. The
      // drag carried the orb out of that rect and the OS region clipped
      // it away mid-gesture (the truncated-ball device symptom: grab the
      // ball right after collapsing a panel, drag, the ball disappears
      // past a modest rectangle). The gesture owns the region while
      // armed; the release's prime lands the footprint at wherever the
      // ball actually rests.
      final window = RecordingStageWindow();
      var screen = const Offset(1048, 548);
      window.screenPointer = () => screen;
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);

      // Open the quick panel, close it, and grab the ball while the exit
      // choreography is still playing (inside the 670 ms window).
      controller.orbSecondary();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 700));
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 350));
      final center = tester.getCenter(find.byType(OrbButton));
      final g = await tester.startGesture(center);
      screen = const Offset(1148, 548);
      await g.moveBy(const Offset(100, 0));
      await tester.pump();

      // The collapse's tail lands mid-gesture — it must NOT re-pin a
      // footprint the drag is about to carry the orb out of.
      await tester.pump(const Duration(milliseconds: 400));
      expect(window.regions.last, isNull);

      // Still dragging, far past where that stale footprint sat: the
      // region stays unclipped, the orb follows, the window never moves.
      screen = const Offset(1348, 548);
      await g.moveBy(const Offset(200, 0));
      await tester.pump();
      expect(window.regions.last, isNull);
      expect(
        tester.getRect(find.byType(OrbButton)).center,
        const Offset(1348, 548),
      );
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));

      // Release: the prime lands the footprint on the resting anchor and
      // the anchor is what persists.
      await g.up();
      await tester.pump();
      expect(window.regions.last, const Rect.fromLTRB(1300, 500, 1396, 596));
      expect(controller.orbAnchor, const Offset(1348, 548));
    });

    testWidgets('a mixed-dpi monitor hop seats in physical pixels', (
      tester,
    ) async {
      // 17 号票: screen_retriever reports each monitor normalized by ITS
      // OWN scale factor, and window_manager converts setBounds through
      // the Flutter view's dpr — which lags a monitor hop. On a mixed-
      // DPI desktop those three spaces disagree: the candidate fell in
      // dead zones, and the hop's logical setBounds landed the window
      // (and the footprint region) somewhere the orb never paints —
      // stranded invisible until a hotkey heal. The snapshot now
      // re-normalizes everything to ONE window space (uniform ÷ dpr,
      // dead-zone-free), and the hop commands the PHYSICAL twin.
      final window = RecordingStageWindow();
      // A dpr-2 world: logical 1920-wide areas, 3840-wide physical
      // twins. The landed reply is the physical rect ÷ the post-move
      // dpr — exactly what the native side derives.
      window.screens = const [
        Rect.fromLTRB(0, 0, 1920, 1080),
        Rect.fromLTRB(1920, 0, 3840, 1080),
      ];
      window.screensPhysical = const [
        Rect.fromLTRB(0, 0, 3840, 2160),
        Rect.fromLTRB(3840, 0, 7680, 2160),
      ];
      window.landedFor = (p) =>
          Rect.fromLTRB(p.left / 2, p.top / 2, p.right / 2, p.bottom / 2);
      var screen = const Offset(1048, 548);
      window.screenPointer = () => screen;
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      // The startup seating went out in physical pixels too.
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 3840, 2160));

      final center = tester.getCenter(find.byIcon(Icons.mic_none_rounded));
      final g = await tester.startGesture(center);
      // Deep into the second monitor — in the single window space this
      // is plain containment, no dead zone to fall through.
      screen = const Offset(2200, 548);
      await g.moveBy(const Offset(1152, 0));
      await tester.pump();

      // The hop commanded the second area's PHYSICAL twin — not the
      // logical rect a dpr-riding setBounds would mangle.
      expect(window.bounds, const [
        Rect.fromLTRB(0, 0, 3840, 2160),
        Rect.fromLTRB(3840, 0, 7680, 2160),
      ]);
      // The orb is window-internal content of the NEW area: 280 from
      // its left edge (anchor 2200 − origin 1920).
      expect(
        tester.getRect(find.byType(OrbButton)).center,
        const Offset(280, 548),
      );

      await g.up();
      await tester.pump();
      // The footprint region lands inside the seated window and the
      // anchor persists in the (settled) logical space.
      expect(window.regions.last, const Rect.fromLTRB(232, 500, 328, 596));
      expect(controller.orbAnchor, const Offset(2200, 548));
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('orb_position = [2200, 548]'),
      );
    });

    testWidgets('a dpr flip mid-hop re-bases the rect and snaps the anchor', (
      tester,
    ) async {
      // The hop's REPLY, not the assumption, is the truth: the dpr can
      // flip between the send and the landing, seating the window at a
      // different logical rect than the cache assumed. The host adopts
      // the landed rect, and the release's prime clamps any stale-space
      // anchor back INSIDE it — the footprint region can never again
      // land outside the window (the stranding symptom's backstop).
      final window = RecordingStageWindow();
      window.screens = const [
        Rect.fromLTRB(0, 0, 1920, 1080),
        Rect.fromLTRB(1920, 0, 3840, 1080),
      ];
      window.screensPhysical = const [
        Rect.fromLTRB(0, 0, 3840, 2160),
        Rect.fromLTRB(3840, 0, 7680, 2160),
      ];
      // Primary behaves dpr-2; the hop's landing reports a HALVED rect
      // on the second monitor (whatever the OS decided — the reply
      // wins).
      window.landedFor = (p) => p.topLeft == const Offset(3840, 0)
          ? const Rect.fromLTRB(1920, 0, 2400, 540)
          : Rect.fromLTRB(p.left / 2, p.top / 2, p.right / 2, p.bottom / 2);
      var screen = const Offset(1048, 548);
      window.screenPointer = () => screen;
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);

      final center = tester.getCenter(find.byIcon(Icons.mic_none_rounded));
      final g = await tester.startGesture(center);
      screen = const Offset(2200, 548);
      await g.moveBy(const Offset(1152, 0));
      await tester.pump();
      // The drag frame clamped the anchor into the ASSUMED second-area
      // rect (2200, 548) — outside the landed window's bottom edge.
      expect(controller.orbAnchor, const Offset(2200, 548));

      await g.up();
      await tester.pump();
      // The prime snapped the anchor inside the LANDED rect: y 548 →
      // 492 (540 − 48). The correction persists.
      expect(controller.orbAnchor, const Offset(2200, 492));
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('orb_position = [2200, 492]'),
      );
      // And the footprint region sits inside the landed window.
      expect(window.regions.last, const Rect.fromLTRB(232, 444, 328, 540));
    });

    testWidgets('content at the resize floor keeps its right inset', (
      tester,
    ) async {
      // 18 号票: the pinned-chrome overflow floor must be the PAINTED
      // card's minimum, not the slot's — the resize floor (360) applies
      // to the slot, and the painted card is 16 narrower. Flooring the
      // bands at 360 pushed the content column past the card's right
      // edge at the narrowest resize: the content bottomed out early
      // and the right inset was eaten (device check caught it). At the
      // floor the bands now match the interior exactly.
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      controller.panelFootprint = SrGeometry.panelMinSize;
      await pumpQuickOpen(tester, controller);
      expect(tester.takeException(), isNull);

      // Slot (360 wide) at the upLeft anchor (1048,548) lands at
      // x 736..1096; the painted card is 744..1088, and the list's
      // content inset is 16 — so a full-width row's right edge must sit
      // at ≤ 1072. The old floor laid the band 360 wide: the row ran to
      // 1088, flush with (and clipped at) the card edge.
      final rowRight = tester
          .getTopRight(find.byKey(const Key('quick-open-settings:scenarios')))
          .dx;
      expect(rowRight, lessThanOrEqualTo(1072.5));
    });

    testWidgets('an idle drag clamps the anchor and persists it', (
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

      // Anchor (1048, 548) -> (1083, 563): the orb content followed,
      // the window never moved, the region re-pinned to the moved
      // footprint.
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions.last, const Rect.fromLTRB(1035, 515, 1131, 611));
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

      // Flush: the footprint region exactly on the work-area corner —
      // the window itself is long since the whole work area.
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions.last, const Rect.fromLTRB(1824, 984, 1920, 1080));
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
      // The first (and so far only) bounds call is the startup seating
      // of the work-area window (ADR-0022) — no drag ever moved it, and
      // no expand added one.
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      await windDown(tester, controller);
    });

    testWidgets('panel-stage anchor drag moves layout, never the window', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      var screen = const Offset(1048, 548);
      window.screenPointer = () => screen;
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpQuickOpen(tester, controller);

      // Work-area window at (0,0,1920,1080) (02 号票); the card sits at
      // (676,56,1096,596) — 420x540, the height capped at half the work
      // area — the orb socketed at its bottom-right (1048,548).
      final card0 = tester.getRect(find.byType(QuickPanel));
      expect(card0, const Rect.fromLTRB(676, 56, 1096, 596));

      // Drag the anchor button past the 8px slop: the card follows the
      // ball INSIDE the window — zero setBounds, zero HWND motion.
      final g = await tester.startGesture(
        tester.getCenter(find.byType(OrbButton)),
      );
      screen = const Offset(1098, 598);
      await g.moveBy(const Offset(50, 50));
      await tester.pump();
      expect(window.bounds, hasLength(1)); // the startup seating only
      // The press unclipped the region; frozen for the gesture (ADR 0017).
      expect(window.regions.last, isNull);
      // Card and orb moved by exactly the drag delta, socket concentric.
      expect(
        tester.getRect(find.byType(QuickPanel)),
        card0.shift(const Offset(50, 50)),
      );
      expect(
        tester.getRect(find.byType(OrbButton)),
        Rect.fromCircle(center: const Offset(1098, 598), radius: 48),
      );
      await g.up();
      await tester.pump();

      // Release: the hit region catches up to the new card rect.
      expect(window.regions.last, card0.shift(const Offset(50, 50)));
      // The new anchor persisted (松手即写, no quadrant snap).
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('orb_position = [1098, 598]'),
      );
      // Closing collapses onto the moved anchor — the window NEVER
      // shrank (ADR-0022); the region narrowed to the moved footprint.
      controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 700));
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions.last, const Rect.fromLTRB(1050, 550, 1146, 646));
    });

    testWidgets('the quadrant switch crosses center+48; hysteresis inside', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      var screen = const Offset(1048, 548);
      window.screenPointer = () => screen;
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpQuickOpen(tester, controller);
      expect(window.regions.last, const Rect.fromLTRB(676, 56, 1096, 596));

      final g = await tester.startGesture(
        tester.getCenter(find.byType(OrbButton)),
      );

      // Left past the CENTER (960) but inside the hysteresis band
      // (>912): the direction holds (未过中心只平移 — the card only
      // translates, socket concentric, chrome unchanged).
      screen = const Offset(918, 548);
      await g.moveBy(const Offset(-130, 0));
      await tester.pump();
      expect(
        tester.getRect(find.byType(OrbButton)).center,
        const Offset(918, 548),
      );
      // Still upLeft: the card's bottom-right hugs the anchor.
      expect(tester.getRect(find.byType(QuickPanel)).right, 918 + 48);

      // Past the threshold (960 − 48): the direction flips and the
      // quadrant motion layer carries the re-pin (12 号票) — the ball
      // never moves (跨阈重推), the card SPRINGS around it to the new
      // corner.
      screen = const Offset(900, 548);
      await g.moveBy(const Offset(-18, 0));
      await tester.pump();
      expect(
        tester.getRect(find.byType(OrbButton)).center,
        const Offset(900, 548),
      );
      // The spring lands (critically damped, ≈340ms settle feel).
      await tester.pump(const Duration(milliseconds: 600));
      // upRight now: the card's bottom-LEFT hugs the anchor.
      expect(tester.getRect(find.byType(QuickPanel)).left, 900 - 48);
      await g.up();
      await tester.pump();
      // Release region re-pins to the new-configuration card rect.
      expect(window.regions.last, const Rect.fromLTRB(852, 56, 1272, 596));
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('orb_position = [900, 548]'),
      );
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('a sub-threshold release on the anchor stays a click', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpQuickOpen(tester, controller);

      // 5px inside the 8px slop: the release is the orb button's
      // primary action — the quick panel CLOSES; nothing moved (阈内
      // 松手=主操作). The header grip that used to own this zone is
      // gone (02 号票) — the anchor button is the one affordance.
      final g = await tester.startGesture(
        tester.getCenter(find.byType(OrbButton)),
      );
      await g.moveBy(const Offset(4, 3));
      await g.up();
      await tester.pump(const Duration(milliseconds: 700));

      expect(controller.stage, StageKind.orb);
      // Nothing ever moved the window: the one bounds call is the
      // startup seating (ADR-0022) — the click-close's collapse only
      // narrowed the region. The push trail: startup footprint, expand
      // card, press null, click release back to the card, collapse to
      // the footprint.
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions[0], const Rect.fromLTRB(1000, 500, 1096, 596));
      expect(window.regions[1], const Rect.fromLTRB(676, 56, 1096, 596));
      expect(window.regions[2], isNull);
      expect(window.regions[3], const Rect.fromLTRB(676, 56, 1096, 596));
      expect(window.regions.last, const Rect.fromLTRB(1000, 500, 1096, 596));
    });

    testWidgets('dragging across monitors re-bases the window once', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      window.screens = const [
        Rect.fromLTWH(0, 0, 1920, 1080),
        Rect.fromLTWH(1920, 0, 1920, 1080),
      ];
      var screen = const Offset(1048, 548);
      window.screenPointer = () => screen;
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpQuickOpen(tester, controller);

      final g = await tester.startGesture(
        tester.getCenter(find.byType(OrbButton)),
      );
      // Straight into the second monitor's work area.
      screen = const Offset(2500, 548);
      await g.moveBy(const Offset(1452, 0));
      await tester.pump();

      // ONE atomic jump onto the second work area (纯位移 setBounds) —
      // the crossing also re-derives the direction against the NEW
      // area's center (2500 < 2880: the card flips to grow right).
      expect(window.bounds, const [
        Rect.fromLTRB(0, 0, 1920, 1080),
        Rect.fromLTRB(1920, 0, 3840, 1080),
      ]);
      expect(
        tester.getRect(find.byType(OrbButton)).center,
        const Offset(580, 548), // window-local == view coordinates
      );
      await g.up();
      await tester.pump();
      // The crossing re-derived the direction mid-gesture — the re-pin
      // spring (12 号票) was still flying at the release, so the hit
      // region lands with it, on the new corner.
      await tester.pump(const Duration(milliseconds: 600));
      // Card re-pinned: anchor-side left edge, region in new-window
      // coords (screen 2452..2872 minus the 1920 origin).
      expect(window.regions.last, const Rect.fromLTRB(532, 56, 952, 596));
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('orb_position = [2500, 548]'),
      );
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('the anchor drags in every session phase (rectifying too)', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      var screen = const Offset(1048, 548);
      window.screenPointer = () => screen;
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpToRecording(tester, controller);

      // Recording: a drag past the slop moves the card; the session
      // keeps running (the release never fires the stop click).
      var g = await tester.startGesture(
        tester.getCenter(find.byType(OrbButton)),
      );
      screen = const Offset(1098, 548);
      await g.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(controller.phase, BridgeSessionState.recording);
      expect(tester.getRect(find.byType(SessionPanel)).left, 676 + 50);
      await g.up();
      await tester.pump();

      // Rectifying: the click table is cold (修正中可拖不可点) — the
      // drag still moves the card, and the phase survives the release.
      await controller.stopSession();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.phase, BridgeSessionState.rectifying);
      g = await tester.startGesture(tester.getCenter(find.byType(OrbButton)));
      screen = const Offset(1148, 548);
      await g.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(controller.phase, BridgeSessionState.rectifying);
      expect(tester.getRect(find.byType(SessionPanel)).left, 726 + 50);
      await g.up();
      await tester.pump();
      await windDown(tester, controller);
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
      // move. Height half-caps at 540 (02 号票: half of the 1080 work
      // area; the anchor's own span 596 is looser), so the card grows
      // only in width: 420 + 60 = 480.
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
      expect(controller.panelFootprint, const Size(480, 540));
      expect(window.regions.last, const Rect.fromLTRB(616, 56, 1096, 596));
      expect(
        File('${dir.path}/$uiPrefsFile').readAsStringSync(),
        contains('panel_size = [480, 540]'),
      );
      // The shared footprint: the next open (after a close) keeps it.
      controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 700));
      controller.orbSecondary();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      expect(window.regions.last, const Rect.fromLTRB(616, 56, 1096, 596));
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('the resize floor holds: shrinking stops at 360x440', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final dir = scratch();
      final controller = await pumpGeometry(tester, window: window, dir: dir);
      await pumpQuickOpen(tester, controller);

      // Drag the corner handle toward the orb by (100, 100): intent
      // 320x440, the floor holds the width at 360 (height lands on the
      // 440 floor exactly).
      final corner = tester.getCenter(
        find.byKey(const Key('panel-resize-corner')),
      );
      final g = await tester.startGesture(corner);
      await g.moveBy(const Offset(100, 100));
      await g.up();
      await tester.pump();

      expect(window.bounds, hasLength(1)); // zero HWND churn (ADR 0017)
      expect(controller.panelFootprint, const Size(360, 440));
      expect(window.regions.last, const Rect.fromLTRB(736, 156, 1096, 596));
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets(
      'a resize gesture never touches the HWND (the window sits at the work area)',
      (tester) async {
        // ADR 0017 + 02 号票: the expand already jumped the window to
        // the whole work area, so a resize is pure Flutter layout —
        // zero setBounds across the whole gesture. A mid-gesture HWND
        // size change flashes even as a single jump: the stale child
        // surface composites top-left-aligned for one DWM frame when
        // the engine loses the present race (probe evidence, report
        // section 0.1).
        final window = RecordingStageWindow();
        final dir = scratch();
        final controller = await pumpGeometry(tester, window: window, dir: dir);
        await pumpQuickOpen(tester, controller);
        expect(window.bounds, hasLength(1)); // the startup seating only
        expect(window.bounds.last, Rect.fromLTRB(0, 0, 1920, 1080));

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
        expect(controller.panelFootprint, const Size(510, 540));
        // ...the card itself took the width growth inside the work-area
        // window (the height already sat at its 540 half-cap).
        expect(tester.getSize(find.byType(QuickPanel)), const Size(510, 540));
        // The hit-through region caught up to the final slot.
        expect(window.regions.last, Rect.fromLTRB(586, 56, 1096, 596));
        await controller.closeQuick();
        await tester.pump(const Duration(milliseconds: 700));
        // Back to the orb: the region narrowed to the footprint (the
        // window itself never moved, never resized — the whole point).
        expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
        expect(window.regions.last, const Rect.fromLTRB(1000, 500, 1096, 596));
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
      expect(tester.getSize(find.byType(QuickPanel)), const Size(510, 540));
      await g.up();
      await tester.pump();
      expect(identical(tester.widget(find.byType(QuickPanel)), before), isTrue);
      await controller.closeQuick();
      await tester.pump(const Duration(milliseconds: 700));
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

    testWidgets(
      'the footer flips at the guard line both ways, holding the busy lock',
      (tester) async {
        // 13 号票: one flip per crossing, one line in both directions.
        // The busy lock means a re-cross mid-flight waits for the flight
        // to land — the down-flip runs to its circle end even after the
        // width has grown back past the line, and only the completion
        // re-check launches the up-flip.
        final window = RecordingStageWindow();
        final dir = scratch();
        final gateway = FakeGateway();
        final controller = await pumpGeometry(
          tester,
          window: window,
          dir: dir,
          gateway: gateway,
        );
        controller.panelFootprint = const Size(560, 560);
        await pumpToPreview(tester, controller, gateway);
        // Wide band: full capsules, labels mounted at their natural size.
        expect(find.text('对照原文'), findsOneWidget);
        final labelSize = tester.getSize(find.text('对照原文'));

        // Shrink past the guard in one move (the free vertical edge is
        // the LEFT one at the default bottom-right anchor): the
        // down-flip starts. A post-frame-started ticker latches on the
        // NEXT frame — pump in that rhythm (one to arm, then advance).
        final edge = tester.getCenter(find.byKey(const Key('panel-resize-v')));
        final g = await tester.startGesture(edge);
        await tester.pump();
        await g.moveBy(const Offset(180, 0)); // 560 → 380: below the line
        await tester.pump(); // the crossing frame; the flip starts at its end
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        // The label's LAYOUT has not moved — text is faded out, never
        // clipped.
        final fading = find.text('对照原文');
        if (fading.evaluate().isNotEmpty) {
          expect(tester.getSize(fading), labelSize);
        }

        // Grow back past the line while the down-flight is still in the
        // air: the busy lock holds — no mid-air reversal, the flight
        // keeps folding toward the circle. (The flight needs its full
        // 320ms to land — 19 号票 pacing spread the stages across the
        // whole timeline.)
        await g.moveBy(const Offset(-180, 0)); // back to 560
        await tester.pump(); // the re-crossing frame: busy, ignored
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        expect(find.text('对照原文'), findsNothing);

        // The flight lands; the completion re-check sees the wide band
        // and launches the up-flip, which restores the capsules.
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('对照原文'), findsOneWidget);
        await g.up();
        await tester.pump();
        expect(controller.panelFootprint, const Size(560, 540));
        await windDown(tester, controller);
      },
    );

    testWidgets('the morph rides one continuous flight — no whips', (
      tester,
    ) async {
      // 19 号票 (five rounds of device feedback): round one's emphasized
      // landing blew stages through in 1–2 frames (跳变) then sat dead
      // (间断); round two's even stage split cured the whips but read as
      // TWO stitched animations; round five pinned the split on the
      // GROUP geometry — the gaps tightening ahead of the width stage
      // read as a stage of their own even with the text camouflaged.
      // The flight now gathers and blooms with the content channels
      // (fade + tuck) while ALL geometry (width + gaps) shares the one
      // width window, proportional; every phase handoff decelerates to
      // zero velocity. Sample every 16ms frame and pin the failure
      // modes: no frame carries a whole stage, no stretch sits still,
      // the width's pop attack stays a decaying curve, and the geometry
      // never splits into two windows.
      final window = RecordingStageWindow();
      final dir = scratch();
      final gateway = FakeGateway();
      final controller = await pumpGeometry(
        tester,
        window: window,
        dir: dir,
        gateway: gateway,
      );
      controller.panelFootprint = const Size(560, 560);
      await pumpToPreview(tester, controller, gateway);

      final edge = tester.getCenter(find.byKey(const Key('panel-resize-v')));
      final g = await tester.startGesture(edge);
      await tester.pump();
      await g.moveBy(const Offset(180, 0)); // 560 → 380: below the line
      await tester.pump(); // the crossing frame; the flip starts at its end

      final labelOpacity = find.byWidgetPredicate(
        (w) =>
            w is Opacity && w.child is Text && (w.child as Text).data == '重新生成',
      );
      final reroll = find.byKey(const Key('session-reroll'));
      final rerollIcon = find.descendant(
        of: reroll,
        matching: find.byType(Icon),
      );
      double? lastWidth;
      double? lastOpacity;
      var deadRun = 0;
      var worstDeadRun = 0;
      double? height0;
      double? top0;
      double? width0;
      double? gap0;
      // Frame 0 latches the post-frame-started ticker (its own delta is
      // the parked capsule); frames 1..20 walk the flight, 16ms a frame.
      for (var i = 0; i <= 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final box = tester.getRect(reroll);
        final width = box.width;
        // 四轮 ruling: BOTH arms pin the same constant height and the
        // band is bottom-pinned, so neither a button's height nor its
        // top edge may move on ANY frame. The capsule arm's INTRINSIC
        // height (the kbd chip's line box, tallest) used to step into
        // the circle's pinned one at the branch swap — a sub-pixel band
        // twitch the device raster snapped into view.
        if (i == 0) {
          height0 = box.height;
          top0 = box.top;
          width0 = box.width;
        } else {
          expect(
            box.height,
            closeTo(height0!, 0.25),
            reason: 'height step at frame $i',
          );
          expect(
            box.top,
            closeTo(top0!, 0.25),
            reason: 'vertical bob at frame $i',
          );
          expect(
            tester.getSize(find.byKey(const Key('session-cancel'))).height,
            closeTo(height0, 0.25),
            reason: 'kbd capsule height at frame $i',
          );
        }
        // 三轮 ruling: the icon's inset from the capsule's left border
        // is CONSTANT through the entire morph, both branches — the
        // collapse eats the right side only. The constant is the pad
        // (8) plus the hairline border (1), which insets the content
        // origin equally in both branches.
        expect(
          tester.getTopLeft(rerollIcon).dx - tester.getTopLeft(reroll).dx,
          closeTo(9, 0.5),
          reason: 'icon inset at frame $i',
        );
        final hasLabel = labelOpacity.evaluate().isNotEmpty;
        final opacity = hasLabel
            ? tester.widget<Opacity>(labelOpacity).opacity
            : null;
        // 五轮 ruling: the inter-button gap and the width collapse
        // share ONE window, proportional. While the label is still
        // visible the gap holds its capsule value (the gather is the
        // content channel alone); once the label folds the gap's
        // progress equals the width's progress — the group's envelope
        // is a single continuous squeeze, never a gap stage ahead of a
        // width stage (the device read that as two stitched animations
        // even with the text camouflaged).
        final gapNow =
            box.left -
            tester.getTopRight(find.byKey(const Key('session-raw-toggle'))).dx;
        if (i == 0) {
          gap0 = gapNow;
        } else if (hasLabel) {
          expect(
            gapNow,
            closeTo(gap0!, 0.3),
            reason: 'gap moved while content still visible at frame $i',
          );
        } else {
          final pW = (width0! - width) / (width0 - height0);
          final pG = (gap0! - gapNow) / (gap0 - 4.0);
          expect(pG, closeTo(pW, 0.05), reason: 'gap/width desync at frame $i');
        }
        if (lastWidth != null) {
          final dw = (width - lastWidth).abs();
          final dOp = (opacity != null && lastOpacity != null)
              ? (opacity - lastOpacity).abs()
              : 0.0;
          // The expand's width attack lands ~21px on its first frame
          // (curveEnter's decaying pop); the collapse's gather stays
          // far gentler. Anything past 26 in one 16ms frame is a
          // blowthrough, not a pop.
          expect(dw, lessThan(26), reason: 'width jump at frame $i');
          expect(dOp, lessThan(0.25), reason: 'opacity jump at frame $i');
          deadRun = (dw <= 0.1 && dOp <= 0.02) ? deadRun + 1 : 0;
          if (deadRun > worstDeadRun) worstDeadRun = deadRun;
        }
        lastWidth = width;
        lastOpacity = opacity;
      }
      // The flight landed a circle with nothing ever sitting still for
      // four frames.
      expect(worstDeadRun, lessThan(4));
      expect(find.text('重新生成'), findsNothing);
      await g.up();
      await tester.pump();
      expect(controller.panelFootprint, const Size(380, 540));
      await windDown(tester, controller);
    });

    testWidgets('a fast narrow tucks the racing tail under the ball', (
      tester,
    ) async {
      // 20 号票: a narrowing fast enough to beat the flight leaves the
      // folding capsules wider than the band for a few frames — the
      // guard cannot be made infinitely wide, so the race is structural.
      // The old straight clip on the group's box cut that tail
      // mid-panel, a vertical container edge that read as a UI artifact.
      // The group now overflows freely toward the anchor ball and the
      // band's one boundary is the ball's own silhouette.
      final window = RecordingStageWindow();
      final dir = scratch();
      final gateway = FakeGateway();
      final controller = await pumpGeometry(
        tester,
        window: window,
        dir: dir,
        gateway: gateway,
      );
      controller.panelFootprint = const Size(560, 560);
      await pumpToPreview(tester, controller, gateway);

      final edge = tester.getCenter(find.byKey(const Key('panel-resize-v')));
      final g = await tester.startGesture(edge);
      await tester.pump();
      await g.moveBy(const Offset(180, 0)); // 560 → 380: racing the flight
      await tester.pump(); // the crossing frame; the flip starts at its end
      await tester.pump(const Duration(milliseconds: 100)); // mid-flight
      expect(tester.takeException(), isNull);

      // No straight clip anywhere in the band — the group rides an
      // overflow box and paints toward the ball.
      final band = find.byKey(const Key('panel-chrome-footer'));
      expect(
        find.descendant(of: band, matching: find.byType(UnconstrainedBox)),
        findsNothing,
      );
      expect(
        find.descendant(of: band, matching: find.byType(OverflowBox)),
        findsOneWidget,
      );

      // The one boundary is the ball's silhouette (default upLeft: the
      // ball owns the band's right end, 40 in from the card's corner).
      final occlusion = find.byKey(const Key('footer-ball-occlusion'));
      final size = tester.getSize(occlusion);
      final path = tester.widget<ClipPath>(occlusion).clipper!.getClip(size);
      final ballC = Offset(size.width - 40, size.height - 40);
      expect(
        path.contains(const Offset(10, 20)),
        isTrue,
        reason: "the row's start stays paintable",
      );
      expect(
        path.contains(ballC),
        isFalse,
        reason: 'the disc zone belongs to the ball',
      );
      // THE ruling: nothing emerges past the ball — the sliver between
      // the arc and the card's edge is removed too.
      expect(path.contains(Offset(size.width - 5, ballC.dy)), isFalse);
      // Content room extends into the old reserve, up to the arc (the
      // disc spans [cx−30, cx+30] at the equator: 75 from the band's
      // right edge is 5 clear of it).
      expect(path.contains(Offset(size.width - 75, ballC.dy)), isTrue);

      // The flight still lands a circle group despite the race.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('重新生成'), findsNothing);
      await g.up();
      await tester.pump();
      expect(controller.panelFootprint, const Size(380, 540));
      await windDown(tester, controller);
    });

    testWidgets('the expand direction follows the anchor\'s quadrant', (
      tester,
    ) async {
      // Each quadrant opens once: the work-area window is the SAME
      // (0,0,1920,1080) every time (02 号票) — what follows the anchor's
      // quadrant is the CARD: it grows away from the ball, and the orb
      // lands mid-window wherever the anchor sits. Anchors sit flush
      // inside the area, as a clamped drag would leave them.
      for (final (anchor, expectCard, orbAtTop) in [
        // Bottom-right anchor (default): grows up-left, orb at the
        // card's bottom-right corner.
        (Offset(1824, 984), Rect.fromLTRB(1452, 492, 1872, 1032), false),
        // Bottom-left: grows up-right.
        (Offset(48, 984), Rect.fromLTRB(0, 492, 420, 1032), false),
        // Top-left: grows down-right, orb at the card's top-left.
        (Offset(48, 48), Rect.fromLTRB(0, 0, 420, 540), true),
        // Top-right: grows down-left.
        (Offset(1824, 48), Rect.fromLTRB(1452, 0, 1872, 540), true),
      ]) {
        final window = RecordingStageWindow(anchor - const Offset(48, 48));
        final dir = scratch();
        final controller = await pumpGeometry(tester, window: window, dir: dir);
        await pumpQuickOpen(tester, controller);

        expect(
          window.bounds.last,
          const Rect.fromLTRB(0, 0, 1920, 1080),
          reason: 'anchor at $anchor',
        );
        // The card grew away from the ball: its anchor corner hugs the
        // orb, its size is the shared footprint (420x540 at this cap).
        expect(
          tester.getRect(find.byType(QuickPanel)),
          expectCard,
          reason: 'anchor at $anchor',
        );
        // The orb lands exactly on the anchor, mid-window — top row
        // only for the two top anchors.
        final orbTopLeft = tester.getTopLeft(find.byType(OrbButton));
        expect(
          orbTopLeft,
          anchor - const Offset(48, 48),
          reason: 'anchor at $anchor',
        );
        expect(
          orbTopLeft.dy,
          orbAtTop ? lessThan(96) : greaterThan(900),
          reason: 'anchor at $anchor',
        );
        await controller.closeQuick();
        await tester.pump(const Duration(milliseconds: 700));
      }
    });

    // -- 12 号票: the quadrant motion layer ---------------------------------

    group('quadrant motion layer', () {
      /// Pumps the shell, opens the quick panel, and grabs the anchor
      /// button (past-arming comes with the moves). Returns the
      /// controller, the recording window, the gesture, and a screen-
      /// cursor setter (the production drag path).
      Future<
        (
          SpeechController,
          RecordingStageWindow,
          TestGesture,
          void Function(Offset),
        )
      >
      armedDrag(WidgetTester tester) async {
        final window = RecordingStageWindow();
        var screen = const Offset(1048, 548);
        window.screenPointer = () => screen;
        final dir = scratch();
        final controller = await pumpGeometry(tester, window: window, dir: dir);
        await pumpQuickOpen(tester, controller);
        final g = await tester.startGesture(
          tester.getCenter(find.byType(OrbButton)),
        );
        return (controller, window, g, (s) => screen = s);
      }

      testWidgets('a threshold flip springs the card around the ball', (
        tester,
      ) async {
        final (controller, window, g, moveTo) = await armedDrag(tester);
        final card0 = tester.getRect(find.byType(QuickPanel));
        expect(card0, const Rect.fromLTRB(676, 56, 1096, 596));

        // Past the center − 48: the flip fires. The ball parks on the
        // pointer; the card is still at the OLD pin at this frame (the
        // spring's clock starts here) and its SIZE never changes.
        moveTo(const Offset(900, 548));
        await g.moveBy(const Offset(-148, 0));
        await tester.pump();
        expect(
          tester.getRect(find.byType(OrbButton)).center,
          const Offset(900, 548),
        );
        final atFlip = tester.getRect(find.byType(QuickPanel));
        expect(atFlip.size, card0.size);
        expect(atFlip.left, closeTo(528, 1)); // the old pin, anchor-moved

        // Mid-flight: strictly between the pins, still the same size.
        await tester.pump(const Duration(milliseconds: 200));
        final mid = tester.getRect(find.byType(QuickPanel));
        expect(mid.size, card0.size);
        expect(mid.left, inExclusiveRange(530, 850));

        // Settled: the exact new pin, and the release region (the form
        // was at rest) hugs it at once.
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          tester.getRect(find.byType(QuickPanel)),
          const Rect.fromLTRB(852, 56, 1272, 596),
        );
        await g.up();
        await tester.pump();
        expect(window.regions.last, const Rect.fromLTRB(852, 56, 1272, 596));
        await controller.closeQuick();
        await tester.pump(const Duration(milliseconds: 700));
      });

      testWidgets('a mid-flight re-cross retargets without a jump', (
        tester,
      ) async {
        final (controller, window, g, moveTo) = await armedDrag(tester);

        // Flip toward upRight, let the spring fly half-way, then cross
        // BACK past the +48 band: the target flips again MID-FLIGHT.
        moveTo(const Offset(900, 548));
        await g.moveBy(const Offset(-148, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final before = tester.getRect(find.byType(QuickPanel));
        moveTo(const Offset(1048, 548));
        await g.moveBy(const Offset(148, 0));
        await tester.pump();
        final after = tester.getRect(find.byType(QuickPanel));

        // No jump in FORM space: the card's offset from the ball is
        // continuous across the retarget (the 144px absolute move is
        // the ball's own translation, carried by the card as always).
        expect(after.left - 1048, closeTo(before.left - 900, 1));
        expect(after.top - 548, closeTo(before.top - 548, 1));

        // The re-engaged spring carries the card back toward the
        // ORIGINAL pin and lands on it exactly.
        await tester.pump(const Duration(milliseconds: 60));
        expect(
          tester.getRect(find.byType(QuickPanel)).left,
          lessThan(after.left),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          tester.getRect(find.byType(QuickPanel)),
          const Rect.fromLTRB(676, 56, 1096, 596),
        );
        await g.up();
        await tester.pump();
        expect(window.regions.last, const Rect.fromLTRB(676, 56, 1096, 596));
        await controller.closeQuick();
        await tester.pump(const Duration(milliseconds: 700));
      });

      testWidgets('a diagonal crossing moves both axes as one', (tester) async {
        final (controller, _, g, moveTo) = await armedDrag(tester);

        // One move crossing BOTH thresholds (x < 912, y < 492): both
        // axes retarget in the same update and ride the SAME spring —
        // 对角并合一记, never X-then-Y.
        moveTo(const Offset(880, 480));
        await g.moveBy(const Offset(-168, -68));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));

        // Mid-flight: both axes strictly between their pins, at the
        // SAME progress (a straight diagonal transit around the ball).
        final mid = tester.getRect(find.byType(QuickPanel));
        final px = (832 - mid.left) / 324; // target gl=0 lands left 832
        final py = (432 - mid.top) / 444; // target gu=0 lands top 432
        expect(px, inExclusiveRange(0.02, 0.98));
        expect(py, inExclusiveRange(0.02, 0.98));
        expect(px, closeTo(py, 0.02));

        await tester.pump(const Duration(milliseconds: 600));
        expect(
          tester.getRect(find.byType(QuickPanel)),
          const Rect.fromLTRB(832, 432, 1252, 972),
        );
        await g.up();
        await controller.closeQuick();
        await tester.pump(const Duration(milliseconds: 700));
      });

      testWidgets('the chrome hands over without disappearing mid-switch', (
        tester,
      ) async {
        final window = RecordingStageWindow();
        var screen = const Offset(1048, 548);
        window.screenPointer = () => screen;
        final dir = scratch();
        final gateway = FakeGateway();
        final controller = await pumpGeometry(
          tester,
          window: window,
          dir: dir,
          gateway: gateway,
        );
        await pumpToPreview(tester, controller, gateway);

        // Bottom-anchored at rest: the top fade is the resident xl soft
        // cut already (小修 13 — it never unmounts; only its height
        // rides the form).
        expect(find.byKey(const Key('session-top-fade')), findsOneWidget);
        expect(
          tester
              .widget<Positioned>(find.byKey(const Key('session-top-fade')))
              .height,
          SrSpace.xl,
        );

        // A pure VERTICAL flip (the x threshold is never crossed).
        final g = await tester.startGesture(
          tester.getCenter(find.byType(OrbButton)),
        );
        screen = const Offset(1048, 470);
        await g.moveBy(const Offset(0, -78));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));

        // Mid-switch everything stays MOUNTED: the header cluster, all
        // three footer capsules, the footer band — and the top fade
        // rides the same window, its height handing over 24 → 48 (小修
        // 13: the height is the handoff now; controls never unmount,
        // and neither does the fade).
        expect(find.text('预览'), findsOneWidget);
        for (final key in [
          const Key('session-raw-toggle'),
          const Key('session-reroll'),
          const Key('session-cancel'),
        ]) {
          expect(find.byKey(key), findsOneWidget);
        }
        expect(find.byKey(const Key('panel-chrome-footer')), findsOneWidget);
        expect(find.byKey(const Key('session-top-fade')), findsOneWidget);

        // Settled top-anchored: the fade is the 48 anchor band now.
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(const Key('session-top-fade')), findsOneWidget);
        expect(
          tester
              .widget<Positioned>(find.byKey(const Key('session-top-fade')))
              .height,
          SrGeometry.anchorInset,
        );
        await g.up();
        await tester.pump();
        await windDown(tester, controller);
      });
    });
  });

  // -- 11 号票: the grow choreography (窝圆 → footprint) ----------------------

  group('grow choreography', () {
    /// Opens the session window and lands the timeline at [elapsed] of
    /// the grow: the panel mounts on the first (zero-length) frame, the
    /// controller's clock advances on the second. [elapsed] of null
    /// leaves the card at the disc.
    Future<SpeechController> pumpGrowing(
      WidgetTester tester,
      RecordingStageWindow window, {
      Duration? elapsed,
    }) async {
      final controller = await pumpController(
        tester,
        FakeGateway(),
        stageWindow: window,
      );
      await controller.startSession();
      await tester.pump(); // mount at v = 0 (the socket disc)
      if (elapsed != null) await tester.pump(elapsed);
      return controller;
    }

    /// The emphasized curve the choreography rides (07 号票: v = C(u)).
    double curveAt(double u) => Curves.easeInOutCubicEmphasized.transform(u);

    /// The card size at size-progress [v] for the 420x540 slot (the
    /// 1080p half-cap): painted spans 404x524 at rest.
    Size cardAt(double v) => Size(80 + 324 * v, 80 + 444 * v);

    /// Size equality with a tolerance — the widget's chained-tween
    /// arithmetic can land ULPs off the test's closed-form numbers.
    void expectCardSize(Size actual, Size expected) {
      expect(actual.width, closeTo(expected.width, 0.01));
      expect(actual.height, closeTo(expected.height, 0.01));
    }

    testWidgets('the card grows out of the socket disc along the curve', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final controller = await pumpGrowing(tester, window);
      final card = find.byKey(const Key('panel-card'));
      // 小修 18: the fade is DIRECT alpha on the card's own paints —
      // the fill's alpha is the √ramp (E9: the boundary composites the
      // contribution as α², so the paint is pre-compensated with √;
      // the surface token is opaque).
      double ink() =>
          (tester.widget<DecoratedBox>(card).decoration as BoxDecoration)
              .color!
              .a;

      // The socket disc: side 2R (80), concentric with the ball — the
      // degenerate start of the growth. The fade rides the SAME
      // timeline (环先实: solid by 80% of the size progress).
      expect(tester.getSize(card), const Size(80, 80));
      expect(ink(), 0);

      // Early on (u = 0.2) the fade is still riding v / 0.8 — painted
      // at its √ (E9 double-premultiply compensation).
      await tester.pump(const Duration(milliseconds: 128));
      expectCardSize(tester.getSize(card), cardAt(curveAt(0.2)));
      expect(ink(), closeTo(math.sqrt(curveAt(0.2) / 0.8), 0.001));

      // Halfway through the clock the size sits at the curve's v; the
      // ring is already solid (v > 0.8).
      await tester.pump(const Duration(milliseconds: 192)); // u = 0.5
      expectCardSize(tester.getSize(card), cardAt(curveAt(0.5)));
      expect(ink(), 1);

      await tester.pump(SrMotion.grow); // past the whole entrance
      expect(tester.getSize(card), const Size(404, 524));
      await windDown(tester, controller);
    });

    testWidgets('the card never fades through an opacity layer (小修 18)', (
      tester,
    ) async {
      // The device-quirk lock: a layer-composited partial-alpha card at
      // the window transparency boundary composites DARK on device —
      // the card-shaped ghost the E1 fade-off experiment killed. The
      // ramp must live on the card's own paint colors; no opacity
      // widget may sit on the card's ANCESTOR CHAIN mid-fade. (The
      // footer's label channel keeps its own Opacity — it rides over
      // the card's opaque interior, never across the transparency
      // boundary, so it is out of this contract's scope.)
      final window = RecordingStageWindow();
      final controller = await pumpGrowing(tester, window);
      await tester.pump(const Duration(milliseconds: 128)); // mid-fade

      final slotEl = tester.element(find.byKey(const Key('stage-panel-slot')));
      final offenders = <String>[];
      tester.element(find.byKey(const Key('panel-card'))).visitAncestorElements(
        (el) {
          if (identical(el, slotEl)) return false;
          final w = el.widget;
          if (w is Opacity || w is AnimatedOpacity || w is FadeTransition) {
            offenders.add('$w');
          }
          return true;
        },
      );
      expect(offenders, isEmpty, reason: 'nothing may carry the card fade');

      // And the ramp is where the device-proven path needs it: the
      // card's own fill, at the √-compensated value (E9: the boundary
      // composites α², so the paint carries √α).
      final ink =
          (tester
                      .widget<DecoratedBox>(find.byKey(const Key('panel-card')))
                      .decoration
                  as BoxDecoration)
              .color!
              .a;
      expect(ink, closeTo(math.sqrt(curveAt(0.2) / 0.8), 0.001));
      await tester.pump(SrMotion.grow);
      await windDown(tester, controller);
    });

    testWidgets('the content ink fades only over the solid ring (小修 18)', (
      tester,
    ) async {
      // 真机 2026-09-22: with only the surface fading, the full-alpha
      // ink popped in and out with the clip edge. The ink now fades on
      // the tail of the SAME timeline — but only over the opaque card:
      // its opacity layer may never exist while the surface is still
      // semi-transparent, because layer output that lands on the
      // window transparency boundary at partial alpha composites DARK
      // (the card ghost E1 killed). The phase split is the containment.
      final window = RecordingStageWindow();
      final controller = await pumpGrowing(tester, window);
      final card = find.byKey(const Key('panel-card'));
      final inkBand = find.byKey(const Key('panel-content-fade'));
      double cardInk() =>
          (tester.widget<DecoratedBox>(card).decoration as BoxDecoration)
              .color!
              .a;
      double inkFade() => tester.widget<Opacity>(inkBand).opacity;

      // Early (u = 0.2): the surface is mid-fade — the ink paints
      // nothing at all.
      await tester.pump(const Duration(milliseconds: 128));
      expect(cardInk(), lessThan(1));
      expect(inkFade(), 0);

      // Halfway (u = 0.5): the surface is already solid and the ink is
      // riding its own phase — a layer, but strictly over the opaque
      // card.
      await tester.pump(const Duration(milliseconds: 192));
      expect(cardInk(), 1);
      final mid = ((curveAt(0.5) - 0.8) / 0.2).clamp(0.0, 1.0);
      expect(inkFade(), closeTo(mid, 0.001));
      expect(
        inkFade(),
        inExclusiveRange(0, 1),
        reason: 'the ink phase must not be over before the ring is solid',
      );

      // Collapse mirrors it: by u = 0.5 the ink is fully gone while the
      // surface is still fading out.
      await tester.pump(SrMotion.grow);
      await controller.cancelSession();
      await tester.pump(); // the grow-back starts, v stays at 1
      await tester.pump(const Duration(milliseconds: 320)); // u = 0.5
      expect(inkFade(), 0);
      expect(cardInk(), lessThan(1));

      await windDown(tester, controller);
    });

    testWidgets('the collapse plays the same-direction profile, no reverse', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final controller = await pumpGrowing(tester, window);
      await tester.pump(SrMotion.grow); // at rest
      final card = find.byKey(const Key('panel-card'));

      await controller.cancelSession();
      await tester.pump(); // the grow-back starts, v stays continuous
      expect(tester.getSize(card), const Size(404, 524));

      // v = 1 - C(u): fast while big, easing toward the ball (大时快、
      // 近球时慢) — NOT the entrance's replay.
      await tester.pump(const Duration(milliseconds: 320)); // u = 0.5
      expectCardSize(tester.getSize(card), cardAt(1 - curveAt(0.5)));

      // Past grow + slack the region narrowed to the orb footprint
      // around the anchor (1048,548); the window itself NEVER changed
      // (ADR-0022) and the card is gone.
      await tester.pump(const Duration(milliseconds: 700));
      expect(window.bounds.single, const Rect.fromLTRB(0, 0, 1920, 1080));
      expect(window.regions.last, const Rect.fromLTRB(1000, 500, 1096, 596));
      expect(card, findsNothing);
    });

    testWidgets('the chrome pins to the card edges while it grows', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final controller = await pumpGrowing(
        tester,
        window,
        elapsed: const Duration(milliseconds: 320), // u = 0.5
      );
      final cardRect = tester.getRect(find.byKey(const Key('panel-card')));

      // 钉边裁切: the header band rides the card's CURRENT visual top,
      // the session footer its current visual bottom (头底不换), the
      // body clips to the height between them.
      expect(
        tester.getTopLeft(find.byKey(const Key('panel-chrome-header'))),
        cardRect.topLeft,
      );
      expect(
        tester.getBottomRight(find.byKey(const Key('panel-chrome-footer'))),
        cardRect.bottomRight,
      );
      await windDown(tester, controller);
    });

    testWidgets('the anchored corner never moves through the growth', (
      tester,
    ) async {
      // Four anchors, one per quadrant; the socket arc stays pinned on
      // the ball whatever direction the card grows in (四向镜像). The
      // pinned corner sits R=40 diagonally outward from the anchor.
      for (final (anchor, corner) in [
        (const Offset(1824, 984), Alignment.bottomRight), // upLeft
        (const Offset(48, 984), Alignment.bottomLeft), // upRight
        (const Offset(48, 48), Alignment.topLeft), // downRight
        (const Offset(1824, 48), Alignment.topRight), // downLeft
      ]) {
        final window = RecordingStageWindow(anchor - const Offset(48, 48));
        final controller = await pumpGrowing(tester, window);
        final card = find.byKey(const Key('panel-card'));

        final atDisc = corner.withinRect(tester.getRect(card));
        expect(
          atDisc,
          offsetMoreOrLessEquals(
            Offset(anchor.dx + corner.x * 40, anchor.dy + corner.y * 40),
            epsilon: 0.5,
          ),
          reason: 'anchor at $anchor: the disc hugs the ball',
        );
        await tester.pump(const Duration(milliseconds: 320));
        expect(
          corner.withinRect(tester.getRect(card)),
          offsetMoreOrLessEquals(atDisc, epsilon: 0.5),
          reason: 'anchor at $anchor, mid-growth',
        );
        await tester.pump(SrMotion.grow);
        expect(
          corner.withinRect(tester.getRect(card)),
          offsetMoreOrLessEquals(atDisc, epsilon: 0.5),
          reason: 'anchor at $anchor, at rest',
        );
        await windDown(tester, controller);
      }
    });

    testWidgets('a reopen mid-collapse continues from the running v', (
      tester,
    ) async {
      final window = RecordingStageWindow();
      final controller = await pumpGrowing(tester, window);
      await tester.pump(SrMotion.grow); // at rest
      final card = find.byKey(const Key('panel-card'));

      await controller.cancelSession();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320)); // collapse mid-air
      final midSize = tester.getSize(card);

      // The reopen retargets the tween from the CURRENT v — no jump
      // back to the disc, no restart flash.
      await controller.startSession();
      await tester.pump();
      expect(
        tester.getSize(card).width,
        greaterThan(midSize.width - 0.5),
        reason: 'the interrupted entrance continues from its v',
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.getSize(card), const Size(404, 524));
      await windDown(tester, controller);
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
        // (义务随锚点角走) — now as a HEIGHT handover (小修 13: both
        // edges always carry a fade): the 48 anchor band exactly while
        // the orb shares the header row, the xl soft cut (24) while it
        // sits on the footer's edge.
        expect(
          tester
              .widget<Positioned>(find.byKey(const Key('session-top-fade')))
              .height,
          dir.growUp ? SrSpace.xl : SrGeometry.anchorInset,
        );
        // The bottom soft cut is the xl constant in every quadrant: the
        // raw fold / footer band — never the orb — owns the body's
        // bottom edge, so the bottom fade carries no anchor semantics.
        expect(
          tester
              .widget<Positioned>(find.byKey(const Key('session-bottom-fade')))
              .height,
          SrSpace.xl,
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

      testWidgets('circle footers keep both alignments and clear the orb', (
        tester,
      ) async {
        // 13 号票: below the guard the circles inherit the capsule
        // group's obligations — 仅左下右对齐 elsewhere row-start, and the
        // orb-side reserve still buys clearance from the ball.
        for (final dir in [
          stage.GrowthDirection.upLeft,
          stage.GrowthDirection.upRight,
        ]) {
          final gateway = FakeGateway();
          final controller = await pumpAtQuadrant(
            tester,
            dir: dir,
            gateway: gateway,
          );
          controller.panelFootprint = const Size(380, 540);
          await pumpToPreview(tester, controller, gateway);
          // The preview entry swaps in the wide three — let the flip
          // land (arm the ticker, then fly it out).
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));

          // Below the guard: circles, labels folded away.
          expect(find.text('对照原文'), findsNothing);
          final orb = orbCoreInView(tester);
          final raw = tester.getRect(
            find.byKey(const Key('session-raw-toggle')),
          );
          final cancel = tester.getRect(
            find.byKey(const Key('session-cancel')),
          );
          expect(raw.intersect(orb).isEmpty, isTrue, reason: 'raw vs orb');
          expect(
            cancel.intersect(orb).isEmpty,
            isTrue,
            reason: 'cancel vs orb',
          );
          final slot = tester.getRect(find.byType(SessionPanel));
          final rowStart =
              slot.left + SrGeometry.cardMargin + SrSpace.cornerInset;
          final rowEnd =
              slot.right - SrGeometry.cardMargin - SrSpace.cornerInset;
          if (dir == stage.GrowthDirection.upRight) {
            expect(cancel.right, closeTo(rowEnd, 1), reason: '左下右对齐');
          } else {
            expect(raw.left, closeTo(rowStart, 1), reason: 'row-start');
          }
          await windDown(tester, controller);
        }
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
        // The list's tail clearance (小修 13): the anchor band (96)
        // while the orb anchors the bottom edge; the md floor (12) at
        // the top quadrants — the last entry row never kisses the
        // card's bottom edge. Scroll the tail itself into the built
        // range first (the list builds lazily).
        await tester.dragUntilVisible(
          find.byKey(const Key('quick-tail-clearance')),
          panelScrollable(),
          const Offset(0, -60),
        );
        expect(
          tester
              .widget<SizedBox>(find.byKey(const Key('quick-tail-clearance')))
              .height,
          dir.growUp ? SrGeometry.anchorInset * 2 : SrSpace.md,
        );
        await controller.closeQuick();
        await tester.pump(const Duration(milliseconds: 700));
      });
    }
  });

  group('body scrollbar hangs on the window edge (小修 16)', () {
    /// The auto scrollbar exists only on desktop platforms — the
    /// MaterialScrollBehavior attaches one around every scrollable — so
    /// the guards run as a windows-only variant (the framework resets
    /// the platform override around the body properly). Whatever the
    /// widest text line does, the bar's box must reach the body's
    /// CONTENT edge (the fade spans the body stack; the content rides
    /// inset by contentInset on both sides), never hug the paragraph.

    /// Narrow lines, many of them: the body must scroll while the widest
    /// line stays far short of the body's width.
    const narrowLines =
        '短句一\n短句二\n短句三\n短句四\n短句五\n短句六\n'
        '短句七\n短句八\n短句九\n短句十\n短句十一\n短句十二\n'
        '短句十三\n短句十四\n短句十五\n短句十六\n短句十七\n短句十八\n'
        '短句十九\n短句二十\n短句廿一\n短句廿二\n短句廿三\n短句廿四';

    Finder sessionScrollbar() => find.descendant(
      of: find.byType(SessionPanel),
      matching: find.byType(Scrollbar),
    );

    Finder sessionScrollable() => find.descendant(
      of: find.byType(SessionPanel),
      matching: find.byType(Scrollable),
    );

    testWidgets('the stream face scrollbar rides the body edge', (
      tester,
    ) async {
      final gateway = FakeGateway();
      final window = RecordingStageWindow();
      final controller = await pumpController(
        tester,
        gateway,
        stageWindow: window,
      );
      await pumpToRecording(tester, controller);
      gateway.emit(const BridgeEvent.liveTranscriptUpdated(text: narrowLines));
      await tester.pump();

      // The premise: the scroll is actually engaged.
      final scroll = tester.state<ScrollableState>(sessionScrollable());
      expect(scroll.position.maxScrollExtent, greaterThan(0));

      final body = tester.getRect(find.byKey(const Key('session-top-fade')));
      final bar = tester.getRect(sessionScrollbar());
      expect(
        bar.right,
        closeTo(body.right - SrSpace.contentInset, 0.5),
        reason: 'the thumb hangs on the window edge, not the text',
      );
      await windDown(tester, controller);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('the preview scrollbar rides the body edge', (tester) async {
      final gateway = FakeGateway();
      final window = RecordingStageWindow();
      final controller = await pumpController(
        tester,
        gateway,
        stageWindow: window,
      );
      await pumpToPreview(
        tester,
        controller,
        gateway,
        chunks: const [narrowLines],
      );

      // The premise: the scroll is actually engaged.
      final scroll = tester.state<ScrollableState>(sessionScrollable());
      expect(scroll.position.maxScrollExtent, greaterThan(0));

      final body = tester.getRect(find.byKey(const Key('session-top-fade')));
      final bar = tester.getRect(sessionScrollbar());
      expect(
        bar.right,
        closeTo(body.right - SrSpace.contentInset, 0.5),
        reason: 'the thumb hangs on the window edge, not the text',
      );
      await windDown(tester, controller);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  testWidgets('the thinking stream drives the 思考中 three-piece and the '
      'marquee, then hands over once', (tester) async {
    final gateway = FakeGateway();
    final window = RecordingStageWindow();
    final controller = await pumpController(
      tester,
      gateway,
      stageWindow: window,
    );

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.phase, BridgeSessionState.rectifying);
    // Zero-trace before any thinking token: plain 修正中, no marquee.
    expect(find.text('修正中'), findsOneWidget);
    expect(find.byKey(const Key('thinking-marquee')), findsNothing);
    expect(controller.thinkingActive, isFalse);

    // First thinking token: the word flips, the dot breathes accent, the
    // elapsed slot appears (the recording timer's family), the marquee
    // mounts over the card (shimmer from the first token — text waits
    // for the reveal gate).
    gateway.streamThinking(['先听一遍原句,想清楚时间与术语的处理']);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('思考中'), findsOneWidget);
    expect(controller.thinkingActive, isTrue);
    expect(find.byKey(const Key('thinking-marquee')), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);

    // Feed through the reveal gate (startVis + capacity lines at the
    // real card geometry) — pump in ticker frames so the machine folds
    // and reveals.
    for (var i = 0; i < 14; i++) {
      gateway.streamThinking(['思考内容占位思考内容占位思考内容占位思']);
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(controller.thinking!.revealed, isTrue);

    // The one-way handover: the body's first chunk flips the word back
    // WHILE STILL RECTIFYING (the preview transition comes later), and
    // the marquee unmounts after its fade.
    gateway.emit(BridgeEvent.rectifiedTextChunk(delta: '修正好的文本'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.phase, BridgeSessionState.rectifying);
    expect(find.text('修正中'), findsOneWidget);
    expect(controller.thinkingActive, isFalse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('thinking-marquee')), findsNothing);
    // Late thinking after the handover never relights anything.
    gateway.streamThinking(['迟到的思考']);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('修正中'), findsOneWidget);
    expect(find.byKey(const Key('thinking-marquee')), findsNothing);

    expect(controller.previewText, '修正好的文本');
    gateway.emit(
      BridgeEvent.sessionStateChanged(
        from: BridgeSessionState.rectifying,
        to: BridgeSessionState.preview,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.phase, BridgeSessionState.preview);
    await windDown(tester, controller);
  });

  testWidgets('a thinking-less attempt never shows the marquee (zero-trace)', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final window = RecordingStageWindow();
    final controller = await pumpController(
      tester,
      gateway,
      stageWindow: window,
    );

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    // Rectifying with no thinking token: plain 修正中, no machine
    // activity, no marquee — the signal-driven zero-trace.
    expect(find.text('修正中'), findsOneWidget);
    expect(controller.thinkingActive, isFalse);
    expect(find.byKey(const Key('thinking-marquee')), findsNothing);
    await windDown(tester, controller);
  });

  testWidgets('a reroll mints a fresh marquee machine', (tester) async {
    final gateway = FakeGateway();
    final window = RecordingStageWindow();
    final controller = await pumpController(
      tester,
      gateway,
      stageWindow: window,
    );

    await pumpToPreview(tester, controller, gateway);
    await controller.reroll();
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.phase, BridgeSessionState.rectifying);
    // A fresh machine: no first token yet.
    expect(controller.thinking!.thinkStarted, isFalse);
    gateway.streamThinking(['第二轮思考']);
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.thinkingActive, isTrue);
    await windDown(tester, controller);
  });
}

String textOf(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data!;
