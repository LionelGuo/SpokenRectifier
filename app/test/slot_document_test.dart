/// The fill-slot document, locked cell by cell (ticket 19): extraction
/// (以本轮文本为准、同形也抽、少吐少颗、不补不发明), substitution (预填
/// 初值、空串、含空格、不 trim、同号多处、整段空串), retention (改动判
/// 定、掏空不复活、少吐不蒸发、重现带回、改回读作未改、骨架编辑全丢),
/// and the single undo stack with the regeneration barrier (值与骨架同栈、
/// 重生成即清双栈、栈底无操作、身份不动).

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/src/preview/slot_document.dart';

void main() {
  group('scanSentinels: 机械扫描', () {
    test('digits are the id — multi-digit, adjacent, shapes only', () {
      final spans = scanSentinels('a‡12‡b‡3‡');
      expect(spans, [
        const PlaceholderSpan(id: 12, start: 1, end: 5),
        const PlaceholderSpan(id: 3, start: 6, end: 9),
      ]);
    });

    test('no digits, no shape — lone marks and letters are plain text', () {
      expect(scanSentinels('‡ ‡a‡ ‡12 ‡1‡'), [
        const PlaceholderSpan(id: 1, start: 10, end: 13),
      ]);
    });

    test('id 0 and leading zeros mint mechanically', () {
      expect(scanSentinels('‡0‡').first.id, 0);
      expect(scanSentinels('‡01‡').first.id, 1);
    });
  });

  group('抽取: this round\'s text is the truth', () {
    test('every same-shape extracts — origin is not distinguished (同形也抽)', () {
      final doc = SlotDocument();
      doc.arrive('发给‡1‡,还有 ‡7‡', {1: '张三'});
      expect(doc.visibleIdentities, {1, 7});
      expect(doc.valueOf(1), '张三');
      expect(doc.valueOf(7), ''); // 表缺号 → 该槽空
    });

    test('prefill rows for absent numbers are ignored (表多号)', () {
      final doc = SlotDocument();
      doc.arrive('只有‡1‡', {1: '一', 99: '多'});
      expect(doc.identities, {1});
    });

    test('a dropped number is one slot fewer — nothing patched, nothing invented (少吐少颗、不补不发明)', () {
      final doc = SlotDocument();
      doc.arrive('A‡1‡B‡2‡C', {1: '一', 2: '二'});
      doc.arrive('A‡1‡B', {1: '一'});
      expect(doc.visibleIdentities, {1});
      expect(doc.fillSlots.map((span) => span.id), [1]);
      expect(doc.identities, {1, 2}); // the value map survives (少吐不蒸发)
    });

    test('no shapes, no slots — the text substitutes to itself', () {
      final doc = SlotDocument();
      doc.arrive('普通文本,没有任何记号', const {});
      expect(doc.visibleIdentities, isEmpty);
      expect(doc.fillSlots, isEmpty);
      expect(doc.substitute(), '普通文本,没有任何记号');
    });

    test('multiple occurrences of one number are one identity (同号多处)', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡与‡1‡', {1: '张三'});
      expect(doc.visibleIdentities, {1});
      expect(doc.fillSlots.length, 2);
      expect(doc.fillSlots.every((span) => span.id == 1), isTrue);
    });

    test('post-arrival edits mint nothing (人改/粘出的同形是普通字)', () {
      final doc = SlotDocument();
      doc.arrive('正文', const {});
      doc.editSkeleton('x‡8‡y');
      expect(doc.identities, isEmpty);
      expect(doc.fillSlots, isEmpty);
      expect(doc.substitute(), 'x‡8‡y'); // unminted shape passes verbatim
    });

    test('editing an unminted number is a no-op, not a mint', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡', {1: '一'});
      doc.editValue(9, '九');
      expect(doc.identities, {1});
      expect(doc.canUndo, isFalse);
    });
  });

  group('代入: confirm substitutes mechanically', () {
    test('an untouched slot substitutes its prefill (预填即初值)', () {
      final doc = SlotDocument();
      doc.arrive('发给‡1‡', {1: '张三'});
      expect(doc.substitute(), '发给张三');
    });

    test('an edited slot substitutes the edit (所见即所插的模型侧)', () {
      final doc = SlotDocument();
      doc.arrive('发给‡1‡', {1: '张三'});
      doc.editValue(1, '李四');
      expect(doc.substitute(), '发给李四');
    });

    test('an empty value leaves nothing at its position (零字符 → 该位置没有)', () {
      final doc = SlotDocument();
      doc.arrive('a‡1‡b', {1: ''});
      expect(doc.substitute(), 'ab');
    });

    test('characters inside a value land verbatim, spaces included (含空格原样)', () {
      final doc = SlotDocument();
      doc.arrive('a‡1‡b', {1: ' 张三 '});
      expect(doc.substitute(), 'a 张三 b');
    });

    test('junctions are not trimmed (不 trim)', () {
      final doc = SlotDocument();
      doc.arrive('发给 ‡1‡ 了', {1: '张三'});
      expect(doc.substitute(), '发给 张三 了');
    });

    test('one value per number, at every occurrence (同号处处同一串)', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡与‡1‡', {1: '张三'});
      expect(doc.substitute(), '张三与张三');
    });

    test('a shape-only skeleton with all-empty values substitutes to the empty string (整段空串不设闸)', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡‡2‡', {1: '', 2: ''});
      expect(doc.substitute(), '');
    });

    test('substitution is one pass — value text that looks like a sentinel lands verbatim', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡和‡2‡', {1: '', 2: 'X'});
      doc.editValue(1, '‡2‡');
      expect(doc.substitute(), '‡2‡和X'); // the substituted shape stays, the real one became X
    });
  });

  group('保值: values hang on the pin, not the round', () {
    test('a modified value survives regeneration (改动过的值按号保留)', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡', {1: 'A'});
      doc.editValue(1, 'B');
      doc.arrive('‡1‡', {1: 'C'});
      expect(doc.valueOf(1), 'B');
      expect(doc.prefillOf(1), 'C');
      expect(doc.isModified(1), isTrue);
    });

    test('an untouched value follows the new prefill (未改的用新预填)', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡', {1: 'A'});
      doc.arrive('‡1‡', {1: 'C'});
      expect(doc.valueOf(1), 'C');
      expect(doc.isModified(1), isFalse);
    });

    test('emptying is a modification — a new prefill does not resurrect it (掏空不复活)', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡', {1: 'A'});
      doc.editValue(1, '');
      doc.arrive('‡1‡', {1: 'C'});
      expect(doc.valueOf(1), '');
    });

    test('a dropped number\'s value does not evaporate, and returns with it (少吐不蒸发、重现带回)', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡和‡2‡', {1: '一', 2: 'A'});
      doc.editValue(2, 'B');
      doc.arrive('只有‡1‡', {1: '一'});
      expect(doc.visibleIdentities, {1});
      expect(doc.valueOf(2), 'B'); // invisible, still held
      doc.arrive('‡1‡和‡2‡', {1: '一', 2: 'E'});
      expect(doc.valueOf(2), 'B'); // back, with its value
      expect(doc.prefillOf(2), 'E');
    });

    test('an untouched dropped value adopts the prefill of the round it returns in', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡和‡2‡', {1: '一', 2: 'A'});
      doc.arrive('只有‡1‡', {1: '一'});
      doc.arrive('‡1‡和‡2‡', {1: '一', 2: 'E'});
      expect(doc.valueOf(2), 'E');
    });

    test('typing back the old prefill byte-for-byte reads as untouched (改回读作未改)', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡', {1: 'A'});
      doc.editValue(1, 'X');
      doc.editValue(1, 'A');
      doc.arrive('‡1‡', {1: 'C'});
      expect(doc.valueOf(1), 'C');
      expect(doc.isModified(1), isFalse);
    });

    test('skeleton edits die with the round they were made in (骨架编辑照旧全丢)', () {
      final doc = SlotDocument();
      doc.arrive('原文‡1‡', {1: 'v'});
      doc.editSkeleton('手改过的正文');
      doc.arrive('新文‡1‡', {1: 'v'});
      expect(doc.skeleton, '新文‡1‡');
    });
  });

  group('撤销: one stack, the regeneration barrier', () {
    test('value and skeleton edits revert together, in time order (值与骨架同栈、按时间统一回退)', () {
      final doc = SlotDocument();
      doc.arrive('A‡1‡B', {1: '一'});
      doc.editValue(1, '二');
      doc.editSkeleton('A‡1‡B补');
      doc.editValue(1, '三');

      expect(doc.skeleton, 'A‡1‡B补');
      expect(doc.valueOf(1), '三');

      expect(doc.undo(), isTrue); // revert the third edit
      expect(doc.skeleton, 'A‡1‡B补');
      expect(doc.valueOf(1), '二');

      expect(doc.undo(), isTrue); // revert the second edit
      expect(doc.skeleton, 'A‡1‡B');
      expect(doc.valueOf(1), '二');

      expect(doc.undo(), isTrue); // revert the first edit → the round's initial state
      expect(doc.skeleton, 'A‡1‡B');
      expect(doc.valueOf(1), '一');

      expect(doc.undo(), isFalse); // 栈底无操作

      expect(doc.redo(), isTrue); // walk forward through the same states
      expect(doc.valueOf(1), '二');
      expect(doc.skeleton, 'A‡1‡B');
      expect(doc.redo(), isTrue);
      expect(doc.skeleton, 'A‡1‡B补');
      expect(doc.redo(), isTrue);
      expect(doc.valueOf(1), '三');
      expect(doc.redo(), isFalse);
    });

    test('undo before any edit is a no-op (栈底 = 当轮初态)', () {
      final doc = SlotDocument();
      doc.arrive('A‡1‡B', {1: '一'});
      expect(doc.canUndo, isFalse);
      expect(doc.undo(), isFalse);
      expect(doc.skeleton, 'A‡1‡B');
      expect(doc.valueOf(1), '一');
    });

    test('a new edit drops the redo tail', () {
      final doc = SlotDocument();
      doc.arrive('A‡1‡B', {1: '一'});
      doc.editValue(1, '二');
      doc.undo();
      expect(doc.canRedo, isTrue);
      doc.editValue(1, '三');
      expect(doc.canRedo, isFalse);
      expect(doc.valueOf(1), '三');
    });

    test('regeneration clears both stacks — the barrier (重生成即清双栈)', () {
      final doc = SlotDocument();
      doc.arrive('A‡1‡B', {1: '一'});
      doc.editValue(1, '二');
      doc.editSkeleton('手改');
      doc.undo();
      expect(doc.canUndo, isTrue);
      expect(doc.canRedo, isTrue);
      doc.arrive('C‡1‡D', {1: '一'});
      expect(doc.canUndo, isFalse);
      expect(doc.canRedo, isFalse);
      expect(doc.undo(), isFalse);
      expect(doc.skeleton, 'C‡1‡D'); // no path back across the barrier
    });

    test('undo and redo never touch identity (身份不动)', () {
      final doc = SlotDocument();
      doc.arrive('‡1‡和‡2‡', {1: '一', 2: '二'});
      doc.editValue(1, '改');
      doc.editSkeleton('‡1‡');
      doc.undo();
      doc.undo();
      expect(doc.identities, {1, 2});
      expect(doc.visibleIdentities, {1, 2});
      doc.redo();
      expect(doc.identities, {1, 2});
      expect(doc.visibleIdentities, {1, 2});
    });
  });
}
