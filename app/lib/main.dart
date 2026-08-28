/// App bootstrap: window shape, tray, global hotkey, and the Rust engine.
///
/// Everything platform-touching lives here; the UI tree in app_root.dart
/// stays pure and testable. Window bounds after startup belong to the
/// stage choreography (src/shell/window_stage.dart) — this file only
/// sets the orb footprint once at launch.
///
/// Two entry modes in one executable: desktop_multi_window re-runs this
/// main() for the settings window's engine, passing entrypoint arguments
/// ["multi_window", <windowId>, <windowArgument>] (the windowArgument is
/// our JSON, kind 'settings') — the race-free way a sub-engine learns
/// what it is (querying the channel instead races the sub-engine's
/// channel registration and loses; spike 2026-08-28).

library;

import 'dart:async' show unawaited;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PhysicalKeyboardKey;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_root.dart';
import 'app_state.dart';
import 'gateway.dart';
import 'sample_speech.dart';
import 'src/design/tokens.dart' show SrGeometry;
import 'src/rust/api.dart' show BridgeSessionState, createEngine;
import 'src/rust/frb_generated.dart' show RustLib;
import 'src/settings/caption_theme.dart';
import 'src/settings/connection_store.dart';
import 'src/settings/fidelity_eval.dart';
import 'src/settings/history_store.dart';
import 'src/settings/settings_channel.dart';
import 'src/settings/settings_domain.dart';
import 'src/settings/settings_glue.dart';
import 'src/settings/settings_store.dart';
import 'src/settings/settings_window.dart';
import 'src/settings/system_store.dart';
import 'src/settings/terms_store.dart';
import 'src/shell/window_stage.dart' show StageWindow, WindowManagerStageWindow;
import 'ui_prefs.dart';

const _toggleOrbKey = 'toggle-orb';
const _scenarioMenuKey = 'scenario-menu';
const _scenarioDefaultKey = 'scenario-default';
const _scenarioItemKeyPrefix = 'scenario-item:';
const _openConfigKey = 'open-config';
const _clearHistoryKey = 'clear-history';
const _exitKey = 'exit';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sub-engine entry: desktop_multi_window re-runs main per window with
  // the entrypoint arguments it set natively. The main engine carries
  // the exe's own command line instead (normally empty).
  if (args.isNotEmpty && args.first == 'multi_window') {
    final launch = parseSettingsLaunch(args.length > 2 ? args[2] : null);
    if (launch != null) {
      await _runSettingsWindow(launch);
      return;
    }
    // A sub-window that is not ours to render (none exists today): park
    // empty rather than running a second orb shell in it.
    runApp(const SizedBox.shrink());
    return;
  }

  await windowManager.ensureInitialized();

  // No titleBarStyle: the runner creates a pure WS_POPUP window.
  // TitleBarStyle.hidden would re-enter window_manager's WM_NCCALCSIZE
  // trimming, which keeps 8-px non-client strips on the left/right/bottom
  // edges (visible as bright lines on a transparent window, and the cause
  // of the old ~9px view inset) — spec §3, finding 4.
  const options = WindowOptions(
    size: SrGeometry.orbFootprint,
    minimumSize: SrGeometry.orbFootprint,
    alwaysOnTop: true,
    skipTaskbar: true,
    title: 'SpokenRectifier',
    backgroundColor: Colors.transparent,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAlignment(Alignment.bottomRight);
    // Pull the orb 24px inside the work area so it does not hug edges.
    final pos = await windowManager.getPosition();
    await windowManager.setPosition(pos.translate(-24, -24));
    await windowManager.show();
  });

  await RustLib.init();
  // The engine must exist before anything subscribes to its event stream:
  // the controller's constructor subscribes immediately, and a subscribe
  // that races engine creation errors out and takes the pending
  // createEngine future down with it (ghost window, no hotkey). So:
  // create, then build the shell around the outcome.
  String? startupError;
  try {
    // Real default microphone (capture + VAD) as the speech source; real
    // rectify LLM and real insertion when the config keys resolve, with
    // the scripted responses as the pure-demo fallback.
    await createEngine(llmResponses: sampleRectified);
  } catch (e) {
    // e.g. an ASR key without an LLM key: keep the app alive and show the
    // problem instead of failing the launch with a dead window.
    startupError = '初始化失败:$e';
  }
  await TrayManager.instance.setIcon('assets/tray_icon.ico');

  // The theme rides the app-owned prefs file (missing file = follow the
  // system); the quick panel's tri-state switcher writes it back.
  final controller = SpeechController(
    gateway: RustSpeechEngineGateway(),
    themeMode: loadUiThemeMode(uiPrefsSearchDirs()),
  );
  if (startupError != null) {
    controller.reportStartupError(startupError);
  }
  // Paint the scenario pickers from the library file (empty library =
  // pickers hidden; selection always starts on the default register).
  await controller.loadScenarios();
  // The quick panel's passage-mode toggle paints the engine's current
  // value (config-seeded; never persisted).
  await controller.loadPassageMode();

  await _installHotkey(controller);

  // The settings window (an independent OS window): the quick panel's
  // entry rows open it on a domain, and its events come back through
  // the controller — the single source every picker paints from.
  final settingsWindow = DesktopSettingsWindow(controller);
  await WindowMethodChannel(
    settingsToMainChannel,
    mode: ChannelMode.unidirectional,
  ).setMethodCallHandler(settingsWindow.handleSubWindowCall);
  controller.addListener(() {
    // One-way follow: theme and selection repaint the open settings
    // window (no-ops while it is closed).
    unawaited(settingsWindow.syncTheme(controller.themeMode));
    unawaited(settingsWindow.syncSelection(controller.selectedScenario));
  });

  runApp(
    _Shell(
      controller: controller,
      stageWindow: const WindowManagerStageWindow(),
      onOpenSettings: settingsWindow.open,
    ),
  );
}

/// The settings window's engine entry: a standard OS window (title bar,
/// taskbar entry, centered, resizable — spec §4.4), not a panel of the
/// morphing orb window. The bridge initializes per engine; the Rust side
/// is one process/one dylib, so this engine reads and writes the very
/// files the orb shell's engine sees (the file is the sync, the channel
/// only carries events).
Future<void> _runSettingsWindow(SettingsLaunch launch) async {
  await windowManager.ensureInitialized();
  await RustLib.init();

  const options = WindowOptions(
    size: Size(920, 640),
    minimumSize: Size(760, 520),
    title: settingsWindowTitle,
    titleBarStyle: TitleBarStyle.normal,
    center: true,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    // Paint the caption before the first show (no flash of the
    // system-seeded color): dmw seeds it from the SYSTEM apps theme, the
    // launch arguments already carry the app's.
    applyWindowsCaptionTheme(
      effectiveBrightness(
        launch.theme,
        PlatformDispatcher.instance.platformBrightness,
      ),
    );
    await windowManager.show();
    await windowManager.focus();
  });

  final channel = DesktopSettingsChannel();
  runApp(
    SettingsWindowApp(
      store: const RustScenarioStore(),
      channel: channel,
      initialDomain: launch.domain,
      initialTheme: launch.theme,
      initialSelection: launch.selected,
      historyStore: const RustHistorySettingsStore(),
      evalRunner: const RustFidelityEvalRunner(),
      termsStore: const RustTermsStore(),
      connectionStore: const RustConnectionStore(),
      systemStore: const RustSystemStore(),
    ),
  );
}

Future<void> _installHotkey(SpeechController controller) async {
  await HotKeyManager.instance.register(
    HotKey(
      key: PhysicalKeyboardKey.keyV,
      modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
    ),
    keyDownHandler: (_) => controller.hotkeyToggle(),
  );
}

/// Hosts the tray listener; window morphing lives in the stage host.
class _Shell extends StatefulWidget {
  const _Shell({
    required this.controller,
    required this.stageWindow,
    required this.onOpenSettings,
  });

  final SpeechController controller;
  final StageWindow stageWindow;
  final Future<void> Function(SettingsDomain domain) onOpenSettings;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> with TrayListener {
  SpeechController get controller => widget.controller;

  /// Last values the tray reflected, so token-dense transcript events do
  /// not rebuild the menu.
  BridgeSessionState? _trayPhase;
  bool? _trayOrbVisible;
  String? _trayScenario;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    controller.addListener(_onControllerChanged);
    // Paint the initial tooltip and menu before any event arrives.
    _refreshTray();
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    trayManager.removeListener(this);
    super.dispose();
  }

  void _onControllerChanged() {
    if (_trayPhase != controller.phase ||
        _trayOrbVisible != controller.orbVisible ||
        _trayScenario != controller.selectedScenario) {
      _refreshTray();
    }
  }

  Future<void> _refreshTray() async {
    _trayPhase = controller.phase;
    _trayOrbVisible = controller.orbVisible;
    _trayScenario = controller.selectedScenario;
    // Status wording aligned with the session window's phase vocabulary.
    final phase = switch (controller.phase) {
      BridgeSessionState.idle => '空闲',
      BridgeSessionState.recording => '聆听中',
      BridgeSessionState.rectifying => '修正中',
      BridgeSessionState.preview => '预览',
      BridgeSessionState.inserted => '已插入',
      BridgeSessionState.cancelled => '已取消',
    };
    await trayManager.setToolTip('SpokenRectifier · $phase');
    await trayManager.setContextMenu(
      Menu(
        items: [
          // The orb's visibility switch lives here only — no panel owns
          // it (a hidden orb has no surface to un-hide it).
          MenuItem.checkbox(
            key: _toggleOrbKey,
            label: '显示悬浮球',
            checked: controller.orbVisible,
          ),
          // The scenario submenu mirrors the session chip: 默认 plus
          // every library entry, applying from the next rectify on —
          // and hides entirely over an empty library (a lone 默认 has
          // nothing to pick between; the editor is the creation path).
          // Scenario keys carry an `scenario-item:` prefix so an entry
          // literally named "default" can never collide with the 默认
          // item's reserved key.
          if (controller.scenarios.isNotEmpty)
            MenuItem.submenu(
              key: _scenarioMenuKey,
              label: '场景',
              submenu: Menu(
                items: [
                  MenuItem.checkbox(
                    key: _scenarioDefaultKey,
                    label: '默认',
                    checked: controller.selectedScenario == null,
                  ),
                  for (final scenario in controller.scenarios)
                    MenuItem.checkbox(
                      key: '$_scenarioItemKeyPrefix${scenario.name}',
                      label: scenario.name,
                      checked: controller.selectedScenario == scenario.name,
                    ),
                ],
              ),
            ),
          MenuItem(key: _openConfigKey, label: '打开配置文件'),
          MenuItem(key: _clearHistoryKey, label: '清空历史'),
          MenuItem.separator(),
          MenuItem(key: _exitKey, label: '退出'),
        ],
      ),
    );
  }

  @override
  Future<void> onTrayIconMouseDown() async {
    controller.setOrbVisible(!controller.orbVisible);
  }

  @override
  Future<void> onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case _toggleOrbKey:
        controller.setOrbVisible(!controller.orbVisible);
      // The 默认 item owns its reserved key; scenario items carry the
      // `scenario-item:` prefix plus the entry name, so the two can
      // never collide (an entry named "default" stays reachable).
      case _scenarioDefaultKey:
        await controller.selectScenario(null);
      case final String key when key.startsWith(_scenarioItemKeyPrefix):
        await controller.selectScenario(
          key.substring(_scenarioItemKeyPrefix.length),
        );
      case _openConfigKey:
        await controller.openConfigFile();
      case _clearHistoryKey:
        await controller.clearHistory();
      case _exitKey:
        await windowManager.destroy();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SpokenRectifierApp(
      controller: controller,
      stageWindow: widget.stageWindow,
      onOpenSettings: widget.onOpenSettings,
    );
  }
}
