/// The main-window settings glue's one-window invariant (small-fix 15):
/// however fast the quick panel's entry rows are clicked, at most one
/// settings window ever exists. The races that broke it — concurrent
/// opens each spawning a sub-engine, and a send into a just-created
/// window (its handler not yet attached) being misread as death — are
/// driven through a recording fake of the desktop_multi_window plugin
/// on the default binary messenger: no second engine, no Rust dylib.

library;

import 'dart:async';
import 'dart:convert';

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
  late StreamController<void> windowsChanged;
  late DesktopSettingsWindow glue;

  setUp(() {
    plugin = _FakeMultiWindow();
    controller = SpeechController(gateway: FakeGateway());
    windowsChanged = StreamController<void>.broadcast();
    glue = DesktopSettingsWindow(
      controller,
      windowsChanged: windowsChanged.stream,
      initialPrewarmDelay: Duration.zero,
      prewarmArmDelay: Duration.zero,
      prewarmRearmDelay: Duration.zero,
      // Long enough that the default glue never retires mid-test; the
      // retirement's own tests build their own glue with a live clock.
      prewarmRetireDelay: const Duration(hours: 1),
    );
  });

  tearDown(() {
    plugin.dispose();
    controller.dispose();
    windowsChanged.close();
  });

  /// Enough event-loop turns for a zero-duration timer and the queue
  /// chains behind it to run out.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

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

  test('prewarm boots one hidden window; an open rides it', () async {
    glue.armPrewarm();
    await settle();

    // The hidden engine booted: created with the prewarm marker, and
    // nothing on this side showed it.
    expect(plugin.createCalls, 1);
    expect(plugin.creates.single, contains('"prewarm":true'));
    expect(plugin.shown, isEmpty);

    await glue.open(SettingsDomain.general);

    // The open navigated the booted engine instead of spawning another.
    expect(plugin.createCalls, 1);
    expect(
      plugin.sent.where((s) => s.$2 == 'navigate').single.$3,
      'general',
    );
    expect(plugin.shown, ['w1']);
  });

  test('a click racing the prewarm boot still opens exactly one window',
      () async {
    final gate = Completer<void>();
    plugin.gateCreate = gate;
    glue.armPrewarm();
    await Future<void>.delayed(Duration.zero); // the timer fired, create held
    final opening = glue.open(SettingsDomain.history);
    await Future<void>.delayed(Duration.zero);
    gate.complete();

    await opening;

    // The click queued behind the prewarm's create and navigated it.
    expect(plugin.createCalls, 1);
    expect(
      plugin.sent.where((s) => s.$2 == 'navigate').single.$3,
      'history',
    );
  });

  test('a closed window re-arms, but never behind an open panel', () async {
    glue.armPrewarm();
    await settle();
    expect(plugin.createCalls, 1);

    // The user closes it via the title bar: the window leaves the list,
    // the windows-changed event prunes the handle, the re-arm boots a
    // fresh hidden engine (ADR-0024's repeat-tweaker warmth).
    plugin.dead.add('w1');
    plugin.alive.remove('w1');
    windowsChanged.add(null);
    await settle();
    expect(plugin.createCalls, 2);
    expect(plugin.creates.last, contains('"prewarm":true'));
    expect(plugin.shown, isEmpty);

    // The same close with the quick panel standing open: the birth
    // waits (a boot inside a panel session is the scroll jank), then
    // fires three seconds — zero here — after the collapse.
    plugin.dead.add('w2');
    plugin.alive.remove('w2');
    controller.quickOpen = true;
    windowsChanged.add(null);
    await settle();
    expect(plugin.createCalls, 2); // deferred, not dropped

    controller.quickOpen = false;
    controller.notifyListeners();
    await settle();
    expect(plugin.createCalls, 3);
    expect(plugin.creates.last, contains('"prewarm":true'));
  });

  test('an idle engine retires and stays dead until a reveal re-arms', () async {
    final retiring = DesktopSettingsWindow(
      controller,
      windowsChanged: windowsChanged.stream,
      prewarmArmDelay: Duration.zero,
      prewarmRetireDelay: Duration.zero,
    );
    retiring.armPrewarm();
    await settle();
    expect(plugin.createCalls, 1);

    // The idle clock ran out at birth: the hidden window was asked to
    // close (the fake drops it from the alive list), and once the
    // windows-changed prune sees it gone, that death does NOT re-arm
    // (the retirement is the one that stays dead — ADR-0024).
    await settle();
    expect(plugin.alive, isEmpty);
    windowsChanged.add(null);
    await settle();
    expect(plugin.createCalls, 1);

    // The panel's quiet reveal is what brings warmth back.
    retiring.armPrewarm();
    await settle();
    expect(plugin.createCalls, 2);
  });

  test('a retirement never lands inside an open panel', () async {
    final retiring = DesktopSettingsWindow(
      controller,
      windowsChanged: windowsChanged.stream,
      prewarmArmDelay: Duration.zero,
      prewarmRetireDelay: const Duration(milliseconds: 40),
    );
    retiring.armPrewarm();
    await settle();
    expect(plugin.createCalls, 1);

    // The panel stands open when the idle clock runs out: the
    // retirement holds (someone may be heading for a settings row) and
    // restarts its clock instead of closing the warmth (the window
    // stays alive; a landed close would have dropped it from the list).
    controller.quickOpen = true;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(plugin.alive, contains('w1'));
  });

  test('arming while a window lives creates nothing', () async {
    glue.armPrewarm();
    await settle();
    expect(plugin.createCalls, 1);

    // Every quick-panel reveal arms; while an engine already stands
    // (hidden or shown) the arm is a no-op.
    glue.armPrewarm();
    await settle();
    await glue.open(SettingsDomain.general);
    glue.armPrewarm();
    await settle();

    expect(plugin.createCalls, 1);
  });

  test('the exit chain never resurrects the window', () async {
    glue.armPrewarm();
    await settle();
    expect(plugin.createCalls, 1);

    await glue.close();
    await settle();

    // The exit flag disarms every arm path: no second engine on the
    // way out.
    expect(plugin.createCalls, 1);
    expect(plugin.alive, isEmpty);
  });

  test('the prewarm marker parses into a hidden launch', () {
    final launch = parseSettingsLaunch(
      jsonEncode({
        'kind': 'settings',
        'prewarm': true,
        'domain': 'general',
        'theme': 'dark',
      }),
    )!;
    expect(launch.hidden, isTrue);
    expect(launch.domain, SettingsDomain.general);

    // No marker: a normal create, whose engine shows itself at staging.
    final normal = parseSettingsLaunch(
      jsonEncode({'kind': 'settings', 'domain': 'general'}),
    )!;
    expect(normal.hidden, isFalse);
  });
}
