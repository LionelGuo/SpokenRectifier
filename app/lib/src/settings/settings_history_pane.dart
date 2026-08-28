/// The 历史 domain: full-session browsing (raw + rectified, newest
/// first), retrieval (复制原始转写 straight to the clipboard; 重新修正
/// routed to the main window through the cross-window channel — the
/// same controller path the quick panel's rows take), the `[history]`
/// settings (保留期 chips, the 不留存 switch whose enable clears what
/// exists), and the one-click clear (the same bridge call the tray
/// makes). File is truth: every mutation re-reads the store.

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../design/controls.dart' show SrButton, SrCard;
import '../design/hover.dart';
import '../design/tokens.dart';
import '../rust/api.dart' show BridgeHistoryEntry;
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
    required this.onHistoryChanged,
    required this.onRerectify,
  });

  final HistorySettingsStore store;

  /// Fires every time the store's shape changed (retention, keep-nothing,
  /// clear) — the main window re-reads its rows.
  final Future<void> Function() onHistoryChanged;

  /// History retrieval routed to the main window's session flow.
  final Future<void> Function(String rawTranscript) onRerectify;

  @override
  State<SettingsHistoryPane> createState() => _SettingsHistoryPaneState();
}

class _SettingsHistoryPaneState extends State<SettingsHistoryPane> {
  HistorySettings? _config;
  List<BridgeHistoryEntry> _entries = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final config = await widget.store.loadConfig();
      final entries = await widget.store.list();
      if (!mounted) return;
      setState(() {
        _config = config;
        _entries = entries;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '历史读取失败:$e');
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
      setState(() => _error = '历史设置保存失败:$e');
    }
  }

  /// The 不留存 switch's enable is destructive by design (开启即清空):
  /// confirm once, then clear follows the config change.
  Future<void> _toggleKeepNothing(bool on) async {
    final config = _config;
    if (config == null) return;
    if (on && _entries.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => _ConfirmDialog(
          title: '开启不留存?',
          body: '将立即清空全部 ${_entries.length} 条既有历史,且不再记录新会话。',
          confirmLabel: '开启并清空',
        ),
        barrierDismissible: false,
      );
      if (confirmed != true) return;
    }
    await _saveConfig(config.copyWith(enabled: !on));
    await _reload();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ConfirmDialog(
        key: const Key('settings-history-clear-confirm'),
        title: '清空全部历史?',
        body: '将删除全部 ${_entries.length} 条记录,不可恢复。',
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
      setState(() => _error = '清空失败:$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final config = _config;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('历史', style: SrType.title.copyWith(color: pal.textPrimary)),
            const SizedBox(width: 10),
            Text(
              '仅本机留存文本;音频永不落盘',
              style: SrType.caption.copyWith(color: pal.textTertiary),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const Key('settings-history-error'),
            style: SrType.caption.copyWith(color: pal.live),
          ),
        ],
        const SizedBox(height: 16),
        if (config == null)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          _ConfigCard(
            config: config,
            onToggleKeepNothing: _toggleKeepNothing,
            onRetention: (days) =>
                _saveConfig(config.copyWith(retentionDays: days)),
            onClear: _entries.isEmpty || !config.enabled ? null : _clear,
          ),
          const SizedBox(height: 20),
          if (!config.enabled)
            _EmptyNote(
              key: const Key('settings-history-keep-nothing-note'),
              icon: Icons.block_rounded,
              text: '不留存模式:不记录任何会话。关闭开关后恢复记录。',
            )
          else if (_entries.isEmpty)
            _EmptyNote(
              key: const Key('settings-history-empty'),
              icon: Icons.history_rounded,
              text: '暂无历史记录',
            )
          else
            for (final entry in _entries)
              _HistoryEntryRow(entry: entry, onRerectify: widget.onRerectify),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '不留存',
                      style: SrType.body.copyWith(
                        color: pal.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '完全不记录;开启即清空既有历史',
                      style: SrType.micro.copyWith(color: pal.textTertiary),
                    ),
                  ],
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
            '保留期',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '超过保留期的记录在读取时自动清理',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 10),
          Wrap(
            key: const Key('settings-history-retention'),
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in days)
                _RetentionChip(
                  days: preset,
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
                label: '一键清空',
                onTap: onClear,
              ),
              if (!config.enabled) ...[
                const SizedBox(width: 10),
                Text(
                  '不留存模式下无历史',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
              ],
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

class _RetentionChip extends StatelessWidget {
  const _RetentionChip({
    required this.days,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final int days;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: SrMotion.fade,
          curve: SrMotion.curveFade,
          key: Key('settings-history-retention:$days'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? pal.accentSoft
                : pal.surfaceOverlay.withValues(
                    alpha: hover && enabled ? 1 : 0,
                  ),
            borderRadius: BorderRadius.circular(SrRadius.control),
            border: Border.all(
              color: selected
                  ? pal.accent.withValues(alpha: 0.6)
                  : pal.hairline,
            ),
          ),
          child: Text(
            _retentionLabel(days),
            style: SrType.caption.copyWith(
              color: !enabled
                  ? pal.textTertiary
                  : (selected ? pal.accentText : pal.textSecondary),
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

class _HistoryEntryRow extends StatelessWidget {
  const _HistoryEntryRow({required this.entry, required this.onRerectify});

  final BridgeHistoryEntry entry;
  final Future<void> Function(String rawTranscript) onRerectify;

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
                      style: SrType.caption.copyWith(color: pal.textSecondary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.rectifiedText.replaceAll('\n', ' '),
                      key: Key('settings-history-rectified:${entry.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SrType.caption.copyWith(color: pal.textTertiary),
                    ),
                  ],
                ),
              ),
              // 悬停显复制/重修 — the quick panel's fade recipe.
              IgnorePointer(
                ignoring: !hover,
                child: AnimatedOpacity(
                  duration: SrMotion.fade,
                  curve: SrMotion.curveFade,
                  opacity: hover ? 1 : 0,
                  child: Row(
                    children: [
                      _EntryAction(
                        key: Key('settings-history-copy:${entry.id}'),
                        icon: Icons.copy_rounded,
                        tooltip: '复制原始转写',
                        onTap: () => Clipboard.setData(
                          ClipboardData(text: entry.rawTranscript),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _EntryAction(
                        key: Key('settings-history-rerectify:${entry.id}'),
                        icon: Icons.refresh_rounded,
                        tooltip: '重新修正',
                        onTap: () => onRerectify(entry.rawTranscript),
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
      builder: (hover) => Tooltip(
        message: tooltip,
        waitDuration: SrMotion.tooltipWait,
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
                style: SrType.caption.copyWith(color: pal.textSecondary),
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
