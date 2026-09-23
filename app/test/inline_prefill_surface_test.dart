/// Ticket 29: the inline prefill grammar on the session surface — the
/// rectifying stream renders `‡N:值‡` as the family's full capsule with
/// the value growing live out of the chunks (ruling 26's streaming
/// design), the bare `‡N‡` keeps its number circle, no sentinel chrome
/// ever paints on the main surface (聆听/修正中/预览各阶段、含流式边
/// 界), and the preview's extraction treats the inline form as slot N
/// with its value riding the PreviewPrefills event — never the body
/// text (值事实源=事件).

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/preview/slot_surface.dart';
import 'package:spokenrectifier_app/src/rust/api/engine.dart'
    show BridgeEvent,
        BridgePrefillRow,
        BridgeSessionState;

import 'fake_gateway.dart';
import 'fake_rectify_store.dart';

/// Pumps a pinned session through to rectifying, ready for chunks.
Future<SpeechController> pumpRectifying(
  WidgetTester tester,
  FakeGateway gateway,
) async {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    SpokenRectifierApp(
      controller: controller,
      rectifyStore: FakeRectifyBehaviorStore(),
    ),
  );
  await controller.startSession();
  await tester.pump(const Duration(milliseconds: 350));
  await gateway.pinPlaceholder();
  await tester.pump();
  await controller.stopSession();
  await tester.pump(const Duration(milliseconds: 350));
  expect(controller.phase, BridgeSessionState.rectifying);
  return controller;
}

Future<void> chunk(
  WidgetTester tester,
  FakeGateway gateway,
  String delta,
) async {
  gateway.emit(BridgeEvent.rectifiedTextChunk(delta: delta));
  await tester.pump();
}

void main() {
  testWidgets('the stream grows an inline capsule as the chunks arrive', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpRectifying(tester, gateway);

    // `‡1:` already IS the capsule (解析到 ‡N: 即生成胶囊) — number
    // present, value still empty; the colon never paints.
    await chunk(tester, gateway, '发给‡1:');
    expect(find.byKey(const ValueKey('pin-capsule-1')), findsOneWidget);
    expect(find.textContaining('‡'), findsNothing);
    expect(find.textContaining(':'), findsNothing);

    // The value grows character by character, inside the capsule.
    await chunk(tester, gateway, '张');
    expect(find.textContaining('张'), findsOneWidget);
    await chunk(tester, gateway, '三');
    expect(find.textContaining('张三'), findsOneWidget);

    // The closing mark ends the value; what follows lands after the
    // capsule as body text.
    await chunk(tester, gateway, '‡,收到');
    expect(find.textContaining('张三'), findsOneWidget);
    expect(find.textContaining(',收到'), findsOneWidget);
    expect(find.textContaining('‡'), findsNothing);

    await controller.cancelSession();
    await tester.pump(const Duration(milliseconds: 1200));
  });

  testWidgets('a bare sentinel beside an inline capsule stays a circle', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpRectifying(tester, gateway);

    await chunk(tester, gateway, '发‡2:李四‡给‡1‡收尾');
    expect(find.byKey(const ValueKey('pin-capsule-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-capsule-1')), findsOneWidget);
    expect(find.textContaining('李四'), findsOneWidget);
    expect(find.textContaining('‡'), findsNothing);

    await controller.cancelSession();
    await tester.pump(const Duration(milliseconds: 1200));
  });

  testWidgets(
    'the preview adopts the inline form with the event row as its value',
    (tester) async {
      final gateway = FakeGateway();
      final controller = await pumpRectifying(tester, gateway);

      await chunk(tester, gateway, '发给‡1:正文里的旧值‡一份');
      // The row, not the body text, is the value's fact source (29 号票).
      gateway.emit(
        const BridgeEvent.previewPrefills(
          prefills: [BridgePrefillRow(number: 1, value: '张三')],
        ),
      );
      gateway.emit(
        const BridgeEvent.sessionStateChanged(
          from: BridgeSessionState.rectifying,
          to: BridgeSessionState.preview,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // The editing surface's flat text carries the ROW's value in the
      // capsule and nothing of the inline chrome anywhere.
      final surface = tester.state(
        find.byKey(const Key('session-text')),
      ) as SlotSurfaceState;
      expect(surface.paintedTextForTest, contains('张三'));
      expect(surface.paintedTextForTest.contains('正文里的旧值'), isFalse);
      expect(surface.capsuleIds, [1]);

      // The panel adopted the substituted text: the whole inline form
      // collapsed to the row's value — the confirm path needs no rewrite.
      expect(controller.previewText, '发给张三一份');

      await controller.cancelSession();
      await tester.pump(const Duration(milliseconds: 1200));
    },
  );
}
