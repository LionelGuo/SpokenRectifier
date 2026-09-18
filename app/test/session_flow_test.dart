/// The orb-position session flow as a pure function, locked cell by
/// cell. This is the single source both the orb clicks and the hotkey
/// route through (球位状态机:单一来源纯函数,与热键主流程同构).

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:spokenrectifier_app/src/rust/api.dart' show BridgeSessionState;
import 'package:spokenrectifier_app/src/shell/session_flow.dart';

void main() {
  group('flowAction: idle', () {
    test('primary starts a session', () {
      expect(
        flowAction(BridgeSessionState.idle, SessionInput.primary),
        SessionCommand.start,
      );
    });

    test('everything else is ignored', () {
      expect(flowAction(BridgeSessionState.idle, SessionInput.enter), isNull);
      expect(flowAction(BridgeSessionState.idle, SessionInput.escape), isNull);
      expect(
        flowAction(BridgeSessionState.idle, SessionInput.secondary),
        isNull,
      );
    });
  });

  group('flowAction: recording', () {
    test('primary stops into rectification', () {
      // The orb's left click. The primary hotkey with the quick-mode
      // switch on does not use this cell (release stops, not keyDown);
      // with the switch off it still does. Locked in hold_watcher_test.
      expect(
        flowAction(BridgeSessionState.recording, SessionInput.primary),
        SessionCommand.stop,
      );
    });

    test('escape cancels — extended to the recording phase', () {
      expect(
        flowAction(BridgeSessionState.recording, SessionInput.escape),
        SessionCommand.cancel,
      );
    });

    test('enter and secondary do nothing', () {
      expect(
        flowAction(BridgeSessionState.recording, SessionInput.enter),
        isNull,
      );
      expect(
        flowAction(BridgeSessionState.recording, SessionInput.secondary),
        isNull,
      );
    });
  });

  group('flowAction: rectifying', () {
    test('the orb is disabled — primary is ignored', () {
      expect(
        flowAction(BridgeSessionState.rectifying, SessionInput.primary),
        isNull,
      );
      expect(
        flowAction(BridgeSessionState.rectifying, SessionInput.enter),
        isNull,
      );
    });

    test('escape still cancels', () {
      expect(
        flowAction(BridgeSessionState.rectifying, SessionInput.escape),
        SessionCommand.cancel,
      );
    });
  });

  group('flowAction: preview', () {
    test('primary or enter confirms what is on screen', () {
      expect(
        flowAction(BridgeSessionState.preview, SessionInput.primary),
        SessionCommand.confirm,
      );
      expect(
        flowAction(BridgeSessionState.preview, SessionInput.enter),
        SessionCommand.confirm,
      );
    });

    test('escape cancels', () {
      expect(
        flowAction(BridgeSessionState.preview, SessionInput.escape),
        SessionCommand.cancel,
      );
      expect(
        flowAction(BridgeSessionState.preview, SessionInput.secondary),
        isNull,
      );
    });
  });

  group('flowAction: transient feedback phases', () {
    test('inserted and cancelled ignore every input', () {
      for (final phase in [
        BridgeSessionState.inserted,
        BridgeSessionState.cancelled,
      ]) {
        for (final input in SessionInput.values) {
          expect(flowAction(phase, input), isNull, reason: '$phase $input');
        }
      }
    });
  });

  group('stageFor', () {
    test('active session phases show the session window', () {
      for (final phase in [
        BridgeSessionState.recording,
        BridgeSessionState.rectifying,
        BridgeSessionState.preview,
      ]) {
        expect(stageFor(phase, false), StageKind.session, reason: '$phase');
      }
    });

    test('idle and feedback phases rest on the orb', () {
      expect(stageFor(BridgeSessionState.idle, false), StageKind.orb);
      expect(stageFor(BridgeSessionState.inserted, false), StageKind.orb);
      expect(stageFor(BridgeSessionState.cancelled, false), StageKind.orb);
    });

    test('quick panel opens only while idle — a session takes over', () {
      expect(stageFor(BridgeSessionState.idle, true), StageKind.quick);
      expect(stageFor(BridgeSessionState.recording, true), StageKind.session);
    });
  });
}
