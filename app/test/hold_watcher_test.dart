/// Ticket 03: the primary-hotkey hold watcher as the shell sees it —
/// swallow repeats of one physical hold on or off the quick-mode switch,
/// keep the tap path when the host cannot poll, and never start a watch
/// from the orb (球左键不跟).
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
  test('a recording press stops on its release, switch on or off', () async {
    final gateway = FakeGateway()..watchHoldSucceeds = true;
    final controller = makeController(gateway);

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('startSession'));
    expect(controller.phase, BridgeSessionState.recording);
    expect(gateway.commands, contains('watchHold:open:17,18,86'));

    // The hold released without upgrading (the switch-off mark is
    // refused); the recording continues. The next press is new.
    gateway.holding = false;
    await controller.hotkeyToggle();
    // No stop on keyDown: the watch owns this press's release. A
    // switch-off hold would otherwise toggle through auto-repeat —
    // the start/stop flicker the 2026-09-19 matrix caught.
    expect(gateway.commands, contains('watchHold:stop:17,18,86'));
    expect(gateway.commands, isNot(contains('stopSession')));
  });

  test('a host that cannot poll keeps today\'s keyDown stop', () async {
    final gateway = FakeGateway(); // watchHoldSucceeds defaults false
    final controller = makeController(gateway);

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('startSession'));
    expect(controller.phase, BridgeSessionState.recording);

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('stopSession'));
  });

  test('a live watch swallows WM_HOTKEY repeats of the same hold', () async {
    final gateway = FakeGateway()..watchHoldSucceeds = true;
    final controller = makeController(gateway);

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('startSession'));
    expect(gateway.commands, contains('watchHold:open:17,18,86'));
    expect(gateway.holding, isTrue);

    await controller.hotkeyToggle();
    await controller.hotkeyToggle();
    expect(gateway.commands.where((c) => c == 'startSession').length, 1);
    expect(gateway.commands, isNot(contains('stopSession')));
    expect(gateway.commands.where((c) => c.startsWith('watchHold')).length, 1);
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
    expect(gateway.commands.where((c) => c.startsWith('watchHold')), isEmpty);

    await controller.hotkeyToggle();
    expect(gateway.commands, contains('stopSession'));
  });
}
