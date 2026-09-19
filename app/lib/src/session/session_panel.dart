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
    required this.dir,
  });

  final SpeechController controller;
  final bool exiting;

  /// Which corner the orb anchors (the anchor button overlaps that
  /// corner's edge row — header or footer depending on growth axis).
  final GrowthDirection dir;

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
      dir: widget.dir,
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
    return Padding(
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
          // 左上 (downRight): the orb owns this row's start — the phase
          // cluster yields as one unit (让位按簇: the reserve is a row-edge
          // placeholder, never inserted inside the cluster).
          if (!widget.dir.growUp && !widget.dir.growLeft)
            const SizedBox(width: SrGeometry.anchorHeaderReserve),
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
          // 右上 (downLeft): the orb owns this row's end — the header
          // reserve (56, not the footer's 48: the recording ring extends
          // 6px past the ball and must clear the chip; spec §3 义务层).
          if (!widget.dir.growUp && widget.dir.growLeft)
            const SizedBox(width: SrGeometry.anchorHeaderReserve),
        ],
      ),
    );
  }

  Widget _textArea(BuildContext context, SrPalette pal) {
    final recording = c.phase == BridgeSessionState.recording;
    final editor = _editor;
    final previewing = _isPreview && editor != null;
    // Top-anchored orb (右上/左上): the ball's lower half rides over this
    // region — the body keeps a 48 top padding (scrolled to top, the
    // first line rests exactly at the fade's lower edge) under a
    // surface-colored fade that dissolves arriving content into the card
    // below the header (锚边渐隐, spec §3). Bottom-anchored orb: no body
    // fade — the footer row plus its 48 reserve carry the bottom edge.
    final orbAtTop = !widget.dir.growUp;
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            // Straight-edge body content: contentInset (below the corner
            // band).
            padding: EdgeInsets.fromLTRB(
              SrSpace.contentInset,
              orbAtTop ? SrGeometry.anchorInset : SrSpace.md,
              SrSpace.contentInset,
              SrSpace.sm,
            ),
            child: Stack(
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
            ),
          ),
        ),
        if (orbAtTop)
          // Full-width, flush under the header row: opaque surface at
          // the top dissolving to transparent 48 in (the bottom fade's
          // mirror). The orb (stage layer) paints above it and stays
          // crisp; content under the fade is inert to the pointer.
          Positioned(
            key: const Key('session-top-fade'),
            left: 0,
            right: 0,
            top: 0,
            height: SrGeometry.anchorInset,
            child: IgnorePointer(
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
      ],
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
    return Padding(
      // Corner-band row (bottom-left arc): cornerInset horizontal; the
      // vertical 20 keeps the buttons' visual bottom inside the capsule.
      padding: const EdgeInsets.fromLTRB(
        SrSpace.cornerInset,
        SrSpace.xs,
        SrSpace.cornerInset,
        20,
      ),
      child: Row(
        children: [
          // 左下 (upRight): the orb owns this row's start — one
          // anchorInset, not two: the ball's right edge sits anchorInset +
          // orbBall/2 = 76 from the window's left edge, while this row's
          // content starts cardMargin + hairline + cornerInset = 33 from
          // it — the true overlap is 43, and 48 keeps a 5px gap. The
          // header's twin keeps 56 instead (the recording ring's reach;
          // the footer band never carries one).
          if (widget.dir.growUp && !widget.dir.growLeft)
            const SizedBox(width: SrGeometry.anchorInset),
          // Capsules keep their intrinsic width (icon-only shrinking is a
          // later change). At the reshape floor they no longer fit beside
          // the reserve — clip the overflow so the debug stripe stays gone
          // (ticket 01's 420-wide pin still holds; 360 is 60px tighter).
          // 左下 alone right-aligns the group (仅左下底栏钮组右对齐:
          // the orb holds the row's start, the three buttons yield to the
          // far side — their ORDER stays frozen, 对照 → 重新生成 → 取消).
          Expanded(
            child: UnconstrainedBox(
              alignment: widget.dir.growUp && !widget.dir.growLeft
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              constrainedAxis: Axis.vertical,
              clipBehavior: Clip.hardEdge,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isPreview) ...[
                    _GhostButton(
                      key: const Key('session-raw-toggle'),
                      pal: pal,
                      icon: Icons.compare_arrows_rounded,
                      label: '对照原文',
                      onTap: _toggleTranscript,
                    ),
                    const SizedBox(width: SrSpace.sm),
                    _GhostButton(
                      key: const Key('session-reroll'),
                      pal: pal,
                      icon: Icons.refresh_rounded,
                      label: '重新生成',
                      onTap: c.reroll,
                    ),
                    const SizedBox(width: SrSpace.sm),
                  ],
                  // Cancel spans the whole session, recording included
                  // (Esc's twin — 窗底取消文字钮).
                  _GhostButton(
                    key: const Key('session-cancel'),
                    pal: pal,
                    icon: Icons.close_rounded,
                    label: '取消',
                    kbd: 'Esc',
                    onTap: c.escapeAction,
                  ),
                ],
              ),
            ),
          ),
          // 右下 (upLeft) alone: the orb button lives here, above this
          // row's end. Top-anchored orbs (右上/左上) put no reserve in the
          // footer at all — the ball shares the HEADER's row there, and
          // obligations follow the anchor's edge only (义务随锚点角走).
          if (widget.dir.growUp && widget.dir.growLeft)
            const SizedBox(width: SrGeometry.anchorInset),
        ],
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

/// Ghost (secondary) button.
class _GhostButton extends StatefulWidget {
  const _GhostButton({
    super.key,
    required this.pal,
    required this.icon,
    required this.label,
    required this.onTap,
    this.kbd,
  });

  final SrPalette pal;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? kbd;

  @override
  State<_GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<_GhostButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final pal = widget.pal;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: SrMotion.fast,
          // 8px horizontal: the preview footer's three capsules must fit
          // beside the anchor reserve inside the 420px panel footprint.
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _hover ? pal.surfaceOverlay : pal.surfaceRaised,
            // Capsule: the footer buttons live in the corner band — pill
            // ends echo the concentric corner arc.
            borderRadius: BorderRadius.circular(SrRadius.capsule),
            border: Border.all(color: pal.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: pal.textSecondary),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: SrType.caption.copyWith(color: pal.textSecondary),
              ),
              if (widget.kbd != null) ...[
                const SizedBox(width: 6),
                Container(
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
                    widget.kbd!,
                    style: SrType.kbd.copyWith(color: pal.textTertiary),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
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
