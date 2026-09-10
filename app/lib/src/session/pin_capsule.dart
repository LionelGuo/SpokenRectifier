/// The placeholder capsule visuals (ticket 21, widened for ruling 26's
/// inline grammar in ticket 29): the flat capsule family the sentinels
/// project as on the session surface — never the bare `‡N‡` four
/// characters, nor the inline `‡N:值‡` chrome. While listening and
/// rectifying the BARE sentinel collapses to the number circle (号圆) —
/// the family's own degenerate capsule, its width squeezed until the
/// two caps meet as one circle (2026-09-09 反馈九: both faces share one
/// positional strategy — side breathing reserved in layout on both
/// sides, absorbed at the line edges, the same line-ink anchor). The
/// circle itself is PAINTED by the stream surface's foreground layer
/// onto the spacer this module reserves, centered on its line's text
/// ink — the same anchor the preview's fill capsules use, in the same
/// frame the layout happens (23 号验收轮: the WidgetSpan's own middle
/// alignment follows font metrics and sat visibly off on real fallback
/// chains, and any post-frame correction lags the stream's constant
/// re-layout).
///
/// The INLINE form is the family's full capsule even on the stream face
/// (ruling 26's streaming design): the moment the scan sees `‡N:` the
/// capsule exists — number plus the value still growing — and the value
/// is real text in the paragraph, so the capsule the stream grows is
/// byte-for-byte the capsule the preview opens with. The projection
/// below lays the stream text out the way the preview's flat projection
/// does (chip placeholder + value + reservation), so both faces query
/// the same string they lay out.
///
/// Family rules (spec 「预览填写槽·视觉」, 08 号五轮): all-flat — no
/// border, no shadow; the number is plain small text; the empty-state
/// look is shared with the preview fill slot; the capsule never carries
/// data-layer characters (两侧间距走视觉).

library;

import '../design/tokens.dart';
import '../preview/slot_document.dart';
import '../preview/slot_projection.dart' show ProjectedSlot, chipPlaceholder;

/// The marker's own painted width for [id]: the family's capsule
/// squeezed to its degenerate form — one digit exactly the pill's
/// height, the two caps meeting as one circle; wider numbers grow
/// into the family's stadium of the same cap radius instead of
/// clipping (2026-09-09 反馈九: the stream marker IS a capsule, just
/// narrow).
double pinCapsuleWidth(int id) {
  final digits = id.toString().length;
  return digits <= 1 ? SrCapsule.height : SrCapsule.height + (digits - 1) * 7.0;
}

/// The spacer's inline reservation for [id]: the marker's own width
/// plus the family's side breathing on both sides — the same
/// [SrCapsule.sidePad] the preview reserves around its pills, carried
/// here in layout by the one span the stream face has. The surface's
/// painter places the marker inside, absorbing a side's breathing
/// when the marker sits at that line edge (行首/行尾不留空位), and
/// consecutive markers are placed as one run sharing a single slack,
/// so the gaps between them never double up (反馈十一).
double pinCapsuleReservation(int id) =>
    pinCapsuleWidth(id) + 2 * SrCapsule.sidePad;

/// One bare sentinel's circle in the stream projection: its identity
/// and the code-unit offset of its placeholder in [StreamMarkers.flat].
class StreamCircle {
  const StreamCircle({required this.id, required this.at});

  final int id;
  final int at;

  @override
  bool operator ==(Object other) =>
      other is StreamCircle && other.id == id && other.at == at;

  @override
  int get hashCode => Object.hash(StreamCircle, id, at);

  @override
  String toString() => 'StreamCircle(id: $id, at: $at)';
}

/// The stream face's flat projection of one text: the string its
/// paragraph lays out, with every bare sentinel as one placeholder and
/// every inline form as chip placeholder + value + reservation — the
/// same shape the preview's [SlotProjection] gives its occurrences, so
/// the stream's growing capsule and the preview's fill capsule share
/// one geometry. Pure data; the span tree and the painters are the
/// surface's (slot_surface.dart).
class StreamMarkers {
  const StreamMarkers({
    required this.flat,
    required this.circles,
    required this.capsules,
  });

  /// The text the paragraph holds — body runs verbatim, the markers'
  /// placeholders as U+FFFC, the inline values as real text.
  final String flat;

  /// The bare sentinels, in body order.
  final List<StreamCircle> circles;

  /// The inline forms, in body order, with their flat coordinates. The
  /// [ProjectedSlot.valueStart]/[ProjectedSlot.valueEnd] range is the
  /// value the text itself carries — the growing value while the form
  /// is unclosed, verbatim once closed.
  final List<ProjectedSlot> capsules;

  @override
  bool operator ==(Object other) =>
      other is StreamMarkers &&
      other.flat == flat &&
      other.circles == circles &&
      other.capsules == capsules;

  @override
  int get hashCode => Object.hash(StreamMarkers, flat, circles, capsules);

  @override
  String toString() =>
      'StreamMarkers(flat: $flat, circles: $circles, capsules: $capsules)';
}

/// Projects [text] for the stream face: one pass of [scanForms], the
/// bare forms becoming circle placeholders, the inline forms (an
/// unclosed tail included — the growing capsule) becoming chip +
/// value + reservation. Pure and total.
StreamMarkers projectStream(String text) {
  final circles = <StreamCircle>[];
  final capsules = <ProjectedSlot>[];
  final flat = StringBuffer();
  var copied = 0;
  for (final form in scanForms(text)) {
    flat.write(text.substring(copied, form.start));
    if (form.kind == ScannedFormKind.bare) {
      flat.write(chipPlaceholder);
      circles.add(StreamCircle(id: form.id, at: flat.length - 1));
    } else {
      final chipAt = flat.length;
      flat
        ..write(chipPlaceholder)
        ..write(form.value)
        ..write(chipPlaceholder);
      capsules.add(
        ProjectedSlot(
          id: form.id,
          bodyStart: form.start,
          bodyEnd: form.end,
          chipAt: chipAt,
          valueStart: chipAt + 1,
          valueEnd: chipAt + 1 + form.value.length,
        ),
      );
    }
    copied = form.end;
  }
  flat.write(text.substring(copied));
  return StreamMarkers(
    flat: flat.toString(),
    circles: List.unmodifiable(circles),
    capsules: List.unmodifiable(capsules),
  );
}
