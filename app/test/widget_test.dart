/// Widget tests for the shell: the full interaction surface (orb, live
/// transcript panel, preview confirm/cancel) rides a pure-Dart fake
/// gateway — no Rust dylib, no platform channels.

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/app_root.dart' show SpokenRectifierApp, windowSizeFor;
import 'package:spokenrectifier_app/app_state.dart';
import 'package:spokenrectifier_app/src/rust/api.dart'
    show BridgeEvent, BridgeSessionState;

import 'fake_gateway.dart';

Future<SpeechController> pumpController(
  WidgetTester tester,
  FakeGateway gateway, {
  bool panelExpanded = false,
}) async {
  final controller = SpeechController(
    gateway: gateway,
    scriptedPhrases: const [],
  );
  controller.panelExpanded = panelExpanded;
  addTearDown(controller.dispose);
  await tester.pumpWidget(SpokenRectifierApp(controller: controller));
  return controller;
}

Future<void> pumpToRecording(
  WidgetTester tester,
  SpeechController controller,
) async {
  await controller.startSession();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('idle orb tap starts a session', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.pump(const Duration(milliseconds: 350));

    // No scripted phrases: the mic-mode engine needs no fake session armed.
    expect(gateway.commands, ['startSession']);
    expect(controller.phase, BridgeSessionState.recording);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
  });

  testWidgets('live transcript streams into the expanded panel', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    // Tap the (silent) recording orb to expand the panel.
    await tester.tap(find.byIcon(Icons.mic_off));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('live-transcript')), findsOneWidget);

    gateway.emit(const BridgeEvent.liveTranscriptUpdated(text: '你好\n世界'));
    await tester.pump();
    expect(find.text('你好\n世界'), findsOneWidget);
    expect(find.textContaining('段落 0'), findsOneWidget);
  });

  testWidgets('speech activity drives the orb and panel speaking state', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
    expect(controller.speaking, isFalse);

    gateway.emit(const BridgeEvent.speechActivityChanged(speaking: true));
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.speaking, isTrue);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.mic_off), findsNothing);

    gateway.emit(const BridgeEvent.speechActivityChanged(speaking: false));
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.speaking, isFalse);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);

    // The panel header mirrors the state too.
    controller.togglePanel();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('静音'), findsOneWidget);
  });

  testWidgets('a failed start surfaces the error and stays idle', (
    tester,
  ) async {
    final gateway = FakeGateway()..failNextStart = Exception('no default input device');
    final controller = await pumpController(tester, gateway);

    await controller.startSession();
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.phase, BridgeSessionState.idle);
    expect(controller.lastError, contains('no default input device'));
    expect(find.byKey(const Key('error-flash')), findsOneWidget);
  });

  testWidgets('a new session resets the speaking flag', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    gateway.emit(const BridgeEvent.speechActivityChanged(speaking: true));
    await tester.pump();
    expect(controller.speaking, isTrue);

    await controller.cancelSession();
    await tester.pump(const Duration(milliseconds: 350));
    await controller.startSession();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.speaking, isFalse);
  });

  testWidgets('stop streams chunks into preview, Enter confirms, back to orb', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['修正', '后的文本']);
    await tester.pump(const Duration(milliseconds: 350));

    // The preview card shows the joined chunks in its editable field.
    final field = tester.widget<EditableText>(
      find.byKey(const Key('preview-field')),
    );
    expect(field.controller.text, '修正后的文本');

    // Enter confirms while the field does not hold focus (the card does).
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.commands, contains('confirmInsert'));
    expect(controller.phase, BridgeSessionState.idle);
    expect(find.byKey(const Key('inserted-flash')), findsOneWidget);
  });

  testWidgets('Esc cancels from preview', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['文本']);
    await tester.pump(const Duration(milliseconds: 350));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.commands, contains('cancelSession'));
    expect(controller.phase, BridgeSessionState.idle);
  });

  testWidgets('reroll button asks the engine again', (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['一']);
    await tester.pump(const Duration(milliseconds: 350));

    await tester.tap(find.byKey(const Key('preview-reroll')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.commands, contains('reroll'));
    expect(controller.phase, BridgeSessionState.rectifying);
  });

  testWidgets('reroll restarts chunk accumulation instead of concatenating',
      (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['第一版']);
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.previewText, '第一版');

    // Reroll and stream a second attempt.
    await controller.reroll();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['第二版']);
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.previewText, '第二版');
    final field = tester.widget<EditableText>(
      find.byKey(const Key('preview-field')),
    );
    expect(field.controller.text, '第二版');
  });

  testWidgets('Enter inside the editing field confirms, not newline',
      (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['待确认文本']);
    await tester.pump(const Duration(milliseconds: 350));

    // Focus the field itself, then press Enter: the appended newline is
    // interpreted as confirm (IME composing keeps its own Enter).
    await tester.tap(find.byKey(const Key('preview-field')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.commands, contains('confirmInsert'));
    expect(controller.phase, BridgeSessionState.idle);
  });

  testWidgets('editing the preview pushes updates after the debounce', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['初稿']);
    await tester.pump(const Duration(milliseconds: 350));

    await tester.enterText(find.byKey(const Key('preview-field')), '改过的初稿');
    expect(
      gateway.commands.where((c) => c.startsWith('updatePreviewText')),
      isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(gateway.commands.where((c) => c.startsWith('updatePreviewText')), [
      'updatePreviewText:改过的初稿',
    ]);
    expect(controller.previewText, '改过的初稿');
  });

  testWidgets('an edit racing a reroll is dropped, not pushed stale', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['初稿']);
    await tester.pump(const Duration(milliseconds: 350));

    // Edit, then immediately reroll before the debounce fires: once
    // rectifying starts, that edit is stale and must not be pushed.
    await tester.enterText(find.byKey(const Key('preview-field')), '改了一半');
    await controller.reroll();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      gateway.commands.where((c) => c.startsWith('updatePreviewText')),
      isEmpty,
    );
  });

  testWidgets('engine errors surface next to the orb', (tester) async {
    final gateway = FakeGateway();
    await pumpController(tester, gateway);

    gateway.emit(const BridgeEvent.error(message: '修正失败:没有 API key'));
    await tester.pump();
    expect(find.byKey(const Key('error-flash')), findsOneWidget);
    expect(find.textContaining('没有 API key'), findsOneWidget);
  });

  test('rectifying shares the preview window footprint so reroll never resizes',
      () {
    expect(
      windowSizeFor(BridgeSessionState.rectifying, panelExpanded: false),
      windowSizeFor(BridgeSessionState.preview, panelExpanded: false),
    );
  });

  test('toggleSession maps hotkey presses to start and stop', () async {
    final gateway = FakeGateway();
    final controller = SpeechController(
      gateway: gateway,
      scriptedPhrases: const [],
    );

    await controller.toggleSession();
    expect(gateway.commands, contains('startSession'));

    await controller.toggleSession();
    expect(gateway.commands, contains('stopSession'));
  });

  test('scripted speech feeds phrases and paragraph silences', () async {
    final gateway = FakeGateway();
    final controller = SpeechController(
      gateway: gateway,
      scriptedPhrases: const ['一', '二', '三'],
      speechInterval: const Duration(milliseconds: 1),
    );

    await controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(gateway.said.length, greaterThanOrEqualTo(3));
    expect(
      gateway.commands.where((c) => c.startsWith('fakeSilence:1300')).length,
      greaterThanOrEqualTo(1),
    );
    await controller.cancelSession();
  });

  testWidgets('Enter within the debounce window inserts the edited text',
      (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['初稿']);
    await tester.pump(const Duration(milliseconds: 350));

    // Edit and press Enter immediately — well inside the 350 ms debounce.
    await tester.enterText(find.byKey(const Key('preview-field')), '改完的终稿');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 350));

    // The edit reached the engine before the confirm, not after it.
    final commands = gateway.commands;
    final editAt = commands.indexOf('updatePreviewText:改完的终稿');
    final confirmAt = commands.indexOf('confirmInsert');
    expect(editAt, greaterThanOrEqualTo(0));
    expect(confirmAt, greaterThan(editAt));
    expect(controller.phase, BridgeSessionState.idle);
  });

  testWidgets('the raw transcript comparison expands under the rectified text',
      (tester) async {
    final gateway = FakeGateway();
    final controller = await pumpController(tester, gateway);

    await pumpToRecording(tester, controller);
    gateway.emit(const BridgeEvent.liveTranscriptUpdated(text: '嗯那个\n原话'));
    await tester.pump();
    await controller.stopSession();
    await tester.pump(const Duration(milliseconds: 350));
    gateway.streamRectify(['整理好的书面文本']);
    await tester.pump(const Duration(milliseconds: 350));

    // Hidden until asked; the rectified editor is always there.
    expect(find.byKey(const Key('raw-transcript')), findsNothing);
    expect(find.byKey(const Key('preview-field')), findsOneWidget);

    await tester.tap(find.byKey(const Key('preview-raw-toggle')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('preview-field')), findsOneWidget);
    expect(find.text('原始转写'), findsOneWidget);
    expect(find.text('嗯那个\n原话'), findsOneWidget);

    // Toggling again hides the comparison; the edit flow is unaffected.
    await tester.tap(find.byKey(const Key('preview-raw-toggle')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('raw-transcript')), findsNothing);
    expect(controller.previewText, '整理好的书面文本');
  });
}
