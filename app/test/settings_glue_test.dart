/// The main-window settings glue's one-window invariant (small-fix 15):
/// however fast the quick panel's entry rows are clicked, at most one
/// settings window ever exists. The races that broke it — concurrent
/// opens each spawning a sub-engine, and a send into a just-created
/// window (its handler not yet attached) being misread as death — are
/// driven through a recording fake of the desktop_multi_window plugin
/// on the default binary messenger: no second engine, no Rust dylib.

library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/settings/settings_domain.dart';
import 'package:spokenrectifier_app/src/settings/settings_glue.dart';

import 'fake_gateway.dart';

const _mainChannel = MethodChannel('mixin.one/desktop_multi_window');
const _windowChannels = MethodChannel('mixin.one/desktop_multi_window/channels');

/// A recording stand-in for the desktop_multi_window plugin's native
/// side: the windows it has created (and whether they are still
/// listed), the window_ calls and cross-window sends that rode its
/// channels, and the two failure switches the races need — a gated
/// create (spawning a sub-engine takes real time) and a booting
/// sub-engine whose handler has not attached yet.
class _FakeMultiWindow {
  _FakeMultiWindow() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_mainChannel, (call) async {
          switch (call.method) {
            case 'createWindow':
              createCalls++;
              creates.add((call.arguments as Map)['arguments'] as String);
              final id = 'w$createCalls';
              final gate = gateCreate;
              if (gate != null) await gate.future;
              alive.add(id);
              return id;
            case 'window_show':
              shown.add((call.arguments as Map)['windowId'] as String);
            case 'getAllWindows':
              return alive
                  .map((id) => {'windowId': id, 'windowArgument': ''})
                  .toList();
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowChannels, (call) async {
          if (call.method != 'invokeMethod') return null;
          final args = call.arguments as Map;
          final windowId =
              (args['channel'] as String).split('/').last;
          final method = args['method'] as String;
          if (dead.contains(windowId)) {
            throw PlatformException(
              code: 'CHANNEL_NOT_FOUND',
              message: 'window gone',
            );
          }
          if (method == 'close') {
            alive.remove(windowId);
            return null;
          }
          if (bootFailures > 0) {
            bootFailures--;
            throw PlatformException(
              code: 'CHANNEL_NOT_FOUND',
              message: 'handler not attached yet',
            );
          }
          sent.add((windowId, method, args['arguments']));
          return null;
        });
  }

  int createCalls = 0;
  final creates = <String>[];
  final alive = <String>[];
  final shown = <String>[];
  final sent = <(String, String, dynamic)>[];
  final dead = <String>{};

  /// Holds every createWindow in flight until completed — the window
  /// a rapid second click has to NOT see yet.
  Completer<void>? gateCreate;

  /// How many cross-window sends still fail with CHANNEL_NOT_FOUND:
  /// a sub-engine booting its handler.
  int bootFailures = 0;

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_mainChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowChannels, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeMultiWindow plugin;
  late SpeechController controller;
  late DesktopSettingsWindow glue;

  setUp(() {
    plugin = _FakeMultiWindow();
    controller = SpeechController(gateway: FakeGateway());
    glue = DesktopSettingsWindow(controller);
  });

  tearDown(() {
    plugin.dispose();
    controller.dispose();
  });

  test('rapid clicks during the spawn open exactly one window', () async {
    // The create is held in flight, as spawning a sub-engine is; all
    // three clicks land inside that window of time.
    final gate = Completer<void>();
    plugin.gateCreate = gate;
    final opens = [
      glue.open(SettingsDomain.general),
      glue.open(SettingsDomain.general),
      glue.open(SettingsDomain.general),
    ];
    await Future<void>.delayed(Duration.zero);
    gate.complete();

    await Future.wait(opens);

    expect(plugin.createCalls, 1);
    // The queued clicks joined the created window: navigated it and
    // brought it back, never spawned a second one.
    expect(
      plugin.sent.where((s) => s.$2 == 'navigate').length,
      2,
    );
    expect(plugin.shown, everyElement('w1'));
  });

  test('a click during the sub-engine boot waits out its handler', () async {
    // First open creates the window (its domain rides the launch
    // arguments — no send). The second click's navigate then fails
    // while the window is still listed: booting, not dead.
    plugin.bootFailures = 2;
    await glue.open(SettingsDomain.general);

    await glue.open(SettingsDomain.history);

    expect(plugin.createCalls, 1);
    expect(plugin.sent.where((s) => s.$2 == 'navigate').last.$3, 'history');
  });

  test('a window confirmed gone from the list is recreated', () async {
    await glue.open(SettingsDomain.general);
    plugin.alive.remove('w1');
    plugin.dead.add('w1');

    await glue.open(SettingsDomain.history);

    // Death is proven by the list; the recreate carries its domain on
    // the launch arguments (no send can beat the sub-engine's boot).
    expect(plugin.createCalls, 2);
    expect(plugin.creates.last, contains('"domain":"history"'));
  });

  test('tray-exit close waits for an in-flight open and closes it', () async {
    final gate = Completer<void>();
    plugin.gateCreate = gate;
    final opening = glue.open(SettingsDomain.general);
    final closing = glue.close();
    await Future<void>.delayed(Duration.zero);
    gate.complete();

    await Future.wait([opening, closing]);

    expect(plugin.createCalls, 1);
    expect(plugin.alive, isEmpty);
  });
}
