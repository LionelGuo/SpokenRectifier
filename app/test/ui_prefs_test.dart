/// The ui prefs file's write half (ticket 16): placement, in-place key
/// replacement, preservation of lines the theme does not own, and the
/// read/write round trip every mode has to survive.

library;

import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/ui_prefs.dart';

Future<Directory> scratch(String name) async {
  final dir = await Directory.systemTemp.createTemp(name);
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

Future<String> saved(Directory dir, ThemeMode mode) async {
  saveUiThemeMode([dir.path], mode);
  return File('${dir.path}/$uiPrefsFile').readAsString();
}

void main() {
  test('a fresh write creates the file in the first directory', () async {
    final one = await scratch('sr-ui-prefs-one-');
    final two = await scratch('sr-ui-prefs-two-');

    expect(await saved(one, ThemeMode.dark), 'theme = "dark"\n');
    expect(await File('${two.path}/$uiPrefsFile').exists(), isFalse);
  });

  test('an existing file keeps ownership — never a shadowing copy', () async {
    final one = await scratch('sr-ui-prefs-shadow-one-');
    final two = await scratch('sr-ui-prefs-shadow-two-');
    final existing = File('${two.path}/$uiPrefsFile');
    await existing.writeAsString('theme = "light"\n');

    saveUiThemeMode([one.path, two.path], ThemeMode.dark);

    // Written into the resolved file, nothing forked into the earlier
    // directory: a second copy would win the next startup read.
    expect(await existing.readAsString(), 'theme = "dark"\n');
    expect(await File('${one.path}/$uiPrefsFile').exists(), isFalse);
    expect(loadUiThemeMode([one.path, two.path]), ThemeMode.dark);
  });

  test('the write replaces the theme key in place and preserves the rest', () async {
    final dir = await scratch('sr-ui-prefs-preserve-');
    final file = File('${dir.path}/$uiPrefsFile');
    // Later tickets own geometry keys here (orb position, panel size);
    // a human hand may comment. All of it survives a theme flip.
    await file.writeAsString(
      '# app-owned\ntheme = "dark"\npanel_size = [420, 560]\n',
    );

    expect(await saved(dir, ThemeMode.system),
        '# app-owned\ntheme = "system"\npanel_size = [420, 560]\n');

    // A commented-out theme line is not the key: the real one appends.
    await file.writeAsString('# theme = "dark"\n');
    expect(await saved(dir, ThemeMode.light), '# theme = "dark"\ntheme = "light"\n');

    // A missing trailing newline is repaired, not glued onto.
    await file.writeAsString('theme = "dark"');
    expect(await saved(dir, ThemeMode.light), 'theme = "light"\n');
  });

  test('every mode round trips through the reader', () async {
    final dir = await scratch('sr-ui-prefs-round-trip-');
    for (final mode in [
      ThemeMode.light,
      ThemeMode.dark,
      ThemeMode.system,
    ]) {
      await saved(dir, mode);
      expect(loadUiThemeMode([dir.path]), mode, reason: '$mode survived');
    }
  });

  test('nowhere writable fails loudly instead of silently', () async {
    // A directory squatting on the file's path makes the existing-file
    // read itself blow up: the write must throw, never pass quietly.
    final one = await scratch('sr-ui-prefs-locked-');
    await Directory('${one.path}/$uiPrefsFile').create();

    expect(
      () => saveUiThemeMode([one.path], ThemeMode.light),
      throwsA(isA<FileSystemException>()),
    );
  });
}
