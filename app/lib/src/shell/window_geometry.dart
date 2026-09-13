/// Orb-anchored window geometry — the pure-function core of ticket 20
/// (球拖动/面板上沿拖动/尺寸调节/持久化共用的几何规则, spec §3
/// 拖拽与尺寸调节).
///
/// Everything is keyed on the ANCHOR (锚点): the orb's ball center in
/// logical screen coordinates — the one point that survives every window
/// form. The window's relation to the anchor never changes: whichever
/// corner the growth direction pins, the anchor sits `anchorInset`
/// inward from it, so footprint changes keep the ball pixel-stationary
/// (编舞铁律).
///
/// The growth direction is DERIVED, never stored: each axis grows toward
/// the roomier side of the current work area, ties growing up/left (the
/// spec default). The spec's 贴边退化 (a pinned edge degrades the axis)
/// is that rule's natural special case — a ball pinned to the top edge
/// already sits in the upper half, so the axis already grows down; a
/// separate min-size flip guard would only fire on screens where NEITHER
/// side fits the minimum, and there the size clamp below keeps the
/// window on screen under the floor instead of off it.
///
/// All coordinates are logical, window_manager's coordinate system
/// inside and out (spec §3 finding 3). Pure functions only — no window,
/// no IO; the callers own the side effects.

library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import '../design/tokens.dart';

/// Which corner of the window stays put as the footprint changes. The
/// anchor sits `anchorInset` inward from that corner and the panel grows
/// away from it.
enum GrowthDirection { upLeft, upRight, downLeft, downRight }

extension GrowthDirectionX on GrowthDirection {
  bool get growLeft =>
      this == GrowthDirection.upLeft || this == GrowthDirection.downLeft;
  bool get growUp =>
      this == GrowthDirection.upLeft || this == GrowthDirection.upRight;
}

/// The orb window's rect for an anchor: the footprint centered on the
/// ball. Direction-free — all four corners hold the anchor at the same
/// center.
Rect orbFootprintAt(Offset anchor) => Rect.fromCenter(
  center: anchor,
  width: SrGeometry.orbFootprint.width,
  height: SrGeometry.orbFootprint.height,
);

/// Clamp an anchor so the whole orb footprint sits inside the work area
/// (不压任务栏). A flush landing — footprint edge on the work-area edge —
/// is legal; the clamp itself produces exactly those.
Offset clampAnchor(Offset anchor, Rect workArea) {
  final inset = SrGeometry.anchorInset;
  // A work area smaller than the footprint cannot host it anywhere:
  // settle for the middle (degenerate screens; the drag just feels
  // pinned).
  if (workArea.width < SrGeometry.orbFootprint.width ||
      workArea.height < SrGeometry.orbFootprint.height) {
    return workArea.center;
  }
  return Offset(
    anchor.dx.clamp(workArea.left + inset, workArea.right - inset),
    anchor.dy.clamp(workArea.top + inset, workArea.bottom - inset),
  );
}

/// The growth direction for an anchor: each axis grows toward the
/// roomier half of [workArea]; exact ties grow up and left (the spec
/// default upLeft).
GrowthDirection chooseGrowthDirection(Offset anchor, Rect workArea) {
  final center = workArea.center;
  final left = anchor.dx >= center.dx;
  final up = anchor.dy >= center.dy;
  if (left) {
    return up ? GrowthDirection.upLeft : GrowthDirection.downLeft;
  }
  return up ? GrowthDirection.upRight : GrowthDirection.downRight;
}

/// The open-panel window rect: the pinned corner sits `anchorInset`
/// outward from the anchor, the body extending [size] in the growth
/// direction.
Rect panelRectFor(Offset anchor, Size size, GrowthDirection dir) {
  final inset = SrGeometry.anchorInset;
  final left = dir.growLeft
      ? anchor.dx + inset - size.width
      : anchor.dx - inset;
  final top = dir.growUp ? anchor.dy + inset - size.height : anchor.dy - inset;
  return Rect.fromLTWH(left, top, size.width, size.height);
}

/// The anchor a window rect implies — [panelRectFor]'s inverse, and the
/// orb window's ball center whatever the direction.
Offset anchorOf(Rect window, GrowthDirection dir) {
  final inset = SrGeometry.anchorInset;
  return switch (dir) {
    GrowthDirection.upLeft => Offset(
      window.right - inset,
      window.bottom - inset,
    ),
    GrowthDirection.upRight => Offset(
      window.left + inset,
      window.bottom - inset,
    ),
    GrowthDirection.downLeft => Offset(
      window.right - inset,
      window.top + inset,
    ),
    GrowthDirection.downRight => Offset(
      window.left + inset,
      window.top + inset,
    ),
  };
}

/// Shift [rect] the shortest way fully inside [workArea] — the
/// whole-unit clamp for header-drag moves (夹紧整窗矩形). A rect larger
/// than the work area on an axis pins to that axis' near edge.
Rect clampRectIntoWorkArea(Rect rect, Rect workArea) {
  var dx = 0.0;
  var dy = 0.0;
  if (rect.width <= workArea.width) {
    if (rect.left < workArea.left) dx = workArea.left - rect.left;
    if (rect.right > workArea.right) dx = workArea.right - rect.right;
  } else {
    dx = workArea.left - rect.left;
  }
  if (rect.height <= workArea.height) {
    if (rect.top < workArea.top) dy = workArea.top - rect.top;
    if (rect.bottom > workArea.bottom) dy = workArea.bottom - rect.bottom;
  } else {
    dy = workArea.top - rect.top;
  }
  return rect.shift(Offset(dx, dy));
}

/// The ceiling every panel size clamps to, per axis: at most 70% of the
/// work area AND at most the space between the pinned corner and the
/// opposite work-area edge. The resize gesture freezes the window at
/// this size while the card grows inside it by layout alone (ticket 20:
/// a per-frame HWND resize forces the engine to rebuild its EGL surface
/// and stretch stale pixels across the client area — the reshape
/// ghosting).
Size maxPanelSize(Offset anchor, GrowthDirection dir, Rect workArea) {
  final inset = SrGeometry.anchorInset;
  final fitWidth = dir.growLeft
      ? anchor.dx + inset - workArea.left
      : workArea.right - (anchor.dx - inset);
  final fitHeight = dir.growUp
      ? anchor.dy + inset - workArea.top
      : workArea.bottom - (anchor.dy - inset);
  return Size(
    math.min(fitWidth, workArea.width * SrGeometry.panelMaxWorkAreaFraction),
    math.min(fitHeight, workArea.height * SrGeometry.panelMaxWorkAreaFraction),
  );
}

/// Clamp a panel-size intent to what the anchor can actually host:
/// [maxPanelSize] above as the ceiling, the floor at least. The floor
/// yields only when even the minimum would not fit — staying on screen
/// wins (degenerate screens).
Size clampPanelSize(
  Size intent,
  Offset anchor,
  GrowthDirection dir,
  Rect workArea,
) {
  final ceiling = maxPanelSize(anchor, dir, workArea);
  return Size(
    _clampAxis(intent.width, SrGeometry.panelMinSize.width, ceiling.width),
    _clampAxis(intent.height, SrGeometry.panelMinSize.height, ceiling.height),
  );
}

double _clampAxis(double intent, double floor, double ceiling) {
  if (ceiling < floor) return ceiling; // degenerate: on screen > floor
  return intent.clamp(floor, ceiling);
}

/// Whether a persisted anchor may come back to life: the whole orb
/// footprint must sit inside SOME current work area (显示器拓扑变化时
/// 整组丢弃回默认,不夹紧复活). Flush edges count as inside.
bool anchorRestorable(Offset anchor, List<Rect> workAreas) {
  final inset = SrGeometry.anchorInset;
  for (final wa in workAreas) {
    if (anchor.dx >= wa.left + inset &&
        anchor.dx <= wa.right - inset &&
        anchor.dy >= wa.top + inset &&
        anchor.dy <= wa.bottom - inset) {
      return true;
    }
  }
  return false;
}

/// The full geometry plan for opening a panel at an anchor: the derived
/// direction, the effective size (intent clamped to what fits), and the
/// window rect. By construction the rect lies inside [workArea].
({GrowthDirection dir, Size size, Rect window}) expandPlan(
  Offset anchor,
  Size panelIntent,
  Rect workArea,
) {
  final dir = chooseGrowthDirection(anchor, workArea);
  final size = clampPanelSize(panelIntent, anchor, dir, workArea);
  return (dir: dir, size: size, window: panelRectFor(anchor, size, dir));
}
