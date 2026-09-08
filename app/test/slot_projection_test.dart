/// The flat projection (ticket 22): skeleton → chip+value string, and the
/// two-way mapping between slot-cursor stops and flat offsets. The dual
/// dock points live as distinct flat positions — the placeholder's two
/// edges (槽内/槽外两个停靠点;08/20 号票).

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/src/preview/slot_document.dart';
import 'package:spokenrectifier_app/src/preview/slot_editor.dart';
import 'package:spokenrectifier_app/src/preview/slot_projection.dart';

SlotEditor arriveEditor(String text, Map<int, String> prefill) {
  final editor = SlotEditor(SlotDocument());
  editor.arrive(text, prefill);
  return editor;
}

void main() {
  test('sentinels project to chip + value; body passes through', () {
    final editor = arriveEditor('发给‡1‡一下', {1: '张三'});
    final projection = SlotProjection(editor.doc);
    expect(projection.base, '发给$chipPlaceholder张三一下');
    expect(projection.slots, hasLength(1));
    final slot = projection.slots.single;
    expect(slot.id, 1);
    expect(slot.chipAt, 2);
    expect(slot.valueStart, 3);
    expect(slot.valueEnd, 5);
  });

  test('empty value leaves the chip alone in the string', () {
    final editor = arriveEditor('发给‡1‡一下', {});
    expect(SlotProjection(editor.doc).base, '发给$chipPlaceholder一下');
  });

  test('same-shapes typed after arrival pass through verbatim', () {
    // Arrival mints every shape in the round's text (同形也抽,19 号票) —
    // an unminted same-shape only exists from post-arrival edits.
    final editor = arriveEditor('甲‡1‡乙丙', {1: '值'});
    editor.place(const SlotCursor.outside(5)); // past 乙
    editor.insert('‡2‡');
    final projection = SlotProjection(editor.doc);
    expect(projection.base, '甲$chipPlaceholder值乙‡2‡丙');
    expect(projection.slots.map((s) => s.id), [1]);
  });

  test('same identity twice projects two occurrences of one value', () {
    final editor = arriveEditor('甲‡1‡乙‡1‡丙', {1: '张'});
    final projection = SlotProjection(editor.doc);
    expect(projection.base, '甲$chipPlaceholder张乙$chipPlaceholder张丙');
    expect(projection.slots, hasLength(2));
    expect(projection.slots.first.valueStart, 2);
    expect(projection.slots.last.chipAt, 4);
    expect(projection.slots.last.valueStart, 5);
  });

  group('cursor ⇄ flat round trips', () {
    for (final (caseName, text, prefill) in [
      ('slot between words', '发给‡1‡一下', <int, String>{1: '张三'}),
      ('empty value', '发给‡1‡一下', <int, String>{}),
      ('slot at both ends', '‡1‡中‡2‡', <int, String>{1: 'a', 2: 'bb'}),
      ('adjacent slots', '甲‡1‡‡2‡乙', <int, String>{1: '', 2: 'x'}),
      ('no slots at all', '普普通通', <int, String>{}),
    ]) {
      test('every stop maps and returns: $caseName', () {
        final editor = arriveEditor(text, prefill);
        final projection = SlotProjection(editor.doc);
        for (final stop in editor.stops) {
          final flat = projection.cursorToFlat(stop);
          expect(flat, inInclusiveRange(0, projection.base.length));
          // Inside stops and outside stops on a capsule's left edge must
          // come back exactly; outside stops past a capsule are ambiguous
          // only at the right edge (inside-end shares the flat position).
          final back = projection.flatToCursor(flat, preferInside: stop.inside);
          expect(back, stop, reason: '$stop -> $flat -> $back');
        }
      });
    }
  });

  test('the placeholder edge separates outside-left from inside-0', () {
    final editor = arriveEditor('发给‡1‡一下', {1: '张三'});
    final projection = SlotProjection(editor.doc);
    final outsideLeft = projection.cursorToFlat(const SlotCursor.outside(2));
    final insideZero = projection.cursorToFlat(
      const SlotCursor.inside(at: 2, offset: 0),
    );
    expect(outsideLeft, 2); // before the placeholder
    expect(insideZero, 3); // after it
    expect(
      projection.flatToCursor(2, preferInside: false),
      const SlotCursor.outside(2),
    );
    expect(
      projection.flatToCursor(3, preferInside: true),
      const SlotCursor.inside(at: 2, offset: 0),
    );
  });

  test('body offsets past capsules keep their place after edits shift', () {
    // A long first value pushes the second capsule's flat position.
    final editor = arriveEditor('‡1‡与‡2‡', {1: '很长的值', 2: '短'});
    final projection = SlotProjection(editor.doc);
    expect(projection.base, '$chipPlaceholder很长的值与$chipPlaceholder短');
    final second = projection.slots.last;
    expect(second.chipAt, 6);
    expect(second.valueStart, 7);
    // The end stop: past both capsules (the long value pushes, the second
    // sentinel shrinks).
    expect(projection.cursorToFlat(const SlotCursor.outside(7)), 8);
  });
}
