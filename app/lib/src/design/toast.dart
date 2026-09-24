/// The shared transient toast (ui-copy [toast 形态规格] answer, visual
/// verdict of [toast 视觉形态原型] — A 胶囊): one capsule per window
/// surface, fired via `SrToast.of(context).show(...)`.
///
/// - Form: opaque surfaceRaised capsule + hairline edge, a leading
///   state-colored icon (error live / success success), neutral
///   caption text, layered shadows lifted off the surface.
/// - Placement: [SrToastAnchor.top] on the settings window (below the
///   OS caption), bottom-center-in-card on the panel stages — fixed,
///   never flipped by GrowthDirection, clear of the chrome rows and
///   the anchor button. The orb window mounts no scope — a capsule
///   would not fit its footprint-circle region either; the badge
///   keeps the attention duty and the sentence rides the tray
///   tooltip (小修 24).
/// - Timing: success 2000ms / error 3000ms dwell, click-to-dismiss,
///   new replaces old (each restarts the clock).
/// - Tone contract (14 号票's audit rule): the leading icon wears the
///   tone, so the message must lean the same way — never an
///   affirmative-only text on the error tone, never a negative one on
///   success. A state that is both (saved-but-not-adopted) names both
///   in the text.
/// - Motion: fade + 8px slide on the shared enter/exit tokens — a
///   bottom-anchored toast rises in, a top-anchored one settles down.
///
/// The scope owns no business state: call sites decide what to show
/// (lastError wiring belongs to the panes, not this file).

library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Which window edge a toast hugs. The slide direction follows: bottom
/// toasts rise in, top toasts settle down.
enum SrToastAnchor { top, bottom }

/// The two tones a toast carries. The leading icon wears the state;
/// the text stays neutral textPrimary.
enum SrToastTone { error, success }

/// What a call site can do with the window's toast: fire one.
abstract interface class SrToast {
  /// Shows [message] as this window's toast. A live toast is replaced
  /// (no queue): the entrance restarts and the dwell clock resets.
  void show(String message, {SrToastTone tone});

  /// The window's toast entry point:
  ///
  /// ```dart
  /// SrToast.of(context).show('修正模型已保存', tone: SrToastTone.success);
  /// ```
  ///
  /// Throws if no [SrToastScope] wraps the caller — same posture as
  /// [Scaffold.of]: a missing scope is a wiring bug, not a runtime
  /// condition to swallow.
  static SrToast of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_SrToastScopeInherited>()!.scope;
}

/// One toast layer per window surface, above [child]'s content. Mount
/// it at the surface root (the settings window's home body, the panel
/// stage slot) so the capsule floats over every pane the window shows.
class SrToastScope extends StatefulWidget {
  const SrToastScope({
    super.key,
    required this.anchor,
    required this.clearance,
    required this.child,
  });

  final SrToastAnchor anchor;

  /// Distance from the anchored edge the capsule keeps: the settings
  /// window clears its caption strip, the panels clear the card margin
  /// plus the footer chrome band (spec: 让开 chrome 行与锚钮).
  final double clearance;

  final Widget child;

  @override
  State<SrToastScope> createState() => _SrToastScopeState();
}

class _SrToastScopeInherited extends InheritedWidget {
  const _SrToastScopeInherited({required this.scope, required super.child});

  final _SrToastScopeState scope;

  @override
  bool updateShouldNotify(_SrToastScopeInherited old) => false;
}

class _SrToastScopeState extends State<SrToastScope>
    with SingleTickerProviderStateMixin
    implements SrToast {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: SrMotion.enter,
    reverseDuration: SrMotion.exit,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _ctrl,
    curve: SrMotion.curveEnter,
    reverseCurve: SrMotion.curveExit,
  );

  _ToastEntry? _entry;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _curved.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void show(String message, {SrToastTone tone = SrToastTone.error}) {
    _timer?.cancel();
    setState(() => _entry = _ToastEntry(tone: tone, message: message));
    _ctrl.forward(from: 0); // replace: newest wins, entrance restarts
    _timer = Timer(
      tone == SrToastTone.error ? SrMotion.toastError : SrMotion.toastSuccess,
      _dismiss,
    );
  }

  void _dismiss() {
    _timer?.cancel();
    if (_entry == null) return;
    _ctrl.reverse();
    // Hold the entry through the exit fade, then clear it. (A status
    // listener would race forward(from: 0)'s momentary dismissed
    // notify and clear a freshly shown entry.)
    _timer = Timer(SrMotion.exit, () {
      if (mounted) setState(() => _entry = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final top = widget.anchor == SrToastAnchor.top;
    return _SrToastScopeInherited(
      scope: this,
      child: Stack(
        // Expand: the hosted surface (a pane, a Scaffold) is a
        // non-positioned child and must fill the window like it filled
        // the slot the scope replaces.
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned.fill(
            child: Padding(
              padding: top
                  ? EdgeInsets.only(top: widget.clearance)
                  : EdgeInsets.only(bottom: widget.clearance),
              child: Align(
                alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
                child: _buildToast(pal),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToast(SrPalette pal) {
    final entry = _entry;
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, _) {
        final t = _curved.value;
        return IgnorePointer(
          // Pass clicks through to the surface below while nothing is
          // shown; the fading capsule keeps its tap-to-dismiss.
          ignoring: entry == null,
          child: GestureDetector(
            onTap: _dismiss,
            child: Opacity(
              opacity: entry == null ? 0 : t,
              child: Transform.translate(
                // Bottom toasts rise in; top toasts settle down.
                offset: Offset(
                  0,
                  (1 - t) *
                      _rise *
                      (widget.anchor == SrToastAnchor.bottom ? 1 : -1),
                ),
                child: entry == null
                    ? const SizedBox.shrink()
                    : _capsule(pal, entry),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _capsule(SrPalette pal, _ToastEntry entry) {
    final error = entry.tone == SrToastTone.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: pal.surfaceRaised,
        borderRadius: BorderRadius.circular(SrRadius.capsule),
        border: Border.all(color: pal.hairline),
        // The 2026-09-17 verdict: the prototype's 0.30/0.16 read
        // slightly heavy on the real machine, so the layers lighten
        // to 0.20/0.10 (blur and offsets unchanged).
        boxShadow: [
          BoxShadow(
            color: pal.scrim.withValues(alpha: 0.20),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: pal.scrim.withValues(alpha: 0.10),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            error ? Icons.error_rounded : Icons.check_circle_rounded,
            size: 15,
            color: error ? pal.live : pal.success,
          ),
          const SizedBox(width: 6),
          Text(
            entry.message,
            key: const Key('sr-toast'),
            style: SrType.caption.copyWith(color: pal.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _ToastEntry {
  const _ToastEntry({required this.tone, required this.message});

  final SrToastTone tone;
  final String message;
}

// Component constants (window_stage's _entranceRise precedent): the
// entrance slide distance and the capsule's inner padding. Sizes of
// the toast's own body, not shared surface values — tokens stay the
// spec's extraction surface for everything cross-component.
const _rise = 8.0;
