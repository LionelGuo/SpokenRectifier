/// The thinking-marquee machine (14 号票): the 09 prototype's smoke
/// assertion set, ported. Geometry at the default 420×560 card:
/// textW 372, startH 168 (startVis 6), maxH 336, fold at 24 CJK chars.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/src/session/thinking_marquee.dart';

ThinkingMarquee machine() => ThinkingMarquee()..setGeometry(420, 560);

/// A run of `lineCount` lines fed at `msPerLine` cadence, ticking in
/// 100 ms frames between feeds. Each phrase is 25 CJK chars → folds to
/// exactly one line (375px > the 372px width) leaving a 1-char partial.
void feedLines(ThinkingMarquee m, int lineCount, int msPerLine) {
  for (var i = 0; i < lineCount; i++) {
    m.pushText('思' * 25);
    if (i < lineCount - 1) {
      var left = msPerLine;
      while (left > 0) {
        final dt = left > 100 ? 100 : left;
        m.tick(dt);
        left -= dt;
      }
    }
  }
}

/// The lines visible in the band right now (text, in tape order).
List<String> visibleOf(ThinkingMarquee m) {
  final top = m.view().tapeTop;
  return [
    for (final (text, slot) in m.lineSnapshot)
      if (slot * ThinkingMarquee.lineH - top + ThinkingMarquee.lineH > 0 &&
          slot * ThinkingMarquee.lineH - top < m.hPx)
        text,
  ];
}

void main() {
  test('nothing shows before the first thinking token (zero-trace)', () {
    final m = machine();
    m.tick(3000);
    expect(m.thinkStarted, isFalse);
    expect(m.hasVisual, isFalse);
    expect(m.view().regionAlpha, 0);
    expect(m.view().revealAlpha, 0);
  });

  test('the reveal gate waits for startVis + capacity lines, then fades in '
      'over the emphasize span', () {
    final m = machine();
    expect(m.startVis, 6);
    feedLines(m, 6 + ThinkingMarquee.capacity - 1, 50);
    expect(m.revealed, isFalse, reason: 'one line short of the gate');
    feedLines(m, 1, 50);
    expect(m.revealed, isTrue, reason: 'exactly 起高可视行数 + 容量');
    expect(m.view().revealAlpha, 0, reason: 'the fade starts on the clock');
    m.tick(160);
    final half = m.view().revealAlpha;
    expect(half, greaterThan(0));
    expect(half, lessThan(1));
    m.tick(160);
    expect(m.view().revealAlpha, closeTo(1, 0.01));
  });

  test('buffered-ahead-of-geometry text folds at the first layout', () {
    final m = ThinkingMarquee();
    m.pushText('思' * 25);
    expect(m.thinkStarted, isTrue, reason: 'the signal counts immediately');
    expect(m.lineSnapshot, isEmpty, reason: 'nothing folds without a width');
    m.setGeometry(420, 560);
    expect(m.lineSnapshot, isNotEmpty);
  });

  test('a newline completes a line whatever its width', () {
    final m = machine();
    m.pushText('短句\n');
    expect(m.lineSnapshot.length, 1);
    expect(m.lineSnapshot.first.$1, '短句');
  });

  test('the tape-top is monotone: 出顶即逝, never blank above the head', () {
    final m = machine();
    feedLines(m, 30, 400);
    // Monotone in LINE units: a line that left the top never returns.
    // (The park guard may trim a sub-line overshoot — 09 behaved the
    // same — so strict pixel monotonicity is not the invariant.)
    var lastLine = (m.view().tapeTop / ThinkingMarquee.lineH).floor();
    for (var i = 0; i < 100; i++) {
      m.tick(100);
      final top = m.view().tapeTop;
      expect(
        (top / ThinkingMarquee.lineH).floor(),
        greaterThanOrEqualTo(lastLine),
      );
      lastLine = (top / ThinkingMarquee.lineH).floor();
      if (m.lineSnapshot.isNotEmpty) {
        expect(
          top,
          greaterThanOrEqualTo(
            m.lineSnapshot.first.$2 * ThinkingMarquee.lineH - 1e-6,
          ),
          reason: 'no blank strip above the head line (clamp floor)',
        );
      }
    }
  });

  test('a stall stops the tape softly and growth freezes (停等)', () {
    final m = machine();
    feedLines(m, 20, 400);
    // Run until the buffer drains.
    var wasMoving = false;
    for (var i = 0; i < 400; i++) {
      final before = m.view().tapeTop;
      m.tick(100);
      final after = m.view().tapeTop;
      if ((after - before) > 0.01) wasMoving = true;
    }
    expect(wasMoving, isTrue, reason: 'sanity: the tape moved while fed');
    // Drained: the park guard holds the window on the last line.
    final top = m.view().tapeTop;
    m.tick(1000);
    expect(
      m.view().tapeTop,
      closeTo(top, 0.5),
      reason: 'frozen on the park guard',
    );
    // And the band's growth is gated: no spare content, no growth.
    final h = m.hPx;
    m.tick(1000);
    expect(m.hPx, h);
  });

  test('a discard drops only its own slot — the visible set is unchanged', () {
    final m = machine();
    // Overload the buffer fast so discards fire: 30 lines at once.
    feedLines(m, 30, 1);
    var discardSeen = false;
    var guard = 0;
    while (!discardSeen && guard++ < 400) {
      final before = visibleOf(m);
      final droppedBefore = m.dropped;
      m.tick(100);
      if (m.dropped > droppedBefore) {
        discardSeen = true;
        final after = visibleOf(m);
        expect(
          after,
          equals(before),
          reason: 'a discard may never shift a visible line',
        );
      }
    }
    expect(discardSeen, isTrue, reason: 'sanity: the overload discarded');
  });

  test('a stream faster than vMax never empties the window (no desert)', () {
    // The device failure (14 号票真机): a sustained feed above the
    // scroll clamp out-runs the window — a plain slot splice discards
    // the line the window is about to enter, and the window spends
    // the whole attempt scrolling through dropped slots as blank
    // tape. The discard COMPRESSES the waiting tape instead: the
    // window always faces dense content, and the overflow is
    // sacrificed invisibly below the bottom edge.
    final m = machine();
    feedLines(m, 10, 50); // reveal
    for (var i = 0; i < 60; i++) {
      m.pushText('思' * 25); // one line per 300 ms ≈ 3.3 lines/s > vMax
      m.tick(100);
      m.tick(100);
      m.tick(100);
      // The window never faces blank tape: content is always visible…
      expect(visibleOf(m), isNotEmpty, reason: 'desert at feed #$i');
      // …and the tape below the window stays dense — the first
      // waiting line sits exactly at the window's edge line, with no
      // dropped slot wedged open ahead of it.
      final edge = ((m.view().tapeTop + m.hPx) / ThinkingMarquee.lineH)
          .ceil();
      final waiting = [
        for (final (_, slot) in m.lineSnapshot)
          if (slot >= edge) slot,
      ];
      if (waiting.isNotEmpty) {
        expect(waiting.first, edge, reason: 'void below the window at #$i');
      }
    }
    expect(m.dropped, greaterThan(0), reason: 'the overload did sacrifice');
  });

  test('steady state: feeding 1.5 lines/s settles near v = k × 2', () {
    final m = machine();
    // Reveal first (10 lines), then steady 1.5 lines/s ≈ 667 ms/line.
    feedLines(m, 12, 50);
    const msPerLine = 667;
    for (var i = 0; i < 25; i++) {
      m.pushText('思' * 25);
      var left = msPerLine;
      while (left > 0) {
        final dt = left > 100 ? 100 : left;
        m.tick(dt);
        left -= dt;
      }
    }
    // 稳态:缓冲≈速率/k=2 行,v≈0.75×2=1.5 行/s;1.5 行/s
    // means the whole 25-line feed scrolls away in ~16.7 s of tape.
    final v = m.scrollPx / (25 * msPerLine) / ThinkingMarquee.lineH * 1000;
    expect(v, greaterThan(1.0));
    expect(v, lessThan(2.0));
  });

  test('the band grows monotonically toward max after reveal, gated on '
      'spare content', () {
    final m = machine();
    // The gate wants ONGOING spare content (断流冻结): feed 5 lines/s
    // while the band climbs — it reaches 60% of the card and never
    // shrinks. (The window honestly consumes what it shows now, so a
    // finite feed would starve the gate before the top.)
    feedLines(m, 10, 50);
    var last = m.hPx;
    var i = 0;
    while (m.hPx < m.maxBandH && i++ < 400) {
      m.pushText('思' * 25); // one line per 200 ms
      m.tick(50);
      m.tick(50);
      m.tick(50);
      m.tick(50);
      expect(m.hPx, greaterThanOrEqualTo(last - 1e-6), reason: 'never shrinks');
      last = m.hPx;
    }
    expect(
      m.hPx,
      m.maxBandH,
      reason: 'reaches 60% of the card with content to spare',
    );
  });

  test('the handover latch is one-way: no relight, the region fades out '
      'over the fade span', () {
    final m = machine();
    feedLines(m, 12, 50);
    expect(m.view().regionAlpha, 1);
    m.handOver();
    expect(m.handedOver, isTrue);
    m.tick(1);
    expect(
      m.view().regionAlpha,
      lessThan(1),
      reason: 'the fade starts at once',
    );
    m.tick(179);
    expect(m.view().regionAlpha, 0);
    // Late thinking text still feeds but never relights.
    m.pushText('交棒后才到的思考文本');
    m.tick(100);
    expect(m.view().regionAlpha, 0);
    expect(m.hasVisual, isFalse);

    // The elapsed label froze at the handover instant.
    final frozen = m.view().elapsedMs;
    m.tick(5000);
    expect(m.view().elapsedMs, frozen);
  });

  test('the elapsed clock runs from the first token', () {
    final m = machine();
    m.pushText('先到的一个字');
    m.tick(1000);
    expect(m.view().elapsedMs, greaterThanOrEqualTo(1000));
  });
}
