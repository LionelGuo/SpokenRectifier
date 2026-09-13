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
import 'screen_cursor.dart';
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

  /// While a panel stage holds the window at the panel growth ceiling
  /// (ADR 0017), the card slot's rect in WINDOW coordinates — the OS
  /// window region narrows to it, so the transparent margin neither
  /// paints nor hit-tests (clicks fall through to the desktop). Null
  /// restores the whole window (the orb stage, and a resize gesture
  /// whose growing card must paint beyond the stale slot).
  Future<void> setCardRegion(Rect? windowRect);

  /// Every display's work area, logical coordinates — the drag/resize
  /// clamps and the expand-direction chooser consume these (ticket 20).
  Future<List<Rect>> workAreas();

  /// Live pointer in logical screen coordinates. Synchronous: a drag
  /// update has no await budget, and a method-channel read would race
  /// the window the same way view-relative deltas do.
  ///
  /// Null when the platform cannot report one (widget tests): the host
  /// then treats `PointerEvent.position` as screen-stable, which is
  /// what the test view actually is — `setBounds` never moves it.
  Offset? pointerOnScreen();

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
  Future<void> setCardRegion(Rect? windowRect) {
    // The native side works in physical pixels; this seam speaks
    // logical, like every other method here.
    const channel = MethodChannel('spokenrectifier/window');
    if (windowRect == null) {
      return channel.invokeMethod('setRegion');
    }
    final dpr = windowManager.getDevicePixelRatio();
    return channel.invokeMethod('setRegion', {
      'left': (windowRect.left * dpr).round(),
      'top': (windowRect.top * dpr).round(),
      'right': (windowRect.right * dpr).round(),
      'bottom': (windowRect.bottom * dpr).round(),
    });
  }

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
  Offset? pointerOnScreen() =>
      logicalCursorScreen(windowManager.getDevicePixelRatio());

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
    _panelSize.value = null;
    _rectKnown = false;
    _grabArmed = false;
    _grabLive = false;
    _pendingBounds = null;
    _boundsIdle = null;
    _pumping = false;
    unawaited(_primeGeometry());
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    _keyboardNode.dispose();
    _panelSize.dispose();
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
    _grabArmed = false;
    _grabLive = false;
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

  /// The ticket-20 expand: direction derived from the anchor's quadrant
  /// in the work area holding it, panel size clamped to what that anchor
  /// can host — in one atomic setBounds that keeps the ball
  /// pixel-stationary. ADR 0017: the window jumps to the panel growth
  /// CEILING, not the footprint — resize gestures then never touch the
  /// HWND (the reshape ghosting lived in per-frame WM_SIZE storms, and
  /// the residual one-frame flash in a mid-gesture size jump: the stale
  /// child surface composites top-left-aligned for a frame when the
  /// engine loses the present race). The card renders in the slot; the
  /// transparent margin neither paints nor hit-tests ([setCardRegion]).
  Future<void> _expandBounds(StageWindow window) async {
    _areas = await window.workAreas(); // refresh for the gestures to come
    final anchor = anchorOf(_rect, _dir);
    final area = _areaHolding(anchor, _areas ?? const []);
    final plan = expandPlan(anchor, c.panelFootprint, area);
    _dir = plan.dir;
    _panelSize.value = plan.size;
    await _applyBounds(
      panelRectFor(anchor, maxPanelSize(anchor, plan.dir, area), plan.dir),
    );
    unawaited(_pushPanelRegion());
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
    _grabArmed = false;
    _grabLive = false;
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
      // The orb window is whole again (ADR 0017). Region first; the
      // slot notifier stays until the panel unmounts below — notifying
      // null while the card is still in the tree would flash it
      // full-bleed for a frame.
      unawaited(_pushCardRegion(null));
    }
    if (!mounted || seq != _seq) return;
    // 3. Back to the standalone ball.
    setState(() {
      _displayed = StageKind.orb;
      _exiting = false;
    });
    _panelSize.value = null;
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
  Size _resizeSize0 = Size.zero; // resize: size at grab, growth is absolute
  Offset _resizeSign = Offset.zero;

  /// The panel footprint the slot renders the card at. Null while the
  /// window has only ever been the footprint itself (the slot is
  /// full-bleed); set at every expand and held through the resize
  /// gestures — the freeze keeps it while the HWND sits at the growth
  /// ceiling, and the release keeps it until the shrunk view lands
  /// (identical to full-bleed by then).
  ///
  /// A [ValueNotifier] so a resize can grow the slot without
  /// [setState] on this host: StageHost.setState rebuilt SessionPanel /
  /// QuickPanel (and SlotSurface re-measured) on every pointer move,
  /// which is the remaining frame-rate tax once the HWND is frozen
  /// (window-gesture-perf H3).
  final ValueNotifier<Size?> _panelSize = ValueNotifier(null);

  /// Pointer minus the moving target at grab. Screen-stable when the
  /// platform can report one; otherwise the view-relative event position
  /// (widget tests — `setBounds` never moves that view).
  Offset _grabOffset = Offset.zero;
  Offset _grabPointer = Offset.zero;
  bool _useScreenPointer = false;

  /// In-flight setBounds coalescing: pointer events outrun the platform
  /// channel, and a queue of stale rects flickers the window backwards.
  /// One pump sends the latest pending rect each lap; expand/collapse
  /// await until the pump is idle so their jump lands before the swap.
  Rect? _pendingBounds;
  Future<void>? _boundsIdle;
  bool _pumping = false;

  /// Press sampled a grab; updates no-op until then. Cleared on expand
  /// so a click-that-opens cannot keep moving the window.
  bool _grabArmed = false;

  /// A real drag update ran (past the 8px slop); end persists only then.
  bool _grabLive = false;

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
  /// the OS window never disagree about where the window is. In-flight
  /// calls coalesce to the latest rect — a queue of stale SetWindowPos
  /// is what flickered the orb backwards mid-drag. Expand/collapse await
  /// until this rect (or a later one) has been sent, including a leftover
  /// pump spawned after the previous future already completed.
  Future<void> _applyBounds(Rect bounds) async {
    _rect = bounds;
    _rectKnown = true;
    _pendingBounds = bounds;
    if (!_pumping) {
      _boundsIdle = _pumpBounds();
    }
    while (_pumping) {
      final wait = _boundsIdle;
      if (wait == null) break;
      await wait;
    }
  }

  Future<void> _pumpBounds() async {
    _pumping = true;
    try {
      while (_pendingBounds != null) {
        final next = _pendingBounds!;
        _pendingBounds = null;
        await widget.stageWindow?.setBounds(next);
      }
    } finally {
      if (_pendingBounds != null) {
        // A nudge arrived after the loop's last null-check: keep
        // pumping so `_applyBounds` waiters (expand) still land.
        // Stay `_pumping` so those waiters don't exit between laps.
        _boundsIdle = _pumpBounds();
      } else {
        _pumping = false;
        _boundsIdle = null;
      }
    }
  }

  Rect _gestureArea(Offset point) => _areaHolding(point, _areas ?? const []);

  /// Screen-stable cursor when the platform has one; otherwise the
  /// view-relative event position (the test view does not move).
  Offset? _livePointer(Offset fallback) {
    if (!_useScreenPointer) return fallback;
    return widget.stageWindow?.pointerOnScreen();
  }

  void _latchPointerSource(Offset fallback) {
    final screen = widget.stageWindow?.pointerOnScreen();
    _useScreenPointer = screen != null;
    _grabPointer = screen ?? fallback;
  }

  // -- orb drag (idle only; the orb button gates arming) -------------------

  void _orbDragStart(Offset pointer) {
    if (!_rectKnown || c.stage != StageKind.orb) return;
    _dragAnchor = anchorOf(_rect, _dir);
    _latchPointerSource(pointer);
    _grabOffset = _grabPointer - _dragAnchor;
    _grabArmed = true;
    // Live only once the 8px slop arms — a click must not persist.
  }

  void _orbDragUpdate(Offset pointer) {
    if (!_grabArmed || c.stage != StageKind.orb) return;
    final p = _livePointer(pointer);
    if (p == null) return;
    _grabLive = true;
    // Absolute (pointer − grab), not accumulated deltas: a clamped
    // edge does not build debt for the return trip, and a window
    // moving under the cursor does not shrink the next event.
    _dragAnchor = clampAnchor(p - _grabOffset, _gestureArea(_dragAnchor));
    unawaited(_applyBounds(orbFootprintAt(_dragAnchor)));
    c.noteGeometryLive(anchor: _dragAnchor);
  }

  void _orbDragEnd() {
    if (!_grabArmed || c.stage != StageKind.orb) return;
    _grabArmed = false;
    if (!_grabLive) return;
    _grabLive = false;
    c.noteGeometryDone(anchor: _dragAnchor);
    unawaited(_primeGeometry()); // fresh areas for the next gesture
  }

  // -- header drag: the whole unit (panel + orb) moves ---------------------

  void _panelMoveStart(Offset pointer) {
    if (!_rectKnown) return;
    _moveRect = _rect;
    _latchPointerSource(pointer);
    _grabOffset = _grabPointer - _moveRect.topLeft;
    _grabArmed = true;
    // Live only once the 8px slop arms — a header click persists nothing.
  }

  void _panelMoveUpdate(Offset pointer) {
    if (!_grabArmed) return;
    final p = _livePointer(pointer);
    if (p == null) return;
    _grabLive = true;
    final area = _gestureArea(anchorOf(_moveRect, _dir));
    _moveRect = clampRectIntoWorkArea(
      Rect.fromLTWH(
        p.dx - _grabOffset.dx,
        p.dy - _grabOffset.dy,
        _moveRect.width,
        _moveRect.height,
      ),
      area,
    );
    unawaited(_applyBounds(_moveRect));
    c.noteGeometryLive(anchor: anchorOf(_moveRect, _dir));
  }

  void _panelMoveEnd() {
    if (!_grabArmed) return;
    _grabArmed = false;
    if (!_grabLive) return;
    _grabLive = false;
    c.noteGeometryDone(anchor: anchorOf(_moveRect, _dir));
    unawaited(_primeGeometry());
  }

  // -- resize: the anchor corner never moves, the panel grows away ---------
  //
  // The HWND never changes during the gesture (ticket 20's reshape
  // ghosting: every per-frame size change forces the engine to rebuild
  // its EGL surface, and even a single mid-gesture jump flashes — the
  // stale child surface composites top-left-aligned for one DWM frame
  // when the engine loses the present race). The window is ALREADY at
  // the growth ceiling (the expand jumped there, ADR 0017): the gesture
  // grows the card by layout in the slot and touches nothing but
  // Flutter state and the window region until the release.

  void _resizeStart(Offset pointer, Offset growSign) {
    if (!_rectKnown) return;
    _resizeAnchor = anchorOf(_rect, _dir);
    // The gesture's size base is the CARD (the slot), not the window —
    // the window sits at the growth ceiling while a panel is open.
    _resizeSize = _panelSize.value ?? _rect.size;
    _resizeSize0 = _resizeSize;
    _resizeSign = growSign;
    _latchPointerSource(pointer);
    _grabArmed = true;
    _grabLive = true; // press-to-resize: every press is a gesture
    // Unclip the window region: the card grows by layout beyond the
    // stale slot and must paint there (the gesture holds the pointer
    // capture, so the transiently hit-testable margin costs nothing).
    unawaited(_pushCardRegion(null));
  }

  void _resizeGrow(Offset pointer) {
    if (!_grabArmed) return;
    final p = _livePointer(pointer);
    if (p == null) return;
    final growth = Offset(
      (p.dx - _grabPointer.dx) * _resizeSign.dx,
      (p.dy - _grabPointer.dy) * _resizeSign.dy,
    );
    final size = clampPanelSize(
      _resizeSize0 + growth,
      _resizeAnchor,
      _dir,
      _gestureArea(_resizeAnchor),
    );
    if (size == _resizeSize) return; // a bound edge eats the motion
    _resizeSize = size;
    // Layout only — zero setBounds, and no StageHost.setState: the
    // slot's ValueListenableBuilder is the only subscriber.
    _panelSize.value = size;
    c.noteGeometryLive(panel: size);
  }

  void _resizeEnd() {
    if (!_grabArmed) return;
    _grabArmed = false;
    _grabLive = false;
    // The card kept growing inside the frozen window; only the window
    // region and the persisted footprint catch up.
    unawaited(_pushPanelRegion());
    c.noteGeometryDone(panel: _resizeSize);
    unawaited(_primeGeometry());
  }

  /// The card slot's rect in WINDOW coordinates — the OS window region
  /// (ADR 0017). Pushed when the slot moves within a still-open window
  /// (expand, resize settle) and cleared when the window must be whole
  /// (press — the growing card paints beyond the stale slot — and the
  /// orb stage). Window MOVES don't change window coordinates; mid-
  /// growth pushes are pointless while the gesture holds the pointer
  /// capture.
  Future<void> _pushCardRegion(Rect? region) async {
    final window = widget.stageWindow;
    if (window == null) return;
    await window.setCardRegion(region);
  }

  Future<void> _pushPanelRegion() => _pushCardRegion(_panelRegion());

  Rect? _panelRegion() {
    final size = _panelSize.value;
    if (size == null) return null;
    final anchor = anchorOf(_rect, _dir);
    return panelRectFor(anchor, size, _dir).shift(-_rect.topLeft);
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
          onStart: (p) => _resizeStart(p, Offset(left ? -1 : 1, 0)),
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
          onStart: (p) => _resizeStart(p, Offset(0, up ? -1 : 1)),
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
          onStart: (p) => _resizeStart(p, Offset(left ? -1 : 1, up ? -1 : 1)),
          onGrow: _resizeGrow,
          onEnd: _resizeEnd,
        ),
      ),
    ];
  }

  /// The panel's slot in the window: full-bleed whenever the window is
  /// the panel footprint itself; the anchor-pinned sub-rect while the
  /// window is bigger than the card (a resize gesture freezing the HWND
  /// at its growth ceiling). Keyed on the LAYOUT constraints, not the
  /// commanded bounds — the view takes a setBounds a frame or two after
  /// Dart sends it, and a slot computed against bounds the view hasn't
  /// reached yet paints those frames at the wrong offset; the
  /// constraints are always exactly what this frame renders at, so the
  /// card stays anchor-pinned through the freeze and release jumps.
  ///
  /// The card itself is the [ValueListenableBuilder]'s `child`, so a
  /// resize notifies only this builder (the Positioned) — StageHost
  /// does not setState, and the panel Element is reused.
  Widget _panelSlot({required Widget child}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ValueListenableBuilder<Size?>(
          valueListenable: _panelSize,
          child: child,
          builder: (context, panelSize, slot) {
            final view = constraints.biggest;
            final size = panelSize ?? view;
            final anchor = anchorOf(Offset.zero & view, _dir);
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fromRect(
                  rect: panelRectFor(anchor, size, _dir),
                  child: slot!,
                ),
              ],
            );
          },
        );
      },
    );
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
          // Panel bodies and their resize affordances share one slot:
          // full-bleed while the window IS the panel footprint, the
          // anchor-pinned sub-rect while a resize gesture grows the card
          // by layout inside the frozen window. Only one panel is
          // mounted at a time; each animates its own entrance on mount
          // and exit via [PanelBody.exiting].
          if (_displayed != StageKind.orb)
            _panelSlot(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _displayed == StageKind.session
                        ? SessionPanel(
                            controller: c,
                            exiting: _exiting,
                            dir: _dir,
                            grip: _grip,
                          )
                        : QuickPanel(
                            controller: c,
                            exiting: _exiting,
                            onOpenSettings: widget.onOpenSettings,
                            dir: _dir,
                            grip: _grip,
                          ),
                  ),
                  // The resize affordances ride above the panel, flush to
                  // the slot's free edges (the shared footprint resizes
                  // as one — 一调俱调).
                  if (_gesturesLive) ..._resizeHandles(),
                ],
              ),
            ),
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
