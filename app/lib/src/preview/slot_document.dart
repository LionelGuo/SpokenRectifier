/// The preview fill-slot document (ticket 19): the single source of truth
/// the preview editing surface projects from — the skeleton (the body
/// text carrying its `‡N‡` sentinels) plus one map of identity → current
/// value. A fill slot is not a second store: it is a sentinel occurrence
/// projected as a span in the body, edited in place through its value in
/// the map (骨架 + 身份→当前值,填写槽是跨度投影;05 号票).
///
/// The number is the identity (`‡1‡` is slot 1 — the digits are the id,
/// 07 号票). Identities are minted exactly once per round, mechanically
/// from the round's arrival text: every same-shape counts, origin is
/// never distinguished. Values hang on the pin, not the round: the value
/// map persists for the whole preview session and survives rounds where
/// its number is invisible (值挂钉不挂轮;13 号票).
///
/// Sources: the spec's 「预览填写槽」 section over decisions 04/05/13/14.
/// Pure Dart, no Flutter — headless-testable; tickets 20/22 build the
/// cursor graph and the editing surface on top of this model.

library;

/// One `‡N‡` occurrence in a text: the parsed [id] plus its code-unit
/// span. `‡` is U+2021 (one UTF-16 unit) and the digits are ASCII, so
/// the offsets are exact code-unit offsets.
///
/// Two layers read this record: [SlotDocument.fillSlots] projects the
/// editable slots of the current skeleton, and ticket 20's cursor graph
/// walks the same spans as capsule boundaries.
class PlaceholderSpan {
  const PlaceholderSpan({
    required this.id,
    required this.start,
    required this.end,
  });

  /// The identity: the number inside the marks. Same number, same slot,
  /// wherever it occurs (同号多处处处同一串).
  final int id;

  /// Offset of the leading `‡` in the enclosing text.
  final int start;

  /// Offset just past the trailing `‡`.
  final int end;

  @override
  bool operator ==(Object other) =>
      other is PlaceholderSpan &&
      other.id == id &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(PlaceholderSpan, id, start, end);

  @override
  String toString() => 'PlaceholderSpan(id: $id, start: $start, end: $end)';
}

final _sentinel = RegExp(r'‡[0-9]+‡');

/// Scans [text] for `‡` + ASCII digits + `‡` shapes, left to right,
/// non-overlapping (first match wins). Pure and total.
///
/// The census reads strings, not pin events: any same-shape text counts
/// — a shape the user happened to speak into the transcript is
/// mechanically a slot, exactly like a pinned one (同形也抽). The digits
/// parse as a number (`‡01‡` is slot 1) and `‡0‡` mints id 0; the engine
/// never emits those, but the scan is shape-driven and special-cases
/// nothing.
List<PlaceholderSpan> scanSentinels(String text) => [
      for (final match in _sentinel.allMatches(text))
        PlaceholderSpan(
          id: int.parse(match[0]!.substring(1, match[0]!.length - 1)),
          start: match.start,
          end: match.end,
        ),
    ];

/// The preview-stage fill-slot document: skeleton + identity → current
/// value, the round lifecycle (extraction, retention, the stack
/// barrier), and the two projections (fill slots, the substituted
/// confirm text).
///
/// One document lives for one preview session — a fresh session gets a
/// fresh document, so the stacks and the value map die with the session.
class SlotDocument {
  String _skeleton = '';

  /// Minted identity → current value. Persists for the whole preview
  /// session (值挂钉不挂轮): entries survive invisible rounds.
  final Map<int, String> _values = {};

  /// Minted identity → the prefill of its most recent *visible* round.
  /// The baseline [isModified] compares against; moves only at [arrive].
  final Map<int, String> _prefill = {};

  /// The identities extracted from this round's arrival text.
  Set<int> _visible = {};

  final List<_Snapshot> _undo = [];
  final List<_Snapshot> _redo = [];

  /// The body text carrying its sentinels — the half of the source of
  /// truth the user's body edits mutate. Confirmed output comes out of
  /// it by [substitute]; the document never collapses into the flat
  /// string before confirm (确认前不收扁).
  String get skeleton => _skeleton;

  /// The identities of this round — extracted once, from this round's
  /// text, and nothing re-extracts later. A number the model dropped is
  /// simply absent this round: one slot fewer, no empty span patched in,
  /// no position invented (少吐少颗,不补空跨度、不发明落点).
  Set<int> get visibleIdentities => Set.unmodifiable(_visible);

  /// Every identity minted this preview session, in minting order.
  /// [visibleIdentities] is this round's subset; the difference is the
  /// invisible-but-kept set whose values ride out the round (少吐不蒸发).
  Set<int> get identities => Set.unmodifiable(_values.keys);

  /// The fill slots of the current skeleton, in body order: every
  /// sentinel occurrence whose number is minted. An occurrence of a
  /// minted number the user re-typed into the body is that identity's
  /// span like any other; a same-shape with an unminted number is
  /// ordinary text and no slot — post-arrival edits mint nothing.
  List<PlaceholderSpan> get fillSlots => [
        for (final span in scanSentinels(_skeleton))
          if (_values.containsKey(span.id)) span,
      ];

  /// The current value of slot [id] — what confirm substitutes. Empty
  /// string is a real state (an emptied slot, 掏空); unminted numbers
  /// have no slot and read as empty.
  String valueOf(int id) => _values[id] ?? '';

  /// The prefill of [id]'s most recent visible round — '' for unminted
  /// numbers. For an invisible-but-kept identity this stays at the
  /// round it was last seen in, which is exactly the baseline its
  /// modified-ness is judged against when it returns.
  String prefillOf(int id) => _prefill[id] ?? '';

  /// Whether [id]'s value is user-modified: current ≠ last visible
  /// round's prefill — the stateless predicate (13 号票). Emptying counts
  /// as a modification; typing back the old prefill byte-for-byte reads
  /// as untouched. Inherent edge: emptying a slot whose prefill was
  /// already empty is indistinguishable from never touching it, and so
  /// follows the next prefill.
  bool isModified(int id) => _values[id] != _prefill[id];

  /// The confirm output: every minted sentinel occurrence replaced by
  /// its current value — one pass over the skeleton, substituted text
  /// never re-scanned (a value that itself looks like a sentinel lands
  /// verbatim). Empty values leave nothing at their position; any
  /// character inside a value, spaces included, lands as-is; the
  /// neighbours join without trimming; one value per number lands at
  /// every occurrence. An unminted same-shape is ordinary text and
  /// passes through literally. No gate anywhere: partially empty, all
  /// empty, an all-empty skeleton — all substitute (不另设闸).
  String substitute() {
    final buffer = StringBuffer();
    var copied = 0;
    for (final span in scanSentinels(_skeleton)) {
      final value = _values[span.id];
      if (value == null) continue; // unminted shape: stays verbatim
      buffer
        ..write(_skeleton.substring(copied, span.start))
        ..write(value);
      copied = span.end;
    }
    return (buffer..write(_skeleton.substring(copied))).toString();
  }

  /// A round of rectified text arrives at the preview. The first round
  /// and every regeneration — manual reroll, scenario switch, any
  /// trigger — are the same call (一切预览重生成同规则).
  ///
  /// Extraction: the identity set is minted from this round's text, once
  /// — every same-shape counts (同形也抽), the visible set follows the
  /// text (少吐少颗), nothing is patched in or invented. Prefill rows
  /// for numbers not in the text are ignored (表多号); numbers without a
  /// row prefill empty (表缺号→该槽空).
  ///
  /// Retention: the value map persists — a visible number keeps its
  /// value when modified (emptying included; 掏空不被新预填复活),
  /// adopts the fresh prefill when not, and mints now when first seen.
  ///
  /// The skeleton becomes this round's text — body edits die with the
  /// round they were made in (骨架编辑照旧全丢). Both undo stacks clear:
  /// regeneration is the barrier, no gate, no prompt (14 号票).
  void arrive(String rectifiedText, Map<int, String> prefill) {
    _visible = {
      for (final span in scanSentinels(rectifiedText)) span.id,
    };
    for (final id in _visible) {
      final fresh = prefill[id] ?? '';
      // Unminted (null == null) and unmodified both adopt the fresh
      // prefill; a modified value — including an emptied one — stays.
      if (_values[id] == _prefill[id]) _values[id] = fresh;
      _prefill[id] = fresh;
    }
    _skeleton = rectifiedText;
    _undo.clear();
    _redo.clear();
  }

  /// Edit a slot's value — typing inside the capsule, as tickets 20/22
  /// drive it. Unminted numbers are a no-op: identity never grows
  /// through edits (身份不增不减).
  void editValue(int id, String value) {
    if (!_values.containsKey(id)) return;
    _change(() => _values[id] = value);
  }

  /// Replace the skeleton wholesale — the coarse form of a body edit;
  /// ticket 20's cursor-level ops apply through the same machinery.
  void editSkeleton(String skeleton) {
    _change(() => _skeleton = skeleton);
  }

  /// Whether an edit of this round can step back / forward again.
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Step one edit back — values and skeleton move together, in time
  /// order (值与骨架同栈、按时间统一回退). Returns false at the round's
  /// initial state, the bottom of the stack, where another undo is a
  /// no-op. Never crosses a regeneration (the barrier cleared the
  /// stacks) and never touches identity: the minted and visible sets
  /// stay exactly as they are.
  bool undo() {
    if (_undo.isEmpty) return false;
    _redo.add(_Snapshot(_skeleton, _values));
    _restore(_undo.removeLast());
    return true;
  }

  /// Step one undone edit forward again. A new edit drops the redo tail.
  bool redo() {
    if (_redo.isEmpty) return false;
    _undo.add(_Snapshot(_skeleton, _values));
    _restore(_redo.removeLast());
    return true;
  }

  /// One undoable mutation: snapshot before, drop the redo tail, apply.
  /// Every mutating entry point routes through here, which is what keeps
  /// value edits and body edits on one stack in time order — ticket 20's
  /// cursor ops included.
  void _change(void Function() apply) {
    _undo.add(_Snapshot(_skeleton, _values));
    _redo.clear();
    apply();
  }

  void _restore(_Snapshot snapshot) {
    _skeleton = snapshot.skeleton;
    _values
      ..clear()
      ..addAll(snapshot.values);
  }
}

class _Snapshot {
  _Snapshot(this.skeleton, Map<int, String> values)
      : values = Map.of(values);

  final String skeleton;
  final Map<int, String> values;
}
