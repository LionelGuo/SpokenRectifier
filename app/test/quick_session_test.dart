/// Ticket 04: the session window's 「快速」 phase word and the pin-hotkey
/// disarm on `QuickMarked`. The settings third card lives in
/// `settings_window_test.dart`; this file locks the window reaction.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/hotkey_binding.dart';
import 'package:spokenrectifier_app/src/rust/api/engine.dart'
    show BridgeEvent,
        BridgeSessionState;

import 'fake_gateway.dart';
import 'fake_rectify_store.dart';

/// Same recorder [pin_hotkey_test] uses — kept local so this file
/// does not import another test's `main`.
class RecordingPinHotkeyRegistrar implements PinHotkeyRegistrar {
  final calls = <String>[];
  VoidCallback? onPin;

  @override
  Future<void> register(HotkeyBinding chord, void Function() onPin) async {
    calls.add('register');
    this.onPin = onPin;
  }

  @override
  Future<void> unregister() async {
    calls.add('unregister');
    onPin = null;
  }

  void press() => onPin?.call();
}

Future<SpeechController> pumpController(
  WidgetTester tester,
  FakeGateway gateway, {
  PinHotkeyRegistrar? pinHotkey,
}) async {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
    pinHotkey: pinHotkey,
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

void main() {
  testWidgets('an upgrade flips the listening word to 快速', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    expect(find.text('聆听中'), findsOneWidget);
    expect(find.text('快速'), findsNothing);
    expect(controller.quickMarked, isFalse);

    gateway.emit(const BridgeEvent.quickMarked());
    await tester.pump();
    expect(controller.phase, BridgeSessionState.recording);
    expect(controller.quickMarked, isTrue);
    expect(find.text('快速'), findsOneWidget);
    expect(find.text('聆听中'), findsNothing);

    await windDown(tester, controller);
  });

  testWidgets('entering rectifying restores 修正中 and clears the flag', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    gateway.emit(const BridgeEvent.quickMarked());
    await tester.pump();
    expect(find.text('快速'), findsOneWidget);

    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.phase, BridgeSessionState.rectifying);
    expect(controller.quickMarked, isFalse);
    expect(find.text('修正中'), findsOneWidget);
    expect(find.text('快速'), findsNothing);

    await windDown(tester, controller);
  });

  testWidgets('preview — happy path and demotion — paints 预览, never 快速', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    gateway.emit(const BridgeEvent.quickMarked());
    await tester.pump();
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(const ['待确认文本']);
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.phase, BridgeSessionState.preview);
    expect(find.text('预览'), findsOneWidget);
    expect(find.text('快速'), findsNothing);

    await windDown(tester, controller);

    // Failure demotion: Recording → Preview with the flag already
    // cleared on the transition. The word follows the phase; no extra
    // banner.
    await pumpToRecording(tester, controller);
    gateway.emit(const BridgeEvent.quickMarked());
    await tester.pump();
    gateway.emit(
      const BridgeEvent.sessionStateChanged(
        from: BridgeSessionState.recording,
        to: BridgeSessionState.preview,
      ),
    );
    await tester.pump();
    expect(controller.phase, BridgeSessionState.preview);
    expect(controller.quickMarked, isFalse);
    expect(find.text('预览'), findsOneWidget);
    expect(find.text('快速'), findsNothing);
    expect(find.byKey(const Key('sr-toast')), findsNothing);

    await windDown(tester, controller);
  });

  testWidgets('QuickMarked disarms the pin even if this session never pinned', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final registrar = RecordingPinHotkeyRegistrar();
    final controller = await pumpController(
      tester,
      gateway,
      pinHotkey: registrar,
    );

    await pumpToRecording(tester, controller);
    expect(registrar.calls, ['register']);

    gateway.emit(const BridgeEvent.quickMarked());
    await tester.pump();
    expect(registrar.calls, ['register', 'unregister']);

    // A leftover press after the disarm never reaches the bridge
    // (shell belt; the engine would refuse too).
    registrar.press();
    await tester.pump();
    expect(gateway.commands.where((c) => c == 'pinPlaceholder'), isEmpty);

    // Capture-end while still recording must not re-hang the chord.
    await controller.setHotkeysPaused(true);
    await controller.setHotkeysPaused(false);
    expect(registrar.calls.where((c) => c == 'register').length, 1);

    await windDown(tester, controller);
  });

  testWidgets('an unupgraded recording keeps 聆听中 and the pin', (tester) async {
    final gateway = FakeGateway();
    final registrar = RecordingPinHotkeyRegistrar();
    final controller = await pumpController(
      tester,
      gateway,
      pinHotkey: registrar,
    );

    await pumpToRecording(tester, controller);
    expect(find.text('聆听中'), findsOneWidget);
    expect(find.text('快速'), findsNothing);
    expect(registrar.calls, ['register']);
    registrar.press();
    await tester.pump();
    expect(gateway.commands.where((c) => c == 'pinPlaceholder').length, 1);

    await windDown(tester, controller);
  });
}
