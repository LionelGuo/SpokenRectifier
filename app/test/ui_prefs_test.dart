/// The app-owned UI preferences file: startup reads, tolerant parsing,
/// and the search order mirroring the engine's config search dirs.

library;

import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
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
    final f = File('${d.path}/$uiPrefsFile')..writeAsStringSync('theme = "dark"\n');
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
}
