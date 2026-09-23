/// A pure-Dart engine gateway for widget tests: records commands and
/// simulates the engine's event reactions, no Rust dylib involved.

library;

import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/rust/api/engine.dart';
import 'package:spokenrectifier_app/src/rust/api/history.dart';
import 'package:spokenrectifier_app/src/rust/api/library.dart';

class FakeGateway implements SpeechEngineGateway {
  final commands = <String>[];
  final said = <String>[];

  /// When true, [watchHold] reports a live watch (a host that can
  /// poll — Windows). Default false: widget tests keep today's tap
  /// path, the non-Windows shape.
  bool watchHoldSucceeds = false;

  /// Mirrors the poller's "currently holding" flag after a successful
  /// [watchHold]; tests flip it to simulate a release.
  bool holding = false;

  /// When set, the next startSession throws this (e.g. no microphone).
  Object? failNextStart;

  /// When set, the next `scenarios()` throws this (engine never assembled).
  Object? failNextScenarios;

  /// When set, the next `setStyleDirective` throws this.
  Object? failNextSetStyleDirective;

  /// When set, the next `openConfigFile` throws this.
  Object? failNextOpenConfig;

  /// When set, the next `rectifyText` throws this.
  Object? failNextRectifyText;

  /// Stored sessions, mirroring the engine's history recording: each
  /// confirmInsert appends one entry (raw = the last live transcript, as
  /// the engine records the session's frozen utterance). Tests seed or
  /// inspect this list directly.
  final historyEntries = <BridgeHistoryEntry>[];
  int _nextHistoryId = 1;
  String _liveText = '';

  /// What `rectifyText` streams back as the re-rectified text.
  String rectifyResponse = '重新修正后的文本';

  /// The scenario library `scenarios()` hands back.
  final scenarioLibrary = <BridgeScenario>[];

  /// The scenario name the last `setStyleDirective` carried (the
  /// pass-through the store resolves; recorded separately so the
  /// command log's format stays stable).
  String? lastStyleScenario;

  /// The source row the last `rectifyText` named, if any.
  PlatformInt64? lastSourceSessionId;

  /// The global directive `globalDirective()` hands back (null = unset);
  /// tests mutate it to simulate a file change.
  String? global;

  /// The dictionary `termsList()` hands back; quick-add/remove mutate it
  /// with the same trim/dedup/blank-reject rules as the file-backed one.
  final dictionary = <String>[];

  /// When set, the next `appendTerm` throws this.
  Object? failNextAppendTerm;

  final _events = StreamController<BridgeEventEnvelope>.broadcast();
  int _seq = 0;
  BridgeSessionState _state = BridgeSessionState.idle;

  void emit(BridgeEvent event) {
    // The raw side of every recorded pair is the utterance's transcript.
    if (event case BridgeEvent_LiveTranscriptUpdated(:final text)) {
      _liveText = text;
    }
    _seq += 1;
    _events.add(
      BridgeEventEnvelope(
        seq: BigInt.from(_seq),
        sessionId: BigInt.one,
        atMs: BigInt.from(_seq * 10),
        event: event,
      ),
    );
  }

  void _transition(BridgeSessionState to) {
    emit(BridgeEvent.sessionStateChanged(from: _state, to: to));
    _state = to;
  }

  /// Simulate a streaming rectify result, ending in the preview state.
  void streamRectify(List<String> deltas) {
    for (final delta in deltas) {
      emit(BridgeEvent.rectifiedTextChunk(delta: delta));
    }
    _transition(BridgeSessionState.preview);
  }

  /// Simulate thinking-channel deltas (14 号票) mid-rectify: emitted as
  /// the marquee's feed, no state change — the caller interleaves them
  /// with [streamRectify] chunks to shape the handover.
  void streamThinking(List<String> deltas) {
    for (final delta in deltas) {
      emit(BridgeEvent.rectifyThinkingDelta(delta: delta));
    }
  }

  @override
  Future<void> startSession() async {
    commands.add('startSession');
    if (failNextStart != null) {
      final failure = failNextStart;
      failNextStart = null;
      throw failure!;
    }
    _pins = 0;
    _transition(BridgeSessionState.recording);
  }

  @override
  Future<void> stopSession() async {
    commands.add('stopSession');
    _transition(BridgeSessionState.rectifying);
  }

  @override
  Future<void> cancelSession() async {
    commands.add('cancelSession');
    if (_state != BridgeSessionState.idle) {
      _transition(BridgeSessionState.cancelled);
      _transition(BridgeSessionState.idle);
    }
  }

  /// The slot table the last confirm carried (占位符钉入入库), for
  /// assertions; null before the first confirm.
  List<BridgePlaceholderFill>? lastPlaceholderFills;

  @override
  Future<void> confirmInsert(List<BridgePlaceholderFill> placeholders) async {
    commands.add('confirmInsert');
    lastPlaceholderFills = placeholders;
    emit(BridgeEvent.textInserted(text: '插入的文本'));
    // The engine records the finished session into its history store.
    historyEntries.add(
      BridgeHistoryEntry(
        id: _nextHistoryId++,
        createdAtMs: BigInt.from(_seq * 10),
        rawTranscript: _liveText,
        rectifiedText: '插入的文本',
      ),
    );
    _transition(BridgeSessionState.inserted);
    _transition(BridgeSessionState.idle);
  }

  @override
  Future<void> reroll() async {
    commands.add('reroll');
    _transition(BridgeSessionState.rectifying);
  }

  @override
  Future<void> updatePreviewText(String text) async {
    commands.add('updatePreviewText:$text');
    emit(BridgeEvent.previewTextUpdated(text: text));
  }

  /// Sentinels minted so far this recording (the engine's per-session
  /// counter, mirrored for the pin path).
  int _pins = 0;

  @override
  Future<void> pinPlaceholder() async {
    commands.add('pinPlaceholder');
    // The engine rejects a pin outside recording with no state change.
    if (_state != BridgeSessionState.recording) {
      throw StateError('rejected: pinPlaceholder outside recording');
    }
    _pins += 1;
    emit(BridgeEvent.liveTranscriptUpdated(text: '$_liveText‡$_pins‡'));
  }

  @override
  Future<void> rectifyText(
    String rawTranscript, {
    required BridgeSessionStyle style,
    PlatformInt64? sourceSessionId,
  }) async {
    lastSourceSessionId = sourceSessionId;
    // The one-time pin decorates the recorded command, so tests can
    // tell the retrieval kinds apart (named directive / explicit 默认 /
    // following the live selection).
    final pin = switch (style) {
      BridgeSessionStyle_Live() => '',
      BridgeSessionStyle_Directive(:final text) => '@$text',
      BridgeSessionStyle_DefaultRegister() => '@默认',
    };
    commands.add('rectifyText:$rawTranscript$pin');
    if (failNextRectifyText != null) {
      final failure = failNextRectifyText;
      failNextRectifyText = null;
      throw failure!;
    }
    // Mirror the engine: straight into rectifying, the utterance's
    // transcript published for the preview's raw comparison, then the
    // streamed result ending in preview.
    _transition(BridgeSessionState.rectifying);
    emit(BridgeEvent.liveTranscriptUpdated(text: rawTranscript));
    streamRectify([rectifyResponse]);
  }

  @override
  Future<List<BridgeScenario>> scenarios() async {
    commands.add('scenarios');
    if (failNextScenarios != null) {
      final failure = failNextScenarios;
      failNextScenarios = null;
      throw failure!;
    }
    return List.of(scenarioLibrary);
  }

  @override
  Future<void> setStyleDirective(String? directive, {String? scenario}) async {
    commands.add('setStyleDirective:$directive');
    lastStyleScenario = scenario;
    if (failNextSetStyleDirective != null) {
      final failure = failNextSetStyleDirective;
      failNextSetStyleDirective = null;
      throw failure!;
    }
  }

  @override
  Future<String?> globalDirective() async {
    commands.add('globalDirective');
    return global;
  }

  @override
  Future<void> setGlobalDirective(String? directive) async {
    commands.add('setGlobalDirective:$directive');
  }

  @override
  Future<List<String>> termsList() async {
    commands.add('termsList');
    return List.of(dictionary);
  }

  @override
  Future<void> appendTerm(String term) async {
    commands.add('appendTerm:$term');
    if (failNextAppendTerm != null) {
      final failure = failNextAppendTerm;
      failNextAppendTerm = null;
      throw failure!;
    }
    final trimmed = term.trim();
    if (trimmed.isEmpty) {
      throw StateError('a term may not be blank');
    }
    if (!dictionary.contains(trimmed)) dictionary.add(trimmed);
  }

  @override
  Future<void> removeTerm(String term) async {
    commands.add('removeTerm:$term');
    dictionary.removeWhere((t) => t == term.trim());
  }

  @override
  Future<void> restoreFocus() async {
    commands.add('restoreFocus');
  }

  @override
  Future<void> openConfigFile() async {
    commands.add('openConfigFile');
    if (failNextOpenConfig != null) {
      final failure = failNextOpenConfig;
      failNextOpenConfig = null;
      throw failure!;
    }
  }

  @override
  Future<List<BridgeHistoryEntry>> historyList() async {
    commands.add('historyList');
    return List.of(historyEntries);
  }

  @override
  Future<void> historyClear() async {
    commands.add('historyClear');
    historyEntries.clear();
  }

  @override
  Future<void> fakeBeginSession() async {
    commands.add('fakeBeginSession');
  }

  @override
  Future<void> fakeSay(String text) async {
    said.add(text);
  }

  @override
  Future<void> fakeSilence(int elapsedMs) async {
    commands.add('fakeSilence:$elapsedMs');
  }

  @override
  Stream<BridgeEventEnvelope> events() => _events.stream;

  @override
  Future<bool> watchHold(
    List<int> vks, {
    required bool stopOnEarlyRelease,
  }) async {
    commands.add(
      'watchHold:${stopOnEarlyRelease ? 'stop' : 'open'}:${vks.join(',')}',
    );
    // Mirror the Rust gate: a watch only starts while recording.
    // `watchHoldSucceeds` is the host's ability to poll (Windows), not
    // the master switch — the real gate arms either way.
    if (!watchHoldSucceeds || _state != BridgeSessionState.recording) {
      holding = false;
      return false;
    }
    holding = true;
    return true;
  }

  @override
  Future<bool> isHolding() async => holding;
}
