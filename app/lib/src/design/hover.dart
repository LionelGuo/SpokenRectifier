/// The shared hover and press machinery: MouseRegion / Listener + flag,
/// so every control that paints hover or press states off the token
/// palette need not copy it. The builder gets the flag; the caller owns
/// duration/curve and colors (the quick panel's rules: surface fade
/// 180ms, fill by the target color's own alpha; press fill via
/// [SrPressFill] — 26 号票's two-tier rule: press rides `fast`, the
/// discrete switch that follows the release rides `fade`).

library;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';

class SrHover extends StatefulWidget {
  const SrHover({super.key, required this.builder});

  final Widget Function(bool hover) builder;

  @override
  State<SrHover> createState() => _SrHoverState();
}

class _SrHoverState extends State<SrHover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.builder(_hover),
    );
  }
}

/// The press flag: true while a primary pointer is down on the control
/// (release and cancel both clear it). Listener, not the arena — press
/// feedback must not wait for the tap's disambiguation.
class SrPress extends StatefulWidget {
  const SrPress({super.key, required this.builder});

  final Widget Function(bool pressed) builder;

  @override
  State<SrPress> createState() => _SrPressState();
}

class _SrPressState extends State<SrPress> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kPrimaryButton) {
          setState(() => _pressed = true);
        }
      },
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: widget.builder(_pressed),
    );
  }
}
