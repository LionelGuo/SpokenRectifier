/// The settings window's rectify seam: the effective `[rectify.full]` /
/// `[rectify.light_touch]` / `[rectify.quick]` behavior (ADR-0015/0016/0020)
/// from the layer files,
/// legacy `[llm]` keys already folded in through the grandfather. One
/// model both ways — the read paints the initial form, every save writes
/// the whole model (the owning layers and the per-layer legacy-key
/// translation live on the Rust side, `save_rectify_behavior`).
///
/// File-level, with the same runtime adoption seam as the connection
/// domain: a save re-hands the layer files to the live engine
/// ([RectifyBehaviorStore.applyConnections], ADR-0010 scope extended by
/// ADR-0015), so the next rectify attempt — first stop, reroll, a
/// history re-rectify — runs the new behavior, no restart. A refused
/// adoption throws while the files stay saved; the pane shows the
/// banner. Injectable so widget tests run with an in-memory model and
/// no Rust dylib.

library;

import '../rust/api.dart' as rust;

/// The legal thinking-policy wire names, in chip display order
/// (ADR-0015; the pane labels them 始终 / 仅占位符 / 关闭).
const rectifyPolicies = ['always', 'placeholders', 'off'];

/// Sentinel so [RectifyBehavior.copyWith] can set the extra directive
/// to null (blank = unset) instead of keeping the previous value.
const _unset = Object();

/// The `[rectify]` behavior as the pane paints and saves it: both tiers'
/// thinking policy and prefill, the light-touch master switch,
/// threshold, and extra directive, plus the quick-mode sub-section
/// (master switch, rectify gate, its own directive). Two tiers, never
/// inheriting; quick stands beside them rather than above.
///
/// [connectionThinking] rides along read-only: it is the CONNECTION
/// domain's reading of its thinking fields, carried on this same read
/// because it is exactly the cards' disable condition (ADR-0019 item 3)
/// — one round trip, and a chip click's re-read keeps it fresh.
class RectifyBehavior {
  const RectifyBehavior({
    required this.fullThinkingPolicy,
    required this.fullPrefill,
    required this.lightTouchEnabled,
    required this.lightTouchMaxChars,
    required this.lightTouchThinkingPolicy,
    required this.lightTouchPrefill,
    this.lightTouchExtraDirective,
    this.quickEnabled = false,
    this.quickRectify = true,
    this.quickExtraDirective,
    this.connectionThinking = 'on',
  });

  /// `always` | `placeholders` | `off` (ADR-0015).
  final String fullThinkingPolicy;
  final bool fullPrefill;
  final bool lightTouchEnabled;

  /// ≥ 1; the short-utterance ceiling for light touch.
  final int lightTouchMaxChars;
  final String lightTouchThinkingPolicy;
  final bool lightTouchPrefill;

  /// The light-touch-only directive; null/blank = not injected
  /// (ADR-0016: an empty save removes the key).
  final String? lightTouchExtraDirective;

  /// The quick-mode master switch (ADR-0020): off — the file default —
  /// means no held hotkey ever upgrades a session.
  final bool quickEnabled;

  /// Whether an upgraded session still rectifies; off pastes the raw
  /// transcript straight through.
  final bool quickRectify;

  /// The quick-mode-only directive, taken in place of the light-touch
  /// one on quick attempts; null/blank = not injected (ADR-0020).
  final String? quickExtraDirective;

  /// The connection's thinking reading: `on` / `off` / `unconfigured` /
  /// `broken` (ADR-0019 item 3). Only `on` leaves the two cards' policy
  /// chips live — the other three are one semantic, and a broken file
  /// reads as inert here (the connection card is where its detail
  /// paints).
  final String connectionThinking;

  /// True while the connection's thinking fields are inert: the two
  /// cards' policy chips go unselectable and their combination warning
  /// silences. Recovery is the connection domain's switch or a fixed
  /// file — nothing on this pane.
  bool get thinkingDisabled => connectionThinking != 'on';

  /// A copy with the named fields replaced — the pick-to-save flow's
  /// builder (a chip click or a switch flip writes the whole model with
  /// everything else as committed).
  RectifyBehavior copyWith({
    String? fullThinkingPolicy,
    bool? fullPrefill,
    bool? lightTouchEnabled,
    int? lightTouchMaxChars,
    String? lightTouchThinkingPolicy,
    bool? lightTouchPrefill,
    Object? lightTouchExtraDirective = _unset,
    bool? quickEnabled,
    bool? quickRectify,
    Object? quickExtraDirective = _unset,
  }) => RectifyBehavior(
    fullThinkingPolicy: fullThinkingPolicy ?? this.fullThinkingPolicy,
    fullPrefill: fullPrefill ?? this.fullPrefill,
    lightTouchEnabled: lightTouchEnabled ?? this.lightTouchEnabled,
    lightTouchMaxChars: lightTouchMaxChars ?? this.lightTouchMaxChars,
    lightTouchThinkingPolicy:
        lightTouchThinkingPolicy ?? this.lightTouchThinkingPolicy,
    lightTouchPrefill: lightTouchPrefill ?? this.lightTouchPrefill,
    lightTouchExtraDirective: identical(lightTouchExtraDirective, _unset)
        ? this.lightTouchExtraDirective
        : lightTouchExtraDirective as String?,
    quickEnabled: quickEnabled ?? this.quickEnabled,
    quickRectify: quickRectify ?? this.quickRectify,
    quickExtraDirective: identical(quickExtraDirective, _unset)
        ? this.quickExtraDirective
        : quickExtraDirective as String?,
    connectionThinking: connectionThinking,
  );

  @override
  bool operator ==(Object other) =>
      other is RectifyBehavior &&
      other.fullThinkingPolicy == fullThinkingPolicy &&
      other.fullPrefill == fullPrefill &&
      other.lightTouchEnabled == lightTouchEnabled &&
      other.lightTouchMaxChars == lightTouchMaxChars &&
      other.lightTouchThinkingPolicy == lightTouchThinkingPolicy &&
      other.lightTouchPrefill == lightTouchPrefill &&
      other.lightTouchExtraDirective == lightTouchExtraDirective &&
      other.quickEnabled == quickEnabled &&
      other.quickRectify == quickRectify &&
      other.quickExtraDirective == quickExtraDirective &&
      other.connectionThinking == connectionThinking;

  @override
  int get hashCode => Object.hash(
    fullThinkingPolicy,
    fullPrefill,
    lightTouchEnabled,
    lightTouchMaxChars,
    lightTouchThinkingPolicy,
    lightTouchPrefill,
    lightTouchExtraDirective,
    quickEnabled,
    quickRectify,
    quickExtraDirective,
    connectionThinking,
  );
}

/// Rectify persistence as the rectify domain needs it.
abstract class RectifyBehaviorStore {
  /// The effective `[rectify]` behavior from the layer files, legacy
  /// `[llm]` keys already folded in (ADR-0015's grandfather).
  Future<RectifyBehavior> load();

  /// Write the editor's whole model; returns the re-read view (the
  /// files' truth, not the ask). No combination validation rides this
  /// path — a thinking-off × prefill-on tier saves fine, the pane's
  /// live warning is presentation only.
  Future<RectifyBehavior> save(RectifyBehavior behavior);

  /// Adopt the saved files into the live engine (the same rebuild the
  /// connection domain's save triggers, ADR-0010 scope extended to
  /// `[rectify]`): the next rectify attempt runs the new behavior.
  /// Throws when the engine refuses the adoption: the files stay
  /// saved and the engine keeps the previous config.
  Future<void> applyConnections();
}

/// The production store over the flutter_rust_bridge calls.
class RustRectifyBehaviorStore implements RectifyBehaviorStore {
  const RustRectifyBehaviorStore();

  @override
  Future<RectifyBehavior> load() => rust.rectifyBehavior().then(_fromWire);

  @override
  Future<RectifyBehavior> save(RectifyBehavior behavior) =>
      rust.setRectifyBehavior(edit: _toWire(behavior)).then(_fromWire);

  @override
  Future<void> applyConnections() => rust.applyConnectionConfigs();

  static rust.BridgeRectifyBehavior _toWire(RectifyBehavior behavior) =>
      rust.BridgeRectifyBehavior(
        fullThinkingPolicy: behavior.fullThinkingPolicy,
        fullPrefill: behavior.fullPrefill,
        lightTouchEnabled: behavior.lightTouchEnabled,
        lightTouchMaxChars: BigInt.from(behavior.lightTouchMaxChars),
        lightTouchThinkingPolicy: behavior.lightTouchThinkingPolicy,
        lightTouchPrefill: behavior.lightTouchPrefill,
        lightTouchExtraDirective: behavior.lightTouchExtraDirective,
        quickEnabled: behavior.quickEnabled,
        quickRectify: behavior.quickRectify,
        quickExtraDirective: behavior.quickExtraDirective,
        // Read-only on this wire: the save path never writes it (the
        // connection domain owns those keys), but the struct is one
        // shape both ways and the write rides along untouched.
        connectionThinking: behavior.connectionThinking,
      );

  static RectifyBehavior _fromWire(rust.BridgeRectifyBehavior view) =>
      RectifyBehavior(
        fullThinkingPolicy: view.fullThinkingPolicy,
        fullPrefill: view.fullPrefill,
        lightTouchEnabled: view.lightTouchEnabled,
        lightTouchMaxChars: view.lightTouchMaxChars.toInt(),
        lightTouchThinkingPolicy: view.lightTouchThinkingPolicy,
        lightTouchPrefill: view.lightTouchPrefill,
        lightTouchExtraDirective: view.lightTouchExtraDirective,
        quickEnabled: view.quickEnabled,
        quickRectify: view.quickRectify,
        quickExtraDirective: view.quickExtraDirective,
        connectionThinking: view.connectionThinking,
      );
}
