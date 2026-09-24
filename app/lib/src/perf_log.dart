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
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/scheduler.dart' show FrameTiming, SchedulerBinding;

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
    feedRecordingFrames(timings);
  });
}

// ---- the recording steady-state watch (17 号票) ----------------------------
//
// The 挂卡 render story has a cause side (controller notifies: the 20Hz
// synthesized level tick plus the envelope events) and an effect side
// (frames scheduled, and each frame's build/raster cost). Both sides go
// into one summary line per window while a recording is under way, so
// the real machine's log carries the before/after numbers of the
// repaint-storm fix without DevTools in the loop.

/// How much recording wall time one summary line covers.
const recordingWindowLength = Duration(seconds: 5);

/// True while the watch runs — the recording state transitions own
/// this (start on entering Recording, stop on leaving it).
bool _recordingWatch = false;

/// The frames bucketed into the window currently open, and the notify
/// count the window opened at (the delta is the cause side).
final List<FrameTiming> _recordingFrames = [];
int _recordingNotifies0 = 0;

/// Where the cause side is read from (the controller's own counter).
int Function() _recordingNotifyCount = () => 0;

/// Starts (or restarts) the steady-state watch. The controller calls
/// this on entering Recording with its notify counter; harmless in
/// tests, where the log stays console-only.
void startRecordingWatch(int Function() notifyCount) {
  _recordingWatch = true;
  _recordingNotifyCount = notifyCount;
  _recordingNotifies0 = notifyCount();
  _recordingFrames.clear();
}

/// Stops the watch and writes whatever partial window is open.
void stopRecordingWatch() {
  if (!_recordingWatch) return;
  _recordingWatch = false;
  _writeRecordingWindow();
  _recordingFrames.clear();
}

/// The timings callback's tap into the watch (the same registration
/// [observeFrameJank] already owns): buckets the batch, closes the
/// window when it has covered its wall length.
void feedRecordingFrames(List<FrameTiming> timings) {
  if (!_recordingWatch || timings.isEmpty) return;
  _recordingFrames.addAll(timings);
  final windowStart = _recordingFrames.first.timestampInMicroseconds(
    FramePhase.vsyncStart,
  );
  final windowEnd = timings.last.timestampInMicroseconds(FramePhase.vsyncStart);
  if (Duration(microseconds: windowEnd - windowStart) >=
      recordingWindowLength) {
    _writeRecordingWindow();
    _recordingFrames.clear();
  }
}

void _writeRecordingWindow() {
  final line = recordingWindowLine(
    frames: _recordingFrames,
    notifies: _recordingNotifyCount() - _recordingNotifies0,
  );
  if (line != null) _write(line);
  // The next window (or the final partial one) counts from here.
  _recordingNotifies0 = _recordingNotifyCount();
}

/// Formats one window's summary, or null when no frame landed in it —
/// the testable core of the watch.
String? recordingWindowLine({
  required List<FrameTiming> frames,
  required int notifies,
}) {
  if (frames.isEmpty) return null;
  final window = Duration(
    microseconds:
        frames.last.timestampInMicroseconds(FramePhase.vsyncStart) -
        frames.first.timestampInMicroseconds(FramePhase.vsyncStart),
  );
  var buildTotal = Duration.zero;
  var buildMax = Duration.zero;
  var rasterTotal = Duration.zero;
  var rasterMax = Duration.zero;
  for (final t in frames) {
    buildTotal += t.buildDuration;
    if (t.buildDuration > buildMax) buildMax = t.buildDuration;
    rasterTotal += t.rasterDuration;
    if (t.rasterDuration > rasterMax) rasterMax = t.rasterDuration;
  }
  String us(Duration d) => d.inMicroseconds.toString();
  return '[sr-perf][recording_window] ${window.inMilliseconds}ms '
      'frames=${frames.length} notifies=$notifies '
      'build_avg=${us(buildTotal ~/ frames.length)}us '
      'build_max=${us(buildMax)}us '
      'raster_avg=${us(rasterTotal ~/ frames.length)}us '
      'raster_max=${us(rasterMax)}us';
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
