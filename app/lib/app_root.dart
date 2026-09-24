/// The shell UI: one morphing window hosting the orb (every session
/// state) and the mutually exclusive panels — the session window (live
/// transcript -> streaming rectify -> preview, one continuous surface)
/// and the quick panel placeholder. Window bounds live in
/// `src/shell/window_stage.dart` (the jump-hidden choreography); this
/// widget is the pure, testable tree on top of [SpeechController].

library;

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'src/design/theme.dart';
import 'src/settings/rectify_store.dart';
import 'src/settings/settings_domain.dart';
import 'src/shell/window_stage.dart';

class SpokenRectifierApp extends StatelessWidget {
  const SpokenRectifierApp({
    super.key,
    required this.controller,
    this.stageWindow,
    this.onOpenSettings,
    this.onPanelRevealed,
    required this.rectifyStore,
  });

  final SpeechController controller;

  /// The window bounds seam; null in tests that only exercise surfaces.
  final StageWindow? stageWindow;

  /// The settings window's doorway (the quick panel's management
  /// entries); null in tests.
  final void Function(SettingsDomain domain)? onOpenSettings;

  /// The quick panel stood open — the settings prewarm's arm signal
  /// (16 号票); null in tests.
  final VoidCallback? onPanelRevealed;

  /// The quick panel's rectify tiers' store — the same store the
  /// settings window's 修正 page edits.
  final RectifyBehaviorStore rectifyStore;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // The shell listens to the THEME alone (17 号票): it used to
      // rebuild per controller notify — MaterialApp, both themes and
      // the whole stage re-resolved twenty times a second so the
      // recording level ring could read one double. The theme feed is
      // the only controller state this build consumes; every surface
      // below owns its own listener for what it paints.
      listenable: controller.themeFeed,
      builder: (context, _) => MaterialApp(
        title: 'SpokenRectifier',
        debugShowCheckedModeBanner: false,
        themeMode: controller.themeMode,
        theme: srTheme(Brightness.light),
        darkTheme: srTheme(Brightness.dark),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: StageHost(
            controller: controller,
            stageWindow: stageWindow,
            onOpenSettings: onOpenSettings,
            onPanelRevealed: onPanelRevealed,
            rectifyStore: rectifyStore,
          ),
        ),
      ),
    );
  }
}
