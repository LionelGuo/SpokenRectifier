/// The settings window: a REAL independent OS window (standard title bar,
/// taskbar entry, centered, resizable — spec §4.4), not another panel of
/// the morphing orb window. Spawned via desktop_multi_window (a second
/// Flutter engine re-runs main; see main.dart's sub-entry branch). Its
/// data seams are the file-backed stores (the bridge, direct) and its
/// cross-window link is [SettingsChannel] (events only, never state).
///
/// All seven domains are filled: scenarios (场景库), fidelity eval
/// (保真评测) and history (历史) since ticket 18, terms (术语),
/// connection (模型与连接), advanced (高级, read-only escape hatch) and
/// about (关于) since ticket 19. The eval run lives in a controller here
/// — it survives domain switches; closing the window is what stops it.

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton;
import '../design/hover.dart';
import '../design/theme.dart' show srTheme;
import '../design/tokens.dart';
import '../rust/api.dart' show BridgeScenario;
import 'caption_theme.dart';
import 'connection_store.dart';
import 'fidelity_eval.dart';
import 'history_store.dart';
import 'settings_about_pane.dart';
import 'settings_advanced_pane.dart';
import 'settings_channel.dart';
import 'settings_connection_pane.dart';
import 'settings_domain.dart';
import 'settings_fidelity_pane.dart';
import 'settings_history_pane.dart';
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
    required this.systemStore,
    this.initialTheme = ThemeMode.system,
    this.initialSelection,
    this.captionTheme = applyWindowsCaptionTheme,
  });

  final ScenarioStore store;
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

  /// The advanced and about domains' seam (read-only timings, version,
  /// and the open-config entry the tray shares).
  final SystemStore systemStore;

  /// Theme and selection ride the window arguments (the main window
  /// cannot push into the sub-engine before its handler exists), then
  /// follow live over the channel.
  final ThemeMode initialTheme;
  final String? initialSelection;

  /// Paints the OS caption (title bar) with the effective brightness;
  /// injectable so widget tests can record the applications.
  final void Function(Brightness brightness) captionTheme;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp>
    with WidgetsBindingObserver {
  ThemeMode _mode = ThemeMode.system;
  SettingsDomain _domain = SettingsDomain.scenarios;
  List<BridgeScenario> _scenarios = const [];
  String? _selected;
  String? _error;

  /// The eval run outlives the pane: switching domains must not stop it
  /// (only closing the window — this state dying with the engine — or
  /// the pane's 取消 does).
  late final FidelityEvalController _eval = FidelityEvalController(
    runner: widget.evalRunner,
  );

  @override
  void initState() {
    super.initState();
    _mode = widget.initialTheme;
    _domain = widget.initialDomain;
    _selected = widget.initialSelection;
    _load();
    widget.channel.onTheme = _setMode;
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
      // empty state plus the error; nothing is written.
      if (!mounted) return;
      setState(() => _error = '场景库读取失败:$e');
    }
  }

  /// Persist the editor's whole model, then tell the main window. Local
  /// state only moves once the file has accepted the write — the file is
  /// the truth, the editor is a view.
  Future<bool> _commit(
    List<BridgeScenario> next, {
    String? renamedFrom,
    String? renamedTo,
  }) async {
    try {
      await widget.store.save(next);
    } catch (e) {
      setState(() => _error = '场景库保存失败:$e');
      return false;
    }
    setState(() => _scenarios = next);
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
        // light while dark mode darkened everything else.
        builder: (context) => Scaffold(
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
        ),
      ),
    );
  }

  Widget _domainPane(BuildContext context) {
    return switch (_domain) {
      SettingsDomain.scenarios => _ScenarioPane(
        scenarios: _scenarios,
        selected: _selected,
        error: _error,
        onSelect: _select,
        onAddOrUpdate: _addOrUpdate,
        onDelete: _delete,
      ),
      SettingsDomain.fidelity => SettingsFidelityPane(controller: _eval),
      SettingsDomain.history => SettingsHistoryPane(
        store: widget.historyStore,
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
      SettingsDomain.advanced => SettingsAdvancedPane(store: widget.systemStore),
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
      builder: (hover) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          // Surface-fade feel (the quick panel's hover rule): fill eases
          // in and out on the symmetric fade token, tinted by the target
          // color's own alpha.
          duration: SrMotion.fade,
          curve: SrMotion.curveFade,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? pal.accentSoft
                : pal.surfaceOverlay.withValues(alpha: hover ? 1 : 0),
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
    required this.error,
    required this.onSelect,
    required this.onAddOrUpdate,
    required this.onDelete,
  });

  final List<BridgeScenario> scenarios;
  final String? selected;
  final String? error;
  final Future<void> Function(String? name) onSelect;
  final Future<void> Function(BridgeScenario edited, String? originalName)
  onAddOrUpdate;
  final Future<void> Function(String name) onDelete;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('场景库', style: SrType.title.copyWith(color: pal.textPrimary)),
            const SizedBox(width: 10),
            Text(
              '未选中时使用默认语体',
              style: SrType.caption.copyWith(color: pal.textTertiary),
            ),
            const Spacer(),
            SrButton(
              key: const Key('settings-scenario-new'),
              primary: true,
              label: '新建场景',
              onTap: () => _editScenario(context, null),
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(
            error!,
            key: const Key('settings-scenario-error'),
            style: SrType.caption.copyWith(color: pal.live),
          ),
        ],
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
      BridgeScenario(name: name, directive: directive),
      existing?.name,
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
            const SizedBox(height: 6),
            Text(
              '场景是一条命名的风格指令,选中后自下一次修正起生效。',
              style: SrType.caption.copyWith(color: pal.textTertiary),
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
      builder: (hover) => Padding(
        // Hover hit area = the painted card (row gap outside).
        padding: const EdgeInsets.only(bottom: 10),
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  size: 16,
                  color: selected ? pal.accentText : pal.textTertiary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        scenario.name,
                        style: SrType.body.copyWith(
                          color: selected ? pal.accentText : pal.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        scenario.directive,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: SrType.caption.copyWith(
                          color: pal.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Hover actions mirror the quick panel's history rows:
                // resident layout, cross-dissolved on the fade token.
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
        child: Tooltip(
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
      setState(() => _error = '已有同名场景');
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
              // The name field borrows the quick panel's term-row recipe:
              // the box is drawn by the container (paint = layout), the
              // TextField inside is undecorated.
              _DialogField(
                fieldKey: const Key('settings-scenario-name-field'),
                controller: _name,
                label: '名称',
                autoFocus: true,
              ),
              const SizedBox(height: 12),
              _DialogField(
                fieldKey: const Key('settings-scenario-directive-field'),
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
                  style: SrType.caption.copyWith(color: pal.live),
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

class _DialogField extends StatelessWidget {
  const _DialogField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.autoFocus = false,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool autoFocus;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: SrType.micro.copyWith(color: pal.textTertiary)),
        const SizedBox(height: 4),
        TextField(
          key: fieldKey,
          controller: controller,
          autofocus: autoFocus,
          minLines: minLines,
          maxLines: maxLines,
          style: SrType.body.copyWith(color: pal.textPrimary),
          cursorColor: pal.accent,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            focusedBorder: InputBorder.none,
            enabledBorder: InputBorder.none,
            filled: true,
            fillColor: pal.surfaceOverlay,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 9,
            ),
          ),
        ),
      ],
    );
  }
}
