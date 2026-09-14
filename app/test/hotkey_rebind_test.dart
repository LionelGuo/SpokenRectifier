/// Ticket 16: the two product chords hot-swap through the controller —
/// capture unregisters both, a file change re-reads and applies, the
/// main-flow chord swaps at once, the pin swaps the object (armed
/// mid-listen: hand the old back and take the new; idle: next listen).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/hotkey_binding.dart';
import 'package:spokenrectifier_app/ui_prefs.dart';

import 'fake_gateway.dart';

class RecordingPrimaryHotkeyRegistrar implements PrimaryHotkeyRegistrar {
  final calls = <String>[];
  HotkeyBinding? current;

  @override
  Future<void> apply(HotkeyBinding chord, VoidCallback onPress) async {
    calls.add('apply:${chord.wire}');
    current = chord.isNone ? null : chord;
  }

  @override
  Future<void> unregister() async {
    calls.add('unregister');
    current = null;
  }
}

class RecordingPinHotkeyRegistrar implements PinHotkeyRegistrar {
  final calls = <String>[];
  HotkeyBinding? lastChord;

  @override
  Future<void> register(HotkeyBinding chord, VoidCallback onPin) async {
    calls.add('register');
    lastChord = chord;
  }

  @override
  Future<void> unregister() async {
    calls.add('unregister');
    lastChord = null;
  }
}

SpeechController makeController({
  required FakeGateway gateway,
  required List<String> dirs,
  RecordingPrimaryHotkeyRegistrar? primary,
  RecordingPinHotkeyRegistrar? pin,
  HotkeyBinding primaryChord = HotkeyBinding.primaryDefault,
  HotkeyBinding pinChord = HotkeyBinding.pinDefault,
}) {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
    uiPrefsDirs: dirs,
    primaryChord: primaryChord,
    pinChord: pinChord,
    primaryHotkeys: primary,
    pinHotkey: pin,
  );
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sr-hotkey-rebind-');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('capture unregisters both chords; ending capture re-hangs', () async {
    final primary = RecordingPrimaryHotkeyRegistrar();
    final pin = RecordingPinHotkeyRegistrar();
    final gateway = FakeGateway();
    final controller = makeController(
      gateway: gateway,
      dirs: [tmp.path],
      primary: primary,
      pin: pin,
    );

    await controller.installProductHotkeys();
    expect(primary.calls, ['apply:Ctrl+Alt+V']);
    primary.calls.clear();

    await controller.startSession();
    await Future<void>.delayed(Duration.zero);
    expect(pin.calls, ['register']);
    pin.calls.clear();

    await controller.setHotkeysPaused(true);
    expect(primary.calls, ['unregister']);
    expect(pin.calls, ['unregister']);

    await controller.setHotkeysPaused(false);
    expect(primary.calls, ['unregister', 'apply:Ctrl+Alt+V']);
    expect(pin.calls, ['unregister', 'register']);
    expect(pin.lastChord, HotkeyBinding.pinDefault);

    await controller.cancelSession();
  });

  test('a file change hot-swaps the main-flow chord at once', () async {
    final primary = RecordingPrimaryHotkeyRegistrar();
    final gateway = FakeGateway();
    final controller = makeController(
      gateway: gateway,
      dirs: [tmp.path],
      primary: primary,
    );
    await controller.installProductHotkeys();
    primary.calls.clear();

    saveUiHotkey(
      [tmp.path],
      HotkeySlot.primary,
      HotkeyBinding.tryParse('Alt+Q')!,
    );
    await controller.onHotkeysChanged();

    expect(controller.primaryChord.wire, 'Alt+Q');
    expect(primary.calls, ['apply:Alt+Q']);
  });

  test(
    'an idle pin rebind only swaps the object; next listen arms it',
    () async {
      final pin = RecordingPinHotkeyRegistrar();
      final gateway = FakeGateway();
      final controller = makeController(
        gateway: gateway,
        dirs: [tmp.path],
        pin: pin,
      );
      expect(pin.calls, isEmpty);

      saveUiHotkey(
        [tmp.path],
        HotkeySlot.pin,
        HotkeyBinding.tryParse('Ctrl+P')!,
      );
      await controller.onHotkeysChanged();
      expect(controller.pinChord.wire, 'Ctrl+P');
      expect(pin.calls, isEmpty); // idle: no register yet

      await controller.startSession();
      await Future<void>.delayed(Duration.zero);
      expect(pin.calls, ['register']);
      expect(pin.lastChord!.wire, 'Ctrl+P');
      await controller.cancelSession();
    },
  );

  test(
    'a mid-listen pin rebind hands the old chord back and takes the new',
    () async {
      final pin = RecordingPinHotkeyRegistrar();
      final gateway = FakeGateway();
      final controller = makeController(
        gateway: gateway,
        dirs: [tmp.path],
        pin: pin,
      );
      await controller.startSession();
      await Future<void>.delayed(Duration.zero);
      expect(pin.lastChord, HotkeyBinding.pinDefault);
      pin.calls.clear();

      saveUiHotkey(
        [tmp.path],
        HotkeySlot.pin,
        HotkeyBinding.tryParse('Ctrl+P')!,
      );
      await controller.onHotkeysChanged();
      expect(pin.calls, ['unregister', 'register']);
      expect(pin.lastChord!.wire, 'Ctrl+P');
      await controller.cancelSession();
    },
  );

  test(
    'an empty primary bind unregisters and leaves the orb as the stepper',
    () async {
      final primary = RecordingPrimaryHotkeyRegistrar();
      final gateway = FakeGateway();
      final controller = makeController(
        gateway: gateway,
        dirs: [tmp.path],
        primary: primary,
      );
      await controller.installProductHotkeys();
      primary.calls.clear();

      saveUiHotkey([tmp.path], HotkeySlot.primary, const HotkeyBinding.none());
      await controller.onHotkeysChanged();
      expect(controller.primaryChord.isNone, isTrue);
      expect(primary.calls, ['unregister']);

      await controller.hotkeyToggle();
      expect(gateway.commands, contains('startSession'));
      await controller.cancelSession();
    },
  );

  test('an empty pin bind never registers, even while listening', () async {
    final pin = RecordingPinHotkeyRegistrar();
    final gateway = FakeGateway();
    final controller = makeController(
      gateway: gateway,
      dirs: [tmp.path],
      pin: pin,
      pinChord: const HotkeyBinding.none(),
    );
    await controller.startSession();
    await Future<void>.delayed(Duration.zero);
    expect(pin.calls, isEmpty);
    await controller.cancelSession();
  });

  test('capture in progress swallows a file change until it ends', () async {
    final primary = RecordingPrimaryHotkeyRegistrar();
    final gateway = FakeGateway();
    final controller = makeController(
      gateway: gateway,
      dirs: [tmp.path],
      primary: primary,
    );
    await controller.installProductHotkeys();
    await controller.setHotkeysPaused(true);
    primary.calls.clear();

    saveUiHotkey(
      [tmp.path],
      HotkeySlot.primary,
      HotkeyBinding.tryParse('Alt+Q')!,
    );
    await controller.onHotkeysChanged();
    expect(controller.primaryChord.wire, 'Alt+Q');
    expect(primary.calls, isEmpty); // still capturing

    await controller.setHotkeysPaused(false);
    expect(primary.calls, ['apply:Alt+Q']);
  });
}
