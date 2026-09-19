/// Stage-level gesture affordances: the invisible resize handles on the
/// open panel's free edges and free corner (ticket 20). The panel move
/// affordance is the anchor button itself (02 号票 abolished the header
/// grip — its widget died with it); handlers live in window_stage.
///
/// All pointer tracking is raw-`Listener`, deliberately outside the
/// gesture arena: the arena's own slop (~18px) cannot express the
/// 8px click/drag threshold, and two tap deciders would double-fire in
/// the band between them.

library;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';

/// One invisible resize handle: a strip along a free edge or a square
/// at the free corner. The handle reports the pointer's current
/// position; the host maps it against a screen-stable cursor (growing
/// left/up moves the window origin, which would eat view-relative
/// deltas). Press-to-resize: no threshold and no click semantics to
/// protect.
class PanelResizeHandle extends StatefulWidget {
  const PanelResizeHandle({
    super.key,
    required this.cursor,
    required this.onStart,
    required this.onGrow,
    required this.onEnd,
  });

  /// The hover hint (edge: one axis; corner: the matching diagonal).
  final MouseCursor cursor;

  final ValueChanged<Offset> onStart;
  final ValueChanged<Offset> onGrow;
  final VoidCallback onEnd;

  @override
  State<PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<PanelResizeHandle> {
  bool _held = false;

  void _onDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    _held = true;
    widget.onStart(e.position);
  }

  void _onMove(PointerMoveEvent e) {
    if (!_held) return;
    widget.onGrow(e.position);
  }

  void _onUp(PointerUpEvent e) => _finish();

  void _onCancel(PointerCancelEvent e) => _finish();

  void _finish() {
    if (!_held) return;
    _held = false;
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: const SizedBox.expand(),
      ),
    );
  }
}
