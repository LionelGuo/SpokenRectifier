/// The orb — one widget for every state, never leaving the tree while a
/// stage is open (编舞铁律: the ball is the only continuous element).
///
/// Standalone (orb stage): idle mic ball / inserted ✓ / cancelled ✕.
/// Socketed (panel stages): recording stop + live mic ring, rectifying
/// spinner (disabled), preview paste-confirm, quick close ✕.
///
/// Recording dynamics are non-size by design: the ball core stays 56px;
/// liveliness comes from the mic-level arc ring, the glow halo and glyph
/// crossfades — never from scaling the ball itself.

library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../design/tokens.dart';
import '../rust/api.dart' show BridgeSessionState;
import 'session_flow.dart' show StageKind;

/// Visual overshoot of decorations beyond the 56px core (socket, ring,
/// glow). Clip.none lets them paint outside the box.
const _overshoot = 6.0;

/// The resting error pin's diameter (incl. its rim).
const _badgeSize = 12.0;

class OrbButton extends StatefulWidget {
  const OrbButton({
    super.key,
    required this.controller,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final SpeechController controller;

  /// Orb-drag intents (ticket 20), resolved by the raw-pointer tracker
  /// below: the press crossed [SrGeometry.dragThreshold] while the orb
  /// was free to move (idle, no panel). Positions, not deltas — the
  /// stage host maps them onto the window against a screen-stable
  /// cursor (view-relative deltas lag and bounce as the window chases
  /// the pointer). Null (pure-UI tests) disables dragging; clicks are
  /// unaffected.
  final void Function(Offset pointer)? onDragStart;
  final void Function(Offset pointer)? onDragUpdate;
  final void Function()? onDragEnd;

  @override
  State<OrbButton> createState() => _OrbButtonState();
}

class _OrbButtonState extends State<OrbButton> {
  bool _hover = false;
  bool _pressing = false;

  /// The primary press under threshold resolution: where it went down
  /// and whether it resolved into a drag.
  Offset? _down;
  bool _dragging = false;

  SpeechController get c => widget.controller;

  bool get _draggable =>
      widget.onDragUpdate != null && c.stage == StageKind.orb;

  void _onPointerDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    _down = e.position;
    _dragging = false;
    setState(() => _pressing = true);
    // Grab is sampled on down so the 8px slop still rides with the
    // first armed update (the host prefers a screen-stable cursor
    // when the platform has one).
    if (_draggable) widget.onDragStart?.call(e.position);
  }

  void _onPointerMove(PointerMoveEvent e) {
    final down = _down;
    if (down == null) return;
    if (!_dragging) {
      if ((e.position - down).distance <= SrGeometry.dragThreshold) return;
      if (!_draggable) return;
      _dragging = true;
    }
    widget.onDragUpdate?.call(e.position);
  }

  void _onPointerUp(PointerUpEvent e) {
    final wasDragging = _dragging;
    final wasPress = _down != null;
    _down = null;
    _dragging = false;
    setState(() => _pressing = false);
    // End any grab sampled on down (even a click that never armed), so
    // the host does not keep a live grab across the session expand.
    if (wasPress) widget.onDragEnd?.call();
    if (!wasDragging && wasPress && _OrbLook.of(c).clickable) {
      // A release inside the slop: the click path — the same table the
      // hotkey steps through.
      c.orbPrimary();
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    final wasPress = _down != null;
    _down = null;
    _dragging = false;
    setState(() => _pressing = false);
    if (wasPress) widget.onDragEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final look = _OrbLook.of(c);

    return Tooltip(
      // A startup/config error rides the tooltip while the orb idles:
      // there is no panel surface to carry it, and hiding it silently
      // is worse.
      message: look.tooltipFor(c),
      waitDuration: SrMotion.tooltipWait,
      child: MouseRegion(
        cursor: look.clickable
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Listener(
          // Left clicks are threshold-resolved here (8px slop, not the
          // arena's ~18px — the drag must arm before the arena would
          // give up on the tap, and two tap deciders would double-fire
          // in the band between). Only the right click still rides the
          // arena below.
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: (_) => c.orbSecondary(),
            child: SizedBox(
              width: SrGeometry.orbFootprint.width,
              height: SrGeometry.orbFootprint.height,
              child: AnimatedScale(
                // Micro-feedback only; the core never breathes by scale.
                // 1.04 keeps even the aura's outermost alpha (46px) inside
                // the footprint (46 * 1.04 = 47.8 < 48).
                scale: _pressing
                    ? 0.96
                    : (_hover && look.clickable ? 1.04 : 1.0),
                duration: SrMotion.fast,
                curve: SrMotion.curveMicro,
                child: AnimatedBuilder(
                  animation: c,
                  builder: (context, _) => Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Ambient shadow + recording glow, gradient-painted
                      // with alpha reaching EXACTLY zero at
                      // orbMaskFadeEnd from the ball center. No BoxShadow
                      // blur and no mask layer: nothing here can ever be
                      // cut by a square boundary (window rect or shader
                      // saveLayer box) — see _OrbAura.
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _OrbAura(
                            pal: pal,
                            glow: look.glow,
                            level: c.micLevel,
                          ),
                        ),
                      ),
                      Center(
                        child: SizedBox(
                          width: SrGeometry.orbBall,
                          height: SrGeometry.orbBall,
                          child: AnimatedContainer(
                            duration: SrMotion.emphasize,
                            curve: SrMotion.curveEmphasized,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: look.fill(pal),
                              border: Border.all(color: look.border(pal)),
                            ),
                            child: Center(child: look.glyph(pal)),
                          ),
                        ),
                      ),
                      if (look.ring)
                        Positioned(
                          left:
                              (SrGeometry.orbFootprint.width -
                                  SrGeometry.orbBall -
                                  2 * _overshoot) /
                              2,
                          top:
                              (SrGeometry.orbFootprint.height -
                                  SrGeometry.orbBall -
                                  2 * _overshoot) /
                              2,
                          width: SrGeometry.orbBall + 2 * _overshoot,
                          height: SrGeometry.orbBall + 2 * _overshoot,
                          child: CustomPaint(
                            painter: _LevelRing(pal: pal, level: c.micLevel),
                          ),
                        ),
                      // A pending error while the orb rests: a live-color
                      // pin on the ball's top-right edge saying only
                      // "something needs attention"; the tooltip carries
                      // the message (there is no panel to open — the
                      // engine never assembled).
                      if (c.orbErrorPending)
                        Positioned(
                          key: const Key('orb-error-badge'),
                          left:
                              SrGeometry.orbFootprint.center(Offset.zero).dx +
                              (SrGeometry.orbBall / 2) * math.sin(math.pi / 4) -
                              _badgeSize / 2,
                          top:
                              SrGeometry.orbFootprint.center(Offset.zero).dy -
                              (SrGeometry.orbBall / 2) * math.sin(math.pi / 4) -
                              _badgeSize / 2,
                          width: _badgeSize,
                          height: _badgeSize,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: pal.live,
                              // A surface-colored rim separates the pin
                              // from both the ball and the backdrop.
                              border: Border.all(color: pal.surface, width: 3),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ambient shadow and recording glow, painted as explicit radial
/// gradients whose alpha reaches EXACTLY zero at
/// [SrGeometry.orbMaskFadeEnd] (46px) from the ball center — 2px inside
/// the footprint edge (48px).
///
/// This replaces the earlier BoxShadow-blur + ShaderMask combination:
/// a blurred shadow's gaussian tail extends past any containment you
/// draw around it, and both the window rectangle and the mask's own
/// square saveLayer boundary showed up as hard square cuts in preview
/// rounds. A gradient that ends at zero has no tail to cut.
class _OrbAura extends CustomPainter {
  const _OrbAura({required this.pal, required this.glow, required this.level});

  final SrPalette pal;

  /// Recording glow halo.
  final bool glow;

  /// Mic loudness, 0..1 (synthesized from the speaking boolean).
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final lvl = level.clamp(0.0, 1.0);
    final budget = SrGeometry.orbMaskFadeEnd;

    // Ambient shadow: soft disc offset downward like the old BoxShadow.
    // The offset keeps its farthest point inside the containment budget.
    const shadowOffset = Offset(0, 6);
    final shadowCenter = center + shadowOffset;
    final shadowRadius = budget - shadowOffset.distance;
    final shadow = Paint()
      ..shader = ui.Gradient.radial(
        shadowCenter,
        shadowRadius,
        [
          pal.scrim.withValues(alpha: 0.30),
          pal.scrim.withValues(alpha: 0.12),
          const Color(0x00000000),
        ],
        const [0.0, 0.55, 1.0],
      );
    canvas.drawCircle(shadowCenter, shadowRadius, shadow);

    // Recording glow: intensity follows the mic level; the disc grows a
    // little with it but always ends at zero within the budget.
    if (glow) {
      final alpha = 0.16 + lvl * 0.30;
      final radius =
          SrGeometry.orbMaskFadeStart +
          lvl * (budget - SrGeometry.orbMaskFadeStart);
      final halo = Paint()
        ..shader = ui.Gradient.radial(
          center,
          radius,
          [
            pal.live.withValues(alpha: alpha),
            pal.live.withValues(alpha: alpha * 0.5),
            const Color(0x00000000),
          ],
          const [0.0, 0.5, 1.0],
        );
      canvas.drawCircle(center, radius, halo);
    }
  }

  @override
  bool shouldRepaint(_OrbAura oldDelegate) =>
      oldDelegate.glow != glow ||
      oldDelegate.level != level ||
      oldDelegate.pal != pal;
}

/// Mic-level gauge: faint circular track plus a live arc whose sweep
/// follows the synthesized loudness. Painted outside the ball core.
class _LevelRing extends CustomPainter {
  const _LevelRing({required this.pal, required this.level});

  final SrPalette pal;

  /// Mic loudness, 0..1.
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = rect.shortestSide / 2 - 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = pal.liveSoft;
    canvas.drawCircle(center, radius, track);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..color = pal.live;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      level.clamp(0.0, 1.0) * math.pi * 5 / 3,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_LevelRing old) => old.level != level;
}

// ---------------------------------------------------------------------------
// Per-state look
// ---------------------------------------------------------------------------

final class _OrbLook {
  const _OrbLook({
    required this.glyph,
    required this.fill,
    required this.border,
    required this.clickable,
    required this.tooltip,
    this.ring = false,
    this.glow = false,
  });

  final Widget Function(SrPalette) glyph;
  final Color Function(SrPalette) fill;
  final Color Function(SrPalette) border;
  final bool clickable;

  /// Hover hint for the current role.
  final String tooltip;

  /// Recording mic-level arc ring.
  final bool ring;

  /// Recording glow halo.
  final bool glow;

  /// The orb rests with a pending error: the tooltip carries it.
  String tooltipFor(SpeechController c) =>
      c.orbErrorPending ? c.lastError! : tooltip;

  static _OrbLook of(SpeechController c) {
    switch (c.stage) {
      case StageKind.quick:
        return closeLook();
      case StageKind.session:
        switch (c.phase) {
          case BridgeSessionState.recording:
            return _OrbLook(
              glyph: (pal) =>
                  Icon(Icons.stop_rounded, color: Colors.white, size: 26),
              fill: (pal) => pal.live,
              border: (pal) => pal.live,
              clickable: true,
              tooltip: '结束录入',
              ring: true,
              glow: true,
            );
          case BridgeSessionState.rectifying:
            return _OrbLook(
              glyph: (pal) => const _Spinner(size: 22),
              fill: (pal) => pal.surfaceRaised,
              border: (pal) => pal.hairline,
              clickable: false,
              tooltip: '修正中…',
            );
          case BridgeSessionState.preview:
            return _OrbLook(
              glyph: (pal) =>
                  Icon(Icons.check_rounded, color: pal.onAccent, size: 30),
              fill: (pal) => pal.accent,
              border: (pal) => pal.accent,
              clickable: true,
              tooltip: '确认粘贴 · Enter',
            );
          default:
            return closeLook();
        }
      case StageKind.orb:
        switch (c.orbFlash) {
          case OrbFlash.inserted:
            return _OrbLook(
              glyph: (pal) =>
                  Icon(Icons.check_rounded, color: pal.success, size: 30),
              fill: (pal) => pal.successSoft,
              border: (pal) => pal.success,
              clickable: false,
              tooltip: '已插入',
            );
          case OrbFlash.cancelled:
            return _OrbLook(
              glyph: (pal) =>
                  Icon(Icons.close, color: pal.textTertiary, size: 24),
              fill: (pal) => pal.surfaceRaised,
              border: (pal) => pal.hairline,
              clickable: false,
              tooltip: '已取消',
            );
          case OrbFlash.none:
            return _OrbLook(
              glyph: (pal) => Icon(
                Icons.mic_none_rounded,
                color: pal.textPrimary,
                size: 26,
              ),
              fill: (pal) => pal.surfaceRaised,
              border: (pal) => pal.hairline,
              clickable: true,
              tooltip: '点击开始口述 · 右键快捷设置',
            );
        }
    }
  }

  static _OrbLook closeLook() => _OrbLook(
    glyph: (pal) => Icon(Icons.close, color: pal.textSecondary, size: 22),
    fill: (pal) => pal.surfaceRaised,
    border: (pal) => pal.hairline,
    clickable: true,
    tooltip: '关闭 · Esc',
  );
}

/// Small indeterminate arc spinner for the rectifying state.
class _Spinner extends StatefulWidget {
  const _Spinner({required this.size});

  final double size;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: SrMotion.spin,
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          painter: _ArcSpinner(pal: pal, t: _ctrl.value),
        ),
      ),
    );
  }
}

class _ArcSpinner extends CustomPainter {
  const _ArcSpinner({required this.pal, required this.t});

  final SrPalette pal;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.5
      ..color = pal.textSecondary;
    canvas.drawArc(
      rect.deflate(2),
      t * 2 * math.pi,
      1.5 * math.pi / 2,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_ArcSpinner old) => old.t != t;
}
