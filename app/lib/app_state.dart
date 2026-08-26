/// App state: the speech controller mirrors engine events into UI state
/// and drives the fake speech while recording.
///
/// The engine access is behind [SpeechEngineGateway] so widget tests run
/// with a pure-Dart fake — no Rust dylib needed.

library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'src/rust/api.dart';

/// Everything the controller needs from the engine bridge.
abstract class SpeechEngineGateway {
  Future<void> startSession();
  Future<void> stopSession();
  Future<void> cancelSession();
  Future<void> confirmInsert();
  Future<void> reroll();
  Future<void> updatePreviewText(String text);
  Future<void> rectifyText(String rawTranscript);
  Future<List<BridgeHistoryEntry>> historyList();
  Future<void> historyClear();
  Future<void> fakeBeginSession();
  Future<void> fakeSay(String text);
  Future<void> fakeSilence(int elapsedMs);
  Stream<BridgeEventEnvelope> events();
}

/// Mirrors the engine's event stream into UI state and drives the scripted
/// speech while recording. The Rust-backed gateway lives in `gateway.dart`.
class SpeechController extends ChangeNotifier {
  SpeechController({
    required this.gateway,
    this.scriptedPhrases = const [],
    this.speechInterval = const Duration(milliseconds: 900),
  }) {
    // onError: a subscribe against a not-yet-created engine emits a stream
    // error; the command paths surface the same failure with better
    // wording, so swallow it here instead of leaving it unhandled.
    _subscription = gateway.events().listen(_onEnvelope, onError: (Object _) {});
  }

  final SpeechEngineGateway gateway;
  final List<String> scriptedPhrases;
  final Duration speechInterval;

  StreamSubscription<BridgeEventEnvelope>? _subscription;
  Timer? _speechTimer;
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

  /// The rectified text as the user sees it — the single source the
  /// preview card renders and every confirm path inserts. While rectifying
  /// it accumulates the streamed chunks; while previewing it holds the
  /// user's edits (adopted the instant they happen); everywhere else it is
  /// empty. Confirm what you see.
  String previewText = '';

  /// Debounce for pushing preview edits to the engine: edits are adopted
  /// into [previewText] at once, only the engine push waits.
  Timer? _previewPushDebounce;

  static const _previewPushDelay = Duration(milliseconds: 350);

  /// Whether the floating orb is visible at all.
  bool orbVisible = true;

  /// Whether the recording panel is expanded over the orb.
  bool panelExpanded = false;

  /// Stored sessions from the engine's history (newest first), loaded
  /// whenever the history panel opens.
  List<BridgeHistoryEntry> history = const [];

  /// Whether the history panel is open over the idle orb.
  bool historyOpen = false;

  /// Flash of the last inserted text, cleared on the next interaction.
  String? lastInserted;

  /// Last engine error, shown until the next session.
  String? lastError;

  bool get isRecording => phase == BridgeSessionState.recording;

  /// Hotkey behavior: idle starts recording; recording stops into preview;
  /// preview confirms what is on screen; the transient terminal states are
  /// ignored.
  Future<void> toggleSession() async {
    switch (phase) {
      case BridgeSessionState.idle:
        await startSession();
      case BridgeSessionState.recording:
        await stopSession();
      case BridgeSessionState.preview:
        await confirmWhatYouSee();
      case BridgeSessionState.rectifying ||
          BridgeSessionState.inserted ||
          BridgeSessionState.cancelled:
        break;
    }
  }

  Future<void> startSession() async {
    lastError = null;
    lastInserted = null;
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

  void setOrbVisible(bool visible) {
    orbVisible = visible;
    notifyListeners();
  }

  void togglePanel() {
    panelExpanded = !panelExpanded;
    notifyListeners();
  }

  /// Open (or close) the history panel; opening loads the stored
  /// sessions from the engine's history.
  Future<void> toggleHistory() async {
    historyOpen = !historyOpen;
    if (historyOpen) {
      history = await gateway.historyList();
    }
    notifyListeners();
  }

  /// One-click clear (tray menu or the panel's button): wipe every
  /// stored session and refresh the panel.
  Future<void> clearHistory() async {
    await gateway.historyClear();
    history = const [];
    notifyListeners();
  }

  /// Retrieve a historical utterance by re-running it through
  /// rectification: the panel gives way to the normal
  /// rectifying → preview flow, which inserts as usual on confirm.
  Future<void> rectifyFromHistory(String rawTranscript) async {
    historyOpen = false;
    notifyListeners();
    await gateway.rectifyText(rawTranscript);
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

  void _onEnvelope(BridgeEventEnvelope envelope) {
    switch (envelope.event) {
      case BridgeEvent_SessionStateChanged(:final to):
        phase = to;
        if (to == BridgeSessionState.recording) {
          liveText = '';
          paragraphMarks = 0;
          speaking = false;
          // A new session takes over from the history panel.
          historyOpen = false;
        } else if (to == BridgeSessionState.idle) {
          _stopScriptedSpeech();
          panelExpanded = false;
        }
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
      case BridgeEvent_TextInserted(:final text):
        lastInserted = text;
      case BridgeEvent_Error(:final message):
        lastError = message;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _stopScriptedSpeech();
    _previewPushDebounce?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
