/// The perf observation seam (07 号票): the record file's placement
/// (first writable search dir, the ui prefs order), the run header, the
/// append-only growth, and the tolerance family — a seam that cannot
/// write must never throw, and a disk that vanishes mid-run retires the
/// file without a sound.

library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/src/perf_log.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sr-perf-log');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Directory dir(String name) {
    final d = Directory('${tmp.path}/$name')..createSync();
    return d;
  }

  test('attaching stamps a run header in the first writable dir', () {
    final first = dir('first');
    final second = dir('second');
    attachPerfLog([first.path, second.path]);
    final header = File('${first.path}/$perfLogFile').readAsStringSync();
    expect(header.startsWith('--- run '), isTrue);
    expect(File('${second.path}/$perfLogFile').existsSync(), isFalse);
  });

  test('a log line lands verbatim, appended after the header', () {
    final home = dir('home');
    attachPerfLog([home.path]);
    logPerf('perf_session_recording', const Duration(milliseconds: 42));
    logPerf('perf_session_first_text', const Duration(milliseconds: 412));
    final lines = File('${home.path}/$perfLogFile').readAsLinesSync();
    expect(lines[0].startsWith('--- run '), isTrue);
    expect(lines[1], '[sr-perf][perf_session_recording] 42ms');
    expect(lines[2], '[sr-perf][perf_session_first_text] 412ms');
  });

  test('a stamp carries the wall clock, not a duration', () {
    final home = dir('stamps');
    attachPerfLog([home.path]);
    final before = DateTime.now().millisecondsSinceEpoch;
    logPerfStamp('settings_click');
    logPerfStamp('settings_entry');
    final after = DateTime.now().millisecondsSinceEpoch;
    final lines = File('${home.path}/$perfLogFile').readAsLinesSync();
    // Two engines' stamps must be subtractable: both parse as integers,
    // both sit inside the writing window, and neither reads as a
    // duration.
    for (final (i, site) in ['settings_click', 'settings_entry'].indexed) {
      final match = RegExp(
        r'^\[sr-perf\]\[([\w]+)\] @(\d+)$',
      ).firstMatch(lines[i + 1])!;
      expect(match.group(1), site);
      final at = int.parse(match.group(2)!);
      expect(at, greaterThanOrEqualTo(before));
      expect(at, lessThanOrEqualTo(after));
    }
  });

  test('nothing writable leaves the seam console-only and quiet', () {
    // A file standing where a directory was claimed: every open fails.
    final blocker = File('${tmp.path}/blocker')..writeAsStringSync('');
    attachPerfLog([blocker.path]);
    logPerf('perf_session_reply', const Duration(milliseconds: 7));
    expect(File('${blocker.path}/$perfLogFile').existsSync(), isFalse);
  });

  test('a vanished record retires the file without throwing', () {
    final home = dir('gone');
    attachPerfLog([home.path]);
    home.deleteSync(recursive: true);
    logPerf('perf_session_recording', const Duration(milliseconds: 1));
  });
}
