/// The 历史 domain: full-session browsing (raw + rectified, newest
/// first), retrieval (复制原始转写 / 复制修正文本 to the clipboard;
/// 指定场景重新修正 routed to the main window through the cross-window
/// channel — the same controller path the quick panel's rows take, with
/// the picked style, a scenario or the built-in 默认, pinned for that
/// one session), the list-level scenario filter (按场景筛历史: a chip
/// row between the config card and the list — 全部 the opening
/// selection, 默认 the same word and meaning as the rerectify menu's
/// built-in, then each scenario; hidden over an empty library, never
/// persisted), the `[history]` settings (保留期 chips, the 不留存
/// switch whose enable clears what exists), and the one-click clear
/// (the same bridge call the tray makes). File is truth: every
/// mutation re-reads the store.

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../design/controls.dart' show SrButton, SrCard, SrPressFill;
import '../design/hover.dart';
import '../design/sr_tooltip.dart';
import '../design/toast.dart';
import '../design/tokens.dart';
import '../errors.dart';
import '../rust/api/history.dart'
    show BridgeHistoryEntry,
        BridgeHistoryFilter;
import '../rust/api/library.dart'
    show BridgeScenario;
import '../shell/history_retrieval.dart'
    show HistoryRerectify, showScenarioRerectifyMenu;
import '../shell/quick_panel.dart' show formatHistoryStamp;
import 'history_store.dart';

/// The retention presets, shortest to longest. A config value outside
/// the presets (hand-edited file) paints as its own chip so the current
/// value is always selectable.
const _retentionPresets = [7, 30, 90, 365];

class SettingsHistoryPane extends StatefulWidget {
  const SettingsHistoryPane({
    super.key,
    required this.store,
    required this.scenarios,
    required this.onHistoryChanged,
    required this.onRerectify,
  });

  final HistorySettingsStore store;

  /// The scenario library, same source as the 场景库 domain paints — the
  /// one-time rerectify menu lists exactly these.
  final List<BridgeScenario> scenarios;

  /// Fires every time the store's shape changed (retention, keep-nothing,
  /// clear) — the main window re-reads its rows.
  final Future<void> Function() onHistoryChanged;

  /// History retrieval routed to the main window's session flow. The
  /// scenario, when named, pins that one session to it (ticket 23).
  final HistoryRerectify onRerectify;

  @override
  State<SettingsHistoryPane> createState() => _SettingsHistoryPaneState();
}

class _SettingsHistoryPaneState extends State<SettingsHistoryPane> {
  HistorySettings? _config;
  List<BridgeHistoryEntry> _entries = const [];

  /// The whole library's row count, whatever the filter shows: 清空 and
  /// 不留存 act on the whole library (the tray's clear shares the call),
  /// so their confirmations must count what they delete — the filter is
  /// a browsing state and never narrows the blast radius.
  int _allCount = 0;

  /// The list-level scenario scope the chip row selects. Not persisted:
  /// every opening of the pane starts at 全部.
  BridgeHistoryFilter _filter = const BridgeHistoryFilter.all();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final config = await widget.store.loadConfig();
      final entries = await widget.store.list(_filter);
      final all = await widget.store.list(const BridgeHistoryFilter.all());
      if (!mounted) return;
      setState(() {
        _config = config;
        _entries = entries;
        _allCount = all.length;
      });
    } catch (e) {
      if (!mounted) return;
      logRawError('err_history_load', e);
      SrToast.of(context).show('历史记录读取失败', tone: SrToastTone.error);
    }
  }

  Future<void> _saveConfig(HistorySettings next) async {
    try {
      final saved = await widget.store.saveConfig(next);
      if (!mounted) return;
      setState(() => _config = saved);
      await widget.onHistoryChanged();
    } catch (e) {
      if (!mounted) return;
      logRawError('err_history_save', e);
      SrToast.of(context).show('保存失败', tone: SrToastTone.error);
    }
  }

  /// The 不留存 switch's enable is destructive by design (开启即清空):
  /// confirm once, then clear follows the config change.
  Future<void> _toggleKeepNothing(bool on) async {
    final config = _config;
    if (config == null) return;
    if (on && _allCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => _ConfirmDialog(
          title: '开启不留存模式？',
          body: '$_allCount 条历史将被永久删除，新会话将不再保留历史。',
          confirmLabel: '开启并清空',
        ),
        barrierDismissible: false,
      );
      if (confirmed != true) return;
    }
    await _saveConfig(config.copyWith(enabled: !on));
    await _reload();
  }

  /// A chip tap re-reads the list through the seam under the new scope —
  /// file is truth, same as every other mutation here.
  Future<void> _setFilter(BridgeHistoryFilter next) async {
    if (next == _filter) return;
    setState(() => _filter = next);
    await _reload();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ConfirmDialog(
        key: const Key('settings-history-clear-confirm'),
        title: '清空全部历史？',
        body: '$_allCount 条历史将被永久删除。',
        confirmLabel: '清空',
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.store.clear();
      await widget.onHistoryChanged();
      await _reload();
    } catch (e) {
      if (!mounted) return;
      logRawError('err_history_clear', e);
      SrToast.of(context).show('清空失败', tone: SrToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final config = _config;
    // The chip row lists the library's id-bearing entries (production
    // rows always carry one; a null id is an editor draft nothing can
    // filter by). An empty library hides the whole row — everything is
    // 默认 then, the filter carries no information — and so does the
    // keep-nothing mode, which shows no list to filter.
    final filterable = [
      for (final scenario in widget.scenarios)
        if (scenario.id != null) scenario,
    ];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('历史', style: SrType.title.copyWith(color: pal.textPrimary)),
        const SizedBox(height: 16),
        if (config == null)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          _ConfigCard(
            config: config,
            onToggleKeepNothing: _toggleKeepNothing,
            onRetention: (days) =>
                _saveConfig(config.copyWith(retentionDays: days)),
            onClear: _allCount == 0 || !config.enabled ? null : _clear,
          ),
          if (config.enabled && filterable.isNotEmpty) ...[
            const SizedBox(height: 20),
            _FilterRow(
              filter: _filter,
              scenarios: filterable,
              onSelect: _setFilter,
            ),
          ],
          const SizedBox(height: 20),
          if (!config.enabled)
            _EmptyNote(
              key: const Key('settings-history-keep-nothing-note'),
              icon: Icons.block_rounded,
              text: '不留存模式已开启',
            )
          else if (_entries.isEmpty)
            _EmptyNote(
              key: const Key('settings-history-empty'),
              icon: Icons.history_rounded,
              text: '暂无历史记录',
            )
          else
            for (final entry in _entries)
              _HistoryEntryRow(
                entry: entry,
                scenarios: widget.scenarios,
                onRerectify: widget.onRerectify,
              ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// The config card: 不留存 / 保留期 / 一键清空
// ---------------------------------------------------------------------------

class _ConfigCard extends StatelessWidget {
  const _ConfigCard({
    required this.config,
    required this.onToggleKeepNothing,
    required this.onRetention,
    required this.onClear,
  });

  final HistorySettings config;
  final Future<void> Function(bool on) onToggleKeepNothing;
  final ValueChanged<int> onRetention;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    // The chip set: every preset, plus the current value as its own chip
    // when a hand-edited config sits between them.
    final days = [
      ..._retentionPresets,
      if (!_retentionPresets.contains(config.retentionDays))
        config.retentionDays,
    ]..sort();
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '不留存输入历史',
                  style: SrType.section.copyWith(color: pal.textPrimary),
                ),
              ),
              Switch(
                key: const Key('settings-history-keep-nothing'),
                value: !config.enabled,
                onChanged: (on) => onToggleKeepNothing(on),
              ),
            ],
          ),
          Divider(height: 28, color: pal.hairline),
          Text(
            '历史保留时长',
            style: SrType.section.copyWith(color: pal.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            '超过保留时长的记录将被自动清理',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 10),
          Wrap(
            key: const Key('settings-history-retention'),
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in days)
                _SrChip(
                  key: Key('settings-history-retention:$preset'),
                  label: _retentionLabel(preset),
                  selected: preset == config.retentionDays,
                  enabled: config.enabled,
                  onTap: () => onRetention(preset),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SrButton(
                key: const Key('settings-history-clear'),
                label: '清空历史',
                onTap: onClear,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _retentionLabel(int days) => switch (days) {
  7 => '7 天',
  30 => '30 天',
  90 => '90 天',
  365 => '1 年',
  _ => '$days 天',
};

/// One chip of the pane's two single-select rows (保留期 presets, the
/// scenario filter): the shared visual language — selected accentSoft
/// fill + accent border, `SrRadius.control` corners, hover surface,
/// press darkening, the label fading with its box (26 号票 真机 round).
class _SrChip extends StatelessWidget {
  const _SrChip({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => SrPress(
        builder: (pressed) => GestureDetector(
          onTap: enabled ? onTap : null,
          behavior: HitTestBehavior.opaque,
          child: SrPressFill(
            // Press darkens at pointer-down; the highlight follows the
            // selection state (26 号票 真机 round).
            pressed: pressed && enabled,
            radius: BorderRadius.circular(SrRadius.control),
            child: AnimatedContainer(
              duration: SrMotion.fade,
              curve: SrMotion.curveFade,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: pal.surfaceOverlay.withValues(
                  alpha: hover && enabled ? 1 : 0,
                ),
                borderRadius: BorderRadius.circular(SrRadius.control),
                border: Border.all(color: pal.hairline),
              ),
              // The selection's blue rides its own alpha-only layer — a
              // straight lerp into the neutral fill darkened the chip
              // being deselected (26 号票 真机 round).
              foregroundDecoration: BoxDecoration(
                color: selected
                    ? pal.accentSoft
                    : pal.accentSoft.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(SrRadius.control),
                border: Border.all(
                  color: selected
                      ? pal.accent.withValues(alpha: 0.6)
                      : pal.accent.withValues(alpha: 0),
                ),
              ),
              child: AnimatedDefaultTextStyle(
                // The selection is a discrete switch: the label rides the
                // same fade window as its box (26 号票).
                duration: SrMotion.fade,
                curve: SrMotion.curveFade,
                style: SrType.caption.copyWith(
                  color: !enabled
                      ? pal.textTertiary
                      : (selected ? pal.accentText : pal.textSecondary),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
                child: Text(label),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The scenario filter chip row (按场景筛历史)
// ---------------------------------------------------------------------------

/// The list-level scenario scope: 全部 (the opening selection) / 默认 /
/// each scenario — single-select, list-level, deliberately not in the
/// same row as the per-entry retrieval keys. 「默认」 is the same word
/// and the same meaning as the rerectify menu's built-in item: 未选场景,
/// `scenario_id IS NULL`, which deleted scenarios' rows fold into (SET
/// NULL, the schema's own semantics). [scenarios] carries only
/// id-bearing entries — the pane filters the library first, an unsaved
/// editor draft has nothing to filter by.
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.filter,
    required this.scenarios,
    required this.onSelect,
  });

  final BridgeHistoryFilter filter;
  final List<BridgeScenario> scenarios;
  final ValueChanged<BridgeHistoryFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const Key('settings-history-filter'),
      spacing: 8,
      runSpacing: 8,
      children: [
        _SrChip(
          key: const Key('settings-history-filter:all'),
          label: '全部',
          selected: filter == const BridgeHistoryFilter.all(),
          enabled: true,
          onTap: () => onSelect(const BridgeHistoryFilter.all()),
        ),
        _SrChip(
          key: const Key('settings-history-filter:default'),
          label: '默认',
          selected: filter == const BridgeHistoryFilter.defaultRegister(),
          enabled: true,
          onTap: () => onSelect(const BridgeHistoryFilter.defaultRegister()),
        ),
        for (final scenario in scenarios)
          _SrChip(
            key: Key('settings-history-filter:scenario:${scenario.name}'),
            label: scenario.name,
            selected: filter == BridgeHistoryFilter.scenario(scenario.id!),
            enabled: true,
            onTap: () =>
                onSelect(BridgeHistoryFilter.scenario(scenario.id!)),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

class _HistoryEntryRow extends StatelessWidget {
  const _HistoryEntryRow({
    required this.entry,
    required this.scenarios,
    required this.onRerectify,
  });

  final BridgeHistoryEntry entry;
  final List<BridgeScenario> scenarios;
  final HistoryRerectify onRerectify;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final stamp = formatHistoryStamp(
      at: DateTime.fromMillisecondsSinceEpoch(entry.createdAtMs.toInt()),
      now: DateTime.now(),
    );
    return Padding(
      // Row gap outside the hover region, like the quick panel's rows.
      padding: const EdgeInsets.only(bottom: 6),
      child: SrHover(
        builder: (hover) => AnimatedContainer(
          duration: SrMotion.fade,
          curve: SrMotion.curveFade,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: pal.surfaceRaised.withValues(alpha: hover ? 1 : 0),
            borderRadius: BorderRadius.circular(SrRadius.control),
            border: Border.all(color: pal.hairline),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stamp,
                      style: SrType.micro.copyWith(color: pal.textTertiary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.rawTranscript.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SrType.micro.copyWith(color: pal.textSecondary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.rectifiedText.replaceAll('\n', ' '),
                      key: Key('settings-history-rectified:${entry.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SrType.micro.copyWith(color: pal.textTertiary),
                    ),
                  ],
                ),
              ),
              // 悬停显复制/重修 — the quick panel's fade recipe. Three
              // retrieval keys (ticket 23): copy both texts, and a
              // one-time re-rectify under a picked scenario (the menu
              // lists the same library the 场景库 domain paints; an empty
              // library disables the key — the tooltip says why).
              IgnorePointer(
                ignoring: !hover,
                child: AnimatedOpacity(
                  duration: SrMotion.fade,
                  curve: SrMotion.curveFade,
                  opacity: hover ? 1 : 0,
                  child: Row(
                    children: [
                      _EntryAction(
                        key: Key('settings-history-copy-raw:${entry.id}'),
                        // Quote marks read as 逐字原话 — the copy glyph
                        // belongs to the rectified text (same icon as the
                        // quick panel's copy key; 2026-08-30 ruling).
                        icon: Icons.format_quote_rounded,
                        tooltip: '复制原始转写',
                        onTap: () => Clipboard.setData(
                          ClipboardData(text: entry.rawTranscript),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _EntryAction(
                        key: Key('settings-history-copy-rectified:${entry.id}'),
                        icon: Icons.copy_rounded,
                        tooltip: '复制修正文本',
                        onTap: () => Clipboard.setData(
                          ClipboardData(text: entry.rectifiedText),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _ScenarioRerectifyAction(
                        entry: entry,
                        scenarios: scenarios,
                        onRerectify: onRerectify,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryAction extends StatelessWidget {
  const _EntryAction({
    super.key,
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
      builder: (hover) => SrTooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
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

/// The third retrieval key: 指定场景重新修正. The same shell as the two
/// copy keys — icon size, alignment, spacing, hover tint — so the three
/// read as one family; the tap opens the shared scenario menu
/// ([showScenarioRerectifyMenu]), which lists 默认 plus the same entries
/// the 场景库 domain paints — over an empty library 默认 alone, keeping
/// retrieval alive (ticket 28).
class _ScenarioRerectifyAction extends StatelessWidget {
  const _ScenarioRerectifyAction({
    required this.entry,
    required this.scenarios,
    required this.onRerectify,
  });

  final BridgeHistoryEntry entry;
  final List<BridgeScenario> scenarios;
  final HistoryRerectify onRerectify;

  Future<void> _open(BuildContext context) async {
    final pick = await showScenarioRerectifyMenu(
      context,
      scenarios: scenarios,
      itemKeyPrefix: 'settings-history-scenario-item',
    );
    if (pick == null) return;
    await onRerectify(
      entry.rawTranscript,
      style: pick,
      sourceSessionId: entry.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => SrTooltip(
        key: Key('settings-history-rerectify-scenario:${entry.id}'),
        message: '指定场景重新修正',
        child: GestureDetector(
          onTap: () => _open(context),
          child: Icon(
            Icons.style_rounded,
            size: 15,
            color: hover ? pal.accentText : pal.textTertiary,
          ),
        ),
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 48, bottom: 48),
        child: Column(
          children: [
            Icon(icon, size: 32, color: pal.textTertiary),
            const SizedBox(height: 12),
            Text(text, style: SrType.body.copyWith(color: pal.textSecondary)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The confirm dialog (the scenario editor's dialog recipe)
// ---------------------------------------------------------------------------

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    super.key,
    required this.title,
    required this.body,
    required this.confirmLabel,
  });

  final String title;
  final String body;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: SrType.title.copyWith(color: pal.textPrimary)),
              const SizedBox(height: 12),
              Text(
                body,
                style: SrType.micro.copyWith(color: pal.textSecondary),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SrButton(
                    key: const Key('settings-history-confirm-cancel'),
                    label: '取消',
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  SrButton(
                    key: const Key('settings-history-confirm-ok'),
                    label: confirmLabel,
                    primary: true,
                    onTap: () => Navigator.of(context).pop(true),
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
