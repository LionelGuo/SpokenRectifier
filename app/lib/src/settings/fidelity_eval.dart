/// The fidelity eval's (保真评测) Dart-side seam and run controller.
///
/// [FidelityEvalRunner] is the injectable bridge call (the production one
/// starts the Rust-side run and returns its event stream; tests drive a
/// fake). [FidelityEvalController] owns the run's phase so it survives
/// domain switches inside the settings window — the pane is only a view;
/// closing the window (or pressing 取消) is what stops a run, because
/// the sub-engine's Dart isolate going away drops the stream listener
/// and the Rust side aborts at the next case boundary.

library;

import 'dart:async' show StreamSubscription;

import 'package:flutter/foundation.dart';

import '../rust/api.dart' as rust show BridgeEvalSummary, startFidelityEval;
import '../rust/api.dart'
    show
        BridgeEvalEvent,
        BridgeEvalEvent_CaseFinished,
        BridgeEvalEvent_CaseStarted,
        BridgeEvalEvent_Failed,
        BridgeEvalEvent_Finished,
        BridgeEvalEvent_Started;

/// Starts one eval run; the stream closes after `Finished`/`Failed`.
abstract class FidelityEvalRunner {
  Stream<BridgeEvalEvent> start();
}

/// The production runner over the flutter_rust_bridge call.
class RustFidelityEvalRunner implements FidelityEvalRunner {
  const RustFidelityEvalRunner();

  @override
  Stream<BridgeEvalEvent> start() => rust.startFidelityEval();
}

/// One run's phase. `failed` keeps the message; `finished` keeps the
/// summary — both stay painted until the next start.
enum FidelityEvalPhase { idle, running, failed, finished }

class FidelityEvalController extends ChangeNotifier {
  FidelityEvalController({required this.runner});

  final FidelityEvalRunner runner;

  FidelityEvalPhase phase = FidelityEvalPhase.idle;

  /// How many cases the suite carries (set by `Started`).
  int total = 0;

  /// How many have finished (pass or fail) so far.
  int done = 0;

  /// The case now running (its id).
  String? currentCase;

  /// The failure message when [phase] is `failed`.
  String? failure;

  /// The report when [phase] is `finished`.
  rust.BridgeEvalSummary? summary;

  StreamSubscription<BridgeEvalEvent>? _subscription;

  /// Start a run; a run already in flight is a no-op (the Rust side
  /// would refuse it too — this just never asks).
  void start() {
    if (phase == FidelityEvalPhase.running) return;
    phase = FidelityEvalPhase.running;
    done = 0;
    currentCase = null;
    failure = null;
    summary = null;
    notifyListeners();
    _subscription?.cancel();
    _subscription = runner.start().listen(
      _onEvent,
      onError: (Object error) {
        // Setup refusals (no LLM key, a second run) arrive here.
        _end(FidelityEvalPhase.failed, message: '$error');
      },
      onDone: () {
        // A stream closed without a verdict (should not happen; the
        // controller keeps whatever phase the last event left).
        if (phase == FidelityEvalPhase.running) {
          _end(FidelityEvalPhase.failed, message: '评测连接中断');
        }
      },
    );
  }

  /// Stop the run: dropping the listener aborts the Rust side at the
  /// next case boundary. The phase returns to idle (a cancelled run
  /// reports nothing).
  void cancel() {
    if (phase != FidelityEvalPhase.running) return;
    _subscription?.cancel();
    _subscription = null;
    _end(FidelityEvalPhase.idle);
  }

  void _onEvent(BridgeEvalEvent event) {
    switch (event) {
      case BridgeEvalEvent_Started():
        total = event.total;
      case BridgeEvalEvent_CaseStarted():
        currentCase = event.id;
      case BridgeEvalEvent_CaseFinished():
        done = event.index;
      case BridgeEvalEvent_Finished():
        summary = event.summary;
        _subscription?.cancel();
        _subscription = null;
        _end(FidelityEvalPhase.finished);
        return;
      case BridgeEvalEvent_Failed():
        _subscription?.cancel();
        _subscription = null;
        _end(FidelityEvalPhase.failed, message: event.message);
        return;
    }
    notifyListeners();
  }

  void _end(FidelityEvalPhase phase, {String? message}) {
    this.phase = phase;
    failure = message;
    currentCase = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
