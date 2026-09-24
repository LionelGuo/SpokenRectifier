/// The thinking-stream marquee (04 号票's language, 09 号票's terminal
/// constants, landed by 14): rectify attempts that walk a thinking
/// channel stream the thinking TEXT as one-shot feedback — a shimmer
/// band from the first thinking token, a scrolling text band once
/// 「可视行数 + 容量」行 has buffered, and a one-way handover to the
/// rectified body on its first delta. Never retained, never scrolled
/// back, never part of the rectified text (ADR-0019 item 6).
///
/// Two pieces: [ThinkingMarquee] is the pure machine (line folding,
/// speed law, discard, growth, thresholds — a direct port of the 09
/// prototype's machine block, node-smoke-tested there), and
/// [ThinkingMarqueeOverlay] is its paint (a CustomPainter over the
/// whole painted card: shimmer sweep + masked text band).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../design/tokens.dart';

/// One folded line: its tape slot. Slots are ABSOLUTE — a discard
/// removes a slot's line, never renumbers the rest (09 trap ②: a
/// global offset would shift lines already on screen).
class _MarqueeLine {
  const _MarqueeLine(this.text, this.slot);
  final String text;
  final int slot;
}

/// The marquee machine (09 终值). Card geometry arrives with layout
/// ([setGeometry]); text pushed before then buffers and folds once the
/// width is known — the fold width is a layout fact, not a constant.
class ThinkingMarquee {
  ThinkingMarquee();

  // -- terminal constants (09 Answer; 照抄) ---------------------------
  static const double kSpeed = 0.75; // v = k × buffered lines
  static const double vMax = 2.2; // lines/s clamp
  static const double vMin = 0.75; // lines/s floor while material waits
  static const int capacity = 4; // buffered lines before discard
  static const int tauMs = 500; // speed low-pass
  static const double growPxS = 13; // band growth after reveal
  static const double lineH = 30; // 15px text, loose leading
  static const double charW = 15; // CJK fixed pitch (09's measure)
  static const double bandStartFrac = 0.30; // of card height
  static const double bandMaxFrac = 0.60;
  static const double shimmerFrac = 0.75;
  static const int sweepPassMs = 1600;
  static const int sweepPauseMs = 900;

  // -- geometry (set at layout) --------------------------------------
  double? _textW;
  double _startH = 0;
  double _maxH = 0;

  // -- feed state -----------------------------------------------------
  final List<String> _pending = []; // text awaiting geometry
  final List<_MarqueeLine> _queue = [];
  int _nextSlot = 0;
  int dropped = 0;
  String _partial = '';

  // -- motion state ----------------------------------------------------
  int simT = 0; // ms since the machine's birth
  double scrollPx = 0;
  double _vDisp = 0;
  double hPx = 0;
  bool revealed = false;
  int revealT0 = -1;
  int firstThinkT = -1;
  int handoverT = -1;

  /// The machine's geometry from the painted card's box. A changed fold
  /// width re-folds every line from the raw text (a resize mid-thinking
  /// is rare; the marquee is one-shot feedback, a re-fold is honest).
  void setGeometry(double cardW, double cardH) {
    final textW = (cardW - SrSpace.cornerInset * 2).clamp(0.0, double.infinity);
    final widthChanged = _textW != null && (_textW! - textW).abs() > 0.5;
    final firstGeometry = _textW == null;
    _textW = textW;
    _startH = cardH * bandStartFrac;
    _maxH = cardH * bandMaxFrac;
    if (hPx == 0) hPx = _startH;
    if (firstGeometry) {
      for (final text in _pending) {
        _pushChars(text);
      }
      _pending.clear();
    } else if (widthChanged && (_queue.isNotEmpty || _partial.isNotEmpty)) {
      // Re-fold from scratch at the new width.
      final all = [
        for (final line in _queue) line.text,
        if (_partial.isNotEmpty) _partial,
      ].join();
      _queue.clear();
      _nextSlot = 0;
      _partial = '';
      _pushChars(all);
    }
  }

  /// Thinking-channel text arrived (the 「正在思考」 signal itself —
  /// nothing shows until the first character does). Returns whether
  /// THIS call carried the first token (the caller starts its elapsed
  /// cadence off it).
  bool pushText(String delta) {
    final wasSilent = !thinkStarted;
    if (_textW == null) {
      _pending.add(delta);
      // First-think stamps at fold time; a buffered first delta counts
      // as started for the caller's purpose too.
      return wasSilent;
    }
    _pushChars(delta);
    return wasSilent;
  }

  void _pushChars(String text) {
    if (firstThinkT < 0) firstThinkT = simT;
    for (final ch in text.characters) {
      if (ch == '\n') {
        // A newline completes the line whatever its width (04: 换行符
        // 亦算凑满).
        _flushPartial();
        continue;
      }
      _partial += ch;
      if (_partial.characters.length * charW > _textW!) {
        final chars = _partial.characters.toList();
        final overflow = chars.removeLast();
        _takeLine(chars.join());
        _partial = overflow;
      }
    }
  }

  void _flushPartial() {
    if (_partial.isEmpty) return;
    _takeLine(_partial);
    _partial = '';
  }

  void _takeLine(String text) {
    _queue.add(_MarqueeLine(text, _nextSlot++));
    if (!revealed && _queue.length + dropped >= startVis + capacity) {
      revealed = true;
      revealT0 = simT;
      // Launch priming (21 号票): the fade-in shows the band ALREADY at
      // the law's speed. The low-pass would otherwise spend its 500ms
      // ramp eating the runway from a standstill (device: text appears
      // but barely moves at first). The frozen accumulation hands over
      // a full runway, so this primes to ~vMax whatever the stream's
      // pace.
      _vDisp = _targetV(windowTop(), hPx);
    }
  }

  /// The one-way handover latch: the rectified body's first delta. The
  /// region fades out; later thinking text still feeds the machine but
  /// never relights it (the fade is monotone in [view]).
  void handOver() {
    if (handoverT < 0) handoverT = simT;
  }

  /// The reveal gate counted at the START height (09: 凑满「起高可视
  /// 行数 + 容量」才现身——永不见半空条纹框).
  int get startVis => (_startH / lineH).round().clamp(1, 100);

  /// The band's ceiling (60% of the card) — the growth target.
  double get maxBandH => _maxH;

  /// Whether the first thinking token has arrived. Text buffered ahead
  /// of geometry counts: the header must flip the moment the signal
  /// does, not a layout later.
  bool get thinkStarted => firstThinkT >= 0 || _pending.isNotEmpty;

  /// Whether the handover latch has fired.
  bool get handedOver => handoverT >= 0;

  /// Whether anything paints at all (the mount gate; zero-trace is the
  /// null machine / never-started one).
  bool get hasVisual => thinkStarted && view().regionAlpha > 0.01;

  /// The window's tape-top: centered on screen, clamped never to ride
  /// above the alive head line (T monotone = 出顶即逝).
  double windowTop() {
    final raw = scrollPx - (hPx - _startH) / 2;
    final headTop = _queue.isNotEmpty ? _queue.first.slot * lineH : 0.0;
    return raw > headTop ? raw : headTop;
  }

  /// The tape as (text, slot) pairs — the paint loop's and the tests'
  /// read over the _queue without naming the private line type.
  List<(String, int)> get lineSnapshot => [
    for (final line in _queue) (line.text, line.slot),
  ];

  /// The unseen backlog in LINES: the _queue lines below the window's
  /// bottom edge (plus the fractional credit of the line entering it) —
  /// the honest 「已缓冲行数」 under discards. 09's formula read
  /// `_queue.length − bottom`, which equals this only while nothing has
  /// been dropped; under drops a discard that does not touch the tape's
  /// tail left its count unchanged and burned the whole buffer.
  double _backlog(double top, double h) {
    final bottomLines = (top + h) / lineH;
    final firstWaiting = bottomLines.ceil();
    var unseen = 0;
    for (final line in _queue) {
      if (line.slot >= firstWaiting) unseen++;
    }
    // Fractional credit for the entering line's still-unseen part.
    return unseen + (firstWaiting - bottomLines);
  }

  /// The speed law: v = k × buffered lines, floored while material
  /// waits (a slow trickle still crawls visibly — sub-floor rates
  /// decelerate into the line tails and read as stalling), clamped by
  /// vMax. A dry tape targets 0 — 停等缓停 (04 号票's ruling).
  double _targetV(double top, double h) {
    final b = _backlog(top, h);
    if (b <= 0) return 0;
    return math.min(vMax, math.max(kSpeed * b, vMin));
  }

  /// Advance the machine one frame. Ported step-for-step from 09's
  /// `stepMachine` (minus the scripted token generator — real deltas
  /// arrive through [pushText]).
  void tick(int dtMs) {
    simT += dtMs;
    final dt = dtMs / 1000;
    if (_textW == null) return;
    final tStart = windowTop();

    // Text band growth: after reveal, rise toward maxH — gated on spare
    // content (keep ≥ 0.5 line waiting), frozen on starvation,
    // monotonic (never shrinks).
    if (revealed && hPx < _maxH) {
      final prevH = hPx;
      final grew = hPx + growPxS * dt;
      hPx = grew < _maxH ? grew : _maxH;
      if (_backlog(windowTop(), hPx) < 0.5) hPx = prevH; // starved
    }

    // Speed: v = k × buffered (floored while material waits), clamp,
    // low-pass, integrate scroll — REVEALED ONLY (21 号票): nothing
    // paints before the reveal, and an integrating window would spend
    // the accumulation eating the capacity runway the launch rides
    // (device: slow streams revealed with the buffer already burned and
    // crawled from a standstill). The discard below still runs —
    // overflow protection does not care whether anyone is watching.
    if (revealed) {
      var top = windowTop();
      final vTarget = _targetV(top, hPx);
      _vDisp += (vTarget - _vDisp) * (1 - math.exp(-dtMs / tauMs));
      scrollPx += _vDisp * dt * lineH;
      // Park clamp (停等): the window's bottom never passes the last
      // alive line — pinned HERE, before the overshoot can exist,
      // because trimming after the fact (09's belt) drags visible
      // content downward. The growth gate keeps T + h ≤ lastEnd
      // inductively (the frozen reveal starts with T=0, h=startH and
      // the gate's startVis+capacity lines below), so this only ever
      // shaves the current tick's overshoot.
      if (_queue.isNotEmpty) {
        final lastEnd = (_queue.last.slot + 1) * lineH;
        final maxScroll = lastEnd - hPx + (hPx - _startH) / 2;
        if (scrollPx > maxScroll) scrollPx = maxScroll;
      }

      // T 单调 by construction (出顶即逝): the band's growth pulls the
      // centered window back up the tape; when the (low-passed) scroll
      // cannot pay for it — v still recovering from a stall — hold the
      // window where it was instead of letting content regress downward.
      final tNow = windowTop();
      if (tNow < tStart) {
        scrollPx += tStart - tNow;
      }
    }

    // Bounded discard: whole unseen LINES beyond capacity sacrifice
    // the OLDEST not-yet-shown line — the first _queue entry at or
    // past ceil(bottom edge). The splice COMPRESSES the waiting tape
    // below the victim (every later line's slot steps down one): the
    // lines already on screen keep their slots (09 trap ②), and the
    // window never faces a dropped slot as blank tape — under a
    // stream faster than vMax the plain splice opens a desert the
    // window cannot cross (device: first page shows, then nothing
    // for the whole attempt). The compression lives wholly below the
    // bottom edge; the reader sees line N then N+2, never a gap.
    final topNow = windowTop();
    final bottomLines = (topNow + hPx) / lineH;
    final firstWaiting = bottomLines.ceil();
    final unseen = _queue.where((line) => line.slot >= firstWaiting).length;
    if (unseen > capacity) {
      final j = _queue.indexWhere((line) => line.slot >= firstWaiting);
      if (j >= 0) {
        _queue.removeAt(j);
        for (var k = j; k < _queue.length; k++) {
          _queue[k] = _MarqueeLine(_queue[k].text, _queue[k].slot - 1);
        }
        _nextSlot--;
        dropped++;
      }
    }
  }

  /// Derived paint state (pure — the painter and the header read only
  /// this).
  ThinkingMarqueeView view() {
    final thinkOn = thinkStarted;
    final handed = handoverT >= 0;
    var regionAlpha = 0.0;
    if (thinkOn && !handed) {
      regionAlpha = 1;
    } else if (thinkOn && handed) {
      final u = ((simT - handoverT) / SrMotion.fade.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      regionAlpha = 1 - SrMotion.curveFade.transform(u);
    }
    final revealAlpha = revealed
        ? SrMotion.curveFade.transform(
            ((simT - revealT0) / SrMotion.emphasize.inMilliseconds).clamp(
              0.0,
              1.0,
            ),
          )
        : 0.0;
    final elapsedMs = thinkOn ? (handed ? handoverT : simT) - firstThinkT : 0;
    return ThinkingMarqueeView(
      regionAlpha: regionAlpha,
      revealAlpha: revealAlpha,
      elapsedMs: elapsedMs,
      tapeTop: windowTop(),
    );
  }
}

/// Everything the painter (and the header's elapsed) reads per frame.
class ThinkingMarqueeView {
  const ThinkingMarqueeView({
    required this.regionAlpha,
    required this.revealAlpha,
    required this.elapsedMs,
    required this.tapeTop,
  });
  final double regionAlpha;
  final double revealAlpha;
  final int elapsedMs;
  final double tapeTop;
}

/// The painted card's thinking overlay: shimmer band + sweep under a
/// masked, scrolling text band. Ignores the pointer entirely — the
/// chrome beneath keeps handling hits.
class ThinkingMarqueeOverlay extends StatefulWidget {
  const ThinkingMarqueeOverlay({super.key, required this.machine, this.onGone});

  final ThinkingMarquee machine;

  /// Fired once when the handover fade has run out (17 号票): the mount
  /// gate lives in the PANEL's build, and with the per-notify
  /// whole-tree rebuilds retired, no later notify is guaranteed to
  /// re-evaluate it — a last-delta-then-silence attempt would leave a
  /// fully faded overlay mounted. The overlay owns its own end-of-life
  /// signal; the panel's callback rebuilds and unmounts the slot.
  final VoidCallback? onGone;

  @override
  State<ThinkingMarqueeOverlay> createState() => _ThinkingMarqueeOverlayState();
}

class _ThinkingMarqueeOverlayState extends State<ThinkingMarqueeOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final TextPainterCache _cache = TextPainterCache();
  Duration _last = Duration.zero;
  int _frame = 0;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _cache.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _last;
    _last = elapsed;
    widget.machine.tick(dt.inMilliseconds);
    // The fade is monotone once handed over: its running out is a
    // one-way end state, fired exactly once.
    if (!_gone && widget.machine.handedOver && !widget.machine.hasVisual) {
      _gone = true;
      widget.onGone?.call();
      return;
    }
    setState(() => _frame++);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      key: const Key('thinking-marquee'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (size.isFinite) {
            widget.machine.setGeometry(size.width, size.height);
          }
          return RepaintBoundary(
            child: CustomPaint(
              size: size,
              painter: _MarqueePainter(
                machine: widget.machine,
                cache: _cache,
                frame: _frame,
                palette: srPalette(context),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Per-session TextPainter cache: folded lines are immutable, and the
/// painter re-runs every frame. Keyed with the color so a theme flip
/// mid-attempt lays out fresh painters instead of serving stale ones.
class TextPainterCache {
  final Map<(String, Color), TextPainter> _painters = {};

  TextPainter painterFor(String text, Color color) {
    return _painters.putIfAbsent((text, color), () {
      // 09 号票终值 (lineH=30, font 15) derived from the bodyLarge token
      // so the marquee band rides the type scale — and it carries the
      // family fallback explicitly: a TextPainter never sees the theme,
      // and a bare style's CJK falls to the engine default face (28 号
      // 票's 异体字 root cause).
      final base = SrType.bodyLarge;
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: base.copyWith(
            height: ThinkingMarquee.lineH / base.fontSize!,
            color: color,
            fontFamilyFallback: SrType.familyFallback,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: double.infinity);
      return painter;
    });
  }

  void dispose() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
    _painters.clear();
  }
}

/// The quintic ease-in-out the sweep rides (09 round 10: more
/// aggressive than smoothstep — clear dwell at both ends, quick
/// through the middle).
double _quinticEaseInOut(double u) {
  return u * u * u * (u * (u * 6 - 15) + 10);
}

/// The smoothstep ramp shared by every mask: alphas 0/.16/.5/.84/1 at
/// 0/25/50/75/100% of the ramp — zero slope at both ends, so the ramp
/// meets the plateau with continuous slope, no seam (09 trap ⑤).
const _rampStops = [0.0, 0.25, 0.5, 0.75, 1.0];
const _rampAlphas = [0.0, 0.16, 0.5, 0.84, 1.0];

/// The vertical mask's stops (09 终值: each edge ramp covers 20% of the
/// band) — the top ramp up, then its mirror into the bottom edge
/// (`1 − s·ramp`: 0.85/0.90/0.95/1.0 for the falling alphas, α0 exactly
/// at the edge like the top's). The list MUST stay strictly ascending:
/// an unsorted stop list is an invalid gradient and Skia shades it
/// undefined (22 号票: the mirrored positions were first written as the
/// complement `1 − (1−s)·ramp`, and the sweep's bottom edge cut hard
/// while the top — whose half of the list was sorted — faded normally).
@visibleForTesting
List<double> shimmerVerticalMaskStops({double rampFrac = 0.20}) => [
  for (final s in _rampStops) s * rampFrac,
  for (final s in _rampStops.reversed.skip(1)) 1.0 - s * rampFrac,
];

/// The sweep's ramp ladder (09 终值): each α rung's position across
/// the band, mirrored, plateau 45–55%.
const _sweepLadder = [
  0.0, 0.11, 0.22, 0.34, 0.45, //
  0.55, 0.66, 0.78, 0.89, 1.0,
];

/// The moving ramp window's stop positions along the tilted axis:
/// `bandCenter` is the window's center in px along the axis measured
/// from the gradient's midpoint, `span` the gradient's full length.
/// STRICTLY ASCENDING and within (0, 1] for every travel position —
/// the 22 号票 lesson (an unsorted stop list shades undefined)
/// generalized to a moving window.
@visibleForTesting
List<double> sweepWindowStops(double bandCenter, double bandW, double span) => [
  for (final f in _sweepLadder)
    (bandCenter - bandW / 2 + f * bandW + span / 2) / span,
];

class _MarqueePainter extends CustomPainter {
  _MarqueePainter({
    required this.machine,
    required this.cache,
    required this.frame,
    required this.palette,
  });

  final ThinkingMarquee machine;
  final TextPainterCache cache;
  final int frame;
  final SrPalette palette;

  /// The shimmer's edge-fade ramps: 44px horizontally (sub-stops at
  /// 11/22/33), 20% of the band vertically (09 终值).
  static const _shimHRamp = 44.0;
  static const _shimHSub = [
    _shimHRamp * 0.25,
    _shimHRamp * 0.5,
    _shimHRamp * 0.75,
  ];

  /// The sweep's α ramp in 255ths (09 终值, mirrored) — applied to the
  /// palette's sweep base (23 号票: white light on the dark card, the
  /// brand accent as a cool wash on the light card).
  static const _sweepAlphas = [
    0x00, 0x03, 0x06, 0x0B, 0x0D, //
    0x0D, 0x0B, 0x06, 0x03, 0x00,
  ];

  /// The sweep's tilt: iso-brightness edges lean "/" at 15° off
  /// vertical — the gradient axis rides 15° below horizontal
  /// (2026-09-21 device ruling: 30° tried first, settled at 15°; 09's
  /// original 100deg ≈10° read as straight, and the port had
  /// flattened it to 0°).
  static const _sweepTilt = math.pi / 12;

  /// The sweep's width as a fraction of the wrap (70%: the side fades
  /// ride 45% of the band each — widened from 60% on device ask,
  /// 2026-09-21).
  static const _sweepWidthFrac = 0.70;

  @override
  void paint(Canvas canvas, Size size) {
    final view = machine.view();
    if (view.regionAlpha <= 0.01 || size.isEmpty) return;
    _paintShimmer(canvas, size, view.regionAlpha);
    _paintTextBand(canvas, size, view);
  }

  // -- shimmer: fixed tall band, centered, sweep crossing it ----------
  void _paintShimmer(Canvas canvas, Size size, double alpha) {
    final shimH = size.height * ThinkingMarquee.shimmerFrac;
    final top = (size.height - shimH) / 2;
    // 横向贴卡缘 4px: the band reaches to 4 logical px from the card
    // edges (09), wider than the text band's corner inset.
    const edgeGap = 4.0;
    final wrap = Rect.fromLTWH(edgeGap, top, size.width - edgeGap * 2, shimH);
    canvas.saveLayer(
      wrap.inflate(2),
      Paint()..color = Colors.white.withValues(alpha: alpha),
    );

    // The sweep: a ramp window traveling along the tilted axis, parked
    // fully outside during the pause; both turnarounds happen outside
    // the band (faded tails), so no visible jump or cut (09 round 6).
    // The axis leans 30° below horizontal ("/" iso-brightness edges);
    // the travel is the wrap's projection onto it. Inking the WHOLE
    // wrap (not a moving rect) keeps every hard edge under the edge
    // masks below (09 trap ④).
    final bandW = wrap.width * _sweepWidthFrac;
    final cycleMs = ThinkingMarquee.sweepPassMs + ThinkingMarquee.sweepPauseMs;
    final thinkClock = machine.simT - machine.firstThinkT;
    final e = thinkClock % cycleMs;
    final p = _quinticEaseInOut(
      (e / ThinkingMarquee.sweepPassMs).clamp(0.0, 1.0),
    );
    final ax = math.cos(_sweepTilt), ay = math.sin(_sweepTilt);
    final travel = wrap.width * ax + wrap.height * ay;
    final span = travel + 2 * bandW;
    final bandCenter = -(travel + bandW) / 2 + p * (travel + bandW);
    // No base tint (09 round 8 终判: α0 — presence is all in the sweep).
    final sweep = Paint()
      ..shader = LinearGradient(
        // begin/end resolve as Alignment over `wrap` — convert the
        // tilted axis endpoints (± axis·span/2 from the center) into
        // Alignment units (÷ w/2, ÷ h/2) for an exact pixel angle.
        begin: Alignment(-ax * span / wrap.width, -ay * span / wrap.height),
        end: Alignment(ax * span / wrap.width, ay * span / wrap.height),
        colors: [
          for (final a in _sweepAlphas)
            palette.marqueeSweep.withValues(alpha: a / 255),
        ],
        stops: sweepWindowStops(bandCenter, bandW, span),
      ).createShader(wrap);
    canvas.drawRect(wrap, sweep);

    // Vertical falloff (20% multi-stop) then horizontal (44px
    // multi-stop) — two dstIn passes, the CSS nested-mask port (09
    // traps ③/④: both dimensions, and the falloff covers the sweep
    // rect's hard top/bottom edges).
    _applyMask(
      canvas,
      wrap,
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          for (final a in _rampAlphas) Colors.white.withValues(alpha: a),
          for (final a in _rampAlphas.reversed.skip(1))
            Colors.white.withValues(alpha: a),
        ],
        stops: shimmerVerticalMaskStops(),
      ).createShader(wrap),
    );
    _applyMask(
      canvas,
      wrap,
      LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          for (final a in _rampAlphas) Colors.white.withValues(alpha: a),
          for (final a in _rampAlphas.reversed.skip(1))
            Colors.white.withValues(alpha: a),
        ],
        // Ramp up over 44px (sub-stops 11/22/33), plateau, then the
        // mirror ramp down into the right edge. The trailing flat-zero
        // segment needs no stop — the gradient clamps to its last color.
        stops: [
          0.0,
          ..._shimHSub.map((px) => px / wrap.width),
          _shimHRamp / wrap.width,
          1.0 - _shimHRamp / wrap.width,
          ..._shimHSub.reversed.map((px) => 1 - px / wrap.width),
        ],
      ).createShader(wrap),
    );
    canvas.restore();
  }

  // -- text band: dynamic height, masked, translated by the tape ------
  void _paintTextBand(Canvas canvas, Size size, ThinkingMarqueeView view) {
    if (view.revealAlpha <= 0.01) return;
    final h = machine.hPx;
    final top = (size.height - h) / 2;
    final band = Rect.fromLTWH(
      SrSpace.cornerInset,
      top,
      size.width - SrSpace.cornerInset * 2,
      h,
    );
    final opacity = view.revealAlpha * view.regionAlpha;
    canvas.saveLayer(
      band.inflate(2),
      Paint()..color = Colors.white.withValues(alpha: opacity),
    );
    canvas.clipRect(band);
    final tapeTop = view.tapeTop;
    for (final line in machine._queue) {
      final y = line.slot * ThinkingMarquee.lineH - tapeTop;
      if (y + ThinkingMarquee.lineH <= 0 || y >= h) continue;
      cache
          .painterFor(line.text, palette.marqueeText)
          .paint(canvas, Offset(band.left, band.top + y));
    }
    // The band's own top/bottom fade (text-only — it never notches the
    // shimmer underneath): min(48, 带高×30%) smoothstep multi-stop.
    final maskPx = math.min(48.0, h * 0.3);
    final m1 = maskPx * 0.25, m2 = maskPx * 0.5, m3 = maskPx * 0.75;
    _applyMask(
      canvas,
      band,
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          for (final a in _rampAlphas) Colors.white.withValues(alpha: a),
          for (final a in _rampAlphas.reversed.skip(1))
            Colors.white.withValues(alpha: a),
        ],
        stops: [
          0.0,
          m1 / h,
          m2 / h,
          m3 / h,
          maskPx / h,
          1 - maskPx / h,
          1 - m3 / h,
          1 - m2 / h,
          1 - m1 / h,
        ],
      ).createShader(band),
    );
    canvas.restore();
  }

  /// Composite `shader` onto the current layer as an alpha mask (the
  /// dstIn port of a CSS mask-image).
  void _applyMask(Canvas canvas, Rect rect, Shader shader) {
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_MarqueePainter old) =>
      old.frame != frame || old.palette != palette;
}
