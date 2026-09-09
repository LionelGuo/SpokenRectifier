/// The cursor graph and editing discipline over the slot document
/// (ticket 20): where the caret can rest and what each key does there.
/// Pure logic on top of [SlotDocument] — no Flutter, headless-testable;
/// ticket 22's surface maps geometry onto stops and keys onto these
/// operations.
///
/// Stops (停靠点): every code-unit boundary of the body is an outside
/// stop, except those strictly inside a minted `‡N‡` shape; each span
/// additionally carries inside stops — offsets 0..n of its value — so
/// both edges of a span are two stops on two layers (每个跨度边界两个
/// 停靠点,槽内/槽外;08 号票). An empty slot has a single inside stop:
/// left and right are the same state (空槽槽内左右同一状态). Unminted
/// same-shapes are ordinary text with ordinary stops (人改同形不铸号,
/// 19 号票).
///
/// The editing discipline (spec 「预览填写槽」光标条,源:05/08 号票):
///
/// - ←/→ walk stops one at a time. Both layers accept insertion, and an
///   insertion at an outside stop never lands in a span's value (槽外
///   插入绝不落进跨度值).
/// - Outside and flush against a span, Backspace at the right edge and
///   Delete at the left edge step into the slot first; only the next
///   press deletes (先进槽内、再按才删). Inside at an edge, both keys
///   pass through and step out of the slot without touching the body
///   (槽内贴边透传步出槽外) — an empty slot steps out to the side the
///   key faces, so it is transparent to traversal.
/// - A selection only ever touches the characters it covers (选区只动
///   选中的字): spans are never deleted (跨度不删) — a covered value
///   part is removed from the value, and a fully covered slot is
///   emptied, which is also how a mis-pin is taken back (掏空取回误钉;
///   不提供删跨度). Characters typed over a selection land in the layer
///   the selection starts in (新字落选区起点所在层).
/// - Copy/cut yield the visible characters only — covered body text and
///   covered value text, never the identity (身份不出模型). Enter
///   inside a slot is an ordinary insertion of `\n` (槽内 Enter 是
///   换行).
///
/// Every mutation is one atomic [SlotDocument.edit] — one keystroke is
/// one undo step even when it touches body and values together (值与
/// 骨架同栈、按时间统一回退,19 号票). Undo/redo keep the caret on a
/// valid stop; arriving text (regeneration) resets it and drops the
/// selection.

library;

import 'slot_document.dart';

/// One stop of the cursor graph: a position the caret — or a selection
/// anchor — can rest at. Outside stops carry a body offset; inside
/// stops carry the value offset of one occurrence, keyed by the
/// code-unit offset of its leading `‡`, which is unique per occurrence
/// so two occurrences of one identity have their own stops (同号多处
/// 的两份停靠点).
class SlotCursor {
  const SlotCursor.outside(int bodyOffset)
    : inside = false,
      at = bodyOffset,
      offset = 0;

  const SlotCursor.inside({required this.at, required this.offset})
    : inside = true;

  /// Whether this is a stop inside a slot's value, as opposed to a stop
  /// in the body.
  final bool inside;

  /// The body offset when outside; the occurrence's leading-`‡` offset
  /// when inside. For an inside stop this is also its body-facing
  /// coordinate: everything before it in the body lies before the slot.
  final int at;

  /// The value offset; 0 for outside stops.
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is SlotCursor &&
      other.inside == inside &&
      other.at == at &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(SlotCursor, inside, at, offset);

  @override
  String toString() => inside
      ? 'SlotCursor.inside(at: $at, offset: $offset)'
      : 'SlotCursor.outside($at)';
}

/// The editing operations layer over a [SlotDocument]: the stop
/// sequence, the caret and selection, and the key semantics on top of
/// the document's atomic edits.
///
/// The caret and anchor always sit on valid stops of the current
/// document — every operation ends by placing them — so a command can
/// read spans and offsets fresh each time (the spans are a projection,
/// never stored here).
class SlotEditor {
  SlotEditor(this.doc) : _caret = const SlotCursor.outside(0);

  /// The document being edited. The surface reads its skeleton, spans
  /// and values for rendering; mutations go through this editor (or the
  /// document's coarse API), never both halfway through a keystroke.
  final SlotDocument doc;

  SlotCursor _caret;
  SlotCursor? _anchor;

  /// The caret's stop.
  SlotCursor get caret => _caret;

  /// The selection's anchor, when one is being made.
  SlotCursor? get anchor => _anchor;

  /// Whether anchor and caret rest on different stops.
  bool get hasSelection => _anchor != null && _anchor != _caret;

  bool get canUndo => doc.canUndo;
  bool get canRedo => doc.canRedo;

  /// The stops in reading order: each body offset, with every minted
  /// span contributing its inside stops right after its outside-left
  /// stop — so the sequence around a span reads
  /// … outside-left, value 0…n, outside-right …. Adjacent spans share
  /// the one between-stop; an empty slot contributes a single inside
  /// stop; unminted shapes contribute nothing but ordinary body stops.
  List<SlotCursor> get stops {
    final skeleton = doc.skeleton;
    final byStart = {for (final span in doc.fillSlots) span.start: span};
    final result = <SlotCursor>[];
    for (var o = 0; o <= skeleton.length; o++) {
      result.add(SlotCursor.outside(o));
      final span = byStart[o];
      if (span != null) {
        final n = doc.valueOf(span.id).length;
        for (var k = 0; k <= n; k++) {
          result.add(SlotCursor.inside(at: o, offset: k));
        }
        o = span.end - 1; // the loop's o++ lands on span.end
      }
    }
    return result;
  }

  /// The selection's two ends in reading order, or null when
  /// collapsed.
  (SlotCursor, SlotCursor)? get selectionEdges {
    if (!hasSelection) return null;
    final stops = this.stops;
    final anchorIndex = stops.indexOf(_anchor!);
    final caretIndex = stops.indexOf(_caret);
    return anchorIndex <= caretIndex ? (_anchor!, _caret) : (_caret, _anchor!);
  }

  /// Collapse the caret onto [stop] — a tap, or any placement the
  /// surface computes. The stop is normalized: an offset that is not a
  /// stop snaps to the nearest valid one at or before it.
  void place(SlotCursor stop) {
    _caret = _normalize(stop);
    _anchor = null;
  }

  /// Begin a selection from [anchor] to [caret]; equal stops collapse.
  /// Both are normalized like [place].
  void select(SlotCursor anchor, SlotCursor caret) {
    _anchor = _normalize(anchor);
    _caret = _normalize(caret);
    if (_anchor == _caret) _anchor = null;
  }

  /// ← — collapse onto the selection's start, or walk one stop left.
  /// Clamped at the first stop.
  void moveLeft() {
    if (hasSelection) {
      _caret = selectionEdges!.$1;
      _anchor = null;
      return;
    }
    final stops = this.stops;
    final i = stops.indexOf(_normalize(_caret));
    if (i > 0) _caret = stops[i - 1];
  }

  /// → — collapse onto the selection's end, or walk one stop right.
  /// Clamped at the last stop.
  void moveRight() {
    if (hasSelection) {
      _caret = selectionEdges!.$2;
      _anchor = null;
      return;
    }
    final stops = this.stops;
    final i = stops.indexOf(_normalize(_caret));
    if (i >= 0 && i < stops.length - 1) _caret = stops[i + 1];
  }

  /// Backspace. Over a selection: delete the selection. At the caret
  /// outside, flush against a span's right edge: step into the slot
  /// first, delete on the next press (槽外贴边 Backspace 右侧先进槽
  /// 内、再按才删). At the caret inside, against the value's left edge
  /// (an empty slot always): pass through and step out to the left
  /// (槽内贴边透传步出槽外).
  void backspace() {
    final from = selectionEdges?.$1 ?? _normalize(_caret);
    if (hasSelection) {
      _deleteSelection();
      return;
    }
    final caret = _normalize(_caret);
    if (caret.inside) {
      final span = _spanAt(caret.at);
      if (span == null) {
        _caret = caret; // a stale stop; nothing to act on
        return;
      }
      if (caret.offset == 0) {
        _caret = SlotCursor.outside(span.start);
      } else {
        final value = doc.valueOf(span.id);
        final k = caret.offset;
        final landed = SlotCursor.inside(at: span.start, offset: k - 1);
        doc.edit(
          values: {span.id: value.substring(0, k - 1) + value.substring(k)},
          mark: (from, landed),
        );
        _caret = landed;
      }
      return;
    }
    final entering = _spanEndingAt(caret.at);
    if (entering != null) {
      _caret = SlotCursor.inside(
        at: entering.start,
        offset: doc.valueOf(entering.id).length,
      );
      return;
    }
    if (caret.at > 0) {
      final o = caret.at;
      final next =
          doc.skeleton.substring(0, o - 1) + doc.skeleton.substring(o);
      final landed = _normalizeIn(
        next,
        doc.identities,
        doc.valueOf,
        SlotCursor.outside(o - 1),
      );
      doc.edit(skeleton: next, mark: (from, landed));
      _caret = landed;
    }
  }

  /// Forward delete. Over a selection: delete the selection. At the
  /// caret outside, flush against a span's left edge: step into the
  /// slot first (槽外贴边 Delete 左侧先进槽内、再按才删). At the caret
  /// inside, against the value's right edge (an empty slot always):
  /// pass through and step out to the right (槽内贴边透传步出槽外).
  void deleteForward() {
    final from = selectionEdges?.$1 ?? _normalize(_caret);
    if (hasSelection) {
      _deleteSelection();
      return;
    }
    final caret = _normalize(_caret);
    if (caret.inside) {
      final span = _spanAt(caret.at);
      if (span == null) {
        _caret = caret;
        return;
      }
      final n = doc.valueOf(span.id).length;
      if (caret.offset == n) {
        _caret = SlotCursor.outside(span.end);
      } else {
        final value = doc.valueOf(span.id);
        final k = caret.offset;
        final landed = SlotCursor.inside(at: span.start, offset: k);
        doc.edit(
          values: {span.id: value.substring(0, k) + value.substring(k + 1)},
          mark: (from, landed),
        );
        _caret = landed;
      }
      return;
    }
    final entering = _spanAt(caret.at);
    if (entering != null) {
      _caret = SlotCursor.inside(at: entering.start, offset: 0);
      return;
    }
    if (caret.at < doc.skeleton.length) {
      final o = caret.at;
      final next =
          doc.skeleton.substring(0, o) + doc.skeleton.substring(o + 1);
      final landed = _normalizeIn(
        next,
        doc.identities,
        doc.valueOf,
        SlotCursor.outside(o),
      );
      doc.edit(skeleton: next, mark: (from, landed));
      _caret = landed;
    }
  }

  /// Type [text] at the caret, or over the selection — the new
  /// characters land in the layer the selection starts in (新字落选区
  /// 起点所在层). An outside insertion never lands in a span's value; a
  /// minted same-shape the text happens to spell is that identity's
  /// occurrence like any other, while an unminted one stays ordinary
  /// text (post-arrival edits mint nothing, 19 号票). Enter is
  /// `insert('\n')` (槽内 Enter 是换行).
  void insert(String text) {
    if (text.isEmpty) return;
    if (hasSelection) {
      _replaceSelection(text);
      return;
    }
    final from = _normalize(_caret);
    final caret = from;
    if (caret.inside) {
      final span = _spanAt(caret.at);
      if (span == null) {
        _caret = caret;
        return;
      }
      final value = doc.valueOf(span.id);
      final k = caret.offset;
      final landed = SlotCursor.inside(
        at: span.start,
        offset: k + text.length,
      );
      doc.edit(
        values: {span.id: value.substring(0, k) + text + value.substring(k)},
        mark: (from, landed),
      );
      _caret = landed;
      return;
    }
    final o = caret.at;
    final next = doc.skeleton.substring(0, o) + text + doc.skeleton.substring(o);
    final landed = _normalizeIn(
      next,
      doc.identities,
      doc.valueOf,
      SlotCursor.outside(o + text.length),
    );
    doc.edit(skeleton: next, mark: (from, landed));
    _caret = landed;
  }

  /// The selection's visible characters (复制得到可见字,身份不出模
  /// 型): covered body text and covered value text, in reading order —
  /// never the `‡N‡` marks. Empty when collapsed. Pure: the document
  /// is not touched.
  String copy() {
    final edges = selectionEdges;
    if (edges == null) return '';
    final (a, b) = edges;
    final coverage = _coverage(a, b);
    final segments = <(int, String)>[
      for (final (from, to) in coverage.bodyRuns)
        (from, doc.skeleton.substring(from, to)),
      for (final covered in coverage.coveredSpans)
        (
          covered.span.start,
          doc.valueOf(covered.span.id).substring(covered.left, covered.right),
        ),
    ]..sort((x, y) => x.$1.compareTo(y.$1));
    return [for (final (_, text) in segments) text].join();
  }

  /// Copy, then delete the selection — one atomic edit, one undo step.
  String cut() {
    final text = copy();
    if (hasSelection) _deleteSelection();
    return text;
  }

  /// Step one edit back. The stacks live in the document; the caret
  /// travels to where the undone edit began — every edit records the
  /// cursors it started and ended at on its snapshot, and history walks
  /// the caret with the change (undo 回到该步修改开始前,2026-09-09
  /// ruling). A mark-less entry (the coarse forms) keeps the caret,
  /// snapped onto a valid stop. The selection collapses either way.
  bool undo() {
    if (!doc.undo()) return false;
    final mark = doc.restoredMark;
    if (mark is (SlotCursor, SlotCursor)) _caret = _normalize(mark.$1);
    _anchor = null;
    return true;
  }

  /// Step one undone edit forward again — the caret lands behind the
  /// redone modification (重做后光标到该步修改末尾,2026-09-09 ruling).
  bool redo() {
    if (!doc.redo()) return false;
    final mark = doc.restoredMark;
    if (mark is (SlotCursor, SlotCursor)) _caret = _normalize(mark.$2);
    _anchor = null;
    return true;
  }

  /// A round of rectified text arrives: the document mints, retains,
  /// and raises the barrier (19 号票); the editor goes home — caret at
  /// the body's start, selection dropped.
  void arrive(String rectifiedText, Map<int, String> prefill) {
    doc.arrive(rectifiedText, prefill);
    _caret = const SlotCursor.outside(0);
    _anchor = null;
  }

  /// Delete the selection: its body characters go from the skeleton,
  /// its covered value parts go from the values (a fully covered slot
  /// is emptied — 掏空取回误钉), and the caret lands on the selection's
  /// start. Spans are never removed (不提供删跨度).
  void _deleteSelection() {
    final (a, b) = selectionEdges!;
    _caret = _applySelection(_coverage(a, b), a, null);
    _anchor = null;
  }

  /// Delete the selection and type [text] into the layer its start
  /// rests in (新字落选区起点所在层).
  void _replaceSelection(String text) {
    final (a, b) = selectionEdges!;
    _caret = _applySelection(_coverage(a, b), a, text);
    _anchor = null;
  }

  /// Apply a selection's deletions — body runs, and per identity the
  /// union of its occurrences' covered value parts — optionally
  /// splicing [insertion] into the start's layer, all as one atomic
  /// edit. Returns where the caret lands: the selection's start, moved
  /// past any same-identity deletion that now lies before it.
  SlotCursor _applySelection(
    _Coverage coverage,
    SlotCursor a,
    String? insertion,
  ) {
    // Skeleton: drop the covered body runs, right to left. Offsets of
    // the runs never precede the selection's start, so the start's body
    // coordinate stays valid in the result.
    String? skeleton;
    if (coverage.bodyRuns.isNotEmpty) {
      var next = doc.skeleton;
      for (final (from, to) in coverage.bodyRuns.reversed) {
        next = next.substring(0, from) + next.substring(to);
      }
      skeleton = next;
    }

    // Values: per identity, one shared string — occurrences may cover
    // overlapping parts of it, so merge before deleting (right to
    // left, over non-overlapping ranges).
    final values = <int, String>{};
    for (final entry in coverage.byId.entries) {
      var value = doc.valueOf(entry.key);
      for (final (from, to) in _mergeRanges(entry.value).reversed) {
        value = value.substring(0, from) + value.substring(to);
      }
      values[entry.key] = value;
    }

    var caret = a;
    if (a.inside) {
      final id = _spanAt(a.at)!.id;
      final shift = _mergeRanges(coverage.byId[id] ?? const <(int, int)>[])
          .fold(0, (sum, range) => sum + _overlapBefore(range, a.offset));
      final k = a.offset - shift;
      if (insertion != null) {
        final value = values[id] ?? doc.valueOf(id);
        values[id] = value.substring(0, k) + insertion + value.substring(k);
      }
      caret = SlotCursor.inside(at: a.at, offset: k + (insertion?.length ?? 0));
    } else {
      if (insertion != null) {
        final base = skeleton ?? doc.skeleton;
        skeleton = base.substring(0, a.at) + insertion + base.substring(a.at);
      }
      caret = SlotCursor.outside(a.at + (insertion?.length ?? 0));
    }
    final landed = _normalizeIn(
      skeleton ?? doc.skeleton,
      doc.identities,
      (id) => values[id] ?? doc.valueOf(id),
      caret,
    );
    doc.edit(skeleton: skeleton, values: values, mark: (a, landed));
    return landed;
  }

  /// What a selection from [a] to [b] (reading order) covers: the body
  /// runs between them, and per occurrence the covered value part.
  /// Selection edges are always valid stops, so a span is covered
  /// whole or not at all — never cut through the middle of its marks.
  _Coverage _coverage(SlotCursor a, SlotCursor b) {
    // An inside edge's `at` is its span's start: its body-facing
    // coordinate. Everything covered lies between the two coordinates.
    final aBody = a.at;
    final bBody = b.at;

    final bodyRuns = <(int, int)>[];
    final coveredSpans = <_CoveredSpan>[];
    var runStart = aBody;
    for (final span in doc.fillSlots) {
      final aInThis = a.inside && a.at == span.start;
      final bInThis = b.inside && b.at == span.start;
      if (span.end <= aBody || (span.start >= bBody && !bInThis)) continue;
      final n = doc.valueOf(span.id).length;
      // A span straddling an edge without the edge resting inside it
      // cannot happen: that edge would not be a stop. So the defaults
      // below (cover the whole value) are exact whenever the edge is
      // not inside this occurrence.
      coveredSpans.add(
        _CoveredSpan(span, aInThis ? a.offset : 0, bInThis ? b.offset : n),
      );
      if (span.start > runStart) bodyRuns.add((runStart, span.start));
      runStart = span.end;
    }
    if (bBody > runStart) bodyRuns.add((runStart, bBody));
    return _Coverage(bodyRuns, coveredSpans);
  }

  /// Snap [stop] onto a valid stop of the current document: clamp
  /// offsets into range, pull a body offset inside a minted shape down
  /// to the shape's left edge, clamp a value offset into the value,
  /// and fall back to the body when the occurrence is gone.
  SlotCursor _normalize(SlotCursor stop) =>
      _normalizeIn(doc.skeleton, doc.identities, doc.valueOf, stop);

  /// The same snap against a candidate state — the skeleton and value
  /// lookup an edit is about to install — so the caret an edit leaves
  /// can be computed before the edit applies: it rides the undo
  /// snapshot as the mark history restores on undo/redo.
  SlotCursor _normalizeIn(
    String skeleton,
    Set<int> minted,
    String Function(int id) valueAt,
    SlotCursor stop,
  ) {
    final spans = [
      for (final span in scanSentinels(skeleton))
        if (minted.contains(span.id)) span,
    ];
    if (stop.inside) {
      for (final span in spans) {
        if (span.start == stop.at) {
          var k = stop.offset;
          final n = valueAt(span.id).length;
          if (k < 0) k = 0;
          if (k > n) k = n;
          return SlotCursor.inside(at: stop.at, offset: k);
        }
      }
    }
    var o = stop.at;
    if (o < 0) o = 0;
    if (o > skeleton.length) o = skeleton.length;
    for (final span in spans) {
      if (span.start < o && o < span.end) {
        o = span.start; // strictly inside a shape: down to its left edge
        break;
      }
    }
    return SlotCursor.outside(o);
  }

  PlaceholderSpan? _spanAt(int start) {
    for (final span in doc.fillSlots) {
      if (span.start == start) return span;
    }
    return null;
  }

  PlaceholderSpan? _spanEndingAt(int end) {
    for (final span in doc.fillSlots) {
      if (span.end == end) return span;
    }
    return null;
  }
}

/// What a selection covers: the body runs to delete from the skeleton,
/// and the per-occurrence covered value parts.
class _Coverage {
  _Coverage(this.bodyRuns, this.coveredSpans);

  /// Skeleton ranges, in order, pairwise disjoint, never cutting into
  /// a minted shape.
  final List<(int, int)> bodyRuns;

  /// The covered occurrences, in skeleton order.
  final List<_CoveredSpan> coveredSpans;

  /// Covered value parts grouped by identity — occurrences of one
  /// identity share a string, so their parts merge before deletion.
  Map<int, List<(int, int)>> get byId {
    final byId = <int, List<(int, int)>>{};
    for (final covered in coveredSpans) {
      byId.putIfAbsent(covered.span.id, () => []).add((
        covered.left,
        covered.right,
      ));
    }
    return byId;
  }
}

class _CoveredSpan {
  _CoveredSpan(this.span, this.left, this.right);

  final PlaceholderSpan span;

  /// The covered value range [left, right).
  final int left;
  final int right;
}

/// Merge [ranges] into ascending, pairwise-disjoint ranges — the union
/// (occurrences of one identity may cover overlapping parts of the
/// shared value).
List<(int, int)> _mergeRanges(List<(int, int)> ranges) {
  final sorted = ranges.toList()..sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final (from, to) in sorted) {
    if (merged.isNotEmpty && from <= merged.last.$2) {
      final last = merged.removeLast();
      merged.add((last.$1, to > last.$2 ? to : last.$2));
    } else {
      merged.add((from, to));
    }
  }
  return merged;
}

/// How much of [range] lies before offset [k] — what a point at [k]
/// shifts back when the range is deleted. A range containing [k]
/// returns `k - from`: the point falls to the range's start.
int _overlapBefore((int, int) range, int k) {
  final from = range.$1 < k ? range.$1 : k;
  final to = range.$2 < k ? range.$2 : k;
  return to - from;
}
