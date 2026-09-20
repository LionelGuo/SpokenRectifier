/// The session panel: one continuous surface evolving live transcript ->
/// streaming rectify -> preview (修正≡预览同形, only the affordances
/// differ). The text region is the self-drawn slot surface family
/// (ticket 22): read-only capsules while streaming, the editable
/// fill-capsule document the moment the stream completes — what you see
/// is what gets inserted.

library;

import 'dart:async';

// GrowthDirection hidden: the framework exports its own (a sliver
// token); this panel's is the orb-geometry one via window_stage.
import 'package:flutter/material.dart' hide GrowthDirection;

import '../../app_state.dart';
import '../design/toast.dart';
import '../design/tokens.dart';
import '../preview/slot_document.dart';
import '../preview/slot_editor.dart';
import '../preview/slot_surface.dart';
import '../rust/api.dart' show BridgeSessionState;
import '../shell/history_retrieval.dart'
    show DefaultRegisterPick, NamedScenarioPick;
import '../shell/window_stage.dart';

class SessionPanel extends StatefulWidget {
  const SessionPanel({
    super.key,
    required this.controller,
    required this.exiting,
    required this.form,
  });

  final SpeechController controller;
  final bool exiting;

  /// The quadrant form (12 号票): the per-axis values every chrome
  /// obligation derives from — reserves, fades, and the footer group's
  /// alignment re-derive continuously as the panel switches corners,
  /// in step with the card (同步、只移不消失).
  final PanelForm form;

  @override
  State<SessionPanel> createState() => _SessionPanelState();
}

class _SessionPanelState extends State<SessionPanel> {
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Timer? _tick;
  int _toastedErrorSeq = 0;

  SpeechController get c => widget.controller;

  bool get _isPreview => c.phase == BridgeSessionState.preview;
  bool _wasPreview = false;

  /// The preview round's slot document and editor (ticket 22). One
  /// document lives for one preview session: the value map survives
  /// rerolls within it (值挂钉不挂轮, 13 号票) and dies when the phase
  /// leaves the active session states. Null outside a preview session —
  /// the stream branches need no model.
  SlotDocument? _doc;
  SlotEditor? _editor;

  /// Bumped on every preview entry; remounts the editing surface so each
  /// round starts with fresh IME and composing state.
  int _round = 0;

  /// Whether the 对照原文 comparison block is expanded (panel-local UI
  /// state; nothing else reads it).
  bool _showTranscript = false;

  /// The footer's button sets, minted once (stable identities: the group
  /// re-measures only when the set — or the text scale — actually
  /// changes). Preview carries the full three; recording the lone cancel
  /// (Esc's twin — 窗底取消文字钮), which never crosses the guard line in
  /// practice (组宽 ≤98, 13 号票).
  late final List<_FooterSpec> _previewFooter = [
    _FooterSpec(
      key: const Key('session-raw-toggle'),
      icon: Icons.compare_arrows_rounded,
      label: '对照原文',
      onTap: _toggleTranscript,
    ),
    _FooterSpec(
      key: const Key('session-reroll'),
      icon: Icons.refresh_rounded,
      label: '重新生成',
      onTap: c.reroll,
    ),
    _FooterSpec(
      key: const Key('session-cancel'),
      icon: Icons.close_rounded,
      label: '取消',
      kbd: 'Esc',
      onTap: c.escapeAction,
    ),
  ];
  late final List<_FooterSpec> _recordingFooter = [
    _FooterSpec(
      key: const Key('session-cancel'),
      icon: Icons.close_rounded,
      label: '取消',
      kbd: 'Esc',
      onTap: c.escapeAction,
    ),
  ];

  void _toggleTranscript() =>
      setState(() => _showTranscript = !_showTranscript);

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _toastPendingError();
    });
    _wasPreview = c.phase == BridgeSessionState.preview;
    if (_wasPreview) _enterPreview();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (c.phase == BridgeSessionState.recording && mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(SessionPanel old) {
    super.didUpdateWidget(old);
    if (widget.exiting && !old.exiting) {
      _focus.unfocus();
    }
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    _tick?.cancel();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    _toastPendingError();
    if (!_wasPreview && _isPreview) {
      _enterPreview();
    } else if (_wasPreview && !_isPreview) {
      _wasPreview = false;
      // The session's terminal states (inserted / cancelled / idle) end
      // the preview session: the value map and the undo stacks die with
      // it (会话结束栈与值 map 一起消亡, 14 号票). Rectifying — a reroll
      // in flight — keeps them for the retention rules.
      switch (c.phase) {
        case BridgeSessionState.inserted ||
            BridgeSessionState.cancelled ||
            BridgeSessionState.idle:
          _doc = null;
          _editor = null;
        default:
          break;
      }
    }
    setState(() {});
  }

  /// A new [SpeechController.lastError] while this panel is up rides
  /// the stage-slot toast (the inline error row is retired).
  void _toastPendingError() {
    final seq = c.lastErrorSeq;
    final message = c.lastError;
    if (seq == _toastedErrorSeq || message == null) return;
    _toastedErrorSeq = seq;
    SrToast.of(context).show(message, tone: SrToastTone.error);
  }

  /// A round of rectified text has arrived: mint the identities, adopt
  /// the prefills as initial values, raise the undo barrier (19 号票),
  /// hand the keyboard to the editing surface, and adopt the substituted
  /// text as the on-screen preview — what any confirm path would insert.
  void _enterPreview() {
    _wasPreview = true;
    final prefill = {for (final row in c.prefillTable) row.number: row.value};
    if (_doc == null) {
      _doc = SlotDocument();
      _editor = SlotEditor(_doc!);
    }
    _editor!.arrive(c.previewText, prefill);
    _round += 1;
    // The focus request must wait for the editing surface to mount: the
    // node is detached at this listener's moment (the branch builds this
    // frame), and a request against a detached node is dropped.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && c.phase == BridgeSessionState.preview) {
        _focus.requestFocus();
      }
    });
    // Adopt the substituted text as the on-screen preview — but only
    // push when it differs from what the engine just streamed: a
    // pin-less round substitutes to itself, and the push would only arm
    // a pointless debounce (无钉会话零影响).
    final substituted = _doc!.substitute();
    if (substituted != c.previewText) {
      c.editPreviewText(substituted);
    }
  }

  /// The editing surface reports a model change: adopt the substituted
  /// text (the debounced engine push rides the controller's own path).
  void _onSlotChanged(String substituted) {
    c.editPreviewText(substituted);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    // The header row is display-only (02 号票 abolished the header move
    // grip — the anchor button is the panel's one move affordance).
    final header = _header(context, pal);
    return PanelBody(
      exiting: widget.exiting,
      form: widget.form,
      // The pinned top band (钉边裁切): the header row plus its divider
      // ride the card's current visual top as it grows out of the disc.
      header: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Divider(height: 1, thickness: 1, color: pal.hairline),
        ],
      ),
      // The middle: whatever height is left between the bands, clipped
      // to it while the card is still growing. The transcript block is
      // loose-flexible (and flexible inside) so the exit cramp clips it
      // instead of reporting an overflow.
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _textArea(context, pal)),
          Flexible(fit: FlexFit.loose, child: _transcriptSection(context, pal)),
        ],
      ),
      // The pinned bottom band: rides the card's current visual bottom.
      footer: _footer(context, pal),
    );
  }

  Widget _header(BuildContext context, SrPalette pal) {
    final (label, dotColor, live) = switch (c.phase) {
      // Upgrade keeps the recording-red breath (ADR-0020); only the
      // word flips. Rectifying and Preview (incl. a failed demotion)
      // ignore the flag — the engine has already cleared it.
      BridgeSessionState.recording => (
        c.quickMarked ? '快速' : '聆听中',
        pal.live,
        true,
      ),
      BridgeSessionState.rectifying => ('修正中', pal.accent, false),
      _ => ('预览', pal.success, false),
    };
    final elapsed = _formatElapsed(c.recordElapsed);
    // The 场景 chip's label: a one-time pick paints its own name — 默认
    // included (ticket 28), so an explicit default session never
    // masquerades as the selection — otherwise the live selection, or
    // 默认 when nothing is selected.
    final scenario = switch (c.oneTimeStyle) {
      NamedScenarioPick(:final name) => name,
      DefaultRegisterPick() => '默认',
      null => c.selectedScenario ?? '默认',
    };
    return AnimatedBuilder(
      // The header hands its orb-side reserve over continuously (12
      // 号票): both reserves always mounted, their widths scaling with
      // the form — the phase cluster between them TRANSLATES as the
      // weights trade (整簇平移让位), it never disappears.
      animation: widget.form,
      builder: (context, _) => Padding(
        // Corner-band row: aligns to the concentric content capsule
        // (SrSpace.cornerInset). Vertical 20 puts the 16px title's visual
        // top (~24) on the capsule's D=16 arc.
        padding: const EdgeInsets.fromLTRB(
          SrSpace.cornerInset,
          20,
          SrSpace.cornerInset,
          SrSpace.md,
        ),
        child: Row(
          children: [
            // 左上 (downRight) full weight: the orb owns this row's
            // start — the phase cluster yields as one unit (让位按簇:
            // the reserve is a row-edge placeholder, never inserted
            // inside the cluster).
            SizedBox(width: widget.form.headerReserve(leading: true)),
            _PhaseDot(color: dotColor, live: live),
            const SizedBox(width: SrSpace.sm),
            Text(label, style: SrType.body.copyWith(color: pal.textPrimary)),
            if (c.phase == BridgeSessionState.recording) ...[
              const SizedBox(width: SrSpace.sm),
              Text(
                elapsed,
                style: SrType.micro.copyWith(color: pal.textTertiary),
              ),
            ],
            // A picker over an empty library has nothing to pick between:
            // the chip hides until the settings editor fills one in. A
            // one-time pick session (ticket 23's scenario, ticket 28's
            // 默认) paints the same shape with that pick's name — same
            // format, no special badge. 右上 squeezes this row from the
            // end (行尾 56): the chip single-line-ellipsizes (场景 · …)
            // instead of overflowing — the Align keeps it at the row end
            // and lets it shrink only when the space runs out.
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: c.scenarios.isNotEmpty
                    ? _ScenarioChip(label: '场景 · $scenario')
                    : const SizedBox.shrink(),
              ),
            ),
            // 右上 (downLeft) full weight: the orb owns this row's end —
            // the header reserve (56, not the footer's 48: the recording
            // ring extends 6px past the ball and must clear the chip;
            // spec §3 义务层).
            SizedBox(width: widget.form.headerReserve(leading: false)),
          ],
        ),
      ),
    );
  }

  Widget _textArea(BuildContext context, SrPalette pal) {
    final recording = c.phase == BridgeSessionState.recording;
    final editor = _editor;
    final previewing = _isPreview && editor != null;
    // The measuring surface subtree stays STABLE while the form
    // animates — only the padding and the fade wrap re-build per tick
    // (the H3 re-measure tax).
    final content = Stack(
      children: [
        if (recording && c.liveText.isEmpty)
          Text(
            '开始说话…',
            style: SrType.bodyLarge.copyWith(color: pal.textTertiary),
          ),
        if (previewing)
          // The editable preview (ticket 22): the self-drawn fill
          // capsule surface over the slot document. Each round
          // bumps the reset token; edits adopt their substituted
          // text at once.
          SingleChildScrollView(
            controller: _scroll,
            child: SlotSurface(
              key: const Key('session-text'),
              mode: SlotSurfaceMode.preview,
              editor: editor,
              focusNode: _focus,
              scrollController: _scroll,
              resetToken: _round,
              onChanged: _onSlotChanged,
            ),
          )
        else
          // The read-only stream surface (listening / rectifying):
          // sentinels render as capsules — the bare `‡N‡` never
          // shows on the main surface (ticket 21). Rectifying
          // reads the same projection, so sentinels appearing
          // mid-stream collapse into capsules the moment their
          // shape completes.
          SlotSurface(
            key: const Key('session-stream'),
            mode: SlotSurfaceMode.stream,
            text: recording ? c.liveText : c.previewText,
            streamStyle: SrType.bodyLarge.copyWith(
              color: recording ? pal.textSecondary : pal.textPrimary,
            ),
            scrollController: _scroll,
          ),
      ],
    );
    // Top-anchored orb (右上/左上): the ball's lower half rides over
    // this region — the body keeps a 48 top padding (scrolled to top,
    // the first line rests exactly at the fade's lower edge) under a
    // surface-colored fade that dissolves arriving content into the
    // card below the header (锚边渐隐, spec §3). Bottom-anchored orb: no
    // body fade — the footer row plus its 48 reserve carry the bottom
    // edge. Both interpolate continuously with the form (12 号票); the
    // fade hands over by OPACITY — surface over surface, the one
    // "disappearance" that is not a control.
    return AnimatedBuilder(
      animation: widget.form,
      child: content,
      builder: (context, inner) => Stack(
        children: [
          Positioned.fill(
            child: Padding(
              // Straight-edge body content: contentInset (below the
              // corner band); the top rides the form (12 ↔ 48).
              padding: EdgeInsets.fromLTRB(
                SrSpace.contentInset,
                widget.form.bodyTopPad,
                SrSpace.contentInset,
                SrSpace.sm,
              ),
              child: inner!,
            ),
          ),
          if (widget.form.gu < 0.999)
            // Full-width, flush under the header row: opaque surface at
            // the top dissolving to transparent 48 in (the bottom
            // fade's mirror). The orb (stage layer) paints above it and
            // stays crisp; content under the fade is inert to the
            // pointer.
            Positioned(
              key: const Key('session-top-fade'),
              left: 0,
              right: 0,
              top: 0,
              height: SrGeometry.anchorInset,
              child: IgnorePointer(
                child: Opacity(
                  opacity: (1 - widget.form.gu).clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          pal.surface,
                          pal.surface,
                          pal.surface.withValues(alpha: 0),
                        ],
                        stops: const [0.0, 0.25, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _transcriptSection(BuildContext context, SrPalette pal) {
    return AnimatedSize(
      duration: SrMotion.emphasize,
      curve: SrMotion.curveEmphasized,
      alignment: Alignment.bottomCenter,
      child: _showTranscript && c.phase != BridgeSessionState.recording
          ? Container(
              key: const Key('session-raw'),
              margin: const EdgeInsets.fromLTRB(
                SrSpace.contentInset,
                0,
                SrSpace.contentInset,
                SrSpace.sm,
              ),
              padding: const EdgeInsets.all(SrSpace.md),
              decoration: BoxDecoration(
                color: pal.surfaceRaised,
                borderRadius: BorderRadius.circular(SrRadius.control),
                border: Border.all(color: pal.hairline),
              ),
              constraints: const BoxConstraints(maxHeight: 140),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // All-flexible so the exit cramp (the card shrinking
                  // under the open block) clips instead of overflowing.
                  Flexible(
                    child: Text(
                      '原始转写',
                      style: SrType.micro.copyWith(color: pal.textTertiary),
                    ),
                  ),
                  const Flexible(child: SizedBox(height: SrSpace.xs)),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Text(
                        c.liveText.isEmpty ? '（无）' : c.liveText,
                        key: const Key('session-raw-text'),
                        style: SrType.caption.copyWith(
                          color: pal.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _footer(BuildContext context, SrPalette pal) {
    return AnimatedBuilder(
      // The footer hands its reserve and the group's alignment over
      // continuously (12 号票): the whole button group SLIDES across the
      // row as the form changes sides (整组横滑换对齐), passing under the
      // ball where the paths cross — never unmounted, ORDER frozen.
      animation: widget.form,
      builder: (context, _) => ClipPath(
        // 20 号票: the band's ONE clip is the anchor ball's own
        // silhouette — a racing tail disappears into the ball's arc
        // (藏进球下), never sliced by a container edge. The clipper's
        // doc tells the full story.
        key: const Key('footer-ball-occlusion'),
        clipper: _BallOcclusionClipper(
          ballRight: widget.form.gl > 0.5,
          weight: widget.form.gu,
        ),
        child: Padding(
          // Corner-band row (bottom-left arc): cornerInset horizontal;
          // the vertical 20 keeps the buttons' visual bottom inside the
          // capsule.
          padding: const EdgeInsets.fromLTRB(
            SrSpace.cornerInset,
            SrSpace.xs,
            SrSpace.cornerInset,
            20,
          ),
          child: Row(
            children: [
              // 左下 (upRight) full weight: the orb owns this row's start —
              // one anchorInset, not two: the ball's right edge sits
              // anchorInset + orbBall/2 = 76 from the window's left edge,
              // while this row's content starts cardMargin + hairline +
              // cornerInset = 33 from it — the true overlap is 43, and 48
              // keeps a 5px gap. The header's twin keeps 56 instead (the
              // recording ring's reach; the footer band never carries one).
              SizedBox(width: widget.form.footerReserve(leading: true)),
              // Capsules while the band fits them, icon-only circles once
              // the guard line is crossed — ONE shared morph (13 号票) that
              // retires 小修 10's permanent hard clip. 左下 alone
              // right-aligns the group (仅左下底栏钮组右对齐: the orb holds
              // the row's start, the buttons yield to the far side — their
              // ORDER stays frozen, 对照 → 重新生成 → 取消).
              Expanded(
                child: _FooterGroup(
                  pal: pal,
                  form: widget.form,
                  specs: _isPreview ? _previewFooter : _recordingFooter,
                ),
              ),
              // 右下 (upLeft) full weight: the orb button lives here, above
              // this row's end. Top-anchored orbs (右上/左上) carry no
              // reserve in the footer at all — the ball shares the HEADER's
              // row there, and obligations follow the anchor's edge only
              // (义务随锚点角走).
              SizedBox(width: widget.form.footerReserve(leading: false)),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatElapsed(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Pulsing state dot in the header.
class _PhaseDot extends StatefulWidget {
  const _PhaseDot({required this.color, required this.live});

  final Color color;
  final bool live;

  @override
  State<_PhaseDot> createState() => _PhaseDotState();
}

class _PhaseDotState extends State<_PhaseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: SrMotion.breathe,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.live) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
      );
    }
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: 0.5 + _ctrl.value * 0.5),
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.4 * _ctrl.value),
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }
}

// ---- footer morph: capsule ⇄ circle (13 号票 / 03 prototype) --------------

/// The morph's geometry constants — deliberately NOT SrMotion tokens (03
/// 号票: they only ever participate in this one dance). The ladder
/// parameter t runs 1 (capsule) → 0.30 (circle); everything below 0.30
/// is geometrically dead, so the flight never goes there:
///
/// 1 → 0.45        the bloom / gather: the label and the Esc chip fade
///                 (band 0.9 → 0.45) WHILE tucking 6px toward the icon —
///                 the CONTENT channel alone; every group geometry
///                 (button widths, gaps) is frozen here (19 号票 五轮:
///                 a gap stage ahead of the width stage read as two
///                 stitched animations even with the text invisible)
/// 0.45 → 0.30     the width collapses to the circle (diameter = the
///                 button's own height, ≈29), eating the RIGHT side
///                 only — the icon's inset from the left border is
///                 CONSTANT at the capsule pad through the entire morph
///                 (三轮真机裁定). The inter-button gaps 8→4 ride this
///                 SAME window, proportional to the width — the group's
///                 envelope is one continuous squeeze, not a gap stage
///                 followed by a width stage (五轮真机裁定)
///
/// Layout only shrinks AFTER the text's opacity has reached zero — text
/// is faded out, never clipped. The tuck rides a Transform (layout
/// untouched), so it can never clip either.
///
/// Both arms render the SAME constant height (the measured 28.8 + the
/// hairline border) — nothing moves vertically through the flight (四轮
/// 真机: the capsule arm's intrinsic height used to step into the
/// circle's pinned one at the swap, twitching the whole band).
const _footerGuardPad = 24.0;
const _tTextShown = 0.9;
const _tTextGone = 0.45;
const _tRoundDone = 0.3;
const _padCapsule = 8.0;
const _gapCapsule = 8.0;
const _gapRound = 4.0;
const _footerIcon = 14.0;

/// The bloom's slide distance — the inter-content gap doubling as the
/// tuck: at zero opacity the label sits flush against its neighbour,
/// fully inside the button (no overflow, no clip).
const _tuckSlide = 6.0;

/// The fraction of [t] inside the band [lo, hi], clamped to 0–1.
double _seg(double t, double lo, double hi) =>
    ((t - lo) / (hi - lo)).clamp(0.0, 1.0);

double _lerp(double a, double b, double u) => a + (b - a) * u;

/// The expand flight's map u → t (19 号票 二轮): the width pops open on
/// [curveEnter] over the first 40%, then the content blooms on
/// [curveFade] for the remaining 60% — fade + tuck. Both curves arrive
/// at the handoff at ZERO velocity, so the phase change is a soft
/// hinge, not a splice. (五轮: the group's gaps ride the width phase —
/// geometry in ONE window, content in the other.)
double _tExpand(double u) {
  if (u < 0.40) {
    return _lerp(
      _tRoundDone,
      _tTextGone,
      SrMotion.curveEnter.transform(u / 0.40),
    );
  }
  return _lerp(
    _tTextGone,
    1.0,
    SrMotion.curveFade.transform((u - 0.40) / 0.60),
  );
}

/// The collapse flight's map: the mirror — gather on [curveFade] over
/// the first 60% (fade + tuck, the content channel), then the width
/// falls into the circle on [curveFade] (the group's gaps tightening
/// with it, proportional), landing at rest.
double _tCollapse(double u) {
  if (u < 0.60) {
    return _lerp(1.0, _tTextGone, SrMotion.curveFade.transform(u / 0.60));
  }
  return _lerp(
    _tTextGone,
    _tRoundDone,
    SrMotion.curveFade.transform((u - 0.60) / 0.40),
  );
}

/// One flight, fixed direction — the controller's u drives [_tExpand]
/// or [_tCollapse] directly (flips only launch from a parked endpoint,
/// so the map's u = 0 value always equals the parked state).
class _FlightMap extends Animatable<double> {
  const _FlightMap({required this.expand});

  final bool expand;

  @override
  double transform(double u) => expand ? _tExpand(u) : _tCollapse(u);
}

/// One footer button's capsule-state spec. The group owns the specs so it
/// can measure the group's natural width analytically — the guard line
/// must be known even while the group rests in circle state, where no
/// capsule is mounted to measure.
class _FooterSpec {
  const _FooterSpec({
    required this.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.kbd,
  });

  final Key key;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// The optional key hint — painted as the capsule's kbd chip, folded
  /// into the circle state's tooltip.
  final String? kbd;
}

/// The group's capsule-state measurements. Analytic on purpose: the same
/// TextPainter machinery the Text widgets lay out through, so the numbers
/// match the real layout at any font / text scale — no post-frame probing.
class _FooterMetrics {
  _FooterMetrics({required this.buttonWidths, required this.height})
    : natural =
          buttonWidths.fold(0.0, (a, w) => a + w) +
          _gapCapsule * (buttonWidths.length - 1);

  /// Each button's natural capsule width (padding 8, full row).
  final List<double> buttonWidths;

  /// The constant button height — also the circle's diameter (钮高 ≈29:
  /// vertical padding 12 over the caption's 16.8 line). BOTH arms pin
  /// it: the capsule arm's intrinsic tallest line box (the kbd chip's
  /// 17.2) sits a hair above and would step the band at the swap.
  final double height;

  /// G1: the group's natural capsule width.
  final double natural;

  /// The flip line, both directions the SAME line — a band that flips
  /// down inside and up outside is an ANTI-hysteresis and oscillates (the
  /// prototype's smoke run caught exactly that); debounce duty belongs to
  /// the busy lock. The 24px guard lets the down-tween beat a fast drag
  /// past the real overflow point (G1) instead of clipping mid-flight.
  double get guard => natural + _footerGuardPad;
}

_FooterMetrics _measureFooter(BuildContext context, List<_FooterSpec> specs) {
  double textWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: MediaQuery.textScalerOf(context),
      // The labels are CJK-first with latin key hints; the footer row
      // reads left-to-right in both locales.
      textDirection: TextDirection.ltr,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }

  final style = SrType.caption;
  return _FooterMetrics(
    buttonWidths: [
      for (final s in specs)
        // The row the capsule wraps — icon + 6 + label (+ 6 + the chip's
        // own 5×2 + its text) — plus the 8px horizontal padding twice.
        _padCapsule * 2 +
            _footerIcon +
            6 +
            textWidth(s.label, style) +
            (s.kbd != null ? 6 + 10 + textWidth(s.kbd!, SrType.kbd) : 0),
    ],
    height: 6 * 2 + style.fontSize! * style.height!,
  );
}

/// The session footer's button group: capsules while the band's available
/// width fits them, icon-only circles once the guard line is crossed —
/// ONE shared morph, every button riding the same t (13 号票). The whole
/// group slides with the form's alignment (整组横滑换对齐, 12 号票); the
/// buttons never unmount and their order is frozen.
class _FooterGroup extends StatefulWidget {
  const _FooterGroup({
    required this.pal,
    required this.form,
    required this.specs,
  });

  final SrPalette pal;
  final PanelForm form;

  /// The button set (preview: three; recording: the lone cancel — same
  /// function, the narrower group never crosses the guard in practice).
  final List<_FooterSpec> specs;

  @override
  State<_FooterGroup> createState() => _FooterGroupState();
}

class _FooterGroupState extends State<_FooterGroup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: SrMotion.emphasize,
  );

  /// The one-shot flight (t: 1 = capsule … 0.30 = circle). At rest the
  /// controller parks and the map's u = 0 value IS the resting state —
  /// a flip only launches from the parked endpoint, and its map starts
  /// exactly there, so nothing ever jumps.
  Animatable<double> _ladder = const _FlightMap(expand: true);

  /// The available width the guard last saw. The completion re-check
  /// re-evaluates against it: a crossing that arrives mid-flight lands
  /// when the flight lands, never mid-air (the busy lock).
  double? _lastA;
  bool _evalPending = false;

  List<_FooterSpec>? _measuredSpecs;
  TextScaler _measuredScale = TextScaler.noScaling;
  late _FooterMetrics _metrics;

  @override
  void initState() {
    super.initState();
    _morph.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      final a = _lastA; // the busy lock just released
      if (a != null) _evaluate(a);
    });
  }

  @override
  void didUpdateWidget(_FooterGroup old) {
    super.didUpdateWidget(old);
    // The phase swapped the button set (preview ⇄ recording): re-measure
    // and re-judge the same width — the wider preview group may cross a
    // line the lone cancel never could.
    if (!identical(old.specs, widget.specs)) {
      final a = _lastA;
      if (a != null) _scheduleEvaluate(a);
    }
  }

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
  }

  double get _t => _ladder.transform(_morph.value);

  void _evaluate(double available) {
    _lastA = available;
    if (_morph.isAnimating) return; // 忙锁: in flight, no re-flip
    final fits = available >= _metrics.guard;
    if (fits == (_t > 0.5)) return;
    // One flight per crossing, its own shaped map per direction (19 号
    // 票 二轮): each phase decelerates into the handoff — a splice at
    // full speed read as two animations stitched together.
    _ladder = _FlightMap(expand: fits);
    _morph.forward(from: 0);
  }

  /// Defer the threshold check to the frame's end: the LayoutBuilder runs
  /// in the layout phase, and starting the tween from there would notify
  /// builders mid-layout.
  void _scheduleEvaluate(double available) {
    _lastA = available;
    if (_evalPending) return;
    _evalPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _evalPending = false;
      if (!mounted) return;
      _evaluate(_lastA!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    if (!identical(_measuredSpecs, widget.specs) || scale != _measuredScale) {
      _metrics = _measureFooter(context, widget.specs);
      _measuredSpecs = widget.specs;
      _measuredScale = scale;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final a = constraints.maxWidth;
        if (_lastA == null) {
          // First layout: rest in the state this width says — the
          // entrance sweep must START settled (the up-flip at the guard
          // is the sweep's own doing, never a mount flash).
          _lastA = a;
          final capsule = a >= _metrics.guard;
          final t0 = capsule ? 1.0 : _tRoundDone;
          _ladder = Tween<double>(begin: t0, end: t0);
        } else {
          _scheduleEvaluate(a);
        }
        return AnimatedBuilder(
          animation: _morph,
          builder: (context, _) {
            final t = _t;
            // 五轮真机: the gaps ride the SAME window as the width
            // collapse, proportional to it — the group's envelope moves
            // in ONE continuous squeeze. Tightening them across the
            // gather instead split the geometry into two stages (a tiny
            // gap stage, then the width stage) that read as two
            // stitched animations even with the text camouflaged.
            final gap = _lerp(
              _gapRound,
              _gapCapsule,
              _seg(t, _tRoundDone, _tTextGone),
            );
            return IntrinsicHeight(
              child: OverflowBox(
                alignment: Alignment(widget.form.footerAlignX, 0),
                minWidth: 0,
                maxWidth: double.infinity,
                // 20 号票: no straight clip on the group's own box — a
                // narrowing fast enough to beat the flight left the
                // folding tail hitting this edge mid-panel, a vertical
                // cut that read as a UI container slicing the capsule.
                // The tail now overflows freely toward the anchor ball;
                // the band's ball-occlusion clip (on the footer itself)
                // is the one boundary it can meet — the ball's own arc.
                // (IntrinsicHeight: the band's height is unbounded up
                // here, and an OverflowBox fills whatever it is given.)
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < widget.specs.length; i++) ...[
                      if (i > 0) SizedBox(width: gap),
                      _GhostButton(
                        key: widget.specs[i].key,
                        pal: widget.pal,
                        spec: widget.specs[i],
                        t: t,
                        naturalWidth: _metrics.buttonWidths[i],
                        height: _metrics.height,
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// The footer band's occlusion boundary (20 号票): a narrowing fast
/// enough to outrun the morph's flight leaves the folding group wider
/// than the band for a few frames — and the ONE clip that tail may meet
/// is the anchor ball's own silhouette, so it reads as tucking UNDER
/// the ball instead of being sliced by a container edge. The clip
/// removes the ball's disc (core radius + 2 of seam slop, hidden under
/// the disc's edge) AND everything beyond it on that side — nothing can
/// emerge on the ball's far side. Top-anchored forms carry no ball on
/// this row: the weight (gu, the same weight the footer reserve scales
/// by) fades the notch out with the form, and the card's own rounded
/// clip is the honest stop there.
class _BallOcclusionClipper extends CustomClipper<Path> {
  const _BallOcclusionClipper({required this.ballRight, required this.weight});

  /// The anchor ball owns this row's far end (upLeft: the band's right;
  /// upRight mirrors to the left).
  final bool ballRight;

  /// How much the ball sits on this row at all (0–1).
  final double weight;

  @override
  Path getClip(Size size) {
    final paintable = Path()..addRect(Offset.zero & size);
    final r = (SrGeometry.orbBall / 2 + 2) * weight;
    if (r < 1) return paintable;
    // The ball's center is anchorInset − cardMargin in from the card's
    // corner — the band is bottom-pinned at the card's edge and as wide
    // as the card (the mid-growth width floor can fatten it, but the
    // morph never races then). The cut is the far half-plane from the
    // ball's center PLUS the disc itself, so the exposed boundary is
    // the disc's arc facing the group at every height the buttons span.
    final inset = SrGeometry.anchorInset - SrGeometry.cardMargin;
    final cx = ballRight ? size.width - inset : inset;
    final cy = size.height - inset;
    final cut = Path()
      ..addRect(
        ballRight
            ? Rect.fromLTWH(cx, 0, size.width - cx, size.height)
            : Rect.fromLTWH(0, 0, cx, size.height),
      )
      ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    return Path.combine(PathOperation.difference, paintable, cut);
  }

  @override
  bool shouldReclip(_BallOcclusionClipper old) =>
      old.ballRight != ballRight || (old.weight - weight).abs() > 0.001;
}

/// Ghost (secondary) button — the capsule↔circle morph's rider (13 号
/// 票). The group hands down the shared parameter [t]; the button walks
/// its end of the ladder (bloom → width collapse, icon pinned) and
/// keeps its tap target mounted through all of it.
class _GhostButton extends StatefulWidget {
  const _GhostButton({
    super.key,
    required this.pal,
    required this.spec,
    required this.t,
    required this.naturalWidth,
    required this.height,
  });

  final SrPalette pal;
  final _FooterSpec spec;

  /// The group's shared morph parameter (1 = capsule, 0 = circle).
  final double t;

  /// The capsule's natural width (padding 8) — the collapse lerps from
  /// it (t = 0.45) down to the circle, eating the right side only.
  final double naturalWidth;

  /// The constant button height — also the circle's diameter.
  final double height;

  @override
  State<_GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<_GhostButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final pal = widget.pal;
    final spec = widget.spec;
    final t = widget.t;
    final textOpacity = _seg(t, _tTextGone, _tTextShown);
    // The content tucks 6px toward the icon as it fades (a Transform —
    // layout untouched, nothing to clip): the bloom keeps a direction,
    // continuous with the width move that hands off to it.
    final tuck = Offset(-_tuckSlide * (1 - textOpacity), 0);
    // The width collapse runs only once the text is fully gone (t ≤ 0.45)
    // and finishes at t = 0.30 — layout never squeezes visible ink. It
    // eats the RIGHT side only, from the full natural width down to the
    // circle: the icon's inset from the left border is CONSTANT through
    // the whole morph, pinned at the capsule's own pad (三轮真机裁定 —
    // an icon that drifts from its border mid-flight reads as the
    // capsule deforming, not folding).
    final collapse = 1 - _seg(t, _tRoundDone, _tTextGone);
    final roundWidth = _lerp(widget.naturalWidth, widget.height, collapse);
    final iconAlign = Alignment(
      2 * _padCapsule / (roundWidth - _footerIcon) - 1,
      0,
    );

    // Only the decoration rides an implicit transition (the hover fill);
    // every morphing value — padding, width, content — is driven
    // explicitly by t, tick for tick.
    final button = AnimatedContainer(
      duration: SrMotion.fast,
      decoration: BoxDecoration(
        color: _hover ? pal.surfaceOverlay : pal.surfaceRaised,
        // Capsule: the footer buttons live in the corner band — pill
        // ends echo the concentric corner arc; at the circle width the
        // capsule radius clamps into the circle itself.
        borderRadius: BorderRadius.circular(SrRadius.capsule),
        border: Border.all(color: pal.hairline),
      ),
      child: textOpacity > 0
          ? SizedBox(
              // 四轮真机: pin the capsule arm to the SAME constant height
              // the circle arm pins. Its intrinsic height was the row's
              // tallest line box (the kbd chip's 17.2 over the caption's
              // 16.8) — a hair above the measured 28.8 — so the branch
              // swap stepped the band's height mid-flight, and the raster
              // snapped the sub-pixel twitch into view. Identical boxes
              // in both arms move nothing vertically, by construction.
              height: widget.height,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _padCapsule,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      spec.icon,
                      size: _footerIcon,
                      color: pal.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Transform.translate(
                      offset: tuck,
                      child: Opacity(
                        opacity: textOpacity,
                        child: Text(
                          spec.label,
                          style: SrType.caption.copyWith(
                            color: pal.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    if (spec.kbd != null) ...[
                      const SizedBox(width: 6),
                      Transform.translate(
                        offset: tuck,
                        child: Opacity(
                          opacity: textOpacity,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: pal.surfaceOverlay,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: pal.hairline),
                            ),
                            child: Text(
                              spec.kbd!,
                              style: SrType.kbd.copyWith(
                                color: pal.textTertiary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : SizedBox(
              width: roundWidth,
              height: widget.height,
              child: Align(
                alignment: iconAlign,
                child: Icon(
                  spec.icon,
                  size: _footerIcon,
                  color: pal.textSecondary,
                ),
              ),
            ),
    );

    final body = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: spec.onTap, child: button),
    );

    if (t > _tRoundDone) return body;
    // 圆钮态 tooltip 补全名 (03 号票; 19 号票: the plain label, no key
    // suffix — the （Esc） tail was ruled off on device check): the words
    // live only here once the capsule has folded away.
    return Tooltip(
      message: spec.label,
      waitDuration: SrMotion.tooltipWait,
      child: body,
    );
  }
}

/// The scenario indicator (capsule chip). Selection happens in the tray
/// submenu now and the quick panel from ticket 16; the chip shows what
/// the next rectify (rerolls included) will use.
class _ScenarioChip extends StatelessWidget {
  const _ScenarioChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Container(
      key: const Key('scenario-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: pal.accentSoft,
        // Capsule: a corner-band control (preview-approved).
        borderRadius: BorderRadius.circular(SrRadius.capsule),
      ),
      // Single-line ellipsis (场景 · …) when 右上's row-end reserve
      // squeezes the row — the yield is the chip's, never the cluster's.
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: SrType.micro.copyWith(color: pal.accentText),
      ),
    );
  }
}
