/// The session panel: one continuous surface evolving live transcript ->
/// streaming rectify -> preview (修正≡预览同形, only the affordances
/// differ). The text region is a single TextField for the whole ride:
/// read-only while streaming, editable the moment the stream completes —
/// what you see is what gets inserted.

library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../design/tokens.dart';
import '../rust/api.dart' show BridgeSessionState;
import '../shell/window_stage.dart';

class SessionPanel extends StatefulWidget {
  const SessionPanel({
    super.key,
    required this.controller,
    required this.exiting,
  });

  final SpeechController controller;
  final bool exiting;

  @override
  State<SessionPanel> createState() => _SessionPanelState();
}

class _SessionPanelState extends State<SessionPanel> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Timer? _tick;

  SpeechController get c => widget.controller;

  bool get _isPreview => c.phase == BridgeSessionState.preview;
  bool _wasPreview = false;

  /// Whether the 对照原文 comparison block is expanded (panel-local UI
  /// state; nothing else reads it).
  bool _showTranscript = false;

  void _toggleTranscript() =>
      setState(() => _showTranscript = !_showTranscript);

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    _syncText();
    _wasPreview = c.phase == BridgeSessionState.preview;
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
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    _syncText();
    if (!_wasPreview && _isPreview) {
      // The stream completed: the field becomes editable this instant.
      _wasPreview = true;
      _focus.requestFocus();
    } else if (!_isPreview) {
      _wasPreview = false;
    }
  }

  /// Keeps the single text region in step with the streams without
  /// moving the caret while the user edits. Preview edits are adopted
  /// into [SpeechController.previewText] the moment they happen, so the
  /// value-difference check never rewrites under the caret.
  void _syncText() {
    final streamText = c.phase == BridgeSessionState.recording
        ? c.liveText
        : c.previewText;
    if (_text.text == streamText) return;
    _text.value = TextEditingValue(
      text: streamText,
      selection: TextSelection.collapsed(offset: streamText.length),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// Chat-input style Enter: a bare Enter in a non-composing field
  /// arrives as an appended newline — strip it and confirm (same
  /// semantics as ticket 14). While the IME composes, Enter commits the
  /// composition instead and must not confirm.
  void _onEdited(String value) {
    final composing = _text.value.composing;
    if (value.endsWith('\n') && composing == TextRange.empty) {
      final stripped = value.substring(0, value.length - 1);
      _text.value = TextEditingValue(
        text: stripped,
        selection: TextSelection.collapsed(offset: stripped.length),
      );
      c.editPreviewText(stripped);
      c.enterAction();
      return;
    }
    c.editPreviewText(value);
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return PanelBody(
      exiting: widget.exiting,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, pal),
          Divider(height: 1, thickness: 1, color: pal.hairline),
          Expanded(child: _textArea(context, pal)),
          if (c.lastError != null) _errorRow(context, pal),
          _transcriptSection(context, pal),
          _footer(context, pal),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, SrPalette pal) {
    final (label, dotColor, live) = switch (c.phase) {
      BridgeSessionState.recording => ('聆听中', pal.live, true),
      BridgeSessionState.rectifying => ('修正中', pal.accent, false),
      _ => ('预览', pal.success, false),
    };
    final elapsed = _formatElapsed(c.recordElapsed);
    return Padding(
      // Corner-band row: aligns to the concentric content capsule
      // (SrSpace.cornerInset). Vertical 20 puts the 16px title's visual
      // top (~24) on the capsule's D=16 arc.
      padding: const EdgeInsets.fromLTRB(
        SrSpace.cornerInset,
        20,
        SrSpace.cornerInset,
        12,
      ),
      child: Row(
        children: [
          _PhaseDot(color: dotColor, live: live),
          const SizedBox(width: 8),
          Text(label, style: SrType.body.copyWith(color: pal.textPrimary)),
          if (c.phase == BridgeSessionState.recording) ...[
            const SizedBox(width: 8),
            Text(
              elapsed,
              style: SrType.micro.copyWith(color: pal.textTertiary),
            ),
          ],
          const Spacer(),
          // A picker over an empty library has nothing to pick between:
          // the chip hides until the settings editor fills one in. A
          // one-time scenario session (ticket 23) paints the same shape
          // with that scenario's name — same format, no special badge.
          if (c.scenarios.isNotEmpty)
            _ScenarioChip(
              label: '场景 · ${c.oneTimeScenario ?? c.selectedScenario ?? '默认'}',
            ),
        ],
      ),
    );
  }

  Widget _textArea(BuildContext context, SrPalette pal) {
    final empty = _text.text.isEmpty && c.phase == BridgeSessionState.recording;
    return Padding(
      // Straight-edge body content: contentInset (below the corner band).
      padding: const EdgeInsets.fromLTRB(
        SrSpace.contentInset,
        12,
        SrSpace.contentInset,
        8,
      ),
      child: Stack(
        children: [
          if (empty)
            Text(
              '开始说话…',
              style: SrType.bodyLarge.copyWith(color: pal.textTertiary),
            ),
          TextField(
            key: const Key('session-text'),
            controller: _text,
            focusNode: _focus,
            scrollController: _scroll,
            readOnly: !_isPreview,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            showCursor: true,
            cursorColor: c.phase == BridgeSessionState.recording
                ? pal.live
                : pal.accent,
            cursorWidth: 2.5,
            cursorRadius: const Radius.circular(2),
            style: SrType.bodyLarge.copyWith(
              color: c.phase == BridgeSessionState.recording
                  ? pal.textSecondary
                  : pal.textPrimary,
            ),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: '',
            ),
            onChanged: _onEdited,
          ),
        ],
      ),
    );
  }

  /// Engine and startup failures, visible on the panel while one runs
  /// (the orb's tooltip carries them at idle).
  Widget _errorRow(BuildContext context, SrPalette pal) {
    return Container(
      key: const Key('session-error'),
      margin: const EdgeInsets.fromLTRB(
        SrSpace.contentInset,
        0,
        SrSpace.contentInset,
        8,
      ),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: pal.liveSoft,
        borderRadius: BorderRadius.circular(SrRadius.control),
        border: Border.all(color: pal.live.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 15, color: pal.live),
          const SizedBox(width: 8),
          Expanded(
            // Wrapped, not single-line: error diagnoses live in the tail
            // a clipped line would eat.
            child: Text(
              c.lastError!,
              style: SrType.caption.copyWith(color: pal.textPrimary),
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
                8,
              ),
              padding: const EdgeInsets.all(12),
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
                  Text(
                    '原始转写',
                    style: SrType.micro.copyWith(color: pal.textTertiary),
                  ),
                  const SizedBox(height: 4),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Text(
                        c.liveText.isEmpty ? '(无)' : c.liveText,
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
        4,
        SrSpace.cornerInset,
        20,
      ),
      child: Row(
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
          // Cancel spans the whole session, recording included (Esc's
          // twin — 窗底取消文字钮).
          _GhostButton(
            key: const Key('session-cancel'),
            pal: pal,
            icon: Icons.close_rounded,
            label: '取消',
            kbd: 'Esc',
            onTap: c.escapeAction,
          ),
          // Anchor zone: the orb button lives here, above this row.
          const SizedBox(width: SrGeometry.anchorInset * 2),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
      child: Text(label, style: SrType.micro.copyWith(color: pal.accentText)),
    );
  }
}
