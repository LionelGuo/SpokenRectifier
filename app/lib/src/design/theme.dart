/// Shared theme assembly from the token palettes (transparent scaffold:
/// the window itself is the floating surface). Ported from the approved
/// prototype (ticket 12); the settings window (ticket 17) reuses this
/// with its own opaque scaffold background.

library;

import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData srTheme(Brightness brightness) {
  final pal = brightness == Brightness.dark ? SrPalette.dark : SrPalette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: pal.accent,
    onPrimary: pal.onAccent,
    secondary: pal.accent,
    onSecondary: pal.onAccent,
    error: pal.live,
    onError: pal.onAccent,
    surface: pal.surface,
    onSurface: pal.textPrimary,
    primaryContainer: pal.surfaceRaised,
    onPrimaryContainer: pal.textPrimary,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    fontFamilyFallback: const [
      'Segoe UI Variable',
      'Segoe UI',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ],
    splashFactory: NoSplash.splashFactory,
    hoverColor: pal.surfaceOverlay,
    highlightColor: Colors.transparent,
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? pal.onAccent
            : pal.textTertiary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? pal.accent
            : pal.surfaceOverlay,
      ),
      trackOutlineColor: WidgetStatePropertyAll(pal.hairline),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
}
