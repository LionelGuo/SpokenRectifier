/// Ticket 21: the pin chord (Alt+B) lifecycle and the capsule surface —
/// the hotkey registers exactly while listening and hands the key back
/// on every exit path, the press rides the bridge only in listening,
/// and the main surface renders sentinels as number capsules (never the
/// bare `‡N‡`) in both listening and rectifying.

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart' show SrCapsule;
import 'package:spokenrectifier_app/src/rust/api.dart'
    show BridgeEvent, BridgeSessionState;

import 'fake_gateway.dart';

/// A registrar that records the lifecycle and keeps the armed callback,
/// so tests can press the chord exactly the way the platform would.
class RecordingPinHotkeyRegistrar implements PinHotkeyRegistrar {
  final calls = <String>[];
  VoidCallback? onPin;

  @override
  Future<void> register(void Function() onPin) async {
    calls.add('register');
    this.onPin = onPin;
  }

  @override
  Future<void> unregister() async {
    calls.add('unregister');
    onPin = null;
  }

  /// The chord press, as the platform handler delivers it.
  void press() => onPin?.call();
}

Future<SpeechController> pumpController(
  WidgetTester tester,
  FakeGateway gateway, {
  required PinHotkeyRegistrar pinHotkey,
}) async {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
    pinHotkey: pinHotkey,
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(SpokenRectifierApp(controller: controller));
  return controller;
}

/// Ends any open session and pumps past every trailing span (the
/// collapse choreography, the receipt flash) so the test closes clean.
Future<void> windDown(WidgetTester tester, SpeechController controller) async {
  if (controller.phase != BridgeSessionState.idle) {
    await controller.cancelSession();
  }
  await tester.pump(const Duration(milliseconds: 1200));
}

void main() {
  testWidgets('the chord lives exactly while listening, every exit path', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final registrar = RecordingPinHotkeyRegistrar();
    final controller = await pumpController(
      tester,
      gateway,
      pinHotkey: registrar,
    );

    // Idle owns nothing: an idle Alt+B belongs to the system, so no
    // registration exists before a session opens.
    expect(registrar.calls, isEmpty);

    // Entering listening takes the chord.
    await controller.startSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(registrar.calls, ['register']);

    // Ending listening by the main flow hands it back at once.
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(registrar.calls, ['register', 'unregister']);
    await windDown(tester, controller);

    // A second session: the cancel path hands it back too.
    registrar.calls.clear();
    await controller.startSession();
    await tester.pump(const Duration(milliseconds: 350));
    await controller.cancelSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(registrar.calls, ['register', 'unregister']);
    // Past the receipt flash, so no timer outlives the tree.
    await tester.pump(const Duration(milliseconds: 1200));
  });

  testWidgets('a press pins only while listening; outside it is refused', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final registrar = RecordingPinHotkeyRegistrar();
    final controller = await pumpController(
      tester,
      gateway,
      pinHotkey: registrar,
    );

    // The bridge rejects the pin outside listening (the engine's rule,
    // mirrored by the fake)…
    await expectLater(gateway.pinPlaceholder(), throwsStateError);
    int pins() =>
        gateway.commands.where((command) => command == 'pinPlaceholder').length;
    expect(pins(), 1); // the rejected direct call above

    // …and the controller's action is a no-op there, so the chord's
    // press never even reaches the wire.
    await controller.pinAction();
    expect(pins(), 1);

    // While listening the press rides the bridge.
    await controller.startSession();
    await tester.pump(const Duration(milliseconds: 350));
    registrar.press();
    await tester.pump();
    expect(pins(), 2);

    await windDown(tester, controller);
    // Past the session the action is again a no-op (the unregister
    // race never reaches the wire either).
    await controller.pinAction();
    expect(pins(), 2);
  });

  testWidgets('pins render as number capsules and survive transcript updates', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final registrar = RecordingPinHotkeyRegistrar();
    final controller = await pumpController(
      tester,
      gateway,
      pinHotkey: registrar,
    );

    await controller.startSession();
    await tester.pump(const Duration(milliseconds: 350));

    // Only a pin, no speech yet: the capsule is the whole content (the
    // empty-state hint is gone — 只钉不说 is still an utterance).
    registrar.press();
    await tester.pump();
    expect(find.byKey(const ValueKey('pin-capsule-1')), findsOneWidget);
    expect(find.text('开始说话…'), findsNothing);

    // The next transcript update keeps the capsule in place; no bare
    // sentinel shape ever paints on the main surface.
    gateway.emit(const BridgeEvent.liveTranscriptUpdated(text: '话‡1‡继续说'));
    await tester.pump();
    expect(find.byKey(const ValueKey('pin-capsule-1')), findsOneWidget);
    expect(find.textContaining('‡'), findsNothing);

    // Inline, surrounded by text, the capsule stays a small chip — never
    // a line-swallowing block. The spacer's reservation carries the
    // degenerate capsule's width plus the family's side breathing on
    // both sides (the circle itself is painted inside it by the
    // surface's foreground layer). Measured past the window's entrance
    // animation, which scales the whole stage up from 0.94.
    await tester.pump(const Duration(seconds: 1));
    final capsule = tester.getRect(find.byKey(const ValueKey('pin-capsule-1')));
    expect(capsule.height, SrCapsule.height);
    expect(capsule.width, SrCapsule.height + 2 * SrCapsule.sidePad);

    // Consecutive pins each get their own number.
    registrar.press();
    registrar.press();
    await tester.pump();
    expect(find.byKey(const ValueKey('pin-capsule-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-capsule-3')), findsOneWidget);

    await windDown(tester, controller);
  });

  testWidgets('sentinels in the rectifying stream collapse into capsules', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final registrar = RecordingPinHotkeyRegistrar();
    final controller = await pumpController(
      tester,
      gateway,
      pinHotkey: registrar,
    );

    await controller.startSession();
    await tester.pump(const Duration(milliseconds: 350));
    registrar.press();
    await tester.pump();
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.phase, BridgeSessionState.rectifying);

    // The rectify stream carries the sentinel through: the read-only
    // surface paints a capsule, never the four characters. (Chunks are
    // fed directly so the phase stays rectifying — the preview's own
    // surface is ticket 22's to build.)
    gateway.emit(const BridgeEvent.rectifiedTextChunk(delta: '结果一‡1‡收尾'));
    await tester.pump();
    expect(find.byKey(const ValueKey('pin-capsule-1')), findsOneWidget);
    expect(find.textContaining('‡'), findsNothing);

    await windDown(tester, controller);
  });
}
