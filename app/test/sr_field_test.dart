/// Ticket 27: every remaining input box folds into [SrField] — overlay
/// fill, hairline, control radius; single-line 34 high, multiline
/// growing. The chrome lives on the container so the TextField stays
/// undecorated (the same recipe the connection pane already used).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/src/design/controls.dart';
import 'package:spokenrectifier_app/src/design/theme.dart' show srTheme;
import 'package:spokenrectifier_app/src/design/tokens.dart';

Widget host({required Widget child}) => MaterialApp(
  theme: srTheme(Brightness.dark),
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(16), child: child),
  ),
);

BoxDecoration boxOf(WidgetTester tester, Finder field) {
  final container = tester.widget<Container>(
    find.descendant(
      of: field,
      matching: find.byWidgetPredicate(
        (widget) => widget is Container && widget.decoration is BoxDecoration,
      ),
    ),
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  testWidgets('SrField paints overlay fill, hairline and control radius', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        child: SrField(
          key: const Key('field'),
          controller: controller,
          hint: 'hint',
        ),
      ),
    );

    final deco = boxOf(tester, find.byKey(const Key('field')));
    expect(deco.color, SrPalette.dark.surfaceOverlay);
    expect(deco.borderRadius, BorderRadius.circular(SrRadius.control));
    expect((deco.border as Border).top.color, SrPalette.dark.hairline);

    final box = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const Key('field')),
        matching: find.byWidgetPredicate(
          (widget) => widget is Container && widget.decoration is BoxDecoration,
        ),
      ),
    );
    expect(box.constraints?.maxHeight, 34);
    expect(box.constraints?.minHeight, 34);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration!.border, InputBorder.none);
    expect(field.maxLines, 1);
  });

  testWidgets('a multiline SrField grows instead of pinning 34', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        child: SrField(
          key: const Key('field'),
          controller: controller,
          minLines: 2,
          maxLines: 5,
        ),
      ),
    );

    final box = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const Key('field')),
        matching: find.byWidgetPredicate(
          (widget) => widget is Container && widget.decoration is BoxDecoration,
        ),
      ),
    );
    expect(box.constraints, isNull);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 2);
    expect(field.maxLines, 5);
  });

  testWidgets(
    'autofocus and a label ride the shared box, not a second chrome',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(
          child: SrField(
            key: const Key('field'),
            controller: controller,
            label: '名称',
            autofocus: true,
          ),
        ),
      );

      expect(find.text('名称'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).autofocus,
        isTrue,
      );
      // Still one painted box — the label sits above, never draws its own
      // InputDecorator chrome.
      expect(
        find.descendant(
          of: find.byKey(const Key('field')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Container && widget.decoration is BoxDecoration,
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('a monospace SrField pins a real Windows family (28 号票: '
      "'monospace' is not one — it silently fell back)", (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        child: SrField(
          key: const Key('field'),
          controller: controller,
          monospace: true,
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.style?.fontFamily, SrType.monoFamily);
  });
}
