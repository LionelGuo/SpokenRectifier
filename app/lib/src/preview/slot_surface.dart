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
/// (painted by the foreground layer onto the pill's cap — not part of the
/// text, not selectable, not copyable), the selection height never above
/// the capsule, the pill vertically centered on a content-independent
/// anchor — the strut-locked caret line center plus the paragraph's own
/// ink-vs-caret bias (never the line's ink union: that rode the fonts
/// its runs resolved and re-seated as content landed, 停车场 05) — every
/// anchor eased down by SrCapsule.opticalEase, since the typographic
/// box's center rides slightly above the glyphs' true ink, the capsule's
/// horizontal margins reserved in layout (the chip's leading spacer and
/// the per-slot reservation placeholder), and the empty capsule one
/// character narrower than a single character fills it (删空只缩短不消失).
/// A capsule spanning several lines reads as one band across the column:
/// the first segment runs to the column's right edge, interior lines take
/// the full width, the last is flush left past its content — empty value
/// lines included (首行抵右、中行全宽、末行贴左; 23 号验收轮 D3). Every
/// covered line renders as its own band, every band the capsule's own
/// height on its line — except a covered line
/// the capsule's own boxes do not hold, which joins the capsule only
/// when the value hard-continues onto it: a line holding nothing but
/// the wrapped reservation placeholder renders no band at all (one
/// complete pill on the glyph line). An end the wrapper or a newline
/// CUT renders square, and the text beside a cut sits flush against the
/// column's edge exactly like ordinary text — no parking, no clearance;
/// only the capsule's NATURAL ends (the chip's left cap, the value's own
/// end) keep the pill's rounded caps (截断直角、文字贴边; D3 反馈五终
/// 裁, superseding the earlier complete-pill rule) — and a cut end's ink
/// dissolves to nothing approaching it, so the square edge never reads
/// as a drawn edge (截断端渐隐; D3 反馈八). The breathing is CONSTANT
/// at every edge (2026-09-10 反馈十六 re-ruling, retiring the line-edge
/// swallows of 反馈四②/十三): the pill always sits on its reserved
/// sidePad, at a line's start and end like anywhere else, so its
/// placement, its width and the number-to-value distance never depend
/// on what the neighbours or the line's edges hold — and the
/// sidePad-wide background strips flanking every pill stay clickable,
/// carrying the outside docks (愿望三: a position the caret can reach
/// must be clickable).
/// Every line — ink-less ones (placeholders only) included — anchors its
/// chrome on the strut-locked caret line center plus the paragraph's
/// own ink-vs-caret bias, never on a placeholder's own middle alignment
/// (反馈十二: that rides font metrics and re-seats when the first glyph
/// lands; 停车场 05 extended the anchor to ink-holding lines alike, so a
/// capsule's seat never depends on what its line happens to contain).
/// The caret binds to the line its text sits on WHILE it trails an
/// insertion tail (typing, IME composition, paste): at a soft-wrap
/// boundary the framework's default downstream affinity would paint it
/// at the next line's start even though the next typed character still
/// lands on the current line (the wrapper breaks at the next
/// unbreakable unit, not at the caret's own character), so the surface
/// renders such positions upstream, at the current line's end — the
/// caret moves down only when the text itself moves. The moment the
/// caret travels on its own (navigation, click, undo), the downstream
/// binding returns — Home onto a wrapped line's start renders at that
/// line's start — and right after a hard newline downstream is the
/// correct binding anyway (D3 反馈六, 2026-09-09 ruling).
/// The capsule's trailing reservation is FITTED to its line's own
/// leftover (停车场 04, 2026-09-12): a reservation placeholder is
/// unbreakable, and when the capsule's value ends within one
/// reservation's width of the column's right edge it used to wrap
/// itself — leading the next line and indenting the content that
/// follows the capsule by its width (真机: 后续内容不顶格, 空出一段
/// 距离). Every span tree's reservation widths now come from a measured
/// pre-pass; a would-wrap reservation takes exactly the leftover
/// advance its line still holds, so it stays on the capsule's line (the
/// pill paints its own parking tail past the value regardless) and the
/// content that wraps anyway starts flush at x=0, its seat never ruled
/// by the capsule above.

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, RenderParagraph;
import 'package:flutter/services.dart';

import '../design/tokens.dart';
import '../session/pin_capsule.dart'
    show StreamMarkers, pinCapsuleReservation, pinCapsuleWidth, projectStream;
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
  // -- component constants (the capsule family's numbers live in the
  //    design table — SrCapsule, mirrored into the prototype tokens; the
  //    local names keep the use sites and the tests stable) --------------

  /// Capsule height: the pill's diameter at the caps; also the caret's
  /// uniform height and the ceiling for the selection boxes.
  static const double capsuleHeight = SrCapsule.height;

  /// The number chip's cap circle diameter (the left cap).
  static const double chipCircle = SrCapsule.chipCircle;

  /// Breathing room between the chip and the value's first character.
  static const double chipGap = SrCapsule.chipGap;

  /// The pill's right padding — also the empty capsule's cursor parking
  /// space (空胶囊右侧留空位作光标落点;08 号票).
  static const double pillRightPad = SrCapsule.valuePad;

  /// Breathing room between the pill's caps and the neighbouring text,
  /// reserved in layout (the chip's leading spacer and the reservation
  /// placeholder's tail beyond the pill's right cap).
  static const double capsuleSidePad = SrCapsule.sidePad;

  /// Selection boxes never reach the capsule's full height.
  static const double selectionHeight = SrCapsule.selectionHeight;

  static const double caretWidth = SrCapsule.caretWidth;

  /// The empty tail line's parking-stub floor — the value the last
  /// band's right edge never sits below (反馈十八修复二: the reservation's
  /// own width plus the look-tuned pixels that walk the cap start right
  /// of the dissolve; the real GPU lost the fill's lower-left crescent
  /// at the near-degenerate cap-radius width). The reservation riding an
  /// EMPTY tail line widens past it by [capsuleSidePad] (反馈十九, F23
  /// round): the text typed right after the capsule keeps its breathing,
  /// and the pill always ends inside the layout space it owns.
  double get _stubFloor => pillRightPad + capsuleSidePad + 2;

  /// The chrome anchor's downward nudge in px — [SrCapsule.opticalEase]
  /// of the face's font size. The line ink box is a TYPOGRAPHIC box
  /// (font ascent/descent); its center rides ~0.5–1px above the glyphs'
  /// true ink center on the real resolution fonts, which read as the
  /// pill sitting high over its text. The ease lands the dominant fonts
  /// at even-to-slightly-high — never fill-below-wider.
  double get _opticalEasePx =>
      SrCapsule.opticalEase *
      (_isPreview
          ? SrType.bodyLarge.fontSize!
          : (widget.streamStyle ?? SrType.bodyLarge).fontSize!);

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

  /// Stream mode: the paragraph's context (the Builder inside the scroll
  /// view) — the circle painter's and the tests' way to the
  /// RenderParagraph.
  BuildContext? _streamParagraph;

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
      _fitVerified = const {};
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

  /// A base-space offset moved past the composing run — paint space, at
  /// its seat semantics: an offset AT the run's start maps to the start
  /// itself (the run begins there), which is what a range START and a
  /// caret seat want.
  int _paintOf(int baseOffset) {
    if (_composing.isEmpty) return baseOffset;
    final start = _composingCoverStartFlat;
    if (baseOffset <= start) return baseOffset;
    if (baseOffset >= _composingCoverEndFlat) {
      return baseOffset + _composing.length - (_composingCoverEndFlat - start);
    }
    return start;
  }

  /// A base-space RANGE END moved past the composing run — the one
  /// boundary that differs from a start: when a COLLAPSED window sits at
  /// the value's end dock (start == end == valueEnd — typing pinyin at
  /// the value's end, or into an empty capsule), the end EXTENDS past
  /// the run so the pill's measuring range swallows the composing
  /// letters. Un-extended it cut the range at the value's edge and the
  /// pill never grew over the composition (反馈二十: IME 组合不增长胶囊
  /// 长度, 末尾超出胶囊; the selected-value compose path never touches
  /// the boundary, which is why F16's replay never caught it).
  int _paintOfEnd(int baseOffset) {
    if (_composing.isEmpty) return baseOffset;
    final start = _composingCoverStartFlat;
    if (baseOffset < start) return baseOffset;
    if (baseOffset >= _composingCoverEndFlat) {
      return baseOffset + _composing.length - (_composingCoverEndFlat - start);
    }
    return start;
  }

  /// A base-space CONTENT offset — a placeholder whose laid-out box the
  /// geometry queries — moved to paint space: content at the composing
  /// point shifts PAST the run, the way a range END does. The seat maps
  /// ([_paintOf]) pin an offset AT the run's start to the start itself —
  /// the caret's seat — so a composition growing at the capsule's
  /// outside-left dock kept querying the chip at the run's first letter
  /// and the whole capsule chrome stayed pinned over the composing text
  /// instead of being pushed right (真机 05: 组合不把胶囊往右推). Seat
  /// consumers (selection, shadow, caret, the value's own range) are
  /// unchanged; only content probes take this map.
  int _paintContentOf(int baseOffset) {
    if (_composing.isEmpty) return baseOffset;
    if (baseOffset < _composingCoverStartFlat) return baseOffset;
    return _paintOfEnd(baseOffset);
  }

  /// A paint-space offset folded back to base space; inside the composing
  /// run itself maps to the covered range's start (the model caret).
  int _baseOf(int paintOffset) {
    if (_composing.isEmpty) return paintOffset;
    final start = _composingCoverStartFlat;
    if (paintOffset <= start) return paintOffset;
    if (paintOffset >= _composingPaintEnd) {
      return paintOffset - _composing.length + (_composingCoverEndFlat - start);
    }
    return start;
  }

  /// The caret's paint-space flat position: while composing, the system
  /// caret rides the composing run's end (EditableText's convention).
  int get _caretPaintFlat =>
      _composing.isEmpty ? _caretBaseFlat : _composingPaintEnd;

  /// The caret's render position. 反馈六: while the caret trails an
  /// edit tail — text grew and the caret sits at its end (typing, IME
  /// composition, paste) — a soft-wrap boundary renders UPSTREAM, at
  /// the current line's end: the framework's default downstream affinity
  /// paints it at the NEXT line's start even though the next typed
  /// character still lands on the current line (the wrapper breaks at
  /// the next unbreakable unit, not at the caret's own character). A
  /// deletion tail follows the same rule (F1 feedback, 2026-09-10: the
  /// backspace that eats the line's last glyph leaves the caret seated
  /// at the next line's start on engines that seat the boundary there) —
  /// and so does an undo returning to an edit's start, arriving at the
  /// junction with the text it trails. The moment the caret travels on
  /// its own (navigation, click — offset moved with no length change),
  /// the downstream binding returns: Home onto a wrapped line's start
  /// keeps rendering at that line's start. Right after a hard newline
  /// downstream is correct anyway: the position belongs to the new line.
  int? _affinityKeyFlat;
  int? _affinityKeyLen;
  bool _affinityUpstream = false;

  TextPosition _caretRenderPosition(RenderParagraph paragraph) {
    final offset = _caretPaintFlat;
    final text = _paragraphText;
    final downstream = TextPosition(offset: offset);
    if (offset == 0 || text.codeUnitAt(offset - 1) == 0x0A) {
      _affinityKeyFlat = offset;
      _affinityKeyLen = text.length;
      _affinityUpstream = false;
      return downstream;
    }
    if (offset != _affinityKeyFlat || text.length != _affinityKeyLen) {
      final growth = text.length - (_affinityKeyLen ?? text.length);
      _affinityUpstream =
          growth != 0 && offset == (_affinityKeyFlat ?? offset) + growth;
      _affinityKeyFlat = offset;
      _affinityKeyLen = text.length;
    }
    if (!_affinityUpstream) return downstream;
    // Upstream stands even when the engine seats BOTH affinities at the
    // next line's start — a boundary before a wrapped inline placeholder
    // cannot split it, so upstream collapses to the placeholder's left
    // edge on the next line (the real engine does this; flutter_tester
    // does not). [caretRect] parks such a caret at the preceding
    // glyph's right edge, on the glyph's own line (反馈十五②).
    return TextPosition(offset: offset, affinity: TextAffinity.upstream);
  }

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
    final pal = srPalette(context);
    final style = widget.streamStyle ?? SrType.bodyLarge;
    final markers = projectStream(text);
    // The strut pins every line to the style's own metrics: line
    // heights never vary with what a line happens to contain (mixed
    // fallback runs, IME composing runs), so lines — and the capsules
    // anchored to them — never shift as content changes (23 号验收轮:
    // typing a character visibly re-seated the lines).
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    return SingleChildScrollView(
      controller: widget.scrollController,
      child: CustomPaint(
        painter: _StreamPillPainter(this, pal),
        foregroundPainter: _StreamCapsulesPainter(this, pal),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final measured = fittedReservationWidths(
              maxWidth: constraints.maxWidth,
              ambientStyle: DefaultTextStyle.of(context).style,
              style: style,
              strut: strut,
              textScaler: MediaQuery.textScalerOf(context),
              locale: Localizations.maybeLocaleOf(context),
              standardWidth: pillRightPad + capsuleSidePad,
              slots: markers.capsules,
              valueEndsWithNewline: (slot) => markers.flat
                  .substring(slot.valueStart, slot.valueEnd)
                  .endsWith('\n'),
              buildSpans: (widths) => _streamSpanTree(markers, widths),
            );
            final widths = {...measured, ..._fitVerified};
            if (markers.capsules.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _verifyReservationFits(),
              );
            }
            return Builder(
              builder: (paragraphContext) {
                _streamParagraph = paragraphContext;
                return Text.rich(
                  key: const Key('session-stream'),
                  strutStyle: strut,
                  TextSpan(
                    style: style,
                    children: _streamSpanTree(markers, widths),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// The stream paragraph's span tree over its flat projection: body
  /// runs as plain text, every bare sentinel as its circle spacer, every
  /// inline form as chip spacer + value + reservation spacer — the same
  /// three-part shape the preview's capsules lay out as, so the capsule
  /// the stream grows becomes the preview's capsule without re-seating
  /// (29 号票; the value is real text, the growing thing itself). The
  /// reservation riding a value that ends with 回车 widens past the
  /// parking stub by sidePad exactly as the preview's does (反馈十九) —
  /// whatever streams in after it keeps its breathing.
  List<InlineSpan> _streamSpanTree(
    StreamMarkers markers,
    Map<int, double> reservationWidths,
  ) {
    final flat = markers.flat;
    final circleAt = {for (final circle in markers.circles) circle.at: circle};
    final chipAt = {for (final slot in markers.capsules) slot.chipAt: slot};
    final reservationAt = {
      for (final slot in markers.capsules) slot.valueEnd: slot,
    };
    final valueOf = {
      for (final slot in markers.capsules)
        slot.id: flat.substring(slot.valueStart, slot.valueEnd),
    };
    final children = <InlineSpan>[];
    var runStart = 0;
    for (var i = 0; i < flat.length; i++) {
      if (flat.codeUnitAt(i) != 0xFFFC) continue;
      final circle = circleAt[i];
      final chip = chipAt[i];
      final reservation = reservationAt[i];
      if (circle == null && chip == null && reservation == null) {
        continue; // a stray placeholder glyph inside a value: text
      }
      if (i > runStart) {
        children.add(TextSpan(text: flat.substring(runStart, i)));
      }
      if (circle != null) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              key: ValueKey('pin-capsule-${circle.id}'),
              width: pinCapsuleReservation(circle.id),
              height: capsuleHeight,
            ),
          ),
        );
      } else if (chip != null) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              key: ValueKey('pin-capsule-${chip.id}'),
              width: capsuleSidePad + chipCircle + chipGap,
              height: capsuleHeight,
            ),
          ),
        );
      } else {
        final slot = reservation!;
        final emptyTail = (valueOf[slot.id] ?? '').endsWith('\n');
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              width:
                  reservationWidths[slot.id] ??
                  (emptyTail
                      ? _stubFloor + capsuleSidePad
                      : pillRightPad + capsuleSidePad),
              height: 4,
            ),
          ),
        );
      }
      runStart = i + 1;
    }
    if (runStart < flat.length) {
      children.add(TextSpan(text: flat.substring(runStart)));
    }
    return children;
  }

  // -- stream capsule geometry ----------------------------------------------

  /// The stream face's flat projection of its text — the one string the
  /// paragraph lays out and every painter queries (never recomputed
  /// differently, the surface's core discipline).
  StreamMarkers _streamMarkers() => projectStream(widget.text ?? '');

  /// All placeholder offsets in the stream flat text — circles, chips,
  /// reservations: every box the line-ink anchor must exclude.
  List<int> _streamPlaceholderPositions(StreamMarkers markers) => [
    for (var i = 0; i < markers.flat.length; i++)
      if (markers.flat.codeUnitAt(i) == 0xFFFC) i,
  ];

  /// The stream capsules' circle rectangles in paragraph-local
  /// coordinates, keyed by identity: each circle is the family's own
  /// degenerate capsule (2026-09-09 反馈九) — the pill's height and cap
  /// radius, its width squeezed until the caps meet — placed inside its
  /// spacer's reservation by the SAME positional strategy the preview's
  /// pills use: a CONSTANT sidePad of breathing off the neighbours' ink
  /// at every edge, line edges included (2026-09-10 反馈十六 re-ruling —
  /// the line-edge swallows retired; a marker's placement never depends
  /// on what its neighbours or its line edges hold), and vertically
  /// centered on the content-independent anchor the pills use (05 号
  /// 票: strut caret line center + ink bias + ease — never the line's
  /// ink, which re-seats as speech lands),
  /// computed in the same frame the layout happens (painted by the
  /// foreground layer, never placed by the WidgetSpan's font-metric
  /// alignment).
  Map<int, Rect> _streamCircleRects() {
    final paragraph = _streamParagraph?.findRenderObject() as RenderParagraph?;
    if (paragraph == null || !paragraph.attached) return const {};
    final markers = _streamMarkers();
    final lines = textLineInkBoxes(
      paragraph,
      _streamPlaceholderPositions(markers),
      markers.flat.length,
    );
    final inkBias = _paragraphInkBias(paragraph, lines, markers.flat);
    final rects = <int, Rect>{};
    for (final circle in markers.circles) {
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: circle.at, extentOffset: circle.at + 1),
      );
      if (boxes.isEmpty) continue;
      final box = boxes.first.toRect();
      final left = box.left + SrCapsule.sidePad;
      // The one vertical anchor the whole surface shares, content-
      // independent (05 号票): the strut-locked caret line center plus
      // the paragraph's ink bias, eased — the same value whether the
      // line holds speech yet or not, so the marker never re-seats as
      // glyphs land around it (真机: 首字落位胶囊轻微下移); never the
      // spacer's own middle alignment, which rides font metrics.
      final caretPosition = TextPosition(offset: circle.at);
      final caretTop = paragraph.getOffsetForCaret(caretPosition, Rect.zero).dy;
      final caretHeight = paragraph.getFullHeightForCaret(caretPosition);
      final center = caretHeight > 0
          ? caretTop + caretHeight / 2 + inkBias + _opticalEasePx
          : box.center.dy + _opticalEasePx;
      rects[circle.id] = Rect.fromLTRB(
        left,
        center - SrCapsule.height / 2,
        left + pinCapsuleWidth(circle.id),
        center + SrCapsule.height / 2,
      );
    }
    return rects;
  }

  /// The stream's INLINE capsules' rendered bands — the same shape
  /// computation the preview's pills use (one band per covered line,
  /// cut ends square and faded, the parking stub floor), over the
  /// stream's own flat projection with the value the text itself
  /// carries. Read-only face: no active stroke ever fades in.
  Map<int, List<CapsuleBand>> _streamCapsuleBands() {
    final paragraph = _streamParagraph?.findRenderObject() as RenderParagraph?;
    if (paragraph == null || !paragraph.attached) return const {};
    final markers = _streamMarkers();
    return capsuleBandsFor(
      paragraph: paragraph,
      paintText: markers.flat,
      slots: markers.capsules,
      valueEndsWithNewline: (slot) =>
          markers.flat.substring(slot.valueStart, slot.valueEnd).endsWith('\n'),
      opticalEasePx: _opticalEasePx,
    );
  }

  Widget _buildPreview(BuildContext context) {
    final pal = srPalette(context);
    final style = SrType.bodyLarge.copyWith(color: pal.textPrimary);
    // Same strut as the stream face: line heights never vary with a
    // line's content (mixed fallback runs, IME composing runs), so lines
    // never shift as text is typed.
    final strut = StrutStyle.fromTextStyle(
      SrType.bodyLarge,
      forceStrutHeight: true,
    );
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final measured = fittedReservationWidths(
                  maxWidth: constraints.maxWidth,
                  ambientStyle: DefaultTextStyle.of(context).style,
                  style: style,
                  strut: strut,
                  textScaler: MediaQuery.textScalerOf(context),
                  locale: Localizations.maybeLocaleOf(context),
                  standardWidth: pillRightPad + capsuleSidePad,
                  slots: _projection.slots,
                  valueEndsWithNewline: (slot) =>
                      _editor.doc.valueOf(slot.id).endsWith('\n'),
                  buildSpans: (widths) => _spanTree(pal, widths),
                  paintOf: _paintOf,
                  paintOfEnd: _paintOfEnd,
                  paintContentOf: _paintContentOf,
                  composingPaintRange: _composing.isEmpty
                      ? null
                      : TextRange(
                          start: _composingPaintStart,
                          end: _composingPaintEnd,
                        ),
                );
                // The verified overrides win; the whole map lands in
                // both the real tree and (through the closure above)
                // nothing else — the measure re-runs fresh each build.
                final widths = {...measured, ..._fitVerified};
                if (_projection.slots.isNotEmpty) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _verifyReservationFits(),
                  );
                }
                return Text.rich(
                  key: _paragraphKey,
                  strutStyle: strut,
                  TextSpan(style: style, children: _spanTree(pal, widths)),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The paragraph's span tree: body runs as plain text, each capsule as
  /// its chip placeholder (WidgetSpan) followed by its value as plain text
  /// and its reservation placeholder, the composing run underlined over
  /// the selection it replaces. The chip child is a bare spacer — its
  /// leading [capsuleSidePad] plus the cap circle's width; the digits are
  /// painted by the foreground layer onto the pill's cap, so they can
  /// never disagree with the pill's own geometry.
  List<InlineSpan> _spanTree(
    SrPalette pal,
    Map<int, double> reservationWidths,
  ) {
    final projection = _projection;
    final base = projection.base;
    final composing = _composing.isNotEmpty;
    final coverStart = _composingCoverStartFlat;
    final coverEnd = _composingCoverEndFlat;

    // Base segments: (start, end) runs broken at every placeholder
    // boundary and at the composing splice range's edges.
    final breaks = <int>{
      0,
      base.length,
      if (composing) ...[coverStart, coverEnd],
      for (final slot in projection.slots) ...[
        slot.chipAt,
        slot.chipAt + 1,
        slot.valueStart,
        slot.valueEnd,
        slot.valueEnd + 1,
      ],
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
      // its start — even when that segment is a placeholder (the caret
      // rests at the capsule's outside-left dock, or its inside-end).
      if (composingPending && start >= coverStart) {
        children.add(TextSpan(text: _composing, style: underline));
        composingPending = false;
      }
      if (composing && start >= coverStart && end <= coverEnd) {
        continue; // covered by the composing run
      }
      if (base.codeUnitAt(start) == 0xFFFC) {
        ProjectedSlot? chip;
        ProjectedSlot? reservation;
        for (final s in projection.slots) {
          if (s.chipAt == start) chip = s;
          if (s.valueEnd == start) reservation = s;
        }
        // A reservation riding an EMPTY tail line (the value ends with
        // 回车) widens past the parking stub by sidePad (反馈十九): the
        // stub floors above the plain reservation's width, and the text
        // typed right after the capsule would begin against — inside —
        // the pill's span. Widened, the following text keeps its
        // breathing and the pill ends inside its own layout space.
        final emptyTail =
            reservation != null &&
            _editor.doc.valueOf(reservation.id).endsWith('\n');
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              width: chip != null
                  ? capsuleSidePad + chipCircle + chipGap
                  : (reservation != null
                            ? reservationWidths[reservation.id]
                            : null) ??
                        (emptyTail
                            ? _stubFloor + capsuleSidePad
                            : pillRightPad + capsuleSidePad),
              height: chip != null ? capsuleHeight : 4,
            ),
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

  KeyEventResult _onKeyDown(LogicalKeyboardKey key, bool ctrl, bool shift) {
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
        // so the walk is owned here. Off the document's ends the walk
        // homes to its first/last stop (首行再 ↑ 到文档首、末行再 ↓ 到
        // 文档末; F19).
        final up = key == LogicalKeyboardKey.arrowUp;
        final target =
            _verticalStop(up) ??
            (up ? _editor.stops.first : _editor.stops.last);
        _moveTo(target, extend: shift);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        _moveTo(
          ctrl
              ? _editor.stops.first
              : _projection.flatToCursor(
                  _visualLineBounds()?.$1 ?? _lineStartFlat(_caretBaseFlat),
                  preferInside: false,
                ),
          extend: shift,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        if (ctrl) {
          _moveTo(_editor.stops.last, extend: shift);
          return KeyEventResult.handled;
        }
        final walked = _visualLineEndFlat();
        if (walked == null) {
          _moveTo(
            _projection.flatToCursor(
              _lineEndFlat(_caretBaseFlat),
              preferInside: false,
            ),
            extend: shift,
          );
          return KeyEventResult.handled;
        }
        final (endFlat, soft) = walked;
        // End arrives from within the line, so a soft-wrap boundary it
        // lands on binds upstream — it renders at THIS line's end even
        // on engines that seat both affinities onto the next line (F7:
        // 真机 End 跳到下一行, Home 不跳 — a line's start seat is a real
        // glyph seat and needs no binding). A boundary at a wrapped
        // reservation is the value's own end: the outside dock past it
        // seats on the next line.
        if (soft) {
          _affinityKeyFlat = endFlat;
          _affinityKeyLen = _paragraphText.length;
          _affinityUpstream = true;
        }
        _moveTo(
          _projection.flatToCursor(
            endFlat,
            preferInside: soft && _atReservation(endFlat),
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
  // Home/End bound the caret's VISUAL line, so a line the auto-wrapper
  // produced (no '\n' of its own) has its bounds too. Home probes the
  // paragraph at the caret's own dy; End WALKS the seats rightward from
  // the caret until they leave the line (the far-edge probe cannot see
  // the line's end on engines that seat the wrap boundary on the far
  // side only). ↑/↓ probe the paragraph a full pitch from the caret's
  // CENTER and map the hit back through the projection, homing to the
  // document's first/last stop when the probe clamps (the caret is on its
  // boundary line). All fold through
  // flatToCursor, so a bound landing on a capsule edge resolves to its
  // structural (outside) dock — the body-side position of the line —
  // except a line ENDING at a wrapped reservation, whose dock on the
  // next line is wrong: the value's own inside end is the line's end.

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

  /// The caret's VISUAL line bounds in base-space flat offsets: an
  /// auto-wrapped line has no '\n' of its own, so Home/End probe the
  /// paragraph at the caret's own line instead of walking newline
  /// characters (自动换行的行也有行首行尾; 2026-09-09 用户裁定). Null
  /// when the paragraph cannot be probed — the newline-based bounds are
  /// the fallback. A line ending in a hard newline stops BEFORE it: the
  /// newline belongs to the next line's start, not this line's end.
  (int, int)? _visualLineBounds() {
    final paragraph = _paragraph;
    if (paragraph == null) return null;
    final position = _caretRenderPosition(paragraph);
    final caretOffset = paragraph.getOffsetForCaret(position, Rect.zero);
    final lineHeight = paragraph.getFullHeightForCaret(position);
    if (lineHeight <= 0) return null;
    // Probe dead-center of the line, clear of the neighbours' metric
    // boxes grazing the band's edges.
    final dy = caretOffset.dy + lineHeight / 2;
    final start = _baseOf(paragraph.getPositionForOffset(Offset(0, dy)).offset);
    var end = _baseOf(
      paragraph
          .getPositionForOffset(Offset(paragraph.constraints.maxWidth, dy))
          .offset,
    );
    final base = _projection.base;
    if (end > start && end <= base.length && base.codeUnitAt(end - 1) == 0x0A) {
      end--;
    }
    return (start, end);
  }

  /// The caret's visual line's END in base-space flat offsets, walked
  /// one offset at a time from the caret's own seat until the seat
  /// drops to a later line — plus whether that drop is a SOFT wrap
  /// boundary (a hard newline crossing is stepped back before it). The
  /// far-edge probe Home uses cannot see this line's end on engines
  /// that seat a wrap boundary on the far side only (the real engine
  /// collapses both affinities of a boundary before a wrapped
  /// placeholder onto the next line; F7: End resolved past its line).
  /// Mid-line seats are identical on every engine, so the walk needs
  /// nothing the engine disagrees about. Null when the paragraph
  /// cannot be probed.
  (int, bool)? _visualLineEndFlat() {
    final paragraph = _paragraph;
    if (paragraph == null) return null;
    final position = _caretRenderPosition(paragraph);
    final lineDy = paragraph.getOffsetForCaret(position, Rect.zero).dy;
    final text = _paragraphText;
    var o = _caretPaintFlat;
    for (; o < text.length; o++) {
      final dy = paragraph
          .getOffsetForCaret(TextPosition(offset: o), Rect.zero)
          .dy;
      if (dy > lineDy + 0.5) break;
    }
    final end = _baseOf(o);
    final base = _projection.base;
    if (end > 0 && end <= base.length && base.codeUnitAt(end - 1) == 0x0A) {
      // The walk crossed a hard newline: the line's end stops before it.
      return (end - 1, false);
    }
    return (end, o < text.length);
  }

  /// Whether [flat] is a slot's reservation placeholder offset.
  bool _atReservation(int flat) =>
      _projection.slots.any((s) => s.valueEnd == flat);

  /// The stop a line up/down from the caret lands on, or null when the
  /// paragraph cannot be probed or the caret already sits on the
  /// document's first/last line — a clamped probe resolves back onto the
  /// caret's own line, and the caller homes to the document's end stop.
  /// The probe is measured from the caret's CENTER — a full pitch lands
  /// mid-neighbour either way, even when pitches differ — because a pitch
  /// and a half from the caret's TOP is symmetric only downward: upward it
  /// overshoots the line above by half a pitch and landed mid the SECOND
  /// line up (F19: ↑ 隔行跳转 while ↓ walked fine).
  SlotCursor? _verticalStop(bool up) {
    final paragraph = _paragraph;
    if (paragraph == null) return null;
    final position = _caretRenderPosition(paragraph);
    final caretOffset = paragraph.getOffsetForCaret(position, Rect.zero);
    final pitch = paragraph.getFullHeightForCaret(position);
    if (pitch <= 0) return null;
    final center = caretOffset.dy + pitch / 2;
    final probe = Offset(caretOffset.dx, up ? center - pitch : center + pitch);
    final target = paragraph.getPositionForOffset(probe);
    final targetDy = paragraph.getOffsetForCaret(target, Rect.zero).dy;
    if ((targetDy - caretOffset.dy).abs() < 1) return null;
    return _projection.flatToCursor(
      _baseOf(target.offset),
      preferInside: false,
    );
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
      // Tap on the pill: the edit state. ENTERING a capsule starts its
      // value selected for fastest replacement (点预填非空胶囊默认全选
      // — the first tap only); tapping the capsule already under the
      // caret drops the selection and places the caret at the tapped
      // position, so a slot can be edited in place, not only replaced
      // wholesale (2026-09-09 user ruling).
      final slot = _projection.slots.firstWhere((s) => s.id == capsuleId);
      final valueLength = _editor.doc.valueOf(capsuleId).length;
      final entering = _activeId != capsuleId;
      if (entering && valueLength > 0) {
        _editor.select(
          SlotCursor.inside(at: slot.bodyStart, offset: 0),
          SlotCursor.inside(at: slot.bodyStart, offset: valueLength),
        );
      } else {
        _editor.place(cursor);
      }
    } else {
      _editor.place(cursor);
    }
    _bindCaretToTappedLine(local, hit.$1);
    _afterLocalChange();
  }

  /// 反馈十五②: a tap landing on THIS line may resolve to the soft-wrap
  /// boundary offset whose default (downstream) rendering sits at the
  /// NEXT line's start — bind the caret upstream for this position so it
  /// renders at the tapped line's end instead (点击行末, 光标留在行末;
  /// the same binding typing already gets from trailing its insertion
  /// tail). A tap on the next line's start region leaves the downstream
  /// binding: that IS where the position renders. The tap owns the
  /// WHOLE line box it lands on (F3: the old half-pitch threshold only
  /// bound taps in the line's upper half — a low tap on the line's end
  /// intermittently jumped to the next line), so the seat is compared
  /// against the tap point itself: a downstream seat at or below the
  /// tap belongs to a later line than the one tapped.
  void _bindCaretToTappedLine(Offset local, SlotCursor cursor) {
    final paragraph = _paragraph;
    if (paragraph == null) return;
    final flat = _projection.cursorToFlat(cursor);
    if (flat <= 0 || _paragraphText.codeUnitAt(flat - 1) == 0x0A) return;
    final downstream = paragraph.getOffsetForCaret(
      TextPosition(offset: flat),
      Rect.zero,
    );
    if (downstream.dy >= local.dy) {
      _affinityKeyFlat = flat;
      _affinityKeyLen = _paragraphText.length;
      _affinityUpstream = true;
    }
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
  ///
  /// The BACKGROUND the reservations hold outside the pill — a
  /// sidePad-wide strip at each of its flanks — carries the OUTSIDE
  /// docks, geometrically (愿望三: a position the caret can reach must be
  /// clickable; the engine's hit split over a placeholder box wanders
  /// with the layout and cannot carry this). The strips are checked
  /// before the pills so the background owns its own pixels, and any
  /// off-pill resolution landing on a reservation's own flat offset
  /// (a click past the line's very end — the reservation is the line's
  /// last content) maps out the same way.
  (SlotCursor, int?)? _cursorAt(Offset local) {
    final paragraph = _paragraph;
    if (paragraph == null) {
      return null;
    }
    final projection = _projection;
    final flat = _baseOf(paragraph.getPositionForOffset(local).offset);
    final cursor = projection.flatToCursor(flat, preferInside: true);
    for (final entry in _capsuleSegments().entries) {
      final slot = projection.slots.firstWhere((s) => s.id == entry.key);
      final first = entry.value.first;
      final last = entry.value.last;
      if (Rect.fromLTRB(
        first.left - capsuleSidePad,
        first.top - 2,
        first.left,
        first.bottom + 2,
      ).contains(local)) {
        return (
          projection.flatToCursor(slot.chipAt, preferInside: false),
          null,
        );
      }
      if (Rect.fromLTRB(
        last.right,
        last.top - 2,
        last.right + capsuleSidePad,
        last.bottom + 2,
      ).contains(local)) {
        return (
          projection.flatToCursor(slot.valueEnd, preferInside: false),
          null,
        );
      }
    }
    // The pill wins over the text position under it: the whole capsule is
    // the tap target — save its whole-left on the first band.
    for (final entry in _capsuleSegments().entries) {
      for (final rect in entry.value) {
        if (rect.inflate(2).contains(local)) {
          final slot = projection.slots.firstWhere((s) => s.id == entry.key);
          if (rect == entry.value.first &&
              local.dx < _valueContentLeft(paragraph, slot)) {
            return (
              projection.flatToCursor(slot.chipAt, preferInside: false),
              null,
            );
          }
          return (cursor, slot.id);
        }
      }
    }
    if (projection.slots.any((s) => s.chipAt == flat)) {
      return (projection.flatToCursor(flat, preferInside: false), null);
    }
    if (projection.slots.any((s) => s.valueEnd == flat)) {
      return (projection.flatToCursor(flat, preferInside: false), null);
    }
    return (cursor, null);
  }

  /// The left edge of a capsule's CONTENT — its first value glyph — or
  /// negative infinity when the value is empty (no content side: the
  /// whole pill is the entering target).
  double _valueContentLeft(RenderParagraph paragraph, ProjectedSlot slot) {
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: _paintOf(slot.valueStart),
        extentOffset: _paintOfEnd(slot.valueEnd),
      ),
    );
    return boxes.isEmpty ? double.negativeInfinity : boxes.first.toRect().left;
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

  /// The reservation widths the REAL paragraph has verified (停车场 04
  /// second round): a standalone TextPainter's accumulation drifts a
  /// hair from the live paragraph on real font fallback chains, so a
  /// measured fit can still wrap on the machine that measured it fit —
  /// the post-frame check [_verifyReservationFits] reads the laid-out
  /// paragraph itself and tightens from ITS leftover, one shaving frame
  /// at a time if the drift is deeper than the margin. Overrides win
  /// over the measure; they lift once the line holds a full reservation
  /// of room again (content edited back below the edge).
  Map<int, double> _fitVerified = const {};

  // -- geometry for painters and hit tests ---------------------------------

  /// The pill rectangles per capsule identity, in paragraph-local
  /// coordinates — the hover/tap hit boxes and the tests' geometry seam.
  Map<int, List<Rect>> _capsuleSegments() => {
    for (final entry in _capsuleBands().entries)
      entry.key: [for (final band in entry.value) band.rect],
  };

  /// The rendered bands per capsule identity, in paragraph-local
  /// coordinates: each covered line renders as its own band, centered on
  /// a content-independent anchor — the strut-locked caret line center
  /// plus the paragraph's ink bias, eased (05 号票; the ink box of 08 号
  /// 票's ruling rode the fonts the line's runs resolved and re-seated
  /// the capsule as content landed, 真机: 首字落位胶囊轻微下移). An end
  /// the wrapper
  /// or a newline CUT is square, with the text beside it flush against
  /// the column's edge exactly like ordinary text — no parking, no
  /// clearance; only the capsule's NATURAL ends (the chip's left cap,
  /// the value's own end) keep the pill's rounded caps (截断直角、文字
  /// 贴边; D3 反馈五终裁); a cut end's fill and stroke dissolve to
  /// nothing approaching it (截断端渐隐). The empty tail line's
  /// parking stub floors at the reservation's own width, so the cut
  /// dissolve has its flat run and the cap stays one continuous
  /// semicircle clear of it (反馈十八修复二). Every band is the
  /// capsule's own height on its line — the thin daylight between a
  /// wrap's bands is the family's look (反馈十五 reverted the seam-
  /// closing that stretched them). A single-line
  /// capsule is one complete pill.
  /// A capsule spanning several lines reads as one band across the
  /// column — the first segment runs to the column's right edge, interior
  /// lines take the full width, the last is flush left past its content
  /// (首行抵右、中行全宽、末行贴左; 23 号验收轮 D3) — so short wrapped
  /// lines cannot scatter ragged pill ends through the paragraph. Empty
  /// value lines (回车/空行) keep their own full-width segment. The
  /// breathing is CONSTANT at every edge, line edges included: the pill
  /// always sits on its reserved sidePad and never paints over it, so a
  /// capsule's geometry never depends on what its neighbours or its
  /// line's edges hold (2026-09-10 反馈十六 re-ruling, retiring the
  /// line-edge swallows of 反馈四②/十三) — and the background strips the
  /// reservations hold beside the pill stay clickable (愿望三).
  Map<int, List<CapsuleBand>> _capsuleBands() {
    final paragraph = _paragraph;
    if (paragraph == null) return const {};
    return capsuleBandsFor(
      paragraph: paragraph,
      paintText: _paragraphText,
      slots: _projection.slots,
      valueEndsWithNewline: (slot) =>
          _editor.doc.valueOf(slot.id).endsWith('\n'),
      opticalEasePx: _opticalEasePx,
      paintOf: _paintOf,
      paintOfEnd: _paintOfEnd,
      paintContentOf: _paintContentOf,
    );
  }

  // -- reservation fit verification ------------------------------------------

  /// The REAL paragraph's verdict on the reservation fits (停车场 04
  /// second round; 真机: a measured fit still wrapped on real font
  /// fallback chains — the standalone painter's accumulation drifts
  /// from the live one's). Runs post-frame on every build with slots:
  /// any reservation the laid-out paragraph still put on a later line
  /// than its reference box is tightened from the paragraph's OWN
  /// leftover — a two-pixel margin, then a pixel a frame while it still
  /// wraps (convergent; a zero-width reservation cannot indent
  /// anything) — and a sticky fit lifts only once its line again holds
  /// a full reservation's room (lifting earlier would flap against the
  /// measure's own flag).
  void _verifyReservationFits() {
    if (!mounted) return;
    final streamMarkers = _isPreview ? null : _streamMarkers();
    final paragraph = _isPreview
        ? _paragraph
        : _streamParagraph?.findRenderObject() as RenderParagraph?;
    if (paragraph == null || !paragraph.attached) return;
    final slots = _isPreview ? _projection.slots : streamMarkers!.capsules;
    if (slots.isEmpty) return;
    final maxWidth = paragraph.constraints.maxWidth;
    if (!maxWidth.isFinite || maxWidth <= 0) return;
    // Paint-space offsets throughout — while composing rides the value
    // the laid-out paragraph carries the run spliced in and every slot
    // offset shifts (真机第二轮: IME 组合贴边仍缩进); the chip probes
    // content space (05 号票: a caret-left composition shifts the chip
    // past the run).
    final toPaintEnd = _isPreview ? _paintOfEnd : (int f) => f;
    final toContent = _isPreview ? _paintContentOf : (int f) => f;
    final composingPaintRange = !_isPreview || _composing.isEmpty
        ? null
        : TextRange(start: _composingPaintStart, end: _composingPaintEnd);
    final standardWidth = pillRightPad + capsuleSidePad;
    final next = <int, double>{..._fitVerified};
    var changed = false;
    for (final slot in slots) {
      final emptyTail = _isPreview
          ? _editor.doc.valueOf(slot.id).endsWith('\n')
          : streamMarkers!.flat
                .substring(slot.valueStart, slot.valueEnd)
                .endsWith('\n');
      if (emptyTail) continue;
      final reservationPaint = toPaintEnd(slot.valueEnd);
      if (composingPaintRange != null &&
          composingPaintRange.start < reservationPaint + 1 &&
          reservationPaint < composingPaintRange.end) {
        continue; // the composing run replaced this reservation
      }
      final reservationBoxes = paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: reservationPaint,
          extentOffset: reservationPaint + 1,
        ),
      );
      final referenceBoxes = paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: toContent(slot.chipAt),
          extentOffset: reservationPaint,
        ),
      );
      if (reservationBoxes.isEmpty || referenceBoxes.isEmpty) continue;
      final reservation = reservationBoxes.first.toRect();
      final reference = referenceBoxes.last.toRect();
      final pitch = paragraph.getFullHeightForCaret(
        TextPosition(offset: reservationPaint),
      );
      // Line membership by box centres, the measure's own rule: a
      // 4-px middle-aligned placeholder sits a few px below a glyph's
      // top on the same line.
      final wrapped =
          (reservation.center.dy - reference.center.dy).abs() >=
          (pitch > 0 ? pitch / 2 : 8);
      final leftover = maxWidth - reference.right;
      if (wrapped) {
        var width = math.max(0.0, math.min(standardWidth, leftover - 2));
        final existing = next[slot.id];
        // Still wrapped at a value this same formula produced: the
        // drift runs deeper than the margin — shave a pixel and look
        // again next frame.
        if (existing != null && existing <= width) {
          width = math.max(0.0, existing - 1);
        }
        if (next[slot.id] != width) {
          next[slot.id] = width;
          changed = true;
        }
      } else if (next.containsKey(slot.id) && leftover >= standardWidth + 4) {
        next.remove(slot.id);
        changed = true;
      }
    }
    if (changed && mounted) setState(() => _fitVerified = next);
  }

  /// The paragraph's line ink boxes, top to bottom: the TEXT glyphs only
  /// — every placeholder box (chips, reservations, stream circles) is
  /// excluded. These calibrate the paragraph's ink-vs-caret bias (the
  /// constant the content-independent capsule anchor rides, 05 号票) and
  /// carry the selection tint's own anchor; the pills, digits and caret
  /// center on the strut caret line plus that bias instead, so their
  /// seat never depends on what the line happens to contain (胶囊对所
  /// 在行上下间距绝对相等, 不锁像素;08 号票).
  List<Rect> _lineInkBoxes(RenderParagraph paragraph) {
    final text = _paragraphText;
    final positions = <int>[
      for (var i = 0; i < text.length; i++)
        if (text.codeUnitAt(i) == 0xFFFC) i,
    ];
    return textLineInkBoxes(paragraph, positions, text.length);
  }

  /// The paragraph's own ink-vs-caret bias — see [_paragraphInkBiasOf].
  double _paragraphInkBias(
    RenderParagraph paragraph,
    List<Rect> inkLines,
    String flat,
  ) => _paragraphInkBiasOf(paragraph, inkLines, flat);

  /// The ink-box center of the line [dy] falls on, eased down by the
  /// optical nudge — the selection tint's anchor (it highlights text
  /// and tracks the glyphs it tints). The capsules and the caret ride
  /// the content-independent anchor instead (05 号票).
  double _inkCenter(List<Rect> lines, double dy, {double? fallback}) =>
      inkCenterOf(lines, dy, _opticalEasePx, fallback: fallback);

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
  /// height, centered on its line's ink box — the same anchor the pills
  /// and selection use).
  Rect? caretRect() {
    final paragraph = _paragraph;
    if (paragraph == null) return null;
    final position = _caretRenderPosition(paragraph);
    var offset = paragraph.getOffsetForCaret(position, Rect.zero);
    final line = paragraph.getFullHeightForCaret(position);
    // 反馈十五②: an upstream-bound caret whose engine-rendered seat lies
    // on the line BELOW its preceding glyph (the placeholder boundary)
    // parks at that glyph's right edge, on the glyph's own line — the
    // caret stays where the typing or the tap happened, never jumping
    // ahead of the text it trails.
    final text = _paragraphText;
    if (position.affinity == TextAffinity.upstream &&
        position.offset > 0 &&
        text.codeUnitAt(position.offset - 1) != 0x0A) {
      final prevBoxes = paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: position.offset - 1,
          extentOffset: position.offset,
        ),
      );
      if (prevBoxes.isNotEmpty) {
        final prev = prevBoxes.last.toRect();
        if ((prev.center.dy - (offset.dy + line / 2)).abs() > 1) {
          offset = Offset(prev.right, prev.center.dy - line / 2);
        }
      }
    }
    // The caret rides the same content-independent anchor as the pills
    // (05 号票): strut caret line center + ink bias + ease, so the bar
    // stays centered in the pill it sits inside whatever lands on the
    // line.
    final lines = _lineInkBoxes(paragraph);
    final inkBias = _paragraphInkBias(paragraph, lines, _paragraphText);
    final center = offset.dy + line / 2 + inkBias + _opticalEasePx;
    return Rect.fromLTWH(
      offset.dx,
      center - capsuleHeight / 2,
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
        ? _shadow.text.replaceRange(
            previousComposing.start,
            previousComposing.end,
            '',
          )
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

  /// The rendered bands per identity, corner shapes included — the
  /// tests' shape seam (截断直角、自然端圆帽).
  Map<int, List<CapsuleBand>> capsuleBandsForTest() => _capsuleBands();

  /// The stream capsules' circle rectangles per identity — the stream
  /// face's geometry seam.
  Map<int, Rect> streamCircleRectsForTest() => _streamCircleRects();
}

// ---------------------------------------------------------------------------
// shared line geometry
// ---------------------------------------------------------------------------

/// A capsule's covered lines, with a tail line that holds NEITHER the
/// chip nor any value glyph dropped — unless the value hard-continues
/// onto it (it ends with a newline: a trailing 回车's empty line is the
/// caret's real parking line and keeps its band, 反馈七). The tail-less
/// case is the soft-wrap artifact: every value glyph fit on the capsule's
/// line and only the invisible reservation placeholder wrapped; the
/// covered-lines probe — which asks the caret AT the reservation's own
/// offset, downstream — claimed the next line on engines that report the
/// wrap boundary on the far side, and the capsule rendered a spurious
/// empty stub below a complete pill: a fragment hanging by a thread
/// (真机, 反馈十四). With the tail dropped the capsule is one complete
/// pill on its glyph line.
List<({double top, double height})> truncateCoveredLines(
  List<({double top, double height})> covered,
  List<Rect> boxes,
  bool valueEndsWithNewline,
) {
  if (valueEndsWithNewline || covered.length <= 1) return covered;
  var lastHeld = 0;
  for (final box in boxes) {
    for (var i = 0; i < covered.length; i++) {
      if (box.top < covered[i].top + covered[i].height - 1 &&
          box.bottom > covered[i].top + 1) {
        if (i > lastHeld) lastHeld = i;
      }
    }
  }
  if (lastHeld == covered.length - 1) return covered;
  return covered.sublist(0, lastHeld + 1);
}

/// The per-slot reservation widths that keep the capsule's invisible
/// tail from LEADING a wrapped line (停车场 04, 2026-09-12). A
/// reservation placeholder is unbreakable: when the capsule's value
/// ends within one reservation's width of the column's right edge and
/// content follows, the placeholder itself wraps and that content
/// trails it — starting the next line indented by the reservation's
/// width (真机: 后续内容不顶格, 空出一段距离), its seat ruled by the
/// capsule above. The reservation's one layout duty is breathing for
/// SAME-LINE following text; a reservation that wraps has no same-line
/// follower, so the duty is vacuous and only the indent remains.
///
/// The measure lays the caller's own span tree out first in a
/// TextPainter over the same ambient root style, strut, scaler and
/// width the real paragraph resolves (Text.rich nests our styled span
/// under the ambient DefaultTextStyle — the family the runs resolve
/// hangs off that root — and the same engine breaks the same input the
/// same way); every reservation the measure finds on a LATER line than
/// its reference box (the value's last glyph, or the chip when the
/// value is empty) is fitted to exactly the leftover advance its line
/// still holds, minus a hair against float equality. Fitted, it stays
/// on the capsule's line — the pill paints its own parking tail past
/// the value regardless — and the content that wraps anyway starts
/// flush at x=0. Values that end with 回车 are excluded: their
/// reservation rides the value's own empty line (反馈十九's widened
/// stub) and never wraps. The measure iterates to a fixed point
/// (capped): one slot's fit reflows the lines below it, so a downstream
/// slot's leftover is only final once the slots before it are fitted.
Map<int, double> fittedReservationWidths({
  required double maxWidth,
  required TextStyle ambientStyle,
  required TextStyle style,
  required StrutStyle strut,
  required TextScaler textScaler,
  Locale? locale,
  required double standardWidth,
  required List<ProjectedSlot> slots,
  required bool Function(ProjectedSlot slot) valueEndsWithNewline,
  required List<InlineSpan> Function(Map<int, double> widths) buildSpans,
  int Function(int)? paintOf,
  int Function(int)? paintOfEnd,
  int Function(int)? paintContentOf,
  TextRange? composingPaintRange,
}) {
  if (slots.isEmpty || !maxWidth.isFinite || maxWidth <= 0) {
    return const {};
  }
  final toPaintEnd = paintOfEnd ?? (f) => f;
  final toContent = paintContentOf ?? paintOf ?? (f) => f;
  var widths = const <int, double>{};
  for (var pass = 0; pass < 3; pass++) {
    final spans = buildSpans(widths);
    final painter =
        TextPainter(
          text: TextSpan(
            style: ambientStyle,
            children: [TextSpan(style: style, children: spans)],
          ),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
          strutStyle: strut,
          locale: locale,
        )..setPlaceholderDimensions([
          for (final span in spans)
            if (span is WidgetSpan)
              PlaceholderDimensions(
                size: Size(
                  (span.child as SizedBox).width!,
                  (span.child as SizedBox).height!,
                ),
                alignment: PlaceholderAlignment.middle,
              ),
        ]);
    painter.layout(maxWidth: maxWidth);
    var changed = false;
    for (final slot in slots) {
      if (valueEndsWithNewline(slot)) continue;
      // Paint-space offsets: the spans the paragraph (and this painter)
      // lays out carry the composing run spliced in, so a slot's
      // reservation placeholder sits at its SHIFTED index — the base
      // offset would probe the composing text instead and never see
      // the wrap (真机第二轮: IME 组合贴边仍缩进).
      final reservationPaint = toPaintEnd(slot.valueEnd);
      if (composingPaintRange != null &&
          composingPaintRange.start < reservationPaint + 1 &&
          reservationPaint < composingPaintRange.end) {
        continue; // the composing run replaced this reservation
      }
      final reservationBoxes = painter.getBoxesForSelection(
        TextSelection(
          baseOffset: reservationPaint,
          extentOffset: reservationPaint + 1,
        ),
      );
      // The unit the reservation must stay beside: the capsule's last
      // laid-out content before it — the composing run's tail while one
      // rides the value, else the value's last glyph, else the chip. The
      // chip probes CONTENT space: a composition at the capsule's
      // outside-left dock shifts the chip past the run (05 号票).
      final referenceBoxes = painter.getBoxesForSelection(
        TextSelection(
          baseOffset: toContent(slot.chipAt),
          extentOffset: reservationPaint,
        ),
      );
      if (reservationBoxes.isEmpty || referenceBoxes.isEmpty) continue;
      // Line membership, never raw tops: a reservation is a 4-px
      // placeholder MIDDLE-aligned — its box sits a few px below a
      // glyph's even on the same line — so the line test compares box
      // CENTRES against half a line's pitch (same line drifts a px or
      // two; a wrap is a full pitch).
      final reservation = reservationBoxes.first.toRect();
      final reference = referenceBoxes.last.toRect();
      final pitch = painter.getFullHeightForCaret(
        TextPosition(offset: reservationPaint),
        Rect.zero,
      );
      if ((reservation.center.dy - reference.center.dy).abs() <
          (pitch > 0 ? pitch / 2 : 8)) {
        continue; // fits its line
      }
      // The fit keeps two pixels of slack: the standalone measure can
      // drift from the live paragraph's own accumulation on real font
      // fallback chains (the drift that broke the first round on the
      // real machine), and a would-wrap reservation has no same-line
      // follower for the slack to squeeze — invisible by construction.
      // Deeper drift is the post-frame verification's to correct.
      final leftover = maxWidth - reference.right - 2;
      widths = {
        ...widths,
        slot.id: math.max(0, math.min(standardWidth, leftover)),
      };
      changed = true;
    }
    painter.dispose();
    // A fit STICKS: the pass that measured with it in place saw no wrap
    // (that is the repair working), so shrinks are only ever added or
    // tightened, never withdrawn — withdrawing would oscillate (fit →
    // no wrap seen → withdraw → wrap seen → …) and end on the wrong
    // parity with nothing applied.
    if (!changed) break;
  }
  return widths;
}

/// The paragraph's own ink-vs-caret bias: a TEXT line's ink-box
/// center minus its caret line-box center — the engine's leading
/// split for the fonts this paragraph actually resolved, measured
/// from the paragraph itself (a standalone TextPainter seats glyphs
/// differently inside its own line and measures wrong). Ink-less
/// lines anchor on their strut-locked caret line center plus this
/// bias — exactly where their ink anchor lands once glyphs arrive —
/// so the anchor source never switches and nothing re-seats (反馈十
/// 二). Zero when the paragraph holds no text at all: nothing to
/// calibrate from, and only the first glyph's own font delta —
/// sub-pixel on real machines — can move.
double _paragraphInkBiasOf(
  RenderParagraph paragraph,
  List<Rect> inkLines,
  String flat,
) {
  for (var i = 0; i < flat.length; i++) {
    final cu = flat.codeUnitAt(i);
    if (cu == 0xFFFC || cu == 0x0A) continue;
    final probe = TextPosition(offset: i);
    final height = paragraph.getFullHeightForCaret(probe);
    if (height <= 0) continue;
    final center =
        paragraph.getOffsetForCaret(probe, Rect.zero).dy + height / 2;
    for (final line in inkLines) {
      if (center >= line.top - 0.5 && center <= line.bottom + 0.5) {
        return line.center.dy - center;
      }
    }
  }
  return 0;
}

/// The ink-box center of the line [dy] falls on, eased down by
/// [opticalEasePx] — the selection tint's vertical anchor. When no
/// line claims [dy] — an ink-less line, placeholders only — the
/// anchor falls to [fallback] (eased alike).
double inkCenterOf(
  List<Rect> lines,
  double dy,
  double opticalEasePx, {
  double? fallback,
}) {
  for (final line in lines) {
    if (dy >= line.top - 0.5 && dy <= line.bottom + 0.5) {
      return line.center.dy + opticalEasePx;
    }
  }
  return (fallback ?? dy) + opticalEasePx;
}

/// The paragraph lines a capsule covers, top to bottom, as caret bands
/// (the caret's top and full line height at a position on the line). A
/// line with no glyphs — an empty value line between 回车s, or the one
/// a trailing 回车 leaves — is real to the caret but invisible to every
/// box query, so the lines are discovered by parking the caret at each
/// flat position from the chip through the reservation placeholder
/// (which rides the value's last line, so a trailing 回车's line is
/// found too). [paintOf]/[paintOfEnd] carry the caller's base→paint
/// shift (the preview's composing splice; identity on the stream face);
/// [paintContentOf] carries the content-space map the chip probes (05
/// 号票: content at the composing point shifts past the run, seat
/// semantics would pin the walk's start inside the run).
List<({double top, double height})> coveredLinesFor(
  RenderParagraph paragraph,
  ProjectedSlot slot, {
  int Function(int)? paintOf,
  int Function(int)? paintOfEnd,
  int Function(int)? paintContentOf,
}) {
  final toPaintEnd = paintOfEnd ?? (f) => f;
  final toContent = paintContentOf ?? paintOf ?? (f) => f;
  final bands = <({double top, double height})>[];
  for (var f = toContent(slot.chipAt); f <= toPaintEnd(slot.valueEnd); f++) {
    final position = TextPosition(offset: f);
    final top = paragraph.getOffsetForCaret(position, Rect.zero).dy;
    final height = paragraph.getFullHeightForCaret(position);
    var seen = false;
    for (final band in bands) {
      if ((band.top - top).abs() < 0.75) {
        seen = true;
        break;
      }
    }
    if (!seen) bands.add((top: top, height: height));
  }
  bands.sort((a, b) => a.top.compareTo(b.top));
  return bands;
}

/// The rendered bands per capsule identity, in paragraph-local
/// coordinates — the ONE shape computation both faces of the surface
/// family run: the preview's editable pills (29 号's extraction seam)
/// and the stream's read-only inline capsules. Each covered line
/// renders as its own band, centered on a content-independent anchor —
/// the strut-locked caret line center plus the paragraph's ink bias,
/// eased (05 号票; formerly the line's ink box, 08 号票, which re-seated
/// as the line's content changed on real fallback chains); an end the
/// wrapper or a newline CUT is square,
/// only the capsule's NATURAL ends keep the rounded caps (截断直角、文
/// 字贴边; D3 反馈五终裁); a cut end's fill dissolves approaching it
/// (截断端渐隐); the parking stub floors at the reservation's own width
/// (反馈十八修复二); every band is the capsule's own height on its line
/// (反馈十五); the breathing is CONSTANT at every edge (反馈十六).
///
/// [paintText] is the string the paragraph actually lays out — the flat
/// projection (the stream's, or the preview's with the composing run
/// spliced). [valueEndsWithNewline] answers per occurrence, its fact
/// source the caller's (the preview's value map; the stream's own text).
/// [paintOf]/[paintOfEnd] default to identity for faces with no
/// composing overlay; [paintContentOf] carries the content-space map the
/// chip's box probes (05 号票).
Map<int, List<CapsuleBand>> capsuleBandsFor({
  required RenderParagraph paragraph,
  required String paintText,
  required List<ProjectedSlot> slots,
  required bool Function(ProjectedSlot slot) valueEndsWithNewline,
  required double opticalEasePx,
  int Function(int)? paintOf,
  int Function(int)? paintOfEnd,
  int Function(int)? paintContentOf,
}) {
  final toPaint = paintOf ?? (f) => f;
  final toPaintEnd = paintOfEnd ?? (f) => f;
  final toContent = paintContentOf ?? paintOf ?? (f) => f;
  final placeholderPositions = [
    for (var i = 0; i < paintText.length; i++)
      if (paintText.codeUnitAt(i) == 0xFFFC) i,
  ];
  final lines = textLineInkBoxes(
    paragraph,
    placeholderPositions,
    paintText.length,
  );
  final inkBias = _paragraphInkBiasOf(paragraph, lines, paintText);
  // The wrap width the layout itself used — the theoretical right edge
  // a full line of text reaches.
  final columnRight = paragraph.constraints.maxWidth;
  final bands = <int, List<CapsuleBand>>{};
  for (final slot in slots) {
    // The chip probes CONTENT space — an offset at the composing point
    // belongs PAST the run, where the placeholder actually sits (05 号
    // 票: a caret-left composition must push the whole capsule right).
    final chipPaint = toContent(slot.chipAt);
    final chipBoxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: chipPaint, extentOffset: chipPaint + 1),
    );
    final valueBoxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: toPaint(slot.valueStart),
        extentOffset: toPaintEnd(slot.valueEnd),
      ),
    );
    final boxes = <Rect>[
      for (final box in chipBoxes) box.toRect(),
      for (final box in valueBoxes) box.toRect(),
    ]..sort((a, b) => a.left.compareTo(b.left));
    if (boxes.isEmpty) continue;
    var covered = coveredLinesFor(
      paragraph,
      slot,
      paintOf: paintOf,
      paintOfEnd: paintOfEnd,
      paintContentOf: paintContentOf,
    );
    // 反馈十四: a covered tail line holding neither the chip nor any
    // value glyph — claimed by the wrap-boundary caret probe at the
    // reservation's own offset — belongs to the capsule only when the
    // value hard-continues onto it. Otherwise the capsule is one
    // complete pill on its glyph line.
    covered = truncateCoveredLines(covered, boxes, valueEndsWithNewline(slot));
    if (covered.length > 1 && columnRight.isFinite && chipBoxes.isNotEmpty) {
      // Multi-line: one band per covered line, flush to the column.
      // The last band keeps the content-bounded right edge — the body
      // text after the capsule flows on beside it. Every end but the
      // first's left (the chip cap) and the
      // last's right (the value's own end) is a CUT: square. The
      // empty tail line's parking stub floors at the reservation's own
      // width — exactly the layout space it already owns, clear of all
      // ink (反馈十八修复二; the floor's history: 反馈七终案's cap
      // radius, then widened — the near-degenerate width lost the
      // fill's lower-left crescent on the real GPU and left the cut
      // dissolve no flat run).
      final lastBand = covered.last;
      var lastRight = 0.0;
      for (final box in valueBoxes) {
        if (box.top < lastBand.top + lastBand.height - 1 &&
            box.bottom > lastBand.top + 1) {
          lastRight = math.max(lastRight, box.right);
        }
      }
      // The tail breathing is CONSTANT (反馈十六): the last band keeps
      // the parking pad only, whatever does or does not follow. The
      // empty tail line's parking stub floors at the reservation's own
      // width plus the look-tuned pixels (反馈十八修复二 trialed at the
      // reservation's own width, then walked the cap start right a
      // pixel at a time; the ramp clamp keeps the dissolve's length
      // constant): at cap radius + 0.5 the near-degenerate corner
      // geometry lost the fill's lower-left crescent on the real GPU
      // (软件光栅无此缺陷), and the cut dissolve had no flat run to
      // live in — filling the layout space the stub already owns gives
      // the ramp its visible run and walks the cap clear of both the
      // dissolve and the degenerate widths (右端连续半圆弧, 渐变共存).
      final stubFloor =
          SlotSurfaceState.pillRightPad + SlotSurfaceState.capsuleSidePad + 2;
      final lastBandRight = math.max(
        lastRight + SlotSurfaceState.pillRightPad,
        stubFloor,
      );
      // No value glyphs claim the last covered line — the value ended
      // with 回车 and the band there is the capsule's parking stub.
      final slotBands = <CapsuleBand>[];
      // One anchor per covered line, content-independent (05 号票): the
      // strut-locked caret line center plus the paragraph's ink bias —
      // the same value whether the line holds text yet or not, so a
      // capsule's seat never re-seats when its first glyph (or an IME
      // run of another script) lands. The ink box a with-text line
      // reports rides the fonts its runs resolved and visibly drifts on
      // real fallback chains (真机: 首字落位胶囊轻微下移).
      final centers = <double>[
        for (final band in covered)
          band.top + band.height / 2 + inkBias + opticalEasePx,
      ];
      final half = SlotSurfaceState.capsuleHeight / 2;
      for (var i = 0; i < covered.length; i++) {
        // Every band is the capsule's OWN height on its line (反馈十
        // 五: the seam-closing experiment that stretched bands toward
        // their neighbours made the capsule read taller than the
        // family and graze the capsules above and below — the thin
        // daylight between a wrap's bands is the family's look, ruled
        // back).
        final top = centers[i] - half;
        final bottom = centers[i] + half;
        // The first segment's cap keeps its leading sidePad
        // unconditionally (反馈十六); every later segment is a column
        // band: full width, flush left.
        final left = i == 0
            ? chipBoxes.first.toRect().left + SlotSurfaceState.capsuleSidePad
            : 0.0;
        final right = i == covered.length - 1 ? lastBandRight : columnRight;
        slotBands.add(
          CapsuleBand(
            rect: Rect.fromLTRB(left, top, right, bottom),
            leftRounded: i == 0,
            rightRounded: i == covered.length - 1,
          ),
        );
      }
      bands[slot.id] = slotBands;
      continue;
    }
    // Single line: a complete pill hugging its content. Group the
    // covered boxes into per-line runs (one, here): a box overlaps its
    // own line's boxes vertically and never the neighbour line's.
    final runs = <List<Rect>>[];
    for (final box in boxes) {
      final run = runs.isEmpty ? null : runs.last;
      final sameLine =
          run != null &&
          box.top < run.first.bottom + 1 &&
          box.bottom > run.first.top - 1;
      if (sameLine) {
        run.add(box);
      } else {
        runs.add([box]);
      }
    }
    final slotBands = <CapsuleBand>[];
    for (var i = 0; i < runs.length; i++) {
      var left = runs[i].first.left;
      var right = runs[i].first.right;
      for (final box in runs[i]) {
        left = math.min(left, box.left);
        right = math.max(right, box.right);
      }
      // The breathing is CONSTANT (2026-09-10 反馈十六 re-ruling,
      // retiring the line-edge swallows of 反馈四②/十三): the first
      // run's left always sits on the chip reservation's leading
      // sidePad — a capsule's placement and width never depend on
      // what its neighbours or the line's edges hold — and the last
      // run always grows into the parking pad the reservation holds
      // past the value, keeping its breathing tail.
      if (i == 0) left = left + SlotSurfaceState.capsuleSidePad;
      final tail = i == runs.length - 1 ? SlotSurfaceState.pillRightPad : 0.0;
      // The anchor is the strut-locked caret line center of the covered
      // line (反馈十二's convention) plus the paragraph's ink bias —
      // content-independent on EVERY line now, ink-holding ones alike
      // (05 号票): never the run's own placeholder box, never the line's
      // ink union, both of which re-seat as content lands.
      var coveredCenter = runs[i].first.center.dy;
      var coveredDistance = double.infinity;
      for (final band in covered) {
        final distance =
            ((band.top + band.height / 2) - runs[i].first.center.dy).abs();
        if (distance < coveredDistance) {
          coveredDistance = distance;
          coveredCenter = band.top + band.height / 2;
        }
      }
      final center = coveredCenter + inkBias + opticalEasePx;
      slotBands.add(
        CapsuleBand(
          rect: Rect.fromLTRB(
            left,
            center - SlotSurfaceState.capsuleHeight / 2,
            right + tail,
            center + SlotSurfaceState.capsuleHeight / 2,
          ),
          leftRounded: true,
          rightRounded: true,
        ),
      );
    }
    bands[slot.id] = slotBands;
  }
  return bands;
}

/// A paragraph's line ink boxes over the TEXT glyphs only, top to bottom:
/// the selection ranges BETWEEN [placeholders] (flat offsets of the inline
/// placeholder code units) are measured and unioned per line; the
/// placeholder boxes themselves are skipped. Both faces of the surface
/// family anchor their capsule chrome on this — the stream's circle
/// shifts and the preview's pills, digits, selection and caret — so every
/// capsule aligns against where the line's writing actually sits, never
/// against a placeholder's own (font-metric-driven) placement.
List<Rect> textLineInkBoxes(
  RenderParagraph paragraph,
  List<int> placeholders,
  int length,
) {
  final boxes = <TextBox>[];
  var start = 0;
  for (final p in placeholders) {
    if (p > start) {
      boxes.addAll(
        paragraph.getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: p),
        ),
      );
    }
    start = p + 1;
  }
  if (start < length) {
    boxes.addAll(
      paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: length),
      ),
    );
  }
  return _mergeLineBoxes(boxes);
}

/// Unions [boxes] into per-line rectangles, top to bottom: boxes that
/// overlap vertically are one visual line's band.
List<Rect> _mergeLineBoxes(List<TextBox> boxes) {
  if (boxes.isEmpty) return const [];
  final sorted = boxes.toList()..sort((a, b) => a.top.compareTo(b.top));
  final lines = <Rect>[];
  for (final box in sorted) {
    final rect = box.toRect();
    if (lines.isNotEmpty && rect.top < lines.last.bottom) {
      final last = lines.removeLast();
      lines.add(
        Rect.fromLTRB(
          math.min(last.left, rect.left),
          last.top,
          math.max(last.right, rect.right),
          math.max(last.bottom, rect.bottom),
        ),
      );
    } else {
      lines.add(rect);
    }
  }
  return lines;
}

// ---------------------------------------------------------------------------
// painters
// ---------------------------------------------------------------------------

/// One rendered capsule line: the band's rectangle and which of its ends
/// carry the pill's rounded cap. A capsule's NATURAL ends — the chip's
/// left cap and the value's own end — stay rounded; an end the wrapper or
/// a newline CUT is square, the text beside it sits flush against the
/// column's edge like ordinary text (截断直角、文字贴边; D3 反馈五终裁),
/// and the ink dissolves approaching it, so the square edge never reads
/// as a drawn edge (截断端渐隐; D3 反馈八).
class CapsuleBand {
  const CapsuleBand({
    required this.rect,
    required this.leftRounded,
    required this.rightRounded,
  });

  final Rect rect;
  final bool leftRounded;
  final bool rightRounded;

  /// The band's painted shape: rounded caps on the natural ends, square
  /// edges on the cut ones, optionally inflated for the active stroke.
  RRect shape(Radius cap, {double inflate = 0}) => RRect.fromLTRBAndCorners(
    rect.left - inflate,
    rect.top - inflate,
    rect.right + inflate,
    rect.bottom + inflate,
    topLeft: leftRounded ? cap : Radius.zero,
    bottomLeft: leftRounded ? cap : Radius.zero,
    topRight: rightRounded ? cap : Radius.zero,
    bottomRight: rightRounded ? cap : Radius.zero,
  );

  /// A horizontal ALPHA mask holding opaque and dissolving to nothing
  /// across the run approaching each CUT end, so the square edge never
  /// reads as a drawn edge (截断端渐隐). The band's real colour never
  /// rides inside the gradient: translucent gradient stops come out of
  /// the renderer at their alpha SQUARED (D3 反馈八复验: a tinted
  /// gradient washed the whole pill to α², nearly invisible), so the
  /// mask is white-to-transparent — squared to itself at the stops —
  /// and is applied over the flat paint through BlendMode.dstIn inside
  /// a saveLayer. Each side's run is the cap's radius, clamped to a
  /// third of [bounds] (a narrow band keeps some ink) and — when the
  /// opposite end is ROUNDED — to one pixel SHORT of that cap's own flat
  /// edge: a rounded end is always one continuous semicircle (反馈七终
  /// 案), the dissolve never eats into it, and a pixel of SOLID fill
  /// separates the ramp's end from the arc's start (2026-09-10 look-
  /// tuning: the ramp holds its length while the cap start walks right).
  /// (F23 round, 反馈十八: the
  /// parking stub after a trailing 回车 is cut on its left and its
  /// right end IS the cap — the ramp washed the arc's left half away
  /// and it read discontinuous until characters pushed the cap clear;
  /// the stub's flat run is a fraction of a pixel, so its cut side
  /// keeps a solid square edge). Null when no end is cut or neither run
  /// survives the clamps: a complete pill paints its flat colour as-is.
  Shader? cutFadeMask(Rect bounds) {
    final fadeLeft = !leftRounded;
    final fadeRight = !rightRounded;
    if (!fadeLeft && !fadeRight) return null;
    final width = bounds.width;
    final cap = SlotSurfaceState.capsuleHeight / 2;
    double runFor(bool fade, bool oppositeRounded) => fade
        ? math.min(
            math.min(cap, width / 3),
            oppositeRounded ? math.max(0, width - cap - 1) : width,
          )
        : 0.0;
    final leftRun = runFor(fadeLeft, rightRounded);
    final rightRun = runFor(fadeRight, leftRounded);
    if (leftRun <= 0 && rightRun <= 0) return null;
    final fLeft = leftRun / width;
    final fRight = rightRun / width;
    const opaque = Color(0xFFFFFFFF);
    const gone = Color(0x00FFFFFF);
    if (fadeLeft && fadeRight) {
      return LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [gone, opaque, opaque, gone],
        stops: [0, fLeft, 1 - fRight, 1],
      ).createShader(bounds);
    }
    if (fadeLeft) {
      return LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [gone, opaque, opaque],
        stops: [0, fLeft, 1],
      ).createShader(bounds);
    }
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [opaque, opaque, gone],
      stops: [0, 1 - fRight, 1],
    ).createShader(bounds);
  }
}

/// Paints [paint]'s shape, then — when the band has a cut end —
/// confines it with the cut-fade mask: the flat colour first inside a
/// saveLayer, then the alpha gradient over the WHOLE layer rectangle
/// through dstIn. The mask is a plain rect inflated past every edge of
/// the band's ink — a mask sharing the shape's own boundary multiplies
/// its AA against the ink's (a stroked band lost the outer half of
/// its outline along the whole run on hardware), while the rect's
/// α=1 plateau reaches every pixel of the band untouched and only the
/// horizontal ramp toward the cut modulates it. Shared by both faces'
/// pill layers (the preview's and the stream's, 29 号票).
void paintFadedBand(Canvas canvas, CapsuleBand band, RRect shape, Paint paint) {
  final mask = band.cutFadeMask(shape.outerRect);
  if (mask == null) {
    canvas.drawRRect(shape, paint);
    return;
  }
  final layer = shape.outerRect.inflate(1);
  canvas.saveLayer(layer, Paint());
  canvas.drawRRect(shape, paint);
  canvas.drawRect(
    layer,
    Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = mask,
  );
  canvas.restore();
}

/// Paints the stream face's number circles and capsule digits
/// (listening / rectifying): each bare sentinel's spacer reservation
/// carries a flat circle — the family's own degenerate capsule
/// (2026-09-09 反馈九), placed inside the reservation by the same edge
/// and anchor strategy the preview's pills use, in the layout's own
/// frame (号圆; 21 号票家族, 23 号验收轮改绘). Each INLINE form's pill
/// is painted under the text by [_StreamPillPainter]; this layer adds
/// the number digits onto its left cap — the same geometry the pill
/// layer drew, so the digits can never disagree with the pill's
/// placement (29 号票: the growing capsule IS the family's capsule).
class _StreamCapsulesPainter extends CustomPainter {
  _StreamCapsulesPainter(this.state, this.pal);

  final SlotSurfaceState state;
  final SrPalette pal;

  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in state._streamCircleRects().entries) {
      final rect = entry.value;
      // The flat family: fill only — no border, no shadow; one digit a
      // true circle, wider numbers a capsule.
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
        Paint()..color = pal.accentSoft,
      );
      final digits = TextPainter(
        text: TextSpan(
          text: '${entry.key}',
          style: SrType.micro.copyWith(color: pal.accentText, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      digits.paint(
        canvas,
        rect.center - Offset(digits.width / 2, digits.height / 2),
      );
    }
    // The inline capsules' number digits, centered on each pill's left
    // cap circle — the same geometry the pill layer drew, so the digits
    // can never disagree with the pill's placement (号数绝对定位于左
    // 端切圆圆心,08 号票; the chip widget itself is a bare spacer).
    for (final entry in state._streamCapsuleBands().entries) {
      final first = entry.value.first;
      final digits = TextPainter(
        text: TextSpan(
          text: '${entry.key}',
          style: SrType.micro.copyWith(color: pal.accentText, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      digits.paint(
        canvas,
        Offset(
          first.rect.left +
              SlotSurfaceState.capsuleHeight / 2 -
              digits.width / 2,
          first.rect.center.dy - digits.height / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_StreamCapsulesPainter old) => true;
}

/// Paints under the stream text: the INLINE capsules' pills (flat
/// family: fill only, the cut-fade included) — the same band shape the
/// preview's [_BackgroundPainter] draws, over the stream's own flat
/// projection. The bare sentinels' circles are the foreground layer's
/// (they sit ON their reservations, not around text); a pill must sit
/// UNDER the value it grows around (29 号票).
class _StreamPillPainter extends CustomPainter {
  _StreamPillPainter(this.state, this.pal);

  final SlotSurfaceState state;
  final SrPalette pal;

  @override
  void paint(Canvas canvas, Size size) {
    final pillRadius = Radius.circular(SlotSurfaceState.capsuleHeight / 2);
    for (final entry in state._streamCapsuleBands().entries) {
      for (final band in entry.value) {
        paintFadedBand(
          canvas,
          band,
          band.shape(pillRadius),
          Paint()..color = pal.accentSoft,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_StreamPillPainter old) => true;
}

/// Paints under the text: the capsule pills (flat family: fill only) and
/// the selection (height-clamped, never above the capsule).
class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter(this.state, this.pal)
    : super(repaint: Listenable.merge([state._blink, state._activeFade]));

  final SlotSurfaceState state;
  final SrPalette pal;

  /// Paints [paint]'s shape — see [paintFadedBand].
  void _paintFadedBand(
    Canvas canvas,
    CapsuleBand band,
    RRect shape,
    Paint paint,
  ) => paintFadedBand(canvas, band, shape, paint);

  @override
  void paint(Canvas canvas, Size size) {
    final bandsById = state._capsuleBands();
    // Pills first: the selection may tint over them, never under. Every
    // covered line is its own band — rounded caps on the capsule's
    // natural ends, square edges where the wrapper cut it (截断直角),
    // their ink dissolving away as it approaches the cut (截断端渐隐).
    final pillRadius = Radius.circular(SlotSurfaceState.capsuleHeight / 2);
    for (final entry in bandsById.entries) {
      for (final band in entry.value) {
        _paintFadedBand(
          canvas,
          band,
          band.shape(pillRadius),
          Paint()..color = pal.accentSoft,
        );
      }
    }
    // The active capsule's stroke, fading in and out (点按 = 选中编辑态),
    // tracing the fill's own shape.
    final active = state._activeId;
    if (active != null && state._activeFade.value > 0) {
      for (final band in bandsById[active] ?? const <CapsuleBand>[]) {
        final shape = band.shape(pillRadius, inflate: 0.5);
        // The stroke dissolves toward a cut end with its fill, so the
        // outline never draws the edge the fill just hid.
        _paintFadedBand(
          canvas,
          band,
          shape,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = pal.accent.withValues(
              alpha: 0.8 * state._activeFade.value,
            ),
        );
      }
    }
    // Selection over the pills, clamped below the capsule height and
    // centered on each line's ink box (the pills' own anchor).
    final selection = state._selectionPaintRange;
    if (selection != null) {
      final paragraph = state._paragraph;
      if (paragraph != null) {
        final lines = state._lineInkBoxes(paragraph);
        for (final box in paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: selection.baseOffset,
            extentOffset: selection.extentOffset,
          ),
        )) {
          final center = state._inkCenter(lines, box.toRect().center.dy);
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
    // The capsules' number digits, centered on each pill's left cap
    // circle — the same geometry the pill layer drew, so the digits can
    // never disagree with the pill's placement (号数绝对定位于左端切圆
    // 圆心,08 号票; the chip widget itself is a bare spacer).
    for (final entry in state._capsuleSegments().entries) {
      final first = entry.value.first;
      final digits = TextPainter(
        text: TextSpan(
          text: '${entry.key}',
          style: SrType.micro.copyWith(color: pal.accentText, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      digits.paint(
        canvas,
        Offset(
          first.left + SlotSurfaceState.capsuleHeight / 2 - digits.width / 2,
          first.center.dy - digits.height / 2,
        ),
      );
    }
    // Slot hover tooltip: one hint for every capsule in every state —
    // prefill or not, emptied or edited (2026-09-09 user decision; the
    // per-prefill wording 预填:X/预填为空 is retired).
    final tooltip = state._tooltipId;
    if (tooltip != null) {
      final segments = state._capsuleSegments()[tooltip];
      if (segments != null && segments.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: '编辑占位内容',
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
