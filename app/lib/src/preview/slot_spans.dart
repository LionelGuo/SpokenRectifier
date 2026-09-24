part of 'slot_surface.dart';

// ---------------------------------------------------------------------------
// stream fade (25 号票)
// ---------------------------------------------------------------------------

/// One fading region of the stream face: the flat range [start, end) is
/// new text that arrived at [birth] — a tick of the surface's fade
/// clock — and paints as ONE block at a shared alpha until it matures
/// (整段 α 0→1,各段独立计时). Pure data: the machine tests exercise
/// the model directly.
class StreamFadeSegment {
  const StreamFadeSegment(this.start, this.end, this.birth);

  final int start;
  final int end;

  /// The fade-clock tick the segment was born at.
  final Duration birth;

  @override
  bool operator ==(Object other) =>
      other is StreamFadeSegment &&
      other.start == start &&
      other.end == end &&
      other.birth == birth;

  @override
  int get hashCode => Object.hash(start, end, birth);
}

/// The alpha [segment] paints with at fade-clock tick [now]: the curve
/// over the elapsed fraction of [period], clamped to [0, 1].
double streamFadeAlpha(
  StreamFadeSegment segment,
  Duration now, {
  Duration period = SrMotion.fade,
  Curve curve = SrMotion.curveFade,
}) {
  final t = ((now - segment.birth).inMicroseconds / period.inMicroseconds)
      .clamp(0.0, 1.0);
  return curve.transform(t);
}

/// The fade segments after a stream text update: the common prefix of
/// the two flat texts keeps whatever fades it already carries (its own
/// clocks, truncated at the diff point when a rewrite cuts into a
/// still-fading segment); everything from the FIRST differing code unit
/// on is one new segment born at [now] — a rewrite's whole tail re-fades
/// (首异后缀整段,改写段同律淡入). A shrink or a clear keeps only what
/// survives below the diff point.
List<StreamFadeSegment> advanceStreamFades(
  String oldFlat,
  String newFlat,
  List<StreamFadeSegment> existing,
  Duration now,
) {
  var p = 0;
  while (p < oldFlat.length &&
      p < newFlat.length &&
      oldFlat.codeUnitAt(p) == newFlat.codeUnitAt(p)) {
    p++;
  }
  final limit = math.min(p, newFlat.length);
  final kept = [
    for (final s in existing)
      if (math.min(s.end, limit) > s.start)
        StreamFadeSegment(s.start, math.min(s.end, limit), s.birth),
  ];
  if (p < newFlat.length) {
    kept.add(StreamFadeSegment(p, newFlat.length, now));
  }
  return kept;
}

// ---------------------------------------------------------------------------
// shared line geometry
// ---------------------------------------------------------------------------

/// A capsule's covered lines, with a tail line that holds NEITHER the
/// chip nor any value glyph dropped — unless the value hard-continues
/// onto it (it ends with a newline: a trailing 回车's empty line is the
/// caret's real parking line and keeps its band, 反馈七). The tail-less
/// case is the soft-wrap artifact: every value glyph fit on the capsule's
/// line and only the invisible reservation placeholder wrapped; the
/// covered-lines probe — which asks the caret AT the reservation's own
/// offset, downstream — claimed the next line on engines that report the
/// wrap boundary on the far side, and the capsule rendered a spurious
/// empty stub below a complete pill: a fragment hanging by a thread
/// (真机, 反馈十四). With the tail dropped the capsule is one complete
/// pill on its glyph line.
List<({double top, double height})> truncateCoveredLines(
  List<({double top, double height})> covered,
  List<Rect> boxes,
  bool valueEndsWithNewline,
) {
  if (valueEndsWithNewline || covered.length <= 1) return covered;
  var lastHeld = 0;
  for (final box in boxes) {
    for (var i = 0; i < covered.length; i++) {
      if (box.top < covered[i].top + covered[i].height - 1 &&
          box.bottom > covered[i].top + 1) {
        if (i > lastHeld) lastHeld = i;
      }
    }
  }
  if (lastHeld == covered.length - 1) return covered;
  return covered.sublist(0, lastHeld + 1);
}

/// The per-slot reservation widths that keep the capsule's invisible
/// tail from LEADING a wrapped line (停车场 04, 2026-09-12). A
/// reservation placeholder is unbreakable: when the capsule's value
/// ends within one reservation's width of the column's right edge and
/// content follows, the placeholder itself wraps and that content
/// trails it — starting the next line indented by the reservation's
/// width (真机: 后续内容不顶格, 空出一段距离), its seat ruled by the
/// capsule above. The reservation's one layout duty is breathing for
/// SAME-LINE following text; a reservation that wraps has no same-line
/// follower, so the duty is vacuous and only the indent remains.
///
/// The measure lays the caller's own span tree out first in a
/// TextPainter over the same ambient root style, strut, scaler and
/// width the real paragraph resolves (Text.rich nests our styled span
/// under the ambient DefaultTextStyle — the family the runs resolve
/// hangs off that root — and the same engine breaks the same input the
/// same way); every reservation the measure finds on a LATER line than
/// its reference box (the value's last glyph, or the chip when the
/// value is empty) is fitted to exactly the leftover advance its line
/// still holds, minus a hair against float equality. Fitted, it stays
/// on the capsule's line — the pill paints its own parking tail past
/// the value regardless — and the content that wraps anyway starts
/// flush at x=0. Values that end with 回车 are excluded: their
/// reservation rides the value's own empty line (反馈十九's widened
/// stub) and never wraps. The measure iterates to a fixed point
/// (capped): one slot's fit reflows the lines below it, so a downstream
/// slot's leftover is only final once the slots before it are fitted.
Map<ProjectedSlot, double> fittedReservationWidths({
  required double maxWidth,
  required TextStyle ambientStyle,
  required TextStyle style,
  required StrutStyle strut,
  required TextScaler textScaler,
  Locale? locale,
  required double standardWidth,
  required List<ProjectedSlot> slots,
  required bool Function(ProjectedSlot slot) valueEndsWithNewline,
  required List<InlineSpan> Function(Map<ProjectedSlot, double> widths)
  buildSpans,
  int Function(int)? paintOf,
  int Function(int)? paintOfEnd,
  int Function(int)? paintContentOf,
  TextRange? composingPaintRange,
}) {
  if (slots.isEmpty || !maxWidth.isFinite || maxWidth <= 0) {
    return const {};
  }
  final toPaintEnd = paintOfEnd ?? (f) => f;
  final toContent = paintContentOf ?? paintOf ?? (f) => f;
  var widths = const <ProjectedSlot, double>{};
  for (var pass = 0; pass < 3; pass++) {
    final spans = buildSpans(widths);
    final painter =
        TextPainter(
          text: TextSpan(
            style: ambientStyle,
            children: [TextSpan(style: style, children: spans)],
          ),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
          strutStyle: strut,
          locale: locale,
        )..setPlaceholderDimensions([
          for (final span in spans)
            if (span is WidgetSpan)
              PlaceholderDimensions(
                size: Size(
                  (span.child as SizedBox).width!,
                  (span.child as SizedBox).height!,
                ),
                alignment: PlaceholderAlignment.middle,
              ),
        ]);
    painter.layout(maxWidth: maxWidth);
    var changed = false;
    for (final slot in slots) {
      if (valueEndsWithNewline(slot)) continue;
      // Paint-space offsets: the spans the paragraph (and this painter)
      // lays out carry the composing run spliced in, so a slot's
      // reservation placeholder sits at its SHIFTED index — the base
      // offset would probe the composing text instead and never see
      // the wrap (真机第二轮: IME 组合贴边仍缩进).
      final reservationPaint = toPaintEnd(slot.valueEnd);
      if (composingPaintRange != null &&
          composingPaintRange.start < reservationPaint + 1 &&
          reservationPaint < composingPaintRange.end) {
        continue; // the composing run replaced this reservation
      }
      final reservationBoxes = painter.getBoxesForSelection(
        TextSelection(
          baseOffset: reservationPaint,
          extentOffset: reservationPaint + 1,
        ),
      );
      // The unit the reservation must stay beside: the capsule's last
      // laid-out content before it — the composing run's tail while one
      // rides the value, else the value's last glyph, else the chip. The
      // chip probes CONTENT space: a composition at the capsule's
      // outside-left dock shifts the chip past the run (05 号票).
      final referenceBoxes = painter.getBoxesForSelection(
        TextSelection(
          baseOffset: toContent(slot.chipAt),
          extentOffset: reservationPaint,
        ),
      );
      if (reservationBoxes.isEmpty || referenceBoxes.isEmpty) continue;
      // Line membership, never raw tops: a reservation is a 4-px
      // placeholder MIDDLE-aligned — its box sits a few px below a
      // glyph's even on the same line — so the line test compares box
      // CENTRES against half a line's pitch (same line drifts a px or
      // two; a wrap is a full pitch).
      final reservation = reservationBoxes.first.toRect();
      final reference = referenceBoxes.last.toRect();
      final pitch = painter.getFullHeightForCaret(
        TextPosition(offset: reservationPaint),
        Rect.zero,
      );
      if ((reservation.center.dy - reference.center.dy).abs() <
          (pitch > 0 ? pitch / 2 : 8)) {
        continue; // fits its line
      }
      // The fit keeps two pixels of slack: the standalone measure can
      // drift from the live paragraph's own accumulation on real font
      // fallback chains (the drift that broke the first round on the
      // real machine), and a would-wrap reservation has no same-line
      // follower for the slack to squeeze — invisible by construction.
      // Deeper drift is the post-frame verification's to correct.
      final leftover = maxWidth - reference.right - 2;
      widths = {
        ...widths,
        slot: math.max(0, math.min(standardWidth, leftover)),
      };
      changed = true;
    }
    painter.dispose();
    // A fit STICKS: the pass that measured with it in place saw no wrap
    // (that is the repair working), so shrinks are only ever added or
    // tightened, never withdrawn — withdrawing would oscillate (fit →
    // no wrap seen → withdraw → wrap seen → …) and end on the wrong
    // parity with nothing applied.
    if (!changed) break;
  }
  return widths;
}

/// The paragraph's own ink-vs-caret bias: a TEXT line's ink-box
/// center minus its caret line-box center — the engine's leading
/// split for the fonts this paragraph actually resolved, measured
/// from the paragraph itself (a standalone TextPainter seats glyphs
/// differently inside its own line and measures wrong). Ink-less
/// lines anchor on their strut-locked caret line center plus this
/// bias — exactly where their ink anchor lands once glyphs arrive —
/// so the anchor source never switches and nothing re-seats (反馈十
/// 二). Zero when the paragraph holds no text at all: nothing to
/// calibrate from, and only the first glyph's own font delta —
/// sub-pixel on real machines — can move.
double _paragraphInkBiasOf(
  RenderParagraph paragraph,
  List<Rect> inkLines,
  String flat,
) {
  for (var i = 0; i < flat.length; i++) {
    final cu = flat.codeUnitAt(i);
    if (cu == 0xFFFC || cu == 0x0A) continue;
    final probe = TextPosition(offset: i);
    final height = paragraph.getFullHeightForCaret(probe);
    if (height <= 0) continue;
    final center =
        paragraph.getOffsetForCaret(probe, Rect.zero).dy + height / 2;
    for (final line in inkLines) {
      if (center >= line.top - 0.5 && center <= line.bottom + 0.5) {
        return line.center.dy - center;
      }
    }
  }
  return 0;
}

/// The ink-box center of the line [dy] falls on, eased down by
/// [opticalEasePx] — the selection tint's vertical anchor. When no
/// line claims [dy] — an ink-less line, placeholders only — the
/// anchor falls to [fallback] (eased alike).
double inkCenterOf(
  List<Rect> lines,
  double dy,
  double opticalEasePx, {
  double? fallback,
}) {
  for (final line in lines) {
    if (dy >= line.top - 0.5 && dy <= line.bottom + 0.5) {
      return line.center.dy + opticalEasePx;
    }
  }
  return (fallback ?? dy) + opticalEasePx;
}

/// The paragraph lines a capsule covers, top to bottom, as caret bands
/// (the caret's top and full line height at a position on the line). A
/// line with no glyphs — an empty value line between 回车s, or the one
/// a trailing 回车 leaves — is real to the caret but invisible to every
/// box query, so the lines are discovered by parking the caret at each
/// flat position from the chip through the reservation placeholder
/// (which rides the value's last line, so a trailing 回车's line is
/// found too). [paintOf]/[paintOfEnd] carry the caller's base→paint
/// shift (the preview's composing splice; identity on the stream face);
/// [paintContentOf] carries the content-space map the chip probes (05
/// 号票: content at the composing point shifts past the run, seat
/// semantics would pin the walk's start inside the run).
List<({double top, double height})> coveredLinesFor(
  RenderParagraph paragraph,
  ProjectedSlot slot, {
  int Function(int)? paintOf,
  int Function(int)? paintOfEnd,
  int Function(int)? paintContentOf,
}) {
  final toPaintEnd = paintOfEnd ?? (f) => f;
  final toContent = paintContentOf ?? paintOf ?? (f) => f;
  final bands = <({double top, double height})>[];
  for (var f = toContent(slot.chipAt); f <= toPaintEnd(slot.valueEnd); f++) {
    final position = TextPosition(offset: f);
    final top = paragraph.getOffsetForCaret(position, Rect.zero).dy;
    final height = paragraph.getFullHeightForCaret(position);
    var seen = false;
    for (final band in bands) {
      if ((band.top - top).abs() < 0.75) {
        seen = true;
        break;
      }
    }
    if (!seen) bands.add((top: top, height: height));
  }
  bands.sort((a, b) => a.top.compareTo(b.top));
  return bands;
}

/// The rendered bands per capsule OCCURRENCE, in paragraph-local
/// coordinates — the ONE shape computation both faces of the surface
/// family run: the preview's editable pills (29 号's extraction seam)
/// and the stream's read-only inline capsules. Keyed by the occurrence,
/// never the identity: a re-typed same-number marker is its own pill
/// beside the original's (同号多处各一枚; 停车场 19 — the identity key
/// collapsed siblings and the original's pill vanished). Each covered line
/// renders as its own band, centered on a content-independent anchor —
/// the strut-locked caret line center plus the paragraph's ink bias,
/// eased (05 号票; formerly the line's ink box, 08 号票, which re-seated
/// as the line's content changed on real fallback chains); an end the
/// wrapper or a newline CUT is square,
/// only the capsule's NATURAL ends keep the rounded caps (截断直角、文
/// 字贴边; D3 反馈五终裁); a cut end's fill dissolves approaching it
/// (截断端渐隐); the parking stub floors at the reservation's own width
/// (反馈十八修复二); every band is the capsule's own height on its line
/// (反馈十五); the breathing is CONSTANT at every edge (反馈十六).
///
/// [paintText] is the string the paragraph actually lays out — the flat
/// projection (the stream's, or the preview's with the composing run
/// spliced). [valueEndsWithNewline] answers per occurrence, its fact
/// source the caller's (the preview's value map; the stream's own text).
/// [paintOf]/[paintOfEnd] default to identity for faces with no
/// composing overlay; [paintContentOf] carries the content-space map the
/// chip's box probes (05 号票).
Map<ProjectedSlot, List<CapsuleBand>> capsuleBandsFor({
  required RenderParagraph paragraph,
  required String paintText,
  required List<ProjectedSlot> slots,
  required bool Function(ProjectedSlot slot) valueEndsWithNewline,
  required double opticalEasePx,
  int Function(int)? paintOf,
  int Function(int)? paintOfEnd,
  int Function(int)? paintContentOf,
}) {
  final toPaint = paintOf ?? (f) => f;
  final toPaintEnd = paintOfEnd ?? (f) => f;
  final toContent = paintContentOf ?? paintOf ?? (f) => f;
  final placeholderPositions = [
    for (var i = 0; i < paintText.length; i++)
      if (paintText.codeUnitAt(i) == 0xFFFC) i,
  ];
  final lines = textLineInkBoxes(
    paragraph,
    placeholderPositions,
    paintText.length,
  );
  final inkBias = _paragraphInkBiasOf(paragraph, lines, paintText);
  // The wrap width the layout itself used — the theoretical right edge
  // a full line of text reaches.
  final columnRight = paragraph.constraints.maxWidth;
  final bands = <ProjectedSlot, List<CapsuleBand>>{};
  for (final slot in slots) {
    // The chip probes CONTENT space — an offset at the composing point
    // belongs PAST the run, where the placeholder actually sits (05 号
    // 票: a caret-left composition must push the whole capsule right).
    final chipPaint = toContent(slot.chipAt);
    final chipBoxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: chipPaint, extentOffset: chipPaint + 1),
    );
    final valueBoxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: toPaint(slot.valueStart),
        extentOffset: toPaintEnd(slot.valueEnd),
      ),
    );
    final boxes = <Rect>[
      for (final box in chipBoxes) box.toRect(),
      for (final box in valueBoxes) box.toRect(),
    ]..sort((a, b) => a.left.compareTo(b.left));
    if (boxes.isEmpty) continue;
    var covered = coveredLinesFor(
      paragraph,
      slot,
      paintOf: paintOf,
      paintOfEnd: paintOfEnd,
      paintContentOf: paintContentOf,
    );
    // 反馈十四: a covered tail line holding neither the chip nor any
    // value glyph — claimed by the wrap-boundary caret probe at the
    // reservation's own offset — belongs to the capsule only when the
    // value hard-continues onto it. Otherwise the capsule is one
    // complete pill on its glyph line.
    covered = truncateCoveredLines(covered, boxes, valueEndsWithNewline(slot));
    if (covered.length > 1 && columnRight.isFinite && chipBoxes.isNotEmpty) {
      // Multi-line: one band per covered line, flush to the column.
      // The last band keeps the content-bounded right edge — the body
      // text after the capsule flows on beside it. Every end but the
      // first's left (the chip cap) and the
      // last's right (the value's own end) is a CUT: square. The
      // empty tail line's parking stub floors at the reservation's own
      // width — exactly the layout space it already owns, clear of all
      // ink (反馈十八修复二; the floor's history: 反馈七终案's cap
      // radius, then widened — the near-degenerate width lost the
      // fill's lower-left crescent on the real GPU and left the cut
      // dissolve no flat run).
      final lastBand = covered.last;
      var lastRight = 0.0;
      for (final box in valueBoxes) {
        if (box.top < lastBand.top + lastBand.height - 1 &&
            box.bottom > lastBand.top + 1) {
          lastRight = math.max(lastRight, box.right);
        }
      }
      // The tail breathing is CONSTANT (反馈十六): the last band keeps
      // the parking pad only, whatever does or does not follow. The
      // empty tail line's parking stub floors at the reservation's own
      // width plus the look-tuned pixels (反馈十八修复二 trialed at the
      // reservation's own width, then walked the cap start right a
      // pixel at a time; the ramp clamp keeps the dissolve's length
      // constant): at cap radius + 0.5 the near-degenerate corner
      // geometry lost the fill's lower-left crescent on the real GPU
      // (软件光栅无此缺陷), and the cut dissolve had no flat run to
      // live in — filling the layout space the stub already owns gives
      // the ramp its visible run and walks the cap clear of both the
      // dissolve and the degenerate widths (右端连续半圆弧, 渐变共存).
      final stubFloor =
          _SlotSurfaceStateCore.pillRightPad +
          _SlotSurfaceStateCore.capsuleSidePad +
          2;
      final lastBandRight = math.max(
        lastRight + _SlotSurfaceStateCore.pillRightPad,
        stubFloor,
      );
      // No value glyphs claim the last covered line — the value ended
      // with 回车 and the band there is the capsule's parking stub.
      final slotBands = <CapsuleBand>[];
      // One anchor per covered line, content-independent (05 号票): the
      // strut-locked caret line center plus the paragraph's ink bias —
      // the same value whether the line holds text yet or not, so a
      // capsule's seat never re-seats when its first glyph (or an IME
      // run of another script) lands. The ink box a with-text line
      // reports rides the fonts its runs resolved and visibly drifts on
      // real fallback chains (真机: 首字落位胶囊轻微下移).
      final centers = <double>[
        for (final band in covered)
          band.top + band.height / 2 + inkBias + opticalEasePx,
      ];
      final half = _SlotSurfaceStateCore.capsuleHeight / 2;
      for (var i = 0; i < covered.length; i++) {
        // Every band is the capsule's OWN height on its line (反馈十
        // 五: the seam-closing experiment that stretched bands toward
        // their neighbours made the capsule read taller than the
        // family and graze the capsules above and below — the thin
        // daylight between a wrap's bands is the family's look, ruled
        // back).
        final top = centers[i] - half;
        final bottom = centers[i] + half;
        // The first segment's cap keeps its leading sidePad
        // unconditionally (反馈十六); every later segment is a column
        // band: full width, flush left.
        final left = i == 0
            ? chipBoxes.first.toRect().left +
                  _SlotSurfaceStateCore.capsuleSidePad
            : 0.0;
        final right = i == covered.length - 1 ? lastBandRight : columnRight;
        slotBands.add(
          CapsuleBand(
            rect: Rect.fromLTRB(left, top, right, bottom),
            leftRounded: i == 0,
            rightRounded: i == covered.length - 1,
          ),
        );
      }
      bands[slot] = slotBands;
      continue;
    }
    // Single line: a complete pill hugging its content. Group the
    // covered boxes into per-line runs (one, here): a box overlaps its
    // own line's boxes vertically and never the neighbour line's.
    final runs = <List<Rect>>[];
    for (final box in boxes) {
      final run = runs.isEmpty ? null : runs.last;
      final sameLine =
          run != null &&
          box.top < run.first.bottom + 1 &&
          box.bottom > run.first.top - 1;
      if (sameLine) {
        run.add(box);
      } else {
        runs.add([box]);
      }
    }
    final slotBands = <CapsuleBand>[];
    for (var i = 0; i < runs.length; i++) {
      var left = runs[i].first.left;
      var right = runs[i].first.right;
      for (final box in runs[i]) {
        left = math.min(left, box.left);
        right = math.max(right, box.right);
      }
      // The breathing is CONSTANT (2026-09-10 反馈十六 re-ruling,
      // retiring the line-edge swallows of 反馈四②/十三): the first
      // run's left always sits on the chip reservation's leading
      // sidePad — a capsule's placement and width never depend on
      // what its neighbours or the line's edges hold — and the last
      // run always grows into the parking pad the reservation holds
      // past the value, keeping its breathing tail.
      if (i == 0) left = left + _SlotSurfaceStateCore.capsuleSidePad;
      final tail = i == runs.length - 1
          ? _SlotSurfaceStateCore.pillRightPad
          : 0.0;
      // The anchor is the strut-locked caret line center of the covered
      // line (反馈十二's convention) plus the paragraph's ink bias —
      // content-independent on EVERY line now, ink-holding ones alike
      // (05 号票): never the run's own placeholder box, never the line's
      // ink union, both of which re-seat as content lands.
      var coveredCenter = runs[i].first.center.dy;
      var coveredDistance = double.infinity;
      for (final band in covered) {
        final distance =
            ((band.top + band.height / 2) - runs[i].first.center.dy).abs();
        if (distance < coveredDistance) {
          coveredDistance = distance;
          coveredCenter = band.top + band.height / 2;
        }
      }
      final center = coveredCenter + inkBias + opticalEasePx;
      slotBands.add(
        CapsuleBand(
          rect: Rect.fromLTRB(
            left,
            center - _SlotSurfaceStateCore.capsuleHeight / 2,
            right + tail,
            center + _SlotSurfaceStateCore.capsuleHeight / 2,
          ),
          leftRounded: true,
          rightRounded: true,
        ),
      );
    }
    bands[slot] = slotBands;
  }
  return bands;
}

/// A paragraph's line ink boxes over the TEXT glyphs only, top to bottom:
/// the selection ranges BETWEEN [placeholders] (flat offsets of the inline
/// placeholder code units) are measured and unioned per line; the
/// placeholder boxes themselves are skipped. Both faces of the surface
/// family anchor their capsule chrome on this — the stream's circle
/// shifts and the preview's pills, digits, selection and caret — so every
/// capsule aligns against where the line's writing actually sits, never
/// against a placeholder's own (font-metric-driven) placement.
List<Rect> textLineInkBoxes(
  RenderParagraph paragraph,
  List<int> placeholders,
  int length,
) {
  final boxes = <TextBox>[];
  var start = 0;
  for (final p in placeholders) {
    if (p > start) {
      boxes.addAll(
        paragraph.getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: p),
        ),
      );
    }
    start = p + 1;
  }
  if (start < length) {
    boxes.addAll(
      paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: length),
      ),
    );
  }
  return _mergeLineBoxes(boxes);
}

/// Unions [boxes] into per-line rectangles, top to bottom: boxes that
/// overlap vertically are one visual line's band.
List<Rect> _mergeLineBoxes(List<TextBox> boxes) {
  if (boxes.isEmpty) return const [];
  final sorted = boxes.toList()..sort((a, b) => a.top.compareTo(b.top));
  final lines = <Rect>[];
  for (final box in sorted) {
    final rect = box.toRect();
    if (lines.isNotEmpty && rect.top < lines.last.bottom) {
      final last = lines.removeLast();
      lines.add(
        Rect.fromLTRB(
          math.min(last.left, rect.left),
          last.top,
          math.max(last.right, rect.right),
          math.max(last.bottom, rect.bottom),
        ),
      );
    } else {
      lines.add(rect);
    }
  }
  return lines;
}

// ---------------------------------------------------------------------------
// capsule bands (the pill model both faces render)
// ---------------------------------------------------------------------------
/// One rendered capsule line: the band's rectangle and which of its ends
/// carry the pill's rounded cap. A capsule's NATURAL ends — the chip's
/// left cap and the value's own end — stay rounded; an end the wrapper or
/// a newline CUT is square, the text beside it sits flush against the
/// column's edge like ordinary text (截断直角、文字贴边; D3 反馈五终裁),
/// and the ink dissolves approaching it, so the square edge never reads
/// as a drawn edge (截断端渐隐; D3 反馈八).
class CapsuleBand {
  const CapsuleBand({
    required this.rect,
    required this.leftRounded,
    required this.rightRounded,
  });

  final Rect rect;
  final bool leftRounded;
  final bool rightRounded;

  /// The band's painted shape: rounded caps on the natural ends, square
  /// edges on the cut ones, optionally inflated for the active stroke.
  RRect shape(Radius cap, {double inflate = 0}) => RRect.fromLTRBAndCorners(
    rect.left - inflate,
    rect.top - inflate,
    rect.right + inflate,
    rect.bottom + inflate,
    topLeft: leftRounded ? cap : Radius.zero,
    bottomLeft: leftRounded ? cap : Radius.zero,
    topRight: rightRounded ? cap : Radius.zero,
    bottomRight: rightRounded ? cap : Radius.zero,
  );

  /// A horizontal ALPHA mask holding opaque and dissolving to nothing
  /// across the run approaching each CUT end, so the square edge never
  /// reads as a drawn edge (截断端渐隐). The band's real colour never
  /// rides inside the gradient: translucent gradient stops come out of
  /// the renderer at their alpha SQUARED (D3 反馈八复验: a tinted
  /// gradient washed the whole pill to α², nearly invisible), so the
  /// mask is white-to-transparent — squared to itself at the stops —
  /// and is applied over the flat paint through BlendMode.dstIn inside
  /// a saveLayer. Each side's run is the cap's radius, clamped to a
  /// third of [bounds] (a narrow band keeps some ink) and — when the
  /// opposite end is ROUNDED — to one pixel SHORT of that cap's own flat
  /// edge: a rounded end is always one continuous semicircle (反馈七终
  /// 案), the dissolve never eats into it, and a pixel of SOLID fill
  /// separates the ramp's end from the arc's start (2026-09-10 look-
  /// tuning: the ramp holds its length while the cap start walks right).
  /// (F23 round, 反馈十八: the
  /// parking stub after a trailing 回车 is cut on its left and its
  /// right end IS the cap — the ramp washed the arc's left half away
  /// and it read discontinuous until characters pushed the cap clear;
  /// the stub's flat run is a fraction of a pixel, so its cut side
  /// keeps a solid square edge). Null when no end is cut or neither run
  /// survives the clamps: a complete pill paints its flat colour as-is.
  Shader? cutFadeMask(Rect bounds) {
    final fadeLeft = !leftRounded;
    final fadeRight = !rightRounded;
    if (!fadeLeft && !fadeRight) return null;
    final width = bounds.width;
    final cap = _SlotSurfaceStateCore.capsuleHeight / 2;
    double runFor(bool fade, bool oppositeRounded) => fade
        ? math.min(
            math.min(cap, width / 3),
            oppositeRounded ? math.max(0, width - cap - 1) : width,
          )
        : 0.0;
    final leftRun = runFor(fadeLeft, rightRounded);
    final rightRun = runFor(fadeRight, leftRounded);
    if (leftRun <= 0 && rightRun <= 0) return null;
    final fLeft = leftRun / width;
    final fRight = rightRun / width;
    const opaque = Color(0xFFFFFFFF);
    const gone = Color(0x00FFFFFF);
    if (fadeLeft && fadeRight) {
      return LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [gone, opaque, opaque, gone],
        stops: [0, fLeft, 1 - fRight, 1],
      ).createShader(bounds);
    }
    if (fadeLeft) {
      return LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [gone, opaque, opaque],
        stops: [0, fLeft, 1],
      ).createShader(bounds);
    }
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [opaque, opaque, gone],
      stops: [0, 1 - fRight, 1],
    ).createShader(bounds);
  }
}
