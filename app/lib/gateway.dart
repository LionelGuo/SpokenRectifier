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
  Future<void> pinPlaceholder() =>
      rust.execute(command: rust.BridgeCommand.pinPlaceholder());

  @override
  Future<void> rectifyText(
    String rawTranscript, {
    required rust.BridgeSessionStyle style,
  }) => rust.execute(
    command: rust.BridgeCommand.rectifyText(
      rawTranscript: rawTranscript,
      style: style,
    ),
  );

  @override
  Future<List<rust.BridgeScenario>> scenarios() => rust.scenarios();

  @override
  Future<void> setStyleDirective(String? directive) => rust.execute(
    command: rust.BridgeCommand.setStyleDirective(directive: directive),
  );

  @override
  Future<String?> globalDirective() => rust.globalDirective();

  @override
  Future<void> setGlobalDirective(String? directive) => rust.execute(
    command: rust.BridgeCommand.setGlobalDirective(directive: directive),
  );

  @override
  Future<bool> passageMode() => rust.passageMode();

  @override
  Future<void> setPassageMode(bool on) =>
      rust.execute(command: rust.BridgeCommand.setPassageMode(on_: on));

  @override
  Future<List<String>> termsList() => rust.termsList();

  @override
  Future<void> appendTerm(String term) => rust.appendTerm(term: term);

  @override
  Future<void> removeTerm(String term) => rust.removeTerm(term: term);

  @override
  Future<void> restoreFocus() => rust.restoreFocus();

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

  @override
  Future<bool> watchHold(
    List<int> vks, {
    required bool stopOnEarlyRelease,
  }) => rust.watchHold(vks: vks, stopOnEarlyRelease: stopOnEarlyRelease);

  @override
  Future<bool> isHolding() => rust.isHolding();
}
