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
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
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

  /// The user picked a theme segment in the general domain — routed to
  /// the main controller's single `setThemeMode` entry (the quick
  /// panel's switcher is the other caller of the same path).
  Future<void> sendThemePicked(ThemeMode mode);

  /// The user flipped the orb's visibility switch in the general domain
  /// — routed to the main controller's single `setOrbVisible` entry
  /// (the tray checkbox and tray click share it).
  Future<void> sendOrbVisible(bool visible);

  /// A general-domain hotkey row wrote ui.toml (record / clear / restore).
  /// The chord does not ride this event — the file is the truth; the main
  /// engine re-reads and hot-swaps.
  Future<void> sendHotkeysChanged();

  /// Capture started or ended: the main engine unregisters both product
  /// chords for the duration so the settings window can hear the press.
  Future<void> sendHotkeysPaused(bool paused);

  /// The history store changed shape from the history domain (retention
  /// retightened, keep-nothing turned on, everything cleared): the main
  /// window re-reads its recent rows — an event, never mirrored state.
  Future<void> sendHistoryChanged();

  /// History retrieval (重新修正) from the history domain: the main
  /// window runs the utterance through the same rectify path the quick
  /// panel's rows use. [scenario] optionally names a one-time scenario
  /// (ticket 23): that session alone runs under it, the live selection
  /// stays untouched. [sourceSessionId] names the row being re-run.
  Future<void> sendHistoryRerectify(
    String rawTranscript, {
    required ScenarioPick style,
    required PlatformInt64? sourceSessionId,
  });

  /// The dictionary changed on disk (the terms domain's add/rename/
  /// remove — the same file the quick panel's quick-add writes): the
  /// main window re-reads its term chips; the engine re-reads per
  /// session on its own.
  Future<void> sendTermsChanged();

  // ---- inbound: main -> settings ----------------------------------------

  /// Theme follow (one-way from the main window's tri-state).
  set onTheme(void Function(ThemeMode mode) handler);

  /// Orb-visibility follow (the tray toggles while the window is open —
  /// the general domain's switch repaints at once).
  set onOrbVisible(void Function(bool visible) handler);

  /// Selection follow (the main window's pickers are the same selection).
  set onSelection(void Function(String? name) handler);

  /// The user asked for a domain from outside (quick panel entry rows).
  set onNavigate(void Function(SettingsDomain domain) handler);

  /// Connect the inbound callbacks to the native channel.
  Future<void> attach();
}

/// The production link over desktop_multi_window's method channels.
class DesktopSettingsChannel implements SettingsChannel {
  DesktopSettingsChannel({Future<void> Function()? revealPrep})
    // A named parameter cannot be private, so the initializing formal
    // this lint wants is not writable here.
    // ignore: prefer_initializing_formals
    : _revealPrep = revealPrep;

  final WindowMethodChannel _toMain = const WindowMethodChannel(
    settingsToMainChannel,
    mode: ChannelMode.unidirectional,
  );

  /// Run once before the first reveal of a prewarmed window (08 号票):
  /// its staging-time center may be stale by the time anyone navigates
  /// to it, so the reveal re-centers — and show() is what turns the
  /// hidden engine's window visible at all. Null for a normal window,
  /// which showed itself at staging.
  final Future<void> Function()? _revealPrep;

  bool _revealed = false;

  void Function(ThemeMode mode)? _onTheme;
  void Function(String? name)? _onSelection;
  void Function(SettingsDomain domain)? _onNavigate;
  void Function(bool visible)? _onOrbVisible;

  @override
  set onTheme(void Function(ThemeMode mode) handler) => _onTheme = handler;

  @override
  set onOrbVisible(void Function(bool visible) handler) =>
      _onOrbVisible = handler;

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
  Future<void> sendThemePicked(ThemeMode mode) =>
      _send('theme-selected', mode.name);

  @override
  Future<void> sendOrbVisible(bool visible) =>
      _send('set-orb-visible', visible);

  @override
  Future<void> sendHotkeysChanged() => _send('hotkeys-changed', null);

  @override
  Future<void> sendHotkeysPaused(bool paused) =>
      _send('hotkeys-paused', paused);

  @override
  Future<void> sendHistoryChanged() => _send('history-changed', null);

  @override
  Future<void> sendHistoryRerectify(
    String rawTranscript, {
    required ScenarioPick style,
    required PlatformInt64? sourceSessionId,
  }) => _send('history-rerectify', {
    'raw': rawTranscript,
    // The pick rides as one discriminator key: a scenario's name, or
    // the default-register flag — never both, so a name can never
    // collide with the flag.
    if (style is NamedScenarioPick) 'scenario': style.name,
    if (style is DefaultRegisterPick) 'defaultRegister': true,
    if (sourceSessionId != null) 'sourceId': sourceSessionId.toInt(),
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
      await _dispatch(call);
      return null;
    });
  }

  Future<void> _dispatch(MethodCall call) async {
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
      case 'orb-follow':
        // Tolerance default: a malformed push reads as visible.
        _onOrbVisible?.call(call.arguments as bool? ?? true);
      case 'navigate':
        _onNavigate?.call(settingsDomainFromName(call.arguments as String?));
        // The reveal (a prewarmed window's first navigate; a no-op for
        // a window that already showed itself at staging): recenter if
        // asked, show — the main side's show() is a bare SW_SHOW
        // (desktop_multi_window), which does not raise a background
        // window — and focus() restores a minimized one, raises it, and
        // brings it to the foreground.
        if (!_revealed) {
          _revealed = true;
          await _revealPrep?.call();
          await windowManager.show();
        }
        unawaited(windowManager.focus());
      case 'close':
        // Tray exit closes the settings window FIRST, through its own
        // WM_CLOSE -> DestroyWindow chain (the title-bar X path). Riding
        // process teardown instead parks this engine's shutdown in
        // post-loop static destructors — seconds of a visibly frozen
        // window. Fire-and-forget: this isolate dies inside the call.
        unawaited(windowManager.close());
    }
  }
}
