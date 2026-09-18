/// The product hotkey chord: wire form, whitelist, capture completion,
/// and the two-slot collision rule (ticket 16 / map 06).
library;

import 'package:flutter/services.dart' show PhysicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/hotkey_binding.dart';

void main() {
  group('tryParse', () {
    test('the two today-defaults round-trip', () {
      expect(
        HotkeyBinding.tryParse('Ctrl+Alt+V'),
        HotkeyBinding.primaryDefault,
      );
      expect(HotkeyBinding.tryParse('Alt+B'), HotkeyBinding.pinDefault);
      expect(HotkeyBinding.primaryDefault.wire, 'Ctrl+Alt+V');
      expect(HotkeyBinding.pinDefault.wire, 'Alt+B');
    });

    test('"none" (any case) is the empty bind, not a fallback', () {
      expect(HotkeyBinding.tryParse('none'), const HotkeyBinding.none());
      expect(HotkeyBinding.tryParse('NONE'), const HotkeyBinding.none());
      expect(HotkeyBinding.tryParse(' None '), const HotkeyBinding.none());
      expect(const HotkeyBinding.none().wire, 'none');
      expect(const HotkeyBinding.none().label, '未绑定');
      expect(const HotkeyBinding.none().isNone, isTrue);
    });

    test('modifier order canonicalizes to Ctrl+Alt+Shift+key', () {
      expect(
        HotkeyBinding.tryParse('Shift+Alt+Ctrl+V')!.wire,
        'Ctrl+Alt+Shift+V',
      );
      expect(HotkeyBinding.tryParse('alt+ctrl+b')!.wire, 'Ctrl+Alt+B');
      expect(HotkeyBinding.tryParse('control+shift+1')!.wire, 'Ctrl+Shift+1');
    });

    test('F1–F11 and digits are legal; F12 is not', () {
      expect(HotkeyBinding.tryParse('Ctrl+F11')!.wire, 'Ctrl+F11');
      expect(HotkeyBinding.tryParse('Alt+0')!.wire, 'Alt+0');
      expect(HotkeyBinding.tryParse('Ctrl+F12'), isNull);
    });

    test(
      'illegal forms return null (caller falls back to the slot default)',
      () {
        for (final raw in [
          '',
          'V', // bare key
          'Ctrl', // modifier as key
          'Ctrl+',
          'Win+V',
          'Meta+V',
          'Ctrl+Alt+Win+V',
          'Fn+B',
          'CapsLock+A',
          'Ctrl+Space',
          'Ctrl+Enter',
          'Ctrl+Esc',
          'Ctrl+F12',
          'not a chord',
        ]) {
          expect(HotkeyBinding.tryParse(raw), isNull, reason: raw);
        }
      },
    );
  });

  group('fromPress', () {
    test('a legal chord completes on the key-down', () {
      expect(
        HotkeyBinding.fromPress(
          key: PhysicalKeyboardKey.keyV,
          pressed: {
            PhysicalKeyboardKey.controlLeft,
            PhysicalKeyboardKey.altLeft,
            PhysicalKeyboardKey.keyV,
          },
        ),
        HotkeyBinding.primaryDefault,
      );
    });

    test('a modifier by itself does not complete', () {
      expect(
        HotkeyBinding.fromPress(
          key: PhysicalKeyboardKey.altLeft,
          pressed: {PhysicalKeyboardKey.altLeft},
        ),
        isNull,
      );
    });

    test('a bare key does not complete', () {
      expect(
        HotkeyBinding.fromPress(
          key: PhysicalKeyboardKey.keyV,
          pressed: {PhysicalKeyboardKey.keyV},
        ),
        isNull,
      );
    });

    test('Meta / Fn / CapsLock / F12 / unknown keys do not complete', () {
      expect(
        HotkeyBinding.fromPress(
          key: PhysicalKeyboardKey.keyV,
          pressed: {PhysicalKeyboardKey.metaLeft, PhysicalKeyboardKey.keyV},
        ),
        isNull,
      );
      expect(
        HotkeyBinding.fromPress(
          key: PhysicalKeyboardKey.f12,
          pressed: {PhysicalKeyboardKey.controlLeft, PhysicalKeyboardKey.f12},
        ),
        isNull,
      );
      expect(
        HotkeyBinding.fromPress(
          key: PhysicalKeyboardKey.space,
          pressed: {PhysicalKeyboardKey.altLeft, PhysicalKeyboardKey.space},
        ),
        isNull,
      );
    });
  });

  group('conflictsWith', () {
    test('two equal non-empty chords collide; empties never do', () {
      expect(
        HotkeyBinding.primaryDefault.conflictsWith(
          HotkeyBinding.tryParse('Alt+Ctrl+V')!,
        ),
        isTrue,
      );
      expect(
        HotkeyBinding.primaryDefault.conflictsWith(HotkeyBinding.pinDefault),
        isFalse,
      );
      expect(
        const HotkeyBinding.none().conflictsWith(const HotkeyBinding.none()),
        isFalse,
      );
      expect(
        const HotkeyBinding.none().conflictsWith(HotkeyBinding.pinDefault),
        isFalse,
      );
    });
  });

  test('each slot has today\'s default', () {
    expect(HotkeyBinding.defaultFor(HotkeySlot.primary).wire, 'Ctrl+Alt+V');
    expect(HotkeyBinding.defaultFor(HotkeySlot.pin).wire, 'Alt+B');
  });

  group('win32Vks', () {
    test('the default primary chord is Ctrl+Alt+V', () {
      expect(HotkeyBinding.primaryDefault.win32Vks, [0x11, 0x12, 0x56]);
    });

    test('the default pin chord is Alt+B', () {
      expect(HotkeyBinding.pinDefault.win32Vks, [0x12, 0x42]);
    });

    test('an empty bind has no keys to watch', () {
      expect(const HotkeyBinding.none().win32Vks, isEmpty);
    });

    test('Shift+F11 is the function-key vk, not a letter', () {
      expect(HotkeyBinding.tryParse('Shift+F11')!.win32Vks, [0x10, 0x7A]);
    });
  });
}
