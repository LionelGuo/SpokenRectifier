/// Ticket 03: the primary-hotkey hold watcher as the shell sees it —
/// swallow repeats, keep the tap path when the switch is off, and never
/// start a watch from the orb (球左键不跟).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/hotkey_binding.dart';
import 'package:spokenrectifier_app/src/rust/api.dart' show BridgeSessionState;

import 'fake_gateway.dart';

SpeechController makeController(FakeGateway gateway) {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
    primaryChord: HotkeyBinding.primaryDefault,
  );
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  test(
    'with the switch off a second press still stops — today\'s tap path',
    () async {
      final gateway = FakeGateway();
      final controller = makeController(gateway);

      await controller.hotkeyToggle();
      expect(gateway.commands, contains('startSession'));
      expect(controller.phase, BridgeSessionState.recording);
      // The shell still asks; the Rust gate returns false.
      expect(gateway.commands, contains('watchHold:open:17,18,86'));

      await controller.hotkeyToggle();
      expect(gateway.commands, contains('stopSession'));
    },
  );

  test('a live watch swallows WM_HOTKEY repeats of the same hold', () async {
    final gateway = FakeGateway()..watchHoldSucceeds = true;
    final controller = makeController(gateway);

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('startSession'));
    expect(gateway.commands, contains('watchHold:open:17,18,86'));
    expect(gateway.holding, isTrue);

    await controller.hotkeyToggle();
    await controller.hotkeyToggle();
    expect(
      gateway.commands.where((c) => c == 'startSession').length,
      1,
    );
    expect(gateway.commands, isNot(contains('stopSession')));
    expect(
      gateway.commands.where((c) => c.startsWith('watchHold')).length,
      1,
    );
  });

  test(
    'a short opening release then a second press arms the tap-to-stop watch',
    () async {
      final gateway = FakeGateway()..watchHoldSucceeds = true;
      final controller = makeController(gateway);

      await controller.hotkeyToggle();
      gateway.holding = false; // the opening watch ended on release

      await controller.hotkeyToggle();
      expect(gateway.commands, contains('watchHold:stop:17,18,86'));
      expect(gateway.commands, isNot(contains('stopSession')));
    },
  );

  test('the orb start does not arm a watch', () async {
    final gateway = FakeGateway()..watchHoldSucceeds = true;
    final controller = makeController(gateway);

    await controller.orbPrimary();
    expect(gateway.commands, ['startSession']);
    expect(gateway.holding, isFalse);
  });

  test('the orb still stops on click while a watch is live', () async {
    final gateway = FakeGateway()..watchHoldSucceeds = true;
    final controller = makeController(gateway);

    await controller.hotkeyToggle();
    expect(gateway.holding, isTrue);

    await controller.orbPrimary();
    expect(gateway.commands, contains('stopSession'));
  });

  test('an empty bind never arms a watch', () async {
    final gateway = FakeGateway()..watchHoldSucceeds = true;
    final controller = SpeechController(
      gateway: gateway,
      scriptedPhrases: const [],
      primaryChord: const HotkeyBinding.none(),
    );
    addTearDown(controller.dispose);

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('startSession'));
    expect(
      gateway.commands.where((c) => c.startsWith('watchHold')),
      isEmpty,
    );

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('stopSession'));
  });
}
