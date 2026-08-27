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
import 'src/shell/window_stage.dart';

class SpokenRectifierApp extends StatelessWidget {
  const SpokenRectifierApp({
    super.key,
    required this.controller,
    this.stageWindow,
  });

  final SpeechController controller;

  /// The window bounds seam; null in tests that only exercise surfaces.
  final StageWindow? stageWindow;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        title: 'SpokenRectifier',
        debugShowCheckedModeBanner: false,
        themeMode: controller.themeMode,
        theme: srTheme(Brightness.light),
        darkTheme: srTheme(Brightness.dark),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: StageHost(controller: controller, stageWindow: stageWindow),
        ),
      ),
    );
  }
}
