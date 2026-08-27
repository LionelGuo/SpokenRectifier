/// The app-owned UI preferences file, `spokenrectifier-ui.toml` — the
/// theme's persistence home (spec §5). The app owns this file the way
/// it owns the scenario library: it lives in the first writable search
/// directory, not in the user-authored config layers (ADR-0004).
///
/// Ticket 15 reads at startup (missing file = follow the system);
/// ticket 16's quick-panel switcher does the writing. Later tickets add
/// geometry keys (orb position, panel size) to the same file — the
/// writer preserves every line it does not own.

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

/// Persist the theme selection (the quick panel's tri-state). The write
/// goes to the file the reader resolves — never a second copy, which
/// would shadow the first on the next startup read — and only when no
/// file exists anywhere does it land in the first directory that
/// accepts a write. Every other line (comments, the geometry keys later
/// tickets own) survives verbatim; a `theme` key the reader would
/// recognize is replaced in place. Throws when nothing is writable.
void saveUiThemeMode(List<String> dirs, ThemeMode mode) {
  final line = 'theme = "${_themeValue(mode)}"';
  for (final dir in dirs) {
    final file = File('$dir/$uiPrefsFile');
    if (!file.existsSync()) continue;
    // An existing file owns the key wherever it lives: a failed write
    // here is a real failure, not a reason to fork a shadowing copy.
    file.writeAsStringSync(_withThemeLine(file.readAsStringSync(), line));
    return;
  }
  for (final dir in dirs) {
    try {
      File('$dir/$uiPrefsFile').writeAsStringSync('$line\n');
      return;
    } on FileSystemException {
      continue; // not writable: the next directory gets its chance
    }
  }
  throw const FileSystemException(
    'no writable directory for the ui prefs file',
  );
}

String _themeValue(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
  ThemeMode.system => 'system',
};

/// Swap the `theme` key into `text`, preserving every other line. The
/// key is located by the reader's own rule (first `theme`-prefixed,
/// comment-stripped line); appending repairs a missing trailing newline
/// so the key never glues onto the current last line, and a replaced
/// file always ends with exactly one (later keys append cleanly).
String _withThemeLine(String text, String line) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var probe = lines[i];
    final comment = probe.indexOf('#');
    if (comment >= 0) probe = probe.substring(0, comment);
    if (probe.trim().startsWith('theme')) {
      lines[i] = line;
      return _withTrailingNewline(lines.join('\n'));
    }
  }
  final prefix = text.isEmpty || text.endsWith('\n') ? '' : '\n';
  return '$text$prefix$line\n';
}

String _withTrailingNewline(String text) =>
    text.isEmpty || text.endsWith('\n') ? text : '$text\n';
