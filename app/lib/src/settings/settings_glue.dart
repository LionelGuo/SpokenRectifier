/// The main window's side of the settings window: spawning/focusing the
/// sub-engine window, pushing theme and selection into it, and reacting
/// to its events (library changed, scenario selected). Thin platform
/// glue — the reactions all land in [SpeechController], which the widget
/// tests exercise; nothing here needs a second engine to be tested.
///
/// Window lifetime: the controller handle is dropped when the native
/// window goes away (watched via desktop_multi_window's windows-changed
/// stream), whether the user closed it via its title bar or it died
/// otherwise; a send into a dead window throws and the next open()
/// recreates it.

library;

import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show MethodCall;

import '../../app_state.dart' show SpeechController;
import 'settings_channel.dart' show settingsToMainChannel;
import 'settings_domain.dart';

/// Owns the settings window from the main engine.
class DesktopSettingsWindow {
  DesktopSettingsWindow(this._controller) {
    onWindowsChanged.listen((_) => _pruneWindow());
  }

  final SpeechController _controller;
  WindowController? _window;
  ThemeMode? _lastTheme;
  String? _lastSelection;

  /// Open the settings window on [domain] — creating it hidden, pushing
  /// the current theme and selection into its arguments (a push cannot
  /// beat the sub-engine's handler registration), then showing it. An
  /// already-open window is navigated and brought back instead.
  Future<void> open(SettingsDomain domain) async {
    final existing = _window;
    if (existing != null) {
      try {
        await existing.invokeMethod('navigate', domain.name);
        await existing.show();
        return;
      } catch (_) {
        _window = null; // died since we last looked; recreate below
      }
    }
    final controller = await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({
          'kind': 'settings',
          'domain': domain.name,
          'theme': _controller.themeMode.name,
          'selected': _controller.selectedScenario,
        }),
        hiddenAtLaunch: true,
      ),
    );
    _window = controller;
    _lastTheme = _controller.themeMode;
    _lastSelection = _controller.selectedScenario;
    await controller.show();
  }

  /// Push the theme to the settings window (no-op while closed).
  Future<void> syncTheme(ThemeMode mode) async {
    if (_lastTheme == mode) return;
    _lastTheme = mode;
    final window = _window;
    if (window == null) return;
    try {
      await window.invokeMethod('theme', mode.name);
    } catch (_) {}
  }

  /// Push the scenario selection (no-op while closed).
  Future<void> syncSelection(String? name) async {
    if (_lastSelection == name) return;
    _lastSelection = name;
    final window = _window;
    if (window == null) return;
    try {
      await window.invokeMethod('selection-follow', name);
    } catch (_) {}
  }

  /// The sub-window's events (registered on [settingsToMainChannel] by
  /// main.dart). Data never rides this channel — each event re-reads the
  /// file through the controller, the one place the pickers paint from.
  Future<dynamic> handleSubWindowCall(MethodCall call) async {
    switch (call.method) {
      case 'scenarios-changed':
        final args = call.arguments as Map<Object?, Object?>?;
        await _controller.onScenariosLibraryChanged(
          renamedFrom: args?['renamedFrom'] as String?,
          renamedTo: args?['renamedTo'] as String?,
        );
      case 'scenario-selected':
        await _controller.selectScenario(call.arguments as String?);
    }
    return null;
  }

  /// Drop the handle when the native window is gone, so a later open()
  /// creates a fresh one instead of talking to a corpse.
  Future<void> _pruneWindow() async {
    final window = _window;
    if (window == null) return;
    final alive = await WindowController.getAll();
    if (!alive.any((candidate) => candidate.windowId == window.windowId)) {
      _window = null;
      _lastTheme = null;
      _lastSelection = null;
    }
  }
}

/// Parse the sub-window's launch arguments (see [DesktopSettingsWindow.open]
/// for the producer). Null when this is the main engine.
SettingsLaunch? parseSettingsLaunch(String? windowArguments) {
  if (windowArguments == null) return null;
  try {
    final decoded = jsonDecode(windowArguments);
    if (decoded is Map<String, dynamic> && decoded['kind'] == 'settings') {
      return SettingsLaunch(
        domain: settingsDomainFromName(decoded['domain'] as String?),
        theme: ThemeMode.values.firstWhere(
          (mode) => mode.name == decoded['theme'],
          orElse: () => ThemeMode.system,
        ),
        selected: decoded['selected'] as String?,
      );
    }
  } on FormatException {
    // Not ours: the main engine's arguments, whatever they carry.
  }
  return null;
}

/// What the sub-engine needs at first paint, from the window arguments.
class SettingsLaunch {
  const SettingsLaunch({
    required this.domain,
    required this.theme,
    required this.selected,
  });

  final SettingsDomain domain;
  final ThemeMode theme;
  final String? selected;
}
