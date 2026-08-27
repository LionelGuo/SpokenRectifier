/// Window-stage choreography: the expand/collapse of the OS window and
/// the lagging surface swap that hides the jump.
///
/// Main scheme (跳变藏动画主案):
/// - Expand: the window bounds jump to the panel footprint in ONE atomic
///   setBounds call (position + size together), pinning the bottom-right
///   corner. Everything painted is anchored bottom-right, so the orb is
///   pixel-stationary on screen while the window grows up-left; the panel
///   body then fades/rises in around the orb over ~240ms.
/// - Collapse: the panel body sinks/fades out (~150ms), THEN the window
///   shrinks back to the orb footprint — the jump lands on an empty
///   window and is invisible.
///
/// The orb button never leaves the widget tree while any stage is open:
/// it is the one continuous element (编舞铁律), morphing glyphs/roles in
/// place. Growth direction is parameterized for the future orb-drag /
/// expand-direction settings (ticket 20).
///
/// All window access sits behind [StageWindow] so widget tests drive the
/// choreography with a recording fake — no platform channels.

library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_state.dart';
import '../design/tokens.dart';
import '../rust/api.dart' show BridgeSessionState;
import 'orb_button.dart';
import 'quick_panel.dart';
import '../session/session_panel.dart';
import 'session_flow.dart' show StageKind;

/// Which corner the window keeps fixed when the footprint changes. v1
/// grows up-left from a bottom-right orb; other values exist for the
/// future expand-direction setting.
enum GrowthDirection { upLeft, upRight, downLeft, downRight }

extension GrowthDirectionX on GrowthDirection {
  bool get growLeft =>
      this == GrowthDirection.upLeft || this == GrowthDirection.downLeft;
  bool get growUp =>
      this == GrowthDirection.upLeft || this == GrowthDirection.upRight;
}

/// The window bounds a stage needs. One seam, two implementations: the
/// real window_manager-backed one in production, a recorder in tests.
abstract class StageWindow {
  Future<Offset> getPosition();
  Future<Size> getSize();
  Future<void> setBounds(Rect bounds);
}

/// The production [StageWindow] over window_manager.
class WindowManagerStageWindow implements StageWindow {
  const WindowManagerStageWindow();

  @override
  Future<Offset> getPosition() => windowManager.getPosition();

  @override
  Future<Size> getSize() => windowManager.getSize();

  @override
  Future<void> setBounds(Rect bounds) => windowManager.setBounds(bounds);
}

/// The footprint each stage owns. Session and quick share one shape, one
/// position, mutual exclusivity (同形同位互斥).
Size footprintFor(StageKind stage) => switch (stage) {
  StageKind.orb => SrGeometry.orbFootprint,
  StageKind.session || StageKind.quick => SrGeometry.panelSize,
};

/// Applies a footprint while pinning the anchor corner, in one atomic
/// setBounds (position + size land together, no intermediate state).
Future<void> stageBounds(
  StageWindow window,
  Size footprint, {
  GrowthDirection dir = GrowthDirection.upLeft,
}) async {
  final pos = await window.getPosition();
  final size = await window.getSize();
  final nx = dir.growLeft ? pos.dx + size.width - footprint.width : pos.dx;
  final ny = dir.growUp ? pos.dy + size.height - footprint.height : pos.dy;
  await window.setBounds(Rect.fromLTWH(nx, ny, footprint.width, footprint.height));
}

/// Hosts the surfaces and drives the window bounds with the choreography
/// above. `_displayed` lags `controller.stage` during collapse.
class StageHost extends StatefulWidget {
  const StageHost({super.key, required this.controller, this.stageWindow});

  final SpeechController controller;

  /// Null in pure-UI tests: the surfaces still swap, bounds calls are
  /// skipped (the fake choreography is asserted with a recording
  /// [StageWindow] instead).
  final StageWindow? stageWindow;

  @override
  State<StageHost> createState() => _StageHostState();
}

class _StageHostState extends State<StageHost> {
  StageKind _displayed = StageKind.orb;

  /// The stage a transition is already animating toward. Guards the
  /// double notify (command path + state-change event) from issuing the
  /// same bounds jump twice.
  StageKind _settling = StageKind.orb;
  bool _exiting = false;
  int _seq = 0; // guards stale async sequencing

  SpeechController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final target = c.stage;
    if (target == _settling) return; // already on it (or underway)

    if (target == StageKind.orb) {
      _collapse();
    } else {
      // Orb -> panel, or panel -> panel: the entrance animation covers
      // the bounds change.
      _expand(target);
    }
  }

  Future<void> _expand(StageKind target) async {
    final seq = ++_seq;
    _settling = target;
    // Jump the window first: everything visible is bottom-right pinned, so
    // this is invisible on screen; the body entrance starts right after.
    if (widget.stageWindow != null) {
      await stageBounds(widget.stageWindow!, footprintFor(target));
    }
    if (!mounted || seq != _seq) return;
    setState(() {
      _displayed = target;
      _exiting = false;
    });
  }

  Future<void> _collapse() async {
    final seq = ++_seq;
    _settling = StageKind.orb;
    // 1. Body exit animation on the still-open panel.
    setState(() => _exiting = true);
    await Future<void>.delayed(SrMotion.exit + const Duration(milliseconds: 30));
    if (!mounted || seq != _seq) return;
    // 2. Shrink the (now visually empty) window back to the orb footprint.
    if (widget.stageWindow != null) {
      await stageBounds(widget.stageWindow!, SrGeometry.orbFootprint);
    }
    if (!mounted || seq != _seq) return;
    // 3. Back to the standalone ball.
    setState(() {
      _displayed = StageKind.orb;
      _exiting = false;
    });
  }

  // ---- keyboard: the in-window twin of the hotkey surface ---------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      c.escapeAction();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (c.phase == BridgeSessionState.preview &&
          c.stage == StageKind.session) {
        c.enterAction();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // Hidden orb at rest: nothing at all (the tray checkbox owns this).
    if (_displayed == StageKind.orb && !c.orbVisible) {
      return const SizedBox.shrink();
    }
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          // Panel bodies. Only one is mounted at a time; each animates its
          // own entrance on mount and exit via [PanelBody.exiting].
          if (_displayed == StageKind.session)
            Positioned.fill(
              child: SessionPanel(controller: c, exiting: _exiting),
            )
          else if (_displayed == StageKind.quick)
            Positioned.fill(child: QuickPanel(controller: c, exiting: _exiting)),
          // The one continuous element: orb in orb stage, anchor button
          // in panel stages — same widget, same screen position, always
          // bottom-right pinned. Flush to the corner: OrbButton lays
          // itself out at the full orb footprint (96x96) with the ball
          // centered, so the ball center lands exactly anchorInset from
          // the window corner and stays concentric with the panel corner
          // arc. (An inset here would push the ball off the arc center
          // and off-center in the orb window — third preview round.)
          Positioned(right: 0, bottom: 0, child: OrbButton(controller: c)),
        ],
      ),
    );
  }
}

/// A panel body: the floating card that fades/rises in from the anchor on
/// entrance and sinks/fades on exit. The card reserves the anchor zone
/// (bottom-right) so the orb button overlaps it cleanly.
class PanelBody extends StatefulWidget {
  const PanelBody({
    super.key,
    required this.exiting,
    required this.child,
  });

  /// True while the stage host plays the exit animation before shrinking
  /// the window.
  final bool exiting;

  final Widget child;

  @override
  State<PanelBody> createState() => _PanelBodyState();
}

class _PanelBodyState extends State<PanelBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: SrMotion.enter,
      reverseDuration: SrMotion.exit,
    )..forward();
  }

  @override
  void didUpdateWidget(PanelBody old) {
    super.didUpdateWidget(old);
    if (widget.exiting && !old.exiting) {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final curved = CurvedAnimation(
      parent: _ctrl,
      curve: SrMotion.curveEnter,
      reverseCurve: SrMotion.curveExit,
    );
    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) => Opacity(
        opacity: curved.value,
        child: Transform.translate(
          // Rises out of the anchor corner; sinks back on exit.
          offset: Offset(0, (1 - curved.value) * 18),
          child: Transform.scale(
            // Grows from the anchor corner (where the orb sits).
            alignment: Alignment.bottomRight,
            scale: 0.94 + 0.06 * curved.value,
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                // Solid surfaces by design (materials spike: no acrylic
                // bet — spec §6).
                color: pal.surface,
                borderRadius: BorderRadius.circular(SrRadius.panel),
                border: Border.all(color: pal.hairline),
                // No drop shadow: the card sits 8px inside the window, so
                // any blur is sliced by the window rectangle and reads as
                // a dark box fringe. The window itself is the floating
                // surface; the hairline border carries the edge.
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
