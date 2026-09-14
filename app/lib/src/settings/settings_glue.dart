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

import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show MethodCall;

import '../../app_state.dart' show SpeechController;
import '../../hotkey_binding.dart';
import '../shell/history_retrieval.dart'
    show DefaultRegisterPick, NamedScenarioPick;
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
  bool? _lastOrbVisible;

  /// Open the settings window on [domain] — creating it hidden, with the
  /// current theme and selection riding its arguments (a push cannot beat
  /// the sub-engine's handler registration). The sub-engine owns the
  /// FIRST show: it stages the window (size, center, caption theme) while
  /// still hidden and only then shows itself — showing from this side
  /// would reveal the window at dmw's native default origin (10,10,
  /// 800×600) and it would visibly jump once the sub-engine's geometry
  /// lands. An already-open window is navigated and brought back instead.
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
          'orb': _controller.orbVisible,
          'primary': _controller.primaryChord.wire,
          'pin': _controller.pinChord.wire,
          'selected': _controller.selectedScenario,
        }),
        hiddenAtLaunch: true,
      ),
    );
    _window = controller;
    _lastTheme = _controller.themeMode;
    _lastSelection = _controller.selectedScenario;
    _lastOrbVisible = _controller.orbVisible;
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

  /// Push the orb's visibility (no-op while closed) — the general
  /// domain's switch follows tray toggles live.
  Future<void> syncOrbVisible(bool visible) async {
    if (_lastOrbVisible == visible) return;
    _lastOrbVisible = visible;
    final window = _window;
    if (window == null) return;
    try {
      await window.invokeMethod('orb-follow', visible);
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
      case 'global-changed':
        // The global directive's file changed: re-read it through the
        // controller and push the fresh text at the engine (ticket 22).
        await _controller.onGlobalDirectiveChanged();
      case 'scenario-selected':
        await _controller.selectScenario(call.arguments as String?);
      case 'theme-selected':
        // The general domain's tri-state mirror: the same single entry
        // the quick panel's switcher takes (wire format = mode name).
        await _controller.setThemeMode(
          ThemeMode.values.firstWhere(
            (mode) => mode.name == call.arguments,
            orElse: () => ThemeMode.system,
          ),
        );
      case 'set-orb-visible':
        // The general domain's orb switch: the same single entry the
        // tray checkbox and tray click take. Tolerance default: a
        // malformed push reads as visible.
        await _controller.setOrbVisible(call.arguments as bool? ?? true);
      case 'hotkeys-changed':
        // The general domain wrote a chord to ui.toml: re-read the file
        // (it is the truth) and hot-swap. The chord itself never rides
        // this event (map 06).
        await _controller.onHotkeysChanged();
      case 'hotkeys-paused':
        // Capture on a row: both product chords come off the OS so the
        // settings window can hear the press; ending capture re-hangs.
        await _controller.setHotkeysPaused(call.arguments as bool? ?? false);
      case 'history-changed':
        // The history domain reshaped the store (retention, keep-nothing,
        // clear): the quick panel's rows re-read the same bridge call.
        await _controller.loadRecentHistory();
      case 'history-rerectify':
        // History retrieval: the same entry point the quick panel's rows
        // take — the session window takes over from here. The pick rides
        // as a scenario's name or the default-register flag (ticket 28);
        // neither present reads as a vanished scenario, which the
        // controller degrades to the live selection.
        final args = call.arguments as Map<Object?, Object?>?;
        final style = args?['defaultRegister'] == true
            ? const DefaultRegisterPick()
            : NamedScenarioPick(args?['scenario'] as String? ?? '');
        await _controller.rerectifyHistory(
          args?['raw'] as String? ?? '',
          style: style,
        );
      case 'terms-changed':
        // The terms domain edited the dictionary file: the quick panel's
        // chips re-read the same bridge call (the engine re-reads per
        // session on its own).
        await _controller.loadTerms();
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
      _lastOrbVisible = null;
      // A capture left running (title-bar X, a dying isolate) must not
      // leave the product chords unregistered — map 06: closing the
      // settings window ends capture and re-hangs from the file.
      unawaited(_controller.setHotkeysPaused(false));
    }
  }

  /// Close the settings window through the proper chain, ahead of the
  /// main window's own close (tray exit). A sub-window left alive at
  /// process exit is torn down by post-loop static destructors with no
  /// message pump — seconds of a visibly frozen window (the small-fix
  /// 03 family). Closing it here runs its teardown inside the live pump
  /// (the title-bar X path), and we wait for the windows-changed prune
  /// to confirm it is really gone before the caller quits; a stuck
  /// window falls through after the bounded wait rather than blocking
  /// exit forever.
  Future<void> close() async {
    final window = _window;
    if (window == null) return;
    unawaited(window.invokeMethod('close', null).catchError((Object _) {}));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_window != null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _pruneWindow();
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
        // Tolerance default: anything but an explicit false reads as
        // visible — the ui.toml rule, applied at the wire too.
        orbVisible: decoded['orb'] != false,
        primary:
            HotkeyBinding.tryParse(decoded['primary'] as String? ?? '') ??
            HotkeyBinding.primaryDefault,
        pin:
            HotkeyBinding.tryParse(decoded['pin'] as String? ?? '') ??
            HotkeyBinding.pinDefault,
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
    this.orbVisible = true,
    this.primary = HotkeyBinding.primaryDefault,
    this.pin = HotkeyBinding.pinDefault,
    required this.selected,
  });

  final SettingsDomain domain;
  final ThemeMode theme;

  /// The orb's visibility at first paint (the general domain's switch);
  /// later changes follow over the channel.
  final bool orbVisible;

  /// The two product chords at first paint (the general domain's rows).
  final HotkeyBinding primary;
  final HotkeyBinding pin;
  final String? selected;
}
