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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import 'src/design/tokens.dart' show SrMotion;
import 'src/rust/api.dart';
import 'src/shell/session_flow.dart';
import 'ui_prefs.dart';

/// Everything the controller needs from the engine bridge.
abstract class SpeechEngineGateway {
  Future<void> startSession();
  Future<void> stopSession();
  Future<void> cancelSession();
  Future<void> confirmInsert();
  Future<void> reroll();
  Future<void> updatePreviewText(String text);
  Future<void> rectifyText(String rawTranscript);
  Future<List<BridgeScenario>> scenarios();
  Future<void> setStyleDirective(String? directive);
  Future<bool> passageMode();
  Future<void> setPassageMode(bool on);
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
}

/// The 900 ms receipt flash the ball shows after a session ends:
/// green check (inserted) or grey cross (cancelled) before it rests
/// back to idle.
enum OrbFlash { none, inserted, cancelled }

/// Mirrors the engine's event stream into UI state and drives the scripted
/// speech while recording. The Rust-backed gateway lives in `gateway.dart`.
class SpeechController extends ChangeNotifier {
  SpeechController({
    required this.gateway,
    this.scriptedPhrases = const [],
    this.speechInterval = const Duration(milliseconds: 900),
    this.themeMode = ThemeMode.system,
    List<String>? uiPrefsDirs,
  }) : uiPrefsDirs = uiPrefsDirs ?? uiPrefsSearchDirs() {
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

  StreamSubscription<BridgeEventEnvelope>? _subscription;
  Timer? _speechTimer;
  Timer? _micBreathTimer;
  Timer? _flashTimer;
  int _nextPhrase = 0;
  int _tick = 0;

  /// Current session phase, mirrored from state-change events.
  BridgeSessionState phase = BridgeSessionState.idle;

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

  /// Elapsed recording time for the session header.
  Duration get recordElapsed => recordStartedAt == null
      ? Duration.zero
      : DateTime.now().difference(recordStartedAt!);

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

  /// Whether the floating orb is visible at all.
  bool orbVisible = true;

  /// Last engine error, shown in the session panel (and on the orb's
  /// tooltip while idle).
  String? lastError;

  /// The scenario library (场景库), loaded once at startup. Empty when the
  /// library file is missing or blank — every picker hides entirely then.
  List<BridgeScenario> scenarios = const [];

  /// The selected scenario's name; null = the built-in default register.
  /// Never persisted: every launch starts on the default (ADR-0004).
  String? selectedScenario;

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
  Future<void> hotkeyToggle() => dispatchInput(SessionInput.primary);

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

  Future<void> closeQuick() async {
    if (!quickOpen) return;
    quickOpen = false;
    notifyListeners();
    // The panel borrowed the foreground while it was open; hand it back
    // the way a cancelled session does. Self-guarded on the inserter
    // side (a foreign foreground is left alone); a failed restore is
    // not actionable — the user simply clicks where they meant to go.
    unawaited(gateway.restoreFocus().catchError((Object _) {}));
  }

  Future<void> startSession() async {
    lastError = null;
    try {
      // Fake speech needs its session armed first; a microphone-mode engine
      // has no fake feed (scriptedPhrases is empty there).
      if (scriptedPhrases.isNotEmpty) {
        await gateway.fakeBeginSession();
      }
      await gateway.startSession();
      _startScriptedSpeech();
    } catch (e) {
      // e.g. the microphone could not be opened: show it, stay idle.
      lastError = '无法开始录音:$e';
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
  /// user sees, not the last pushed snapshot.
  Future<void> confirmWhatYouSee() async {
    final pushPending = _previewPushDebounce != null;
    _previewPushDebounce?.cancel();
    _previewPushDebounce = null;
    if (phase != BridgeSessionState.preview) return;
    if (pushPending) {
      await gateway.updatePreviewText(previewText);
    }
    await gateway.confirmInsert();
  }

  /// Surface a startup failure (engine assembly refused to run) the same
  /// way session errors surface, keeping the shell alive to show it.
  void reportStartupError(String message) {
    lastError = message;
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
      await gateway.setStyleDirective(_directiveOf(name));
    } catch (e) {
      lastError = '场景切换失败:$e';
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

  // ---- the quick panel's own state ---------------------------------------

  /// Passage mode (篇章模式) as the engine holds it: silence only marks
  /// paragraphs vs. a long silence auto-ends. Seeded from the engine at
  /// startup; a switch applies from the next session on and never
  /// persists (a session-lifetime setting, like the scenario selection).
  bool passageMode = true;

  /// Load the engine's current passage mode for the panel's first paint.
  /// A failed read keeps the built-in default (on).
  Future<void> loadPassageMode() async {
    try {
      passageMode = await gateway.passageMode();
    } catch (_) {
      passageMode = true;
    }
    notifyListeners();
  }

  /// Toggle passage mode: the panel repaints at once, the engine adopts
  /// it for the next session. A failed engine call rolls the paint back
  /// — unlike the theme (app-local state), the toggle mirrors engine
  /// state the next session will actually run with. Not persisted
  /// across launches.
  Future<void> setPassageMode(bool on) async {
    final was = passageMode;
    passageMode = on;
    notifyListeners();
    try {
      await gateway.setPassageMode(on);
    } catch (e) {
      passageMode = was; // the engine never adopted it: paint the truth
      lastError = '篇章模式切换失败:$e';
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
      lastError = '术语添加失败:$e';
      notifyListeners();
    }
  }

  /// Remove a term's line from the dictionary file.
  Future<void> removeQuickTerm(String term) async {
    try {
      await gateway.removeTerm(term);
      await loadTerms();
    } catch (e) {
      lastError = '术语删除失败:$e';
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
  /// (the panel's 重新修正). The session window takes over from the
  /// panel; reroll, edit, and insert all work as after a recording.
  Future<void> rerectifyHistory(String rawTranscript) async {
    try {
      await gateway.rectifyText(rawTranscript);
    } catch (e) {
      lastError = '重新修正失败:$e';
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
      lastError = '主题保存失败:$e';
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
      lastError = '无法打开配置文件:$e';
      notifyListeners();
    }
  }

  void setOrbVisible(bool visible) {
    orbVisible = visible;
    notifyListeners();
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
      case BridgeEvent_SessionStateChanged(:final to):
        phase = to;
        if (to == BridgeSessionState.recording) {
          liveText = '';
          paragraphMarks = 0;
          speaking = false;
          recordStartedAt = DateTime.now();
          _startMicBreath();
        } else {
          recordStartedAt = null;
          _stopMicBreath();
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
        if (to != BridgeSessionState.preview) {
          // [previewText] lives only mid-flight: entering rectifying starts
          // a fresh attempt (chunks accumulate from scratch), and the other
          // states hold nothing. A pending edit push dies with the text it
          // belonged to — stale edits never reach the engine.
          _previewPushDebounce?.cancel();
          _previewPushDebounce = null;
          previewText = '';
        }
      case BridgeEvent_LiveTranscriptUpdated(:final text):
        liveText = text;
      case BridgeEvent_ParagraphMarked():
        paragraphMarks += 1;
      case BridgeEvent_SpeechActivityChanged(:final speaking):
        this.speaking = speaking;
      case BridgeEvent_RectifiedTextChunk(:final delta):
        previewText += delta;
      case BridgeEvent_PreviewTextUpdated():
        // Echo of the controller's own push: previewText already holds the
        // value, so this drives nothing (idempotent no-op).
        break;
      case BridgeEvent_TextInserted():
        break; // the inserted state change carries the receipt flash
      case BridgeEvent_Error(:final message):
        lastError = message;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _stopScriptedSpeech();
    _stopMicBreath();
    _flashTimer?.cancel();
    _previewPushDebounce?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
