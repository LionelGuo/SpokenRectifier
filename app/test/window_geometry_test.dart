/// Unit tests for the orb-anchored window geometry (ticket 20's pure
/// core): quadrant chooser, anchor clamp, panel rect ↔ anchor round
/// trip, whole-unit work-area clamp, effective-size caps, restorability,
/// and the expand plan that composes them.

library;

import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/src/design/tokens.dart';
import 'package:spokenrectifier_app/src/shell/window_geometry.dart';

void main() {
  // 1080p minus a taskbar — the fixture work area.
  final wa = Rect.fromLTWH(0, 0, 1920, 1032);
  final waCenter = wa.center;

  group('chooseGrowthDirection', () {
    test('each quadrant grows away from it', () {
      expect(
        chooseGrowthDirection(const Offset(1500, 900), wa),
        GrowthDirection.upLeft,
      );
      expect(
        chooseGrowthDirection(const Offset(400, 900), wa),
        GrowthDirection.upRight,
      );
      expect(
        chooseGrowthDirection(const Offset(1500, 100), wa),
        GrowthDirection.downLeft,
      );
      expect(
        chooseGrowthDirection(const Offset(400, 100), wa),
        GrowthDirection.downRight,
      );
    });

    test('a pinned edge degrades the axis (贴边退化 is the special case)', () {
      // Ball clamped flush to the top edge: upper half → grows down.
      final pinnedTop = clampAnchor(const Offset(960, 0), wa);
      expect(pinnedTop.dy, wa.top + SrGeometry.anchorInset);
      expect(chooseGrowthDirection(pinnedTop, wa), GrowthDirection.downLeft);
    });

    test('exact ties grow up and left (the spec default)', () {
      expect(chooseGrowthDirection(waCenter, wa), GrowthDirection.upLeft);
    });
  });

  group('rederiveDirection (跨阈重推)', () {
    test('holds the current direction inside the center+48 band', () {
      // upLeft (grows left, anchor right of center): past the center
      // already, but not past it by 48 — the axis holds (未过中心只
      // 平移).
      expect(
        rederiveDirection(
          GrowthDirection.upLeft,
          Offset(waCenter.dx - 40, 900),
          wa,
        ),
        GrowthDirection.upLeft,
      );
      // Same on the vertical axis.
      expect(
        rederiveDirection(
          GrowthDirection.upLeft,
          Offset(1500, waCenter.dy - 40),
          wa,
        ),
        GrowthDirection.upLeft,
      );
    });

    test('flips the axis only past center+48 (the hysteresis band)', () {
      expect(
        rederiveDirection(
          GrowthDirection.upLeft,
          Offset(waCenter.dx - 49, 900),
          wa,
        ),
        GrowthDirection.upRight,
      );
      expect(
        rederiveDirection(
          GrowthDirection.upLeft,
          Offset(1500, waCenter.dy - 49),
          wa,
        ),
        GrowthDirection.downLeft,
      );
      // Both axes at once: the diagonal flip in one step.
      expect(
        rederiveDirection(
          GrowthDirection.upLeft,
          Offset(waCenter.dx - 49, waCenter.dy - 49),
          wa,
        ),
        GrowthDirection.downRight,
      );
    });

    test('flipping back needs the full band too — no chatter at the line', () {
      // Now growing right: the anchor sits just LEFT of the center;
      // flipping back to growing left needs center+48 to the right.
      expect(
        rederiveDirection(
          GrowthDirection.upRight,
          Offset(waCenter.dx + 40, 900),
          wa,
        ),
        GrowthDirection.upRight,
      );
      expect(
        rederiveDirection(
          GrowthDirection.upRight,
          Offset(waCenter.dx + 49, 900),
          wa,
        ),
        GrowthDirection.upLeft,
      );
    });

    test('agrees with chooseGrowthDirection far from the center', () {
      for (final anchor in const [
        Offset(1500, 900),
        Offset(400, 900),
        Offset(1500, 100),
        Offset(400, 100),
      ]) {
        final chosen = chooseGrowthDirection(anchor, wa);
        expect(
          rederiveDirection(chosen, anchor, wa),
          chosen,
          reason: 'anchor at $anchor',
        );
      }
    });
  });

  group('clampAnchor', () {
    test('an inside anchor is untouched', () {
      const anchor = Offset(1000, 500);
      expect(clampAnchor(anchor, wa), anchor);
    });

    test('an outside anchor lands flush, footprint fully inside', () {
      final clamped = clampAnchor(const Offset(1900, 1030), wa);
      final footprint = orbFootprintAt(clamped);
      // Edge comparisons, not Rect.contains: a flush landing touches the
      // work-area edge exactly and contains is bottom-right exclusive.
      expect(footprint.left, greaterThanOrEqualTo(wa.left));
      expect(footprint.top, greaterThanOrEqualTo(wa.top));
      expect(footprint.right, wa.right);
      expect(footprint.bottom, wa.bottom);
    });

    test('a work area smaller than the footprint settles at its center', () {
      final tiny = Rect.fromLTWH(0, 0, 60, 40);
      expect(clampAnchor(const Offset(10, 10), tiny), tiny.center);
    });
  });

  group('panelRectFor / anchorOf', () {
    test('upLeft keeps the orb window\'s corner (expand invisibility)', () {
      const anchor = Offset(1872, 984);
      final orbWindow = orbFootprintAt(anchor);
      final panel = panelRectFor(
        anchor,
        SrGeometry.panelSize,
        GrowthDirection.upLeft,
      );
      expect(panel.right, orbWindow.right);
      expect(panel.bottom, orbWindow.bottom);
      expect(panel.size, SrGeometry.panelSize);
    });

    test('anchorOf inverts panelRectFor in all four directions', () {
      const anchor = Offset(700, 400);
      for (final dir in GrowthDirection.values) {
        final rect = panelRectFor(anchor, SrGeometry.panelSize, dir);
        expect(anchorOf(rect, dir), anchor);
      }
    });

    test('anchorOf gives the orb window\'s center whatever the direction', () {
      final orbWindow = orbFootprintAt(const Offset(300, 300));
      for (final dir in GrowthDirection.values) {
        expect(anchorOf(orbWindow, dir), const Offset(300, 300));
      }
    });
  });

  group('clampRectIntoWorkArea', () {
    test('an inside rect is not shifted', () {
      const rect = Rect.fromLTWH(100, 100, 420, 560);
      expect(clampRectIntoWorkArea(rect, wa), rect);
    });

    test('an overhanging rect shifts flush by the shortest way', () {
      // Overhangs only horizontally (bottom 960 stays inside).
      final rect = Rect.fromLTWH(1600, 400, 420, 560);
      final clamped = clampRectIntoWorkArea(rect, wa);
      expect(clamped.right, wa.right);
      expect(clamped.top, rect.top);
    });

    test('a rect overhanging both sides of an axis pins to its near edge', () {
      final rect = Rect.fromLTWH(-50, 0, 2000, 300);
      final clamped = clampRectIntoWorkArea(rect, wa);
      expect(clamped.left, wa.left);
      expect(clamped.width, rect.width); // never resized, only moved
    });
  });

  group('clampPanelSize', () {
    test('the design default passes through at a roomy anchor', () {
      // The 1032-tall fixture work area caps the 560 intent at its half
      // (02 号票: 1080p+任务栏 → 420x516) — a taller area lets the
      // default through.
      final size = clampPanelSize(
        SrGeometry.panelSize,
        const Offset(1872, 984),
        GrowthDirection.upLeft,
        wa,
      );
      expect(size, const Size(420, 516));
      final tall = Rect.fromLTWH(0, 0, 1920, 1200);
      expect(
        clampPanelSize(
          SrGeometry.panelSize,
          const Offset(1872, 1112),
          GrowthDirection.upLeft,
          tall,
        ),
        SrGeometry.panelSize,
      );
    });

    test('the half-work-area ceiling caps both axes', () {
      final size = clampPanelSize(
        const Size(2000, 2000),
        const Offset(1872, 984),
        GrowthDirection.upLeft,
        wa,
      );
      expect(size.width, closeTo(1920 * 0.50, 1e-9));
      expect(size.height, closeTo(1032 * 0.50, 1e-9));
    });

    test('the anchor\'s own span caps tighter than half when it must', () {
      // Near the left edge growing left: the panel can only be as wide
      // as the room left of the pinned corner.
      final size = clampPanelSize(
        const Size(1344, 516),
        const Offset(500, 900),
        GrowthDirection.upLeft,
        wa,
      );
      expect(size.width, 500 + SrGeometry.anchorInset);
      expect(size.height, 516);
    });

    test('half-span cards are switchable at the flip point (02 号票)', () {
      // The property the 0.50 cap exists for: a card clamped under the
      // OLD direction still fits under the NEW one at the very
      // threshold the axis flips at — flush, never clipped. Horizontal
      // flip at center−48 (upLeft → upRight), threshold 912:
      final flipX = const Offset(912, 900);
      final sizeX = clampPanelSize(
        const Size(9999, 516),
        flipX,
        GrowthDirection.upLeft,
        wa,
      );
      final rectX = panelRectFor(flipX, sizeX, GrowthDirection.upRight);
      expect(rectX.left, greaterThanOrEqualTo(wa.left));
      expect(rectX.right, lessThanOrEqualTo(wa.right));
      // Vertical flip at center−48 (upLeft → downLeft), threshold 492:
      final flipY = const Offset(1400, 492);
      final sizeY = clampPanelSize(
        const Size(960, 9999),
        flipY,
        GrowthDirection.upLeft,
        wa,
      );
      final rectY = panelRectFor(flipY, sizeY, GrowthDirection.downLeft);
      expect(rectY.top, greaterThanOrEqualTo(wa.top));
      expect(rectY.bottom, lessThanOrEqualTo(wa.bottom));
    });

    test('the floor holds under the ceiling', () {
      final size = clampPanelSize(
        const Size(100, 100),
        const Offset(1872, 984),
        GrowthDirection.upLeft,
        wa,
      );
      expect(size, SrGeometry.panelMinSize);
    });

    test('a degenerate work area yields below the floor, not off screen', () {
      final tiny = Rect.fromLTWH(0, 0, 400, 500);
      final size = clampPanelSize(
        const Size(420, 560),
        const Offset(200, 250),
        GrowthDirection.upLeft,
        tiny,
      );
      expect(size.width, lessThan(SrGeometry.panelMinSize.width));
      expect(size.height, lessThan(SrGeometry.panelMinSize.height));
      final window = panelRectFor(
        const Offset(200, 250),
        size,
        GrowthDirection.upLeft,
      );
      expect(window.left, greaterThanOrEqualTo(tiny.left));
      expect(window.top, greaterThanOrEqualTo(tiny.top));
    });
  });

  group('maxPanelSize', () {
    test('is exactly the ceiling clampPanelSize caps to', () {
      const anchor = Offset(1060, 900);
      final ceiling = maxPanelSize(anchor, GrowthDirection.upLeft, wa);
      expect(
        clampPanelSize(
          const Size(9999, 9999),
          anchor,
          GrowthDirection.upLeft,
          wa,
        ),
        ceiling,
      );
    });

    test(
      'the freeze window it implies pins the anchor, on screen, every quadrant',
      () {
        // The resize gesture jumps the HWND to panelRectFor(anchor,
        // maxPanelSize) before growing the card by layout inside it: that
        // window must itself obey the anchor contract (iron law 1) and the
        // work area, and contain every smaller panel rect.
        for (final anchor in const [
          Offset(1872, 984),
          Offset(48, 984),
          Offset(1872, 48),
          Offset(48, 48),
        ]) {
          final dir = chooseGrowthDirection(anchor, wa);
          final frozen = panelRectFor(
            anchor,
            maxPanelSize(anchor, dir, wa),
            dir,
          );
          expect(anchorOf(frozen, dir), anchor, reason: 'anchor $anchor');
          expect(frozen.left, greaterThanOrEqualTo(wa.left));
          expect(frozen.top, greaterThanOrEqualTo(wa.top));
          expect(frozen.right, lessThanOrEqualTo(wa.right));
          expect(frozen.bottom, lessThanOrEqualTo(wa.bottom));
          // Every clamp-legal panel rect during the gesture sits inside the
          // frozen window (the slot is that rect shifted by its origin).
          final mid = clampPanelSize(SrGeometry.panelSize, anchor, dir, wa);
          final midRect = panelRectFor(anchor, mid, dir);
          expect(
            midRect.left >= frozen.left &&
                midRect.top >= frozen.top &&
                midRect.right <= frozen.right &&
                midRect.bottom <= frozen.bottom,
            isTrue,
            reason: 'anchor $anchor',
          );
        }
      },
    );
  });

  group('normalizeAreas', () {
    test('re-normalizes per-monitor reports into one window space', () {
      // Mixed-DPI desktop (17 号票): a 150% primary beside a 100%
      // secondary. screen_retriever divides each monitor's rcWork by
      // ITS OWN factor — rects that tile no single space. One window
      // dpr (1.5) must re-tile the whole desktop exactly.
      final areas = normalizeAreas([
        (reported: Rect.fromLTWH(0, 0, 1920, 1560), scaleFactor: 1.5),
        (reported: Rect.fromLTWH(2880, 0, 3840, 1560), scaleFactor: 1.0),
      ], 1.5);
      expect(areas.physical[0], const Rect.fromLTWH(0, 0, 2880, 2340));
      expect(areas.physical[1], const Rect.fromLTWH(2880, 0, 3840, 1560));
      expect(areas.logical[0], const Rect.fromLTWH(0, 0, 1920, 1560));
      expect(areas.logical[1], const Rect.fromLTWH(1920, 0, 2560, 1040));
      // Tiling: the secondary picks up exactly where the primary ends
      // — the dead zone the per-monitor normalization left is gone.
      expect(areas.logical[1].left, areas.logical[0].right);
      expect(areas.dpr, 1.5);
      expect(areas.factors, [1.5, 1.0]);
    });

    test('a non-positive window dpr degrades to identity', () {
      final areas = normalizeAreas([
        (reported: Rect.fromLTWH(0, 0, 1920, 1032), scaleFactor: 1.0),
      ], 0);
      expect(areas.logical.single, wa);
      expect(areas.dpr, 1.0);
    });
  });

  group('restoreAnchor', () {
    // A dpr-2 window snapshot of a mixed desktop: the primary's own
    // factor is 2, the secondary's is 1 — both logical rects share the
    // window's single divisor (2).
    const areas = WorkAreas(
      logical: [
        Rect.fromLTWH(0, 0, 1920, 1080),
        Rect.fromLTWH(1920, 0, 1920, 1080),
      ],
      physical: [
        Rect.fromLTWH(0, 0, 3840, 2160),
        Rect.fromLTWH(3840, 0, 3840, 2160),
      ],
      factors: [2.0, 1.0],
    );

    test('an anchor inside a work area restores in the snapshot space', () {
      expect(restoreAnchor(const Offset(1000, 500), areas), isNotNull);
      // The primary's own factor equals the snapshot divisor: identity.
      expect(
        restoreAnchor(const Offset(1000, 500), areas),
        const Offset(1000, 500),
      );
    });

    test('a save made on the other monitor revives through its factor', () {
      // Saved while the window sat on the secondary (divisor 1): the
      // value IS that monitor's physical coordinates.
      expect(
        restoreAnchor(const Offset(5760, 500), areas),
        const Offset(2880, 250),
      );
    });

    test('a flush anchor restores (edges count as inside)', () {
      final flush = Offset(wa.left + SrGeometry.anchorInset, wa.bottom - 48);
      expect(
        restoreAnchor(
          flush,
          WorkAreas(logical: [wa], physical: [wa], factors: [1.0]),
        ),
        flush,
      );
    });

    test('an anchor outside every work area discards (不夹紧复活)', () {
      expect(restoreAnchor(const Offset(9000, 500), areas), isNull);
      expect(
        restoreAnchor(
          const Offset(1000, 500),
          const WorkAreas(logical: [], physical: []),
        ),
        isNull,
      );
      expect(restoreAnchor(null, areas), isNull);
    });
  });

  group('expandPlan', () {
    test('composes direction, clamped size, and an on-screen rect', () {
      final plan = expandPlan(
        const Offset(1872, 984),
        SrGeometry.panelSize,
        wa,
      );
      expect(plan.dir, GrowthDirection.upLeft);
      // The 560 intent half-caps at 516 on the 1032-tall fixture (02
      // 号票).
      expect(plan.size, const Size(420, 516));
      expect(anchorOf(plan.window, plan.dir), const Offset(1872, 984));
      expect(plan.window.right, lessThanOrEqualTo(wa.right));
      expect(plan.window.bottom, lessThanOrEqualTo(wa.bottom));
      expect(plan.window.left, greaterThanOrEqualTo(wa.left));
      expect(plan.window.top, greaterThanOrEqualTo(wa.top));
    });

    test('an oversized intent fit-caps to the anchor\'s span', () {
      // Under the 0.50 cap a DERIVED direction always has span ≥ half,
      // so the span cap only binds for a direction the anchor has
      // outgrown — the size stays put across a mid-panel threshold flip
      // or a monitor topology change.
      final size = clampPanelSize(
        const Size(1344, 516),
        const Offset(700, 900),
        GrowthDirection.upLeft,
        wa,
      );
      expect(size.width, 700 + SrGeometry.anchorInset); // 748 < the 960 half
      // The card lands flush, never off screen.
      expect(
        panelRectFor(const Offset(700, 900), size, GrowthDirection.upLeft).left,
        wa.left,
      );
    });

    test('the anchor stays put in every quadrant (ball pixel-stationary)', () {
      for (final anchor in const [
        Offset(1872, 984),
        Offset(48, 984),
        Offset(1872, 48),
        Offset(48, 48),
      ]) {
        final plan = expandPlan(anchor, SrGeometry.panelSize, wa);
        expect(anchorOf(plan.window, plan.dir), anchor);
        // Edges compared (not Rect.contains): a flush landing touches
        // the work-area edge exactly, and contains is bottom-right
        // exclusive.
        expect(plan.window.left, greaterThanOrEqualTo(wa.left));
        expect(plan.window.top, greaterThanOrEqualTo(wa.top));
        expect(plan.window.right, lessThanOrEqualTo(wa.right));
        expect(
          plan.window.bottom,
          lessThanOrEqualTo(wa.bottom),
          reason: 'window inside work area for $anchor',
        );
      }
    });
  });
}
