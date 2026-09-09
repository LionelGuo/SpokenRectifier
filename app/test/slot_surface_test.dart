/// Ticket 22: the preview editing surface — the fill capsules over the
/// slot document (rendering shape, tap-to-edit with prefill select-all,
/// the dual dock points under the surface's own keys, IME-delivered
/// typing, the single undo stack, the slot hover tooltip, copy of the
/// visible characters, and the substituted text the panel adopts).

library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/design/theme.dart' show srTheme;
import 'package:spokenrectifier_app/src/design/tokens.dart'
    show SrCapsule, SrType;
import 'package:spokenrectifier_app/src/preview/slot_editor.dart';
import 'package:spokenrectifier_app/src/preview/slot_projection.dart';
import 'package:spokenrectifier_app/src/preview/slot_surface.dart';
import 'package:spokenrectifier_app/src/rust/api.dart'
    show BridgeEvent, BridgePrefillRow, BridgeSessionState;

import 'fake_gateway.dart';

class SlotPreviewHarness {
  SlotPreviewHarness(this.tester, this.gateway, this.controller, this.surface);

  final WidgetTester tester;
  final FakeGateway gateway;
  final SpeechController controller;
  final SlotSurfaceState surface;

  /// A capsule's rect in screen coordinates.
  Rect capsuleRect(int id) {
    final base = tester.getRect(find.byKey(const Key('session-text')));
    final local = surface.capsuleSegmentsForTest()[id]!.first;
    return local.shift(base.topLeft);
  }

  /// Types exactly the way the platform delivers it: an editing-value
  /// update against the surface's own IME shadow.
  Future<void> type(String text) async {
    final value = surface.currentTextEditingValue!;
    final caret = value.selection.baseOffset;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: value.text.replaceRange(caret, caret, text),
        selection: TextSelection.collapsed(offset: caret + text.length),
      ),
    );
    await tester.pump();
  }

  Future<void> key(LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await tester.pump();
  }

  /// A key chord with Ctrl (and optionally Shift) held, the way the
  /// framework reports real shortcuts.
  Future<void> ctrlKey(
    LogicalKeyboardKey k, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.sendKeyEvent(k);
    await tester.pump();
    if (shift) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }
}

/// Pumps a pinned session through to the preview: [pins] slots (`‡1‡`,
/// `‡2‡`, …) with [prefill] (and [prefill2], for two) as their initial
/// values inside the given [body].
Future<SlotPreviewHarness> pumpSlotPreview(
  WidgetTester tester, {
  String body = '发给‡1‡一下',
  String prefill = '张三',
  String? prefill2,
  int pins = 1,
}) async {
  final gateway = FakeGateway();
  final controller = SpeechController(gateway: gateway, scriptedPhrases: const []);
  addTearDown(controller.dispose);
  await tester.pumpWidget(SpokenRectifierApp(controller: controller));

  await controller.startSession();
  await tester.pump(const Duration(milliseconds: 350));
  for (var i = 0; i < pins; i++) {
    await gateway.pinPlaceholder();
    await tester.pump();
  }
  await controller.stopSession();
  await tester.pump(const Duration(milliseconds: 350));

  gateway.emit(BridgeEvent.rectifiedTextChunk(delta: body));
  gateway.emit(
    BridgeEvent.previewPrefills(
      prefills: [
        BridgePrefillRow(number: 1, value: prefill),
        if (prefill2 != null) BridgePrefillRow(number: 2, value: prefill2),
      ],
    ),
  );
  gateway.emit(
    const BridgeEvent.sessionStateChanged(
      from: BridgeSessionState.rectifying,
      to: BridgeSessionState.preview,
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  final surface =
      tester.state(find.byKey(const Key('session-text'))) as SlotSurfaceState;
  return SlotPreviewHarness(tester, gateway, controller, surface);
}

Future<void> windDown(WidgetTester tester, SpeechController controller) async {
  if (controller.phase != BridgeSessionState.idle) {
    await controller.cancelSession();
  }
  await tester.pump(const Duration(milliseconds: 1200));
}

void main() {
  testWidgets(
    'the outgoing setClient configuration carries the view id the engine requires', (
    tester,
  ) async {
    // The Windows engine rejects TextInput.setClient outright when the
    // configuration has no integer viewId — the text model is never
    // created and every typed character is silently dropped (the
    // acceptance-round finding: typing inserted nothing on hardware).
    final h = await pumpSlotPreview(tester);
    final args = h.tester.testTextInput.setClientArgs;
    expect(args, isNotNull, reason: 'a client must be attached in preview');
    expect(args!['viewId'], isA<int>());
    expect(args['inputAction'], 'TextInputAction.newline');
    await windDown(tester, h.controller);
  },
  );

  testWidgets('the preview paints the prefill in a capsule, no bare sentinel', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester);
    expect(h.surface.flatBaseText, '发给￼张三￼一下');
    // The whole main surface never shows the four sentinel characters.
    expect(find.textContaining('‡'), findsNothing);
    expect(h.surface.capsuleSegmentsForTest().keys, [1]);
    await windDown(tester, h.controller);
  });

  testWidgets('tapping a prefill capsule selects its whole value', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester);
    await tester.tapAt(h.capsuleRect(1).center);
    await tester.pump();

    // The tapped capsule is the edited one, its value fully selected —
    // the fastest replace path (点预填非空胶囊默认全选).
    expect(h.surface.activeSlotId, 1);
    final edges = h.surface.editor.selectionEdges!;
    expect(edges.$1, const SlotCursor.inside(at: 2, offset: 0));
    expect(edges.$2, const SlotCursor.inside(at: 2, offset: 2));

    // Typing over the selection replaces the prefill wholesale, and the
    // substituted text (what confirm would insert) follows at once.
    await h.type('李四');
    expect(h.surface.flatBaseText, '发给￼李四￼一下');
    expect(h.controller.previewText, '发给李四一下');
    await windDown(tester, h.controller);
  });

  testWidgets(
    'a Chinese IME composition over the selected value replaces it (the Windows engine sequence)', (
      tester,
    ) async {
      final h = await pumpSlotPreview(tester);
      await tester.tapAt(h.capsuleRect(1).center);
      await tester.pump();
      // 张三 is fully selected; the shadow carries the selection at flat
      // 3..5 of 发给￼张三一下.
      final shadow = h.surface.currentTextEditingValue!;
      expect(shadow.selection.baseOffset, 3);
      expect(shadow.selection.extentOffset, 5);

      // Replay the engine's exact updateEditingState payloads for typing
      // pinyin "zhang" over that selection (text_input_plugin.cc /
      // text_input_model.cc): begin collapses the composing range at the
      // selection start without touching the text...
      h.tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '发给￼张三￼一下',
          selection: TextSelection(baseOffset: 3, extentOffset: 5),
          composing: TextRange(start: 3, end: 3),
        ),
      );
      await h.tester.pump();
      // ...then the first compose change: the engine DELETED the selection
      // and inserted the composing run at the selection start.
      h.tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '发给￼zhang￼一下',
          selection: TextSelection.collapsed(offset: 8),
          composing: TextRange(start: 3, end: 8),
        ),
      );
      await h.tester.pump();
      // Mid-composition: the model keeps its selection (the overlay covers
      // it) and the painted paragraph equals the platform text.
      expect(h.surface.flatBaseText, '发给￼张三￼一下');
      expect(h.surface.composingText, 'zhang');
      expect(h.surface.paintedTextForTest, '发给￼zhang￼一下');

      // Space commits 张: the commit itself sends no update (the plugin
      // defers to the end event); the end event carries the final state.
      h.tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '发给￼张￼一下',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 0),
        ),
      );
      await h.tester.pump();

      expect(h.surface.composingText, '');
      expect(h.surface.editor.doc.valueOf(1), '张');
      expect(h.surface.flatBaseText, '发给￼张￼一下');
      expect(h.controller.previewText, '发给张一下');
      await windDown(tester, h.controller);
    },
  );

  testWidgets(
    'an IME commit over a value at the end of the body lands (no out-of-range composing strip)', (
      tester,
    ) async {
      // The same engine sequence with the capsule last in the body: the
      // composing window our old code computed ran past the platform
      // text's end and the handler died on every commit (真机「卡住很
      // 久、替换不落地」的路径).
      final h = await pumpSlotPreview(tester, body: '发给‡1‡');
      await tester.tapAt(h.capsuleRect(1).center);
      await h.tester.pump();
      expect(h.surface.flatBaseText, '发给￼张三￼');

      h.tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '发给￼zhang￼',
          selection: TextSelection.collapsed(offset: 8),
          composing: TextRange(start: 3, end: 8),
        ),
      );
      await h.tester.pump();
      expect(h.surface.composingText, 'zhang');

      h.tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '发给￼张￼',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 0),
        ),
      );
      await h.tester.pump();

      expect(h.surface.composingText, '');
      expect(h.surface.editor.doc.valueOf(1), '张');
      expect(h.surface.flatBaseText, '发给￼张￼');
      await windDown(tester, h.controller);
    },
  );

  testWidgets(
    'only the first tap on a capsule selects all; the next tap places the caret', (
      tester,
    ) async {
      final h = await pumpSlotPreview(tester);
      // Entering the capsule: 张三 starts selected (the replace path).
      await tester.tapAt(h.capsuleRect(1).center);
      await tester.pump();
      final edges = h.surface.editor.selectionEdges!;
      expect(edges.$1, const SlotCursor.inside(at: 2, offset: 0));
      expect(edges.$2, const SlotCursor.inside(at: 2, offset: 2));

      // Tapping the capsule already under the caret drops the selection
      // and puts the caret at the tapped position instead of re-selecting
      // (2026-09-09 ruling: slots must be editable in place). Tap exactly
      // at a stop's caret rect, derived from the caret parked there.
      final origin = tester.getRect(
        find.byKey(const Key('session-text')),
      ).topLeft;
      for (final target in [
        const SlotCursor.inside(at: 2, offset: 2),
        const SlotCursor.inside(at: 2, offset: 0),
      ]) {
        h.surface.editor.place(target);
        await tester.pump();
        final point = h.surface.caretRect()!.center + origin;
        await tester.tapAt(point);
        await tester.pump();
        expect(h.surface.editor.selectionEdges, isNull);
        expect(h.surface.editor.caret, target);
        expect(h.surface.activeSlotId, 1);
      }

      // Leaving and coming back re-arms the wholesale replace.
      h.surface.editor.place(h.surface.editor.stops.last);
      await tester.pump();
      await tester.tapAt(h.capsuleRect(1).center);
      await tester.pump();
      expect(h.surface.editor.selectionEdges?.$2, const SlotCursor.inside(
        at: 2,
        offset: 2,
      ));
      await windDown(tester, h.controller);
    },
  );

  testWidgets('typing into an empty capsule fills its value', (tester) async {
    final h = await pumpSlotPreview(tester, prefill: '');
    await tester.tapAt(h.capsuleRect(1).center);
    await tester.pump();
    expect(h.surface.activeSlotId, 1);
    await h.type('王五');
    expect(h.surface.flatBaseText, '发给￼王五￼一下');
    expect(h.controller.previewText, '发给王五一下');
    await windDown(tester, h.controller);
  });

  testWidgets(
    'backspace at the outside right edge steps inside, then deletes', (
      tester,
    ) async {
      final h = await pumpSlotPreview(tester);
      // Park just outside the capsule's right edge: from the end (past
      // 下), ← twice walks onto the between stop.
      final end = h.surface.editor.stops.last;
      h.surface.editor.place(end);
      await h.key(LogicalKeyboardKey.arrowLeft);
      await h.key(LogicalKeyboardKey.arrowLeft);
      expect(
        h.surface.editor.caret,
        const SlotCursor.outside(5),
        reason: 'the stop beside the capsule is the outside right dock',
      );

      // First backspace steps into the capsule (先进槽内)…
      await h.key(LogicalKeyboardKey.backspace);
      expect(
        h.surface.editor.caret,
        const SlotCursor.inside(at: 2, offset: 2),
      );
      expect(h.surface.editor.doc.valueOf(1), '张三');
      // …the second deletes one character of the value (再按才删).
      await h.key(LogicalKeyboardKey.backspace);
      expect(h.surface.editor.doc.valueOf(1), '张');
      // Deleting the last character empties but never drops the capsule
      // (删空只缩短不消失): the pill is still there, narrower.
      await h.key(LogicalKeyboardKey.backspace);
      expect(h.surface.editor.doc.valueOf(1), '');
      expect(h.surface.capsuleSegmentsForTest().keys, [1]);
      expect(h.controller.previewText, '发给一下');
      await windDown(tester, h.controller);
    },
  );

  testWidgets(
    'backspace inside at the left edge passes through and steps out', (
      tester,
    ) async {
      final h = await pumpSlotPreview(tester);
      h.surface.editor.place(const SlotCursor.inside(at: 2, offset: 0));
      await tester.pump();
      await h.key(LogicalKeyboardKey.backspace);
      expect(h.surface.editor.caret, const SlotCursor.outside(2));
      expect(h.surface.editor.doc.valueOf(1), '张三');
      await windDown(tester, h.controller);
    },
  );

  testWidgets('the empty capsule is one character narrower than one char', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester, prefill: '');
    final emptyWidth = h.surface.capsuleSegmentsForTest()[1]!.first.width;
    // Enter the capsule first (the arrival caret sits at the body's start).
    await tester.tapAt(h.capsuleRect(1).center);
    await tester.pump();
    await h.type('字');
    final oneCharWidth = h.surface.capsuleSegmentsForTest()[1]!.first.width;
    expect(emptyWidth, lessThan(oneCharWidth));
    expect(
      oneCharWidth - emptyWidth,
      greaterThan(10),
      reason: 'the difference is a full character cell',
    );
    await windDown(tester, h.controller);
  });

  testWidgets('Enter inside a slot is a newline in the value, never a confirm', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester);
    h.surface.editor.place(const SlotCursor.inside(at: 2, offset: 2));
    await tester.pump();
    await h.key(LogicalKeyboardKey.enter);
    await h.key(LogicalKeyboardKey.enter);
    expect(h.surface.editor.doc.valueOf(1), '张三\n\n');
    expect(h.controller.phase, BridgeSessionState.preview);
    expect(h.gateway.commands, isNot(contains('confirmInsert')));
    // The substituted text carries the newlines into what would insert.
    expect(h.controller.previewText, '发给张三\n\n一下');
    await windDown(tester, h.controller);
  });

  testWidgets('Ctrl+Z and redo step slot values and body edits on one stack', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester);
    // Two edits: a body insert at the start, then a value edit.
    await h.type('。');
    await tester.tapAt(h.capsuleRect(1).center);
    await tester.pump();
    await h.type('李四');
    expect(h.surface.flatBaseText, '。发给￼李四￼一下');

    // One stack, in time order: undo takes the value edit back first,
    // then the body insert (值与骨架同栈、按时间统一回退). The caret
    // walks with the history: undo lands where the undone edit began,
    // redo behind the redone modification (2026-09-09 ruling).
    await h.ctrlKey(LogicalKeyboardKey.keyZ);
    expect(h.surface.flatBaseText, '。发给￼张三￼一下');
    expect(h.surface.editor.caret, const SlotCursor.inside(at: 3, offset: 0));
    await h.ctrlKey(LogicalKeyboardKey.keyZ);
    expect(h.surface.flatBaseText, '发给￼张三￼一下');
    expect(h.surface.editor.caret, const SlotCursor.outside(0));

    // Redo walks forward again.
    await h.ctrlKey(LogicalKeyboardKey.keyZ, shift: true);
    expect(h.surface.flatBaseText, '。发给￼张三￼一下');
    expect(h.surface.editor.caret, const SlotCursor.outside(1));
    await windDown(tester, h.controller);
  });

  testWidgets('hovering a capsule reveals the edit tooltip', (tester) async {
    final h = await pumpSlotPreview(tester);
    expect(h.surface.tooltipSlotId, isNull);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: h.capsuleRect(1).center);
    addTearDown(gesture.removePointer);
    await tester.pump();
    expect(h.surface.hoverSlotId, 1);
    expect(h.surface.tooltipSlotId, isNull); // not before the wait
    await tester.pump(const Duration(milliseconds: 600));
    expect(h.surface.tooltipSlotId, 1);

    // Leaving the capsule clears it.
    await gesture.moveTo(Offset.zero);
    await tester.pump();
    expect(h.surface.tooltipSlotId, isNull);
    await windDown(tester, h.controller);
  });

  testWidgets('copy across a capsule yields the visible characters only', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester);
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    // Select from inside the capsule's start to past its right edge and
    // copy: the value's text, no sentinel, no identity (身份不出预览).
    h.surface.editor.select(
      const SlotCursor.inside(at: 2, offset: 0),
      const SlotCursor.outside(5),
    );
    await tester.pump();
    await h.ctrlKey(LogicalKeyboardKey.keyC);
    expect(copied, '张三');
    await windDown(tester, h.controller);
  });

  testWidgets('body typing edits the skeleton beside the capsules', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester);
    h.surface.editor.place(h.surface.editor.stops.last); // the body's end
    await tester.pump();
    await h.type('!');
    expect(h.surface.editor.doc.skeleton, '发给‡1‡一下!');
    await windDown(tester, h.controller);
  });

  testWidgets('Home and End walk line bounds, Ctrl the doc bounds', (
    tester,
  ) async {
    // A value with a newline splits the projection into two lines:
    // "发给￼张" / "三一下".
    final h = await pumpSlotPreview(tester, prefill: '张\n三');
    final editor = h.surface.editor;
    editor.place(const SlotCursor.inside(at: 2, offset: 0));
    await tester.pump();

    // End lands before the newline — the first line's last position.
    await h.key(LogicalKeyboardKey.end);
    expect(editor.caret, const SlotCursor.inside(at: 2, offset: 1));
    // Home lands at the line's start, before the capsule.
    await h.key(LogicalKeyboardKey.home);
    expect(editor.caret, const SlotCursor.outside(0));

    // The Ctrl variants jump the whole document.
    await h.ctrlKey(LogicalKeyboardKey.end);
    expect(editor.caret, editor.stops.last);
    await h.ctrlKey(LogicalKeyboardKey.home);
    expect(editor.caret, const SlotCursor.outside(0));

    // Shift+Home extends the selection to the line's start, keeping the
    // far edge — from the second line's end that is 三's left side, not
    // the document's start.
    editor.place(editor.stops.last);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    final edges = editor.selectionEdges!;
    expect(edges.$1, const SlotCursor.inside(at: 2, offset: 2));
    expect(edges.$2, editor.stops.last);
    await windDown(tester, h.controller);
  });

  testWidgets('ArrowUp and ArrowDown walk between the lines', (tester) async {
    final h = await pumpSlotPreview(tester, prefill: '张\n三');
    final editor = h.surface.editor;
    int flat() => SlotProjection(editor.doc).cursorToFlat(editor.caret);

    // From the second line's end, up lands on the first line, down back
    // on the second.
    editor.place(editor.stops.last);
    await tester.pump();
    await h.key(LogicalKeyboardKey.arrowUp);
    expect(flat(), lessThanOrEqualTo(4), reason: 'the first line ends here');
    await h.key(LogicalKeyboardKey.arrowDown);
    expect(flat(), greaterThanOrEqualTo(5), reason: 'the second line starts here');
    await windDown(tester, h.controller);
  });

  // -- capsule chrome geometry (23 号验收轮 D1/D3 修复的回归锁) --------------

  RenderParagraph previewParagraph(WidgetTester tester) =>
      tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const Key('session-text')),
          matching: find.byType(RichText),
        ),
      );

  /// The flat offsets of the placeholder code units (chip + reservation).
  List<int> placeholderPositions(String flat) => [
    for (var i = 0; i < flat.length; i++)
      if (flat.codeUnitAt(i) == 0xFFFC) i,
  ];

  testWidgets(
    'the pill keeps clear of the neighbouring glyphs on both sides', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester);
    final paragraph = previewParagraph(tester);
    final flat = h.surface.flatBaseText;
    final pill = h.surface.capsuleSegmentsForTest()[1]!.first;
    final leftEnd = flat.indexOf('￼');
    final rightStart = flat.lastIndexOf('￼') + 1;
    final before = paragraph
        .getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: leftEnd))
        .last
        .right;
    final after = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: rightStart, extentOffset: flat.length),
        )
        .first
        .left;
    // The margins are reserved in layout (the chip's leading spacer, the
    // reservation placeholder's tail) — the pill's caps may never touch,
    // let alone paint over, the neighbours' ink.
    expect(pill.left - before, greaterThan(4));
    expect(after - pill.right, greaterThan(4));
    await windDown(tester, h.controller);
  },
  );

  testWidgets('the pill centres on the line text ink, filled capsule', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester);
    final paragraph = previewParagraph(tester);
    final flat = h.surface.flatBaseText;
    final lines = textLineInkBoxes(
      paragraph,
      placeholderPositions(flat),
      flat.length,
    );
    final pill = h.surface.capsuleSegmentsForTest()[1]!.first;
    expect(lines, isNotEmpty);
    // The anchor is the line's TEXT glyphs (placeholders excluded), eased
    // down by the optical nudge — the typographic box's center rides
    // slightly above the glyphs' true ink.
    final ease = SrCapsule.opticalEase * SrType.bodyLarge.fontSize!;
    expect(
      (pill.center.dy - (lines.first.center.dy + ease)).abs(),
      lessThan(0.5),
      reason: 'the anchor is the line\'s TEXT glyphs, placeholders excluded',
    );
    await windDown(tester, h.controller);
  });

  testWidgets('the pill centres on the line text ink, empty capsule', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester, prefill: '');
    final paragraph = previewParagraph(tester);
    final flat = h.surface.flatBaseText;
    final lines = textLineInkBoxes(
      paragraph,
      placeholderPositions(flat),
      flat.length,
    );
    final pill = h.surface.capsuleSegmentsForTest()[1]!.first;
    expect(lines, isNotEmpty);
    final ease = SrCapsule.opticalEase * SrType.bodyLarge.fontSize!;
    expect(
      (pill.center.dy - (lines.first.center.dy + ease)).abs(),
      lessThan(0.5),
      reason: 'empty and filled share one anchor: the text, never the chip',
    );
    await windDown(tester, h.controller);
  });

  testWidgets('stream circles center on their line text ink', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: srTheme(Brightness.dark),
        home: Scaffold(
          body: SlotSurface(
            key: const Key('session-stream-solo'),
            mode: SlotSurfaceMode.stream,
            text: '发给‡1‡一下',
            scrollController: scroll,
          ),
        ),
      ),
    );
    await tester.pump();
    final state =
        tester.state(find.byKey(const Key('session-stream-solo')))
            as SlotSurfaceState;
    final rects = state.streamCircleRectsForTest();
    expect(rects.keys, [1]);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byKey(const Key('session-stream-solo')),
        matching: find.byType(RichText),
      ),
    );
    // Flat = 发给(2) + spacer(1) + 一下(2): the glyph-only ink line
    // around the spacer at 2 claims the circle's center.
    final lines = textLineInkBoxes(paragraph, const [2], 5);
    expect(lines, isNotEmpty);
    final ease =
        SrCapsule.opticalEase *
        (state.widget.streamStyle ?? SrType.bodyLarge).fontSize!;
    expect(
      (rects[1]!.center.dy - (lines.first.center.dy + ease)).abs(),
      lessThan(0.5),
      reason: 'the painted circle rides its line\'s text ink center, eased',
    );
    // The degenerate capsule (反馈九): the family's height, the two caps
    // meeting as one circle — mid-line, sidePad breathing inside the
    // reservation on each side, clear of both neighbours' ink.
    final marker = paragraph
        .getBoxesForSelection(const TextSelection(baseOffset: 2, extentOffset: 3))
        .first
        .toRect();
    expect(rects[1]!.height, SrCapsule.height);
    expect(rects[1]!.width, SrCapsule.height);
    expect(rects[1]!.left - marker.left, closeTo(SrCapsule.sidePad, 0.5));
    expect(marker.right - rects[1]!.right, closeTo(SrCapsule.sidePad, 0.5));
  });

  testWidgets('a stream marker absorbs its breathing at line edges', (
    tester,
  ) async {
    Future<(Rect, Rect)> circleFor(String key, String text, int markerAt) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: srTheme(Brightness.dark),
          home: Scaffold(
            body: SlotSurface(
              key: Key(key),
              mode: SlotSurfaceMode.stream,
              text: text,
              scrollController: scroll,
            ),
          ),
        ),
      );
      await tester.pump();
      final state = tester.state(find.byKey(Key(key))) as SlotSurfaceState;
      final circle = state.streamCircleRectsForTest()[1]!;
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(RichText),
        ),
      );
      final box =
          paragraph
              .getBoxesForSelection(
                TextSelection(baseOffset: markerAt, extentOffset: markerAt + 1),
              )
              .first
              .toRect();
      return (circle, box);
    }

    // Starting the line: the reservation's leading breathing is
    // absorbed — the cap flush at the column's edge (行首不留空位).
    final (start, _) = await circleFor(
      'session-stream-flush-start',
      '‡1‡后面还有话',
      0,
    );
    expect(start.left, closeTo(0, 0.5));
    expect(start.width, SrCapsule.height);

    // Ending the line: nothing follows on the line — the tail breathing
    // is absorbed, the cap flush at the reservation's end (行尾不留空位).
    final (end, endBox) = await circleFor(
      'session-stream-flush-end',
      '前面的话‡1‡',
      4,
    );
    expect(end.right, closeTo(endBox.right, 0.5));
    expect(end.left, closeTo(endBox.right - SrCapsule.height, 0.5));

    // Alone on its line: a rigid circle cannot flush both edges — the
    // leading edge wins, the tail keeps its breathing.
    final (solo, _) = await circleFor('session-stream-flush-solo', '‡1‡', 0);
    expect(solo.left, closeTo(0, 0.5));
    expect(solo.width, SrCapsule.height);
  });

  testWidgets('consecutive markers share one spacing', (tester) async {
    // 反馈十一: a run of markers with nothing between them is placed as
    // ONE run — every gap inside it is the reservation's own slack
    // (sidePad on each side), never doubled by one marker absorbing
    // while its neighbour does not.
    Future<Map<int, Rect>> circlesFor(String key, String text) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: srTheme(Brightness.dark),
          home: Scaffold(
            body: SlotSurface(
              key: Key(key),
              mode: SlotSurfaceMode.stream,
              text: text,
              scrollController: scroll,
            ),
          ),
        ),
      );
      await tester.pump();
      final state = tester.state(find.byKey(Key(key))) as SlotSurfaceState;
      return state.streamCircleRectsForTest();
    }

    void expectUniformGaps(Map<int, Rect> rects) {
      final gap12 = rects[2]!.left - rects[1]!.right;
      final gap23 = rects[3]!.left - rects[2]!.right;
      expect(gap12, closeTo(2 * SrCapsule.sidePad, 0.5));
      expect(gap23, closeTo(2 * SrCapsule.sidePad, 0.5));
    }

    // Starting the line (the fresh-pin run): the run flushes left as one
    // and every inner gap is the reservation's own slack — the tail keeps
    // its breathing (行首优先、尾巴留呼吸, at run scale).
    final solo = await circlesFor('session-stream-run-start', '‡1‡‡2‡‡3‡');
    expectUniformGaps(solo);
    expect(solo[1]!.left, closeTo(0, 0.5));

    // Ending the line after text: the run hugs the reservation ends as
    // one, head keeping its breathing toward the text.
    final tail = await circlesFor('session-stream-run-end', '话‡1‡‡2‡‡3‡');
    expectUniformGaps(tail);

    // Between text on both sides: the run centers as one.
    final mid = await circlesFor('session-stream-run-mid', '话‡1‡‡2‡‡3‡话');
    expectUniformGaps(mid);
  });

  testWidgets(
    'a multi-line capsule bands the column: first flush right, middle full width, last flush left', (
    tester,
  ) async {
    // A value with an empty line covers three paragraph lines — content,
    // the empty line, content (回车与空行都算行, and the empty one is
    // invisible to every box query).
    final h = await pumpSlotPreview(tester, prefill: '张三\n\n李四');
    final paragraph = previewParagraph(tester);
    final column = paragraph.constraints.maxWidth;
    final bands = h.surface.capsuleBandsForTest()[1]!;
    final rects = h.surface.capsuleSegmentsForTest()[1]!;
    expect(rects.length, 3, reason: 'the empty middle line keeps its band');
    // First: from the chip to the column's right edge (首行抵右).
    expect(rects[0].left, greaterThan(0));
    expect(rects[0].right, closeTo(column, 0.5));
    // Middle: the empty line spans the whole column (中行全宽).
    expect(rects[1].left, closeTo(0, 0.5));
    expect(rects[1].right, closeTo(column, 0.5));
    // Last: flush left, past its content's ink by the parking pad (末行
    // 贴左) — the body text after the capsule flows on beside it.
    expect(rects[2].left, closeTo(0, 0.5));
    final flat = h.surface.flatBaseText;
    final liStart = flat.indexOf('李四');
    final liRight = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: liStart, extentOffset: liStart + 2),
        )
        .last
        .right;
    expect(rects[2].right, closeTo(liRight + SrCapsule.valuePad, 0.5));
    // Corner shapes: the chip cap and the value's own end stay round;
    // every end a newline (or the wrapper) cut is square (截断直角).
    expect(bands[0].leftRounded, isTrue);
    expect(bands[0].rightRounded, isFalse);
    expect(bands[1].leftRounded, isFalse);
    expect(bands[1].rightRounded, isFalse);
    expect(bands[2].leftRounded, isFalse);
    expect(bands[2].rightRounded, isTrue);
    await windDown(tester, h.controller);
  });

  testWidgets('a trailing newline leaves a flush-left band for the caret', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester, prefill: '张三\n');
    final rects = h.surface.capsuleSegmentsForTest()[1]!;
    expect(rects.length, 2);
    expect(rects[1].left, closeTo(0, 0.5));
    // No content on the last line: the pill there is the parking space
    // alone, where the caret sits after the trailing 回车 — widened to
    // its own cap radius so the right cap is one continuous semicircle
    // (反馈七终案: the raw parking width could not fit the cap, and the
    // renderer's scaled-down radii read as a sliced-off arc).
    final capRadius = SrCapsule.height / 2;
    expect(rects[1].right, closeTo(capRadius, 0.5));
    final bands = h.surface.capsuleBandsForTest()[1]!;
    expect(bands[1].leftRounded, isFalse);
    expect(bands[1].rightRounded, isTrue);
    await windDown(tester, h.controller);
  });

  testWidgets('a capsule starting a line runs flush to the column edge', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester, body: '‡1‡开个会', prefill: '张三');
    final pill = h.surface.capsuleSegmentsForTest()[1]!.first;
    // No text precedes the chip on its line, so the leading text-contact
    // clearance is dropped (行首不留空位).
    expect(pill.left, closeTo(0, 0.5));
    // A capsule the wrapper never cuts is a complete pill: both ends
    // round (自然端圆帽).
    final band = h.surface.capsuleBandsForTest()[1]!.single;
    expect(band.leftRounded, isTrue);
    expect(band.rightRounded, isTrue);
    await windDown(tester, h.controller);
  });

  testWidgets(
    'adjacent capsules keep one spacing, whatever the neighbour holds', (
    tester,
    ) async {
      // 反馈十一: two capsules with nothing between them — a following
      // capsule's chip placeholder is CONTENT, not "nothing follows", so
      // the first pill never swells into the shared gap while its
      // neighbour sits empty and snaps back once it is filled.
      final h = await pumpSlotPreview(
        tester,
        body: '发给‡1‡‡2‡',
        prefill: '张三',
        prefill2: '',
        pins: 2,
      );
      double gap() =>
          h.surface.capsuleSegmentsForTest()[2]!.first.left -
          h.surface.capsuleSegmentsForTest()[1]!.first.right;
      final gapEmpty = gap();
      final widthEmpty = h.surface.capsuleSegmentsForTest()[1]!.first.width;
      expect(
        gapEmpty,
        closeTo(2 * SrCapsule.sidePad, 0.5),
        reason: 'each capsule keeps its own side breathing toward the other',
      );

      // Fill the second capsule: the first capsule's geometry must not move.
      await tester.tapAt(h.capsuleRect(2).center);
      await tester.pump();
      await h.type('李');
      expect(gap(), closeTo(gapEmpty, 0.01));
      expect(
        h.surface.capsuleSegmentsForTest()[1]!.first.width,
        closeTo(widthEmpty, 0.01),
        reason: 'the neighbour filling may not resize the previous pill',
      );
      await windDown(tester, h.controller);
    },
  );

  testWidgets(
    'a capsule ending its line swallows the reservation tail (single line)', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester, body: '发给‡1‡', prefill: '张三');
    final paragraph = previewParagraph(tester);
    final pill = h.surface.capsuleSegmentsForTest()[1]!.first;
    final flat = h.surface.flatBaseText;
    final valueStart = flat.indexOf('张三');
    final valueRight = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: valueStart, extentOffset: valueStart + 2),
        )
        .last
        .right;
    // Nothing follows the capsule on the line: the pill takes the parking
    // space AND the breathing tail the reservation holds for text that
    // is not there (行尾不留空位).
    expect(
      pill.right,
      closeTo(valueRight + SrCapsule.valuePad + SrCapsule.sidePad, 0.5),
    );
    await windDown(tester, h.controller);
  });

  testWidgets(
    'the last band of a multi-line capsule ending the line swallows the tail too', (
    tester,
  ) async {
    final h = await pumpSlotPreview(tester, body: '发给‡1‡', prefill: '张\n三');
    final paragraph = previewParagraph(tester);
    final rects = h.surface.capsuleSegmentsForTest()[1]!;
    expect(rects.length, 2);
    final flat = h.surface.flatBaseText; // 发给￼张\n三￼
    final sanStart = flat.indexOf('三');
    final sanRight = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: sanStart, extentOffset: sanStart + 1),
        )
        .last
        .right;
    expect(
      rects[1].right,
      closeTo(sanRight + SrCapsule.valuePad + SrCapsule.sidePad, 0.5),
    );
    await windDown(tester, h.controller);
  });

  testWidgets(
    'an auto-wrapped value renders square cut ends with flush text', (
    tester,
  ) async {
    // 截断直角、文字贴边 (D3 反馈五终裁): the wrap CUTS a line's end, the
    // cut renders square, and the text beside it runs against the
    // column's edge exactly like ordinary text — no parking zone, no
    // wrap reserve (the reserve's body-text cost was ruled
    // unacceptable).
    final h = await pumpSlotPreview(tester, body: '发给‡1‡', prefill: '测' * 80);
    final paragraph = previewParagraph(tester);
    final column = paragraph.constraints.maxWidth;
    final bands = h.surface.capsuleBandsForTest()[1]!;
    expect(bands.length, greaterThan(1), reason: 'the value overflows one line');
    expect(bands.first.leftRounded, isTrue, reason: 'the chip cap is natural');
    expect(bands.first.rightRounded, isFalse, reason: 'the wrapper cut it');
    expect(bands.last.leftRounded, isFalse, reason: 'the wrapper cut it');
    expect(bands.last.rightRounded, isTrue, reason: 'the value end is natural');
    if (bands.length > 2) {
      expect(bands[1].leftRounded, isFalse);
      expect(bands[1].rightRounded, isFalse);
    }
    // The full line's text sits flush against the column's edge: the
    // wrap leaves at most one character's width of slack, and the band
    // reaches the edge itself.
    final flat = h.surface.flatBaseText;
    final valueStart = flat.indexOf('测');
    var firstTop = double.infinity;
    var firstRight = 0.0;
    for (final box in paragraph.getBoxesForSelection(
      TextSelection(baseOffset: valueStart, extentOffset: valueStart + 80),
    )) {
      if (box.top < firstTop - 1) {
        firstTop = box.top;
        firstRight = box.right;
      } else if ((box.top - firstTop).abs() < 1 && box.right > firstRight) {
        firstRight = box.right;
      }
    }
    expect(column - firstRight, lessThan(16));
    expect(bands.first.rect.right, closeTo(column, 0.5));
    await windDown(tester, h.controller);
  });

  testWidgets('Home and End walk the visual line across auto-wrapped text', (
    tester,
  ) async {
    // A long value wraps without a single '\n': Home/End bound the
    // VISUAL line, not the paragraph (自动换行的行也有行首行尾;
    // 2026-09-09 用户裁定). Ctrl still jumps the document bounds.
    final h = await pumpSlotPreview(tester, body: '发给‡1‡', prefill: '测' * 80);
    final editor = h.surface.editor;

    // The document's end: the value's last visual line.
    editor.place(editor.stops.last);
    await tester.pump();
    await h.key(LogicalKeyboardKey.home);
    final home = editor.caret;
    expect(home.inside, isTrue, reason: 'a wrapped line starts mid-value');
    expect(home.at, 2);
    expect(home.offset, greaterThan(0));
    expect(home.offset, lessThan(80));

    // End returns to the same line's end — the document's last stop.
    await h.key(LogicalKeyboardKey.end);
    expect(editor.caret, editor.stops.last);

    await h.ctrlKey(LogicalKeyboardKey.home);
    expect(editor.caret, const SlotCursor.outside(0));
    await windDown(tester, h.controller);
  });

  testWidgets('the caret at a soft-wrap boundary renders on the current line', (
    tester,
  ) async {
    // 反馈六: the wrapper breaks a line at the next UNBREAKABLE unit
    // (the reservation placeholder after the value), not at the caret's
    // own character — so the caret's offset can sit exactly on a
    // soft-wrap boundary while the next typed character still lands on
    // the current line. The framework's default downstream affinity
    // would paint it a line early; it renders upstream, on the line its
    // preceding character lives on (2026-09-09 ruling).
    final h = await pumpSlotPreview(tester, prefill: 'a');
    final paragraph = previewParagraph(tester);
    h.surface.editor.place(const SlotCursor.inside(at: 2, offset: 1));
    await tester.pump();

    // Grow one long unbroken word letter by letter, the way it is typed:
    // at every step the caret must ride the line the value's last
    // character is on — including the boundary step, where the
    // reservation has already wrapped but one more letter still fits.
    var sawBoundary = false;
    for (var n = 0; n < 110; n++) {
      await h.type('a');
      final flat = h.surface.flatBaseText;
      final valueEnd = flat.lastIndexOf('￼');
      final lastChar = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: valueEnd - 1, extentOffset: valueEnd),
          )
          .last;
      final caret = h.surface.caretRect()!;
      expect(
        (caret.center.dy - (lastChar.top + lastChar.bottom) / 2).abs(),
        lessThan(10),
        reason: 'the caret rides the line its preceding character is on '
            '(letter $n)',
      );
      final upstream = paragraph.getOffsetForCaret(
        TextPosition(offset: valueEnd, affinity: TextAffinity.upstream),
        Rect.zero,
      );
      final downstream = paragraph.getOffsetForCaret(
        TextPosition(offset: valueEnd),
        Rect.zero,
      );
      if (upstream.dy != downstream.dy) sawBoundary = true;
    }
    expect(sawBoundary, isTrue, reason: 'the walk crossed the wrap boundary');
    await windDown(tester, h.controller);
  });

  testWidgets('the caret right after a hard newline renders on the new line', (
    tester,
  ) async {
    // The upstream rule yields at hard newlines: a caret placed just
    // after a '\n' belongs to the new line's start, not the previous
    // line's end.
    final h = await pumpSlotPreview(tester, prefill: '张\n三');
    h.surface.editor.place(const SlotCursor.inside(at: 2, offset: 2));
    await tester.pump();
    final paragraph = previewParagraph(tester);
    final flat = h.surface.flatBaseText; // 发给￼张\n三￼一下
    final sanStart = flat.indexOf('三');
    final sanBox = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: sanStart, extentOffset: sanStart + 1),
        )
        .last;
    final caret = h.surface.caretRect()!;
    expect(
      (caret.center.dy - (sanBox.top + sanBox.bottom) / 2).abs(),
      lessThan(10),
    );
    await windDown(tester, h.controller);
  });

  test('a cut end dissolves its ink; a complete pill stays flat', () {
    // 截断端渐隐 (D3 反馈八): the square ends the wrap and the hard
    // newlines leave never read as drawn edges — the fill and the stroke
    // dissolve to nothing approaching them, through an alpha MASK over
    // the flat colour (the renderer squares translucent gradient stops,
    // so the tint never rides inside the gradient). The complete pill
    // keeps its flat colour.
    const complete = CapsuleBand(
      rect: Rect.fromLTWH(0, 0, 120, 23),
      leftRounded: true,
      rightRounded: true,
    );
    const cutRight = CapsuleBand(
      rect: Rect.fromLTWH(0, 0, 120, 23),
      leftRounded: true,
      rightRounded: false,
    );
    const cutBoth = CapsuleBand(
      rect: Rect.fromLTWH(0, 0, 300, 23),
      leftRounded: false,
      rightRounded: false,
    );
    // The empty tail line's stub: 11.5px wide, cut on the left — the fade
    // run clamps to a third of the band instead of dissolving it whole.
    const stub = CapsuleBand(
      rect: Rect.fromLTWH(0, 0, 11.5, 23),
      leftRounded: false,
      rightRounded: true,
    );
    expect(complete.cutFadeMask(complete.rect), isNull);
    expect(cutRight.cutFadeMask(cutRight.rect), isNotNull);
    expect(cutBoth.cutFadeMask(cutBoth.rect), isNotNull);
    expect(stub.cutFadeMask(stub.rect), isNotNull);
  });
}
