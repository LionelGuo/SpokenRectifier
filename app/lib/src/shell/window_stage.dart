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

// GrowthDirection hidden here: the framework exports its own (an
// obscure sliver-layout token) and this library's is the orb-geometry
// one from window_geometry.dart below.
import 'package:flutter/material.dart' hide GrowthDirection;
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart' as sr;
import 'package:window_manager/window_manager.dart';

import '../../app_state.dart';
import '../design/tokens.dart';
import '../rust/api.dart' show BridgeSessionState;
import '../settings/settings_domain.dart';
import 'orb_button.dart';
import 'panel_gestures.dart';
import 'quick_panel.dart';
import '../session/session_panel.dart';
import 'session_flow.dart' show StageKind;
import 'window_geometry.dart';

// The direction enum lives with the rest of the orb-anchored geometry
// (ticket 20); re-exported here so existing imports keep resolving.
export 'window_geometry.dart' show GrowthDirection, GrowthDirectionX;

/// The window bounds a stage needs. One seam, two implementations: the
/// real window_manager-backed one in production, a recorder in tests.
abstract class StageWindow {
  Future<Offset> getPosition();
  Future<Size> getSize();
  Future<void> setBounds(Rect bounds);

  /// Every display's work area, logical coordinates — the drag/resize
  /// clamps and the expand-direction chooser consume these (ticket 20).
  Future<List<Rect>> workAreas();

  /// Bring the window to the foreground so its keyboard affordances
  /// (Esc, Enter) are live.
  Future<void> focus();
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

  @override
  Future<List<Rect>> workAreas() async {
    final displays = await sr.screenRetriever.getAllDisplays();
    return [
      // visible* is the monitor's work area (rcWork) in the monitor's
      // own logical units — the coordinate system window_manager reports
      // positions in. A display without them is unusable for clamping;
      // skip it rather than guess.
      for (final d in displays)
        if (d.visiblePosition != null && d.visibleSize != null)
          Rect.fromLTWH(
            d.visiblePosition!.dx,
            d.visiblePosition!.dy,
            d.visibleSize!.width,
            d.visibleSize!.height,
          ),
    ];
  }

  @override
  Future<void> focus() => windowManager.focus();
}

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
  await window.setBounds(
    Rect.fromLTWH(nx, ny, footprint.width, footprint.height),
  );
}

/// Hosts the surfaces and drives the window bounds with the choreography
/// above. `_displayed` lags `controller.stage` during collapse.
class StageHost extends StatefulWidget {
  const StageHost({
    super.key,
    required this.controller,
    this.stageWindow,
    this.onOpenSettings,
  });

  final SpeechController controller;

  /// Null in pure-UI tests: the surfaces still swap, bounds calls are
  /// skipped (the fake choreography is asserted with a recording
  /// [StageWindow] instead).
  final StageWindow? stageWindow;

  /// The settings window's doorway, handed down to the quick panel's
  /// management entries. Null in tests.
  final void Function(SettingsDomain domain)? onOpenSettings;

  @override
  State<StageHost> createState() => _StageHostState();
}

class _StageHostState extends State<StageHost> {
  StageKind _displayed = StageKind.orb;

  /// The direction the open panel (or the next one) grows in. Chosen at
  /// every expand from the anchor's quadrant, frozen while any panel is
  /// open (never flips mid-panel — the window would jump sides of the
  /// ball). The orb stage's layout mirrors it too, so the ball sits in
  /// the corner the next panel will grow from.
  GrowthDirection _dir = GrowthDirection.upLeft;

  /// The stage a transition is already animating toward. Guards the
  /// double notify (command path + state-change event) from issuing the
  /// same bounds jump twice.
  StageKind _settling = StageKind.orb;
  bool _exiting = false;
  int _seq = 0; // guards stale async sequencing

  /// The phase the stage window last took the keyboard for.
  BridgeSessionState? _focusedPhase;

  /// Owns the Flutter keyboard while a panel is open: key events
  /// dispatch from the primary focus node UP its ancestors, so the
  /// stage must hold (or re-claim) primary focus for [_onKey] to fire.
  /// Panels hand the keyboard down to their own fields when they need
  /// it (the session field at preview, for edits and IME).
  final FocusNode _keyboardNode = FocusNode(debugLabel: 'stage-keyboard');

  /// The phase the stage node last claimed the keyboard for (guards the
  /// mic-tick notifies, which fire ~20x/s during recording).
  BridgeSessionState? _keyboardPhase;

  SpeechController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    // Prime the geometry cache for the gestures (work areas + current
    // window rect); they run synchronously against it from here on.
    unawaited(_primeGeometry());
  }

  @override
  void didUpdateWidget(StageHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    // A controller swap re-homes the listener (tests iterate shells);
    // stage bookkeeping and the geometry cache restart from the
    // newcomer's own world.
    oldWidget.controller.removeListener(_onChanged);
    c.addListener(_onChanged);
    _settling = StageKind.orb;
    _displayed = StageKind.orb;
    _exiting = false;
    _dir = GrowthDirection.upLeft;
    _seq++;
    _rectKnown = false;
    unawaited(_primeGeometry());
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    _keyboardNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Preview entry guarantees the keyboard: the field becomes editable
    // this instant, wherever the user's focus wandered during recording.
    if (c.phase == BridgeSessionState.preview &&
        _focusedPhase != BridgeSessionState.preview &&
        widget.stageWindow != null) {
      widget.stageWindow!.focus();
    }
    _focusedPhase = c.phase;

    // Entering recording/rectifying (re-)claims the Flutter keyboard for
    // the stage node: a previous session's exit parks primary focus on
    // the enclosing scope, and events dispatched from there never walk
    // down into this subtree. Preview is exempt — the editable field
    // takes the keyboard on entry and needs it for edits, IME, Enter.
    if ((c.phase == BridgeSessionState.recording ||
            c.phase == BridgeSessionState.rectifying) &&
        _keyboardPhase != c.phase) {
      _keyboardNode.requestFocus();
    }
    _keyboardPhase = c.phase;

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
    // Jump the window first: everything visible is pinned to the anchor
    // corner, so this is invisible on screen; the body entrance starts
    // right after.
    if (widget.stageWindow != null) {
      await _expandBounds(widget.stageWindow!);
      // Panels carry the keyboard affordances (Esc, Enter): take the
      // foreground when the stage opens. The orb-click entry already
      // holds it; the hotkey entry does not, and Esc during recording
      // is dead without it. The insertion target is safe — the engine
      // noted it while handling StartSession, before this notify.
      await widget.stageWindow!.focus();
    }
    if (!mounted || seq != _seq) return;
    // Panels carry the keyboard affordances: with the window foreground
    // and the panel mounting fresh, the stage node takes the Flutter
    // keyboard (the quick panel has no field of its own to hand it to).
    _keyboardNode.requestFocus();
    setState(() {
      _displayed = target;
      _exiting = false;
    });
  }

  /// The ticket-20 expand: jump to the shared footprint at the CURRENT
  /// anchor — direction derived from the anchor's quadrant in the work
  /// area holding it, size clamped to what that anchor can host — in one
  /// atomic setBounds that keeps the ball pixel-stationary. The anchor
  /// survives every form, so a panel-size window mid-transition yields
  /// the same anchor as the orb window would.
  Future<void> _expandBounds(StageWindow window) async {
    _areas = await window.workAreas(); // refresh for the gestures to come
    final anchor = anchorOf(_rect, _dir);
    final plan = expandPlan(
      anchor,
      c.panelFootprint,
      _areaHolding(anchor, _areas ?? const []),
    );
    _dir = plan.dir;
    await _applyBounds(plan.window);
  }

  /// The work area holding [point]; the first (primary) when none does —
  /// an anchor caught between display-topology changes still has to
  /// expand somewhere. A silent query (no areas at all) falls back to a
  /// rect so wide the clamps never bind.
  static Rect _areaHolding(Offset point, List<Rect> areas) {
    for (final area in areas) {
      if (point.dx >= area.left &&
          point.dx <= area.right &&
          point.dy >= area.top &&
          point.dy <= area.bottom) {
        return area;
      }
    }
    if (areas.isEmpty) return Rect.fromLTWH(-16000, -16000, 32000, 32000);
    return areas.first;
  }

  Future<void> _collapse() async {
    final seq = ++_seq;
    _settling = StageKind.orb;
    // 1. Body exit animation on the still-open panel.
    setState(() => _exiting = true);
    await Future<void>.delayed(SrMotion.exit + _collapseSlack);
    if (!mounted || seq != _seq) return;
    // 2. Shrink the (now visually empty) window back to the orb
    // footprint, pinning the SAME corner the panel grew from (the ball
    // stays put in every direction).
    if (widget.stageWindow != null) {
      await _applyBounds(
        panelRectFor(anchorOf(_rect, _dir), SrGeometry.orbFootprint, _dir),
      );
    }
    if (!mounted || seq != _seq) return;
    // 3. Back to the standalone ball.
    setState(() {
      _displayed = StageKind.orb;
      _exiting = false;
    });
  }

  // ---- ticket-20 geometry gestures: drag / move / resize -----------------

  /// Cached work areas and the window rect this host last commanded.
  /// Raw pointer events have no await budget — a drag's first update
  /// can land before an async capture from its start would — so the
  /// cache is primed at mount and every gesture step runs synchronously
  /// against it. Areas refresh at every expand and gesture end (topology
  /// changes between gestures, never under a held pointer).
  List<Rect>? _areas;
  Rect _rect = Rect.zero;
  bool _rectKnown = false;

  /// Live geometry per gesture kind (only one kind runs at a time).
  Offset _dragAnchor = Offset.zero; // orb drag: the moving anchor
  Rect _moveRect = Rect.zero; // header drag: the moving window rect
  Offset _resizeAnchor = Offset.zero; // resize: the anchor stays put…
  Size _resizeSize = Size.zero; // …the footprint does the moving

  /// Gestures need the real window; pure-UI tests run without one.
  bool get _gesturesLive => widget.stageWindow != null;

  /// The header grip both panels share (null in tests): dragging the
  /// corner-band header row moves the whole window, orb riding along.
  PanelGrip? get _grip => _gesturesLive
      ? (start: _panelMoveStart, update: _panelMoveUpdate, end: _panelMoveEnd)
      : null;

  Future<void> _primeGeometry() async {
    final window = widget.stageWindow;
    if (window == null) return;
    _areas = await window.workAreas();
    if (!_rectKnown) {
      final pos = await window.getPosition();
      final size = await window.getSize();
      _rect = Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
      _rectKnown = true;
    }
  }

  /// Every bounds this host commands goes through here: the cache and
  /// the OS window never disagree about where the window is.
  Future<void> _applyBounds(Rect bounds) async {
    _rect = bounds;
    _rectKnown = true;
    await widget.stageWindow?.setBounds(bounds);
  }

  Rect _gestureArea(Offset point) => _areaHolding(point, _areas ?? const []);

  // -- orb drag (idle only; the orb button gates arming) -------------------

  void _orbDragStart() {
    if (!_rectKnown || c.stage != StageKind.orb) return;
    _dragAnchor = anchorOf(_rect, _dir);
  }

  void _orbDragUpdate(Offset delta) {
    if (c.stage != StageKind.orb) return;
    // The clamp's landing feeds back: a blocked edge stops the anchor,
    // it never accumulates debt for the return trip.
    _dragAnchor = clampAnchor(_dragAnchor + delta, _gestureArea(_dragAnchor));
    unawaited(_applyBounds(orbFootprintAt(_dragAnchor)));
    c.noteGeometryLive(anchor: _dragAnchor);
  }

  void _orbDragEnd() {
    if (c.stage != StageKind.orb) return;
    c.noteGeometryDone(anchor: _dragAnchor);
    unawaited(_primeGeometry()); // fresh areas for the next gesture
  }

  // -- header drag: the whole unit (panel + orb) moves ---------------------

  void _panelMoveStart() {
    if (!_rectKnown) return;
    _moveRect = _rect;
  }

  void _panelMoveUpdate(Offset delta) {
    if (!_rectKnown) return;
    final area = _gestureArea(anchorOf(_moveRect, _dir));
    _moveRect = clampRectIntoWorkArea(_moveRect.shift(delta), area);
    unawaited(_applyBounds(_moveRect));
    c.noteGeometryLive(anchor: anchorOf(_moveRect, _dir));
  }

  void _panelMoveEnd() {
    c.noteGeometryDone(anchor: anchorOf(_moveRect, _dir));
    unawaited(_primeGeometry());
  }

  // -- resize: the anchor corner never moves, the panel grows away ---------

  void _resizeStart() {
    if (!_rectKnown) return;
    _resizeAnchor = anchorOf(_rect, _dir);
    _resizeSize = _rect.size;
  }

  void _resizeGrow(Offset growth) {
    if (!_rectKnown) return;
    final size = clampPanelSize(
      _resizeSize + growth,
      _resizeAnchor,
      _dir,
      _gestureArea(_resizeAnchor),
    );
    if (size == _resizeSize) return; // a bound edge eats the delta
    _resizeSize = size;
    unawaited(_applyBounds(panelRectFor(_resizeAnchor, size, _dir)));
    c.noteGeometryLive(panel: size);
  }

  void _resizeEnd() {
    c.noteGeometryDone(panel: _resizeSize);
    unawaited(_primeGeometry());
  }

  /// The free-edge strips and the free-corner square, mirrored to the
  /// growth direction (handles sit on the edges AWAY from the anchor
  /// corner, so resizing never moves the ball). The corner paints last:
  /// where it overlaps the strips, it wins the hit.
  List<Widget> _resizeHandles() {
    final left = _dir.growLeft;
    final up = _dir.growUp;
    return [
      Positioned(
        key: const Key('panel-resize-v'),
        left: left ? 0 : null,
        right: left ? null : 0,
        top: 0,
        bottom: 0,
        width: SrGeometry.resizeEdgeHit,
        child: PanelResizeHandle(
          cursor: SystemMouseCursors.resizeLeftRight,
          growSign: Offset(left ? -1 : 1, 0),
          onStart: _resizeStart,
          onGrow: _resizeGrow,
          onEnd: _resizeEnd,
        ),
      ),
      Positioned(
        key: const Key('panel-resize-h'),
        left: 0,
        right: 0,
        top: up ? 0 : null,
        bottom: up ? null : 0,
        height: SrGeometry.resizeEdgeHit,
        child: PanelResizeHandle(
          cursor: SystemMouseCursors.resizeUpDown,
          growSign: Offset(0, up ? -1 : 1),
          onStart: _resizeStart,
          onGrow: _resizeGrow,
          onEnd: _resizeEnd,
        ),
      ),
      Positioned(
        key: const Key('panel-resize-corner'),
        left: left ? 0 : null,
        right: left ? null : 0,
        top: up ? 0 : null,
        bottom: up ? null : 0,
        width: SrGeometry.resizeCornerHit,
        height: SrGeometry.resizeCornerHit,
        child: PanelResizeHandle(
          cursor: left == up
              ? SystemMouseCursors.resizeUpLeftDownRight
              : SystemMouseCursors.resizeUpRightDownLeft,
          growSign: Offset(left ? -1 : 1, up ? -1 : 1),
          onStart: _resizeStart,
          onGrow: _resizeGrow,
          onEnd: _resizeEnd,
        ),
      ),
    ];
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
      focusNode: _keyboardNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          // Panel bodies. Only one is mounted at a time; each animates its
          // own entrance on mount and exit via [PanelBody.exiting].
          if (_displayed == StageKind.session)
            Positioned.fill(
              child: SessionPanel(
                controller: c,
                exiting: _exiting,
                dir: _dir,
                grip: _grip,
              ),
            )
          else if (_displayed == StageKind.quick)
            Positioned.fill(
              child: QuickPanel(
                controller: c,
                exiting: _exiting,
                onOpenSettings: widget.onOpenSettings,
                dir: _dir,
                grip: _grip,
              ),
            ),
          // The resize affordances ride above whichever panel is open
          // (the shared footprint resizes as one — 一调俱调).
          if (_displayed != StageKind.orb && _gesturesLive) ..._resizeHandles(),
          // The one continuous element: orb in orb stage, anchor button
          // in panel stages — same widget, same screen position, pinned
          // to the corner the panel grows from. Flush to the corner:
          // OrbButton lays itself out at the full orb footprint (96x96)
          // with the ball centered, so the ball center lands exactly
          // anchorInset from the window corner and stays concentric with
          // the panel corner arc. (An inset here would push the ball off
          // the arc center and off-center in the orb window — third
          // preview round.)
          Positioned(
            left: _dir.growLeft ? null : 0,
            right: _dir.growLeft ? 0 : null,
            top: _dir.growUp ? null : 0,
            bottom: _dir.growUp ? 0 : null,
            child: OrbButton(
              controller: c,
              onDragStart: _gesturesLive ? _orbDragStart : null,
              onDragUpdate: _gesturesLive ? _orbDragUpdate : null,
              onDragEnd: _gesturesLive ? _orbDragEnd : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Panel-body entrance numbers (component constants, not tokens): the
/// rise distance and starting scale of the entrance transform, plus the
/// scheduling slack that lets the exit animation finish landing before
/// the window shrinks under it.
const _entranceRise = 18.0;
const _entranceScaleFrom = 0.94;
const _collapseSlack = Duration(milliseconds: 30);

/// A panel body: the floating card that fades/rises in from the anchor on
/// entrance and sinks/fades on exit. The card reserves the anchor corner
/// (per [dir]) so the orb button overlaps it cleanly.
class PanelBody extends StatefulWidget {
  const PanelBody({
    super.key,
    required this.exiting,
    required this.dir,
    required this.child,
  });

  /// True while the stage host plays the exit animation before shrinking
  /// the window.
  final bool exiting;

  /// Which corner the orb anchors: the entrance rises out of it and the
  /// starting scale is centered on it, whatever direction the panel
  /// grew in.
  final GrowthDirection dir;

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
          // Rises out of the anchor corner; sinks back on exit. The rise
          // points at the anchor: up-growth rises from below it, down-
          // growth drops in from above it.
          offset: Offset(
            0,
            (1 - curved.value) * _entranceRise * (widget.dir.growUp ? 1 : -1),
          ),
          child: Transform.scale(
            // Grows from the anchor corner (where the orb sits).
            alignment: switch (widget.dir) {
              GrowthDirection.upLeft => Alignment.bottomRight,
              GrowthDirection.upRight => Alignment.bottomLeft,
              GrowthDirection.downLeft => Alignment.topRight,
              GrowthDirection.downRight => Alignment.topLeft,
            },
            scale: _entranceScaleFrom + (1 - _entranceScaleFrom) * curved.value,
            child: Container(
              margin: const EdgeInsets.all(SrGeometry.cardMargin),
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
