/// Ticket 22: the preview editing surface — the fill capsules over the
/// slot document (rendering shape, tap-to-edit with prefill select-all,
/// the dual dock points under the surface's own keys, IME-delivered
/// typing, the single undo stack, the prefill hover tooltip, copy of the
/// visible characters, and the substituted text the panel adopts).

library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart';
import 'package:spokenrectifier_app/app_state.dart';
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

/// Pumps a pinned session through to the preview: one slot (`‡1‡`) with
/// [prefill] as its initial value inside the given [body].
Future<SlotPreviewHarness> pumpSlotPreview(
  WidgetTester tester, {
  String body = '发给‡1‡一下',
  String prefill = '张三',
}) async {
  final gateway = FakeGateway();
  final controller = SpeechController(gateway: gateway, scriptedPhrases: const []);
  addTearDown(controller.dispose);
  await tester.pumpWidget(SpokenRectifierApp(controller: controller));

  await controller.startSession();
  await tester.pump(const Duration(milliseconds: 350));
  await gateway.pinPlaceholder();
  await tester.pump();
  await controller.stopSession();
  await tester.pump(const Duration(milliseconds: 350));

  gateway.emit(BridgeEvent.rectifiedTextChunk(delta: body));
  gateway.emit(
    BridgeEvent.previewPrefills(
      prefills: [BridgePrefillRow(number: 1, value: prefill)],
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
    expect(h.surface.flatBaseText, '发给￼张三一下');
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
    expect(h.surface.flatBaseText, '发给￼李四一下');
    expect(h.controller.previewText, '发给李四一下');
    await windDown(tester, h.controller);
  });

  testWidgets('typing into an empty capsule fills its value', (tester) async {
    final h = await pumpSlotPreview(tester, prefill: '');
    await tester.tapAt(h.capsuleRect(1).center);
    await tester.pump();
    expect(h.surface.activeSlotId, 1);
    await h.type('王五');
    expect(h.surface.flatBaseText, '发给￼王五一下');
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
    expect(h.surface.flatBaseText, '。发给￼李四一下');

    // One stack, in time order: undo takes the value edit back first,
    // then the body insert (值与骨架同栈、按时间统一回退).
    await h.ctrlKey(LogicalKeyboardKey.keyZ);
    expect(h.surface.flatBaseText, '。发给￼张三一下');
    await h.ctrlKey(LogicalKeyboardKey.keyZ);
    expect(h.surface.flatBaseText, '发给￼张三一下');

    // Redo walks forward again.
    await h.ctrlKey(LogicalKeyboardKey.keyZ, shift: true);
    expect(h.surface.flatBaseText, '。发给￼张三一下');
    await windDown(tester, h.controller);
  });

  testWidgets('hovering a capsule reveals the prefill tooltip', (tester) async {
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
}
