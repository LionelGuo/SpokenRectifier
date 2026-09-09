/// The placeholder capsule visuals (ticket 21): the flat capsule family
/// the sentinels project as on the session surface — never the bare
/// `‡N‡` four characters. While listening and rectifying the sentinel
/// collapses to the number circle (号圆); the circle itself is PAINTED by
/// the stream surface's foreground layer onto the spacer this module
/// reserves, centered on its line's text ink — the same anchor the
/// preview's fill capsules use, in the same frame the layout happens
/// (23 号验收轮: the WidgetSpan's own middle alignment follows font
/// metrics and sat visibly off on real fallback chains, and any
/// post-frame correction lags the stream's constant re-layout).
///
/// Family rules (spec 「预览填写槽·视觉」, 08 号五轮): all-flat — no
/// border, no shadow; the number is plain small text; the empty-state
/// look is shared with the preview fill slot; the capsule never carries
/// data-layer characters (两侧间距走视觉).

library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../preview/slot_document.dart' show scanSentinels;

/// The number circle's inline width for [id]: one digit a true circle;
/// wider numbers grow into the family's capsule shape instead of
/// clipping.
double pinCapsuleWidth(int id) {
  final digits = id.toString().length;
  return digits <= 1
      ? SrCapsule.liveSize
      : SrCapsule.liveSize + (digits - 1) * 7.0;
}

/// Splits [text] into display spans: ordinary text as-is, every `‡N‡`
/// sentinel as one keyed spacer ([WidgetSpan], middle-aligned — the
/// alignment only places the invisible reservation; the circle is
/// painted at the line's text-ink center by the surface's foreground
/// layer). This is the read-only projection the main surface paints
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
        child: SizedBox(
          key: ValueKey('pin-capsule-${span.id}'),
          width: pinCapsuleWidth(span.id),
          height: SrCapsule.liveSize,
        ),
      ),
    );
    copied = span.end;
  }
  if (copied < text.length) {
    spans.add(TextSpan(text: text.substring(copied)));
  }
  return spans;
}
