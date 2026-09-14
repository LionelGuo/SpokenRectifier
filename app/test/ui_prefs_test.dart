/// The app-owned UI preferences file: startup reads, tolerant parsing,
/// the search order mirroring the engine's config search dirs — and the
/// write half (ticket 16): placement, in-place key replacement,
/// preservation of lines the theme does not own, and the read/write
/// round trip every mode has to survive. The geometry pair (ticket 20)
/// and the orb's visibility ride the same rules, each with its own
/// tolerance family.

library;

import 'dart:io';
import 'dart:ui' show Offset, Size;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/hotkey_binding.dart';
import 'package:spokenrectifier_app/ui_prefs.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sr-ui-prefs');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Directory dir(String name) {
    final d = Directory('${tmp.path}/$name')..createSync();
    return d;
  }

  test('a missing file reads as follow-the-system', () {
    expect(loadUiThemeMode([dir('empty').path]), ThemeMode.system);
  });

  test('each legal value round-trips', () {
    for (final (text, mode) in [
      ('theme = "light"\n', ThemeMode.light),
      ('theme = "dark"\n', ThemeMode.dark),
      ('theme = "system"\n', ThemeMode.system),
    ]) {
      final d = dir('legal');
      File('${d.path}/$uiPrefsFile').writeAsStringSync(text);
      expect(loadUiThemeMode([d.path]), mode, reason: text);
    }
  });

  test('comments, blank lines and spacing are tolerated', () {
    final d = dir('noise');
    File('${d.path}/$uiPrefsFile').writeAsStringSync(
      '# SpokenRectifier UI preferences (written by the app)\n\n'
      'theme = "dark"  # trailing note\n',
    );
    expect(loadUiThemeMode([d.path]), ThemeMode.dark);
  });

  test('unknown or malformed content degrades to system, never throws', () {
    for (final text in ['theme = "sepia"\n', 'theme = dark\n', '[broken\n']) {
      final d = dir('broken');
      File('${d.path}/$uiPrefsFile').writeAsStringSync(text);
      expect(loadUiThemeMode([d.path]), ThemeMode.system, reason: text);
    }
  });

  test('the first directory holding the file wins', () {
    final one = dir('one');
    final two = dir('two');
    File('${one.path}/$uiPrefsFile').writeAsStringSync('theme = "light"\n');
    File('${two.path}/$uiPrefsFile').writeAsStringSync('theme = "dark"\n');
    expect(loadUiThemeMode([one.path, two.path]), ThemeMode.light);
    expect(loadUiThemeMode([two.path, one.path]), ThemeMode.dark);
  });

  test('an unreadable file is as good as absent', () {
    final d = dir('locked');
    final f = File('${d.path}/$uiPrefsFile')
      ..writeAsStringSync('theme = "dark"\n');
    // No portable "chmod 000" on Windows; delete instead and keep the
    // read guarded by the same catch.
    f.deleteSync();
    expect(loadUiThemeMode([d.path]), ThemeMode.system);
  });

  test('a file with no theme key leaves the default untouched', () {
    final d = dir('other-keys');
    File('${d.path}/$uiPrefsFile').writeAsStringSync('future_key = 1\n');
    expect(loadUiThemeMode([d.path]), ThemeMode.system);
  });

  // -- the write half (ticket 16) -------------------------------------------

  test('a fresh write creates the file in the first directory', () {
    final one = dir('fresh-one');
    final two = dir('fresh-two');

    saveUiThemeMode([one.path, two.path], ThemeMode.dark);

    expect(
      File('${one.path}/$uiPrefsFile').readAsStringSync(),
      'theme = "dark"\n',
    );
    expect(File('${two.path}/$uiPrefsFile').existsSync(), isFalse);
  });

  test('an existing file keeps ownership — never a shadowing copy', () {
    final one = dir('shadow-one');
    final two = dir('shadow-two');
    final existing = File('${two.path}/$uiPrefsFile')
      ..writeAsStringSync('theme = "light"\n');

    saveUiThemeMode([one.path, two.path], ThemeMode.dark);

    // Written into the resolved file, nothing forked into the earlier
    // directory: a second copy would win the next startup read.
    expect(existing.readAsStringSync(), 'theme = "dark"\n');
    expect(File('${one.path}/$uiPrefsFile').existsSync(), isFalse);
    expect(loadUiThemeMode([one.path, two.path]), ThemeMode.dark);
  });

  test('the write replaces the theme key in place and preserves the rest', () {
    final d = dir('preserve');
    final file = File('${d.path}/$uiPrefsFile');
    // Later tickets own geometry keys here (orb position, panel size);
    // a human hand may comment, and key names may share the theme
    // prefix. All of it survives a theme flip untouched.
    file.writeAsStringSync(
      '# app-owned\ntheme = "dark"\npanel_size = [420, 560]\n'
      'theme_extra = "kept"\n',
    );

    saveUiThemeMode([d.path], ThemeMode.system);
    expect(
      file.readAsStringSync(),
      '# app-owned\ntheme = "system"\npanel_size = [420, 560]\n'
      'theme_extra = "kept"\n',
    );

    // A commented-out theme line is not the key: the real one appends.
    file.writeAsStringSync('# theme = "dark"\n');
    saveUiThemeMode([d.path], ThemeMode.light);
    expect(file.readAsStringSync(), '# theme = "dark"\ntheme = "light"\n');

    // A missing trailing newline is repaired, not glued onto.
    file.writeAsStringSync('theme = "dark"');
    saveUiThemeMode([d.path], ThemeMode.light);
    expect(file.readAsStringSync(), 'theme = "light"\n');
  });

  test('every mode round trips through the reader', () {
    final d = dir('round-trip');
    for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
      saveUiThemeMode([d.path], mode);
      expect(loadUiThemeMode([d.path]), mode, reason: '$mode survived');
    }
  });

  test('nowhere writable fails loudly instead of silently', () {
    // A directory squatting on the file's path makes the existing-file
    // read itself blow up: the write must throw, never pass quietly.
    final d = dir('locked-write');
    Directory('${d.path}/$uiPrefsFile').createSync();

    expect(
      () => saveUiThemeMode([d.path], ThemeMode.light),
      throwsA(isA<FileSystemException>()),
    );
  });

  // -- the geometry keys (ticket 20) ----------------------------------------

  test('a missing file reads as no geometry', () {
    final geo = loadUiGeometry([dir('geo-empty').path]);
    expect(geo.orbPosition, isNull);
    expect(geo.panelSize, isNull);
  });

  test('hand-written geometry parses: ints, decimals, spaces, negatives', () {
    final d = dir('geo-hand');
    File('${d.path}/$uiPrefsFile').writeAsStringSync(
      'theme = "dark"\n'
      'orb_position = [ -1920 , 48 ]\n'
      'panel_size = [420, 560.5]\n',
    );
    final geo = loadUiGeometry([d.path]);
    expect(geo.orbPosition, const Offset(-1920, 48));
    expect(geo.panelSize, const Size(420, 560.5));
  });

  test('broken values degrade to null, per key', () {
    for (final text in [
      'orb_position = [x, y]\n', // not numbers
      'orb_position = (100, 200)\n', // not an array
      'panel_size = [420]\n', // not a pair
      'panel_size = [0, 560]\n', // a size must be positive
      'panel_size = [-420, 560]\n',
    ]) {
      final d = dir('geo-broken');
      File('${d.path}/$uiPrefsFile').writeAsStringSync(text);
      final geo = loadUiGeometry([d.path]);
      expect(geo.orbPosition, isNull, reason: text);
      expect(geo.panelSize, isNull, reason: text);
    }
  });

  test('a broken orb_position does not take panel_size down with it', () {
    final d = dir('geo-half');
    File('${d.path}/$uiPrefsFile')
        .writeAsStringSync('orb_position = nowhere\npanel_size = [500, 600]\n');
    final geo = loadUiGeometry([d.path]);
    expect(geo.orbPosition, isNull);
    expect(geo.panelSize, const Size(500, 600));
  });

  test('both keys round-trip through the writer', () {
    final d = dir('geo-round-trip');
    saveUiGeometry(
      [d.path],
      orbPosition: const Offset(1872.5, 984.25),
      panelSize: const Size(420, 560),
    );
    // Integral doubles write as ints; the fraction keeps its exact form.
    expect(
      File('${d.path}/$uiPrefsFile').readAsStringSync(),
      'orb_position = [1872.5, 984.25]\npanel_size = [420, 560]\n',
    );
    final geo = loadUiGeometry([d.path]);
    expect(geo.orbPosition, const Offset(1872.5, 984.25));
    expect(geo.panelSize, const Size(420, 560));
  });

  test('the geometry write preserves every line it does not own', () {
    final d = dir('geo-preserve');
    final file = File('${d.path}/$uiPrefsFile');
    file.writeAsStringSync(
      '# app-owned\n'
      'theme = "dark"\n'
      'orb_position = [10, 20]\n'
      'future_key = 1\n',
    );

    saveUiGeometry(
      [d.path],
      orbPosition: const Offset(100, 200),
      panelSize: const Size(500, 640),
    );
    expect(
      file.readAsStringSync(),
      '# app-owned\n'
      'theme = "dark"\n'
      'orb_position = [100, 200]\n'
      'future_key = 1\n'
      'panel_size = [500, 640]\n', // absent key appends, in place for the rest
    );

    // A null parameter leaves its key untouched.
    saveUiGeometry([d.path], orbPosition: const Offset(1, 2));
    final text = file.readAsStringSync();
    expect(text, contains('orb_position = [1, 2]'));
    expect(text, contains('panel_size = [500, 640]'));
    expect(text, contains('theme = "dark"'));
  });

  test('geometry writes land in the resolved file, never a copy', () {
    final one = dir('geo-shadow-one');
    final two = dir('geo-shadow-two');
    final existing = File('${two.path}/$uiPrefsFile')
      ..writeAsStringSync('theme = "light"\n');

    saveUiGeometry([one.path, two.path], orbPosition: const Offset(3, 4));

    expect(
      existing.readAsStringSync(),
      'theme = "light"\norb_position = [3, 4]\n',
    );
    expect(File('${one.path}/$uiPrefsFile').existsSync(), isFalse);
  });

  // -- the orb visibility ----------------------------------------------------

  test('a missing file reads as visible', () {
    expect(loadUiOrbVisible([dir('orb-empty').path]), isTrue);
  });

  test('both values round-trip through the writer', () {
    final d = dir('orb-round-trip');
    saveUiOrbVisible([d.path], false);
    expect(
      File('${d.path}/$uiPrefsFile').readAsStringSync(),
      'orb_visible = false\n',
    );
    expect(loadUiOrbVisible([d.path]), isFalse);
    saveUiOrbVisible([d.path], true);
    expect(loadUiOrbVisible([d.path]), isTrue);
  });

  test('broken values degrade to visible, never to hidden', () {
    for (final text in [
      'orb_visible = "false"\n', // a quoted string is not a TOML boolean
      'orb_visible = nope\n',
      'orb_visible =\n',
      'orb_visible_note = false\n', // prefix-sharing key, not ours
      'orb_visible_false = false\n',
      '[broken\n',
    ]) {
      final d = dir('orb-broken');
      File('${d.path}/$uiPrefsFile').writeAsStringSync(text);
      expect(loadUiOrbVisible([d.path]), isTrue, reason: text);
    }
  });

  test('the orb write replaces its key in place and preserves the rest', () {
    final d = dir('orb-preserve');
    final file = File('${d.path}/$uiPrefsFile');
    file.writeAsStringSync(
      '# app-owned\ntheme = "dark"\norb_position = [10, 20]\norb_visible = true\n',
    );

    saveUiOrbVisible([d.path], false);
    expect(
      file.readAsStringSync(),
      '# app-owned\ntheme = "dark"\norb_position = [10, 20]\norb_visible = false\n',
    );
  });

  test('comments and spacing are tolerated on the orb key', () {
    final d = dir('orb-noise');
    File('${d.path}/$uiPrefsFile').writeAsStringSync(
      '# app-owned\n\n  orb_visible =   false  # hidden while recording\n',
    );
    expect(loadUiOrbVisible([d.path]), isFalse);
  });

  // -- the product hotkeys (ticket 16) --------------------------------------

  test('a missing file reads as today\'s two defaults, never as empty', () {
    final loaded = loadUiHotkeys([dir('hotkey-empty').path]);
    expect(loaded.primary, HotkeyBinding.primaryDefault);
    expect(loaded.pin, HotkeyBinding.pinDefault);
  });

  test('both chords round-trip through the writer, including none', () {
    final d = dir('hotkey-round-trip');
    saveUiHotkey(
      [d.path],
      HotkeySlot.primary,
      HotkeyBinding.tryParse('Alt+Q')!,
    );
    saveUiHotkey([d.path], HotkeySlot.pin, const HotkeyBinding.none());
    expect(
      File('${d.path}/$uiPrefsFile').readAsStringSync(),
      'primary_hotkey = "Alt+Q"\npin_hotkey = "none"\n',
    );
    final loaded = loadUiHotkeys([d.path]);
    expect(loaded.primary.wire, 'Alt+Q');
    expect(loaded.pin.isNone, isTrue);
  });

  test(
    'missing, broken or unknown values fall back per-slot to the default',
    () {
      for (final (text, wantPrimary, wantPin) in [
        (
          'theme = "dark"\n',
          HotkeyBinding.primaryDefault,
          HotkeyBinding.pinDefault,
        ),
        (
          'primary_hotkey = Ctrl+Alt+V\n', // unquoted: broken, not a chord
          HotkeyBinding.primaryDefault,
          HotkeyBinding.pinDefault,
        ),
        (
          'primary_hotkey = "nope"\npin_hotkey = "Alt+B"\n',
          HotkeyBinding.primaryDefault,
          HotkeyBinding.pinDefault,
        ),
        (
          'primary_hotkey = "none"\n',
          const HotkeyBinding.none(),
          HotkeyBinding.pinDefault,
        ),
        (
          'pin_hotkey = "Win+B"\n',
          HotkeyBinding.primaryDefault,
          HotkeyBinding.pinDefault,
        ),
      ]) {
        final d = dir('hotkey-broken');
        File('${d.path}/$uiPrefsFile').writeAsStringSync(text);
        final loaded = loadUiHotkeys([d.path]);
        expect(loaded.primary, wantPrimary, reason: 'primary of $text');
        expect(loaded.pin, wantPin, reason: 'pin of $text');
      }
    },
  );

  test('the loader does not cross-check a colliding pair', () {
    // A hand-edit that writes the same chord twice is occupancy at
    // runtime, not a load error — each key is read on its own.
    final d = dir('hotkey-collide');
    File('${d.path}/$uiPrefsFile')
        .writeAsStringSync('primary_hotkey = "Alt+B"\npin_hotkey = "Alt+B"\n');
    final loaded = loadUiHotkeys([d.path]);
    expect(loaded.primary.wire, 'Alt+B');
    expect(loaded.pin.wire, 'Alt+B');
  });

  test('a hotkey write replaces its key in place and preserves the rest', () {
    final d = dir('hotkey-preserve');
    final file = File('${d.path}/$uiPrefsFile');
    file.writeAsStringSync(
      '# app-owned\ntheme = "dark"\norb_visible = true\nprimary_hotkey = "Ctrl+Alt+V"\n',
    );

    saveUiHotkey(
      [d.path],
      HotkeySlot.primary,
      HotkeyBinding.tryParse('Ctrl+Q')!,
    );
    expect(
      file.readAsStringSync(),
      '# app-owned\ntheme = "dark"\norb_visible = true\nprimary_hotkey = "Ctrl+Q"\n',
    );
    saveUiHotkey([d.path], HotkeySlot.pin, HotkeyBinding.pinDefault);
    expect(file.readAsStringSync(), contains('pin_hotkey = "Alt+B"'));
    expect(file.readAsStringSync(), contains('theme = "dark"'));
  });
}
