/// App bootstrap: window shape, tray, global hotkey, and the Rust engine.
///
/// Everything platform-touching lives here; the UI tree in app_root.dart
/// stays pure and testable. Window bounds after startup belong to the
/// stage choreography (src/shell/window_stage.dart) — this file only
/// sets the orb footprint once at launch.

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PhysicalKeyboardKey;

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
import 'src/shell/window_stage.dart' show StageWindow, WindowManagerStageWindow;
import 'ui_prefs.dart';

const _toggleOrbKey = 'toggle-orb';
const _scenarioMenuKey = 'scenario-menu';
const _scenarioDefaultKey = 'scenario-default';
const _scenarioItemKeyPrefix = 'scenario-item:';
const _openConfigKey = 'open-config';
const _clearHistoryKey = 'clear-history';
const _exitKey = 'exit';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  runApp(_Shell(controller: controller, stageWindow: const WindowManagerStageWindow()));
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
  const _Shell({required this.controller, required this.stageWindow});

  final SpeechController controller;
  final StageWindow stageWindow;

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
          // every library entry, applying from the next rectify on.
          // Scenario keys carry an `scenario-item:` prefix so an entry
          // literally named "default" can never collide with the 默认
          // item's reserved key.
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
    );
  }
}
