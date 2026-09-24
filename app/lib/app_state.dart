/// App state: the speech controller mirrors engine events into UI state
/// and drives the fake speech while recording.
///
/// User inputs (orb clicks, hotkey, Enter/Esc) all route through the
/// pure [flowAction] table in session_flow.dart — the single source the
/// orb position and the hotkey main flow share (ticket 15). The engine
/// stays authoritative for the phase; this controller only translates.
///
/// The engine access is behind [SpeechEngineGateway] so widget tests run
/// with a pure-Dart fake — no Rust dylib needed.

library;

import 'dart:async';
import 'dart:math';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;

import 'src/design/tokens.dart' show SrGeometry, SrMotion;
import 'src/errors.dart';
import 'src/perf_log.dart';
import 'src/rust/api/engine.dart';
import 'src/rust/api/history.dart';
import 'src/rust/api/library.dart';
import 'src/session/thinking_marquee.dart' show ThinkingMarquee;
import 'src/shell/history_retrieval.dart'
    show DefaultRegisterPick, NamedScenarioPick, ScenarioPick;
import 'hotkey_binding.dart';
import 'src/shell/session_flow.dart';
import 'ui_prefs.dart';

/// Everything the controller needs from the engine bridge.
abstract class SpeechEngineGateway {
  Future<void> startSession();
  Future<void> stopSession();
  Future<void> cancelSession();
  Future<void> confirmInsert(List<BridgePlaceholderFill> placeholders);
  Future<void> reroll();
  Future<void> updatePreviewText(String text);
  Future<void> pinPlaceholder();
  Future<void> rectifyText(
    String rawTranscript, {
    required BridgeSessionStyle style,
    PlatformInt64? sourceSessionId,
  });
  Future<List<BridgeScenario>> scenarios();
  Future<void> setStyleDirective(String? directive, {String? scenario});
  Future<String?> globalDirective();
  Future<void> setGlobalDirective(String? directive);
  Future<List<String>> termsList();
  Future<void> appendTerm(String term);
  Future<void> removeTerm(String term);
  Future<void> restoreFocus();
  Future<void> openConfigFile();
  Future<List<BridgeHistoryEntry>> historyList();
  Future<void> historyClear();
  Future<void> fakeBeginSession();
  Future<void> fakeSay(String text);
  Future<void> fakeSilence(int elapsedMs);
  Stream<BridgeEventEnvelope> events();

  /// Arm the primary-hotkey hold watcher (ADR-0020). Returns whether a
  /// watch is now live — Dart swallows `WM_HOTKEY` repeats off that.
  /// False (never an error) when the master switch is off, the engine
  /// is not recording, or the host cannot poll (non-Windows).
  Future<bool> watchHold(List<int> vks, {required bool stopOnEarlyRelease});

  /// Whether the hold watcher is currently running.
  Future<bool> isHolding();
}

/// The 900 ms receipt flash the ball shows after a session ends:
/// green check (inserted) or grey cross (cancelled) before it rests
/// back to idle.
enum OrbFlash { none, inserted, cancelled }

/// The pin hotkey's platform registration seam (ticket 21 / 16): the
/// chord's global registration, bound to the listening phase —
/// registered the moment a session enters recording, handed back the
/// moment listening ends, so an idle press belongs to whatever app owns
/// the chord (Firefox's bookmark menu and friends). The production
/// implementation wraps hotkey_manager (main.dart); tests inject a
/// recorder. One registrar serves one engine process, like the Esc
/// guard. The chord itself is an argument so a rebind mid-session
/// unregisters the old object and registers the new one.
abstract class PinHotkeyRegistrar {
  /// Take [chord] globally; [onPin] fires on each press while
  /// registered. A [HotkeyBinding.none] is a no-op (empty bind).
  Future<void> register(HotkeyBinding chord, VoidCallback onPin);

  /// Hand the chord back to the system at once.
  Future<void> unregister();
}

/// The main-flow hotkey's platform registration seam (ticket 16): held
/// for the process lifetime, swapped in place on a rebind. Empty bind
/// = not registered (the orb still steps). Tests inject a recorder.
abstract class PrimaryHotkeyRegistrar {
  /// Unregister whatever is current, then register [chord] (a no-op
  /// when it is [HotkeyBinding.none]).
  Future<void> apply(HotkeyBinding chord, VoidCallback onPress);

  /// Drop the current registration without replacing it (capture).
  Future<void> unregister();
}

/// Mirrors the engine's event stream into UI state and drives the scripted
/// speech while recording. The Rust-backed gateway lives in `gateway.dart`.
class SpeechController extends ChangeNotifier {
  SpeechController({
    required this.gateway,
    this.scriptedPhrases = const [],
    this.speechInterval = const Duration(milliseconds: 900),
    this.themeMode = ThemeMode.system,
    this.orbVisible = true,
    this.primaryChord = HotkeyBinding.primaryDefault,
    this.pinChord = HotkeyBinding.pinDefault,
    this.primaryHotkeys,
    this.pinHotkey,
    List<String>? uiPrefsDirs,
  }) : uiPrefsDirs = uiPrefsDirs ?? uiPrefsSearchDirs() {
    // The perf record (07 号票) lives beside the ui prefs file; pointing
    // it here keeps the two app-owned files neighbors whatever launched us.
    attachPerfLog(uiPrefsDirs ?? uiPrefsSearchDirs());
    // onError: a subscribe against a not-yet-created engine emits a stream
    // error; the command paths surface the same failure with better
    // wording, so swallow it here instead of leaving it unhandled.
    _subscription = gateway.events().listen(
      _onEnvelope,
      onError: (Object _) {},
    );
  }

  final SpeechEngineGateway gateway;
  final List<String> scriptedPhrases;
  final Duration speechInterval;

  /// The pin hotkey registration seam; null = no hotkey (tests that do
  /// not exercise the pin, and any host without the platform plugin).
  /// The lifecycle is bound to the listening phase right here: register
  /// on entering recording, unregister the moment it ends. The chord
  /// itself is [pinChord].
  final PinHotkeyRegistrar? pinHotkey;

  /// The main-flow hotkey registration seam; null = no hotkey (tests
  /// that do not exercise the step key). The chord itself is
  /// [primaryChord]; [installProductHotkeys] / a rebind call [apply].
  final PrimaryHotkeyRegistrar? primaryHotkeys;

  /// The main-flow chord as the file last read it. Seeded at startup;
  /// a settings-window edit re-reads the file ([onHotkeysChanged]).
  HotkeyBinding primaryChord;

  /// The pin chord as the file last read it. Same lifecycle as
  /// [primaryChord]; an empty bind means listening never takes a chord.
  HotkeyBinding pinChord;

  /// Capture (the settings window is recording a row): both product
  /// chords are unregistered so the recorder can hear the press.
  bool _hotkeysPaused = false;

  /// This physical hold of the primary chord has a watcher (or is
  /// arming one). Repeats of the same `WM_HOTKEY` are swallowed until
  /// the watcher ends — otherwise the first auto-repeat would stop the
  /// session we just started. Independent of the orb, which still
  /// stops on click through [dispatchInput].
  bool _hotkeyHoldActive = false;

  /// [gateway.watchHold] returned true for the current hold: the
  /// poller is live. Distinguishes "arming" (swallow unconditionally)
  /// from "the opening watch already ended" (the next press is a new
  /// hold, possibly the tap-to-stop).
  bool _holdArmed = false;

  StreamSubscription<BridgeEventEnvelope>? _subscription;
  Timer? _speechTimer;
  Timer? _micBreathTimer;
  Timer? _flashTimer;
  Timer? _thinkingTimer;
  int _nextPhrase = 0;
  int _tick = 0;

  /// Current session phase, mirrored from state-change events.
  BridgeSessionState phase = BridgeSessionState.idle;

  /// This recording was upgraded to quick mode (ADR-0020). Set on
  /// [BridgeEvent_QuickMarked]; cleared the moment listening ends
  /// (Recording → *). The session window paints 「快速」 only while
  /// [phase] is still recording and this is true.
  bool quickMarked = false;

  /// Live transcript as the ASR fake streams it (paragraphs as newlines).
  String liveText = '';

  /// Number of paragraph marks in the current session.
  int paragraphMarks = 0;

  /// Whether the user is speaking per VAD; only meaningful while recording.
  /// Mirrors speech-activity events from the microphone pipeline.
  bool speaking = false;

  /// Synthesized mic loudness, 0..1, while recording — drives the orb's
  /// level ring and glow (non-size recording dynamics). The engine only
  /// reports a speaking boolean, so liveliness is synthesized from it.
  double micLevel = 0;

  /// When the current recording started (header timer); null outside one.
  DateTime? recordStartedAt;

  /// The click-to-card observation window (07 号票): started at the
  /// session-start entry, logged and retired as the recording event and
  /// the first live transcript land. Null outside a starting session.
  Stopwatch? _perfSessionStart;

  /// Elapsed recording time for the session header.
  Duration get recordElapsed => recordStartedAt == null
      ? Duration.zero
      : DateTime.now().difference(recordStartedAt!);

  /// The current rectify attempt's thinking marquee (14 号票): created
  /// on entering rectifying, dies with the attempt (a reroll gets a
  /// fresh one). The thinking text lives ONLY here — one-shot feedback
  /// material for the marquee, never the preview text, never inserted.
  ThinkingMarquee? thinking;

  /// Whether the header paints the 思考中 three-piece now. Signal-driven
  /// (zero-trace): only a real thinking token turns it on — a thinking
  /// policy left off, an unconfigured connection, or an endpoint that
  /// never walks the channel leaves the word at 修正中 with no band, no
  /// shimmer, no breath, no timer.
  bool get thinkingActive =>
      phase == BridgeSessionState.rectifying &&
      thinking != null &&
      thinking!.thinkStarted &&
      !thinking!.handedOver;

  /// The receipt flash currently overriding the orb's idle look.
  OrbFlash orbFlash = OrbFlash.none;

  /// UI theme, seeded at startup from `spokenrectifier-ui.toml` (missing
  /// file = follow the system). The quick panel's tri-state switcher
  /// repaints it at once and writes it back — the read/write loop.
  ThemeMode themeMode;

  /// Where the theme write-back lands (the app-owned prefs file's search
  /// directories); injectable so tests point it at a scratch directory.
  final List<String> uiPrefsDirs;

  /// Whether the quick panel (同形同位互斥) is open over the idle orb.
  /// Only ever true while idle: a session start force-closes it.
  bool quickOpen = false;

  /// The shared footprint's size intent (ticket 20): what the panels try
  /// to open at. Every open clamps it to what the current anchor can
  /// host (window_geometry); the resize handles update it and persist it
  /// to ui.toml. The design token stays the restore default.
  Size panelFootprint = SrGeometry.panelSize;

  /// Last known anchor — the orb's ball center in logical screen
  /// coordinates (ticket 20). Updated by every geometry gesture; the
  /// bootstrap ALWAYS seeds it at startup (restored position or the
  /// computed default, 16 号票/ADR-0022 — the window is the whole work
  /// area and no longer implies where the ball sits). Null only in the
  /// degenerate no-displays launch (saves then write only the panel
  /// key).
  Offset? orbAnchor;

  /// Whether the floating orb is visible at all. Seeded at startup from
  /// `spokenrectifier-ui.toml` (missing/broken key = visible); every
  /// toggle writes back at once — the tray checkbox, the tray click and
  /// the settings window's switch all ride [setOrbVisible], the single
  /// writer entry.
  bool orbVisible;

  /// Last engine error as an on-screen short sentence (the window toast
  /// while a panel is open, the tray tooltip while idle — 小修 24: the
  /// idle orb window's region cannot fit a tooltip bubble, so the
  /// sentence rides the tray, the one channel no region clips). The raw
  /// exception is in the console via [logRawError] — never here.
  String? lastError;

  /// Bumped every time a new error is surfaced, so a panel can toast
  /// even when the short sentence repeats.
  int lastErrorSeq = 0;

  void _setLastError(String message) {
    lastError = message;
    lastErrorSeq++;
  }

  /// The engine refused to assemble at launch (e.g. an ASR provider
  /// with credentials but no adapter). Sticky for the run: every start
  /// click then fails against a dead engine, and that generic failure
  /// must not mask the root cause already in [lastError].
  bool startupFailed = false;

  /// The idle orb carries a pending error (badge + tooltip): a launch
  /// refusal or a failed start the user has not yet acted past.
  bool get orbErrorPending =>
      stage == StageKind.orb && orbFlash == OrbFlash.none && lastError != null;

  /// The scenario library (场景库), loaded once at startup. Empty when the
  /// library file is missing or blank — every picker hides entirely then.
  List<BridgeScenario> scenarios = const [];

  /// The selected scenario's name; null = the built-in default register.
  /// Never persisted: every launch starts on the default (ADR-0004).
  String? selectedScenario;

  /// The one-time style pick the current re-rectify session runs under
  /// (ticket 23's 指定场景重新修正, ticket 28's 默认): the menu pick the
  /// session opened with, cleared when that session ends. The session
  /// window's chip paints it in the standard 场景 · X format while it
  /// runs; the engine holds the actual pin for the session's lifetime.
  ScenarioPick? oneTimeStyle;

  /// The global directive (全局指令, ticket 22) as the file reads it:
  /// null = unset. The quick panel's preview card paints it; the engine
  /// holds its own live copy (pushed on load and on every change), so
  /// the next rectify attempt — rerolls included — runs with it.
  String? globalDirective;

  bool get isRecording => phase == BridgeSessionState.recording;

  /// The surface the morphing window should settle on. The stage host
  /// lags this during collapse (exit animation first, then the shrink).
  StageKind get stage => stageFor(phase, quickOpen);

  // ---- input: one pure table behind the orb, the hotkey and the keys ---

  /// Executes an input through the [flowAction] table — the one entry
  /// the orb click, the hotkey, Enter and Esc all share.
  Future<void> dispatchInput(SessionInput input) async {
    switch (flowAction(phase, input)) {
      case SessionCommand.start:
        await startSession();
      case SessionCommand.stop:
        await stopSession();
      case SessionCommand.confirm:
        await confirmWhatYouSee();
      case SessionCommand.cancel:
        await cancelSession();
      case null:
        break; // ignored by the table (e.g. the orb is disabled)
    }
  }

  /// Left click on the orb / anchor. Stage-aware: the ball is the close
  /// button while the quick panel is open; otherwise it steps the main
  /// flow (the table ignores it while rectifying).
  Future<void> orbPrimary() async {
    if (quickOpen) {
      await closeQuick();
      return;
    }
    await dispatchInput(SessionInput.primary);
  }

  /// The hotkey press — same step as the orb's left click, minus the
  /// panel-close role (a session start force-closes the quick panel).
  ///
  /// The hold watcher owns the primary chord's release (ADR-0020), on or
  /// off the quick-mode switch: a recording press stops on its release,
  /// and repeats of the same physical hold are swallowed — a switch-off
  /// hold must not toggle start/stop through auto-repeat. The orb still
  /// goes through [dispatchInput] and stops on click.
  Future<void> hotkeyToggle() async {
    if (_hotkeyHoldActive) {
      // Still handing the chord to the poller: a WM_HOTKEY repeat
      // during startSession must not fire a second Start.
      if (!_holdArmed) return;
      if (await gateway.isHolding()) return;
      // The opening watch ended (short release); this press is new.
      _hotkeyHoldActive = false;
      _holdArmed = false;
    }

    if (phase == BridgeSessionState.recording) {
      _hotkeyHoldActive = true;
      if (await _armHoldWatcher(stopOnEarlyRelease: true)) {
        _holdArmed = true;
        return;
      }
      _hotkeyHoldActive = false;
      await dispatchInput(SessionInput.primary);
      return;
    }

    final starting = phase == BridgeSessionState.idle;
    if (starting) _hotkeyHoldActive = true;
    await dispatchInput(SessionInput.primary);
    if (starting) {
      if (await _armHoldWatcher(stopOnEarlyRelease: false)) {
        _holdArmed = true;
      } else {
        _hotkeyHoldActive = false;
      }
    }
  }

  /// Hand the current primary chord to the hold watcher. False means
  /// Dart keeps today's tap path (empty bind, not recording, or a
  /// host that cannot poll).
  Future<bool> _armHoldWatcher({required bool stopOnEarlyRelease}) async {
    if (primaryChord.isNone) return false;
    try {
      return await gateway.watchHold(
        primaryChord.win32Vks,
        stopOnEarlyRelease: stopOnEarlyRelease,
      );
    } catch (_) {
      return false;
    }
  }

  /// The pin hotkey's press (ticket 21 / 16): pin a placeholder at the
  /// current end of the spoken segment. The chord is registered exactly
  /// while listening, so this only ever fires there — the phase guard
  /// covers the unregister race (a press that arrived while the key
  /// handback was still in flight). A rejection past the guard is
  /// dropped silently: the session is over, there is no slot to pin
  /// into, and no half state exists to report.
  Future<void> pinAction() async {
    if (phase != BridgeSessionState.recording || quickMarked) return;
    try {
      await gateway.pinPlaceholder();
    } catch (_) {
      // The pin raced the session's end; the honest outcome is a drop.
    }
  }

  /// Take the pin chord for this session. A failed registration (the
  /// chord already taken system-wide) surfaces like any engine failure:
  /// the session runs on, pins are just unreachable. Capture
  /// ([_hotkeysPaused]) and an empty bind both skip the register.
  Future<void> _armPinHotkey() async {
    final hotkey = pinHotkey;
    if (hotkey == null || _hotkeysPaused || pinChord.isNone || quickMarked) {
      return;
    }
    try {
      await hotkey.register(pinChord, pinAction);
    } catch (e) {
      logRawError('err_hotkey_pin', e);
      _setLastError('占位图钉快捷键被占用，请更换组合');
      notifyListeners();
    }
  }

  /// Install (or reinstall) the main-flow chord from [primaryChord]. A
  /// capture leaves it unregistered; an empty bind is a no-op apply.
  Future<void> installProductHotkeys() async {
    final registrar = primaryHotkeys;
    if (registrar == null) return;
    if (_hotkeysPaused || primaryChord.isNone) {
      await registrar.unregister();
      return;
    }
    try {
      await registrar.apply(primaryChord, hotkeyToggle);
    } catch (e) {
      logRawError('err_hotkey_main', e);
      _setLastError('主快捷键被占用，请更换组合');
      notifyListeners();
    }
  }

  /// Capture on / off: the settings window is recording a row, so both
  /// product chords come off the OS (the recorder lives in the settings
  /// engine and cannot hear a globally-registered chord). Ending capture
  /// re-hangs from the file as held in memory — the pin only if a
  /// session is currently listening.
  Future<void> setHotkeysPaused(bool paused) async {
    if (_hotkeysPaused == paused) return;
    _hotkeysPaused = paused;
    if (paused) {
      await primaryHotkeys?.unregister();
      await _disarmPinHotkey();
      return;
    }
    await installProductHotkeys();
    if (phase == BridgeSessionState.recording) {
      await _armPinHotkey();
    }
  }

  /// A settings-window edit landed on the hotkey keys: re-read the
  /// file — it is the truth — adopt the new pair, and hot-swap. The
  /// main-flow chord unregisters+registers at once; the pin swaps the
  /// object (armed mid-listen: hand the old chord back, take the new
  /// one; idle: just the object, next listen arms it).
  Future<void> onHotkeysChanged() async {
    final loaded = loadUiHotkeys(uiPrefsDirs);
    primaryChord = loaded.primary;
    pinChord = loaded.pin;
    notifyListeners();
    if (_hotkeysPaused) return; // still capturing; re-hang on release
    await installProductHotkeys();
    if (phase == BridgeSessionState.recording) {
      // Await the handback: the plugin allocates a new native id per
      // register, so a raced unregister leaves a ghost OS hotkey.
      await _disarmPinHotkey();
      await _armPinHotkey();
    }
  }

  /// Hand the pin chord back to the system the moment listening ends
  /// (结束聆听立刻还键) — recording -> anything disarms, cancel
  /// included. A failed handback is dropped: nothing is actionable
  /// there, and the next session's arm retries. The envelope path
  /// fire-and-forgets this; a rebind awaits it so the new chord
  /// cannot land on a still-registered identifier.
  Future<void> _disarmPinHotkey() async {
    try {
      await pinHotkey?.unregister();
    } catch (_) {}
  }

  /// Right click — quick panel, idle only (会话期无右键). The lists the
  /// panel paints refresh as it opens; the shell shows what it has and
  /// the fresh data lands a moment later.
  void orbSecondary() {
    if (phase != BridgeSessionState.idle) return;
    quickOpen = true;
    notifyListeners();
    unawaited(loadTerms());
    unawaited(loadRecentHistory());
  }

  /// Esc is context-sensitive at stage level: close the quick panel
  /// first, otherwise it flows into the session table (which cancels
  /// from every active phase, recording included).
  Future<void> escapeAction() async {
    if (quickOpen) {
      await closeQuick();
      return;
    }
    await dispatchInput(SessionInput.escape);
  }

  /// Enter confirms what is on screen (the table only honors it in
  /// preview; the session field's own Enter handling is the chat-input
  /// style path in the panel widget).
  Future<void> enterAction() => dispatchInput(SessionInput.enter);

  /// Closes the quick panel. [handBackFocus] false collapses QUIETLY:
  /// the foreground stays where it is because the click's destination
  /// is about to claim it — the settings window the entry row opens.
  /// Restoring to the insertion target there would race the settings
  /// window's own focus and could leave it behind (小修 17).
  Future<void> closeQuick({bool handBackFocus = true}) async {
    if (!quickOpen) return;
    quickOpen = false;
    notifyListeners();
    if (!handBackFocus) return;
    // The panel borrowed the foreground while it was open; hand it back
    // the way a cancelled session does. Self-guarded on the inserter
    // side (a foreign foreground is left alone); a failed restore is
    // not actionable — the user simply clicks where they meant to go.
    unawaited(gateway.restoreFocus().catchError((Object _) {}));
  }

  /// Logs one click-to-card observation (07 号票) if a session-start
  /// window is armed; the sites are reply, recording event, and first
  /// transcript.
  void _logSessionPerf(String site) {
    final watch = _perfSessionStart;
    if (watch == null) return;
    logPerf(site, watch.elapsed);
  }

  Future<void> startSession() async {
    final startupError = startupFailed ? lastError : null;
    lastError = null;
    _perfSessionStart = Stopwatch()..start();
    try {
      // Fake speech needs its session armed first; a microphone-mode engine
      // has no fake feed (scriptedPhrases is empty there).
      if (scriptedPhrases.isNotEmpty) {
        await gateway.fakeBeginSession();
      }
      await gateway.startSession();
      _logSessionPerf('perf_session_reply');
      _startScriptedSpeech();
    } catch (e) {
      // e.g. the command was refused: show it, stay idle. No recording
      // event will ever land, so the observation window dies here.
      _perfSessionStart = null;
      // A launch refusal is the root cause — keep it over the click's
      // generic "engine not created yet" failure.
      if (startupError != null) {
        _setLastError(startupError);
      } else {
        logRawError('err_session_start', e);
        _setLastError(classifyEngineError(e));
      }
    }
    notifyListeners();
  }

  Future<void> stopSession() async {
    _stopScriptedSpeech();
    await gateway.stopSession();
    notifyListeners();
  }

  Future<void> cancelSession() async {
    _stopScriptedSpeech();
    await gateway.cancelSession();
    notifyListeners();
  }

  /// The user edited the preview field: adopt the edit immediately so
  /// [previewText] always mirrors what is on screen, then debounce the
  /// push to the engine. Changes arriving once the phase has moved on
  /// (a card fading out) belong to a dead attempt and are dropped.
  void editPreviewText(String text) {
    if (phase != BridgeSessionState.preview) return;
    previewText = text;
    _previewPushDebounce?.cancel();
    _previewPushDebounce = Timer(_previewPushDelay, _pushPreviewEdit);
  }

  /// The rectified text as the user sees it — the single source the
  /// session panel renders and every confirm path inserts. While
  /// rectifying it accumulates the streamed chunks; while previewing it
  /// holds the user's edits (adopted the instant they happen); everywhere
  /// else it is empty. Confirm what you see.
  String previewText = '';

  /// The pin session's prefill table (ticket 18), delivered by the engine
  /// between the last rectified chunk and the Preview state change: each
  /// row is a slot's number and the model's initial value for it, exactly
  /// as written. Lives mid-flight like [previewText] — a reroll re-delivers
  /// the new round's table before re-entering preview, and pin-less
  /// sessions never receive the event at all. The preview editing surface
  /// (ticket 22) is the consumer.
  List<BridgePrefillRow> prefillTable = const [];

  /// The confirm-time slot table the panel keeps current off its slot
  /// document (占位符钉入入库): one row per slot with a live occurrence,
  /// mirroring exactly what [confirmWhatYouSee] would substitute. Lives
  /// mid-flight like [prefillTable] — republished at every round arrival
  /// and slot edit, and dying with the round it belonged to.
  List<BridgePlaceholderFill> placeholderFills = const [];

  /// Debounce for pushing preview edits to the engine: edits are adopted
  /// into [previewText] at once, only the engine push waits.
  Timer? _previewPushDebounce;

  static const _previewPushDelay = Duration(milliseconds: 350);

  Future<void> _pushPreviewEdit() async {
    _previewPushDebounce = null;
    if (phase != BridgeSessionState.preview) return;
    await gateway.updatePreviewText(previewText);
  }

  /// Confirm what is on screen — the one entry every confirm path shares
  /// (button, Enter, hotkey): flush any edit still inside the debounce
  /// window to the engine, then insert, so the inserted text is what the
  /// user sees, not the last pushed snapshot. The slot table rides the
  /// confirm so the store records each slot beside the session pair.
  Future<void> confirmWhatYouSee() async {
    final pushPending = _previewPushDebounce != null;
    _previewPushDebounce?.cancel();
    _previewPushDebounce = null;
    if (phase != BridgeSessionState.preview) return;
    if (pushPending) {
      await gateway.updatePreviewText(previewText);
    }
    await gateway.confirmInsert(placeholderFills);
  }

  /// Surface a startup failure (engine assembly refused to run) the same
  /// way session errors surface, keeping the shell alive to show it. The
  /// raw message is classified into a bucket short-sentence; the original
  /// stays in the console via [logRawError].
  void reportStartupError(String message) {
    logRawError('err_startup', message);
    _setLastError(classifyEngineError(message));
    startupFailed = true;
    notifyListeners();
  }

  Future<void> reroll() => gateway.reroll();

  /// Load the scenario library at startup, painting the pickers. A
  /// failed read keeps the empty library — exactly like an absent file:
  /// the pickers hide their rows, the tray keeps just 默认. Selection
  /// always starts on the default register (never persisted).
  Future<void> loadScenarios() async {
    try {
      scenarios = await gateway.scenarios();
    } catch (_) {
      // The library is decorative: degrade to empty, never block startup.
      scenarios = const [];
    }
    selectedScenario = null;
    notifyListeners();
  }

  /// A settings-window edit landed on the library file: re-read it and
  /// repair the selection. A rename the selection was sitting on carries
  /// it across (through [selectScenario], so the engine adopts the new
  /// directive text); a selection whose entry vanished — deleted, or a
  /// rename away from under it — falls back to the default register.
  /// The three pickers (tray, quick panel, session chip) repaint from
  /// this controller, so one reload syncs them all.
  Future<void> onScenariosLibraryChanged({
    String? renamedFrom,
    String? renamedTo,
  }) async {
    try {
      scenarios = await gateway.scenarios();
    } catch (_) {
      return; // unreadable right now: keep painting what we had
    }
    final selected = selectedScenario;
    if (selected == renamedFrom &&
        renamedTo != null &&
        _hasScenario(renamedTo)) {
      await selectScenario(renamedTo);
      return;
    }
    if (selected != null && !_hasScenario(selected)) {
      await selectScenario(null);
      return;
    }
    notifyListeners();
  }

  bool _hasScenario(String name) =>
      scenarios.any((scenario) => scenario.name == name);

  /// Select a scenario — its directive text goes straight to the engine
  /// and applies from the next rectify on, rerolls included; null returns
  /// to the default register. Every picker (session chip, tray submenu,
  /// later the quick panel) shares this entry. The UI adopts the pick at
  /// once; a failed engine call surfaces on the error banner instead of
  /// vanishing.
  Future<void> selectScenario(String? name) async {
    selectedScenario = name;
    notifyListeners();
    try {
      // The name rides beside its directive (a pass-through the store
      // resolves when the session is recorded).
      await gateway.setStyleDirective(_directiveOf(name), scenario: name);
    } catch (e) {
      logRawError('err_scenario_switch', e);
      _setLastError('切换失败');
      notifyListeners();
    }
  }

  /// The selected scenario's directive text; a name with no matching
  /// entry (a vanished scenario) reads as the default register.
  String? _directiveOf(String? name) {
    if (name == null) return null;
    for (final scenario in scenarios) {
      if (scenario.name == name) return scenario.directive;
    }
    return null;
  }

  // ---- the global directive (ticket 22) -----------------------------------

  /// Load the global directive at startup: paint the preview card and
  /// push the text at the engine, so every rectify runs with it. A
  /// failed read degrades to unset — like the scenario library, the
  /// directive is decorative state that must never block startup.
  Future<void> loadGlobalDirective() async {
    try {
      globalDirective = await gateway.globalDirective();
    } catch (_) {
      globalDirective = null;
    }
    try {
      await gateway.setGlobalDirective(globalDirective);
    } catch (_) {
      // The engine push failing at startup (engine refused to assemble)
      // surfaces through the startup error path already.
    }
    notifyListeners();
  }

  /// The global directive's file changed (the settings window's save):
  /// re-read the file — it is the truth — adopt the new text, and push it
  /// at the engine. The engine's live read makes the very next attempt
  /// (rerolls of an open session included) run with the new value; this
  /// controller's copy only repaints the quick panel's preview card.
  Future<void> onGlobalDirectiveChanged() async {
    String? fresh;
    try {
      fresh = await gateway.globalDirective();
    } catch (_) {
      return; // unreadable right now: keep painting what we had
    }
    globalDirective = fresh;
    notifyListeners();
    try {
      await gateway.setGlobalDirective(fresh);
    } catch (e) {
      logRawError('err_directive_update', e);
      _setLastError('全局指令未更新');
      notifyListeners();
    }
  }

  /// The hotword dictionary as it stands (file order) — the quick
  /// panel's term chips. The file is the single source: after every
  /// quick-add or removal the list re-reads it, so the chips and the
  /// next session's recognition bias can never disagree.
  List<String> terms = const [];

  Future<void> loadTerms() async {
    try {
      terms = await gateway.termsList();
    } catch (_) {
      terms = const []; // decorative: never block the panel on it
    }
    notifyListeners();
  }

  /// Quick-add one term (trimmed; blank is a no-op — the panel's add
  /// affordance is disabled for blank input anyway).
  Future<void> addQuickTerm(String term) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty) return;
    try {
      await gateway.appendTerm(trimmed);
      await loadTerms();
    } catch (e) {
      logRawError('err_term_add', e);
      _setLastError('添加失败');
      notifyListeners();
    }
  }

  /// Remove a term's line from the dictionary file.
  Future<void> removeQuickTerm(String term) async {
    try {
      await gateway.removeTerm(term);
      await loadTerms();
    } catch (e) {
      logRawError('err_term_remove', e);
      _setLastError('删除失败');
      notifyListeners();
    }
  }

  /// The most recent stored sessions, newest first — the quick panel's
  /// history rows. Full browsing and management live in the settings
  /// window (ticket 18); the tray keeps its one-click clear.
  List<BridgeHistoryEntry> recentHistory = const [];

  /// How many history rows the quick panel lists.
  static const recentHistoryCount = 3;

  Future<void> loadRecentHistory() async {
    try {
      final all = await gateway.historyList();
      recentHistory = all.take(recentHistoryCount).toList();
    } catch (_) {
      recentHistory = const [];
    }
    notifyListeners();
  }

  /// History retrieval: re-run a past utterance through rectification
  /// (the 指定场景重新修正 key). The session window takes over from the
  /// panel; reroll, edit, and insert all work as after a recording.
  /// [style] pins this session's style pick (一次性): the engine keeps
  /// it through rerolls, the selection stays untouched, and
  /// [oneTimeStyle] feeds the session chip until the session ends. The
  /// built-in 默认 pick always resolves — the session runs under the
  /// default register whatever is selected; a named pick whose entry no
  /// longer resolves (the library changed between the two windows)
  /// reads as no pin — the session runs under the live selection.
  Future<void> rerectifyHistory(
    String rawTranscript, {
    required ScenarioPick style,
    PlatformInt64? sourceSessionId,
  }) async {
    final BridgeSessionStyle bridgeStyle;
    ScenarioPick? chipPick = style;
    switch (style) {
      case DefaultRegisterPick():
        bridgeStyle = BridgeSessionStyle.defaultRegister();
      case NamedScenarioPick(:final name):
        final directive = _directiveOf(name);
        if (directive == null) {
          bridgeStyle = BridgeSessionStyle.live();
        } else {
          // The pin carries the scenario's name beside its directive,
          // so the recorded session names the scenario it ran under.
          bridgeStyle = BridgeSessionStyle.directive(
            text: directive,
            scenario: name,
          );
        }
        chipPick = directive == null ? null : NamedScenarioPick(name);
    }
    oneTimeStyle = chipPick;
    try {
      await gateway.rectifyText(
        rawTranscript,
        style: bridgeStyle,
        sourceSessionId: sourceSessionId,
      );
    } catch (e) {
      oneTimeStyle = null;
      logRawError('err_reroll', e);
      _setLastError('重新修正失败');
      notifyListeners();
    }
  }

  /// Pick a theme segment (浅色/深色/跟随系统): the surfaces repaint at
  /// once — the app root listens to this controller — and the selection
  /// persists to the app-owned `spokenrectifier-ui.toml`, closing the
  /// read/write loop. A failed write surfaces on the error banner but
  /// keeps the on-screen mode: the user sees what they got.
  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    try {
      saveUiThemeMode(uiPrefsDirs, mode);
    } catch (e) {
      logRawError('err_theme_save', e);
      _setLastError('保存失败');
      notifyListeners();
    }
  }

  // ---- geometry persistence (ticket 20) ----------------------------------

  /// Trailing ui.toml write for in-flight gestures: a drag killed
  /// mid-flight loses at most one window (随拖动实时持久化).
  Timer? _geometrySave;

  /// A live gesture update (pointer still down): remember the geometry
  /// and schedule the debounced save. No notify — nothing paints from
  /// these values; the window moves through the OS, not the tree.
  void noteGeometryLive({Offset? anchor, Size? panel}) {
    if (anchor != null) orbAnchor = anchor;
    if (panel != null) panelFootprint = panel;
    _geometrySave?.cancel();
    _geometrySave = Timer(const Duration(milliseconds: 300), _saveGeometry);
  }

  /// Gesture end: persist at once (松手即写).
  void noteGeometryDone({Offset? anchor, Size? panel}) {
    if (anchor != null) orbAnchor = anchor;
    if (panel != null) panelFootprint = panel;
    _geometrySave?.cancel();
    _saveGeometry();
  }

  /// Teardown backstop: a live gesture killed inside the debounce
  /// window still persists its last known geometry.
  void flushGeometry() {
    final pending = _geometrySave?.isActive ?? false;
    _geometrySave?.cancel();
    if (pending) _saveGeometry();
  }

  void _saveGeometry() {
    try {
      saveUiGeometry(
        uiPrefsDirs,
        orbPosition: orbAnchor,
        panelSize: panelFootprint,
      );
    } catch (e) {
      logRawError('err_ui_prefs_save', e);
      _setLastError('窗口位置未能保存');
      notifyListeners();
    }
  }

  /// Open the shared config file in the system editor — the tray's
  /// settings entry. A first run creates a commented stub to open; a
  /// failed spawn (nothing to open with, unwritable stub location)
  /// surfaces on the error banner.
  Future<void> openConfigFile() async {
    try {
      await gateway.openConfigFile();
    } catch (e) {
      logRawError('err_config_open', e);
      _setLastError('打开失败');
      notifyListeners();
    }
  }

  /// Show or hide the floating orb — the one entry the tray checkbox,
  /// the tray click and the settings window's switch share. The toggle
  /// paints at once and persists to ui.toml (the read/write loop); a
  /// failed write surfaces on the error banner but keeps the on-screen
  /// state, exactly like the theme: the user sees what they got.
  Future<void> setOrbVisible(bool visible) async {
    orbVisible = visible;
    notifyListeners();
    try {
      saveUiOrbVisible(uiPrefsDirs, visible);
    } catch (e) {
      logRawError('err_orb_visibility_save', e);
      _setLastError('保存失败');
      notifyListeners();
    }
  }

  /// One-click clear (tray menu): wipe every stored session. The
  /// browsing surface for history lives in the quick panel and the
  /// settings window (ticket 18); the tray keeps only this.
  Future<void> clearHistory() async {
    await gateway.historyClear();
    recentHistory = const [];
    notifyListeners();
  }

  void _startScriptedSpeech() {
    _stopScriptedSpeech();
    if (scriptedPhrases.isEmpty) {
      return; // nothing scripted to say (tests, or a real ASR future)
    }
    _nextPhrase = 0;
    _tick = 0;
    _speechTimer = Timer.periodic(speechInterval, (_) => _speakNext());
    // Speak the first phrase immediately so the orb shows life at once.
    _speakNext();
  }

  void _stopScriptedSpeech() {
    _speechTimer?.cancel();
    _speechTimer = null;
  }

  Future<void> _speakNext() async {
    if (scriptedPhrases.isEmpty) {
      return;
    }
    if (_nextPhrase >= scriptedPhrases.length) {
      // Keep "talking" by cycling, like a long-winded user.
      _nextPhrase = 0;
    }
    await gateway.fakeSay(scriptedPhrases[_nextPhrase]);
    _nextPhrase += 1;
    _tick += 1;
    // Every third phrase gets a paragraph-marking pause.
    if (_tick % 3 == 0) {
      await gateway.fakeSilence(1300);
    }
  }

  /// Non-size recording dynamics: a fast tick breathing the level ring
  /// and glow (voice steps set `speaking` on bursts). The engine reports
  /// only a speaking boolean, so the loudness curve is synthesized.
  void _startMicBreath() {
    _stopMicBreath();
    micLevel = 0.08;
    _micBreathTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final target = speaking ? 0.35 + _rand.nextDouble() * 0.6 : 0.06;
      micLevel += (target - micLevel) * 0.35;
      notifyListeners();
    });
  }

  void _stopMicBreath() {
    _micBreathTimer?.cancel();
    _micBreathTimer = null;
    micLevel = 0;
  }

  /// The header's 思考中 elapsed label needs repaints while the
  /// marquee's own ticker (inside the panel) drives the bands. Light
  /// 500 ms cadence — the label shows m:ss.
  void _startThinkingTick() {
    _stopThinkingTick();
    _thinkingTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => notifyListeners(),
    );
  }

  void _stopThinkingTick() {
    _thinkingTimer?.cancel();
    _thinkingTimer = null;
  }

  /// Show the receipt flash on the ball for the token feedback span,
  /// even though the engine has already continued to idle.
  void _flash(OrbFlash kind) {
    orbFlash = kind;
    _flashTimer?.cancel();
    _flashTimer = Timer(SrMotion.feedback, () {
      orbFlash = OrbFlash.none;
      notifyListeners();
    });
  }

  static final _rand = Random(7);

  void _onEnvelope(BridgeEventEnvelope envelope) {
    switch (envelope.event) {
      case BridgeEvent_SessionStateChanged(:final from, :final to):
        phase = to;
        if (to == BridgeSessionState.recording) {
          liveText = '';
          paragraphMarks = 0;
          speaking = false;
          recordStartedAt = DateTime.now();
          _logSessionPerf('perf_session_recording');
          _startMicBreath();
          // A leftover true would skip this session's pin arm; the
          // previous Recording→* already cleared it, this is the belt.
          quickMarked = false;
          unawaited(_armPinHotkey());
        } else {
          recordStartedAt = null;
          // A session that never reached a transcript retires the
          // observation window with it; the next start arms a fresh one.
          _perfSessionStart = null;
          _stopMicBreath();
          // Listening ended by any path — stop session or cancel alike:
          // the chord goes back to the system at once (its Alt+B roles
          // elsewhere — bookmark menus, undo — stay ours-free at idle).
          if (from == BridgeSessionState.recording) {
            unawaited(_disarmPinHotkey());
            _hotkeyHoldActive = false;
            _holdArmed = false;
            quickMarked = false;
          }
        }
        // An active session takes over from the quick panel — recording
        // (hotkey/orb) and rectifying alike: the history re-rectify path
        // enters through rectifying directly, and a panel left flagged
        // open would resurrect when that session ends.
        final sessionActive =
            to == BridgeSessionState.recording ||
            to == BridgeSessionState.rectifying ||
            to == BridgeSessionState.preview;
        if (sessionActive) {
          quickOpen = false;
        }
        if (to == BridgeSessionState.inserted) _flash(OrbFlash.inserted);
        if (to == BridgeSessionState.cancelled) _flash(OrbFlash.cancelled);
        // The one-time style pick dies with its session (inserted and
        // cancelled are the transient terminals every session passes
        // through): the next rectify runs under the live selection.
        if (to == BridgeSessionState.inserted ||
            to == BridgeSessionState.cancelled) {
          oneTimeStyle = null;
        }
        if (to != BridgeSessionState.preview) {
          // [previewText] lives only mid-flight: entering rectifying starts
          // a fresh attempt (chunks accumulate from scratch), and the other
          // states hold nothing. A pending edit push dies with the text it
          // belonged to — stale edits never reach the engine.
          _previewPushDebounce?.cancel();
          _previewPushDebounce = null;
          previewText = '';
          // The prefill table dies with the round it belonged to; a reroll
          // delivers the fresh table ahead of the preview state change.
          prefillTable = const [];
          // So does the slot table — the panel republishes it off the
          // fresh document when the round's preview lands.
          placeholderFills = const [];
        }
        // The marquee machine lives exactly one rectify attempt (14 号票):
        // a fresh machine on entering rectifying (reroll included), gone
        // with the attempt otherwise — a cancelled mid-thinking attempt
        // leaves no trace.
        if (to == BridgeSessionState.rectifying) {
          thinking = ThinkingMarquee();
        } else {
          thinking = null;
          _stopThinkingTick();
        }
      case BridgeEvent_LiveTranscriptUpdated(:final text):
        liveText = text;
        // The network leg's landing moment (07 号票): the first transcript
        // proves the microphone open and provider handshake completed.
        if (_perfSessionStart != null) {
          _logSessionPerf('perf_session_first_text');
          _perfSessionStart = null;
        }
      case BridgeEvent_ParagraphMarked():
        paragraphMarks += 1;
      case BridgeEvent_QuickMarked():
        // Upgrade stays in Recording: the header word flips to 「快速」
        // and the pin chord goes back to the system (engine also
        // refuses PinPlaceholder; this is the shell-side belt).
        quickMarked = true;
        unawaited(_disarmPinHotkey());
      case BridgeEvent_SpeechActivityChanged(:final speaking):
        this.speaking = speaking;
      case BridgeEvent_RectifyThinkingDelta(:final delta):
        // The 「正在思考」 signal itself (ADR-0019 item 6): feeds the
        // one-shot marquee. The first token also starts the header's
        // elapsed cadence.
        final started = thinking?.pushText(delta) ?? false;
        if (started) _startThinkingTick();
      case BridgeEvent_RectifiedTextChunk(:final delta):
        // The one-way handover latch: the body's first delta retires
        // the 思考中 three-piece (the marquee's own ticker finishes its
        // 180 ms fade); later thinking text still feeds the machine but
        // never relights it.
        thinking?.handOver();
        _stopThinkingTick();
        previewText += delta;
      case BridgeEvent_PreviewPrefills(:final prefills):
        // The round's table lands ahead of the Preview state change, so
        // the preview it enters with is already complete (ticket 18).
        prefillTable = prefills;
      case BridgeEvent_PreviewTextUpdated():
        // Echo of the controller's own push: previewText already holds the
        // value, so this drives nothing (idempotent no-op).
        break;
      case BridgeEvent_TextInserted():
        break; // the inserted state change carries the receipt flash
      case BridgeEvent_Error(:final message):
        logRawError('err_bridge', message);
        _setLastError(classifyEngineError(message));
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _stopScriptedSpeech();
    _stopMicBreath();
    _flashTimer?.cancel();
    _thinkingTimer?.cancel();
    _previewPushDebounce?.cancel();
    _geometrySave?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
