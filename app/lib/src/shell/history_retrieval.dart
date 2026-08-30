/// Shared bits of history retrieval (历史取回, ticket 23): the
/// 指定场景重新修正 menu both surfaces open — the settings window's
/// history rows and the quick panel's secondary rows — so the two list
/// the same library, in the same styling, with the same one-time
/// semantics. Also home of the retrieval callback type both rows hand
/// up to the controller.

library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../rust/api.dart' show BridgeScenario;

/// History retrieval handed up to the main window: the utterance to
/// re-run, plus the scenario this one session runs under when the
/// 指定场景 key named one.
typedef HistoryRerectify = Future<void> Function(
  String rawTranscript, {
  String? scenario,
});

/// Open the scenario picker anchored at the calling button's box (the
/// same anchoring PopupMenuButton uses). Returns the picked scenario's
/// name, or null when the menu was dismissed. Callers hand the name to
/// [HistoryRerectify]; the controller resolves the directive and pins
/// the session.
Future<String?> showScenarioRerectifyMenu(
  BuildContext context, {
  required List<BridgeScenario> scenarios,
  String itemKeyPrefix = 'scenario-item',
}) {
  final pal = srPalette(context);
  final button = context.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  return showMenu<String>(
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
      for (final scenario in scenarios)
        PopupMenuItem(
          key: Key('$itemKeyPrefix:${scenario.name}'),
          value: scenario.name,
          height: 38,
          child: Text(
            scenario.name,
            style: SrType.caption.copyWith(color: pal.textPrimary),
          ),
        ),
    ],
  );
}
