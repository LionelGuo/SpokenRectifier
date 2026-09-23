/// Shared setting-surface controls: the button and card recipes the
/// settings window's domains paint with. Extracted when the third pane
/// copied them (ticket 18) — one recipe, hover treatment included, like
/// [SrHover] before it.

library;

import 'package:flutter/material.dart';

import 'hover.dart';
import 'tokens.dart';

/// The press fill (26 号票): a scrim layer pressed onto the control's
/// own shape while the pointer is down, easing in and out over `fast`
/// (feedback must track the finger). It composites over ANY fill —
/// accent, overlay, hover — so every pressable control shares one
/// recipe and one depth, and no palette step is invented for it.
///
/// Position it AROUND the padded box (outside the container that draws
/// the fill), not around the content inside it: the scrim must span the
/// full card — padding and border included — or it reads narrower than
/// the control (26 号票 真机 round).
class SrPressFill extends StatelessWidget {
  const SrPressFill({
    super.key,
    required this.pressed,
    required this.radius,
    required this.child,
  });

  final bool pressed;
  final BorderRadius radius;
  final Widget child;

  /// The scrim's pressed alpha. A tenth of the palette scrim reads on
  /// both themes' fills (dark overlay, light overlay, accent) without
  /// turning any of them into a selection tint.
  static const _alpha = 0.10;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return AnimatedContainer(
      duration: SrMotion.fast,
      curve: SrMotion.curveMicro,
      foregroundDecoration: BoxDecoration(
        color: pal.scrim.withValues(alpha: pressed ? _alpha : 0.0),
        borderRadius: radius,
      ),
      child: child,
    );
  }
}

/// The settings panes' button. Primary = the accent fill; ghost = the
/// hairline outline. A null [onTap] paints the ghost shape inert — the
/// disabled state is visual only, callers decide when an action exists.
class SrButton extends StatelessWidget {
  const SrButton({
    super.key,
    required this.label,
    this.onTap,
    this.primary = false,
    this.dense = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;

  /// The in-field corner form (35 号票): trimmed padding so the button
  /// reads as part of the field's corner pocket, not a full control
  /// parked inside the box.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final enabled = onTap != null;
    return SrHover(
      builder: (hover) => SrPress(
        builder: (pressed) => GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SrPressFill(
            // The scrim wraps the padded box, not the content inside it —
            // inside, it would only cover the inner content and read
            // narrower than the button card (26 号票 真机 round).
            pressed: pressed && enabled,
            radius: BorderRadius.circular(SrRadius.control),
            child: AnimatedContainer(
              duration: SrMotion.fade,
              curve: SrMotion.curveFade,
              padding: dense
                  ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4)
                  : const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                // One hover treatment per shape: the fill's own alpha eases,
                // never a lerp toward transparent (the cross-dissolve rule).
                color: primary
                    ? (hover && enabled
                          ? pal.accent.withValues(alpha: 0.88)
                          : pal.accent)
                    : pal.surfaceOverlay.withValues(
                        alpha: hover && enabled ? 1 : 0,
                      ),
                borderRadius: BorderRadius.circular(SrRadius.control),
                border: primary ? null : Border.all(color: pal.hairline),
              ),
              child: Text(
                label,
                style: SrType.caption.copyWith(
                  color: primary
                      ? pal.onAccent
                      : (enabled ? pal.textSecondary : pal.textTertiary),
                  fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The settings panes' card surface: raised fill, hairline, the
/// pane-wide corner. Content unchanged by hover — rows inside own
/// their own hover treatment.
class SrCard extends StatelessWidget {
  const SrCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Container(
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.surfaceRaised,
        borderRadius: BorderRadius.circular(SrRadius.control + 4),
        border: Border.all(color: pal.hairline),
      ),
      child: child,
    );
  }
}

/// The in-field corner button's inset from the field box's edge (35
/// 号票): right and bottom ride the SAME constant — the hard rule is
/// that the two gaps stay strictly equal, so they share one number.
const double _fieldCornerInset = 4;

/// The text's bottom floor when a corner button owns the pocket: the
/// input's own padding grows by this so a full box never slides a line
/// under the button (dense height ≈ 27 + inset + breathing).
const double _fieldCornerTextFloor = 28;

/// An icon whose color eases between two tones over the shared
/// micro-feedback window, so no icon color snaps beside the box fades
/// around it. The flag need not be hover — the theme segments feed it
/// `selected`, riding the same easing on the discrete switch (26 号票).
class SrHoverTintIcon extends StatelessWidget {
  const SrHoverTintIcon({
    super.key,
    required this.icon,
    required this.size,
    required this.hover,
    required this.resting,
    required this.hovered,
  });

  final IconData icon;
  final double size;
  final bool hover;
  final Color resting;
  final Color hovered;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: resting, end: hover ? hovered : resting),
      duration: SrMotion.fast,
      curve: SrMotion.curveMicro,
      builder: (context, color, _) => Icon(icon, size: size, color: color),
    );
  }
}

/// The settings panes' text field — overlay fill, hairline, control
/// radius; the TextField inside is undecorated (paint = layout).
/// Extracted when the third pane copied the recipe (ticket 19); 27 号票
/// folded every remaining bare box into it. A null [label] paints the
/// box alone (the inline-row shape); a label paints above it (the form
/// shape). The quick panel's term row is the one exception: it keeps
/// its own equal-height container so the add button shares a painter.
///
/// A field-scoped save button rides one of two action slots (35 号票):
/// multiline boxes take [cornerAction] — the button sits inside the
/// box's bottom-right corner, right/bottom insets strictly equal; a
/// single-line box (too shallow for an in-field button) takes
/// [sideAction] — the button stands beside the box, under the label.
class SrField extends StatelessWidget {
  const SrField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.obscure = false,
    this.monospace = false,
    this.onSubmitted,
    this.maxLines,
    this.minLines,
    this.autofocus = false,
    this.cornerAction,
    this.sideAction,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final bool obscure;
  final bool monospace;
  final ValueChanged<String>? onSubmitted;

  /// A multiline field (the request-body JSON box, extra directives):
  /// grows with content from [minLines] up to [maxLines] instead of
  /// the fixed one-line box. Null [maxLines] keeps the 34px single
  /// line. When [maxLines] is set and [minLines] is omitted, the
  /// floor is three lines (the JSON box's original height).
  final int? maxLines;
  final int? minLines;

  /// Dialogs that open onto a name field pass this so the caret is
  /// waiting; the rest of the form never autofocuses.
  final bool autofocus;

  /// A button pinned inside the box's bottom-right corner (multiline
  /// boxes only): the text's bottom padding grows so a full box never
  /// slides a line under it.
  final Widget? cornerAction;

  /// A button standing beside the box row (single-line boxes): it
  /// rides the box's own line, never the label's, so the pair reads
  /// as one control.
  final Widget? sideAction;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final multiline = maxLines != null;
    final input = TextField(
      controller: controller,
      obscureText: obscure,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
      maxLines: maxLines ?? 1,
      minLines: multiline ? (minLines ?? 3) : null,
      style: SrType.body.copyWith(
        color: pal.textPrimary,
        fontFamily: monospace ? SrType.monoFamily : null,
      ),
      cursorColor: pal.accent,
      decoration: InputDecoration(
        isCollapsed: true,
        border: InputBorder.none,
        focusedBorder: InputBorder.none,
        enabledBorder: InputBorder.none,
        hintText: hint,
        // The placeholder matches the input's own size (真机回音
        // 2026-09-23): micro read as a second-class citizen beside
        // the text it previews. Color stays tertiary.
        hintStyle: SrType.body.copyWith(color: pal.textTertiary),
        contentPadding: cornerAction == null
            ? EdgeInsets.zero
            : const EdgeInsets.only(bottom: _fieldCornerTextFloor),
      ),
    );
    final decoration = BoxDecoration(
      color: pal.surfaceOverlay,
      borderRadius: BorderRadius.circular(SrRadius.control),
      border: Border.all(color: pal.hairline),
    );
    Widget box;
    if (cornerAction != null) {
      box = Container(
        decoration: decoration,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: input,
            ),
            // Later in the Stack: painted over the input and hit first,
            // so the corner button owns its pocket. Right and bottom
            // ride the same constant — the equal-gap rule (35 号票).
            Positioned(
              right: _fieldCornerInset,
              bottom: _fieldCornerInset,
              child: cornerAction!,
            ),
          ],
        ),
      );
    } else {
      box = Container(
        height: multiline ? null : 34,
        padding: EdgeInsets.symmetric(
          horizontal: 10,
          vertical: multiline ? 8 : 0,
        ),
        decoration: decoration,
        alignment: multiline ? null : Alignment.centerLeft,
        child: input,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          // The label rides the in-card title tier (the five-tier
          // ladder's third rung, 33 号票 rollout): subhead + textPrimary,
          // like every switch-row title and field-group label.
          Text(
            label!,
            style: SrType.subhead.copyWith(color: pal.textPrimary),
          ),
          const SizedBox(height: 4),
        ],
        if (sideAction != null)
          Row(
            children: [
              Expanded(child: box),
              const SizedBox(width: 8),
              sideAction!,
            ],
          )
        else
          box,
      ],
    );
  }
}
