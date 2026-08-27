/// Design tokens — the single source of truth for every visual value in
/// the app surface (ported verbatim from the approved prototype,
/// `prototype/lib/src/tokens.dart`; the two files must not diverge).
///
/// Rule: widgets never hardcode a color, size, radius, duration or curve.
/// Everything reads from this table so the spec doc in docs/design/ can
/// be extracted from code without divergence.

library;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

/// One palette per brightness. Surfaces are solid / tinted (no acrylic bet,
/// see the choreography decision record); depth comes from hairline borders
/// plus layered shadows.
class SrPalette {
  const SrPalette({
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceOverlay,
    required this.hairline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.accentText,
    required this.live,
    required this.liveSoft,
    required this.success,
    required this.successSoft,
    required this.scrim,
  });

  /// Panel background.
  final Color surface;

  /// Cards raised inside a panel (history rows, transcript quote block).
  final Color surfaceRaised;

  /// Fills sunk below raised cards (chips, text fields, toggles tracks).
  final Color surfaceOverlay;

  /// 1px border around surfaces and dividers.
  final Color hairline;

  final Color textPrimary;
  final Color textSecondary;

  /// Hints, placeholders, timestamps. Not for body copy.
  final Color textTertiary;

  /// Brand accent (azure). Interactive highlights and primary buttons.
  final Color accent;
  final Color onAccent;

  /// Accent at fill opacity for soft chips / focused wells.
  final Color accentSoft;

  /// Legible accent-tinted text, for labels on accentSoft fills.
  final Color accentText;

  /// Recording red and its soft fill.
  final Color live;
  final Color liveSoft;

  final Color success;
  final Color successSoft;

  /// Shadow color (alpha applied per shadow layer).
  final Color scrim;

  static const dark = SrPalette(
    surface: Color(0xFF1F232C),
    surfaceRaised: Color(0xFF272C38),
    surfaceOverlay: Color(0xFF2E3441),
    hairline: Color(0x1AFFFFFF),
    textPrimary: Color(0xFFF3F5F9),
    textSecondary: Color(0xFFADB5C4),
    textTertiary: Color(0xFF8A92A2),
    accent: Color(0xFF3E9BFF),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0x243E9BFF),
    accentText: Color(0xFF8CC4FF),
    live: Color(0xFFFF5D5D),
    liveSoft: Color(0x1FFF5D5D),
    success: Color(0xFF4ADE80),
    successSoft: Color(0x1F4ADE80),
    scrim: Color(0xFF000000),
  );

  static const light = SrPalette(
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF4F5F8),
    surfaceOverlay: Color(0xFFEEF0F4),
    hairline: Color(0x14000000),
    textPrimary: Color(0xFF1B1F27),
    textSecondary: Color(0xFF565E6E),
    textTertiary: Color(0xFF8A92A2),
    accent: Color(0xFF0B6BDB),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0x1A0B6BDB),
    accentText: Color(0xFF1B5FB8),
    live: Color(0xFFD93843),
    liveSoft: Color(0x1AD93843),
    success: Color(0xFF12805C),
    successSoft: Color(0x1A12805C),
    scrim: Color(0xFF0B1020),
  );
}

/// Palette for the current brightness.
SrPalette srPalette(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? SrPalette.dark
    : SrPalette.light;

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------

/// Type scale. CJK-first: generous line height, zero letter spacing.
class SrType {
  static const title = TextStyle(
    fontSize: 16,
    height: 1.4,
    fontWeight: FontWeight.w600,
  );

  /// Session text — the dictated / rectified body copy.
  static const bodyLarge = TextStyle(fontSize: 15, height: 1.6);

  /// Default UI body.
  static const body = TextStyle(fontSize: 14, height: 1.5);

  static const caption = TextStyle(fontSize: 12, height: 1.4);

  /// Timestamps, hints, kbd chips.
  static const micro = TextStyle(fontSize: 11, height: 1.35);

  static const kbd = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );
}

// ---------------------------------------------------------------------------
// Spacing & shape
// ---------------------------------------------------------------------------

abstract final class SrSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;

  /// Panel content inset — the D of the concentric content capsule: the
  /// gap between the card edge and content on straight edges. Rows that
  /// live inside the card's corner band use [cornerInset] instead.
  static const contentInset = 16.0;

  /// Corner-band inset — horizontal inset for rows inside the card's
  /// corner band (header / footer rows). Derived from the content
  /// capsule being concentric with the card corner arc: a visual corner
  /// at uniform radial gap D=contentInset from the arc (R=SrRadius.panel
  /// =40, arc center 40,40 from the card corner) lands at
  /// 40 − (40−16)/√2 ≈ 23 → the 4-grid value 24.
  static const cornerInset = 24.0;
}

abstract final class SrRadius {
  /// Small controls (chips, inputs, toggles).
  static const control = 6.0;

  /// Capsule (full pill) for corner-band controls whose rounded ends
  /// echo the concentric corner arc. Flutter clamps border radii to
  /// half the shorter side, so any large value yields a true capsule.
  static const capsule = 999.0;

  /// Panels and cards. Concentric with the orb: the corner circle's center
  /// coincides with the ball center (48px from the window's bottom-right
  /// corner), so R = anchorInset (48) - card margin (8) = 40. The ball
  /// visually docks into the panel's corner curve (12px ring of surface
  /// between ball edge and card edge).
  static const panel = 40.0;
}

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------

/// Durations and curves. The expand/collapse window jump itself is instant
/// (0 ms) on purpose — it is hidden by the content entrance / exit of the
/// same frame (跳变藏动画主案).
abstract final class SrMotion {
  /// Hover / press micro-feedback.
  static const fast = Duration(milliseconds: 120);

  /// Content entrance after a window jump.
  static const enter = Duration(milliseconds: 240);

  /// Content exit before a window shrink. Faster than entrance: leave
  /// quickly, arrive gracefully.
  static const exit = Duration(milliseconds: 150);

  /// Anchor morphs (ball glyph / role changes) and emphasized moves.
  static const emphasize = Duration(milliseconds: 320);

  /// Inserted / cancelled flash on the ball before it rests back to idle.
  static const feedback = Duration(milliseconds: 900);

  /// One breathing period for the recording glow (non-size dynamics).
  static const breathe = Duration(milliseconds: 2200);

  /// Indeterminate spinner period (the rectifying anchor glyph).
  static const spin = Duration(milliseconds: 1100);

  /// Hover-tooltip reveal delay — an interaction affordance, listed here
  /// so no duration lives outside the table.
  static const tooltipWait = Duration(milliseconds: 500);

  static const curveEnter = Curves.easeOutCubic;
  static const curveExit = Curves.easeInCubic;
  static const curveEmphasized = Curves.easeInOutCubicEmphasized;

  /// Micro-feedback (hover/press scale snaps).
  static const curveMicro = Curves.easeOut;
}

// ---------------------------------------------------------------------------
// Geometry (window footprints & anchors)
// ---------------------------------------------------------------------------

/// Window-level geometry. The ball is centered in its footprint so the
/// footprint's bottom-right corner sits (28 + margin) beyond the ball
/// center on both axes; panel surfaces keep their anchor button at the
/// exact same offset from the window's bottom-right corner, which makes
/// the expand jump keep the ball pixel-stationary.
abstract final class SrGeometry {
  /// The painted ball.
  static const orbBall = 56.0;

  /// Ball + symmetric bleed for glow / shadow. Ball center = 48,48.
  static const orbFootprint = Size(96, 96);

  /// Aura containment budget: the orb's ambient shadow and glow are
  /// painted as radial gradients that reach EXACTLY zero alpha at
  /// [orbMaskFadeEnd] from the ball center — 2px inside the footprint
  /// edge (48) — so no gaussian tail can ever be cut by the window
  /// rectangle or a shader layer boundary (a cut tail reads as a
  /// "semi-transparent box" behind the ball). The glow disc starts its
  /// growth at [orbMaskFadeStart].
  static const orbMaskFadeStart = 40.0;
  static const orbMaskFadeEnd = 46.0;

  /// Session panel and quick panel share one footprint (同形同位互斥).
  static const panelSize = Size(420.0, 560.0);

  /// Margin between the window edge and the panel card — the third
  /// concentric ring value: the panel corner radius is
  /// anchorInset - cardMargin (= 48 - 8 = 40).
  static const cardMargin = 8.0;

  /// Distance from the window's bottom-right corner to the anchor center
  /// (orb footprint half). Panel anchor buttons sit at this offset.
  static const anchorInset = 48.0;
}
