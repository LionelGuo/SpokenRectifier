/// The perf observation seam (07 号票): stage transitions worth a
/// millisecond number log here, so a debug run leaves the
/// click-to-card pipeline's numbers without touching any UI.
///
/// Two sinks, one line: the console (a `flutter run` session shows it
/// live), and an append-only record file beside `spokenrectifier-ui.toml`
/// — the real machine proved a standalone GUI-subsystem exe has no
/// stdout a terminal or a PowerShell redirection can read (07 号票
/// Comment 3), but it always has a disk. The file is the seam that
/// survives every launch mode; the console line stays a courtesy.

library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// The record file's name, resolved inside the ui prefs search dirs —
/// the working directory first, then the exe's directory (dev runs vs a
/// double-clicked portable exe), the same order `spokenrectifier-ui.toml`
/// uses.
const perfLogFile = 'spokenrectifier-perf.log';

/// The record file the first writable search dir owns; null until
/// [attachPerfLog] finds one (or after the disk takes it away).
File? _record;

/// Point the seam at its record file — the first writable dir among
/// [dirs] — and stamp the run's header line. Best-effort: when nothing
/// is writable the seam stays console-only and every log is a no-op
/// past the console. The controller calls this once at birth with the
/// same dirs the ui prefs use, so the two files are neighbors.
void attachPerfLog(List<String> dirs) {
  _record = null;
  for (final dir in dirs) {
    final file = File('$dir/$perfLogFile');
    try {
      final sink = file.openSync(mode: FileMode.append);
      sink.writeStringSync('--- run ${DateTime.now()} ---\n');
      sink.closeSync();
      _record = file;
      return;
    } on FileSystemException {
      continue; // not writable: the next directory gets its chance
    }
  }
}

/// Logs [elapsed] at [site]: the console line, then the record file's
/// append. The only timing seam this effort adds.
void logPerf(String site, Duration elapsed) {
  _write('[sr-perf][$site] ${elapsed.inMilliseconds}ms');
}

/// Stamps [site] with the wall clock (ms since epoch). The settings
/// pipeline (08 号票) spans TWO engines in one process — the click is
/// timed in the main isolate, the boot stages in the sub-engine's — and
/// a duration measured in one isolate cannot be subtracted from one
/// measured in another. Stamps can: one process, one clock.
void logPerfStamp(String site) {
  _write('[sr-perf][$site] @${DateTime.now().millisecondsSinceEpoch}');
}

void _write(String line) {
  debugPrint(line);
  final file = _record;
  if (file == null) return;
  try {
    final sink = file.openSync(mode: FileMode.append);
    sink.writeStringSync('$line\n');
    sink.closeSync();
  } on FileSystemException {
    _record = null; // the disk went away mid-run: console-only from here
  }
}
