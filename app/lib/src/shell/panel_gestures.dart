/// Stage-level gesture affordances for ticket 20: the header-row move
/// grip (面板上沿拖动=整体移动) and the invisible resize handles on the
/// open panel's free edges and free corner. Handlers speak POSITIONS,
/// not deltas — the stage host maps them against a screen-stable cursor
/// so the window can move under the pointer without eating the next
/// event. These widgets only resolve the gesture.
///
/// All pointer tracking is raw-`Listener`, deliberately outside the
/// gesture arena: the arena's own slop (~18px) cannot express the
/// 8px click/drag threshold, and two tap deciders would double-fire in
/// the band between them.

library;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Header-grip callbacks: [start] fires on press (the host samples the
/// grab), [update] carries the pointer's current position, [end] on
/// release (only after a real drag). Positions, not deltas — the host
/// maps them against a screen-stable cursor so the window can move
/// under the pointer without eating the next event.
typedef PanelGrip = ({
  void Function(Offset pointer) start,
  void Function(Offset pointer) update,
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
  bool _dragging = false;

  void _onDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    _down = e.position;
    _dragging = false;
    widget.grip.start(e.position);
  }

  void _onMove(PointerMoveEvent e) {
    final down = _down;
    if (down == null) return;
    if (!_dragging) {
      if ((e.position - down).distance <= SrGeometry.dragThreshold) return;
      _dragging = true;
    }
    widget.grip.update(e.position);
  }

  void _onUp(PointerUpEvent e) => _finish();

  void _onCancel(PointerCancelEvent e) => _finish();

  void _finish() {
    // End any grab sampled on down, even a sub-threshold press that
    // never armed — otherwise the host keeps a live grab.
    if (_down != null) widget.grip.end();
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
