/// The settings window's cross-window link: how the sub-engine talks to
/// the main window. Only events ride this channel — the library data
/// itself always comes from the file via the bridge ([ScenarioStore]),
/// never as mirrored state. The main window owns the reactions: a
/// scenarios-changed event re-reads the library and repaints its three
/// pickers (tray, quick panel, session chip); a scenario-selected event
/// routes through the one [SpeechController.selectScenario] entry.
///
/// Injectable so the settings window's widget tests run with a recording
/// fake — no second engine, no platform channels.

library;

import 'dart:async' show unawaited;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show MethodCall;
import 'package:window_manager/window_manager.dart' show windowManager;

import '../shell/history_retrieval.dart'
    show DefaultRegisterPick, NamedScenarioPick, ScenarioPick;
import 'settings_domain.dart';

/// The channel both windows address the main window by (registered there
/// in unidirectional mode: one handler, every engine may invoke). The
/// glue on the main side registers its handler under this same name.
const settingsToMainChannel = 'spokenrectifier/settings-to-main';

/// The settings sub-window's side of the link.
abstract class SettingsChannel {
  // ---- outbound: settings -> main ---------------------------------------

  /// The library changed on disk; a rename that should carry the current
  /// selection across identifies itself (old name, new name).
  Future<void> sendScenariosChanged({String? renamedFrom, String? renamedTo});

  /// The global directive changed on disk (ticket 22): the main window
  /// re-reads the file and pushes the fresh text at the engine — an
  /// event, never mirrored state.
  Future<void> sendGlobalChanged();

  /// The user picked a scenario in the editor (null = default register).
  Future<void> sendScenarioSelected(String? name);

  /// The history store changed shape from the history domain (retention
  /// retightened, keep-nothing turned on, everything cleared): the main
  /// window re-reads its recent rows — an event, never mirrored state.
  Future<void> sendHistoryChanged();

  /// History retrieval (重新修正) from the history domain: the main
  /// window runs the utterance through the same rectify path the quick
  /// panel's rows use. [scenario] optionally names a one-time scenario
  /// (ticket 23): that session alone runs under it, the live selection
  /// stays untouched.
  Future<void> sendHistoryRerectify(
    String rawTranscript, {
    required ScenarioPick style,
  });

  /// The dictionary changed on disk (the terms domain's add/rename/
  /// remove — the same file the quick panel's quick-add writes): the
  /// main window re-reads its term chips; the engine re-reads per
  /// session on its own.
  Future<void> sendTermsChanged();

  // ---- inbound: main -> settings ----------------------------------------

  /// Theme follow (one-way from the main window's tri-state).
  set onTheme(void Function(ThemeMode mode) handler);

  /// Selection follow (the main window's pickers are the same selection).
  set onSelection(void Function(String? name) handler);

  /// The user asked for a domain from outside (quick panel entry rows).
  set onNavigate(void Function(SettingsDomain domain) handler);

  /// Connect the inbound callbacks to the native channel.
  Future<void> attach();
}

/// The production link over desktop_multi_window's method channels.
class DesktopSettingsChannel implements SettingsChannel {
  final WindowMethodChannel _toMain = const WindowMethodChannel(
    settingsToMainChannel,
    mode: ChannelMode.unidirectional,
  );

  void Function(ThemeMode mode)? _onTheme;
  void Function(String? name)? _onSelection;
  void Function(SettingsDomain domain)? _onNavigate;

  @override
  set onTheme(void Function(ThemeMode mode) handler) => _onTheme = handler;

  @override
  set onSelection(void Function(String? name) handler) =>
      _onSelection = handler;

  @override
  set onNavigate(void Function(SettingsDomain domain) handler) =>
      _onNavigate = handler;

  @override
  Future<void> sendScenariosChanged({String? renamedFrom, String? renamedTo}) =>
      _send('scenarios-changed', {
        'renamedFrom': ?renamedFrom,
        'renamedTo': ?renamedTo,
      });

  @override
  Future<void> sendGlobalChanged() => _send('global-changed', null);

  @override
  Future<void> sendScenarioSelected(String? name) =>
      _send('scenario-selected', name);

  @override
  Future<void> sendHistoryChanged() => _send('history-changed', null);

  @override
  Future<void> sendHistoryRerectify(
    String rawTranscript, {
    required ScenarioPick style,
  }) => _send('history-rerectify', {
    'raw': rawTranscript,
    // The pick rides as one discriminator key: a scenario's name, or
    // the default-register flag — never both, so a name can never
    // collide with the flag.
    if (style is NamedScenarioPick) 'scenario': style.name,
    if (style is DefaultRegisterPick) 'defaultRegister': true,
  });

  @override
  Future<void> sendTermsChanged() => _send('terms-changed', null);

  Future<void> _send(String method, dynamic arguments) async {
    try {
      await _toMain.invokeMethod(method, arguments);
    } catch (_) {
      // The main window is always there in production; a dropped event
      // (e.g. mid-teardown) is not actionable.
    }
  }

  @override
  Future<void> attach() async {
    final controller = await WindowController.fromCurrentEngine();
    await controller.setWindowMethodHandler((call) async {
      _dispatch(call);
      return null;
    });
  }

  void _dispatch(MethodCall call) {
    switch (call.method) {
      case 'theme':
        final name = call.arguments as String?;
        final mode = ThemeMode.values.firstWhere(
          (mode) => mode.name == name,
          orElse: () => ThemeMode.system,
        );
        _onTheme?.call(mode);
      case 'selection-follow':
        _onSelection?.call(call.arguments as String?);
      case 'navigate':
        _onNavigate?.call(settingsDomainFromName(call.arguments as String?));
        // The main side's show() is a bare SW_SHOW (desktop_multi_window),
        // which does not raise a background window; focus() restores a
        // minimized one, raises it, and brings it to the foreground.
        unawaited(windowManager.focus());
    }
  }
}
