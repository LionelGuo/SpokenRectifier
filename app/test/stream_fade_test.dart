/// Ticket 25: the stream face's fading inflow. Each new suffix of the
/// stream text — the ASR's full resends and the rectify chunks alike —
/// fades in as ONE block over `SrMotion.fade` (180ms, `curveFade`):
/// the common prefix keeps its ink, everything from the first differing
/// code unit on re-fades (首异后缀整段,改写段同律淡入), each segment on
/// its own clock, the ticker running only while a segment is still
/// maturing. Machine tests exercise the diff/alpha model directly; the
/// widget guards drive both real paths (recording rewrite, rectify
/// append) through the panel.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/preview/slot_surface.dart'
    show
        SlotSurface,
        SlotSurfaceState,
        StreamFadeSegment,
        advanceStreamFades,
        streamFadeAlpha;
import 'package:spokenrectifier_app/src/rust/api.dart'
    show BridgeEvent, BridgeSessionState;

import 'fake_gateway.dart';
import 'fake_rectify_store.dart';

Future<SpeechController> pumpController(
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
  return controller;
}

Future<void> pumpToRecording(
  WidgetTester tester,
  SpeechController controller,
) async {
  await controller.startSession();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> windDown(WidgetTester tester, SpeechController controller) async {
  if (controller.phase != BridgeSessionState.idle) {
    await controller.cancelSession();
  }
  await tester.pump(const Duration(milliseconds: 1200));
}

SlotSurfaceState surfaceState(WidgetTester tester) =>
    tester.state<SlotSurfaceState>(find.byType(SlotSurface));

/// The stream paragraph's span holding exactly [text], or null — the
/// widget side's fade seam (a fading span carries a style override; a
/// plain one carries none).
TextSpan? spanWithText(WidgetTester tester, String text) {
  // The key marks both the SlotSurface and its Text.rich; widgetList
  // would cast rather than filter, so pick the Text by hand.
  final surface = find
      .byKey(const Key('session-stream'))
      .evaluate()
      .map((element) => element.widget)
      .whereType<Text>()
      .first;
  final stack = <InlineSpan>[surface.textSpan!];
  while (stack.isNotEmpty) {
    final span = stack.removeLast();
    if (span is TextSpan) {
      if (span.text == text) return span;
      stack.addAll(span.children ?? const <InlineSpan>[]);
    }
  }
  return null;
}

double? spanAlpha(WidgetTester tester, String text) =>
    spanWithText(tester, text)?.style?.color?.a;

void main() {
  group('advanceStreamFades (the diff model)', () {
    const t0 = Duration.zero;
    const t40 = Duration(milliseconds: 40);
    const t90 = Duration(milliseconds: 90);

    test('an append fades only the new suffix', () {
      expect(
        advanceStreamFades('你好', '你好世界', const [], t0),
        [const StreamFadeSegment(2, 4, t0)],
      );
    });

    test('a rewrite re-fades the whole tail from the first difference', () {
      expect(
        advanceStreamFades('今天天气', '今天，天气晴', const [], t0),
        [const StreamFadeSegment(2, 6, t0)],
      );
    });

    test('a surviving fade keeps its own clock beside the new segment', () {
      expect(
        advanceStreamFades('abcdefgh', 'abcdefghij', const [
          StreamFadeSegment(2, 5, t40),
        ], t90),
        [const StreamFadeSegment(2, 5, t40), const StreamFadeSegment(8, 10, t90)],
      );
    });

    test('a rewrite cutting into a fading segment truncates it at the diff',
        () {
      expect(
        advanceStreamFades('abcdef', 'abcXYf', const [
          StreamFadeSegment(2, 8, t0),
        ], t0),
        [const StreamFadeSegment(2, 3, t0), const StreamFadeSegment(3, 6, t0)],
      );
    });

    test('a shrink keeps only what survives below the diff', () {
      expect(
        advanceStreamFades('ABCDE', 'ABC', const [
          StreamFadeSegment(0, 5, t0),
        ], t0),
        [const StreamFadeSegment(0, 3, t0)],
      );
    });

    test('a clear fades nothing', () {
      expect(
        advanceStreamFades('ABC', '', const [StreamFadeSegment(0, 3, t0)], t0),
        isEmpty,
      );
    });
  });

  group('streamFadeAlpha (the timing model)', () {
    const segment = StreamFadeSegment(0, 1, Duration.zero);

    test('rides the fade curve over 180ms and clamps', () {
      expect(streamFadeAlpha(segment, Duration.zero), 0.0);
      expect(
        streamFadeAlpha(segment, const Duration(milliseconds: 90)),
        closeTo(0.5, 0.001),
      );
      expect(streamFadeAlpha(segment, const Duration(milliseconds: 180)), 1.0);
      expect(streamFadeAlpha(segment, const Duration(milliseconds: 400)), 1.0);
    });

    test('is anchored at the segment birth', () {
      final late = const StreamFadeSegment(0, 1, Duration(milliseconds: 60));
      expect(streamFadeAlpha(late, const Duration(milliseconds: 60)), 0.0);
      expect(
        streamFadeAlpha(late, const Duration(milliseconds: 150)),
        closeTo(0.5, 0.001),
      );
      expect(streamFadeAlpha(late, const Duration(milliseconds: 240)), 1.0);
    });
  });

  testWidgets('appended rectify chunks fade in and mature', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('修正中'), findsOneWidget);

    gateway.emit(const BridgeEvent.rectifiedTextChunk(delta: '今天天气'));
    await tester.pump();
    // Born this frame: the whole chunk is one segment at alpha 0.
    expect(surfaceState(tester).streamFadesForTest, [
      const StreamFadeSegment(0, 4, Duration.zero),
    ]);
    expect(spanAlpha(tester, '今天天气'), closeTo(0.0, 0.001));

    await tester.pump(const Duration(milliseconds: 90));
    expect(spanAlpha(tester, '今天天气'), closeTo(0.5, 0.01));

    await tester.pump(const Duration(milliseconds: 90));
    // Matured: the clock stops and the span is plain again.
    expect(surfaceState(tester).streamFadesForTest, isEmpty);
    expect(spanWithText(tester, '今天天气')!.style, isNull);

    // The next chunk rides its own fresh clock; the matured text never
    // re-fades.
    gateway.emit(const BridgeEvent.rectifiedTextChunk(delta: '不错'));
    await tester.pump();
    expect(surfaceState(tester).streamFadesForTest, [
      const StreamFadeSegment(4, 6, Duration.zero),
    ]);
    expect(spanWithText(tester, '今天天气')!.style, isNull);
    expect(spanAlpha(tester, '不错'), closeTo(0.0, 0.001));
    await tester.pump(const Duration(milliseconds: 90));
    expect(spanAlpha(tester, '不错'), closeTo(0.5, 0.01));
    expect(spanWithText(tester, '今天天气')!.style, isNull);

    await windDown(tester, controller);
  });

  testWidgets('a recording rewrite re-fades the whole new tail', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);
    await pumpToRecording(tester, controller);

    gateway.emit(const BridgeEvent.liveTranscriptUpdated(text: '今天天气'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // The first burst matured; the clock is stopped.
    expect(surfaceState(tester).streamFadesForTest, isEmpty);

    // The ASR's intermediate result rewrote the tail: everything from
    // the first difference re-fades as one — on a FRESH epoch (the
    // matured burst's stale tick must not read as an old birth).
    gateway.emit(const BridgeEvent.liveTranscriptUpdated(text: '今天，天气晴'));
    await tester.pump();
    expect(surfaceState(tester).streamFadesForTest, [
      const StreamFadeSegment(2, 6, Duration.zero),
    ]);
    expect(spanWithText(tester, '今天')!.style, isNull);
    expect(spanAlpha(tester, '，天气晴'), closeTo(0.0, 0.001));
    await tester.pump(const Duration(milliseconds: 90));
    expect(spanAlpha(tester, '，天气晴'), closeTo(0.5, 0.01));
    await tester.pump(const Duration(milliseconds: 90));
    expect(surfaceState(tester).streamFadesForTest, isEmpty);
    // Matured: the two parts merged back into one plain run.
    expect(spanWithText(tester, '今天，天气晴'), isNotNull);

    await windDown(tester, controller);
  });
}
