/// The rectify domain's fake store, shared by the settings window's and
/// the quick panel's tests: the behavior in memory; a save records the
/// ask and returns it as the re-read truth; the post-save engine
/// adoption ([applyCalls]) is recorded and can be refused
/// ([FakeRectifyBehaviorStore.failNextApply]).
library;

import 'package:spokenrectifier_app/src/settings/rectify_store.dart';

class FakeRectifyBehaviorStore implements RectifyBehaviorStore {
  FakeRectifyBehaviorStore([
    this.behavior = const RectifyBehavior(
      fullThinkingPolicy: 'always',
      fullPrefill: true,
      lightTouchEnabled: true,
      lightTouchMaxChars: 40,
      lightTouchThinkingPolicy: 'always',
      lightTouchPrefill: true,
    ),
  ]);

  /// Today's defaults (ADR-0015: a missing section reads as the
  /// always-on, prefill-on behavior).
  RectifyBehavior behavior;

  final saves = <RectifyBehavior>[];

  /// When set, the next save throws (an unwritable layer file).
  Object? failNextSave;

  /// How many saves handed the files to the live engine afterwards.
  int applyCalls = 0;

  /// When set, the next apply throws (the engine refused the adoption).
  Object? failNextApply;

  @override
  Future<RectifyBehavior> load() async => behavior;

  @override
  Future<RectifyBehavior> save(RectifyBehavior next) async {
    if (failNextSave != null) {
      final failure = failNextSave;
      failNextSave = null;
      throw failure!;
    }
    saves.add(next);
    behavior = next;
    return next;
  }

  @override
  Future<void> applyConnections() async {
    if (failNextApply != null) {
      final failure = failNextApply;
      failNextApply = null;
      throw failure!;
    }
    applyCalls++;
  }
}
