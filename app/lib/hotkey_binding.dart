/// The two product hotkey chords: the main-flow step and the pin, as
/// persisted in `spokenrectifier-ui.toml` (ticket 16 / map 06).
///
/// Wire form is a quoted TOML string: `"Ctrl+Alt+V"`, `"Alt+B"`, or
/// `"none"` for an empty bind. Missing, broken, or unknown values fall
/// back to today's defaults — never to empty. The canonical modifier
/// order is Ctrl+Alt+Shift+key; legality is the product whitelist
/// (at least one of Ctrl/Alt/Shift; A–Z / 0–9 / F1–F11; no Meta/Win,
/// no Fn, no CapsLock, no F12, no bare key).
library;

import 'package:flutter/services.dart' show PhysicalKeyboardKey;

/// Which of the two product chords a row / write is about.
enum HotkeySlot { primary, pin }

/// One product binding: either [HotkeyBinding.none] or a legal chord.
class HotkeyBinding {
  const HotkeyBinding._({
    required this.ctrl,
    required this.alt,
    required this.shift,
    required this.key,
  });

  /// Empty bind: the chord is not registered (`"none"` on disk).
  const HotkeyBinding.none()
    : ctrl = false,
      alt = false,
      shift = false,
      key = '';

  /// A chord the whitelist accepts. [key] is the canonical token
  /// (`V`, `B`, `F11`, `0`).
  const HotkeyBinding.chord({
    required this.ctrl,
    required this.alt,
    required this.shift,
    required this.key,
  });

  final bool ctrl;
  final bool alt;
  final bool shift;

  /// Canonical primary-key token; empty iff this is [HotkeyBinding.none].
  final String key;

  bool get isNone => key.isEmpty;

  /// Today's main-flow chord (`Ctrl+Alt+V`).
  static const primaryDefault = HotkeyBinding._(
    ctrl: true,
    alt: true,
    shift: false,
    key: 'V',
  );

  /// Today's pin chord (`Alt+B`).
  static const pinDefault = HotkeyBinding._(
    ctrl: false,
    alt: true,
    shift: false,
    key: 'B',
  );

  static HotkeyBinding defaultFor(HotkeySlot slot) => switch (slot) {
    HotkeySlot.primary => primaryDefault,
    HotkeySlot.pin => pinDefault,
  };

  /// Parse a wire / hand-edit string. `"none"` (any case) is empty;
  /// anything else illegal returns null so the caller can fall back to
  /// the slot's default (not to empty).
  static HotkeyBinding? tryParse(String raw) {
    final text = raw.trim();
    if (text.toLowerCase() == 'none') return const HotkeyBinding.none();
    final parts = [
      for (final part in text.split('+'))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (parts.length < 2) return null;
    final keyTok = parts.last.toUpperCase();
    if (!_legalKeys.containsKey(keyTok)) return null;
    var ctrl = false, alt = false, shift = false;
    for (final mod in parts.take(parts.length - 1)) {
      switch (mod.toLowerCase()) {
        case 'ctrl':
        case 'control':
          ctrl = true;
        case 'alt':
          alt = true;
        case 'shift':
          shift = true;
        default:
          return null; // Meta/Win, Fn, CapsLock, unknown
      }
    }
    if (!ctrl && !alt && !shift) return null;
    return HotkeyBinding._(ctrl: ctrl, alt: alt, shift: shift, key: keyTok);
  }

  /// Build a legal chord from a physical key-down plus the currently
  /// pressed set. Null = not a completing press (a modifier by itself,
  /// a banned key, a bare key, Meta/Fn/CapsLock held) — the recorder
  /// keeps waiting.
  static HotkeyBinding? fromPress({
    required PhysicalKeyboardKey key,
    required Set<PhysicalKeyboardKey> pressed,
  }) {
    if (_modifierKeys.contains(key)) return null;
    if (pressed.contains(PhysicalKeyboardKey.metaLeft) ||
        pressed.contains(PhysicalKeyboardKey.metaRight) ||
        pressed.contains(PhysicalKeyboardKey.fn) ||
        pressed.contains(PhysicalKeyboardKey.capsLock)) {
      return null;
    }
    final keyTok = _tokenFor(key);
    if (keyTok == null) return null;
    final ctrl =
        pressed.contains(PhysicalKeyboardKey.controlLeft) ||
        pressed.contains(PhysicalKeyboardKey.controlRight);
    final alt =
        pressed.contains(PhysicalKeyboardKey.altLeft) ||
        pressed.contains(PhysicalKeyboardKey.altRight);
    final shift =
        pressed.contains(PhysicalKeyboardKey.shiftLeft) ||
        pressed.contains(PhysicalKeyboardKey.shiftRight);
    if (!ctrl && !alt && !shift) return null;
    return HotkeyBinding._(ctrl: ctrl, alt: alt, shift: shift, key: keyTok);
  }

  /// Disk / channel form: `"none"` or `Ctrl+Alt+Shift+V` (omitting
  /// missing modifiers, that fixed order).
  String get wire {
    if (isNone) return 'none';
    final mods = <String>[if (ctrl) 'Ctrl', if (alt) 'Alt', if (shift) 'Shift'];
    return '${mods.join('+')}+$key';
  }

  /// Row label: `未绑定` or the wire form.
  String get label => isNone ? '未绑定' : wire;

  PhysicalKeyboardKey? get physicalKey => isNone ? null : _legalKeys[key];

  /// Two empty binds do not collide; only two equal non-empty chords do.
  bool conflictsWith(HotkeyBinding other) =>
      !isNone && !other.isNone && this == other;

  @override
  bool operator ==(Object other) =>
      other is HotkeyBinding &&
      ctrl == other.ctrl &&
      alt == other.alt &&
      shift == other.shift &&
      key == other.key;

  @override
  int get hashCode => Object.hash(ctrl, alt, shift, key);

  @override
  String toString() => 'HotkeyBinding($wire)';
}

/// Canonical token → physical key. Only the whitelist lives here.
const _legalKeys = <String, PhysicalKeyboardKey>{
  'A': PhysicalKeyboardKey.keyA,
  'B': PhysicalKeyboardKey.keyB,
  'C': PhysicalKeyboardKey.keyC,
  'D': PhysicalKeyboardKey.keyD,
  'E': PhysicalKeyboardKey.keyE,
  'F': PhysicalKeyboardKey.keyF,
  'G': PhysicalKeyboardKey.keyG,
  'H': PhysicalKeyboardKey.keyH,
  'I': PhysicalKeyboardKey.keyI,
  'J': PhysicalKeyboardKey.keyJ,
  'K': PhysicalKeyboardKey.keyK,
  'L': PhysicalKeyboardKey.keyL,
  'M': PhysicalKeyboardKey.keyM,
  'N': PhysicalKeyboardKey.keyN,
  'O': PhysicalKeyboardKey.keyO,
  'P': PhysicalKeyboardKey.keyP,
  'Q': PhysicalKeyboardKey.keyQ,
  'R': PhysicalKeyboardKey.keyR,
  'S': PhysicalKeyboardKey.keyS,
  'T': PhysicalKeyboardKey.keyT,
  'U': PhysicalKeyboardKey.keyU,
  'V': PhysicalKeyboardKey.keyV,
  'W': PhysicalKeyboardKey.keyW,
  'X': PhysicalKeyboardKey.keyX,
  'Y': PhysicalKeyboardKey.keyY,
  'Z': PhysicalKeyboardKey.keyZ,
  '0': PhysicalKeyboardKey.digit0,
  '1': PhysicalKeyboardKey.digit1,
  '2': PhysicalKeyboardKey.digit2,
  '3': PhysicalKeyboardKey.digit3,
  '4': PhysicalKeyboardKey.digit4,
  '5': PhysicalKeyboardKey.digit5,
  '6': PhysicalKeyboardKey.digit6,
  '7': PhysicalKeyboardKey.digit7,
  '8': PhysicalKeyboardKey.digit8,
  '9': PhysicalKeyboardKey.digit9,
  'F1': PhysicalKeyboardKey.f1,
  'F2': PhysicalKeyboardKey.f2,
  'F3': PhysicalKeyboardKey.f3,
  'F4': PhysicalKeyboardKey.f4,
  'F5': PhysicalKeyboardKey.f5,
  'F6': PhysicalKeyboardKey.f6,
  'F7': PhysicalKeyboardKey.f7,
  'F8': PhysicalKeyboardKey.f8,
  'F9': PhysicalKeyboardKey.f9,
  'F10': PhysicalKeyboardKey.f10,
  'F11': PhysicalKeyboardKey.f11,
};

final _modifierKeys = {
  PhysicalKeyboardKey.controlLeft,
  PhysicalKeyboardKey.controlRight,
  PhysicalKeyboardKey.altLeft,
  PhysicalKeyboardKey.altRight,
  PhysicalKeyboardKey.shiftLeft,
  PhysicalKeyboardKey.shiftRight,
  PhysicalKeyboardKey.metaLeft,
  PhysicalKeyboardKey.metaRight,
  PhysicalKeyboardKey.fn,
  PhysicalKeyboardKey.capsLock,
};

String? _tokenFor(PhysicalKeyboardKey key) {
  for (final entry in _legalKeys.entries) {
    if (entry.value == key) return entry.key;
  }
  return null;
}
