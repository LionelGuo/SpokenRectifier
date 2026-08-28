/// The shared hover machinery: MouseRegion + flag, so every control that
/// paints hover states off the token palette need not copy it. The
/// builder gets the flag; the caller owns duration/curve and colors (the
/// quick panel's rules: surface fade 180ms, fill by the target color's
/// own alpha).

library;

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
