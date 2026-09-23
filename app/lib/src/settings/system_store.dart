/// The settings window's system seam: the advanced timings (an editable
/// form, ADR-0007 revised 2026-08-28 — a save writes the layer files and
/// hands the new values to the live engine: engine timings from the next
/// session on, insertion timings at once), the about info, and the
/// open-config-file entry the tray already owns (the same bridge call —
/// 同源迁移, ticket 19). Injectable so widget tests run with an
/// in-memory model and no Rust dylib.

library;

import '../rust/api/about.dart' as rust;
import '../rust/api/advanced.dart' as rust;

/// The effective `[engine]` timings (plain Dart ints; the wire's u64
/// arrives as BigInt, the seam converts).
class EngineTiming {
  const EngineTiming({
    required this.passageMode,
    required this.paragraphSilenceMs,
    required this.sessionEndSilenceMs,
    required this.rectifyTimeoutMs,
  });

  final bool passageMode;
  final int paragraphSilenceMs;
  final int sessionEndSilenceMs;
  final int rectifyTimeoutMs;

  @override
  bool operator ==(Object other) =>
      other is EngineTiming &&
      other.passageMode == passageMode &&
      other.paragraphSilenceMs == paragraphSilenceMs &&
      other.sessionEndSilenceMs == sessionEndSilenceMs &&
      other.rectifyTimeoutMs == rectifyTimeoutMs;

  @override
  int get hashCode => Object.hash(
    passageMode,
    paragraphSilenceMs,
    sessionEndSilenceMs,
    rectifyTimeoutMs,
  );
}

/// The effective `[insertion]` timings.
class InsertionTiming {
  const InsertionTiming({
    required this.mode,
    required this.focusSettleMs,
    required this.pasteSettleMs,
    required this.typingDelayMs,
  });

  /// `paste` or `typing`.
  final String mode;
  final int focusSettleMs;
  final int pasteSettleMs;
  final int typingDelayMs;

  @override
  bool operator ==(Object other) =>
      other is InsertionTiming &&
      other.mode == mode &&
      other.focusSettleMs == focusSettleMs &&
      other.pasteSettleMs == pasteSettleMs &&
      other.typingDelayMs == typingDelayMs;

  @override
  int get hashCode =>
      Object.hash(mode, focusSettleMs, pasteSettleMs, typingDelayMs);
}

/// Version and open-source info the about pane paints.
class AboutInfo {
  const AboutInfo({required this.version, required this.license, this.repoUrl});

  final String version;
  final String license;
  final String? repoUrl;
}

/// Advanced + about persistence as the two domains need it.
abstract class SystemStore {
  /// The effective engine and insertion timings, right now.
  Future<({EngineTiming engine, InsertionTiming insertion})> loadAdvanced();

  /// Write the form's `[engine]` model (passage mode + the three
  /// timings) and hand it to the live engine (each session snapshots
  /// what it opens with, so the save applies from the NEXT session on).
  /// Returns the re-read view.
  Future<EngineTiming> saveEngineSettings({
    required bool passageMode,
    required int paragraphSilenceMs,
    required int sessionEndSilenceMs,
    required int rectifyTimeoutMs,
  });

  /// Write the form's `[insertion]` model and swap it into the live
  /// inserter at once — the next confirm runs with the new mode and
  /// pacing. Returns the re-read view.
  Future<InsertionTiming> saveInsertionTiming({
    required String mode,
    required int focusSettleMs,
    required int pasteSettleMs,
    required int typingDelayMs,
  });

  /// Version and open-source info.
  Future<AboutInfo> loadAbout();

  /// Open the shared config file in the system editor — the tray
  /// entry's own bridge call (a first run creates a commented stub).
  /// Returns the path that was opened.
  Future<String> openConfigFile();
}

/// The production store over the flutter_rust_bridge calls.
class RustSystemStore implements SystemStore {
  const RustSystemStore();

  @override
  Future<({EngineTiming engine, InsertionTiming insertion})>
  loadAdvanced() async {
    final config = await rust.advancedConfig();
    return (
      engine: EngineTiming(
        passageMode: config.engine.passageMode,
        paragraphSilenceMs: config.engine.paragraphSilenceMs.toInt(),
        sessionEndSilenceMs: config.engine.sessionEndSilenceMs.toInt(),
        rectifyTimeoutMs: config.engine.rectifyTimeoutMs.toInt(),
      ),
      insertion: InsertionTiming(
        mode: config.insertion.mode,
        focusSettleMs: config.insertion.focusSettleMs.toInt(),
        pasteSettleMs: config.insertion.pasteSettleMs.toInt(),
        typingDelayMs: config.insertion.typingDelayMs.toInt(),
      ),
    );
  }

  @override
  Future<EngineTiming> saveEngineSettings({
    required bool passageMode,
    required int paragraphSilenceMs,
    required int sessionEndSilenceMs,
    required int rectifyTimeoutMs,
  }) async {
    final saved = await rust.setEngineSettings(
      passageMode: passageMode,
      paragraphSilenceMs: BigInt.from(paragraphSilenceMs),
      sessionEndSilenceMs: BigInt.from(sessionEndSilenceMs),
      rectifyTimeoutMs: BigInt.from(rectifyTimeoutMs),
    );
    return EngineTiming(
      passageMode: saved.passageMode,
      paragraphSilenceMs: saved.paragraphSilenceMs.toInt(),
      sessionEndSilenceMs: saved.sessionEndSilenceMs.toInt(),
      rectifyTimeoutMs: saved.rectifyTimeoutMs.toInt(),
    );
  }

  @override
  Future<InsertionTiming> saveInsertionTiming({
    required String mode,
    required int focusSettleMs,
    required int pasteSettleMs,
    required int typingDelayMs,
  }) async {
    final saved = await rust.setInsertionTiming(
      mode: mode,
      focusSettleMs: BigInt.from(focusSettleMs),
      pasteSettleMs: BigInt.from(pasteSettleMs),
      typingDelayMs: BigInt.from(typingDelayMs),
    );
    return InsertionTiming(
      mode: saved.mode,
      focusSettleMs: saved.focusSettleMs.toInt(),
      pasteSettleMs: saved.pasteSettleMs.toInt(),
      typingDelayMs: saved.typingDelayMs.toInt(),
    );
  }

  @override
  Future<AboutInfo> loadAbout() async {
    final info = await rust.about();
    return AboutInfo(
      version: info.version,
      license: info.license,
      repoUrl: info.repoUrl,
    );
  }

  @override
  Future<String> openConfigFile() => rust.openConfigFile();
}
