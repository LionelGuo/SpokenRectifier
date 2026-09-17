/// Widget tests for the shared toast (ui-copy [toast 组件落地]):
/// appears on show, dwells per tone, replaces instead of queueing,
/// dismisses on tap, and passes clicks through to the surface below
/// while nothing is shown. Motion follows the shared enter/exit
/// tokens, so the timing assertions read straight off [SrMotion].

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/src/design/theme.dart' show srTheme;
import 'package:spokenrectifier_app/src/design/toast.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart';

void main() {
  // Fires the toast from below the scope, the way a real pane would.
  late BuildContext below;
  Widget host({SrToastAnchor anchor = SrToastAnchor.bottom}) => MaterialApp(
    theme: srTheme(Brightness.dark),
    home: SrToastScope(
      anchor: anchor,
      clearance: 12,
      child: Builder(
        builder: (context) {
          below = context;
          return const SizedBox.expand();
        },
      ),
    ),
  );

  Future<void> fire(
    WidgetTester tester,
    String message, {
    SrToastTone tone = SrToastTone.success,
  }) async {
    SrToast.of(below).show(message, tone: tone);
    await tester.pump();
  }

  testWidgets('a toast appears and leaves after its dwell', (tester) async {
    await tester.pumpWidget(host());
    await fire(tester, '已保存');
    expect(textOf(tester, const Key('sr-toast')), '已保存');

    // Success dwells 2000ms, then the 150ms exit fades it out and the
    // entry clears with the exit's landing.
    await tester.pump(SrMotion.toastSuccess);
    expect(find.byKey(const Key('sr-toast')), findsOneWidget); // exiting
    await tester.pump(SrMotion.exit);
    expect(find.byKey(const Key('sr-toast')), findsNothing);
  });

  testWidgets('an error lingers longer than a success', (tester) async {
    await tester.pumpWidget(host());
    await fire(tester, '网络异常', tone: SrToastTone.error);

    // Past the success dwell the error is still up...
    await tester.pump(SrMotion.toastSuccess);
    expect(find.byKey(const Key('sr-toast')), findsOneWidget);
    // ...and comes down only after its own 3000ms.
    await tester.pump(SrMotion.toastError - SrMotion.toastSuccess);
    await tester.pump(SrMotion.exit);
    expect(find.byKey(const Key('sr-toast')), findsNothing);
  });

  testWidgets('a new toast replaces the live one and resets its clock', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await fire(tester, '第一条', tone: SrToastTone.error);
    await tester.pump(const Duration(milliseconds: 2500));

    // The replacement lands mid-dwell: newest wins, oldest gone.
    await fire(tester, '第二条');
    expect(textOf(tester, const Key('sr-toast')), '第二条');
    expect(find.text('第一条'), findsNothing);

    // The dwell restarted with the replacement: at the FIRST toast's
    // 3000ms deadline (2500 + 500) the second is still up.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('sr-toast')), findsOneWidget);
    // It leaves on its own clock (a success: 2000ms from its show).
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(SrMotion.exit);
    expect(find.byKey(const Key('sr-toast')), findsNothing);
  });

  testWidgets('a tap dismisses the toast', (tester) async {
    await tester.pumpWidget(host());
    await fire(tester, '网络异常', tone: SrToastTone.error);
    await tester.pump(SrMotion.enter); // settled in, fully opaque

    await tester.tap(find.byKey(const Key('sr-toast')));
    await tester.pump();
    await tester.pump(SrMotion.exit);
    expect(find.byKey(const Key('sr-toast')), findsNothing);
  });

  testWidgets('clicks pass through to the surface while nothing shows', (
    tester,
  ) async {
    var hits = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: srTheme(Brightness.dark),
        home: SrToastScope(
          anchor: SrToastAnchor.bottom,
          clearance: 12,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => hits++,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    // Tap right where the capsule would sit (bottom-center, above the
    // clearance): with no entry the layer must be invisible to hits.
    await tester.tapAt(const Offset(400, 600 - 12 - 16));
    expect(hits, 1);
  });

  testWidgets('the scope hosts both anchors and fires from below', (
    tester,
  ) async {
    for (final anchor in SrToastAnchor.values) {
      await tester.pumpWidget(host(anchor: anchor));
      await fire(tester, '顶部锚点');
      expect(find.byKey(const Key('sr-toast')), findsOneWidget);
    }
  });
}

String textOf(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data!;
