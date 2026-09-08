/// The placeholder capsule visuals (ticket 21): the flat capsule family
/// the sentinels project as on the session surface — never the bare
/// `‡N‡` four characters. While listening and rectifying the sentinel
/// collapses to the number round (号圆胶囊); the preview's full fill
/// capsule (08 号票) joins the same family in ticket 22.
///
/// Family rules (spec 「预览填写槽·视觉」, 08 号五轮): all-flat — no
/// border, no shadow; the number is plain small text; the empty-state
/// look is shared with the preview fill slot; the capsule never carries
/// data-layer characters (两侧间距走视觉).

library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../preview/slot_document.dart' show scanSentinels;

/// One pinned placeholder's collapsed form: a flat round chip carrying
/// the number, read-only (聆听不能填 — nothing here is editable).
class PinNumberCapsule extends StatelessWidget {
  const PinNumberCapsule({super.key, required this.id});

  /// The placeholder's identity — the digits inside the sentinel. The
  /// number IS the slot (数字即身份, 07 号票), so it is all the chip
  /// shows.
  final int id;

  /// Capsule height: 18 keeps the chip inside bodyLarge's 24px line box
  /// with equal breathing room top and bottom (行上下间距绝对相等).
  static const double size = 18;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Container(
      key: ValueKey('pin-capsule-$id'),
      height: size,
      // minWidth keeps one digit a true circle; wider numbers grow into
      // the family's capsule shape instead of clipping.
      constraints: const BoxConstraints(minWidth: size),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // The flat family: fill only — no border, no shadow.
        color: pal.accentSoft,
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Text(
        '$id',
        // Plain small digits — not bold, not accented beyond family tint.
        style: SrType.micro.copyWith(color: pal.accentText, height: 1),
      ),
    );
  }
}

/// Splits [text] into display spans: ordinary text as-is, every
/// `‡N‡` sentinel as one [PinNumberCapsule] inline (middle-aligned to
/// the line). This is the read-only projection the main surface paints
/// while listening and rectifying — the scan is the same shape-driven
/// one the slot model uses (同形也抽), so a same-shape the ASR happened
/// to transcribe renders as a capsule too, exactly as it would extract
/// as a slot later.
List<InlineSpan> sentinelSpans(String text) {
  final spans = <InlineSpan>[];
  var copied = 0;
  for (final span in scanSentinels(text)) {
    if (span.start > copied) {
      spans.add(TextSpan(text: text.substring(copied, span.start)));
    }
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: PinNumberCapsule(id: span.id),
      ),
    );
    copied = span.end;
  }
  if (copied < text.length) {
    spans.add(TextSpan(text: text.substring(copied)));
  }
  return spans;
}
