/// Window-stage choreography: the panel expand/collapse and the window
/// model underneath it.
///
/// Permanent work-area window (16 号票 / ADR-0022): the HWND is seated
/// on the anchor's work area once, BEFORE it is ever shown, and NEVER
/// changes size on the choreography path. Every visible HWND size
/// change races the engine's next present (ADR-0017's probe: the stale
/// surface composites top-left-aligned for one DWM frame — the ghost
/// orb at the screen corner, and the orb's blink-at-rest, that the
/// 10/11/12 device check caught); a window that never resizes cannot
/// lose that race. All shaping is the OS window REGION plus Flutter
/// layout:
/// - Idle: region = the orb footprint — the window paints and
///   hit-tests exactly the 96x96 it always did.
/// - Expand: region = the card rect (pushed at expand; the card grows
///   inside it, 11 号票), the card growing out of the socket disc
///   around the pixel-stationary orb over [SrMotion.grow].
/// - Panel period: dragging the anchor button moves ONLY window-internal
///   layout (card + chrome follow the ball; the HWND never moves except
///   a monitor crossing, one atomic jump). Crossing the work-area
///   center +48 re-derives the growth direction (跨阈重推); the growth
///   ceiling is the CARD's size cap (half the work area), not the HWND.
///   The re-pin is the QUADRANT MOTION LAYER (12 号票): the card's size
///   never changes — its position springs around the ball to the new
///   corner ([PanelForm], critically damped, retargetable mid-flight),
///   and every chrome obligation derives from the same two continuous
///   form values, moving in step, never disappearing.
/// - Collapse: the card shrinks back into the socket disc
///   ([SrMotion.grow], the same-direction profile — never a reversed
///   playback), then the region narrows back to the orb footprint —
///   zero setBounds; the orb paints its receipt flash inside it.
///
/// The idle orb drag is the SAME in-window anchor drag as the panel
/// one; a monitor crossing is the one remaining atomic jump (work area
/// to work area), and a topology drift heals at the next prime.
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
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart' as sr;
import 'package:window_manager/window_manager.dart';

import '../../app_state.dart';
import '../design/toast.dart';
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
export 'window_geometry.dart' show GrowthDirection, GrowthDirectionX, WorkAreas;

/// The window bounds a stage needs. One seam, two implementations: the
/// real window_manager-backed one in production, a recorder in tests.
abstract class StageWindow {
  Future<Offset> getPosition();
  Future<Size> getSize();

  /// Seat the window on a rect in GLOBAL PHYSICAL pixels (17 号票): the
  /// OS move must never ride a logical→physical conversion through the
  /// Flutter view's dpr — that value lags a monitor hop, which is how a
  /// mixed-DPI crossing used to land the window misplaced and strand the
  /// orb outside it (invisible and unclickable until the next heal).
  /// Returns the LANDED rect in the window's logical space, normalized
  /// by the post-move dpr — the truth the host adopts.
  Future<Rect> seatBoundsPhysical(Rect physical);

  /// While a panel stage holds the work-area window (ADR 0017, 02 号
  /// 票), the card slot's rect in WINDOW LOGICAL coordinates — the OS
  /// window region narrows to it, so the transparent margin neither
  /// paints nor hit-tests (clicks fall through to the desktop). The
  /// native side scales by its live dpr at execution time. Null
  /// restores the whole window (the orb stage, and any gesture whose
  /// moving card must paint beyond the stale slot — resize growth,
  /// anchor drag).
  Future<void> setCardRegion(Rect? windowRect);

  /// Every display's work area in the window's single coordinate space
  /// (17 号票: uniformly ÷ the window's dpr, so the rects tile the
  /// desktop exactly at any DPI mix) with their physical twins — the
  /// drag/resize clamps, the expand-direction chooser, and the monitor
  /// hop consume these.
  Future<WorkAreas> workAreas();

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
  Future<Rect> seatBoundsPhysical(Rect physical) async {
    const channel = MethodChannel('spokenrectifier/window');
    final res = await channel.invokeMethod('setBoundsPhysical', {
      'left': physical.left.round(),
      'top': physical.top.round(),
      'right': physical.right.round(),
      'bottom': physical.bottom.round(),
    });
    final map = Map<String, dynamic>.from(res as Map);
    return Rect.fromLTWH(
      (map['left'] as num).toDouble(),
      (map['top'] as num).toDouble(),
      (map['width'] as num).toDouble(),
      (map['height'] as num).toDouble(),
    );
  }

  @override
  Future<void> setCardRegion(Rect? windowRect) {
    // Logical window coordinates; the native side scales by its LIVE
    // dpr at execution time — a Dart-side × view-dpr multiplication
    // would ride the same lag the seating above sheds (17 号票).
    const channel = MethodChannel('spokenrectifier/window');
    if (windowRect == null) {
      return channel.invokeMethod('setRegion');
    }
    return channel.invokeMethod('setRegion', {
      'left': windowRect.left,
      'top': windowRect.top,
      'right': windowRect.right,
      'bottom': windowRect.bottom,
    });
  }

  @override
  Future<WorkAreas> workAreas() async {
    final displays = await sr.screenRetriever.getAllDisplays();
    // visible* arrives normalized by EACH monitor's own scale factor
    // (screen_retriever's MonitorToEncodableMap) — on a mixed-DPI
    // desktop those rects tile no single space. De-normalize to global
    // physical, then divide every rect by the SAME window dpr: one
    // uniform scaling of the desktop, dead-zone-free at any DPI mix.
    // A display without visible*/scale readings is unusable for
    // clamping; skip it rather than guess.
    return normalizeAreas([
      for (final d in displays)
        if (d.visiblePosition != null &&
            d.visibleSize != null &&
            d.scaleFactor != null &&
            d.scaleFactor! > 0)
          (
            reported: Rect.fromLTWH(
              d.visiblePosition!.dx,
              d.visiblePosition!.dy,
              d.visibleSize!.width,
              d.visibleSize!.height,
            ),
            scaleFactor: d.scaleFactor!.toDouble(),
          ),
    ], windowManager.getDevicePixelRatio());
  }

  @override
  Offset? pointerOnScreen() =>
      logicalCursorScreen(windowManager.getDevicePixelRatio());

  @override
  Future<void> focus() => windowManager.focus();
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

class _StageHostState extends State<StageHost>
    with SingleTickerProviderStateMixin {
  StageKind _displayed = StageKind.orb;

  /// The direction the open panel (or the next one) grows in. Chosen at
  /// every expand from the anchor's quadrant, then RE-DERIVED on every
  /// center+48 threshold cross while a panel is open (跨阈重推, 02 号票 —
  /// the card re-pins around the ball at the new corner; the chrome
  /// re-derives discretely with it). The orb stage's layout mirrors it
  /// too, so the ball sits in the corner the next panel will grow from.
  GrowthDirection _dir = GrowthDirection.upLeft;

  /// The anchor (ball center) in SCREEN coordinates — the one point the
  /// whole choreography keys on, maintained live through every gesture.
  /// The window rect alone stopped implying it when the panel-period
  /// window became the whole work area (02 号票): the anchor sits
  /// wherever the ball is, not at a window corner.
  Offset _anchor = Offset.zero;

  /// The anchor in WINDOW-local coordinates, as a notifier so the card
  /// slot and the orb button follow a drag without [setState] on this
  /// host (the H3 rebuild tax — panels and their measuring surfaces
  /// must not rebuild per pointer move). Re-synced by [_applyBounds]
  /// (window jumps re-base the local frame) and every anchor move.
  final ValueNotifier<Offset> _anchorLocalN = ValueNotifier(Offset.zero);

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

  /// The quadrant motion layer (12 号票): the per-axis form values the
  /// card rect and every chrome obligation derive from. Snapped at
  /// every expand, retargeted on every threshold flip — the drag's per-
  /// pointer updates never touch it (the card translates with the ball
  /// by anchor alone; only a flip animates).
  late final PanelForm _form;

  /// A release deferred the hit-region push because the form was still
  /// springing — the region must never hug a rect the card has left
  /// (it lands when the form settles).
  bool _regionAfterMotion = false;

  SpeechController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    _form = PanelForm(this)..addListener(_onFormSettled);
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
    _form.snap(true, true);
    _regionAfterMotion = false;
    _seq++;
    _panelSize.value = null;
    _anchorLocalN.value = Offset.zero;
    _rectKnown = false;
    _prevRect = Rect.zero;
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
    _anchorLocalN.dispose();
    _form.removeListener(_onFormSettled);
    _form.dispose();
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

  /// The expand (ticket 20 + 02 号票): direction derived from the
  /// anchor's quadrant in the work area holding it, card size clamped
  /// to what that anchor can host. The window is ALREADY that work area
  /// (ADR-0022 — seated at startup, healed at every prime), so the
  /// expand issues NO setBounds at all; the corrective branch below
  /// only fires when a topology change slipped past the primes. The
  /// card renders in the slot at its anchor-derived rect; the
  /// transparent margin neither paints nor hit-tests ([setCardRegion] —
  /// the card rect from here on). Win+Tab sees a work-area transparent
  /// window — the known, accepted cost (02).
  Future<void> _expandBounds(StageWindow window) async {
    _areasW = await window.workAreas(); // refresh for the gestures to come
    final area = _gestureArea(_anchor);
    if (_rect != area) {
      await _applyBounds(area);
    } else {
      _syncAnchorLocal();
    }
    // The hotkey wake-up path lands here with the anchor possibly parked
    // outside the window (the stranding this ticket cured at the source;
    // the snap is the belt-and-suspenders that also heals legacy states)
    // — pull it in before the plan derives from it (17 号票).
    _snapAnchorInto(_rect);
    final plan = expandPlan(_anchor, c.panelFootprint, _rect);
    _dir = plan.dir;
    _form.snap(plan.dir.growLeft, plan.dir.growUp);
    _panelSize.value = plan.size;
    unawaited(_pushStageRegion());
  }

  Future<void> _collapse() async {
    final seq = ++_seq;
    _settling = StageKind.orb;
    _grabArmed = false;
    _grabLive = false;
    _regionAfterMotion = false;
    // 1. Grow-back animation on the still-open panel (the card shrinks
    //    into the socket disc, 11 号票).
    setState(() => _exiting = true);
    await Future<void>.delayed(SrMotion.grow + _collapseSlack);
    if (!mounted || seq != _seq) return;
    // 2. The window NEVER shrinks (ADR-0022: a visible size change
    // races the engine's present — the ghost/blink the device check
    // caught). The region narrows to the orb footprint instead: the
    // card is already back inside the disc, the orb paints its receipt
    // flash within, and the desktop around it comes back. Region
    // first; the slot notifier stays until the panel unmounts below —
    // notifying null while the card is still in the tree would flash
    // it full-bleed for a frame.
    if (widget.stageWindow != null) {
      unawaited(_pushCardRegion(orbFootprintAt(_anchor).shift(-_rect.topLeft)));
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
  /// changes between gestures, never under a held pointer). The snapshot
  /// carries the physical twins the monitor hop commands (17 号票).
  WorkAreas? _areasW;
  Rect _rect = Rect.zero;

  /// The rect commanded before [_rect]: while the view lags a jump
  /// (metrics land a frame or two after setBounds), the stale view is
  /// still the previous window — [_anchorInView] pins the anchor into
  /// it so the ball never leaves the surface mid-jump.
  Rect _prevRect = Rect.zero;
  bool _rectKnown = false;

  /// Live geometry per gesture kind (only one kind runs at a time).
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

  /// In-flight seating coalescing: pointer events outrun the platform
  /// channel, and a queue of stale rects flickers the window backwards.
  /// One pump sends the latest pending seat each lap; expand/collapse
  /// await until the pump is idle so their jump lands before the swap.
  /// The seat carries both frames — the logical rect the cache assumes
  /// immediately, and the physical twin the OS move commands (17 号票).
  ({Rect logical, Rect physical})? _pendingBounds;
  Future<void>? _boundsIdle;
  bool _pumping = false;

  /// Press sampled a grab; updates no-op until then. Cleared on expand
  /// so a click-that-opens cannot keep moving the window.
  bool _grabArmed = false;

  /// A real drag update ran (past the 8px slop); end persists only then.
  bool _grabLive = false;

  /// Gestures need the real window; pure-UI tests run without one.
  bool get _gesturesLive => widget.stageWindow != null;

  Future<void> _primeGeometry() async {
    final window = widget.stageWindow;
    if (window == null) return;
    _areasW = await window.workAreas();
    if (!_rectKnown) {
      final pos = await window.getPosition();
      final size = await window.getSize();
      _rect = Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
      _rectKnown = true;
      // First prime: adopt the bootstrap's published anchor (ADR-0022 —
      // the window is the work area and no longer implies where the
      // ball sits); a legacy footprint window's center stands in when
      // nothing published one (tests, degenerate launches).
      _setAnchor(c.orbAnchor ?? _rect.center);
    }
    // Self-heal (ADR-0022): seat the window on the anchor's work area
    // whenever the two drifted apart — a display-topology change, or a
    // recording window that starts as the footprint. Always off the
    // visual path: primes run at mount and gesture ends, never under a
    // held pointer.
    final areas = _areasW;
    if (areas != null && areas.logical.isNotEmpty) {
      final area = areaHolding(_anchor, areas.logical);
      if (_rect != area) await _applyBounds(area);
      _snapAnchorInto(_rect);
    }
    // Resting idle: the region is the orb footprint (the window's
    // shape). Skipped while a panel still holds the window — its own
    // pushes own the region — or a gesture runs.
    if (c.stage == StageKind.orb &&
        _displayed == StageKind.orb &&
        !_grabArmed) {
      unawaited(_pushStageRegion());
    }
  }

  /// Pull the anchor back inside the (landed) window whenever its
  /// footprint fell out (17 号票): a monitor hop's dpr flip leaves the
  /// last drag frames computing the cursor in the STALE space — the
  /// anchor can park outside the window the OS actually seated. Clamping
  /// into the landed rect bounds the error to the work-area edge and
  /// persists the correction; a coherent anchor never moves (the clamp
  /// is the identity then).
  void _snapAnchorInto(Rect area) {
    final snapped = clampAnchor(_anchor, area);
    if (snapped == _anchor) return;
    _setAnchor(snapped);
    c.noteGeometryDone(anchor: snapped);
  }

  /// Every bounds this host commands goes through here: the cache and
  /// the OS window never disagree about where the window is. In-flight
  /// calls coalesce to the latest seat — a queue of stale SetWindowPos
  /// is what flickered the orb backwards mid-drag. Expand/collapse await
  /// until this rect (or a later one) has been sent, including a leftover
  /// pump spawned after the previous future already completed.
  Future<void> _applyBounds(Rect bounds) async {
    _prevRect = _rect;
    _rect = bounds;
    _rectKnown = true;
    _syncAnchorLocal(); // a jump re-bases the local frame
    _pendingBounds = (
      logical: bounds,
      physical: _areasW?.physicalFor(bounds) ?? bounds,
    );
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
        final window = widget.stageWindow;
        if (window == null) continue;
        final landed = await window.seatBoundsPhysical(next.physical);
        // A monitor hop flips the window's dpr between the send and the
        // reply: adopt the LANDED rect (the post-move truth, normalized
        // by the new dpr) as the cache — unless a newer seat already
        // superseded this lap (17 号票: this is the re-base that keeps
        // the region and the paint computing in the settled space).
        if (_pendingBounds == null && mounted && landed != _rect) {
          _prevRect = _rect;
          _rect = landed;
          _rectKnown = true;
          _syncAnchorLocal();
        }
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

  /// The logical work-area list of the cached snapshot (empty while
  /// unprimed).
  List<Rect> get _areas => _areasW?.logical ?? const <Rect>[];

  /// The area a point lands in for planning and clamping; a silent
  /// query (no areas at all) falls back to a rect so wide the clamps
  /// never bind.
  Rect _gestureArea(Offset point) {
    final areas = _areas;
    if (areas.isEmpty) {
      return Rect.fromLTWH(-16000, -16000, 32000, 32000);
    }
    return areaHolding(point, areas);
  }

  // -- the live anchor (screen ↔ window-local ↔ view) -----------------------

  /// Move the anchor (screen coordinates) and re-base the local frame.
  void _setAnchor(Offset screen) {
    _anchor = screen;
    _syncAnchorLocal();
  }

  /// Re-derive the local anchor from [_anchor] and [_rect] — after a
  /// window jump re-based the frame. A same value does not notify (the
  /// orb stage's per-frame moves keep the local anchor constant).
  void _syncAnchorLocal() {
    _anchorLocalN.value = _anchor - _rect.topLeft;
  }

  /// The anchor in VIEW coordinates for a view of [view] size. When the
  /// view has caught up with [_rect] this is the plain local anchor;
  /// while it lags a commanded jump (the view takes a setBounds a frame
  /// or two after Dart sends it), the stale view is still the PREVIOUS
  /// window — the anchor's position in THAT is what should paint, so
  /// the ball never leaves the surface mid-jump.
  Offset _anchorInView(Size view) {
    final stale =
        (view.width - _rect.width).abs() > 0.5 ||
        (view.height - _rect.height).abs() > 0.5;
    return _anchor - (stale ? _prevRect.topLeft : _rect.topLeft);
  }

  /// The work area a panel drag targets: the one the CANDIDATE anchor
  /// lands in (a monitor crossing re-bases the window on it), or the
  /// current rect when the candidate sits between work areas (the
  /// pointer is on its way somewhere; the clamp holds the ball inside).
  Rect _dragTargetArea(Offset candidate) {
    for (final area in _areas) {
      if (area.contains(candidate)) return area;
    }
    return _rect;
  }

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

  // -- the anchor drag: one path, every stage (ADR-0022) --------------------
  //
  // The window NEVER moves for a drag — the anchor is window-internal
  // content (the orb; plus the card and chrome while a panel is open),
  // so dragging the ball is the SAME gesture at every stage: the press
  // unclips the region, the updates move the anchor (everything
  // orb-keyed follows by layout), the release re-pins the region and
  // persists. The one HWND motion left is the monitor crossing (a
  // single atomic jump onto the new work area). The orb button gates
  // the 8px threshold; within it a release is the primary action, past
  // it a drag that cannot click.

  void _anchorDragStart(Offset pointer) {
    if (!_rectKnown) return;
    _latchPointerSource(pointer);
    _grabOffset = _grabPointer - _anchor;
    _grabArmed = true;
    // Live only once the 8px slop arms — within it a release is the
    // orb button's primary action (阈内松手=主操作), never a move. The
    // moving orb/card must paint beyond the stale region: unclip for
    // the gesture (the press holds pointer capture, so the transiently
    // hit-testable margin costs nothing — same as a resize press).
    unawaited(_pushCardRegion(null));
  }

  void _anchorDragUpdate(Offset pointer) {
    if (!_grabArmed) return;
    final p = _livePointer(pointer);
    if (p == null) return;
    _grabLive = true;
    // Absolute (pointer − grab), not accumulated deltas — the clamp at
    // a work-area edge builds no debt for the return trip.
    final candidate = p - _grabOffset;
    final area = _dragTargetArea(candidate);
    final anchor = clampAnchor(candidate, area);
    // The monitor crossing: one atomic jump onto the new work area
    // (the only HWND motion of the gesture, idle or panel; pure
    // translation when the areas match in size).
    if (area != _rect) unawaited(_applyBounds(area));
    _setAnchor(anchor);
    c.noteGeometryLive(anchor: _anchor);
    // The threshold switch (跨阈重推), panel stages only: past the
    // work-area center +48 the direction flips and the quadrant motion
    // layer carries the re-pin (12 号票) — the card SPRINGS around the
    // ball to the new corner (size unchanged), the chrome re-deriving
    // continuously from the same form values. The setState here only
    // refreshes the discrete [_dir] consumers (resize handles, clamps);
    // the card itself moves on the form's notifies. Inside the band
    // the direction holds: the card only translates, socket concentric
    // (未过中心只平移). At the orb stage nothing flips — the expand
    // derives its own direction.
    if (_displayed != StageKind.orb) {
      final dir = rederiveDirection(_dir, anchor, area);
      if (dir != _dir) {
        setState(() => _dir = dir);
        _form.retarget(growLeft: dir.growLeft, growUp: dir.growUp);
      }
    }
  }

  void _anchorDragEnd() {
    if (!_grabArmed) return;
    _grabArmed = false;
    final live = _grabLive;
    _grabLive = false;
    // No quadrant snap (松手不吸附): the ball parks wherever it is, and
    // that is the anchor. The direction stays derived, never stored.
    if (live) c.noteGeometryDone(anchor: _anchor);
    // Release: the hit region catches up to wherever the stage now
    // rests — the card rect with a panel open (restoring what the
    // press unclipped, including a click that never armed), the orb
    // footprint at idle (the prime below owns that one — a click at
    // idle is about to open or close a stage, and that transition owns
    // the very next push). A switch still springing DEFERS the push to
    // landing: the region must never hug a rect the card is on its way
    // out of.
    if (_displayed != StageKind.orb) {
      if (_form.atRest) {
        unawaited(_pushStageRegion());
      } else {
        _regionAfterMotion = true;
      }
    }
    unawaited(_primeGeometry()); // fresh areas + heal + idle footprint
  }

  /// The form's settle watcher: a release that deferred its hit-region
  /// push lands it now — the card has arrived at the rect the region
  /// hugs. Panel already closed or a new gesture armed: the flag waits
  /// for the next settle (the gesture's own release re-evaluates).
  void _onFormSettled() {
    if (!_form.atRest || !_regionAfterMotion) return;
    _regionAfterMotion = false;
    if (_displayed != StageKind.orb && !_grabArmed) {
      unawaited(_pushStageRegion());
    }
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
    _resizeAnchor = _anchor;
    // The gesture's size base is the CARD (the slot), not the window —
    // the window sits at the whole work area while a panel is open.
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
    unawaited(_pushStageRegion());
    c.noteGeometryDone(panel: _resizeSize);
    unawaited(_primeGeometry());
  }

  /// The card slot's rect in WINDOW coordinates — the OS window region
  /// (ADR 0017). Lifted to null when the window must be whole (a press
  /// whose moving card would paint beyond the stale slot — resize
  /// growth, anchor drag). Mid-gesture pushes are pointless while the
  /// gesture holds the pointer capture; window MOVES don't change
  /// window coordinates.
  Future<void> _pushCardRegion(Rect? region) async {
    final window = widget.stageWindow;
    if (window == null) return;
    await window.setCardRegion(region);
  }

  /// The stage's resting region (window coordinates): the card rect
  /// while a panel holds the window, the orb footprint at idle — the
  /// window itself is ALWAYS the whole work area (ADR-0022), so the
  /// region is the only thing that ever narrows it. Pushed when the
  /// stage settles (idle prime, expand, resize release, drag release,
  /// collapse end).
  Rect _stageRegion() {
    final size = _panelSize.value;
    if (size != null) {
      return panelRectFor(_anchor, size, _dir).shift(-_rect.topLeft);
    }
    return orbFootprintAt(_anchor).shift(-_rect.topLeft);
  }

  Future<void> _pushStageRegion() => _pushCardRegion(_stageRegion());

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

  /// The panel's slot: the card is a rect INSIDE the (work-area)
  /// window — anchor position + growth direction + clamped size derive
  /// it (02 号票: the card is no longer the window). Keyed on the LAYOUT
  /// constraints where they disagree with the commanded bounds: the
  /// view takes a setBounds a frame or two after Dart sends it, and a
  /// slot computed against bounds the view hasn't reached yet paints
  /// those frames at the wrong offset — [_anchorInView] degrades the
  /// anchor into the stale view instead.
  ///
  /// The card itself is the inner builder's `child`, so a resize or a
  /// drag notifies only the builders (the Positioned) — StageHost does
  /// not setState per pointer move, and the panel Element is reused.
  Widget _panelSlot({required Widget child}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ValueListenableBuilder<Size?>(
          valueListenable: _panelSize,
          child: child,
          builder: (context, panelSize, slot) {
            return ValueListenableBuilder<Offset>(
              valueListenable: _anchorLocalN,
              builder: (context, _, _) {
                // The form's notifies drive the re-pin alone: the card
                // translates around the ball while the panel Element
                // itself stays put (the H3 rebuild tax — only the
                // Positioned re-builds per tick).
                return AnimatedBuilder(
                  animation: _form,
                  child: slot,
                  builder: (context, slotChild) {
                    final view = constraints.biggest;
                    final size = panelSize ?? view;
                    // Without a stage window (pure-UI tests) the view IS
                    // the card, full-bleed at the derived corner.
                    final anchor = _rectKnown
                        ? _anchorInView(view)
                        : anchorOf(Offset.zero & view, _dir);
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned.fromRect(
                          rect: panelRectAt(
                            anchor,
                            size,
                            gl: _form.gl,
                            gu: _form.gu,
                          ),
                          child: slotChild!,
                        ),
                      ],
                    );
                  },
                );
              },
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
                  // The panel stage's toast layer (ui-copy toast spec):
                  // bottom-center IN the card, fixed — never flipped by
                  // the growth direction. The scope wraps the panel at
                  // the slot, so the slot edge is the card's outer
                  // bounds (the card paints its 8px margin inside) and
                  // 72 parks the capsule above the session footer band
                  // and the quick panel's bottom content — the value
                  // the verdict was judged on in the prototype.
                  Positioned.fill(
                    child: SrToastScope(
                      anchor: SrToastAnchor.bottom,
                      clearance: 72,
                      child: _displayed == StageKind.session
                          ? SessionPanel(
                              controller: c,
                              exiting: _exiting,
                              form: _form,
                            )
                          : QuickPanel(
                              controller: c,
                              exiting: _exiting,
                              onOpenSettings: widget.onOpenSettings,
                              form: _form,
                            ),
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
          // in panel stages — same widget, same screen position, at the
          // anchor wherever it sits in the window (02 号票: the panel
          // window is the whole work area; the ball is mid-window, no
          // longer at a corner). OrbButton lays itself out at the full
          // orb footprint (96x96) with the ball centered, so the ball
          // center lands exactly on the anchor and stays concentric with
          // the card's corner arc (an inset would push the ball off the
          // arc center — third preview round).
          LayoutBuilder(
            builder: (context, constraints) {
              return ValueListenableBuilder<Offset>(
                valueListenable: _anchorLocalN,
                child: OrbButton(
                  controller: c,
                  onDragStart: _gesturesLive ? _anchorDragStart : null,
                  onDragUpdate: _gesturesLive ? _anchorDragUpdate : null,
                  onDragEnd: _gesturesLive ? _anchorDragEnd : null,
                ),
                builder: (context, _, orb) {
                  final view = constraints.biggest;
                  final anchor = _rectKnown
                      ? _anchorInView(view)
                      : anchorOf(Offset.zero & view, _dir);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fromRect(
                        rect: orbFootprintAt(anchor),
                        child: orb!,
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The quadrant motion layer (12 号票, language by 02 / 08): the open
/// panel's per-axis CONTINUOUS FORM VALUES, [gl]/[gu] ∈ [0,1].
///
/// 1 = the card's anchor edge sits `anchorInset` outward on that side
/// (grows left / up from the ball); 0 = the opposite side; a mid-value
/// is the switch's transit — the card keeps its SIZE and translates
/// around the ball (the ball presses into the card interior, occluded
/// topmost, the socket back to concentric at rest). The card rect and
/// EVERY chrome obligation derive from these two doubles — one source,
/// everything moves in step.
///
/// Each axis is one critically damped spring ([SrMotion.quadSpring*]):
/// a threshold flip swaps only that axis's TARGET, carrying the current
/// position and velocity into the new simulation — the clock never
/// restarts (重定向只换目标、速度连续; a mid-flight re-cross retargets
/// again, it never bounces). The ticker runs only while an axis is in
/// flight and stops at rest.
class PanelForm extends ChangeNotifier {
  PanelForm(TickerProvider vsync) {
    // Constructor body, not an initializer: the callback is an instance
    // method tear-off.
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: SrMotion.quadSpringMass,
    stiffness: SrMotion.quadSpringStiffness,
  );

  double _gl = 1.0;
  double _gu = 1.0;
  _AxisSpring? _x;
  _AxisSpring? _y;
  Duration _lastTick = Duration.zero;

  /// The current form values — card rect and chrome derivation read
  /// these live (build 直读).
  double get gl => _gl;
  double get gu => _gu;

  /// True while no axis is in flight — the settled state callers wait
  /// on (e.g. the deferred hit-region push).
  bool get atRest => _x == null && _y == null;

  /// Set the form without animating: mount, expand, and resets land on
  /// their corner directly — the grow choreography owns the entrance.
  void snap(bool growLeft, bool growUp) {
    _x = null;
    _y = null;
    _ticker.stop();
    _lastTick = Duration.zero;
    final gl = growLeft ? 1.0 : 0.0;
    final gu = growUp ? 1.0 : 0.0;
    if (_gl == gl && _gu == gu) return;
    _gl = gl;
    _gu = gu;
    notifyListeners();
  }

  /// Spring toward the new corner: per axis, only a CHANGED target gets
  /// a new simulation — seeded from the axis's current value and the
  /// running spring's velocity (continuity; an idle axis starts at
  /// rest). A target equal to the value at rest spawns nothing.
  void retarget({required bool growLeft, required bool growUp}) {
    _x = _retargetAxis(_x, _gl, growLeft);
    _y = _retargetAxis(_y, _gu, growUp);
    if (!atRest && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  _AxisSpring? _retargetAxis(_AxisSpring? axis, double value, bool one) {
    final target = one ? 1.0 : 0.0;
    if (axis != null && axis.target == target) return axis;
    if (axis == null && value == target) return null;
    final velocity = axis?.velocity ?? 0.0;
    return _AxisSpring(
      SpringSimulation(_spring, value, target, velocity),
      target,
    );
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    _gl = _advance(_x, _gl, dt);
    _gu = _advance(_y, _gu, dt);
    if (atRest) {
      _ticker.stop();
      _lastTick = Duration.zero;
    }
    notifyListeners();
  }

  double _advance(_AxisSpring? axis, double value, Duration dt) {
    if (axis == null) return value;
    axis.t += dt;
    final t = axis.t.inMicroseconds / 1e6;
    final x = axis.sim.x(t);
    // Distance is the landing test (a sub-per-mil residue is invisible;
    // Simulation.isDone also demands a 1e-3 VELOCITY, which a critical
    // spring only reaches ~200ms past its visible settle — the snap
    // would stall every caller waiting on [atRest]).
    if ((x - axis.target).abs() > 0.001) return x;
    // Landed: snap to the exact endpoint (chrome mounts key off exact
    // 0/1) and retire the axis.
    if (identical(axis, _x)) _x = null;
    if (identical(axis, _y)) _y = null;
    return axis.target;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // ---- chrome derivation (统一派生: both surfaces read these) ----------

  /// The header row's orb-side reserve (56, the ring-bearing row): each
  /// side carries the full width scaled by how much the orb sits on the
  /// header row at all (1 − gu) and on that side (leading = 1 − gl).
  /// The cluster between them TRANSLATES as the weights trade (整簇平移
  /// 让位) — nothing disappears.
  double headerReserve({required bool leading}) =>
      SrGeometry.anchorHeaderReserve * (1 - gu) * (leading ? 1 - gl : gl);

  /// The session footer's orb-side reserve (48, the bare ball core).
  double footerReserve({required bool leading}) =>
      SrGeometry.anchorInset * gu * (leading ? 1 - gl : gl);

  /// The footer button group's horizontal alignment (−1 row start … +1
  /// row end): right-aligned ONLY in the bottom-left form (upRight) —
  /// everywhere else the group hugs the row start. A switch slides the
  /// whole group across the row (整组横滑换对齐, 序不翻), passing under
  /// the ball where the paths cross (the ball occludes).
  double get footerAlignX => -1 + 2 * (1 - gl) * gu;

  /// Body content's top padding: 12 under a bottom-anchored orb,
  /// growing to 48 as the orb takes the header's edge (连续插值).
  double get bodyTopPad =>
      SrSpace.md + (SrGeometry.anchorInset - SrSpace.md) * (1 - gu);
}

/// One axis's flight: the running simulation, its target, and the time
/// since it started (velocity is sampled from the simulation itself).
class _AxisSpring {
  _AxisSpring(this.sim, this.target);

  final SpringSimulation sim;
  final double target;
  Duration t = Duration.zero;

  double get value => sim.x(t.inMicroseconds / 1e6);
  double get velocity => sim.dx(t.inMicroseconds / 1e6);
}

/// Grow-choreography constants (component values, not tokens — they only
/// ever participate in this dance): the socket disc's side (窝圆 = 2×R,
/// the growth's degenerate start), the ring-solid threshold (环先实 —
/// opacity reaches 1 at 80% of the size progress), and the scheduling
/// slack that lets the grow-back finish landing before the window
/// shrinks under it.
const _discSide = SrRadius.panel * 2;
const _ringSolidAt = 0.8;
const _collapseSlack = Duration(milliseconds: 30);

/// A panel body: the floating card that GROWS out of the socket disc
/// around the orb and collapses back into it (11 号票, language by the
/// 01 grilling + 07 prototype), pinned to the quadrant form (12 号票).
///
/// Width and height lerp from the disc (2R, concentric with the ball —
/// the anchor corner's arc stays pinned, radius constant) to the shared
/// footprint; the corner the growth pins is the form's CONTINUOUS
/// blend — [PanelForm]'s per-axis values place the card so the disc
/// stays concentric at every gl/gu (a quadrant flip mid-growth simply
/// re-pins the blend). The chrome pins to the card's CURRENT edges —
/// header to the visual top, the session footer to the visual bottom
/// (头底不换, 四向同律), the body clipped to the remaining height. Opacity
/// rides the SAME timeline, reaching 1 at 80% of the size progress
/// (环先实 — never a fade-then-grow). The collapse plays the
/// same-direction profile v = 1 − C(u) (大时快、近球时慢) as a FORWARD
/// tween — never a `controller.reverse()`, which would replay the
/// entrance backwards (hang large, slam the ball).
class PanelBody extends StatefulWidget {
  const PanelBody({
    super.key,
    required this.exiting,
    required this.form,
    required this.header,
    required this.body,
    this.footer,
  });

  /// True while the stage host plays the grow-back animation before
  /// shrinking the window.
  final bool exiting;

  /// The quadrant form: the card's anchor corner blends along the
  /// per-axis values (1 = left/up), keeping the socket disc concentric
  /// with the ball at every value of the growth AND the switch.
  final PanelForm form;

  /// The pinned top band (the header row plus its divider): laid out at
  /// natural height at the card's current visual top.
  final Widget header;

  /// The middle: forced into the height left between the bands and
  /// clipped to it; stretches to the card's bottom when there is no
  /// footer (the quick panel).
  final Widget body;

  /// The session window's footer band: pinned to the card's current
  /// visual bottom. Null for the quick panel.
  final Widget? footer;

  @override
  State<PanelBody> createState() => _PanelBodyState();
}

/// The pinned-chrome layout (钉边裁切): header at the card's current
/// top, footer at its current bottom, the body tight between them —
/// everything beyond the card paints clipped by the card's rounded
/// clip. Bands and body lay out at the chrome width floor while the
/// card is narrower (mid-growth), so no row ever reports an overflow;
/// the surplus just paints clipped, exactly the way the prototype's
/// `overflow: hidden` behaved.
class _PinnedChromeLayout extends MultiChildLayoutDelegate {
  _PinnedChromeLayout();

  static const _header = 'header';
  static const _body = 'body';
  static const _footer = 'footer';

  @override
  void performLayout(Size size) {
    final width = size.width < SrGeometry.panelMinSize.width
        ? SrGeometry.panelMinSize.width
        : size.width;
    final headerH = layoutChild(
      _header,
      BoxConstraints.tightFor(width: width),
    ).height;
    positionChild(_header, Offset.zero);
    final hasFooter = hasChild(_footer);
    final footerH = hasFooter
        ? layoutChild(_footer, BoxConstraints.tightFor(width: width)).height
        : 0.0;
    if (hasFooter) {
      positionChild(_footer, Offset(0, size.height - footerH));
    }
    final bottom = hasFooter ? size.height - footerH : size.height;
    layoutChild(
      _body,
      BoxConstraints.tight(Size(width, (bottom - headerH).clamp(0.0, 9e9))),
    );
    positionChild(_body, Offset(0, headerH));
  }

  @override
  bool shouldRelayout(_PinnedChromeLayout oldDelegate) => false;
}

class _PanelBodyState extends State<PanelBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  /// The size-progress tween for the CURRENT phase (grow or collapse),
  /// rebuilt on every phase flip with the running v as its begin — an
  /// interrupted phase continues from where it is instead of jumping.
  Animatable<double> _vTween = Tween<double>(
    begin: 0,
    end: 1,
  ).chain(CurveTween(curve: SrMotion.curveEmphasized));

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: SrMotion.grow)
      ..forward();
  }

  @override
  void didUpdateWidget(PanelBody old) {
    super.didUpdateWidget(old);
    if (widget.exiting == old.exiting) return;
    _retarget(growing: !widget.exiting);
    _ctrl.forward(from: 0);
  }

  /// Swap the phase, keeping v continuous: the new tween starts from
  /// the v the old one is currently showing.
  void _retarget({required bool growing}) {
    final v0 = _vTween.transform(_ctrl.value);
    // Both phases ride the SAME emphasized curve; the collapse only
    // swaps the tween's ends — v = v0·(1 − C(u)), the same-direction
    // profile. (Chaining an inverted curve onto a v0→0 tween would
    // evaluate v0·C(u): the card would never shrink.)
    _vTween = growing
        ? Tween<double>(
            begin: v0,
            end: 1,
          ).chain(CurveTween(curve: SrMotion.curveEmphasized))
        : Tween<double>(
            begin: v0,
            end: 0,
          ).chain(CurveTween(curve: SrMotion.curveEmphasized));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return AnimatedBuilder(
          // The grow timeline AND the quadrant form both repaint the
          // card: a switch mid-growth re-pins the blend in step.
          animation: Listenable.merge([_ctrl, widget.form]),
          builder: (context, _) {
            // The size progress: 0 = socket disc, 1 = shared footprint.
            final v = _vTween.transform(_ctrl.value);
            // The full painted card = the slot rect minus the card
            // margin on every side. The growth lerps from the disc
            // toward it PINNING THE ANCHOR CORNER: the socket arc
            // stays concentric with the ball the whole way. The pinned
            // corner blends along the form values (1 = left/up) — at
            // the disc width the placement reduces to the anchor's
            // in-slot position, so the disc is concentric at EVERY gl/
            // gu, not just the four corners.
            final full = constraints.biggest;
            final maxW = full.width - SrGeometry.cardMargin * 2;
            final maxH = full.height - SrGeometry.cardMargin * 2;
            final w = _discSide + (maxW - _discSide) * v;
            final h = _discSide + (maxH - _discSide) * v;
            final left = SrGeometry.cardMargin + (maxW - w) * widget.form.gl;
            final top = SrGeometry.cardMargin + (maxH - h) * widget.form.gu;
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fromRect(
                  rect: Rect.fromLTWH(left, top, w, h),
                  child: Opacity(
                    key: const Key('panel-card-ink'),
                    // The fade rides the growth's own timeline: the
                    // ring around the ball is solid by 80% of the size
                    // progress — never a fade-then-grow (环先实).
                    opacity: (v / _ringSolidAt).clamp(0.0, 1.0),
                    child: DecoratedBox(
                      key: const Key('panel-card'),
                      decoration: BoxDecoration(
                        // Solid surfaces by design (materials spike: no
                        // acrylic bet — spec §6).
                        color: pal.surface,
                        borderRadius: BorderRadius.circular(SrRadius.panel),
                        border: Border.all(color: pal.hairline),
                        // No drop shadow: the card sits inside the
                        // window, so any blur is sliced by the window
                        // rectangle and reads as a dark box fringe. The
                        // window itself is the floating surface; the
                        // hairline border carries the edge.
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(SrRadius.panel),
                        child: CustomMultiChildLayout(
                          delegate: _PinnedChromeLayout(),
                          children: [
                            LayoutId(
                              id: _PinnedChromeLayout._header,
                              child: KeyedSubtree(
                                key: const Key('panel-chrome-header'),
                                child: widget.header,
                              ),
                            ),
                            LayoutId(
                              id: _PinnedChromeLayout._body,
                              child: widget.body,
                            ),
                            if (widget.footer != null)
                              LayoutId(
                                id: _PinnedChromeLayout._footer,
                                child: KeyedSubtree(
                                  key: const Key('panel-chrome-footer'),
                                  child: widget.footer!,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
