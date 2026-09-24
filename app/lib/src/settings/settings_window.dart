/// The settings window: a REAL independent OS window (standard title bar,
/// taskbar entry, centered, resizable — spec §4.4), not another panel of
/// the morphing orb window. Spawned via desktop_multi_window (a second
/// Flutter engine re-runs main; see main.dart's sub-entry branch). Its
/// data seams are the file-backed stores (the bridge, direct) and its
/// cross-window link is [SettingsChannel] (events only, never state).
///
/// All nine domains are filled: general (通用 — the theme tri-state
/// mirror, the orb's visibility, the 开机自启 switch, and the two
/// product-hotkey rows), scenarios (场景库), rectify (修正 —
/// the [rectify] behavior cards), history (历史), terms (术语),
/// connection (模型与连接), fidelity eval (保真评测), advanced (高级) and
/// about (关于). The eval run lives in a controller here — it survives
/// domain switches; closing the window is what stops it.

library;

import 'package:flutter/material.dart';

import '../../hotkey_binding.dart';
import '../../ui_prefs.dart';
import '../design/controls.dart' show SrButton, SrField, SrPressFill;
import '../design/hover.dart';
import '../design/sr_tooltip.dart';
import '../design/theme.dart' show srTheme;
import '../design/toast.dart';
import '../design/tokens.dart';
import '../errors.dart';
import '../rust/api/library.dart'
    show BridgeScenario;
import 'caption_theme.dart';
import 'connection_store.dart';
import 'fidelity_eval.dart';
import 'history_store.dart';
import 'rectify_store.dart';
import 'settings_about_pane.dart';
import 'settings_advanced_pane.dart';
import 'settings_channel.dart';
import 'settings_connection_pane.dart';
import 'settings_domain.dart';
import 'settings_fidelity_pane.dart';
import 'settings_general_pane.dart';
import 'settings_history_pane.dart';
import 'settings_rectify_pane.dart';
import 'settings_store.dart';
import 'settings_terms_pane.dart';
import 'system_store.dart';
import 'terms_store.dart';

class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({
    super.key,
    required this.store,
    required this.channel,
    required this.initialDomain,
    required this.historyStore,
    required this.evalRunner,
    required this.termsStore,
    required this.connectionStore,
    required this.rectifyStore,
    required this.systemStore,
    this.globalStore = const RustGlobalDirectiveStore(),
    this.initialTheme = ThemeMode.system,
    this.initialOrbVisible = true,
    this.initialPrimary = HotkeyBinding.primaryDefault,
    this.initialPin = HotkeyBinding.pinDefault,
    this.initialSelection,
    this.captionTheme = applyWindowsCaptionTheme,
    this.uiPrefsDirs,
  });

  final ScenarioStore store;

  /// The global directive's data seam (ticket 22) — the companion file
  /// the scenario domain's inline card edits. Defaults to the bridge
  /// store; injectable for widget tests.
  final GlobalDirectiveStore globalStore;
  final SettingsChannel channel;
  final SettingsDomain initialDomain;

  /// The history domain's data seam (the `[history]` config and the
  /// stored sessions, direct through the bridge).
  final HistorySettingsStore historyStore;

  /// The fidelity-eval domain's seam (starts the Rust-side run).
  final FidelityEvalRunner evalRunner;

  /// The terms domain's seam (the hotword dictionary file — the same
  /// calls the quick panel's quick-add makes, plus the rename).
  final TermsStore termsStore;

  /// The connection domain's seam (the effective `[asr]`/`[llm]`
  /// sections; keys ride as placement + edit, never values).
  final ConnectionStore connectionStore;

  /// The rectify domain's seam (the effective `[rectify]` behavior and
  /// the post-save engine adoption it shares with the connection
  /// domain).
  final RectifyBehaviorStore rectifyStore;

  /// The advanced and about domains' seam (read-only timings, version,
  /// and the open-config entry the tray shares).
  final SystemStore systemStore;

  /// Theme and selection ride the window arguments (the main window
  /// cannot push into the sub-engine before its handler exists), then
  /// follow live over the channel. The orb's visibility and the two
  /// product chords ride the same seed (the general domain's knobs).
  final ThemeMode initialTheme;
  final bool initialOrbVisible;
  final HotkeyBinding initialPrimary;
  final HotkeyBinding initialPin;
  final String? initialSelection;

  /// Where a hotkey write lands (the app-owned prefs file's search
  /// directories); injectable so tests point it at a scratch directory.
  /// Null = [uiPrefsSearchDirs] at the write (the constructor stays
  /// const — a method call is not a constant expression).
  final List<String>? uiPrefsDirs;

  /// Paints the OS caption (title bar) with the effective brightness;
  /// injectable so widget tests can record the applications.
  final void Function(Brightness brightness) captionTheme;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp>
    with WidgetsBindingObserver {
  ThemeMode _mode = ThemeMode.system;
  bool _orbVisible = true;

  /// The autostart switch's state (the HKCU Run value's presence).
  /// Null until the read lands — the switch paints off and disabled
  /// rather than guessing. Unlike the orb's visibility this never rides
  /// the launch arguments or the channel: the registry is read here,
  /// written here, and nothing on the main side follows it.
  bool? _autostart;

  HotkeyBinding _primary = HotkeyBinding.primaryDefault;
  HotkeyBinding _pin = HotkeyBinding.pinDefault;
  SettingsDomain _domain = SettingsDomain.scenarios;
  List<BridgeScenario> _scenarios = const [];
  String? _selected;

  /// The global directive as the file reads it (null = unset) — the
  /// inline card's seed and the dirty check's baseline (ticket 22).
  String? _global;

  /// The eval run outlives the pane: switching domains must not stop it
  /// (only closing the window — this state dying with the engine — or
  /// the pane's 取消 does).
  late final FidelityEvalController _eval = FidelityEvalController(
    runner: widget.evalRunner,
  );

  /// Below MaterialApp (and inside [SrToastScope]): the state's own
  /// context sits above the app and cannot look up the toast.
  late BuildContext _toastContext;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialTheme;
    _orbVisible = widget.initialOrbVisible;
    _primary = widget.initialPrimary;
    _pin = widget.initialPin;
    _domain = widget.initialDomain;
    _selected = widget.initialSelection;
    _load();
    widget.channel.onTheme = _setMode;
    widget.channel.onOrbVisible = (visible) =>
        setState(() => _orbVisible = visible);
    widget.channel.onSelection = (name) => setState(() => _selected = name);
    widget.channel.onNavigate = (domain) => setState(() => _domain = domain);
    widget.channel.attach();
    // The caption follows system-brightness flips too (dmw re-seeds it
    // from the system theme on every settings change, and our value must
    // land after that).
    WidgetsBinding.instance.addObserver(this);
    _applyCaptionTheme();
  }

  @override
  void dispose() {
    _eval.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _setMode(ThemeMode mode) {
    setState(() => _mode = mode);
    _applyCaptionTheme();
  }

  /// The general domain's theme pick: paint at once (the caption theme
  /// follows the local adoption), then hand the pick to the main
  /// controller's single entry over the channel — the quick panel's
  /// switcher is the other caller of the same path. The controller's
  /// notify comes back as an idempotent [_setMode] push.
  Future<void> _pickTheme(ThemeMode mode) async {
    _setMode(mode);
    await widget.channel.sendThemePicked(mode);
  }

  /// The general domain's orb switch: paint at once, then hand the flip
  /// to the main controller's single entry over the channel (the tray
  /// checkbox and tray click share it). The write and any failure
  /// banner live on the main side.
  Future<void> _setOrbVisible(bool visible) async {
    setState(() => _orbVisible = visible);
    await widget.channel.sendOrbVisible(visible);
  }

  /// Capture on a hotkey row: the main engine unregisters both product
  /// chords so this window can hear the press.
  Future<void> _setHotkeysPaused(bool paused) =>
      widget.channel.sendHotkeysPaused(paused);

  /// The general domain's autostart switch: write the HKCU Run value
  /// (or delete it) and paint the re-read state — the registry is the
  /// one truth, so the switch never moves ahead of the write. A failed
  /// write toasts and leaves the switch where it was.
  Future<void> _setAutostart(bool enabled) async {
    try {
      final saved = await widget.systemStore.saveAutostart(enabled);
      if (!mounted) return;
      setState(() => _autostart = saved);
    } catch (e) {
      if (!mounted) return;
      logRawError('err_autostart_save', e);
      SrToast.of(_toastContext).show('设置失败', tone: SrToastTone.error);
    }
  }

  /// A row finished a record / clear / restore: write the file (it is
  /// the truth), paint the pair, tell the main engine to re-read. A
  /// failed write keeps the on-screen pair and toasts the error.
  Future<void> _commitHotkey(HotkeySlot slot, HotkeyBinding binding) async {
    try {
      saveUiHotkey(widget.uiPrefsDirs ?? uiPrefsSearchDirs(), slot, binding);
    } catch (e) {
      if (!mounted) return;
      logRawError('err_hotkey_save', e);
      SrToast.of(_toastContext).show('保存失败', tone: SrToastTone.error);
      return;
    }
    if (!mounted) return;
    setState(() {
      switch (slot) {
        case HotkeySlot.primary:
          _primary = binding;
        case HotkeySlot.pin:
          _pin = binding;
      }
    });
    await widget.channel.sendHotkeysChanged();
  }

  @override
  void didChangePlatformBrightness() => _applyCaptionTheme();

  void _applyCaptionTheme() {
    widget.captionTheme(
      effectiveBrightness(
        _mode,
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
      ),
    );
  }

  Future<void> _load() async {
    try {
      final scenarios = await widget.store.load();
      if (!mounted) return;
      setState(() => _scenarios = scenarios);
    } catch (e) {
      // Unreadable today (e.g. a transient lock): the pane shows the
      // empty state; the toast carries the diagnosis. Nothing is written.
      if (!mounted) return;
      logRawError('err_scenario_load', e);
      SrToast.of(_toastContext).show('场景库读取失败', tone: SrToastTone.error);
    }
    try {
      final global = await widget.globalStore.load();
      if (!mounted) return;
      setState(() => _global = global);
    } catch (e) {
      // Same posture: the card seeds empty (unset) and toasts the error.
      if (!mounted) return;
      logRawError('err_directive_load', e);
      SrToast.of(_toastContext).show('全局指令读取失败', tone: SrToastTone.error);
    }
    try {
      final autostart = await widget.systemStore.loadAutostart();
      if (!mounted) return;
      setState(() => _autostart = autostart);
    } catch (e) {
      // Same posture again: the switch stays disabled (unknown) and the
      // toast carries the diagnosis.
      if (!mounted) return;
      logRawError('err_autostart_load', e);
      SrToast.of(_toastContext).show('开机自启状态读取失败', tone: SrToastTone.error);
    }
  }

  /// Persist the global directive (the inline card's save), then tell
  /// the main window — the same file-is-truth, event-after-write flow
  /// the library editor's [_commit] follows. Local state only moves once
  /// the file has accepted the write.
  Future<void> _saveGlobal(String text) async {
    final trimmed = text.trim();
    final next = trimmed.isEmpty ? null : trimmed;
    try {
      await widget.globalStore.save(next);
    } catch (e) {
      if (!mounted) return;
      logRawError('err_directive_save', e);
      SrToast.of(_toastContext).show('保存失败', tone: SrToastTone.error);
      return;
    }
    if (!mounted) return;
    setState(() => _global = next);
    await widget.channel.sendGlobalChanged();
  }

  /// Persist the editor's whole model, then tell the main window. Local
  /// state only moves once the file has accepted the write — and it
  /// moves to the store's re-read, not the editor's draft: new rows
  /// only carry null ids in the draft, and the panes that address
  /// scenarios by id (the history filter chips) need the minted ones
  /// without waiting for a window reopen.
  Future<bool> _commit(
    List<BridgeScenario> next, {
    String? renamedFrom,
    String? renamedTo,
  }) async {
    List<BridgeScenario> stored;
    try {
      stored = await widget.store.save(next);
    } catch (e) {
      logRawError('err_scenario_save', e);
      if (!mounted) return false;
      SrToast.of(_toastContext).show('保存失败', tone: SrToastTone.error);
      return false;
    }
    setState(() => _scenarios = stored);
    await widget.channel.sendScenariosChanged(
      renamedFrom: renamedFrom,
      renamedTo: renamedTo,
    );
    return true;
  }

  Future<void> _addOrUpdate(BridgeScenario edited, String? originalName) async {
    final next = [
      for (final scenario in _scenarios)
        if (scenario.name == originalName) edited else scenario,
      // A new entry (no original) lands at the end; an edit keeps its
      // position (the loop above replaced it in place).
      if (originalName == null) edited,
    ];
    // The selection follows a rename even when the editor is the picker;
    // it lands with the same setState the new list paints in.
    final selectedFollowsRename =
        originalName != null && _selected == originalName;
    if (!await _commit(
      next,
      renamedFrom: originalName,
      renamedTo: originalName == null ? null : edited.name,
    )) {
      return;
    }
    if (selectedFollowsRename) {
      setState(() => _selected = edited.name);
    }
  }

  Future<void> _delete(String name) async {
    final next = [
      for (final scenario in _scenarios)
        if (scenario.name != name) scenario,
    ];
    if (!await _commit(next)) return;
    if (_selected == name) {
      // Deleting the selected scenario returns to the default register;
      // the main window's reaction arrives as the same truth.
      setState(() => _selected = null);
      await widget.channel.sendScenarioSelected(null);
    }
  }

  Future<void> _select(String? name) async {
    setState(() => _selected = name);
    await widget.channel.sendScenarioSelected(name);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpokenRectifier 设置',
      debugShowCheckedModeBanner: false,
      themeMode: _mode,
      theme: srTheme(Brightness.light),
      darkTheme: srTheme(Brightness.dark),
      home: Builder(
        // Palette lookups must resolve BELOW MaterialApp: on the state's
        // own context (above it) Theme.of silently falls back to the
        // light fallback theme, which once left the scaffold and divider
        // light while dark mode darkened everything else. The toast
        // scope rides the same builder: top-center, below the OS caption
        // (the home body starts under it already, so 12 just keeps the
        // capsule off the header line). The tooltip boundary is the
        // window body itself (小修 24's 统一: same wrapper as the panels,
        // clamping to the whole window ≈ stock behavior — this window
        // has no region clipping it).
        builder: (context) => LayoutBuilder(
          builder: (context, constraints) => SrTooltipBoundary(
            rect: Offset.zero & constraints.biggest,
            child: SrToastScope(
          anchor: SrToastAnchor.top,
          clearance: 12,
          child: Builder(
            builder: (toastContext) {
              _toastContext = toastContext;
              return Scaffold(
                backgroundColor: srPalette(context).surface,
                body: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Sidebar(
                      selected: _domain,
                      onSelect: (domain) => setState(() => _domain = domain),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: srPalette(context).hairline,
                    ),
                    Expanded(child: _domainPane(context)),
                  ],
                ),
              );
            },
          ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _domainPane(BuildContext context) {
    return switch (_domain) {
      SettingsDomain.general => SettingsGeneralPane(
        themeMode: _mode,
        orbVisible: _orbVisible,
        autostart: _autostart,
        primary: _primary,
        pin: _pin,
        onThemePicked: _pickTheme,
        onOrbVisible: _setOrbVisible,
        onAutostart: _setAutostart,
        onCapture: _setHotkeysPaused,
        onCommit: _commitHotkey,
      ),
      SettingsDomain.scenarios => _ScenarioPane(
        scenarios: _scenarios,
        selected: _selected,
        global: _global,
        onSelect: _select,
        onAddOrUpdate: _addOrUpdate,
        onDelete: _delete,
        onSaveGlobal: _saveGlobal,
      ),
      SettingsDomain.fidelity => SettingsFidelityPane(controller: _eval),
      SettingsDomain.history => SettingsHistoryPane(
        store: widget.historyStore,
        scenarios: _scenarios,
        onHistoryChanged: widget.channel.sendHistoryChanged,
        onRerectify: widget.channel.sendHistoryRerectify,
      ),
      SettingsDomain.terms => SettingsTermsPane(
        store: widget.termsStore,
        onTermsChanged: widget.channel.sendTermsChanged,
      ),
      SettingsDomain.connection => SettingsConnectionPane(
        store: widget.connectionStore,
      ),
      SettingsDomain.rectify => SettingsRectifyPane(store: widget.rectifyStore),
      SettingsDomain.advanced => SettingsAdvancedPane(
        store: widget.systemStore,
      ),
      SettingsDomain.about => SettingsAboutPane(store: widget.systemStore),
    };
  }
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selected, required this.onSelect});

  final SettingsDomain selected;
  final ValueChanged<SettingsDomain> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        children: [
          for (final domain in SettingsDomain.values)
            _SidebarItem(
              domain: domain,
              selected: domain == selected,
              onTap: () => onSelect(domain),
            ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.domain,
    required this.selected,
    required this.onTap,
  });

  final SettingsDomain domain;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final active = selected;
    return SrHover(
      builder: (hover) => SrPress(
        builder: (pressed) => GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SrPressFill(
            // Press darkens at pointer-down; the active domain's blue
            // below follows the selection (26 号票).
            pressed: pressed,
            radius: const BorderRadius.horizontal(
              left: Radius.circular(SrRadius.control),
              right: Radius.circular(4),
            ),
            child: AnimatedContainer(
              // Surface-fade feel (the quick panel's hover rule): fill
              // eases in and out on the symmetric fade token, tinted by
              // the target color's own alpha.
              duration: SrMotion.fade,
              curve: SrMotion.curveFade,
              margin: const EdgeInsets.only(bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: pal.surfaceOverlay.withValues(alpha: hover ? 1 : 0),
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(SrRadius.control),
                  right: Radius.circular(4),
                ),
              ),
              // The active domain's blue rides its own alpha-only layer —
              // a straight lerp into the neutral fill darkened the item
              // being deselected (26 号票 真机 round).
              foregroundDecoration: BoxDecoration(
                color: active
                    ? pal.accentSoft
                    : pal.accentSoft.withValues(alpha: 0),
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(SrRadius.control),
                  right: Radius.circular(4),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    domain.icon,
                    size: 16,
                    color: active ? pal.accentText : pal.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    domain.label,
                    style: SrType.body.copyWith(
                      color: active ? pal.accentText : pal.textSecondary,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 场景库 pane — the one domain filled out at production quality
// ---------------------------------------------------------------------------

class _ScenarioPane extends StatelessWidget {
  const _ScenarioPane({
    required this.scenarios,
    required this.selected,
    required this.global,
    required this.onSelect,
    required this.onAddOrUpdate,
    required this.onDelete,
    required this.onSaveGlobal,
  });

  final List<BridgeScenario> scenarios;
  final String? selected;

  /// The global directive as the file reads it (null = unset) — the
  /// inline card's seed (ticket 22).
  final String? global;
  final Future<void> Function(String? name) onSelect;
  final Future<void> Function(BridgeScenario edited, String? originalName)
  onAddOrUpdate;
  final Future<void> Function(String name) onDelete;
  final Future<void> Function(String text) onSaveGlobal;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('场景库', style: SrType.title.copyWith(color: pal.textPrimary)),
            const Spacer(),
            SrButton(
              key: const Key('settings-scenario-new'),
              primary: true,
              label: '新建场景',
              onTap: () => _editScenario(context, null),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // The global directive rides above the library list: always
        // present, empty library or not.
        _GlobalDirectiveCard(directive: global, onSave: onSaveGlobal),
        const SizedBox(height: 16),
        if (scenarios.isEmpty)
          _EmptyLibrary()
        else
          for (final scenario in scenarios)
            _ScenarioCard(
              scenario: scenario,
              selected: selected == scenario.name,
              onTap: () =>
                  onSelect(selected == scenario.name ? null : scenario.name),
              onEdit: () => _editScenario(context, scenario),
              onDelete: () => onDelete(scenario.name),
            ),
      ],
    );
  }

  Future<void> _editScenario(
    BuildContext context,
    BridgeScenario? existing,
  ) async {
    final edited = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) => _ScenarioEditorDialog(
        initialName: existing?.name,
        initialDirective: existing?.directive,
        existingNames: {for (final scenario in scenarios) scenario.name},
      ),
    );
    if (edited == null) return;
    final (name, directive) = edited;
    await onAddOrUpdate(
      // The existing entry's id rides along, so a rename keeps the
      // row's identity and the history rows referencing it.
      BridgeScenario(id: existing?.id, name: name, directive: directive),
      existing?.name,
    );
  }
}

/// The global directive's resident inline card (ticket 22): a title, one
/// explanatory line, a multi-line field, and an explicit save button —
/// disabled until the text differs from the saved directive. Saving blank
/// text is how the directive is turned off (it writes the unset form).
class _GlobalDirectiveCard extends StatefulWidget {
  const _GlobalDirectiveCard({required this.directive, required this.onSave});

  /// The saved directive as the file reads it (null = unset).
  final String? directive;
  final Future<void> Function(String text) onSave;

  @override
  State<_GlobalDirectiveCard> createState() => _GlobalDirectiveCardState();
}

class _GlobalDirectiveCardState extends State<_GlobalDirectiveCard> {
  late final TextEditingController _field = TextEditingController(
    text: widget.directive ?? '',
  );

  @override
  void initState() {
    super.initState();
    // The dirty check re-runs on every keystroke (the save button's
    // enable follows), without threading onChanged through SrField.
    _field.addListener(_onInput);
  }

  @override
  void didUpdateWidget(_GlobalDirectiveCard old) {
    super.didUpdateWidget(old);
    // A save landed (the parent's state moved): re-seed the field to the
    // canonical trimmed text so the dirty check resets. Unrelated
    // rebuilds (theme, selection) leave the field untouched.
    if (widget.directive != old.directive) {
      _field.text = widget.directive ?? '';
    }
  }

  @override
  void dispose() {
    _field.removeListener(_onInput);
    _field.dispose();
    super.dispose();
  }

  void _onInput() {
    if (mounted) setState(() {});
  }

  bool get _dirty => _field.text.trim() != (widget.directive ?? '');

  Future<void> _save() async {
    if (!_dirty) return;
    await widget.onSave(_field.text);
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return AnimatedContainer(
      key: const Key('settings-global-card'),
      duration: SrMotion.fade,
      curve: SrMotion.curveFade,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.surfaceRaised,
        borderRadius: BorderRadius.circular(SrRadius.control + 4),
        border: Border.all(color: pal.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '全局指令',
                style: SrType.section.copyWith(color: pal.textPrimary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '始终生效，与场景指令冲突时以场景为准',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SrField(
            key: const Key('settings-global-field'),
            controller: _field,
            hint: '例：全部输出以简体中文书写，语气克制',
            minLines: 2,
            maxLines: 5,
            // The save rides the box's own bottom-right corner (35 号票):
            // a field-scoped button belongs to its field, not the card's
            // footer. It lights up only when there is something to save —
            // enabled (accent) while dirty, a quiet outlined button at
            // rest; disabled means no-op, never hidden.
            cornerAction: SrButton(
              key: const Key('settings-global-save'),
              dense: true,
              primary: _dirty,
              label: '保存',
              onTap: _dirty ? _save : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 96, bottom: 96),
        child: Column(
          children: [
            Icon(Icons.style_outlined, size: 32, color: pal.textTertiary),
            const SizedBox(height: 12),
            Text(
              key: const Key('settings-scenario-empty'),
              '暂无场景',
              style: SrType.body.copyWith(color: pal.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({
    required this.scenario,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final BridgeScenario scenario;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => SrPress(
        builder: (pressed) => Padding(
          // Hover hit area = the painted card (row gap outside).
          padding: const EdgeInsets.only(bottom: 10),
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: SrPressFill(
              // Press darkens at pointer-down; the border highlight
              // follows the selection state (26 号票 真机 round).
              pressed: pressed,
              radius: BorderRadius.circular(SrRadius.control + 4),
              child: AnimatedContainer(
                key: Key('settings-scenario-card:${scenario.name}'),
                duration: SrMotion.fade,
                curve: SrMotion.curveFade,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: pal.surfaceRaised,
                  borderRadius: BorderRadius.circular(SrRadius.control + 4),
                  border: Border.all(
                    color: selected
                        ? pal.accent.withValues(alpha: 0.6)
                        : (hover
                              ? pal.accent.withValues(alpha: 0.45)
                              : pal.hairline),
                  ),
                ),
                // The title row centers optically (31 号票): the
                // subhead title (33 号票's card-title ruling), the 16px
                // glyph, and the 15px action icons share one horizontal
                // line — the directive preview stays under it, indented
                // to the title's edge.
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // The glyph swap cross-dissolves instead of
                        // snapping (26 号票): check and ring fade through
                        // each other on the surface-fade window.
                        AnimatedSwitcher(
                          duration: SrMotion.fade,
                          switchInCurve: SrMotion.curveFade,
                          switchOutCurve: SrMotion.curveFade,
                          child: Icon(
                            selected
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            key: ValueKey(selected),
                            size: 16,
                            color: selected ? pal.accentText : pal.textTertiary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: AnimatedDefaultTextStyle(
                            // The selection is a discrete switch: the title
                            // rides the same fade window as the border
                            // (26 号票).
                            duration: SrMotion.fade,
                            curve: SrMotion.curveFade,
                            style: SrType.subhead.copyWith(
                              color: selected
                                  ? pal.accentText
                                  : pal.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                            child: Text(scenario.name),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Hover actions mirror the quick panel's history
                        // rows: resident layout, cross-dissolved on the
                        // fade token.
                        IgnorePointer(
                          ignoring: !hover,
                          child: AnimatedOpacity(
                            duration: SrMotion.fade,
                            curve: SrMotion.curveFade,
                            opacity: hover ? 1 : 0,
                            child: Row(
                              children: [
                                _CardAction(
                                  icon: Icons.edit_outlined,
                                  tooltip: '编辑',
                                  onTap: onEdit,
                                ),
                                const SizedBox(width: 10),
                                _CardAction(
                                  icon: Icons.delete_outline_rounded,
                                  tooltip: '删除',
                                  onTap: onDelete,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      // Icon (16) + its gap (10): the preview hangs under
                      // the title, not under the glyph.
                      padding: const EdgeInsets.only(left: 26),
                      child: Text(
                        scenario.directive,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: SrType.micro.copyWith(color: pal.textTertiary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SrTooltip(
          message: tooltip,
          child: Icon(
            icon,
            size: 15,
            color: hover ? pal.accentText : pal.textTertiary,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The add/edit dialog
// ---------------------------------------------------------------------------

class _ScenarioEditorDialog extends StatefulWidget {
  const _ScenarioEditorDialog({
    required this.initialName,
    required this.initialDirective,
    required this.existingNames,
  });

  final String? initialName;
  final String? initialDirective;

  /// The library's names as the dialog opened — validation input, so a
  /// save can never produce the duplicated-name file the Rust writer
  /// refuses.
  final Set<String> existingNames;

  @override
  State<_ScenarioEditorDialog> createState() => _ScenarioEditorDialogState();
}

class _ScenarioEditorDialogState extends State<_ScenarioEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _directive = TextEditingController(
    text: widget.initialDirective,
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _directive.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final directive = _directive.text.trim();
    if (name.isEmpty || directive.isEmpty) {
      setState(() => _error = '名称与风格指令都不能为空');
      return;
    }
    // Keeping one's own name while editing is fine; taking another
    // entry's name is a duplicate the Rust writer would refuse.
    final duplicatesAnother =
        widget.existingNames.contains(name) && name != widget.initialName;
    if (duplicatesAnother) {
      setState(() => _error = '已存在同名场景');
      return;
    }
    Navigator.of(context).pop((name, directive));
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.initialName == null ? '新建场景' : '编辑场景',
                style: SrType.title.copyWith(color: pal.textPrimary),
              ),
              const SizedBox(height: 16),
              SrField(
                key: const Key('settings-scenario-name-field'),
                controller: _name,
                label: '名称',
                autofocus: true,
              ),
              const SizedBox(height: 12),
              SrField(
                key: const Key('settings-scenario-directive-field'),
                controller: _directive,
                label: '风格指令',
                minLines: 3,
                maxLines: 6,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const Key('settings-scenario-form-error'),
                  style: SrType.micro.copyWith(color: pal.live),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SrButton(
                    key: const Key('settings-scenario-cancel'),
                    label: '取消',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  SrButton(
                    key: const Key('settings-scenario-save'),
                    primary: true,
                    label: '保存',
                    onTap: _save,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
