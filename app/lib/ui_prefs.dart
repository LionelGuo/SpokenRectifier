/// The app-owned UI preferences file, `spokenrectifier-ui.toml` — the
/// theme's persistence home (spec §5). The app owns this file the way
/// it owns the scenario library: it lives in the first writable search
/// directory, not in the user-authored config layers (ADR-0004).
///
/// Ticket 15 reads at startup (missing file = follow the system);
/// ticket 16's quick-panel switcher does the writing.

library;

import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;

/// The file's name, looked up in every search directory.
const uiPrefsFile = 'spokenrectifier-ui.toml';

/// The directories the file is searched in, first hit wins — the same
/// order the engine's config loader uses (working directory first for
/// dev runs, then the executable's directory for a double-clicked
/// portable exe).
List<String> uiPrefsSearchDirs() {
  final dirs = <String>[Directory.current.path];
  final exe = File(Platform.resolvedExecutable).parent.path;
  if (!dirs.contains(exe)) dirs.add(exe);
  return dirs;
}

/// Read the theme mode from the first `spokenrectifier-ui.toml` among
/// `dirs`. Tolerance rules: a missing or unreadable file, or content
/// without a legal `theme` value, reads as [ThemeMode.system] — a
/// broken prefs file never blocks startup.
ThemeMode loadUiThemeMode(List<String> dirs) {
  for (final dir in dirs) {
    final file = File('$dir/$uiPrefsFile');
    String text;
    try {
      if (!file.existsSync()) continue;
      text = file.readAsStringSync();
    } catch (_) {
      continue; // unreadable: as good as absent
    }
    return _parseTheme(text) ?? ThemeMode.system;
  }
  return ThemeMode.system;
}

/// Extract `theme = "light|dark|system"`, tolerating comments and
/// spacing. Only the app's own writer and a human hand edit this file,
/// so a one-key line parser is the whole grammar. The value must be a
/// quoted string — this is TOML, and an unquoted or otherwise malformed
/// line is a syntax error that reads as "no preference" (null; the
/// caller defaults to system), like the engine's own tolerant loaders.
ThemeMode? _parseTheme(String text) {
  for (var line in text.split('\n')) {
    final comment = line.indexOf('#');
    if (comment >= 0) line = line.substring(0, comment);
    line = line.trim();
    if (!line.startsWith('theme')) continue;
    final match = RegExp('^theme\\s*=\\s*"(.*)"\\s*\$').firstMatch(line);
    if (match == null) return null; // theme key, broken syntax
    switch (match.group(1)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
    }
    return null; // a theme key with an unknown value: fall back
  }
  return null;
}
