/// Shared bits of history retrieval (历史取回, ticket 23): the
/// 指定场景重新修正 menu both surfaces open — the settings window's
/// history rows and the quick panel's secondary rows — so the two list
/// the same library, in the same styling, with the same one-time
/// semantics. Also home of the retrieval callback type both rows hand
/// up to the controller, and of the pick type the menu returns.

library;

import 'package:flutter/material.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;

import '../design/tokens.dart';
import '../rust/api.dart' show BridgeScenario;

/// What the 指定场景重新修正 menu returned: the built-in 默认 item
/// (ticket 28) or a named library scenario. Sealed, and not a plain
/// string, so a scenario literally named 默认 stays a distinct pick
/// from the built-in item.
sealed class ScenarioPick {
  const ScenarioPick();
}

/// The built-in 默认 item: this one session runs under the default
/// register, ignoring the live selection.
class DefaultRegisterPick extends ScenarioPick {
  const DefaultRegisterPick();

  @override
  bool operator ==(Object other) => other is DefaultRegisterPick;

  @override
  int get hashCode => 0;
}

/// A named library scenario; the controller resolves it to its
/// directive text.
class NamedScenarioPick extends ScenarioPick {
  const NamedScenarioPick(this.name);

  final String name;

  @override
  bool operator ==(Object other) =>
      other is NamedScenarioPick && other.name == name;

  @override
  int get hashCode => Object.hash(NamedScenarioPick, name);
}

/// History retrieval handed up to the main window: the utterance to
/// re-run, the style pick this one session runs under, and the history
/// row it re-runs (the new session's 来源会话 when it is recorded).
typedef HistoryRerectify = Future<void> Function(
  String rawTranscript, {
  required ScenarioPick style,
  required PlatformInt64? sourceSessionId,
});

/// Open the scenario picker anchored at the calling button's box (the
/// same anchoring PopupMenuButton uses). Returns the pick — the
/// built-in 默认 item or a scenario's name — or null when the menu was
/// dismissed. Callers hand the pick to [HistoryRerectify]; the
/// controller resolves the directive and pins the session.
Future<ScenarioPick?> showScenarioRerectifyMenu(
  BuildContext context, {
  required List<BridgeScenario> scenarios,
  String itemKeyPrefix = 'scenario-item',
}) {
  final pal = srPalette(context);
  final button = context.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  return showMenu<ScenarioPick>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    ),
    color: pal.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(SrRadius.control),
      side: BorderSide(color: pal.hairline),
    ),
    constraints: const BoxConstraints(minWidth: 160),
    items: [
      // 默认 first, mirroring the tray submenu's shape (ticket 28):
      // this one session runs under the default register even with a
      // scenario selected — and over an empty library it is the only
      // item, keeping retrieval alive. The reserved key format can
      // never collide with a scenario item's, the tray's trick.
      PopupMenuItem(
        key: Key('$itemKeyPrefix-builtin-default'),
        value: const DefaultRegisterPick(),
        height: 38,
        child: Text(
          '默认',
          style: SrType.caption.copyWith(color: pal.textPrimary),
        ),
      ),
      for (final scenario in scenarios)
        PopupMenuItem(
          key: Key('$itemKeyPrefix:${scenario.name}'),
          value: NamedScenarioPick(scenario.name),
          height: 38,
          child: Text(
            scenario.name,
            style: SrType.caption.copyWith(color: pal.textPrimary),
          ),
        ),
    ],
  );
}
