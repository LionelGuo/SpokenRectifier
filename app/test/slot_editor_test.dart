/// The cursor graph and editing discipline (ticket 20): the double
/// docking points (每个跨度边界两个停靠点,←/→ 逐位走、两处插字归属、
/// 槽外插入不进值), the edge keys (槽外贴边先进槽内再删、槽内贴边透传
/// 步出、对称), the selection layer rules (只动字、跨度不删、新字落起点
/// 层、复制/剪切无身份), and the empty/adjacent/Enter family (槽内 Enter
/// 换行、空槽同态、相邻跨度之间可打字), plus the seams back into the
/// document (一键一撤、undo 吸附、arrive 复位).

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/src/preview/slot_document.dart';
import 'package:spokenrectifier_app/src/preview/slot_editor.dart';

SlotEditor arriveEditor(String skeleton, Map<int, String> prefill) {
  final editor = SlotEditor(SlotDocument());
  editor.arrive(skeleton, prefill);
  return editor;
}

void main() {
  group('双停靠点: two stops per span edge, one per body boundary', () {
    // 'A‡1‡B' — the minted span occupies [1, 4), its value '张三' has
    // two code units, so the slot carries inside stops 0..2.
    final skeleton = 'A‡1‡B';

    test('the stop sequence interleaves outside and inside stops', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      expect(editor.stops, [
        const SlotCursor.outside(0),
        const SlotCursor.outside(1),
        const SlotCursor.inside(at: 1, offset: 0),
        const SlotCursor.inside(at: 1, offset: 1),
        const SlotCursor.inside(at: 1, offset: 2),
        const SlotCursor.outside(4),
        const SlotCursor.outside(5),
      ]);
    });

    test('arrow keys walk stop by stop, through the slot and back, clamped at both ends', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.outside(1));
      for (var i = 0; i < 5; i++) {
        editor.moveRight();
      }
      expect(editor.caret, const SlotCursor.outside(5));
      editor.moveRight(); // clamped at the last stop
      expect(editor.caret, const SlotCursor.outside(5));
      for (var i = 0; i < 5; i++) {
        editor.moveLeft();
      }
      expect(editor.caret, const SlotCursor.outside(1));
      editor.moveLeft();
      expect(editor.caret, const SlotCursor.outside(0));
      editor.moveLeft(); // clamped at the first stop
      expect(editor.caret, const SlotCursor.outside(0));
    });

    test('inserting at the outside-left stop lands in the body, never in the value (槽外插入不进值)', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.outside(1));
      editor.insert('X');
      expect(editor.doc.skeleton, 'AX‡1‡B');
      expect(editor.doc.valueOf(1), '张三');
      expect(editor.caret, const SlotCursor.outside(2));
    });

    test('inserting at inside-left lands in the value', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.inside(at: 1, offset: 0));
      editor.insert('X');
      expect(editor.doc.skeleton, skeleton);
      expect(editor.doc.valueOf(1), 'X张三');
      expect(editor.caret, const SlotCursor.inside(at: 1, offset: 1));
    });

    test('the right edge is two stops too: inside-right appends to the value, outside-right to the body', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.inside(at: 1, offset: 2));
      editor.insert('Y');
      expect(editor.doc.valueOf(1), '张三Y');
      expect(editor.caret, const SlotCursor.inside(at: 1, offset: 3));

      final other = arriveEditor(skeleton, {1: '张三'});
      other.place(const SlotCursor.outside(4));
      other.insert('Y');
      expect(other.doc.skeleton, 'A‡1‡YB');
      expect(other.doc.valueOf(1), '张三');
      expect(other.caret, const SlotCursor.outside(5));
    });

    test('place snaps offsets that are not stops: into a shape down to its left edge, past the end back to it', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.outside(2)); // strictly inside ‡1‡
      expect(editor.caret, const SlotCursor.outside(1));
      editor.place(const SlotCursor.outside(99));
      expect(editor.caret, const SlotCursor.outside(5));
    });

    test('an unminted same-shape typed into the body is ordinary text — stops inside it, nothing mints', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.outside(0));
      editor.insert('‡9‡');
      expect(editor.doc.skeleton, '‡9‡A‡1‡B');
      expect(editor.doc.fillSlots.length, 1);
      expect(editor.stops, contains(const SlotCursor.outside(1)));
      expect(editor.stops, contains(const SlotCursor.outside(2)));
      editor.place(const SlotCursor.outside(2)); // inside the unminted shape
      expect(editor.caret, const SlotCursor.outside(2));
    });

    test('a minted same-shape typed into the body becomes that identity\'s second occurrence', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.outside(0));
      editor.insert('‡1‡');
      expect(editor.doc.skeleton, '‡1‡A‡1‡B');
      expect(editor.doc.fillSlots.length, 2);
      editor.place(const SlotCursor.outside(0));
      editor.moveRight(); // into the new occurrence
      expect(editor.caret, const SlotCursor.inside(at: 0, offset: 0));
    });
  });

  group('贴边退格/Delete: in first, then delete; inside passes through', () {
    final skeleton = 'A‡1‡B';

    test('Backspace at the outside-right edge steps into the slot first, deletes on the next press (先进槽内、再按才删)', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.outside(4));
      editor.backspace();
      expect(editor.caret, const SlotCursor.inside(at: 1, offset: 2));
      expect(editor.doc.valueOf(1), '张三');
      expect(editor.canUndo, isFalse); // entering is a caret move, no edit
      editor.backspace();
      expect(editor.doc.valueOf(1), '张');
      expect(editor.caret, const SlotCursor.inside(at: 1, offset: 1));
    });

    test('Delete at the outside-left edge steps into the slot first', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.outside(1));
      editor.deleteForward();
      expect(editor.caret, const SlotCursor.inside(at: 1, offset: 0));
      expect(editor.doc.valueOf(1), '张三');
      expect(editor.canUndo, isFalse);
      editor.deleteForward();
      expect(editor.doc.valueOf(1), '三');
      expect(editor.caret, const SlotCursor.inside(at: 1, offset: 0));
    });

    test('Backspace at inside-left passes through and steps out; the next press deletes the body char (槽内贴边透传步出)', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.inside(at: 1, offset: 0));
      editor.backspace();
      expect(editor.caret, const SlotCursor.outside(1));
      expect(editor.doc.skeleton, skeleton);
      expect(editor.canUndo, isFalse);
      editor.backspace();
      expect(editor.doc.skeleton, '‡1‡B');
      expect(editor.caret, const SlotCursor.outside(0));
    });

    test('Delete at inside-right passes through and steps out — the symmetric case', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.inside(at: 1, offset: 2));
      editor.deleteForward();
      expect(editor.caret, const SlotCursor.outside(4));
      expect(editor.doc.skeleton, skeleton);
      expect(editor.canUndo, isFalse);
      editor.deleteForward();
      expect(editor.doc.skeleton, 'A‡1‡');
      expect(editor.caret, const SlotCursor.outside(4));
    });

    test('an empty slot has one inside state: Backspace exits left, Delete exits right, traversal deletes nothing (空槽槽内左右同一状态)', () {
      final editor = arriveEditor(skeleton, {1: ''});
      editor.place(const SlotCursor.inside(at: 1, offset: 0));
      editor.backspace();
      expect(editor.caret, const SlotCursor.outside(1));
      editor.place(const SlotCursor.inside(at: 1, offset: 0));
      editor.deleteForward();
      expect(editor.caret, const SlotCursor.outside(4));

      editor.place(const SlotCursor.outside(4));
      editor.backspace(); // in
      editor.backspace(); // straight out the other side
      expect(editor.caret, const SlotCursor.outside(1));
      expect(editor.doc.skeleton, skeleton);
      expect(editor.doc.valueOf(1), '');
      expect(editor.canUndo, isFalse);
    });

    test(
      'deleting a value down to empty, then one more Backspace, exits the slot',
      () {
        final editor = arriveEditor(skeleton, {1: 'AB'});
        editor.place(const SlotCursor.inside(at: 1, offset: 2));
        editor.backspace();
        editor.backspace();
        expect(editor.doc.valueOf(1), '');
        expect(editor.caret, const SlotCursor.inside(at: 1, offset: 0));
        editor.backspace();
        expect(editor.caret, const SlotCursor.outside(1));
      },
    );

    test('document-edge guards: Backspace at the start and Delete at the end do nothing', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.place(const SlotCursor.outside(0));
      editor.backspace();
      expect(editor.doc.skeleton, skeleton);
      expect(editor.canUndo, isFalse);
      editor.place(const SlotCursor.outside(5));
      editor.deleteForward();
      expect(editor.doc.skeleton, skeleton);
      expect(editor.canUndo, isFalse);
    });
  });

  group('选区: only the covered characters move; the identity never leaves', () {
    // 'AB‡1‡CD' — the minted span occupies [2, 5).
    final skeleton = 'AB‡1‡CD';

    test(
      'a body-only selection deletes exactly those characters (选区只动选中的字)',
      () {
        final editor = arriveEditor(skeleton, {1: '张三'});
        editor.select(const SlotCursor.outside(1), const SlotCursor.outside(2));
        editor.backspace();
        expect(editor.doc.skeleton, 'A‡1‡CD');
        expect(editor.doc.valueOf(1), '张三');
        expect(editor.caret, const SlotCursor.outside(1));
      },
    );

    test('a fully covered span survives, emptied — the mis-pin take-back (掏空取回,不提供删跨度)', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.select(const SlotCursor.outside(2), const SlotCursor.outside(5));
      editor.backspace();
      expect(editor.doc.skeleton, skeleton);
      expect(editor.doc.valueOf(1), '');
      expect(editor.doc.fillSlots.length, 1);
      expect(editor.caret, const SlotCursor.outside(2));
      expect(editor.undo(), isTrue); // one keystroke, one undo step
      expect(editor.doc.valueOf(1), '张三');
      expect(editor.canUndo, isFalse);
    });

    test('typing over a selection that starts inside a slot lands in the value (新字落选区起点所在层)', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.select(
        const SlotCursor.inside(at: 2, offset: 1),
        const SlotCursor.outside(7),
      );
      editor.insert('X');
      expect(editor.doc.valueOf(1), '张X'); // covered '三' gone, X in its place
      expect(editor.doc.skeleton, 'AB‡1‡'); // covered 'CD' gone
      expect(editor.caret, const SlotCursor.inside(at: 2, offset: 2));
    });

    test(
      'typing over a selection that starts in the body lands in the body',
      () {
        final editor = arriveEditor(skeleton, {1: '张三'});
        editor.select(
          const SlotCursor.outside(0),
          const SlotCursor.inside(at: 2, offset: 1),
        );
        editor.insert('X');
        expect(editor.doc.skeleton, 'X‡1‡CD');
        expect(editor.doc.valueOf(1), '三');
        expect(editor.caret, const SlotCursor.outside(1));
      },
    );

    test('copy yields the visible characters — the marks and identity never leave (身份不出模型)', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.select(const SlotCursor.outside(2), const SlotCursor.outside(5));
      expect(editor.copy(), '张三');
      expect(editor.canUndo, isFalse); // copy is pure
      editor.select(const SlotCursor.outside(1), const SlotCursor.outside(6));
      expect(editor.copy(), 'B张三C');
      expect(editor.copy(), isNot(contains('‡')));
    });

    test('cut copies and deletes in one atomic step', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.select(const SlotCursor.outside(2), const SlotCursor.outside(5));
      expect(editor.cut(), '张三');
      expect(editor.doc.skeleton, skeleton);
      expect(editor.doc.valueOf(1), '');
      expect(editor.undo(), isTrue);
      expect(editor.doc.valueOf(1), '张三');
      expect(editor.canUndo, isFalse);
    });

    test('two occurrences of one identity: copy reads the visible text twice, cut empties the shared value once', () {
      final editor = arriveEditor('‡1‡与‡1‡', {1: 'AB'});
      editor.select(
        const SlotCursor.inside(at: 0, offset: 1),
        const SlotCursor.inside(at: 4, offset: 1),
      );
      expect(editor.copy(), 'B与A');
      expect(editor.cut(), 'B与A');
      expect(editor.doc.valueOf(1), '');
      expect(editor.doc.skeleton, '‡1‡‡1‡');
      expect(editor.undo(), isTrue);
      expect(editor.doc.skeleton, '‡1‡与‡1‡');
      expect(editor.doc.valueOf(1), 'AB');
    });

    test('a compound selection delete touching body and two values is one undo step (值与骨架同栈)', () {
      final editor = arriveEditor('AB‡1‡CD‡2‡E', {1: '张三', 2: '乙'});
      editor.select(const SlotCursor.outside(1), const SlotCursor.outside(11));
      editor.backspace();
      expect(editor.doc.skeleton, 'A‡1‡‡2‡');
      expect(editor.doc.valueOf(1), '');
      expect(editor.doc.valueOf(2), '');
      expect(editor.caret, const SlotCursor.outside(1));
      expect(editor.undo(), isTrue);
      expect(editor.doc.skeleton, 'AB‡1‡CD‡2‡E');
      expect(editor.doc.valueOf(1), '张三');
      expect(editor.doc.valueOf(2), '乙');
      expect(editor.canUndo, isFalse);
    });

    test('arrow keys collapse the selection onto the end they face', () {
      final editor = arriveEditor(skeleton, {1: '张三'});
      editor.select(const SlotCursor.outside(1), const SlotCursor.outside(5));
      editor.moveLeft();
      expect(editor.caret, const SlotCursor.outside(1));
      expect(editor.hasSelection, isFalse);
      editor.select(const SlotCursor.outside(1), const SlotCursor.outside(5));
      editor.moveRight();
      expect(editor.caret, const SlotCursor.outside(5));
      expect(editor.hasSelection, isFalse);
    });
  });

  group('槽内 Enter、空槽与相邻跨度', () {
    test('Enter inside a slot is a newline in the value, not a confirm (槽内 Enter 是换行)', () {
      final editor = arriveEditor('A‡1‡B', {1: '张三'});
      editor.place(const SlotCursor.inside(at: 1, offset: 1));
      editor.insert('\n');
      expect(editor.doc.valueOf(1), '张\n三');
      expect(editor.caret, const SlotCursor.inside(at: 1, offset: 2));
      expect(editor.doc.substitute(), 'A张\n三B');
    });

    test('an emptied slot is still the same slot object — typing inside fills it (空 = 长度零的同一种槽)', () {
      final editor = arriveEditor('AB‡1‡CD', {1: '张三'});
      editor.select(const SlotCursor.outside(2), const SlotCursor.outside(5));
      editor.backspace(); // 掏空
      editor.place(const SlotCursor.inside(at: 2, offset: 0));
      editor.insert('新');
      expect(editor.doc.valueOf(1), '新');
      expect(editor.doc.fillSlots.length, 1);
      expect(editor.caret, const SlotCursor.inside(at: 2, offset: 1));
    });

    test('adjacent spans share one between-stop; typing there lands between them (相邻跨度之间可打字)', () {
      final editor = arriveEditor('‡1‡‡2‡', {1: '一', 2: '二'});
      expect(editor.stops, [
        const SlotCursor.outside(0),
        const SlotCursor.inside(at: 0, offset: 0),
        const SlotCursor.inside(at: 0, offset: 1),
        const SlotCursor.outside(3),
        const SlotCursor.inside(at: 3, offset: 0),
        const SlotCursor.inside(at: 3, offset: 1),
        const SlotCursor.outside(6),
      ]);
      editor.place(const SlotCursor.outside(3));
      editor.backspace(); // enters the left slot's right end
      expect(editor.caret, const SlotCursor.inside(at: 0, offset: 1));
      editor.place(const SlotCursor.outside(3));
      editor.deleteForward(); // enters the right slot's left end
      expect(editor.caret, const SlotCursor.inside(at: 3, offset: 0));

      final other = arriveEditor('‡1‡‡2‡', {1: '一', 2: '二'});
      other.place(const SlotCursor.outside(3));
      other.insert('X');
      expect(other.doc.skeleton, '‡1‡X‡2‡');
      expect(other.doc.valueOf(1), '一');
      expect(other.doc.valueOf(2), '二');
      expect(other.caret, const SlotCursor.outside(4));
    });
  });

  group('与文档层的缝: undo snapping and the arrive reset', () {
    test(
      'undo lands where the undone edit began, redo behind the redone edit',
      () {
        final editor = arriveEditor('A‡1‡B', {1: '张三'});
        editor.place(const SlotCursor.outside(4));
        editor.insert('XY');
        expect(editor.doc.skeleton, 'A‡1‡XYB');
        expect(editor.caret, const SlotCursor.outside(6));
        expect(editor.undo(), isTrue);
        expect(editor.doc.skeleton, 'A‡1‡B');
        // The caret travels to where the undone edit began (2026-09-09
        // ruling: history walks the caret with the change).
        expect(editor.caret, const SlotCursor.outside(4));
        expect(editor.stops, contains(editor.caret));
        expect(editor.redo(), isTrue);
        expect(editor.doc.skeleton, 'A‡1‡XYB');
        // Behind the redone modification.
        expect(editor.caret, const SlotCursor.outside(6));
        expect(editor.canRedo, isFalse);
      },
    );

    test('undo and redo walk the caret across edits on the stack', () {
      final editor = arriveEditor('A‡1‡B', {1: '张三'});
      // Edit 1 in the capsule, then a caret move with no edit, then
      // edit 2 in the body: undo must land at each edit's own site, not
      // wherever the caret happened to sit.
      editor.place(const SlotCursor.inside(at: 1, offset: 2));
      editor.insert('李');
      expect(editor.doc.valueOf(1), '张三李');
      editor.place(const SlotCursor.outside(4));
      editor.insert('XY');
      expect(editor.doc.skeleton, 'A‡1‡XYB');

      expect(editor.undo(), isTrue);
      expect(editor.doc.skeleton, 'A‡1‡B');
      expect(editor.caret, const SlotCursor.outside(4));
      expect(editor.undo(), isTrue);
      expect(editor.doc.valueOf(1), '张三');
      expect(editor.caret, const SlotCursor.inside(at: 1, offset: 2));
      expect(editor.redo(), isTrue);
      expect(editor.doc.valueOf(1), '张三李');
      expect(editor.caret, const SlotCursor.inside(at: 1, offset: 3));
      expect(editor.redo(), isTrue);
      expect(editor.doc.skeleton, 'A‡1‡XYB');
      expect(editor.caret, const SlotCursor.outside(6));
      expect(editor.canRedo, isFalse);
    });

    test('arriving text resets the caret, drops the selection, and hits the barrier', () {
      final editor = arriveEditor('AB‡1‡CD', {1: '张三'});
      editor.select(const SlotCursor.outside(1), const SlotCursor.outside(5));
      editor.backspace();
      expect(editor.canUndo, isTrue);
      editor.arrive('新文‡1‡', {1: 'v'});
      expect(editor.caret, const SlotCursor.outside(0));
      expect(editor.anchor, isNull);
      expect(editor.hasSelection, isFalse);
      expect(editor.canUndo, isFalse);
      expect(editor.doc.skeleton, '新文‡1‡');
    });
  });
}
