/// A pure-Dart engine gateway for widget tests: records commands and
/// simulates the engine's event reactions, no Rust dylib involved.

library;

import 'dart:async';

import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/rust/api.dart';

class FakeGateway implements SpeechEngineGateway {
  final commands = <String>[];
  final said = <String>[];

  /// When set, the next startSession throws this (e.g. no microphone).
  Object? failNextStart;

  final _events = StreamController<BridgeEventEnvelope>.broadcast();
  int _seq = 0;
  BridgeSessionState _state = BridgeSessionState.idle;

  void emit(BridgeEvent event) {
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

  @override
  Future<void> startSession() async {
    commands.add('startSession');
    if (failNextStart != null) {
      final failure = failNextStart;
      failNextStart = null;
      throw failure!;
    }
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

  @override
  Future<void> confirmInsert() async {
    commands.add('confirmInsert');
    emit(BridgeEvent.textInserted(text: '插入的文本'));
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
}
