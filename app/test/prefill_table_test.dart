/// The prefill table's app-state mirror (ticket 18): the rows the engine
/// delivers between the last rectified chunk and the Preview state change
/// land with the preview, and die with the round they belonged to.

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/rust/api.dart';

import 'fake_gateway.dart';

void main() {
  test('the table lands with the preview and dies with the round', () async {
    final gateway = FakeGateway();
    final controller = SpeechController(
      gateway: gateway,
      scriptedPhrases: const [],
      uiPrefsDirs: const [],
    );
    addTearDown(controller.dispose);

    // A pin session rides to rectifying; the engine's event order for a
    // block response is chunks, then the table, then the Preview change.
    await gateway.startSession();
    await gateway.pinPlaceholder();
    await gateway.stopSession();
    gateway.emit(const BridgeEvent.rectifiedTextChunk(delta: '发给‡1‡'));
    gateway.emit(
      const BridgeEvent.previewPrefills(prefills: [
        BridgePrefillRow(number: 1, value: '张三'),
        BridgePrefillRow(number: 2, value: ''),
      ]),
    );
    gateway.emit(
      const BridgeEvent.sessionStateChanged(
        from: BridgeSessionState.rectifying,
        to: BridgeSessionState.preview,
      ),
    );
    await pumpEventQueue();

    expect(controller.previewText, '发给‡1‡');
    expect(
      controller.prefillTable,
      const [
        BridgePrefillRow(number: 1, value: '张三'),
        BridgePrefillRow(number: 2, value: ''),
      ],
    );

    // The reroll opens a fresh round: the old table must not survive
    // into it (the engine re-delivers before preview returns).
    await gateway.reroll();
    await pumpEventQueue();
    expect(controller.prefillTable, isEmpty);
    expect(controller.previewText, isEmpty);

    // And the session's end leaves nothing behind either.
    gateway.emit(
      const BridgeEvent.rectifiedTextChunk(delta: '发给‡1‡'),
    );
    gateway.emit(
      const BridgeEvent.previewPrefills(prefills: [
        BridgePrefillRow(number: 1, value: '李四'),
      ]),
    );
    gateway.emit(
      const BridgeEvent.sessionStateChanged(
        from: BridgeSessionState.rectifying,
        to: BridgeSessionState.preview,
      ),
    );
    await pumpEventQueue();
    expect(
      controller.prefillTable,
      const [BridgePrefillRow(number: 1, value: '李四')],
    );
    await gateway.cancelSession();
    await pumpEventQueue();
    expect(controller.prefillTable, isEmpty);
  });
}
