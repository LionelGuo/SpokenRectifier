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

/// The direction after the anchor moved within an OPEN panel (02 号票
/// 跨阈重推): the current direction HOLDS until the anchor crosses the
/// work-area center by `anchorInset` — the hysteresis band that keeps a
/// ball parked near the center from chattering between quadrants — then
/// the axis flips toward the side it crossed to. Ties resolve like
/// [chooseGrowthDirection] (up/left). The direction is still derived,
/// never stored: it is re-derived on every threshold cross, not frozen
/// at expand.
GrowthDirection rederiveDirection(
  GrowthDirection current,
  Offset anchor,
  Rect workArea,
) {
  final center = workArea.center;
  final hyst = SrGeometry.anchorInset;
  final left = current.growLeft
      ? anchor.dx > center.dx - hyst
      : anchor.dx >= center.dx + hyst;
  final up = current.growUp
      ? anchor.dy > center.dy - hyst
      : anchor.dy >= center.dy + hyst;
  if (left) {
    return up ? GrowthDirection.upLeft : GrowthDirection.downLeft;
  }
  return up ? GrowthDirection.upRight : GrowthDirection.downRight;
}

/// The open-panel card rect for continuous per-axis form values (12
/// 号票): [gl]/[gu] = 1 pins the card's anchor edge `anchorInset`
/// outward on that side (grows left / up), 0 pins it on the opposite
/// side; a mid-value translates the card through the ball — the
/// quadrant switch's transit (球压卡内, the ball occludes topmost) —
/// with the socket disc concentric at every value. The endpoints
/// reproduce [panelRectFor] exactly.
Rect panelRectAt(
  Offset anchor,
  Size size, {
  required double gl,
  required double gu,
}) {
  final inset = SrGeometry.anchorInset;
  return Rect.fromLTWH(
    anchor.dx - inset - (size.width - inset * 2) * gl,
    anchor.dy - inset - (size.height - inset * 2) * gu,
    size.width,
    size.height,
  );
}

/// The open-panel window rect: the pinned corner sits `anchorInset`
/// outward from the anchor, the body extending [size] in the growth
/// direction.
Rect panelRectFor(Offset anchor, Size size, GrowthDirection dir) => panelRectAt(
  anchor,
  size,
  gl: dir.growLeft ? 1.0 : 0.0,
  gu: dir.growUp ? 1.0 : 0.0,
);

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

/// The ceiling every panel size clamps to, per axis: at most half of
/// the work area AND at most the space between the pinned corner and
/// the opposite work-area edge. The panel-period window is the whole
/// work area (02 号票), so this is the CARD's size cap — at half the
/// work area the card lands exactly flush with the edge at the quadrant
/// threshold, making the switch possible from any anchor. The resize
/// gesture never touches the HWND while the card grows inside it by
/// layout alone (ticket 20: a per-frame HWND resize forces the engine
/// to rebuild its EGL surface and stretch stale pixels across the
/// client area — the reshape ghosting).
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

/// One snapshot of the desktop's work areas in the window's coordinate
/// space (17 号票): screen_retriever reports each monitor normalized by
/// ITS OWN scale factor, which on a mixed-DPI desktop does not tile any
/// single space — the drag's cursor (÷ the window's dpr) falls into dead
/// zones between the reported areas, and a setBounds toward them (× the
/// window's possibly-stale dpr) lands the window physically misplaced.
/// The fix is ONE space: every monitor's rect de-normalized to global
/// physical, then divided by the SAME window dpr — a uniform scaling of
/// the physical desktop, so the areas tile exactly at any DPI mix. The
/// physical twins ride along: the OS move is commanded in physical
/// pixels, immune to every dpr lag.
class WorkAreas {
  const WorkAreas({
    required this.logical,
    required this.physical,
    this.factors = const [],
  });

  /// Work areas in the window's logical space (physical ÷ the window's
  /// dpr at snapshot time). Parallel to [physical].
  final List<Rect> logical;

  /// The same rects in global physical pixels — what the OS moves in.
  final List<Rect> physical;

  /// Each monitor's OWN scale factor (parallel; 1.0 when unstated) — the
  /// persisted-anchor revival needs per-monitor de-normalization.
  final List<double> factors;

  /// The single divisor the logical rects share (= the window's dpr when
  /// the snapshot was taken). 1.0 for degenerate snapshots.
  double get dpr {
    if (logical.isEmpty || logical.first.width <= 0) return 1.0;
    return physical.first.width / logical.first.width;
  }

  /// The physical twin of a logical area from this snapshot (the logical
  /// rect itself when it is not one of ours — tests' dpr-1 world).
  Rect physicalFor(Rect logicalArea) {
    final i = logical.indexOf(logicalArea);
    return i >= 0 ? physical[i] : logicalArea;
  }

  double _factorAt(int i) =>
      i < factors.length && factors[i] > 0 ? factors[i] : 1.0;
}

/// Re-normalize per-monitor reports into [WorkAreas]: a display's
/// reported rect is its physical rect ÷ its own scale factor, so × the
/// factor restores global physical exactly (screen_retriever rounds per
/// axis to integers on the way in); ÷ [windowDpr] then puts every area
/// into the window's single space.
WorkAreas normalizeAreas(
  List<({Rect reported, double scaleFactor})> displays,
  double windowDpr,
) {
  final divisor = windowDpr <= 0 ? 1.0 : windowDpr;
  final physical = [
    for (final d in displays)
      Rect.fromLTWH(
        d.reported.left * d.scaleFactor,
        d.reported.top * d.scaleFactor,
        d.reported.width * d.scaleFactor,
        d.reported.height * d.scaleFactor,
      ),
  ];
  return WorkAreas(
    logical: [
      for (final p in physical)
        Rect.fromLTWH(
          p.left / divisor,
          p.top / divisor,
          p.width / divisor,
          p.height / divisor,
        ),
    ],
    physical: physical,
    factors: [for (final d in displays) d.scaleFactor],
  );
}

/// Revive a persisted anchor (17 号票): the saved value lives in the
/// snapshot space of the session that wrote it (the window's dpr when
/// the ball parked — the window sits on the anchor's monitor then, so
/// the divisor is that monitor's own factor). Per area, un-scale by that
/// monitor's factor and test PHYSICAL containment — exact whichever
/// monitor hosted the save — then re-scale into the current snapshot
/// space. Null when no monitor hosts the footprint (显示器拓扑变化时整组
/// 丢弃回默认,不夹紧复活 — the old anchorRestorable verdict).
Offset? restoreAnchor(Offset? saved, WorkAreas areas) {
  if (saved == null || areas.logical.isEmpty) return null;
  final footprint = SrGeometry.orbFootprint;
  for (var i = 0; i < areas.logical.length; i++) {
    final f = areas._factorAt(i);
    final phys = Rect.fromCenter(
      center: Offset(saved.dx * f, saved.dy * f),
      width: footprint.width * f,
      height: footprint.height * f,
    );
    final areaP = areas.physical[i];
    if (phys.left >= areaP.left &&
        phys.right <= areaP.right &&
        phys.top >= areaP.top &&
        phys.bottom <= areaP.bottom) {
      return Offset(saved.dx * f / areas.dpr, saved.dy * f / areas.dpr);
    }
  }
  return null;
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

/// The work area holding [point]; the first (primary) when none does —
/// an anchor caught between display-topology changes still has to land
/// somewhere. An empty list is the caller's to guard (see the stage's
/// prime heal).
Rect areaHolding(Offset point, List<Rect> areas) {
  for (final area in areas) {
    if (point.dx >= area.left &&
        point.dx <= area.right &&
        point.dy >= area.top &&
        point.dy <= area.bottom) {
      return area;
    }
  }
  return areas.first;
}

/// The fallback anchor when nothing restores: 24px of daylight between
/// the orb footprint and the primary work area's bottom-right corner
/// (the footprint is 96 wide, so the anchor sits 24 + 48 inward).
Offset defaultAnchor(Rect primaryWorkArea) =>
    primaryWorkArea.bottomRight - const Offset(72, 72);
