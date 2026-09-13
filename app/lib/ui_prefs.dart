/// The app-owned UI preferences file, `spokenrectifier-ui.toml` — the
/// theme's persistence home (spec §5). The app owns this file the way
/// it owns the scenario library: it lives in the first writable search
/// directory, not in the user-authored config layers (ADR-0004).
///
/// Ticket 15 reads at startup (missing file = follow the system);
/// ticket 16's quick-panel switcher does the writing. Ticket 20 adds the
/// geometry keys — `orb_position = [x, y]` (the anchor, logical
/// coordinates) and `panel_size = [w, h]` — same file, same rules; the
/// writer preserves every line it does not own. The orb-visibility key
/// (`orb_visible = true/false`, a TOML boolean) rides the same family.

library;

import 'dart:io';
import 'dart:ui' show Offset, Size;

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

/// Whether a comment-stripped, trimmed line is the `theme` KEY — `theme`
/// followed by `=` (whitespace between). The strict tail keeps future
/// keys sharing the prefix (`theme_extra`) out of both halves below.
final _themeKeyStart = RegExp(r'^theme\s*=');

/// One line reduced to what the key rules see: comment stripped, trimmed.
String _stripLine(String line) {
  final comment = line.indexOf('#');
  if (comment >= 0) line = line.substring(0, comment);
  return line.trim();
}

/// Extract `theme = "light|dark|system"`, tolerating comments and
/// spacing. Only the app's own writer and a human hand edit this file,
/// so a one-key line parser is the whole grammar. The value must be a
/// quoted string — this is TOML, and an unquoted or otherwise malformed
/// line is a syntax error that reads as "no preference" (null; the
/// caller defaults to system), like the engine's own tolerant loaders.
ThemeMode? _parseTheme(String text) {
  for (var line in text.split('\n')) {
    line = _stripLine(line);
    if (!_themeKeyStart.hasMatch(line)) continue;
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
/// key is located by the reader's own rule ([_themeKeyStart] over
/// comment-stripped lines); appending repairs a missing trailing newline
/// so the key never glues onto the current last line, and a replaced
/// file always ends with exactly one (later keys append cleanly).
String _withThemeLine(String text, String line) =>
    _withOneKey(text, _themeKeyStart, line);

String _withTrailingNewline(String text) =>
    text.isEmpty || text.endsWith('\n') ? text : '$text\n';

// ---- geometry keys (ticket 20) -------------------------------------------

/// Comment-stripped key starts for the geometry pair, the same rule the
/// theme key uses. Strict tails keep prefix-sharing keys
/// (`orb_position_note`) out.
final _orbPositionKeyStart = RegExp(r'^orb_position\s*=');
final _panelSizeKeyStart = RegExp(r'^panel_size\s*=');

/// A pair value: `[-1920, 48]`, `[ 420 , 560.5 ]` — two numbers, ints or
/// decimals, negatives included (multi-monitor coordinates left of the
/// primary).
final _pairTail = RegExp(
  r'^\[\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\]$',
);

/// The geometry keys as loaded: null = absent or broken (keep the
/// in-memory default; a broken prefs file never blocks startup).
typedef UiGeometry = ({Offset? orbPosition, Size? panelSize});

/// Read both geometry keys from the first `spokenrectifier-ui.toml`
/// among `dirs`. Tolerance matches the theme reader: missing/unreadable
/// file or malformed values read as null. A non-positive panel size is
/// broken, not small — null.
UiGeometry loadUiGeometry(List<String> dirs) {
  for (final dir in dirs) {
    final file = File('$dir/$uiPrefsFile');
    String text;
    try {
      if (!file.existsSync()) continue;
      text = file.readAsStringSync();
    } catch (_) {
      continue; // unreadable: as good as absent
    }
    final pos = _parsePair(_orbPositionKeyStart, text);
    final size = _parsePair(_panelSizeKeyStart, text);
    return (
      orbPosition: pos == null ? null : Offset(pos.$1, pos.$2),
      panelSize: size == null || size.$1 <= 0 || size.$2 <= 0
          ? null
          : Size(size.$1, size.$2),
    );
  }
  return (orbPosition: null, panelSize: null);
}

/// First occurrence of a pair key, as two doubles. A present-but-broken
/// key is null (like a broken theme line), an absent key also null.
(double, double)? _parsePair(RegExp keyStart, String text) {
  for (var line in text.split('\n')) {
    line = _stripLine(line);
    if (!keyStart.hasMatch(line)) continue;
    final tail = line.substring(line.indexOf('=') + 1).trim();
    final match = _pairTail.firstMatch(tail);
    if (match == null) return null;
    return (double.parse(match.group(1)!), double.parse(match.group(2)!));
  }
  return null;
}

/// Persist the geometry keys. Null parameters leave their key untouched;
/// the write lands in the file the reader resolves (never a shadowing
/// copy), every other line survives verbatim. Throws when nothing is
/// writable — same contract as the theme writer.
void saveUiGeometry(List<String> dirs, {Offset? orbPosition, Size? panelSize}) {
  final newLines = <(RegExp, String)>[];
  if (orbPosition != null) {
    newLines.add((
      _orbPositionKeyStart,
      'orb_position = [${_num(orbPosition.dx)}, ${_num(orbPosition.dy)}]',
    ));
  }
  if (panelSize != null) {
    newLines.add((
      _panelSizeKeyStart,
      'panel_size = [${_num(panelSize.width)}, ${_num(panelSize.height)}]',
    ));
  }
  for (final dir in dirs) {
    final file = File('$dir/$uiPrefsFile');
    if (!file.existsSync()) continue;
    var text = file.readAsStringSync();
    for (final (key, line) in newLines) {
      text = _withOneKey(text, key, line);
    }
    file.writeAsStringSync(text);
    return;
  }
  for (final dir in dirs) {
    try {
      final fresh = '${newLines.map((e) => e.$2).join('\n')}\n';
      File('$dir/$uiPrefsFile').writeAsStringSync(fresh);
      return;
    } on FileSystemException {
      continue; // not writable: the next directory gets its chance
    }
  }
  throw const FileSystemException(
    'no writable directory for the ui prefs file',
  );
}

/// Integral doubles write as ints (hand-editable); the rest keep their
/// shortest exact round-trip form.
String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

// ---- orb visibility -------------------------------------------------------

/// Comment-stripped key start for the orb's visibility, the same rule the
/// theme and geometry keys use.
final _orbVisibleKeyStart = RegExp(r'^orb_visible\s*=');

/// Read the orb's visibility from the first `spokenrectifier-ui.toml`
/// among `dirs`. Tolerance family: a missing or unreadable file, a
/// missing key, or a broken value reads as true (visible) — the same
/// no-surprise direction as the theme's system fallback: a broken prefs
/// file never hides the orb (the only surface with a hide switch lives
/// in the tray, and a hidden orb has no surface to un-hide it).
bool loadUiOrbVisible(List<String> dirs) {
  for (final dir in dirs) {
    final file = File('$dir/$uiPrefsFile');
    String text;
    try {
      if (!file.existsSync()) continue;
      text = file.readAsStringSync();
    } catch (_) {
      continue; // unreadable: as good as absent
    }
    for (var line in text.split('\n')) {
      line = _stripLine(line);
      if (!_orbVisibleKeyStart.hasMatch(line)) continue;
      final tail = line.substring(line.indexOf('=') + 1).trim();
      // true/false, unquoted — a quoted string or anything else is a
      // broken value, not a hidden orb.
      if (tail == 'false') return false;
      return true;
    }
    return true; // file without the key: today's startup behavior
  }
  return true;
}

/// Persist the orb's visibility. The write lands in the file the reader
/// resolves (never a shadowing copy), every other line survives verbatim.
/// Throws when nothing is writable — same contract as the theme writer.
void saveUiOrbVisible(List<String> dirs, bool visible) {
  final line = 'orb_visible = ${visible ? 'true' : 'false'}';
  for (final dir in dirs) {
    final file = File('$dir/$uiPrefsFile');
    if (!file.existsSync()) continue;
    file.writeAsStringSync(
      _withOneKey(file.readAsStringSync(), _orbVisibleKeyStart, line),
    );
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

/// Swap one key into `text`, preserving every other line — the rule
/// behind [_withThemeLine], generalized.
String _withOneKey(String text, RegExp keyStart, String line) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (keyStart.hasMatch(_stripLine(lines[i]))) {
      lines[i] = line;
      return _withTrailingNewline(lines.join('\n'));
    }
  }
  final prefix = text.isEmpty || text.endsWith('\n') ? '' : '\n';
  return '$text$prefix$line\n';
}
