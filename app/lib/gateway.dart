/// The Rust-backed gateway: thin wrappers over the generated
/// flutter_rust_bridge bindings. Requires `RustLib.init()` and
/// `createFakeEngine` to have run first (see main.dart).

library;

import 'src/rust/api.dart' as rust;

import 'app_state.dart';

class RustSpeechEngineGateway implements SpeechEngineGateway {
  @override
  Future<void> startSession() =>
      rust.execute(command: rust.BridgeCommand.startSession());

  @override
  Future<void> stopSession() =>
      rust.execute(command: rust.BridgeCommand.stopSession());

  @override
  Future<void> cancelSession() =>
      rust.execute(command: rust.BridgeCommand.cancel());

  @override
  Future<void> confirmInsert() =>
      rust.execute(command: rust.BridgeCommand.confirmInsert());

  @override
  Future<void> reroll() => rust.execute(command: rust.BridgeCommand.reroll());

  @override
  Future<void> updatePreviewText(String text) =>
      rust.execute(command: rust.BridgeCommand.updatePreviewText(text: text));

  @override
  Future<void> rectifyText(String rawTranscript) => rust.execute(
        command: rust.BridgeCommand.rectifyText(rawTranscript: rawTranscript),
      );

  @override
  Future<rust.BridgeStyle> style() => rust.style();

  @override
  Future<void> setStyle(rust.BridgeStyle style) =>
      rust.execute(command: rust.BridgeCommand.setStyle(style: style));

  @override
  Future<void> openConfigFile() => rust.openConfigFile();

  @override
  Future<List<rust.BridgeHistoryEntry>> historyList() => rust.historyList();

  @override
  Future<void> historyClear() => rust.historyClear();

  @override
  Future<void> fakeBeginSession() => rust.fakeBeginSession();

  @override
  Future<void> fakeSay(String text) => rust.fakeSay(text: text);

  @override
  Future<void> fakeSilence(int elapsedMs) =>
      rust.fakeSilence(elapsedMs: BigInt.from(elapsedMs));

  @override
  Stream<rust.BridgeEventEnvelope> events() => rust.subscribe();
}
