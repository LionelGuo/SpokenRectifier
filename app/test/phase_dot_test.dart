/// Ticket 24: the header phase dot's breath. The dot breathes exactly
/// while `live` — 聆听 (「快速」 included: the upgrade keeps the
/// recording-red breath) and 思考中 — and paints steady in every other
/// phase (修正中 / 预览). The strengthened amplitude is locked here so
/// a future tweak is deliberate: valley alpha 0.3, glow peak 0.6, the
/// 2200ms `SrMotion.breathe` period untouched.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart';
import 'package:spokenrectifier_app/src/rust/api/engine.dart'
    show BridgeEvent,
        BridgeSessionState;
import 'package:spokenrectifier_app/src/session/session_panel.dart'
    show phaseDotGlowPeakAlpha, phaseDotValleyAlpha;

import 'fake_gateway.dart';
import 'fake_rectify_store.dart';

Future<SpeechController> pumpController(
  WidgetTester tester,
  FakeGateway gateway,
) async {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    SpokenRectifierApp(
      controller: controller,
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

/// The dot's decoration as currently painted.
BoxDecoration dotDecoration(WidgetTester tester) =>
    tester.widget<Container>(
      find.byKey(const Key('session-phase-dot')),
    ).decoration! as BoxDecoration;

double dotAlpha(WidgetTester tester) => dotDecoration(tester).color!.a;

double? dotGlow(WidgetTester tester) {
  final shadows = dotDecoration(tester).boxShadow;
  return shadows == null || shadows.isEmpty ? null : shadows.single.color.a;
}

void main() {
  testWidgets('the breath swings valley 0.3 to peak 1.0 with the glow in step', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    expect(find.text('聆听中'), findsOneWidget);

    // The mount frame parks the controller's clock at zero (11 号票
    // pitfall): the first painted frame IS the valley.
    expect(dotAlpha(tester), closeTo(phaseDotValleyAlpha, 0.001));
    expect(dotGlow(tester), closeTo(0.0, 0.001));

    // Halfway up the 2200ms ramp: alpha 0.3 + 0.5 * 0.7.
    await tester.pump(const Duration(milliseconds: 1100));
    expect(dotAlpha(tester), closeTo(0.65, 0.001));

    // The peak: full alpha, the glow swollen to its raised ceiling.
    await tester.pump(const Duration(milliseconds: 1100));
    expect(dotAlpha(tester), closeTo(1.0, 0.001));
    expect(dotGlow(tester), closeTo(phaseDotGlowPeakAlpha, 0.001));

    // The period itself stays the slow 2200ms cycle.
    expect(SrMotion.breathe, const Duration(milliseconds: 2200));

    await windDown(tester, controller);
  });

  testWidgets('「快速」 keeps the same recording breath', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    gateway.emit(const BridgeEvent.quickMarked());
    await tester.pump();
    expect(find.text('快速'), findsOneWidget);

    // Same wave, same amplitude: valley now, peak half a cycle on.
    expect(dotAlpha(tester), closeTo(phaseDotValleyAlpha, 0.001));
    await tester.pump(const Duration(milliseconds: 1100));
    expect(dotAlpha(tester), closeTo(0.65, 0.001));

    await windDown(tester, controller);
  });

  testWidgets('修正中 paints steady and thinking resumes the breath', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('修正中'), findsOneWidget);

    // Steady: full alpha, no glow, and nothing moves over a half cycle.
    expect(dotAlpha(tester), 1.0);
    expect(dotGlow(tester), isNull);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(dotAlpha(tester), 1.0);

    // The first thinking token flips the word and relights the breath:
    // the clock has run 350ms past the parked zero, so the dot sits
    // mid-ramp — visibly off both endpoints and moving.
    gateway.streamThinking(const ['让我想想']);
    await tester.pump();
    expect(find.text('思考中'), findsOneWidget);
    final mid = dotAlpha(tester);
    expect(mid, lessThan(0.95));
    await tester.pump(const Duration(milliseconds: 1100));
    expect(dotAlpha(tester), isNot(closeTo(mid, 0.05)));

    await windDown(tester, controller);
  });

  testWidgets('预览 paints steady after the handover', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(const ['待确认文本']);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('预览'), findsOneWidget);

    expect(dotAlpha(tester), 1.0);
    expect(dotGlow(tester), isNull);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(dotAlpha(tester), 1.0);

    await windDown(tester, controller);
  });
}
