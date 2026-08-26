/// App bootstrap: window shape, tray, global hotkey, and the Rust engine.
///
/// Everything platform-touching lives here; the UI tree in app_root.dart
/// stays pure and testable.

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PhysicalKeyboardKey;

import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_root.dart'
    show SpokenRectifierApp, orbWindowSize, windowSizeFor;
import 'app_state.dart';
import 'gateway.dart';
import 'sample_speech.dart';
import 'src/rust/api.dart' show BridgeSessionState, createEngine;
import 'src/rust/frb_generated.dart' show RustLib;

const _toggleOrbKey = 'toggle-orb';
const _styleMenuKey = 'style-menu';
const _styleDefaultKey = 'style-default';
const _styleScenarioKeyPrefix = 'style-scenario:';
const _openConfigKey = 'open-config';
const _clearHistoryKey = 'clear-history';
const _exitKey = 'exit';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: orbWindowSize,
    minimumSize: orbWindowSize,
    alwaysOnTop: true,
    skipTaskbar: true,
    title: 'SpokenRectifier',
    titleBarStyle: TitleBarStyle.hidden,
    backgroundColor: Colors.transparent,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAlignment(Alignment.bottomRight);
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

  final controller = SpeechController(gateway: RustSpeechEngineGateway());
  if (startupError != null) {
    controller.reportStartupError(startupError);
  }
  // Paint the scenario pickers from the library file (empty library =
  // pickers hidden; selection always starts on the default register).
  await controller.loadScenarios();

  await _installHotkey(controller);

  runApp(_Shell(controller: controller));
}

Future<void> _installHotkey(SpeechController controller) async {
  await HotKeyManager.instance.register(
    HotKey(
      key: PhysicalKeyboardKey.keyV,
      modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
    ),
    keyDownHandler: (_) => controller.toggleSession(),
  );
}

/// Hosts the tray listener and morphs the window with the phase.
class _Shell extends StatefulWidget {
  const _Shell({required this.controller});

  final SpeechController controller;

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
  Size _lastSize = orbWindowSize;

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
    _morphWindow();
    if (_trayPhase != controller.phase ||
        _trayOrbVisible != controller.orbVisible ||
        _trayScenario != controller.selectedScenario) {
      _refreshTray();
    }
  }

  Future<void> _morphWindow() async {
    final target = windowSizeFor(
      controller.phase,
      panelExpanded: controller.panelExpanded,
      historyOpen: controller.historyOpen,
    );
    if (target != _lastSize) {
      _lastSize = target;
      await windowManager.setSize(target);
    }
  }

  Future<void> _refreshTray() async {
    _trayPhase = controller.phase;
    _trayOrbVisible = controller.orbVisible;
    _trayScenario = controller.selectedScenario;
    final phase = switch (controller.phase) {
      BridgeSessionState.idle => '空闲',
      BridgeSessionState.recording => '录音中',
      BridgeSessionState.rectifying => '修正中',
      BridgeSessionState.preview => '等待确认',
      BridgeSessionState.inserted => '已插入',
      BridgeSessionState.cancelled => '已取消',
    };
    await trayManager.setToolTip('SpokenRectifier · $phase');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem.checkbox(
            key: _toggleOrbKey,
            label: '显示悬浮球',
            checked: controller.orbVisible,
          ),
          // The scenario submenu mirrors the panel's picker row: 默认
          // plus every library entry. Scenario keys carry a `scenario:`
          // prefix so an entry literally named "default" can never
          // collide with the 默认 item's reserved key.
          MenuItem.submenu(
            key: _styleMenuKey,
            label: '风格',
            submenu: Menu(
              items: [
                MenuItem.checkbox(
                  key: _styleDefaultKey,
                  label: '默认',
                  checked: controller.selectedScenario == null,
                ),
                for (final scenario in controller.scenarios)
                  MenuItem.checkbox(
                    key: '$_styleScenarioKeyPrefix${scenario.name}',
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
      // `style-scenario:` prefix plus the entry name, so the two can
      // never collide (an entry named "default" stays reachable).
      case _styleDefaultKey:
        await controller.selectScenario(null);
      case final String key when key.startsWith(_styleScenarioKeyPrefix):
        await controller.selectScenario(
          key.substring(_styleScenarioKeyPrefix.length),
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
    return SpokenRectifierApp(controller: controller);
  }
}
