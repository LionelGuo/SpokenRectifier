/// Pure-function tests for the caption (title bar) theme helper: the
/// mode→brightness resolution and the Flutter-color→COLORREF conversion.
/// The ffi application itself is a no-op in tests (off Windows, or with
/// no such window) and is covered by the real-machine checklist.

library;

import 'dart:ui' show Brightness;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/src/design/tokens.dart' show SrPalette;
import 'package:spokenrectifier_app/src/settings/caption_theme.dart';

void main() {
  group('effectiveBrightness', () {
    test('an explicit mode wins regardless of the platform', () {
      expect(
        effectiveBrightness(ThemeMode.dark, Brightness.light),
        Brightness.dark,
      );
      expect(
        effectiveBrightness(ThemeMode.dark, Brightness.dark),
        Brightness.dark,
      );
      expect(
        effectiveBrightness(ThemeMode.light, Brightness.light),
        Brightness.light,
      );
      expect(
        effectiveBrightness(ThemeMode.light, Brightness.dark),
        Brightness.light,
      );
    });

    test('system follows the platform brightness', () {
      expect(
        effectiveBrightness(ThemeMode.system, Brightness.light),
        Brightness.light,
      );
      expect(
        effectiveBrightness(ThemeMode.system, Brightness.dark),
        Brightness.dark,
      );
    });
  });

  group('colorRefOf', () {
    test('swaps Flutter ARGB into DWM 0x00BBGGRR', () {
      // r=0x12, g=0x34, b=0x56 -> 0x563412
      expect(colorRefOf(const Color(0xFF123456)), 0x563412);
    });

    test('the palette surfaces land as their exact colors', () {
      // #1F232C -> blue 2C, green 23, red 1F.
      expect(colorRefOf(SrPalette.dark.surface), 0x2C231F);
      expect(colorRefOf(SrPalette.light.surface), 0xFFFFFF);
    });
  });
}
