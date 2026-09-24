/// Ticket 26: the two-tier control motion. Press fills (按下/松开的填充
/// 变化) ride `fast` — feedback tracks the finger; discrete switches
/// (选中/采集态) ride `fade`/`curveFade`, and the labels and icons ride
/// their container's window instead of snapping. The press recipe is the
/// shared [SrPressFill] scrim; the guards drive it through the real
/// surfaces — a plain SrButton, the quick panel's scenario chip, the
/// settings hotkey row, and the session footer's ghost buttons.
library;

import 'dart:io' show Directory;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/hotkey_binding.dart';
import 'package:spokenrectifier_app/src/rust/api/engine.dart'
    show BridgeSessionState;
import 'package:spokenrectifier_app/src/rust/api/library.dart'
    show BridgeScenario;
import 'package:spokenrectifier_app/src/design/controls.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart';
import 'package:spokenrectifier_app/src/settings/settings_general_pane.dart';
import 'package:spokenrectifier_app/src/shell/window_stage.dart' as stage;

import 'fake_gateway.dart';
import 'fake_rectify_store.dart';

/// A do-nothing stage window: geometry comes from the work areas it
/// reports (the same 1920×1080 rect the view is pinned to), never from
/// platform channels — and never from the developer's real ui.toml,
/// whose persisted panel size would skew the footer's morph layout.
/// Seated so the ball lands at screen (1500, 900) of the 1920×1080
/// work area — the bottom-right quadrant (widget_test's upLeft seat),
/// where the recording capsule rides the footer's row clear of the orb.
class FakeStageWindow implements stage.StageWindow {
  @override
  Future<Offset> getPosition() async => const Offset(1452, 852);

  @override
  Future<Size> getSize() async => SrGeometry.orbFootprint;

  @override
  Future<Rect> seatBoundsPhysical(Rect physical) async => physical;

  @override
  Future<void> setCardRegion(Rect? windowRect, {bool ellipse = false}) async {}

  @override
  Future<stage.WorkAreas> workAreas() async => stage.WorkAreas(
    logical: const [Rect.fromLTWH(0, 0, 1920, 1080)],
    physical: const [Rect.fromLTWH(0, 0, 1920, 1080)],
    factors: const [1.0],
  );

  @override
  Offset? pointerOnScreen() => null;

  @override
  Future<void> focus() async {}
}

Future<SpeechController> pumpController(
  WidgetTester tester,
  FakeGateway gateway,
) async {
  // Scratch prefs: a fresh ui.toml world (the default 420×560 panel),
  // so the shell's layout is the canonical one.
  final dir = Directory.systemTemp.createTempSync('sr-control-motion-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
    uiPrefsDirs: [dir.path],
  );
  addTearDown(controller.dispose);
  // The panel-period window is the whole work area (02 号票) — pin the
  // view to it (widget_test's convention) so view coordinates match
  // window coordinates and the footer band lays out where it does on
  // device: cancel capsule clear of the ball.
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    SpokenRectifierApp(
      controller: controller,
      stageWindow: FakeStageWindow(),
      rectifyStore: FakeRectifyBehaviorStore(),
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

Future<void> windDown(WidgetTester tester, SpeechController controller) async {
  if (controller.phase != BridgeSessionState.idle) {
    await controller.cancelSession();
  }
  await tester.pump(const Duration(milliseconds: 1200));
}

/// The press scrim's CURRENT (animated) alpha on the first fill under
/// [from]. An AnimatedContainer's widget fields always read as the
/// tween's TARGET, so the live value comes off the render tree's
/// foreground DecoratedBox instead — the one borderless box in the
/// fill's subtree (a kbd chip inside a footer capsule carries one).
double scrimAlpha(WidgetTester tester, Finder from) {
  final fill = find
      .descendant(of: from, matching: find.byType(SrPressFill))
      .first;
  final render = tester.renderObject<RenderDecoratedBox>(
    find.descendant(
      of: fill,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            (widget.decoration as BoxDecoration?)?.border == null,
      ),
    ),
  );
  return (render.decoration as BoxDecoration).color!.a;
}

/// The current (animated) fill color of a control's base box — the
/// bordered BACKGROUND DecoratedBox (the selection wash layered above
/// it is bordered too, but foreground; the borderless foreground one is
/// the press scrim).
Color boxColor(WidgetTester tester, Finder from) =>
    (tester
                .renderObject<RenderDecoratedBox>(
                  find.descendant(
                    of: from,
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is DecoratedBox &&
                          widget.position == DecorationPosition.background &&
                          (widget.decoration as BoxDecoration?)?.border != null,
                    ),
                  ),
                )
                .decoration
            as BoxDecoration)
        .color!;

/// The current (animated) alpha of a control's blue selection wash —
/// the bordered FOREGROUND box riding the same AnimatedContainer.
double washAlpha(WidgetTester tester, Finder from) =>
    (tester
                .renderObject<RenderDecoratedBox>(
                  find.descendant(
                    of: from,
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is DecoratedBox &&
                          widget.position == DecorationPosition.foreground &&
                          (widget.decoration as BoxDecoration?)?.border != null,
                    ),
                  ),
                )
                .decoration
            as BoxDecoration)
        .color!
        .a;

void main() {
  testWidgets('SrButton press fill eases in on press and out on release', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SrButton(label: '保存', onTap: () {}),
          ),
        ),
      ),
    );
    final button = find.byType(SrButton);
    expect(scrimAlpha(tester, button), 0.0);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('保存')),
    );
    await tester.pump();
    // Birth frame: the ease has just been aimed at the scrim.
    expect(scrimAlpha(tester, button), closeTo(0.0, 0.001));
    await tester.pump(const Duration(milliseconds: 120));
    expect(scrimAlpha(tester, button), closeTo(0.10, 0.001));

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(scrimAlpha(tester, button), 0.0);
  });

  testWidgets('a disabled SrButton never paints the press scrim', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SrButton(label: '保存')),
        ),
      ),
    );
    final button = find.byType(SrButton);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('保存')),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(scrimAlpha(tester, button), 0.0);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('a quick scenario chip pick crossfades wash and label', (
    tester,
  ) async {
    final gateway = FakeGateway()
      ..scenarioLibrary.add(
        const BridgeScenario(name: '论文', directive: '学术书面语'),
      );
    final controller = await pumpController(tester, gateway);
    await controller.loadScenarios();
    await tester.pump(const Duration(milliseconds: 350));

    controller.orbSecondary();
    // The card grows out of the disc over 640ms; the list's lazy
    // children mount once the viewport is real — and the slivers build
    // on the frame AFTER that. Two pumps.
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('论文'), findsOneWidget);

    final chip = find.byKey(const Key('quick-scenario:论文'));
    double washOf() => washAlpha(tester, chip);
    Color labelColor() => tester
        .renderObject<RenderParagraph>(find.text('论文'))
        .text
        .style!
        .color!;

    final restLabel = labelColor();

    await tester.tap(chip);
    await tester.pump();
    // Birth frame: nothing has moved yet.
    expect(washOf(), 0.0);
    expect(labelColor(), restLabel);

    await tester.pump(const Duration(milliseconds: 90));
    // Mid-flight: both the wash and the label are between their ends.
    expect(washOf(), greaterThan(0.0));
    expect(labelColor(), isNot(restLabel));
    await tester.pump(const Duration(milliseconds: 90));
    // Settled: the picked chip sits at the selected wash's full ink.
    expect(washOf(), closeTo(srPalette(tester.element(chip)).accentSoft.a, 0.001));
    expect(controller.selectedScenario, '论文');

    await windDown(tester, controller);
  });

  testWidgets('the hotkey row crossfades into and out of capture', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsGeneralPane(
            themeMode: ThemeMode.dark,
            orbVisible: true,
            primary: HotkeyBinding.primaryDefault,
            pin: HotkeyBinding.pinDefault,
            onThemePicked: (_) {},
            onOrbVisible: (_) {},
            onCapture: (_) {},
            onCommit: (_, _) async {},
          ),
        ),
      ),
    );
    await tester.pump();
    final row = find.byKey(const Key('settings-hotkey-primary'));
    double washOf() => washAlpha(tester, row);
    // The box's own label Text (its render object is the paragraph).
    Color labelColor() => tester
        .renderObject<RenderParagraph>(
          find.descendant(of: row, matching: find.byType(Text)),
        )
        .text
        .style!
        .color!;

    final restLabel = labelColor();

    await tester.tap(row);
    await tester.pump();
    // Birth frame: the render still holds the resting fill; the
    // capture label is mounted at once, its ink just arriving.
    expect(washOf(), 0.0);
    expect(find.text('按下组合键录制'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 90));
    // Mid-crossfade: the capture wash is arriving.
    expect(washOf(), greaterThan(0.0));
    await tester.pump(const Duration(milliseconds: 90));
    // Settled: capture wash at full ink, the resting label retired —
    // the switcher's outgoing child unmounts a frame past the window.
    await tester.pump(const Duration(milliseconds: 240));
    expect(washOf(), closeTo(srPalette(tester.element(row)).accentSoft.a, 0.001));
    expect(find.text('Ctrl+Alt+V'), findsNothing);

    // Handing capture to the other row crossfades this one back — and
    // brings the pin's own capture label in on the same window.
    final pinRow = find.byKey(const Key('settings-hotkey-pin'));
    await tester.tap(pinRow);
    // The switcher's clock starts at the FIRST frame after the tap —
    // draw it before elapsing, then ride the window out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    // A frame past the window's end: the outgoing capture label only
    // unmounts on the build after its reverse transition completes.
    await tester.pump();
    expect(
      find.descendant(of: row, matching: find.text('按下组合键录制')),
      findsNothing,
    );
    expect(
      find.descendant(of: pinRow, matching: find.text('按下组合键录制')),
      findsOneWidget,
    );
    expect(labelColor(), restLabel);
    expect(washOf(), 0.0);
  });

  testWidgets('a footer ghost button rides the fast press fill', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    // Preview's footer carries the three ghost capsules, hugging the
    // row's far side clear of the orb. (The recording capsule rides the
    // anchor's row beside the ball by design — on device the stage
    // window sits behind the panel and only the ball-disc punch
    // delivers it clicks, but the widget test has one window, and the
    // orb button's footprint box eats the capsule there.)
    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(const ['待确认文本']);
    await tester.pump(const Duration(milliseconds: 350));

    // 对照原文: the ghost whose tap keeps the preview footer intact
    // (reroll re-rectifies, cancel closes the session — both churn the
    // band mid-assert).
    final toggle = find.byKey(const Key('session-raw-toggle'));
    expect(
      find.descendant(of: toggle, matching: find.byType(SrPressFill)),
      findsOneWidget,
    );
    expect(scrimAlpha(tester, toggle), 0.0);

    final gesture = await tester.startGesture(tester.getCenter(toggle));
    await tester.pump();
    // Birth frame: the ease has just been aimed at the scrim.
    expect(scrimAlpha(tester, toggle), closeTo(0.0, 0.001));
    await tester.pump(const Duration(milliseconds: 120));
    expect(scrimAlpha(tester, toggle), closeTo(0.10, 0.001));

    await gesture.up();
    // Draw the frame the release rebuilds in, then ride the ease out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(scrimAlpha(tester, toggle), 0.0);

    await windDown(tester, controller);
  });

  testWidgets(
    'a theme segment darkens on press and turns blue only once picked',
    (tester) async {
      // 真机 round: the darken is the press's own transient — it must be
      // in at pointer-down, while the fill still rests — and the blue
      // highlight belongs to the selection state, which flips on release.
      var mode = ThemeMode.dark;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SettingsGeneralPane(
                themeMode: mode,
                orbVisible: true,
                primary: HotkeyBinding.primaryDefault,
                pin: HotkeyBinding.pinDefault,
                onThemePicked: (picked) => setState(() => mode = picked),
                onOrbVisible: (_) {},
                onCapture: (_) {},
                onCommit: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final light = find.byKey(const Key('settings-theme-light'));
      final restBox = boxColor(tester, light);

      final gesture = await tester.startGesture(tester.getCenter(light));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // Held down: the scrim is fully in, the fill is still resting —
      // and no blue: the highlight waits for the pick.
      expect(scrimAlpha(tester, light), closeTo(0.10, 0.001));
      expect(washAlpha(tester, light), 0.0);

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      // Released into the pick: scrim lifted, the blue wash arrived.
      expect(scrimAlpha(tester, light), 0.0);
      expect(
        washAlpha(tester, light),
        closeTo(srPalette(tester.element(light)).accentSoft.a, 0.001),
      );

      // 真机 round 2: picking another segment retires this one — its blue
      // fades out ALONE on the alpha-only wash while the base box holds
      // still, so the exit sweeps no darker fill across the old chip.
      final dark = find.byKey(const Key('settings-theme-dark'));
      await tester.tap(dark);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(washAlpha(tester, light), 0.0);
      expect(boxColor(tester, light), restBox);
    },
  );
}
