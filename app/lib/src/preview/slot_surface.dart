/// The self-drawn editing surface family (ticket 22): one surface for the
/// session panel's text region across all its phases — the read-only
/// stream (listening / rectifying, sentinels as number capsules, ticket
/// 21's rendering) and the editable preview (sentinels as full fill
/// capsules over the slot model, tickets 19/20).
///
/// The preview surface is deliberately NOT a TextField: the dual dock
/// points (每个跨度边界两个停靠点,槽内/槽外;08 号票) have no
/// representation in a flat controller offset. Instead the surface owns
/// the whole pipeline:
///
/// - **Layout**: the document's flat projection (skeleton + chip
///   placeholder + values, [SlotProjection]) is laid out by a Text.rich
///   whose chip placeholders are WidgetSpans — the placeholder's two
///   edges ARE the dual dock points in flat space. Two CustomPainters
///   share the paragraph's geometry: one behind (capsule pills,
///   selection), one above (caret, composing underline, hover tooltip).
/// - **Keys**: arrows walk stops, Backspace/Delete pass through the
///   capsule edges, Enter inserts a newline (槽内 Enter 是换行 — the
///   field's chat-input confirm is retired by this surface), Ctrl+Z/Y
///   ride the document's single undo stack, clipboard ops yield the
///   visible characters only (身份不出预览).
/// - **IME**: the surface is its own [TextInputClient]. Composing
///   (pre-edit) text is an overlay spliced into the paragraph and the
///   platform shadow — over the live selection, because the engine
///   deletes the selection and composes at its start
///   (text_input_model.cc) — never the slot model; a commit lands as one
///   atomic [SlotEditor.insert] that replaces that selection — one undo
///   step per composition, not per
///   keystroke. Platform specifics: on Windows the framework handles the
///   editing keys, so this surface consumes them and mutates the model
///   itself; printable text arrives via updateEditingValue only (never
///   from key events).
///
/// Visual rules come from ticket 08's five rounds: the all-flat capsule
/// family (no borders or shadows; the active capsule's stroke fades
/// in/out), the number absolutely positioned in the left cap circle
/// (drawn as the chip placeholder — not selectable, not copyable), the
/// selection height never above the capsule, the pill vertically centered
/// on its line's ink box, and the empty capsule one character narrower
/// than a single character fills it (删空只缩短不消失).

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, RenderParagraph;
import 'package:flutter/services.dart';

import '../design/tokens.dart';
import '../session/pin_capsule.dart' show sentinelSpans;
import 'slot_editor.dart';
import 'slot_projection.dart';

/// Which face of the surface family the panel is showing.
enum SlotSurfaceMode {
  /// Listening / rectifying: read-only stream, sentinels as number
  /// capsules (ticket 21's accepted rendering, unchanged).
  stream,

  /// The editable preview over the slot document.
  preview,
}

class SlotSurface extends StatefulWidget {
  const SlotSurface({
    super.key,
    required this.mode,
    this.text,
    this.streamStyle,
    this.editor,
    this.focusNode,
    this.scrollController,
    this.resetToken = 0,
    this.onChanged,
  });

  final SlotSurfaceMode mode;

  /// The stream text (stream mode only): live transcript or the
  /// accumulating rectify chunks, sentinels included.
  final String? text;

  /// The stream branch's text style (stream mode only): the panel paints
  /// listening dimmer than rectifying.
  final TextStyle? streamStyle;

  /// The editing model (preview mode only). One editor serves one preview
  /// round; the panel remounts the surface (fresh key) per round.
  final SlotEditor? editor;

  /// The keyboard owner (preview mode): the panel's focus node, requested
  /// on preview entry.
  final FocusNode? focusNode;

  /// The panel's scroll controller: the stream branch attaches it (jump
  /// to bottom on updates), the preview branch scrolls to keep the caret
  /// revealed.
  final ScrollController? scrollController;

  /// Fired after every model change (preview mode), carrying the
  /// substituted confirm text — what the panel adopts as the on-screen
  /// preview text.
  final ValueChanged<String>? onChanged;

  /// The preview round this mount serves (preview mode only): a new
  /// round bumps it and the surface resets its ephemeral state — the
  /// IME connection, the composing overlay, the hover — without
  /// unmounting, so the widget's key (the tests' and the panel's anchor)
  /// stays stable across rounds.
  final int resetToken;

  @override
  State<SlotSurface> createState() => SlotSurfaceState();
}

class SlotSurfaceState extends State<SlotSurface>
    with TickerProviderStateMixin
    implements TextInputClient {
  // -- component constants (chip/pill geometry; not design tokens, the
  //    capsule family's own numbers like PinNumberCapsule.size) ----------

  /// Capsule height: the pill's diameter at the caps; also the caret's
  /// uniform height and the ceiling for the selection boxes.
  static const double capsuleHeight = 22.0;

  /// The number chip's cap circle diameter (the left cap).
  static const double chipCircle = 22.0;

  /// Breathing room between the chip and the value's first character.
  static const double chipGap = 4.0;

  /// The pill's right padding — also the empty capsule's cursor parking
  /// space (空胶囊右侧留空位作光标落点;08 号票).
  static const double pillRightPad = 6.0;

  /// Selection boxes never reach the capsule's full height.
  static const double selectionHeight = 20.0;

  static const double caretWidth = 2.5;

  final GlobalKey _paragraphKey = GlobalKey();

  // The preview editor state; stream mode uses none of these.
  SlotEditor get _editor => widget.editor!;

  /// The editing model — also the tests' observation seam.
  SlotEditor get editor => _editor;
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);
  late final AnimationController _activeFade = AnimationController(
    vsync: this,
    duration: SrMotion.fade,
  );
  TextInputConnection? _connection;
  TextEditingValue _shadow = TextEditingValue.empty;

  /// The IME pre-edit text at the caret — an overlay, never model text.
  String _composing = '';

  /// The capsule under the hover (tooltip carrier) and its reveal timer.
  int? _hoverId;
  int? _tooltipId;
  Timer? _tooltipTimer;

  bool get _isPreview => widget.mode == SlotSurfaceMode.preview;

  /// The view the connection targets. The engine rejects setClient
  /// without an integer viewId — without it no platform text model
  /// exists and typed characters are silently dropped (the 22 号
  /// acceptance-round finding).
  int? _viewId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newViewId = View.of(context).viewId;
    if (_isPreview && newViewId != _viewId) {
      _viewId = newViewId;
      // The live connection's config names the old view; re-open under
      // the current one.
      if (widget.focusNode?.hasFocus ?? false) _openConnection();
    }
  }

  @override
  void initState() {
    super.initState();
    if (_isPreview) {
      widget.focusNode?.addListener(_onFocusChanged);
      // Opening waits for didChangeDependencies: the view id the engine
      // demands is only resolvable there.
    }
  }

  @override
  void didUpdateWidget(SlotSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isPreview) {
      // The stream keeps itself pinned to the newest line.
      if (widget.text != oldWidget.text && widget.scrollController != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final scroll = widget.scrollController;
          if (scroll != null && scroll.hasClients && mounted) {
            scroll.jumpTo(scroll.position.maxScrollExtent);
          }
        });
      }
      return;
    }
    if (widget.resetToken != oldWidget.resetToken) {
      // A new preview round: the editor arrived fresh; drop everything
      // ephemeral and re-sync the platform.
      _composing = '';
      _clearTooltip();
      _hoverId = null;
      _connection?.close();
      _connection = null;
      if (widget.focusNode?.hasFocus ?? false) {
        _openConnection();
      }
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tooltipTimer?.cancel();
    if (_isPreview) {
      widget.focusNode?.removeListener(_onFocusChanged);
      _connection?.close();
    }
    _blink.dispose();
    _activeFade.dispose();
    super.dispose();
  }

  // -- model + projection access -------------------------------------------

  SlotProjection get _projection => SlotProjection(_editor.doc);

  /// The flat text the paragraph lays out: the projection with the
  /// composing run spliced over the selection (or at the caret, when
  /// collapsed) — byte-for-byte the platform's text, because the engine
  /// deletes the selection and composes at its start
  /// (text_input_model.cc).
  String get _paragraphText {
    final base = _projection.base;
    if (_composing.isEmpty) return base;
    final start = _composingCoverStartFlat;
    return base.replaceRange(start, _composingCoverEndFlat, _composing);
  }

  int get _composingPaintStart => _composingCoverStartFlat;

  int get _composingPaintEnd => _composingPaintStart + _composing.length;

  /// The flat range the composing run covers: the selection's, while one
  /// is live (that is where the engine composes), else the caret's
  /// collapsed position.
  int get _composingCoverStartFlat {
    final edges = _editor.selectionEdges;
    if (edges == null) return _caretBaseFlat;
    return math.min(
      _projection.cursorToFlat(edges.$1),
      _projection.cursorToFlat(edges.$2),
    );
  }

  int get _composingCoverEndFlat {
    final edges = _editor.selectionEdges;
    if (edges == null) return _caretBaseFlat;
    return math.max(
      _projection.cursorToFlat(edges.$1),
      _projection.cursorToFlat(edges.$2),
    );
  }

  /// The caret's base-space flat position (composing splices at it).
  int get _caretBaseFlat => _projection.cursorToFlat(_editor.caret);

  /// A base-space offset moved past the composing run — paint space.
  int _paintOf(int baseOffset) {
    if (_composing.isEmpty) return baseOffset;
    final start = _composingCoverStartFlat;
    if (baseOffset <= start) return baseOffset;
    if (baseOffset >= _composingCoverEndFlat) {
      return baseOffset + _composing.length -
          (_composingCoverEndFlat - start);
    }
    return start;
  }

  /// A paint-space offset folded back to base space; inside the composing
  /// run itself maps to the covered range's start (the model caret).
  int _baseOf(int paintOffset) {
    if (_composing.isEmpty) return paintOffset;
    final start = _composingCoverStartFlat;
    if (paintOffset <= start) return paintOffset;
    if (paintOffset >= _composingPaintEnd) {
      return paintOffset - _composing.length +
          (_composingCoverEndFlat - start);
    }
    return start;
  }

  /// The caret's paint-space flat position: while composing, the system
  /// caret rides the composing run's end (EditableText's convention).
  int get _caretPaintFlat =>
      _composing.isEmpty ? _caretBaseFlat : _composingPaintEnd;

  RenderParagraph? get _paragraph =>
      _paragraphKey.currentContext?.findRenderObject() as RenderParagraph?;

  /// The capsule under the caret — the one whose stroke fades in.
  int? get _activeId {
    final caret = _editor.caret;
    if (!caret.inside) return null;
    for (final slot in _projection.slots) {
      if (slot.bodyStart == caret.at) return slot.id;
    }
    return null;
  }

  // -- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_isPreview) return _buildStream(context);
    return _buildPreview(context);
  }

  Widget _buildStream(BuildContext context) {
    final text = widget.text ?? '';
    return SingleChildScrollView(
      controller: widget.scrollController,
      child: Text.rich(
        key: const Key('session-stream'),
        TextSpan(
          style: widget.streamStyle ?? SrType.bodyLarge,
          children: sentinelSpans(text),
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final pal = srPalette(context);
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTapDown: (details) => _tap(details.localPosition),
        onPanStart: (details) => _dragStart(details.localPosition),
        onPanUpdate: (details) => _dragUpdate(details.localPosition),
        child: MouseRegion(
          onEnter: (event) => _hover(event.localPosition),
          onHover: (event) => _hover(event.localPosition),
          onExit: (_) => _hover(null),
          child: CustomPaint(
            foregroundPainter: _ForegroundPainter(this, pal),
            painter: _BackgroundPainter(this, pal),
            child: Text.rich(
              key: _paragraphKey,
              TextSpan(
                style: SrType.bodyLarge.copyWith(color: pal.textPrimary),
                children: _spanTree(pal),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The paragraph's span tree: body runs as plain text, each capsule as
  /// its chip placeholder (WidgetSpan) followed by its value as plain
  /// text, the composing run underlined over the selection it replaces.
  List<InlineSpan> _spanTree(SrPalette pal) {
    final projection = _projection;
    final base = projection.base;
    final composing = _composing.isNotEmpty;
    final coverStart = _composingCoverStartFlat;
    final coverEnd = _composingCoverEndFlat;

    // Base segments: (start, end) runs broken at every chip boundary and
    // at the composing splice range's edges.
    final breaks = <int>{
      0,
      base.length,
      if (composing) ...[coverStart, coverEnd],
      for (final slot in projection.slots) ...[slot.chipAt, slot.chipAt + 1],
    };
    final segments = <(int, int)>[];
    final ordered = breaks.toList()..sort();
    for (var i = 0; i < ordered.length - 1; i++) {
      if (ordered[i] < ordered[i + 1]) {
        segments.add((ordered[i], ordered[i + 1]));
      }
    }

    final underline = TextStyle(
      decoration: TextDecoration.underline,
      decorationColor: pal.accent,
      decorationThickness: 1.5,
    );
    final children = <InlineSpan>[];
    var composingPending = composing;
    for (final (start, end) in segments) {
      if (start == end) continue;
      // The composing run splices ahead of the first segment at or past
      // its start — even when that segment is the chip (the caret rests
      // at the capsule's outside-left dock).
      if (composingPending && start >= coverStart) {
        children.add(TextSpan(text: _composing, style: underline));
        composingPending = false;
      }
      if (composing && start >= coverStart && end <= coverEnd) {
        continue; // covered by the composing run
      }
      final isChip = projection.slots.any(
        (s) => s.chipAt == start && end == s.chipAt + 1,
      );
      if (isChip) {
        final slot = projection.slots.firstWhere((s) => s.chipAt == start);
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _NumberChip(id: slot.id),
          ),
        );
        continue;
      }
      children.add(TextSpan(text: base.substring(start, end)));
    }
    if (composingPending) {
      children.add(TextSpan(text: _composing, style: underline));
    }
    return children;
  }

  // -- keyboard ------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed;
    final shift = keyboard.isShiftPressed;
    final result = _onKeyDown(key, ctrl, shift);
    return result;
  }

  KeyEventResult _onKeyDown(
    LogicalKeyboardKey key,
    bool ctrl,
    bool shift,
  ) {

    // While composing, the IME owns the keyboard: every editing key is
    // consumed without model action (the composition commits via
    // updateEditingValue); printables stay ignored so they feed the IME.
    if (_composing.isNotEmpty) {
      return switch (key) {
        LogicalKeyboardKey.arrowLeft ||
        LogicalKeyboardKey.arrowRight ||
        LogicalKeyboardKey.arrowUp ||
        LogicalKeyboardKey.arrowDown ||
        LogicalKeyboardKey.home ||
        LogicalKeyboardKey.end ||
        LogicalKeyboardKey.backspace ||
        LogicalKeyboardKey.delete ||
        LogicalKeyboardKey.enter ||
        LogicalKeyboardKey.numpadEnter ||
        LogicalKeyboardKey.escape => KeyEventResult.handled,
        _ => KeyEventResult.ignored,
      };
    }

    // Ctrl+Home/End fall through to the line-navigation cases, which
    // read ctrl themselves for the doc-bound variant.
    if (ctrl &&
        key != LogicalKeyboardKey.home &&
        key != LogicalKeyboardKey.end) {
      if (key == LogicalKeyboardKey.keyZ) {
        if (shift) {
          _mutate(_editor.redo);
        } else {
          _mutate(_editor.undo);
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        _mutate(_editor.redo);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyC) {
        _copy();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyX) {
        _cut();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV) {
        _paste();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyA) {
        final stops = _editor.stops;
        if (stops.isNotEmpty) _editor.select(stops.first, stops.last);
        _afterLocalChange();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        if (shift) {
          _shiftExtend(_editor.selectionEdges?.$1, backwards: true);
        } else {
          _mutate(_editor.moveLeft);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (shift) {
          _shiftExtend(_editor.selectionEdges?.$2, backwards: false);
        } else {
          _mutate(_editor.moveRight);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.arrowDown:
        // A bubbled vertical arrow would hit the app's directional
        // focus-traversal shortcuts and walk the focus off the surface,
        // so the walk is owned here.
        final up = key == LogicalKeyboardKey.arrowUp;
        final target =
            _verticalStop(up) ??
            _projection.flatToCursor(
              up
                  ? _lineStartFlat(_caretBaseFlat)
                  : _lineEndFlat(_caretBaseFlat),
              preferInside: false,
            );
        _moveTo(target, extend: shift);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        _moveTo(
          ctrl
              ? _editor.stops.first
              : _projection.flatToCursor(
                _lineStartFlat(_caretBaseFlat),
                preferInside: false,
              ),
          extend: shift,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        _moveTo(
          ctrl
              ? _editor.stops.last
              : _projection.flatToCursor(
                _lineEndFlat(_caretBaseFlat),
                preferInside: false,
              ),
          extend: shift,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.backspace:
        _mutate(_editor.backspace);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.delete:
        _mutate(_editor.deleteForward);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        // 槽内 Enter 是换行,处处一致 (08 号票: the field's chat-input
        // confirm is retired by this surface). The stage-level Enter
        // (focus outside the surface) still confirms.
        _mutate(() => _editor.insert('\n'));
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored; // printables flow through the IME
    }
  }

  /// Shift+←/→: keep the far edge, walk the near one.
  void _shiftExtend(SlotCursor? fixedEdge, {required bool backwards}) {
    final anchor = fixedEdge ?? _editor.caret;
    final stops = _editor.stops;
    final i = stops.indexOf(_editor.caret);
    final next = backwards
        ? (i > 0 ? stops[i - 1] : stops.first)
        : (i >= 0 && i < stops.length - 1 ? stops[i + 1] : stops.last);
    _editor.select(anchor, next);
    _afterLocalChange();
  }

  // -- line navigation ------------------------------------------------------
  //
  // Home/End are flat-space line bounds over the projection's base; ↑/↓
  // probe the paragraph a line's pitch above/below the caret and map the
  // hit back through the projection. Both fold through flatToCursor, so a
  // bound landing on a capsule edge resolves to its structural (outside)
  // dock — the body-side position of the line.

  int _lineStartFlat(int flat) {
    final base = _projection.base;
    final i = flat <= 0 ? -1 : base.lastIndexOf('\n', math.max(0, flat - 1));
    return i + 1;
  }

  int _lineEndFlat(int flat) {
    final base = _projection.base;
    final i = base.indexOf('\n', flat);
    return i == -1 ? base.length : i;
  }

  /// The stop a line up/down from the caret lands on, or null when the
  /// paragraph cannot be probed.
  SlotCursor? _verticalStop(bool up) {
    final paragraph = _paragraph;
    if (paragraph == null) return null;
    final position = TextPosition(offset: _caretPaintFlat);
    final caretOffset = paragraph.getOffsetForCaret(position, Rect.zero);
    // A pitch and a half from the caret's top clears the rest of this
    // line and lands mid-neighbour even when pitches differ.
    final pitch = paragraph.getFullHeightForCaret(position) * 1.5;
    final probe = Offset(
      caretOffset.dx,
      up ? caretOffset.dy - pitch : caretOffset.dy + pitch,
    );
    final target = paragraph.getPositionForOffset(probe);
    return _projection.flatToCursor(_baseOf(target.offset), preferInside: false);
  }

  /// Place the caret, or extend the selection keeping its far edge.
  void _moveTo(SlotCursor target, {required bool extend}) {
    if (extend) {
      final anchor = _editor.selectionEdges?.$1 ?? _editor.caret;
      _editor.select(anchor, target);
    } else {
      _editor.place(target);
    }
    _afterLocalChange();
  }

  void _copy() {
    final text = _editor.copy();
    if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
  }

  void _cut() {
    final text = _editor.cut();
    if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
    _afterLocalChange();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null || !mounted) return;
    final text = data!.text!;
    if (text.isNotEmpty) _mutate(() => _editor.insert(text));
  }

  // -- pointer -------------------------------------------------------------

  void _tap(Offset local) {
    final hit = _cursorAt(local);
    if (hit == null) return;
    final (cursor, capsuleId) = hit;
    if (capsuleId != null) {
      // Tap on the pill: the edit state; a non-empty value starts
      // selected for fastest replacement (点预填非空胶囊默认全选).
      final slot = _projection.slots.firstWhere((s) => s.id == capsuleId);
      final valueLength = _editor.doc.valueOf(capsuleId).length;
      if (valueLength > 0) {
        _editor.select(
          SlotCursor.inside(at: slot.bodyStart, offset: 0),
          SlotCursor.inside(at: slot.bodyStart, offset: valueLength),
        );
      } else {
        _editor.place(SlotCursor.inside(at: slot.bodyStart, offset: 0));
      }
    } else {
      _editor.place(cursor);
    }
    _afterLocalChange();
  }

  SlotCursor? _dragAnchor;

  void _dragStart(Offset local) {
    final hit = _cursorAt(local);
    if (hit == null) return;
    _dragAnchor = hit.$1;
    _editor.select(_dragAnchor!, hit.$1);
    _afterLocalChange();
  }

  void _dragUpdate(Offset local) {
    if (_dragAnchor == null) return;
    final hit = _cursorAt(local);
    if (hit == null) return;
    _editor.select(_dragAnchor!, hit.$1);
    _afterLocalChange();
  }

  void _hover(Offset? local) {
    int? id;
    if (local != null) {
      for (final entry in _capsuleSegments().entries) {
        for (final rect in entry.value) {
          if (rect.inflate(2).contains(local)) id = entry.key;
        }
      }
    }
    if (id == _hoverId) return;
    _hoverId = id;
    _clearTooltip();
    if (id != null) {
      _tooltipTimer = Timer(SrMotion.tooltipWait, () {
        if (mounted && _hoverId == id) {
          setState(() => _tooltipId = id);
        }
      });
    }
    setState(() {});
  }

  void _clearTooltip() {
    _tooltipTimer?.cancel();
    _tooltipTimer = null;
    if (_tooltipId != null) _tooltipId = null;
  }

  /// A point's stop and, when it lands on a capsule's pill, that capsule.
  (SlotCursor, int?)? _cursorAt(Offset local) {
    final paragraph = _paragraph;
    if (paragraph == null) return null;
    final projection = _projection;
    // The pill wins over the text position under it: the whole capsule is
    // the tap target, chip included.
    for (final entry in _capsuleSegments().entries) {
      for (final rect in entry.value) {
        if (rect.inflate(2).contains(local)) {
          final slot = projection.slots.firstWhere((s) => s.id == entry.key);
          final cursor = _projection.flatToCursor(
            _baseOf(paragraph.getPositionForOffset(local).offset),
            preferInside: true,
          );
          return (cursor, slot.id);
        }
      }
    }
    final flat = _baseOf(paragraph.getPositionForOffset(local).offset);
    return (projection.flatToCursor(flat, preferInside: true), null);
  }

  // -- mutation plumbing ---------------------------------------------------

  /// One user-driven model mutation: apply, then sync everything that
  /// watches the model — the platform shadow, the caret blink, the
  /// panel's substituted text, the caret's scroll reveal.
  void _mutate(VoidCallback op) {
    op();
    _afterLocalChange();
  }

  void _afterLocalChange() {
    _syncShadow();
    _blink.value = 0;
    final newActive = _activeId;
    if (newActive != _activeFadeTarget) {
      _activeFadeTarget = newActive;
      if (newActive != null) {
        _activeFade.forward();
      } else {
        _activeFade.reverse();
      }
    }
    widget.onChanged?.call(_editor.doc.substitute());
    _revealCaret();
    setState(() {});
  }

  int? _activeFadeTarget;

  // -- geometry for painters and hit tests ---------------------------------

  /// The pill rectangles per capsule identity, in paragraph-local
  /// coordinates: each wrapped line contributes one rounded segment,
  /// grown by the right padding on the last one.
  Map<int, List<Rect>> _capsuleSegments() {
    final paragraph = _paragraph;
    if (paragraph == null) return const {};
    final projection = _projection;
    final segments = <int, List<Rect>>{};
    for (final slot in projection.slots) {
      final boxes = <TextBox>[
        ...paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: _paintOf(slot.chipAt),
            extentOffset: _paintOf(slot.chipAt) + 1,
          ),
        ),
        ...paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: _paintOf(slot.valueStart),
            extentOffset: _paintOf(slot.valueEnd),
          ),
        ),
      ]..sort((a, b) => a.left.compareTo(b.left));
      final merged = <Rect>[];
      for (final box in boxes) {
        final boxCenter = box.toRect().center.dy;
        final rect = Rect.fromLTRB(
          box.left,
          boxCenter - capsuleHeight / 2,
          box.right,
          boxCenter + capsuleHeight / 2,
        );
        final sameLine =
            merged.isNotEmpty &&
            (rect.center.dy - merged.last.center.dy).abs() < 3;
        if (sameLine && rect.left - merged.last.right < 1.5) {
          final last = merged.removeLast();
          merged.add(
            Rect.fromLTRB(
              last.left,
              (last.top + rect.top) / 2,
              math.max(last.right, rect.right),
              (last.bottom + rect.bottom) / 2,
            ),
          );
        } else {
          merged.add(rect);
        }
      }
      if (merged.isEmpty) continue;
      final last = merged.removeLast();
      merged.add(
        last.expandToInclude(
          Rect.fromLTRB(
            last.left,
            last.top,
            last.right + pillRightPad,
            last.bottom,
          ),
        ),
      );
      segments[slot.id] = merged;
    }
    return segments;
  }

  /// The selection's paint-space range, or null when collapsed — and
  /// while composing: the overlay covers the selection, and the platform
  /// holds none (the model keeps it for the commit to replace).
  TextSelection? get _selectionPaintRange {
    if (_composing.isNotEmpty) return null;
    final edges = _editor.selectionEdges;
    if (edges == null) return null;
    final a = _paintOf(_projection.cursorToFlat(edges.$1));
    final b = _paintOf(_projection.cursorToFlat(edges.$2));
    return TextSelection(baseOffset: a, extentOffset: b);
  }

  /// The caret rectangle in paragraph-local coordinates (uniform capsule
  /// height, centered on its line).
  Rect? caretRect() {
    final paragraph = _paragraph;
    if (paragraph == null) return null;
    final offset = paragraph.getOffsetForCaret(
      TextPosition(offset: _caretPaintFlat),
      Rect.zero,
    );
    final line = paragraph.getFullHeightForCaret(
      TextPosition(offset: _caretPaintFlat),
    );
    final lineCenter = offset.dy + line / 2;
    return Rect.fromLTWH(
      offset.dx,
      lineCenter - capsuleHeight / 2,
      caretWidth,
      capsuleHeight,
    );
  }

  void _revealCaret() {
    final scroll = widget.scrollController;
    final paragraph = _paragraph;
    if (scroll == null || !scroll.hasClients || paragraph == null) return;
    final caret = caretRect();
    if (caret == null) return;
    final viewport = RenderAbstractViewport.maybeOf(paragraph);
    if (viewport == null) return;
    final position = scroll.position;
    final revealTop = viewport
        .getOffsetToReveal(paragraph, 0.0, rect: caret)
        .offset;
    final revealBottom = viewport
        .getOffsetToReveal(paragraph, 1.0, rect: caret)
        .offset;
    if (revealTop < position.pixels) {
      position.jumpTo(math.max(position.minScrollExtent, revealTop));
    } else if (revealBottom > position.pixels) {
      position.jumpTo(math.min(position.maxScrollExtent, revealBottom));
    }
  }

  // -- the platform text input ---------------------------------------------

  void _onFocusChanged() {
    if (widget.focusNode?.hasFocus ?? false) {
      _openConnection();
    } else {
      _connection?.close();
      _connection = null;
    }
  }

  void _openConnection() {
    _connection?.close();
    _shadow = _buildShadow();
    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        viewId: _viewId,
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
      ),
    );
    _connection!
      ..show()
      ..setEditingState(_shadow);
  }

  /// The shadow value: what the platform model holds — the paragraph text
  /// (composing included) with the editor's selection at paint offsets.
  /// While composing, the selection rides the composing run's end, the
  /// platform's own convention (text_input_model.cc).
  TextEditingValue _buildShadow() {
    final edges = _editor.selectionEdges;
    final int base;
    final int extent;
    if (_composing.isNotEmpty) {
      base = extent = _composingPaintEnd;
    } else if (edges == null) {
      base = extent = _caretPaintFlat;
    } else {
      base = _paintOf(_projection.cursorToFlat(edges.$1));
      extent = _paintOf(_projection.cursorToFlat(edges.$2));
    }
    return TextEditingValue(
      text: _paragraphText,
      selection: TextSelection(baseOffset: base, extentOffset: extent),
      composing: _composing.isEmpty
          ? TextRange.empty
          : TextRange(start: _composingPaintStart, end: _composingPaintEnd),
    );
  }

  /// Push the local state to the platform after a local mutation. Never
  /// while composing: rewriting the editing state mid-composition breaks
  /// the IME, and a composition leaves no local mutations (the keys are
  /// consumed).
  void _syncShadow() {
    if (_composing.isNotEmpty) return;
    _shadow = _buildShadow();
    _connection?.setEditingState(_shadow);
    _reportCaretGeometry();
  }

  /// Tell the IME where the caret sits, so the candidate window homes to
  /// it (EditableText does the same after every caret move).
  void _reportCaretGeometry() {
    final paragraph = _paragraph;
    final connection = _connection;
    if (paragraph == null || connection == null || !connection.attached) {
      return;
    }
    final transform = paragraph.getTransformTo(null);
    connection.setEditableSizeAndTransform(paragraph.size, transform);
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    // The new pre-edit run, exactly as the platform holds it.
    final composingRange = value.composing;
    final newComposing = composingRange.isValid && !composingRange.isCollapsed
        ? value.text.substring(composingRange.start, composingRange.end)
        : '';
    final previousComposing = _shadow.composing;
    final hadComposing =
        previousComposing.isValid && !previousComposing.isCollapsed;

    if (_shadow.text.isEmpty) {
      // No shadow was ever pushed (a race with the connection): adopt the
      // platform state without touching the model.
      _composing = newComposing;
      _shadow = value;
      setState(() {});
      return;
    }

    // Everything outside the composing windows must be the projection
    // plus committed insertions; diff the two bases to find them. Each
    // side's window is stripped at the PLATFORM's own indices: the
    // engine composes over the selection at its start
    // (text_input_model.cc deletes the selection on the first compose
    // change), a position none of our own state describes.
    final newBase = newComposing.isEmpty
        ? value.text
        : value.text.replaceRange(composingRange.start, composingRange.end, '');
    final oldBase = hadComposing
        ? _shadow.text.replaceRange(previousComposing.start, previousComposing.end, '')
        : _shadow.text;

    var prefix = 0;
    while (prefix < oldBase.length &&
        prefix < newBase.length &&
        oldBase[prefix] == newBase[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < oldBase.length - prefix &&
        suffix < newBase.length - prefix &&
        oldBase[oldBase.length - 1 - suffix] ==
            newBase[newBase.length - 1 - suffix]) {
      suffix++;
    }
    final inserted = newBase.substring(prefix, newBase.length - suffix);

    if (inserted.isNotEmpty) {
      // A commit or a plain keystroke: one atomic model insert (one undo
      // step, 值与骨架同栈). Over a composition the editor's still-live
      // selection is what was being composed over — inserting replaces
      // it, which lands the replacement the IME committed.
      _editor.insert(inserted);
    }
    // A shrunk middle with nothing inserted is the compose-start deletion
    // of the selection: the model keeps it and the composing overlay
    // covers it until the commit (or the cancel) arrives.
    _composing = newComposing;
    _shadow = value;

    _blink.value = 0;
    widget.onChanged?.call(_editor.doc.substitute());
    _revealCaret();
    setState(() {});
  }

  @override
  void performAction(TextInputAction action) {
    // Newlines arrive as model inserts (the key handler) or committed
    // text (the Windows plugin adds '\n' to the editing state before
    // this action); there is nothing to do here. Multiline fields never
    // finalize on actions.
  }

  @override
  void connectionClosed() {
    _connection = null;
    if (widget.focusNode?.hasFocus ?? false) _openConnection();
  }

  @override
  TextEditingValue? get currentTextEditingValue => _shadow;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  // The desktop-multiline surface takes no part in the mobile/IME
  // affordances; the defaults it would inherit through `with` are spelled
  // out because this class *implements* the client interface.
  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  bool onFocusReceived() => false;

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void showToolbar() {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void performSelector(String selectorName) {}

  // -- test observation ----------------------------------------------------

  /// The projection's base text (no composing run) — what the tests read
  /// as the surface's content.
  String get flatBaseText => _projection.base;

  /// The text the paragraph actually lays out — the projection with the
  /// composing run spliced over the selection. While composing over a
  /// selection this must equal the platform's text: the engine deletes
  /// the selection and composes at its start (text_input_model.cc).
  String get paintedTextForTest => _paragraphText;

  /// The composing overlay currently in flight.
  String get composingText => _composing;

  /// The capsule identities in body order.
  List<int> get capsuleIds => [for (final slot in _projection.slots) slot.id];

  /// The identity whose stroke is fading in (the edited capsule).
  int? get activeSlotId => _activeId;

  /// The identity under the hover.
  int? get hoverSlotId => _hoverId;

  /// The identity whose prefill tooltip has revealed (past the hover
  /// wait).
  int? get tooltipSlotId => _tooltipId;

  /// The pill rectangles per identity — the tests' geometry seam.
  Map<int, List<Rect>> capsuleSegmentsForTest() => _capsuleSegments();
}

// ---------------------------------------------------------------------------
// painters
// ---------------------------------------------------------------------------

/// Paints under the text: the capsule pills (flat family: fill only) and
/// the selection (height-clamped, never above the capsule).
class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter(this.state, this.pal)
    : super(repaint: Listenable.merge([state._blink, state._activeFade]));

  final SlotSurfaceState state;
  final SrPalette pal;

  @override
  void paint(Canvas canvas, Size size) {
    final segments = state._capsuleSegments();
    // Pills first: the selection may tint over them, never under.
    for (final entry in segments.entries) {
      final list = entry.value;
      for (var i = 0; i < list.length; i++) {
        final first = i == 0;
        final last = i == list.length - 1;
        final radius = SlotSurfaceState.capsuleHeight / 2;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            list[i],
            topLeft: first ? Radius.circular(radius) : Radius.zero,
            bottomLeft: first ? Radius.circular(radius) : Radius.zero,
            topRight: last ? Radius.circular(radius) : Radius.zero,
            bottomRight: last ? Radius.circular(radius) : Radius.zero,
          ),
          Paint()..color = pal.accentSoft,
        );
      }
    }
    // The active capsule's stroke, fading in and out (点按 = 选中编辑态).
    final active = state._activeId;
    if (active != null && state._activeFade.value > 0) {
      for (final rect in segments[active] ?? const <Rect>[]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect.inflate(0.5),
            Radius.circular(SlotSurfaceState.capsuleHeight / 2),
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = pal.accent.withValues(
              alpha: 0.8 * state._activeFade.value,
            ),
        );
      }
    }
    // Selection over the pills, clamped below the capsule height.
    final selection = state._selectionPaintRange;
    if (selection != null) {
      final paragraph = state._paragraph;
      if (paragraph != null) {
        for (final box in paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: selection.baseOffset,
            extentOffset: selection.extentOffset,
          ),
        )) {
          final center = box.toRect().center.dy;
          final rect = Rect.fromLTRB(
            box.left,
            center - SlotSurfaceState.selectionHeight / 2,
            box.right,
            center + SlotSurfaceState.selectionHeight / 2,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(3)),
            Paint()..color = pal.accent.withValues(alpha: 0.25),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => true;
}

/// Paints over the text: the blinking caret, the composing underline, and
/// the prefill hover tooltip.
class _ForegroundPainter extends CustomPainter {
  _ForegroundPainter(this.state, this.pal)
    : super(repaint: Listenable.merge([state._blink, state._activeFade]));

  final SlotSurfaceState state;
  final SrPalette pal;

  @override
  void paint(Canvas canvas, Size size) {
    // Composing underline.
    if (state.composingText.isNotEmpty) {
      final paragraph = state._paragraph;
      if (paragraph != null) {
        for (final box in paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: state._composingPaintStart,
            extentOffset: state._composingPaintEnd,
          ),
        )) {
          final paint = Paint()
            ..color = pal.accent
            ..strokeWidth = 1.5;
          canvas.drawLine(
            Offset(box.left, box.bottom + 1),
            Offset(box.right, box.bottom + 1),
            paint,
          );
        }
      }
    }
    // Caret: shown while focused, blinking.
    final focused = state.widget.focusNode?.hasFocus ?? false;
    if (focused && state._blink.value < 0.5) {
      final caret = state.caretRect();
      if (caret != null) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            caret,
            const Radius.circular(SlotSurfaceState.caretWidth / 2),
          ),
          Paint()..color = pal.accent,
        );
      }
    }
    // Prefill tooltip: the prefill has no visual mark but the hover.
    final tooltip = state._tooltipId;
    if (tooltip != null) {
      final segments = state._capsuleSegments()[tooltip];
      if (segments != null && segments.isNotEmpty) {
        final prefill = state._editor.doc.prefillOf(tooltip);
        final label = prefill.isEmpty ? '预填为空' : '预填:$prefill';
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: SrType.micro.copyWith(color: pal.textSecondary),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final card = Rect.fromLTWH(0, 0, tp.width + 12, tp.height + 8);
        final anchor = segments.first;
        var origin = Offset(
          (anchor.center.dx - card.width / 2).clamp(0, size.width - card.width),
          anchor.top - card.height - 4,
        );
        if (origin.dy < 0) origin = Offset(origin.dx, anchor.bottom + 4);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            card.shift(origin),
            Radius.circular(SrRadius.control),
          ),
          Paint()..color = pal.surfaceRaised,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            card.shift(origin),
            Radius.circular(SrRadius.control),
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = pal.hairline,
        );
        tp.paint(canvas, origin + const Offset(6, 4));
      }
    }
  }

  @override
  bool shouldRepaint(_ForegroundPainter old) => true;
}

/// The capsule's number chip: the pill's left cap circle carrying the
/// digits (号数绝对定位于左端切圆圆心的普通小字 — the circle itself is
/// painted by the pill layer; this widget is only the digits and the
/// horizontal space the cap occupies in the line). Fixed size, so the
/// WidgetSpan never stretches to the bounded paragraph width (the 21 号
/// regression).
class _NumberChip extends StatelessWidget {
  const _NumberChip({required this.id});

  final int id;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SizedBox(
      width: SlotSurfaceState.chipCircle + SlotSurfaceState.chipGap,
      height: SlotSurfaceState.capsuleHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: SlotSurfaceState.chipCircle,
            height: SlotSurfaceState.capsuleHeight,
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                '$id',
                style: SrType.micro.copyWith(color: pal.accentText, height: 1),
              ),
            ),
          ),
          const SizedBox(width: SlotSurfaceState.chipGap),
        ],
      ),
    );
  }
}
