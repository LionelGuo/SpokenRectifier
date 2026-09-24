/// The house tooltip: a Material [Tooltip] re-clamped to the surface
/// that owns it (小修 24).
///
/// The main window is one OS window pinned to the whole work area
/// (ADR-0022) whose OS region shrinks to the card slot (ADR-0017):
/// anything the root overlay paints past the card is neither drawn
/// nor hit. Stock Tooltip clamps its bubble against the overlay — the
/// whole window — so a bubble crossing the card edge is hard-clipped
/// by the region unless the card happens to sit flush against the
/// screen edge. [SrTooltip] instead clamps through Flutter 3.47's
/// [Tooltip.positionDelegate] into [SrTooltipBoundary]'s rect: the
/// bubble flips above when below would clip, slides inward at the
/// sides, and wraps instead of overflowing (maxWidth = the boundary
/// width). The settings window mounts the same wrapper over its own
/// body, so every site behaves identically.
///
/// Outside a boundary the tooltip does not exist at all — the idle
/// orb window's region is the 84px footprint circle, which no bubble
/// fits in (and never did: the idle tooltip has been region-clipped
/// to invisibility since ADR-0017). The idle error sentence lives in
/// the tray tooltip instead (小修 24, ruling 丙).
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// How far the clamped bubble keeps from the boundary's edges — the
/// `margin` positionDependentBox clamps against, and half the slack
/// behind its maxWidth. Small on purpose: the boundary is already the
/// card's outer edge, not a window edge with chrome to avoid.
const double _bubbleInset = 4.0;

/// The rect (overlay coordinates) a surface's tooltips must stay
/// inside, or null for "no owning surface — render no tooltip". The
/// stage host mounts it around everything with the live card-slot
/// rect, swapping in the NULL rect while idle (the layer never
/// unmounts — a structural swap re-inflates the orb subtree and kills
/// a live grab's release, 小修 12's lesson); the settings window
/// mounts it over its own body.
class SrTooltipBoundary extends InheritedWidget {
  const SrTooltipBoundary({
    super.key,
    required this.rect,
    required super.child,
  });

  final Rect? rect;

  /// Null when no owning surface is in scope — callers render no
  /// tooltip then ([SrTooltip] already handles it; exposed for tests).
  static Rect? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SrTooltipBoundary>()?.rect;

  @override
  bool updateShouldNotify(SrTooltipBoundary oldWidget) => rect != oldWidget.rect;
}

/// [positionDependentBox] against [boundary] instead of the overlay:
/// translate the target into boundary-local space, clamp, translate
/// back. Public for the unit tests (小修 24's structural guard).
Offset srTooltipClamp(Rect boundary, TooltipPositionContext ctx) {
  return boundary.topLeft +
      positionDependentBox(
        size: boundary.size,
        childSize: ctx.tooltipSize,
        target: ctx.target - boundary.topLeft,
        verticalOffset: ctx.verticalOffset,
        preferBelow: ctx.preferBelow,
        margin: _bubbleInset,
      );
}

/// The one tooltip every window surface uses. Without a boundary in
/// scope this is the bare child — no bubble can be placed, so none is
/// attempted (the idle orb).
class SrTooltip extends StatelessWidget {
  const SrTooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration = SrMotion.tooltipWait,
  });

  final String message;
  final Widget child;
  final Duration waitDuration;

  @override
  Widget build(BuildContext context) {
    final boundary = SrTooltipBoundary.maybeOf(context);
    if (boundary == null) return child;
    return Tooltip(
      message: message,
      waitDuration: waitDuration,
      // Wrap wide messages (the instruction previews can run long)
      // instead of letting them overflow the boundary. The minHeight
      // matches the SDK desktop default Tooltip height.
      constraints: BoxConstraints(
        minHeight: 24.0,
        maxWidth: boundary.width - 2 * _bubbleInset,
      ),
      positionDelegate: (ctx) => srTooltipClamp(boundary, ctx),
      child: child,
    );
  }
}
