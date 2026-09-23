/// The perf observation seam (07 号票): stage transitions worth a
/// millisecond number log here, so a debug run's console holds the
/// click-to-card pipeline without touching any UI. Same contract as
/// [logRawError] in errors.dart — a site tag plus the raw value; no
/// tracing framework, no file.

library;

import 'package:flutter/foundation.dart' show debugPrint;

/// Logs [elapsed] at [site]. The only timing seam this effort adds.
void logPerf(String site, Duration elapsed) {
  debugPrint('[sr-perf][$site] ${elapsed.inMilliseconds}ms');
}
