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

  /// Session text — the dictated / rectified body copy. The 1.7 line
  /// height (2026-09-09 验收定, was 1.6) gives the taller capsule family
  /// room per line so its optical asymmetry reads less contrasted.
  static const bodyLarge = TextStyle(fontSize: 15, height: 1.7);

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

  /// Surface fades: row hover fills and reveal groups. Longer than
  /// [fast], with the symmetric [curveFade] — the micro curve's fast
  /// start reads as a snap, not a gradient.
  static const fade = Duration(milliseconds: 180);

  /// Content entrance after a window jump.
  static const enter = Duration(milliseconds: 240);

  /// Content exit before a window shrink. Faster than entrance: leave
  /// quickly, arrive gracefully.
  static const exit = Duration(milliseconds: 150);

  /// Anchor morphs (ball glyph / role changes) and emphasized moves.
  static const emphasize = Duration(milliseconds: 320);

  /// The panel card's grow choreography (11 号票 / 07 prototype): the
  /// card grows from the socket disc (窝圆, side 2×R) to the shared
  /// footprint — width and height along a constant radius — in BOTH
  /// directions on [curveEmphasized]. Long on purpose: 240/320 both
  /// read as rushed against the non-linear growth.
  static const grow = Duration(milliseconds: 640);

  /// The quadrant switch's spring (12 号票 / 08 prototype), one per
  /// axis: critically damped (damping = 2√(mass·stiffness) ≈ 33.5),
  /// a ≈340ms settle feel. The card's per-axis form value rides it; a
  /// threshold flip swaps the TARGET mid-flight carrying position and
  /// velocity — the clock never restarts (重定向只换目标、速度连续).
  /// Kept apart from [grow]: the switch is a hand-following,
  /// retargetable motion; the grow a fixed ceremonial timeline.
  static const quadSpringMass = 1.0;
  static const quadSpringStiffness = 280.0;

  /// Inserted / cancelled flash on the ball before it rests back to idle.
  static const feedback = Duration(milliseconds: 900);

  /// One breathing period for the recording glow (non-size dynamics).
  static const breathe = Duration(milliseconds: 2200);

  /// Indeterminate spinner period (the rectifying anchor glyph).
  static const spin = Duration(milliseconds: 1100);

  /// Hover-tooltip reveal delay — an interaction affordance, listed here
  /// so no duration lives outside the table.
  static const tooltipWait = Duration(milliseconds: 500);

  /// Toast dwell: a success confirmation leaves quickly, an error
  /// notice lingers (ui-copy toast spec: 成功 2000 / 错误 3000, both
  /// click-to-dismiss and new-replaces-old).
  static const toastSuccess = Duration(milliseconds: 2000);
  static const toastError = Duration(milliseconds: 3000);

  static const curveEnter = Curves.easeOutCubic;
  static const curveExit = Curves.easeInCubic;
  static const curveEmphasized = Curves.easeInOutCubicEmphasized;

  /// Micro-feedback (hover/press scale snaps).
  static const curveMicro = Curves.easeOut;

  /// Symmetric surface fades (row hover fills, reveal groups): a slow
  /// start reads as a gradient where [curveMicro]'s fast start would
  /// read as a snap.
  static const curveFade = Curves.easeInOut;
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
  /// The design default; user-resized panels override it at runtime
  /// (ticket 20), this stays the restore default.
  static const panelSize = Size(420.0, 560.0);

  /// Floor for the user-resizable shared footprint (spec §3 拖拽与尺寸
  /// 调节; yields only on degenerate screens where even this would not
  /// fit — staying on screen wins).
  static const panelMinSize = Size(360.0, 440.0);

  /// Ceiling for the shared footprint as a per-axis fraction of the
  /// current work area. Half (02 号票改判, was 0.70): with the panel-
  /// period window at the whole work area, a card capped at half spans
  /// exactly flush with the work-area edge at the moment its anchor
  /// crosses the center — the quadrant switch is possible from ANY
  /// anchor position, never clipped by the ceiling.
  static const panelMaxWorkAreaFraction = 0.50;

  /// Margin between the window edge and the panel card — the third
  /// concentric ring value: the panel corner radius is
  /// anchorInset - cardMargin (= 48 - 8 = 40).
  static const cardMargin = 8.0;

  /// Distance from the window's bottom-right corner to the anchor center
  /// (orb footprint half). Panel anchor buttons sit at this offset.
  static const anchorInset = 48.0;

  /// The HEADER row's orb-side reserve (spec §3 四向 chrome 契约): the
  /// footer keeps the bare [anchorInset] (ball-core overlap 43 + 5px
  /// seam), but the header band can carry the recording orb, whose level
  /// ring extends 6px past the ball horizontally — 48 + 8 keeps ~8px
  /// beyond the ring's outer edge.
  static const anchorHeaderReserve = anchorInset + 8;

  /// Pointer slop before a press resolves as a drag instead of a click
  /// (logical px; spec §3 拖拽与尺寸调节 — inside it, the window never
  /// moves and the press stays a tap).
  static const dragThreshold = 8.0;

  /// The resize hit strips' thickness on the panel's free edges, and
  /// the free-corner square's side (its zone overrides the strips where
  /// they meet).
  static const resizeEdgeHit = 6.0;
  static const resizeCornerHit = 16.0;
}

// ---------------------------------------------------------------------------
// Capsule family (placeholder capsules)
// ---------------------------------------------------------------------------

/// The placeholder capsule family's own geometry — one table for both
/// faces: the stream 号圆 (listening / rectifying, ticket 21) and the
/// preview fill capsule (ticket 22). The pill's vertical placement is
/// computed from the line's ink box, never a locked pixel — with one
/// deliberate exception: [opticalEase], the safe downward nudge that
/// keeps the pill from riding high over its glyphs (08 号票's 绝对相等
/// refined by the 23 号 acceptance rounds).
abstract final class SrCapsule {
  /// The fill capsule's pill height — also the caret's uniform height,
  /// the ceiling the selection clamps under, and the stream 号圆's own
  /// diameter: the listening/rectifying marker IS the family's
  /// degenerate capsule, its width squeezed until the two caps meet
  /// as one circle (2026-09-09 反馈九: one geometry for both faces,
  /// retiring the 号圆's private 18). 23 (2026-09-09 验收, was 22): one
  /// pixel taller, riding the 1.7 line height, so the remaining
  /// optical asymmetry contrasts less.
  static const double height = 23.0;

  /// The number chip's cap circle diameter (the fill capsule's left cap,
  /// always the pill's full height — the cap is a true semicircle).
  static const double chipCircle = 23.0;

  /// Breathing room between the chip and the value's first character
  /// (2026-09-09 验收反馈十: narrowed from 4 to 2; 2026-09-10 反馈十七
  /// trial: 0 — the value starts flush at the cap circle's edge).
  static const double chipGap = 0.0;

  /// The pill's right padding — the breathing room inside the pill past
  /// the value's last character, also the empty capsule's cursor parking
  /// space (空胶囊右侧留空位作光标落点; 08 号票; 2026-09-09 验收定 9;
  /// 2026-09-10 反馈十七 trial: 12).
  static const double valuePad = 12.0;

  /// Breathing room between the pill's caps and the neighbouring text —
  /// reserved in layout on both sides (the chip's leading spacer, and the
  /// per-slot reservation placeholder after the value), never painted over
  /// the neighbours' ink. CONSTANT everywhere: the pill keeps it at a
  /// line's start and end too (2026-09-10 反馈十六 re-ruling, retiring the
  /// line-edge swallows of 反馈四②/十三 — the number-to-value distance and
  /// the capsule-to-capsule gap may never depend on what neighbours hold),
  /// so every outside dock keeps a clickable background strip. 4 (was 6):
  /// the narrower constant softens the line-start indent the retired flush
  /// leaves behind.
  static const double sidePad = 4.0;

  /// Selection boxes never reach the capsule's full height.
  static const double selectionHeight = 20.0;

  /// The caret's stroke width.
  static const double caretWidth = 2.5;

  /// The whole chrome anchor's downward nudge, as a fraction of the
  /// face's font size (2026-09-09 验收裁定). The line ink box's center —
  /// a TYPOGRAPHIC box (font ascent/descent, accent headroom included) —
  /// sits measurably above the glyphs' true ink center on the real
  /// resolution fonts (measured from the font tables, centers above the
  /// baseline in em: YaHei '中' ink 0.349 vs box 0.398, YaHei digits
  /// 0.378 vs 0.398, Segoe digits 0.350 vs 0.414; SimSun 0.361 vs
  /// 0.359 is the near-neutral outlier). Dropping the anchor 0.02em
  /// lands the dominant fonts at even-to-slightly-high (never
  /// fill-below-wider); only the legacy SimSun fallback flips by a
  /// sub-visible ~0.6px. A deliberate constant, small by design — not
  /// per-font tuning (标号/选区/光标/号圆同锚下移, 药丸不再骑高).
  static const double opticalEase = 0.02;
}
