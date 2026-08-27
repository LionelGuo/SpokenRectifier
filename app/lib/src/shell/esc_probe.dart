/// TEMPORARY diagnostic probe (e2e focus round 3): appends one line per
/// Esc sighting to `esc-debug.log` next to the exe, mirroring the
/// Rust-side esc_guard probe — together they pinpoint which layer ate a
/// dead Esc (hook verdict vs OS delivery vs Flutter dispatch). No-op off
/// Windows, so widget tests on Linux never touch the disk. Delete both
/// probes once the diagnosis lands.

library;

import 'dart:io';

void escProbe(String note) {
  if (!Platform.isWindows) return;
  try {
    final dir = File(Platform.resolvedExecutable).parent;
    final log = File('${dir.path}${Platform.pathSeparator}esc-debug.log');
    log.writeAsStringSync(
      '${DateTime.now().millisecondsSinceEpoch} flutter $note\n',
      mode: FileMode.append,
    );
  } catch (_) {
    // Diagnostics never break the app.
  }
}
