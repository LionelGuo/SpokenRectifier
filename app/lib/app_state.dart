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
    _subscription = gateway.events().listen(_onEnvelope);
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

  /// The rectified text being previewed: streamed chunks, then user edits.
  String previewText = '';

  /// Chunks of the current rectify attempt (streamed output).
  String _chunkTail = '';

  /// Whether the floating orb is visible at all.
  bool orbVisible = true;

  /// Whether the recording panel is expanded over the orb.
  bool panelExpanded = false;

  /// Flash of the last inserted text, cleared on the next interaction.
  String? lastInserted;

  /// Last engine error, shown until the next session.
  String? lastError;

  bool get isRecording => phase == BridgeSessionState.recording;

  /// Hotkey behavior: idle starts recording; recording stops into preview;
  /// preview confirms; the transient terminal states are ignored.
  Future<void> toggleSession() async {
    switch (phase) {
      case BridgeSessionState.idle:
        await startSession();
      case BridgeSessionState.recording:
        await stopSession();
      case BridgeSessionState.preview:
        await confirmInsert();
      case BridgeSessionState.rectifying ||
          BridgeSessionState.inserted ||
          BridgeSessionState.cancelled:
        break;
    }
  }

  Future<void> startSession() async {
    lastError = null;
    lastInserted = null;
    await gateway.fakeBeginSession();
    await gateway.startSession();
    _startScriptedSpeech();
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

  Future<void> confirmInsert() => gateway.confirmInsert();

  Future<void> reroll() => gateway.reroll();

  Future<void> updatePreviewText(String text) =>
      gateway.updatePreviewText(text);

  void setOrbVisible(bool visible) {
    orbVisible = visible;
    notifyListeners();
  }

  void togglePanel() {
    panelExpanded = !panelExpanded;
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

  void _onEnvelope(BridgeEventEnvelope envelope) {
    switch (envelope.event) {
      case BridgeEvent_SessionStateChanged(:final to):
        phase = to;
        if (to == BridgeSessionState.recording) {
          liveText = '';
          paragraphMarks = 0;
          previewText = '';
          _chunkTail = '';
        } else if (to == BridgeSessionState.idle) {
          _stopScriptedSpeech();
          panelExpanded = false;
        }
      case BridgeEvent_LiveTranscriptUpdated(:final text):
        liveText = text;
      case BridgeEvent_ParagraphMarked():
        paragraphMarks += 1;
      case BridgeEvent_RectifiedTextChunk(:final delta):
        _chunkTail += delta;
        previewText = _chunkTail;
      case BridgeEvent_PreviewTextUpdated(:final text):
        previewText = text;
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
    _subscription?.cancel();
    super.dispose();
  }
}
