/// The quick panel placeholder: same footprint, same position, mutually
/// exclusive with the session window (同形同位互斥). Ticket 15 delivers
/// the shell — orb right-click opens it, Esc / the orb-✕ close it, the
/// window grows and collapses with the approved choreography — while
/// ticket 16 fills in the sections (scenario quick-pick, quick terms,
/// recent history, passage mode, the theme tri-state that also writes
/// `spokenrectifier-ui.toml`, settings entry).

library;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../design/tokens.dart';
import 'window_stage.dart';

class QuickPanel extends StatelessWidget {
  const QuickPanel({super.key, required this.controller, required this.exiting});

  final SpeechController controller;
  final bool exiting;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return PanelBody(
      exiting: exiting,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // Corner-band row: aligns to the concentric content capsule
            // (SrSpace.cornerInset). Vertical 20 puts the 16px title's
            // visual top (~24) on the capsule's D=16 arc.
            padding: const EdgeInsets.fromLTRB(
              SrSpace.cornerInset,
              20,
              SrSpace.cornerInset,
              12,
            ),
            child: Row(
              children: [
                Text(
                  '快捷设置',
                  style: SrType.title.copyWith(color: pal.textPrimary),
                ),
                const SizedBox(width: 8),
                Text(
                  'Esc 关闭',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: pal.hairline),
          Expanded(
            child: Center(
              child: Text(
                '建设中 · 即将上线',
                key: const Key('quick-placeholder'),
                style: SrType.body.copyWith(color: pal.textTertiary),
              ),
            ),
          ),
          // Anchor zone: the orb button (close, in this stage) overlays
          // the panel's bottom-right corner.
          const SizedBox(height: SrGeometry.anchorInset * 2),
        ],
      ),
    );
  }
}
