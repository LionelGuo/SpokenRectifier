part of 'slot_surface.dart';

// ---------------------------------------------------------------------------
// painters
// ---------------------------------------------------------------------------

/// Paints [paint]'s shape, then — when the band has a cut end —
/// confines it with the cut-fade mask: the flat colour first inside a
/// saveLayer, then the alpha gradient over the WHOLE layer rectangle
/// through dstIn. The mask is a plain rect inflated past every edge of
/// the band's ink — a mask sharing the shape's own boundary multiplies
/// its AA against the ink's (a stroked band lost the outer half of
/// its outline along the whole run on hardware), while the rect's
/// α=1 plateau reaches every pixel of the band untouched and only the
/// horizontal ramp toward the cut modulates it. Shared by both faces'
/// pill layers (the preview's and the stream's, 29 号票).
void paintFadedBand(Canvas canvas, CapsuleBand band, RRect shape, Paint paint) {
  final mask = band.cutFadeMask(shape.outerRect);
  if (mask == null) {
    canvas.drawRRect(shape, paint);
    return;
  }
  final layer = shape.outerRect.inflate(1);
  canvas.saveLayer(layer, Paint());
  canvas.drawRRect(shape, paint);
  canvas.drawRect(
    layer,
    Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = mask,
  );
  canvas.restore();
}

/// Paints the stream face's number circles and capsule digits
/// (listening / rectifying): each bare sentinel's spacer reservation
/// carries a flat circle — the family's own degenerate capsule
/// (2026-09-09 反馈九), placed inside the reservation by the same edge
/// and anchor strategy the preview's pills use, in the layout's own
/// frame (号圆; 21 号票家族, 23 号验收轮改绘). Each INLINE form's pill
/// is painted under the text by [_StreamPillPainter]; this layer adds
/// the number digits onto its left cap — the same geometry the pill
/// layer drew, so the digits can never disagree with the pill's
/// placement (29 号票: the growing capsule IS the family's capsule).
class _StreamCapsulesPainter extends CustomPainter {
  _StreamCapsulesPainter(this.state, this.pal);

  final _SlotSurfaceStateCore state;
  final SrPalette pal;

  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in state._streamCircleRects().entries) {
      final rect = entry.value;
      // A capsule arriving mid-stream fades with its segment (25 号
      // 票): fill and digits ride the alpha at the marker's own offset.
      final alpha = state._streamFadeAlphaAt(entry.key.at);
      // The flat family: fill only — no border, no shadow; one digit a
      // true circle, wider numbers a capsule.
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
        Paint()
          ..color = pal.accentSoft.withValues(alpha: pal.accentSoft.a * alpha),
      );
      final digits = TextPainter(
        text: TextSpan(
          text: '${entry.key.id}',
          style: SrType.micro.copyWith(
            color: pal.accentText.withValues(alpha: pal.accentText.a * alpha),
            height: 1,
            // Painters don't see the theme — carry the chain (28 号票).
            fontFamilyFallback: SrType.familyFallback,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      digits.paint(
        canvas,
        rect.center - Offset(digits.width / 2, digits.height / 2),
      );
    }
    // The inline capsules' number digits, centered on each pill's left
    // cap circle — the same geometry the pill layer drew, so the digits
    // can never disagree with the pill's placement (号数绝对定位于左
    // 端切圆圆心,08 号票; the chip widget itself is a bare spacer).
    for (final entry in state._streamCapsuleBands().entries) {
      final first = entry.value.first;
      final alpha = state._streamFadeAlphaAt(entry.key.chipAt);
      final digits = TextPainter(
        text: TextSpan(
          text: '${entry.key.id}',
          style: SrType.micro.copyWith(
            color: pal.accentText.withValues(alpha: pal.accentText.a * alpha),
            height: 1,
            // Painters don't see the theme — carry the chain (28 号票).
            fontFamilyFallback: SrType.familyFallback,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      digits.paint(
        canvas,
        Offset(
          first.rect.left +
              _SlotSurfaceStateCore.capsuleHeight / 2 -
              digits.width / 2,
          first.rect.center.dy - digits.height / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_StreamCapsulesPainter old) => true;
}

/// Paints under the stream text: the INLINE capsules' pills (flat
/// family: fill only, the cut-fade included) — the same band shape the
/// preview's [_BackgroundPainter] draws, over the stream's own flat
/// projection. The bare sentinels' circles are the foreground layer's
/// (they sit ON their reservations, not around text); a pill must sit
/// UNDER the value it grows around (29 号票).
class _StreamPillPainter extends CustomPainter {
  _StreamPillPainter(this.state, this.pal);

  final _SlotSurfaceStateCore state;
  final SrPalette pal;

  @override
  void paint(Canvas canvas, Size size) {
    final pillRadius = Radius.circular(_SlotSurfaceStateCore.capsuleHeight / 2);
    for (final entry in state._streamCapsuleBands().entries) {
      // The pill rides the alpha at its own chip offset — it fades in
      // only when the capsule itself is new (25 号票); appended text
      // after a matured capsule never pulses the pill.
      final alpha = state._streamFadeAlphaAt(entry.key.chipAt);
      for (final band in entry.value) {
        paintFadedBand(
          canvas,
          band,
          band.shape(pillRadius),
          Paint()
            ..color = pal.accentSoft.withValues(
              alpha: pal.accentSoft.a * alpha,
            ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_StreamPillPainter old) => true;
}

/// Paints under the text: the capsule pills (flat family: fill only) and
/// the selection (height-clamped, never above the capsule).
class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter(this.state, this.pal)
    : super(repaint: Listenable.merge([state._blink, state._activeFade]));

  final _SlotSurfaceStateCore state;
  final SrPalette pal;

  /// Paints [paint]'s shape — see [paintFadedBand].
  void _paintFadedBand(
    Canvas canvas,
    CapsuleBand band,
    RRect shape,
    Paint paint,
  ) => paintFadedBand(canvas, band, shape, paint);

  @override
  void paint(Canvas canvas, Size size) {
    final bandsById = state._capsuleBands();
    // Pills first: the selection may tint over them, never under. Every
    // covered line is its own band — rounded caps on the capsule's
    // natural ends, square edges where the wrapper cut it (截断直角),
    // their ink dissolving away as it approaches the cut (截断端渐隐).
    final pillRadius = Radius.circular(_SlotSurfaceStateCore.capsuleHeight / 2);
    for (final entry in bandsById.entries) {
      for (final band in entry.value) {
        _paintFadedBand(
          canvas,
          band,
          band.shape(pillRadius),
          Paint()..color = pal.accentSoft,
        );
      }
    }
    // The active capsule occurrence's stroke, fading in and out (点按 =
    // 选中编辑态), tracing the fill's own shape — the occurrence under
    // the caret only, never its same-number siblings (停车场 19).
    final active = state._activeSlot;
    if (active != null && state._activeFade.value > 0) {
      for (final band in bandsById[active] ?? const <CapsuleBand>[]) {
        final shape = band.shape(pillRadius, inflate: 0.5);
        // The stroke dissolves toward a cut end with its fill, so the
        // outline never draws the edge the fill just hid.
        _paintFadedBand(
          canvas,
          band,
          shape,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = pal.accent.withValues(
              alpha: 0.8 * state._activeFade.value,
            ),
        );
      }
    }
    // Selection over the pills, clamped below the capsule height and
    // centered on each line's ink box (the pills' own anchor).
    final selection = state._selectionPaintRange;
    if (selection != null) {
      final paragraph = state._paragraph;
      if (paragraph != null) {
        final lines = state._lineInkBoxes(paragraph);
        for (final box in paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: selection.baseOffset,
            extentOffset: selection.extentOffset,
          ),
        )) {
          final center = state._inkCenter(lines, box.toRect().center.dy);
          final rect = Rect.fromLTRB(
            box.left,
            center - _SlotSurfaceStateCore.selectionHeight / 2,
            box.right,
            center + _SlotSurfaceStateCore.selectionHeight / 2,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(3)),
            Paint()..color = pal.accent.withValues(alpha: 0.25),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => true;
}

/// Paints over the text: the blinking caret, the composing underline, and
/// the prefill hover tooltip.
class _ForegroundPainter extends CustomPainter {
  _ForegroundPainter(this.state, this.pal)
    : super(repaint: Listenable.merge([state._blink, state._activeFade]));

  final _SlotSurfaceStateCore state;
  final SrPalette pal;

  @override
  void paint(Canvas canvas, Size size) {
    // Composing underline.
    if (state.composingText.isNotEmpty) {
      final paragraph = state._paragraph;
      if (paragraph != null) {
        for (final box in paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: state._composingPaintStart,
            extentOffset: state._composingPaintEnd,
          ),
        )) {
          final paint = Paint()
            ..color = pal.accent
            ..strokeWidth = 1.5;
          canvas.drawLine(
            Offset(box.left, box.bottom + 1),
            Offset(box.right, box.bottom + 1),
            paint,
          );
        }
      }
    }
    // Caret: shown while focused, blinking.
    final focused = state.widget.focusNode?.hasFocus ?? false;
    if (focused && state._blink.value < 0.5) {
      final caret = state.caretRect();
      if (caret != null) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            caret,
            const Radius.circular(_SlotSurfaceStateCore.caretWidth / 2),
          ),
          Paint()..color = pal.accent,
        );
      }
    }
    // The capsules' number digits, centered on each pill's left cap
    // circle — the same geometry the pill layer drew, so the digits can
    // never disagree with the pill's placement (号数绝对定位于左端切圆
    // 圆心,08 号票; the chip widget itself is a bare spacer).
    for (final entry in state._capsuleSegments().entries) {
      final first = entry.value.first;
      final digits = TextPainter(
        text: TextSpan(
          text: '${entry.key.id}',
          style: SrType.micro.copyWith(
            color: pal.accentText,
            height: 1,
            // Painters don't see the theme — carry the chain (28 号票).
            fontFamilyFallback: SrType.familyFallback,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      digits.paint(
        canvas,
        Offset(
          first.left +
              _SlotSurfaceStateCore.capsuleHeight / 2 -
              digits.width / 2,
          first.center.dy - digits.height / 2,
        ),
      );
    }
    // Slot hover tooltip: one hint for every capsule in every state —
    // prefill or not, emptied or edited (2026-09-09 user decision; the
    // per-prefill wording 预填:X/预填为空 is retired).
    final tooltip = state._tooltipSlot;
    if (tooltip != null) {
      final segments = state._capsuleSegments()[tooltip];
      if (segments != null && segments.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: '编辑占位内容',
            style: SrType.micro.copyWith(
              color: pal.textSecondary,
              // Painters don't see the theme — carry the chain (28 号票).
              fontFamilyFallback: SrType.familyFallback,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final card = Rect.fromLTWH(0, 0, tp.width + 12, tp.height + 8);
        final anchor = segments.first;
        var origin = Offset(
          (anchor.center.dx - card.width / 2).clamp(0, size.width - card.width),
          anchor.top - card.height - 4,
        );
        if (origin.dy < 0) origin = Offset(origin.dx, anchor.bottom + 4);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            card.shift(origin),
            Radius.circular(SrRadius.control),
          ),
          Paint()..color = pal.surfaceRaised,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            card.shift(origin),
            Radius.circular(SrRadius.control),
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = pal.hairline,
        );
        tp.paint(canvas, origin + const Offset(6, 4));
      }
    }
  }

  @override
  bool shouldRepaint(_ForegroundPainter old) => true;
}
