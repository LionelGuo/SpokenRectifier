/// Shared setting-surface controls: the button and card recipes the
/// settings window's domains paint with. Extracted when the third pane
/// copied them (ticket 18) — one recipe, hover treatment included, like
/// [SrHover] before it.

library;

import 'package:flutter/material.dart';

import 'hover.dart';
import 'tokens.dart';

/// The settings panes' button. Primary = the accent fill; ghost = the
/// hairline outline. A null [onTap] paints the ghost shape inert — the
/// disabled state is visual only, callers decide when an action exists.
class SrButton extends StatelessWidget {
  const SrButton({
    super.key,
    required this.label,
    this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final enabled = onTap != null;
    return SrHover(
      builder: (hover) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: SrMotion.fade,
          curve: SrMotion.curveFade,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            // One hover treatment per shape: the fill's own alpha eases,
            // never a lerp toward transparent (the cross-dissolve rule).
            color: primary
                ? (hover && enabled
                      ? pal.accent.withValues(alpha: 0.88)
                      : pal.accent)
                : pal.surfaceOverlay.withValues(alpha: hover && enabled ? 1 : 0),
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
