/// The main window's side of the settings window: spawning/focusing the
/// sub-engine window, pushing theme and selection into it, and reacting
/// to its events (library changed, scenario selected). Thin platform
/// glue — the reactions all land in [SpeechController], which the widget
/// tests exercise; nothing here needs a second engine to be tested.
///
/// Window lifetime: the controller handle is dropped when the native
/// window goes away (watched via desktop_multi_window's windows-changed
/// stream), whether the user closed it via its title bar or it died
/// otherwise. Death is confirmed against the window list, never
/// presumed from a failed send — a send into a just-created window
/// fails while its sub-engine is still booting, and replacing that
/// window was the overlapping-settings-windows bug.

library;

import 'dart:async' show Timer, unawaited;
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show MethodCall;

import '../../app_state.dart' show SpeechController;
import '../../hotkey_binding.dart';
import '../perf_log.dart';
import '../shell/history_retrieval.dart'
    show DefaultRegisterPick, NamedScenarioPick;
import 'settings_channel.dart' show settingsToMainChannel;
import 'settings_domain.dart';

/// Owns the settings window from the main engine.
class DesktopSettingsWindow {
  DesktopSettingsWindow(
    this._controller, {
    Stream<void>? windowsChanged,
    this.prewarmArmDelay = Duration.zero,
  }) : _windowsChanged = windowsChanged ?? onWindowsChanged {
    _windowsChanged.listen((_) => _pruneWindow());
  }

  final SpeechController _controller;

  /// The windows-changed stream (dmw's in production; injectable so the
  /// prune path is testable without a native window actually dying).
  final Stream<void> _windowsChanged;

  /// How long after an arm call before the boot fires — zero by
  /// default: the quiet window that keeps the boot off the quick
  /// panel's gestures lives with the signal's source (the panel's
  /// reveal-arm, 16 号票), and this timer is only the debounce for
  /// repeated arms. Injectable so tests can widen it.
  final Duration prewarmArmDelay;

  WindowController? _window;
  ThemeMode? _lastTheme;
  String? _lastSelection;
  bool? _lastOrbVisible;
  Timer? _prewarmTimer;

  /// Set by the exit chain's [close]: the prunes it drives must not
  /// re-arm the prewarm and resurrect a window on the way out.
  bool _closing = false;

  /// Opens run one at a time, in click order. A create takes a whole
  /// sub-engine (hundreds of milliseconds), so concurrent opens would
  /// each see no window yet and each spawn one; a queued open runs
  /// after the create it waited on and takes the navigate-an-existing-
  /// window path instead.
  Future<void> _openQueue = Future<void>.value();

  /// Open the settings window on [domain] — creating it hidden, with the
  /// current theme and selection riding its arguments (a push cannot beat
  /// the sub-engine's handler registration). The sub-engine owns the
  /// FIRST show: it stages the window (size, center, caption theme) while
  /// still hidden and only then shows itself — showing from this side
  /// would reveal the window at dmw's native default origin (10,10,
  /// 800×600) and it would visibly jump once the sub-engine's geometry
  /// lands. An already-open window is navigated and brought back instead.
  Future<void> open(SettingsDomain domain) {
    final opened = _openQueue.then((_) => _open(domain));
    // A failed open must not poison the queue for the next click.
    _openQueue = opened.then<void>((_) {}, onError: (Object _) {});
    return opened;
  }

  Future<void> _open(SettingsDomain domain) async {
    final watch = Stopwatch()..start();
    final existing = _window;
    if (existing != null) {
      if (await _navigateExisting(existing, domain)) {
        // The warm path's whole story (08 号票): click to shown, over a
        // sub-engine that already booted (today: an open window being
        // re-navigated; after prewarm: every open past the first idle).
        logPerf('settings_reopen', watch.elapsed);
        return;
      }
      _window = null; // confirmed gone from the window list
    }
    // The cold path's epoch: the sub-engine stamps its own entry against
    // this same wall clock (one process, one clock), so click-to-entry —
    // the sub-engine's whole boot — reads straight off the log.
    logPerfStamp('settings_click');
    final controller = await _createWindow(domain, prewarm: false);
    _window = controller;
    _lastTheme = _controller.themeMode;
    _lastSelection = _controller.selectedScenario;
    _lastOrbVisible = _controller.orbVisible;
  }

  /// What a fresh sub-engine needs at first paint, riding its launch
  /// arguments (see [open] for why a push cannot replace this).
  Map<String, dynamic> _launchPayload(
    SettingsDomain domain, {
    required bool prewarm,
  }) => {
    'kind': 'settings',
    if (prewarm) 'prewarm': true,
    'domain': domain.name,
    'theme': _controller.themeMode.name,
    'orb': _controller.orbVisible,
    'primary': _controller.primaryChord.wire,
    'pin': _controller.pinChord.wire,
    'selected': _controller.selectedScenario,
  };

  Future<WindowController> _createWindow(
    SettingsDomain domain, {
    required bool prewarm,
  }) => WindowController.create(
    WindowConfiguration(
      arguments: jsonEncode(_launchPayload(domain, prewarm: prewarm)),
      hiddenAtLaunch: true,
    ),
  );

  /// Arm the prewarm (08 号票; policy re-aimed in 16 号票): boot the
  /// settings sub-engine hidden in the background so an open is a
  /// navigate-and-show over a booted engine instead of a whole cold
  /// start. The arm signal is the quick panel standing open — the only
  /// doorway to settings — not startup and not a close: every sub-engine
  /// death leaks GPU memory the driver never reclaims (16 号票's
  /// measurement), so engines are born only where a settings open is
  /// plausibly minutes away, and never automatically after a close.
  /// [prewarmArmDelay] after the arm call, the boot fires.
  void armPrewarm() => _schedulePrewarm(prewarmArmDelay);

  void _schedulePrewarm(Duration delay) {
    if (_closing) return;
    _prewarmTimer?.cancel();
    _prewarmTimer = Timer(delay, () {
      _prewarmTimer = null;
      unawaited(prewarm());
    });
  }

  /// Boot the settings window hidden now; a no-op when one already
  /// exists. Rides the open queue: a click landing mid-boot queues
  /// behind it and takes the navigate path, never a second create.
  Future<void> prewarm() {
    final warmed = _openQueue.then((_) => _prewarm());
    _openQueue = warmed.then<void>((_) {}, onError: (Object _) {});
    return warmed;
  }

  Future<void> _prewarm() async {
    if (_window != null || _closing) return;
    final controller = await _createWindow(
      SettingsDomain.scenarios,
      prewarm: true,
    );
    _window = controller;
    _lastTheme = _controller.themeMode;
    _lastSelection = _controller.selectedScenario;
    _lastOrbVisible = _controller.orbVisible;
    // The create resolves before the sub-engine finishes booting; the
    // sub's own settings_frame RSS stamp is the settled second-engine
    // cost — this one just anchors the before.
    logPerfMem('prewarm_created');
  }

  /// Navigate the open window to [domain] and bring it back. False
  /// only when the window is confirmed gone from the native window
  /// list: a send that fails while the window is still listed is a
  /// sub-engine created a moment ago whose channel handler has not
  /// attached yet (booting, not dead — its first show and domain rode
  /// the launch arguments), which the bounded retry rides out.
  Future<bool> _navigateExisting(
    WindowController window,
    SettingsDomain domain,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await window.invokeMethod('navigate', domain.name);
        await window.show();
        return true;
      } catch (_) {
        if (!await _isListed(window)) return false;
        // Still alive but wedged past the bound: drop this click — the
        // one-window invariant outranks the navigation.
        if (attempt >= 50) return true;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// The authoritative aliveness check (the windows-changed stream's
  /// pull form). An unreadable list errs on the side of alive: a
  /// window is never replaced on doubt.
  Future<bool> _isListed(WindowController window) async {
    try {
      final alive = await WindowController.getAll();
      return alive.any((candidate) => candidate.windowId == window.windowId);
    } catch (_) {
      return true;
    }
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
        final sourceId = args?['sourceId'] as int?;
        await _controller.rerectifyHistory(
          args?['raw'] as String? ?? '',
          style: style,
          sourceSessionId: sourceId == null
              ? null
              : PlatformInt64Util.from(sourceId),
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
    if (await _isListed(window)) return;
    _window = null;
    _lastTheme = null;
    _lastSelection = null;
    _lastOrbVisible = null;
    // The teardown's own number (16 号票): whether the resident set
    // actually returns the second engine's pages decides if a retire-
    // and-rearm lever is worth anything.
    logPerfMem('settings_pruned');
    // A capture left running (title-bar X, a dying isolate) must not
    // leave the product chords unregistered — map 06: closing the
    // settings window ends capture and re-hangs from the file.
    unawaited(_controller.setHotkeysPaused(false));
    // No re-arm here (16 号票): a sub-engine's death leaks GPU memory,
    // so nothing respawns one on its own — the next quick-panel reveal
    // arms the next boot, where a settings open is plausibly close.
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
    // The exit chain: nothing this side does from here on may spawn a
    // replacement window (the prunes below re-arm the prewarm).
    _closing = true;
    _prewarmTimer?.cancel();
    // Wait out an in-flight open first: a create resolving after this
    // returns would leave a live window riding into process exit (the
    // frozen-linger family, small-fix 08).
    await _openQueue;
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
        // The prewarm marker (08 号票): stage but never self-show.
        hidden: decoded['prewarm'] == true,
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
    this.hidden = false,
    this.orbVisible = true,
    this.primary = HotkeyBinding.primaryDefault,
    this.pin = HotkeyBinding.pinDefault,
    required this.selected,
  });

  final SettingsDomain domain;
  final ThemeMode theme;

  /// A prewarmed create (08 号票): the engine stages itself — geometry,
  /// caption theme, first frame — but never shows; the first navigate
  /// from the main window reveals (and re-centers) it.
  final bool hidden;

  /// The orb's visibility at first paint (the general domain's switch);
  /// later changes follow over the channel.
  final bool orbVisible;

  /// The two product chords at first paint (the general domain's rows).
  final HotkeyBinding primary;
  final HotkeyBinding pin;
  final String? selected;
}
