/// The preview fill-slot document (ticket 19): the single source of truth
/// the preview editing surface projects from — the skeleton (the body
/// text carrying its sentinel forms — the bare `‡N‡` and, since ruling
/// 26, the inline `‡N:值‡`; the scan treats both as slot N's span, and
/// the inline value text itself is never the fact source — values ride
/// the PreviewPrefills event, 29 号票) plus one map of identity →
/// current value. A fill slot is not a second store: it is a sentinel
/// occurrence projected as a span in the body, edited in place through
/// its value in the map (骨架 + 身份→当前值,填写槽是跨度投影;05 号票).
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

/// One sentinel form found by [scanForms]: the response grammar's two
/// spellings (ruling 26) — the bare `‡N‡` and the inline `‡N:值‡` — as
/// one record. The [kind] is shape-driven (a colon was present), never
/// value-driven: `‡1:‡` is an inline form with an empty value and
/// renders as a full capsule, not a circle.
enum ScannedFormKind { bare, inline }

/// One classified form: the parsed [id], its code-unit span, and — for
/// the inline kind — the value verbatim, possibly still growing
/// ([unclosed]: the closing `‡` has not arrived; the value keeps the
/// characters accumulated after the colon, ruling 26's streaming rule).
class ScannedForm {
  const ScannedForm({
    required this.id,
    required this.kind,
    required this.start,
    required this.end,
    required this.value,
    required this.unclosed,
  });

  /// The identity: the number between the marks, leading zeros folded
  /// (`‡01‡` is slot 1). Same number, same slot, wherever it occurs.
  final int id;

  final ScannedFormKind kind;

  /// Offset of the leading `‡` in the enclosing text.
  final int start;

  /// Just past the form's last character: the closing `‡`, or the text's
  /// end when [unclosed].
  final int end;

  /// The inline form's value, verbatim — everything after the colon up
  /// to the closing `‡` (newlines mechanically kept; the taught contract
  /// only asks the model not to write them). Empty for the bare kind.
  final String value;

  /// An inline form whose closing `‡` never came: still a slot, its
  /// value the characters accumulated so far (the stream's growing
  /// capsule).
  final bool unclosed;

  PlaceholderSpan get span => PlaceholderSpan(id: id, start: start, end: end);

  @override
  bool operator ==(Object other) =>
      other is ScannedForm &&
      other.id == id &&
      other.kind == kind &&
      other.start == start &&
      other.end == end &&
      other.value == value &&
      other.unclosed == unclosed;

  @override
  int get hashCode =>
      Object.hash(ScannedForm, id, kind, start, end, value, unclosed);

  @override
  String toString() =>
      'ScannedForm(id: $id, kind: $kind, start: $start, end: $end, '
      'value: $value, unclosed: $unclosed)';
}

/// The largest identity the engine's rows can carry (`u32`) — a number
/// beyond it is not an identity on either side of the bridge: the engine
/// drops the row and leaves the text as body, and the scan mirrors that
/// (an overflow shape is literal text, never a slot).
const maxSlotId = 0xFFFFFFFF;

/// One greedy left-to-right pass over a text, classifying every code
/// unit into body or form — the Dart mirror of the engine's
/// `scan_forms` (`crates/engine/src/prefill.rs`), so the shell's
/// identity set can never disagree with the rows the engine delivered:
///
/// - bare `‡N‡` and inline `‡N:值‡` are both forms; the inline value
///   runs from the colon to the next `‡` (newlines kept), or to the
///   text's end when it never closes (unclosed — still a form);
/// - `‡` + ASCII digits, settled by `:` or `‡`; a run broken by any
///   other character was never a form and stays literal body text —
///   including a trailing bare `‡N` run, exactly the fragment the
///   engine's splitter holds back off the chunk stream;
/// - `‡‡` reopens at the second mark; `‡:` with no digits is literal;
/// - leading zeros fold; a number beyond [maxSlotId] drops the form and
///   leaves the text as body (the engine's overflow rule);
/// - a `‡` that starts no form is literal body text, byte-for-byte.
///
/// Pure and total; code-unit offsets (`‡` is U+2021, one unit). The
/// value is carried for the STREAM face's growing capsules only — the
/// preview's fact source stays the PreviewPrefills event, never the
/// body text (29 号票).
List<ScannedForm> scanForms(String text) {
  final forms = <ScannedForm>[];
  // State: -1 body, >= 0 the digit run's opening `‡` offset; _valueStart
  // >= 0 marks the value state (offset of its first code unit).
  var start = -1;
  var digitsEnd = 0;
  var valueStart = -1;

  void close({required int end, required bool unclosed}) {
    final digits = text.substring(start + 1, digitsEnd);
    final id = int.tryParse(digits);
    // Beyond u32 the engine drops the row and leaves the text as body;
    // the scan agrees, so the shape never mints here either.
    if (id == null || id > maxSlotId) return;
    final inline = valueStart >= 0;
    // The inline value runs to just before the closing `‡`; an unclosed
    // form keeps everything to the text's end.
    final valueEnd = inline ? (unclosed ? text.length : end - 1) : 0;
    forms.add(
      ScannedForm(
        id: id,
        kind: inline ? ScannedFormKind.inline : ScannedFormKind.bare,
        start: start,
        end: end,
        value: inline ? text.substring(valueStart, valueEnd) : '',
        unclosed: unclosed,
      ),
    );
  }

  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (valueStart >= 0) {
      if (c == 0x2021) {
        final end = i + 1;
        close(end: end, unclosed: false);
        start = -1;
        valueStart = -1;
      }
      continue; // everything else is value, newlines included
    }
    if (start >= 0) {
      if (c >= 0x30 && c <= 0x39) {
        digitsEnd = i + 1;
      } else if (c == 0x3A && digitsEnd > start + 1) {
        valueStart = i + 1;
      } else if (c == 0x2021 && digitsEnd > start + 1) {
        final end = i + 1;
        close(end: end, unclosed: false);
        start = -1;
      } else if (c == 0x2021) {
        start = i; // `‡‡`: the first was literal; this one opens anew
        digitsEnd = i + 1;
      } else {
        start = -1; // a breaking character: the run was never a form
      }
      continue;
    }
    if (c == 0x2021) {
      start = i;
      digitsEnd = i + 1;
    }
  }
  if (valueStart >= 0) {
    close(end: text.length, unclosed: true); // unclosed: keep the tail
  }
  // A trailing bare `‡N` run is body residue — never a form (the engine
  // holds it off the stream; a finished response releases it as text).
  return forms;
}

/// Scans [text] for its sentinel forms — both spellings, [scanForms] —
/// as spans. Pure and total.
///
/// The census reads strings, not pin events: any same-shape text counts
/// — a shape the user happened to speak into the transcript is
/// mechanically a slot, exactly like a pinned one (同形也抽). The digits
/// parse as a number (`‡01‡` is slot 1) and `‡0‡` mints id 0; the
/// engine never emits those, but the scan is shape-driven and
/// special-cases nothing.
List<PlaceholderSpan> scanSentinels(String text) => [
  for (final form in scanForms(text)) form.span,
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

  /// The confirm-time slot table (占位符钉入入库): one row per identity
  /// with a live occurrence in the skeleton — exactly the slots whose
  /// values [substitute] actually lands in the inserted text — in
  /// first-occurrence order. Each row carries the identity's number,
  /// the prefill of its most recent visible round ('' = none
  /// delivered), and the current value the confirm substitutes
  /// (possibly ''). Same-number occurrences fold to one row; a minted
  /// identity whose occurrences the body edits deleted contributes
  /// nothing and gets no row.
  List<({int number, String prefill, String value})> confirmRows() {
    final seen = <int>{};
    return [
      for (final span in fillSlots)
        if (seen.add(span.id))
          (
            number: span.id,
            prefill: prefillOf(span.id),
            value: valueOf(span.id),
          ),
    ];
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
    _visible = {for (final span in scanSentinels(rectifiedText)) span.id};
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
    _restoredMark = null;
  }

  /// One undoable edit touching any combination of skeleton and values
  /// as a single atomic step — ticket 20's cursor operations go through
  /// here, so one keystroke is one undo step even when it deletes body
  /// text and value text together. Same rules as the two coarse forms:
  /// unminted ids in [values] are ignored (身份不增不减), and an edit
  /// that would change nothing pushes no snapshot.
  ///
  /// [mark] is opaque to the document — the editor passes the cursors
  /// its edit began and ended at, and [undo]/[redo] hand them back via
  /// [restoredMark] so history walks the caret with the change.
  void edit({String? skeleton, Map<int, String>? values, Object? mark}) {
    final changesNothing =
        (skeleton == null || skeleton == _skeleton) &&
        (values == null ||
            values.entries.every(
              (e) => !_values.containsKey(e.key) || _values[e.key] == e.value,
            ));
    if (changesNothing) return;
    _change(() {
      if (skeleton != null) _skeleton = skeleton;
      if (values != null) {
        for (final e in values.entries) {
          if (_values.containsKey(e.key)) _values[e.key] = e.value;
        }
      }
    }, mark);
  }

  /// Edit a slot's value — typing inside the capsule, as tickets 20/22
  /// drive it. Unminted numbers are a no-op: identity never grows
  /// through edits (身份不增不减).
  void editValue(int id, String value) => edit(values: {id: value});

  /// Replace the skeleton wholesale — the coarse form of a body edit;
  /// ticket 20's cursor ops apply the fine-grained form through [edit].
  void editSkeleton(String skeleton) => edit(skeleton: skeleton);

  /// Whether an edit of this round can step back / forward again.
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// The mark carried by the entry the last [undo]/[redo] restored —
  /// the editor's cursors for that edit. Null when the stacks have not
  /// been walked since the last edit or arrival, or the entry carried
  /// no mark (the coarse forms).
  Object? get restoredMark => _restoredMark;
  Object? _restoredMark;

  /// Step one edit back — values and skeleton move together, in time
  /// order (值与骨架同栈、按时间统一回退). Returns false at the round's
  /// initial state, the bottom of the stack, where another undo is a
  /// no-op. Never crosses a regeneration (the barrier cleared the
  /// stacks) and never touches identity: the minted and visible sets
  /// stay exactly as they are. The restored entry's mark lands in
  /// [restoredMark].
  bool undo() {
    if (_undo.isEmpty) return false;
    final popped = _undo.removeLast();
    _redo.add(_Snapshot(_skeleton, _values, popped.mark));
    _restore(popped);
    _restoredMark = popped.mark;
    return true;
  }

  /// Step one undone edit forward again. A new edit drops the redo
  /// tail. The restored entry's mark lands in [restoredMark].
  bool redo() {
    if (_redo.isEmpty) return false;
    final popped = _redo.removeLast();
    _undo.add(_Snapshot(_skeleton, _values, popped.mark));
    _restore(popped);
    _restoredMark = popped.mark;
    return true;
  }

  /// One undoable mutation: snapshot before, drop the redo tail, apply.
  /// Every mutating entry point routes through here, which is what keeps
  /// value edits and body edits on one stack in time order — ticket 20's
  /// cursor ops included. The snapshot carries the edit's [mark]
  /// (opaque here) so history can walk the editor's caret with it.
  void _change(void Function() apply, Object? mark) {
    _undo.add(_Snapshot(_skeleton, _values, mark));
    _redo.clear();
    _restoredMark = null;
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
  _Snapshot(this.skeleton, Map<int, String> values, this.mark)
    : values = Map.of(values);

  final String skeleton;
  final Map<int, String> values;

  /// Opaque rider from the edit that left this state — the editor's
  /// cursors for that edit (where it began, where it ended).
  final Object? mark;
}
