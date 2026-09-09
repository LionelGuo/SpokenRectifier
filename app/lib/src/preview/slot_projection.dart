/// The flat projection of a slot document (ticket 22): the skeleton with
/// every minted sentinel replaced by an inline number chip, its value, and
/// a trailing reservation placeholder — the string the preview editing
/// surface lays out, the caret walks and the platform text input holds.
/// Pure Dart, no Flutter; headless-testable.
///
/// The projection is one string built in one pass:
///
/// ```text
/// 发给␀张三␀一下         (␀ = U+FFFC, a placeholder code unit)
///  ^^^^^^^ skeleton      chip + value + reservation replace each ‡N‡
/// ```
///
/// The chip placeholder is one code unit at the capsule's left end — the
/// number chip's box in the paragraph. It is what makes the dual dock
/// points addressable in flat space: the stop outside a span's left edge
/// is the offset before its placeholder, the stop inside the value is the
/// offset after it (槽内/槽外两个停靠点;20 号票) — two distinct flat
/// positions, so the paragraph's own caret geometry renders both without
/// any model change.
///
/// The reservation placeholder is one more code unit right past the value
/// (at [ProjectedSlot.valueEnd]): an inline spacer the surface sizes to
/// the pill's right padding plus its side breathing room. It carries the
/// capsule's horizontal margins in LAYOUT — the pill's caps may never
/// paint over the neighbours' ink, and the only reservation that leaves
/// the caret and the IME alone (a letter-spaced glyph would push both
/// past the capsule; 23 号验收轮) is a zero-content placeholder. The
/// caret boundary at the value's end sits before it, so the inside-end
/// dock still lands inside the pill.
///
/// Composing (IME pre-edit) text is NOT part of this projection: the
/// surface splices it at the caret when it builds the paragraph and the
/// platform shadow, keeping [SlotProjection.base] stable while a
/// composition is in flight.

library;

import 'slot_document.dart';
import 'slot_editor.dart' show SlotCursor;

/// The object replacement character standing in for a capsule's inline
/// placeholders in the flat text — one code unit, never user-typed. The
/// chip carries it at the capsule's left end; the reservation at the
/// value's right.
const chipPlaceholder = '\uFFFC';

/// One capsule occurrence's coordinates in the projection: where the chip
/// placeholder sits and where the value text runs.
class ProjectedSlot {
  const ProjectedSlot({
    required this.id,
    required this.bodyStart,
    required this.bodyEnd,
    required this.chipAt,
    required this.valueStart,
    required this.valueEnd,
  });

  /// The identity — same number, same slot, wherever it occurs.
  final int id;

  /// The occurrence's leading-`‡` offset in the skeleton.
  final int bodyStart;

  /// Just past the trailing `‡` in the skeleton.
  final int bodyEnd;

  /// The chip placeholder's offset in the projection; the value begins at
  /// `chipAt + 1`.
  final int chipAt;

  /// The value's first code unit in the projection.
  final int valueStart;

  /// Just past the value's last code unit (== valueStart when empty) —
  /// and the reservation placeholder's own offset.
  final int valueEnd;

  @override
  bool operator ==(Object other) =>
      other is ProjectedSlot &&
      other.id == id &&
      other.bodyStart == bodyStart &&
      other.bodyEnd == bodyEnd &&
      other.chipAt == chipAt &&
      other.valueStart == valueStart &&
      other.valueEnd == valueEnd;

  @override
  int get hashCode =>
      Object.hash(ProjectedSlot, id, bodyStart, bodyEnd, chipAt, valueStart);

  @override
  String toString() =>
      'ProjectedSlot(id: $id, body: $bodyStart-$bodyEnd, '
      'flat: $chipAt, value: $valueStart-$valueEnd)';
}

/// A snapshot projection of one document state. Rebuilt cheaply on every
/// model change; nothing here is cached across edits.
class SlotProjection {
  SlotProjection(SlotDocument doc) : slots = List.unmodifiable(_build(doc)) {
    final buffer = StringBuffer();
    var copied = 0;
    for (final slot in slots) {
      buffer
        ..write(doc.skeleton.substring(copied, slot.bodyStart))
        ..write(chipPlaceholder)
        ..write(doc.valueOf(slot.id))
        ..write(chipPlaceholder);
      copied = slot.bodyEnd;
    }
    base = (buffer..write(doc.skeleton.substring(copied))).toString();
  }

  /// The projected text: skeleton body + chip placeholder + value +
  /// reservation placeholder per minted occurrence, in body order.
  /// Unminted same-shapes pass through verbatim (人改同形不铸号,19 号票).
  late final String base;

  /// The minted occurrences in body order, with their flat coordinates.
  final List<ProjectedSlot> slots;

  static Iterable<ProjectedSlot> _build(SlotDocument doc) sync* {
    var shift = 0; // flat − body for everything already walked
    for (final span in doc.fillSlots) {
      final valueLength = doc.valueOf(span.id).length;
      final chipAt = span.start + shift;
      yield ProjectedSlot(
        id: span.id,
        bodyStart: span.start,
        bodyEnd: span.end,
        chipAt: chipAt,
        valueStart: chipAt + 1,
        valueEnd: chipAt + 1 + valueLength,
      );
      // This occurrence grew (or shrank) the text by chip + value +
      // reservation against the sentinel it replaced.
      shift += 2 + valueLength - (span.end - span.start);
    }
  }

  /// A stop's flat position. A body offset strictly inside a minted shape
  /// (never a valid stop) is pulled down to the shape's left edge.
  int cursorToFlat(SlotCursor cursor) {
    if (!cursor.inside) return _outsideToFlat(cursor.at);
    for (final slot in slots) {
      if (slot.bodyStart == cursor.at) {
        return slot.valueStart + cursor.offset;
      }
    }
    return _outsideToFlat(cursor.at); // a stale inside stop: fall home
  }

  int _outsideToFlat(int bodyOffset) {
    var flat = bodyOffset;
    for (final slot in slots) {
      if (slot.bodyEnd <= bodyOffset) {
        // The occurrence replaced its sentinel with chip + value +
        // reservation. The outside-right stop lands past the reservation,
        // clear of the pill's right cap.
        flat += 2 + (slot.valueEnd - slot.valueStart) -
            (slot.bodyEnd - slot.bodyStart);
      } else if (slot.bodyStart < bodyOffset) {
        return slot.chipAt; // mid-shape: down to its left edge
      } else {
        break;
      }
    }
    return flat;
  }

  /// A flat position's stop. Capsule boundaries are ambiguous in flat
  /// space — the chip's offset is both outside-left and inside-0, the
  /// value end both inside-end and outside-right — so [preferInside]
  /// picks the layer; the surface resolves it from context (a tap inside
  /// the pill is an inside stop, a caret mapped home from beyond is not).
  SlotCursor flatToCursor(int flat, {required bool preferInside}) {
    for (final slot in slots) {
      if (flat == slot.chipAt) {
        return preferInside
            ? SlotCursor.inside(at: slot.bodyStart, offset: 0)
            : SlotCursor.outside(slot.bodyStart);
      }
      if (flat > slot.chipAt && flat < slot.valueEnd) {
        return SlotCursor.inside(
          at: slot.bodyStart,
          offset: flat - slot.valueStart,
        );
      }
      if (flat == slot.valueEnd) {
        return preferInside
            ? SlotCursor.inside(
                at: slot.bodyStart,
                offset: slot.valueEnd - slot.valueStart,
              )
            : SlotCursor.outside(slot.bodyEnd);
      }
    }
    // Body: walk back over the occurrences it sits past.
    var bodyOffset = flat;
    for (final slot in slots) {
      final width = 2 + (slot.valueEnd - slot.valueStart);
      if (flat >= slot.valueEnd) {
        bodyOffset -= width - (slot.bodyEnd - slot.bodyStart);
      } else {
        break;
      }
    }
    return SlotCursor.outside(bodyOffset);
  }
}
