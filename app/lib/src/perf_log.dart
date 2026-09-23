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
import 'package:flutter/scheduler.dart'
    show FrameTiming, SchedulerBinding;

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

/// Stamps [site] with the process's resident set in bytes (16 号票): the
/// memory pipeline's counterpart to the wall-clock stamp — one process,
/// one RSS, so a value written from the settings engine's isolate reads
/// against one from the main engine's (the boot milestones attribute by
/// delta only if they share that one number).
void logPerfMem(String site) {
  _write('[sr-perf][$site] rss=${ProcessInfo.currentRss}B');
}

/// Formats a timing over [threshold] into a log line, or null when the
/// frame was fast enough — the testable core of [observeFrameJank].
String? frameSlowLine(
  FrameTiming timing, {
  Duration threshold = const Duration(milliseconds: 32),
}) {
  if (timing.buildDuration + timing.rasterDuration <= threshold) {
    return null;
  }
  return '[sr-perf][frame_slow] build '
      '${timing.buildDuration.inMilliseconds}ms raster '
      '${timing.rasterDuration.inMilliseconds}ms '
      '@${DateTime.now().millisecondsSinceEpoch}';
}

/// Watches the frame pipeline and logs every slow frame's wall clock
/// (16 号票 排查轮): a jank cluster's position in the log reads against
/// the arm/boot stamps and the data-load stamps of the same run, which
/// is how the scroll jank gets attributed instead of guessed. The main
/// engine attaches this; the settings engine's boot frames are slow by
/// design and would only add noise.
void observeFrameJank() {
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final timing in timings) {
      final line = frameSlowLine(timing);
      if (line != null) _write(line);
    }
  });
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
