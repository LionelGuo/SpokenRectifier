/// The settings window's caption (title bar) theme, applied on Windows
/// through DWM. desktop_multi_window seeds sub-window captions from the
/// SYSTEM apps theme (Win32Window::UpdateTheme runs at window creation),
/// so on a dark-mode system the caption is born black even under the
/// app's light theme. This helper takes ownership for the one window that
/// has a title bar (the orb, session window, and quick panel are all
/// frameless): the immersive dark-mode flag — which drives the caption's
/// text and button glyphs — is set from the app's effective brightness,
/// and on Windows 11 the caption is additionally painted the window
/// surface's exact color, so the title bar reads as the body's seamless
/// continuation (the bleed-zero rule, applied to the chrome). Attribute
/// ids unsupported on older systems are refused silently: Windows 10
/// degrades to the plain dark/light caption.

library;

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:ui' show Brightness;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/painting.dart' show Color;

import '../design/tokens.dart' show SrPalette;

/// The settings window's title: the bootstrap's WindowOptions and the
/// caption helper's FindWindow lookup share this one constant (the lookup
/// requires the title to already be set, which waitUntilReadyToShow does
/// before the first show).
const settingsWindowTitle = 'SpokenRectifier 设置';

// DWM attribute ids (dwmapi.h); the numeric literals are stable ABI.
const int _useTitleBarDarkTheme = 19; // Windows 10 1809's name for the flag
const int _useImmersiveDarkMode = 20; // renamed from 19041 on
const int _captionColor = 35; // Windows 11: the caption's fill color

/// Resolve a theme mode against the platform brightness into the
/// brightness the caption should paint.
Brightness effectiveBrightness(ThemeMode mode, Brightness platform) =>
    mode == ThemeMode.dark ||
        (mode == ThemeMode.system && platform == Brightness.dark)
    ? Brightness.dark
    : Brightness.light;

/// The COLORREF (0x00BBGGRR) DWM expects for a Flutter color.
@visibleForTesting
int colorRefOf(Color color) {
  final argb = color.toARGB32();
  return ((argb & 0xFF) << 16) | (argb & 0xFF00) | ((argb >> 16) & 0xFF);
}

/// Apply the caption theme for [brightness] to the settings window. A
/// no-op off Windows, or when the window cannot be found (which is what
/// widget tests on a headless host see).
void applyWindowsCaptionTheme(Brightness brightness) {
  if (!Platform.isWindows) return;
  final hwnd = _findSettingsWindow();
  if (hwnd == null) return;
  final dark = brightness == Brightness.dark;
  // The flag drives the caption's text and glyphs; Windows 10 1809 knows
  // it only under its pre-19041 name, so fall back when 20 is refused.
  if (!_setAttributeUint32(hwnd, _useImmersiveDarkMode, dark ? 1 : 0)) {
    _setAttributeUint32(hwnd, _useTitleBarDarkTheme, dark ? 1 : 0);
  }
  // Win11 only; a refusal keeps whatever fill the flag above implies.
  final surface = brightness == Brightness.dark
      ? SrPalette.dark.surface
      : SrPalette.light.surface;
  _setAttributeUint32(hwnd, _captionColor, colorRefOf(surface));
}

// Opened lazily: top-level finals evaluate on first use, which only ever
// happens behind the Platform.isWindows guard above.

final int Function(Pointer<Utf16>, Pointer<Utf16>) _findWindowW =
    DynamicLibrary.open('user32.dll').lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowW');

final int Function(int, int, Pointer<Void>, int) _dwmSetWindowAttribute =
    DynamicLibrary.open('dwmapi.dll').lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)
    >('DwmSetWindowAttribute');

int? _findSettingsWindow() {
  final title = settingsWindowTitle.toNativeUtf16();
  try {
    final hwnd = _findWindowW(Pointer.fromAddress(0), title);
    return hwnd == 0 ? null : hwnd;
  } finally {
    calloc.free(title);
  }
}

/// Returns whether DWM accepted the attribute (S_OK == 0).
bool _setAttributeUint32(int hwnd, int attribute, int value) {
  final pointer = calloc<Uint32>()..value = value;
  try {
    return _dwmSetWindowAttribute(
          hwnd,
          attribute,
          pointer.cast(),
          sizeOf<Uint32>(),
        ) ==
        0;
  } finally {
    calloc.free(pointer);
  }
}
