/// Stage-level gesture affordances for ticket 20: the header-row move
/// grip (面板上沿拖动=整体移动) and the invisible resize handles on the
/// open panel's free edges and free corner. Handlers speak DELTAS, not
/// absolutes — the stage host owns the window geometry, the work-area
/// clamps and the persistence; these widgets only resolve the gesture.
///
/// All pointer tracking is raw-`Listener`, deliberately outside the
/// gesture arena: the arena's own slop (~18px) cannot express the
/// 8px click/drag threshold, and two tap deciders would double-fire in
/// the band between them.

library;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Header-grip callbacks: [start] fires once when the threshold is
/// crossed, [update] carries the pointer delta since the previous
/// event, [end] on release (only after a real drag).
typedef PanelGrip = ({
  void Function() start,
  void Function(Offset delta) update,
  void Function() end,
});

/// The header row as the panel's move grip: dragging anywhere on the
/// row moves the whole window — the orb rides along, its anchor role
/// intact. Thresholded like the orb drag so tiny jiggles move nothing;
/// the row hosts no clicks today (its chips and hints are
/// display-only).
class PanelGripBar extends StatefulWidget {
  const PanelGripBar({super.key, required this.grip, required this.child});

  final PanelGrip grip;
  final Widget child;

  @override
  State<PanelGripBar> createState() => _PanelGripBarState();
}

class _PanelGripBarState extends State<PanelGripBar> {
  Offset? _down;
  Offset _last = Offset.zero;
  bool _dragging = false;

  void _onDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    _down = e.position;
    _last = e.position;
    _dragging = false;
  }

  void _onMove(PointerMoveEvent e) {
    final down = _down;
    if (down == null) return;
    if (!_dragging) {
      if ((e.position - down).distance <= SrGeometry.dragThreshold) return;
      _dragging = true;
      widget.grip.start();
    }
    widget.grip.update(e.position - _last);
    _last = e.position;
  }

  void _onUp(PointerUpEvent e) => _finish();

  void _onCancel(PointerCancelEvent e) => _finish();

  void _finish() {
    if (_dragging) widget.grip.end();
    _down = null;
    _dragging = false;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: widget.child,
      ),
    );
  }
}

/// One invisible resize handle: a strip along a free edge or a square
/// at the free corner. Pointer deltas map to footprint growth through
/// [growSign] — dragging away from the orb grows the panel, toward it
/// shrinks — and the host clamps. Press-to-resize: no threshold and no
/// click semantics to protect.
class PanelResizeHandle extends StatefulWidget {
  const PanelResizeHandle({
    super.key,
    required this.cursor,
    required this.growSign,
    required this.onStart,
    required this.onGrow,
    required this.onEnd,
  });

  /// The hover hint (edge: one axis; corner: the matching diagonal).
  final MouseCursor cursor;

  /// Per-axis sign: footprint growth = pointer delta * growSign.
  final Offset growSign;

  final VoidCallback onStart;
  final ValueChanged<Offset> onGrow;
  final VoidCallback onEnd;

  @override
  State<PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<PanelResizeHandle> {
  Offset? _last;

  void _onDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    _last = e.position;
    widget.onStart();
  }

  void _onMove(PointerMoveEvent e) {
    final last = _last;
    if (last == null) return;
    final delta = e.position - last;
    _last = e.position;
    widget.onGrow(
      Offset(delta.dx * widget.growSign.dx, delta.dy * widget.growSign.dy),
    );
  }

  void _onUp(PointerUpEvent e) => _finish();

  void _onCancel(PointerCancelEvent e) => _finish();

  void _finish() {
    if (_last == null) return;
    _last = null;
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
