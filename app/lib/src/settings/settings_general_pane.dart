/// The 通用 domain: the shell's own knobs. The theme tri-state is a
/// mirror of the quick panel's switcher (same segments, same single
/// `setThemeMode` entry on the main controller — this pane's edit rides
/// the channel back, the write and the banner live on the main side);
/// the orb's visibility is the tray checkbox's sibling, persisted to
/// ui.toml the same way. The two product-hotkey rows live here too:
/// click to capture, first legal chord writes the file at once (map 06).
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../hotkey_binding.dart';
import '../design/controls.dart' show SrCard;
import '../design/hover.dart';
import '../design/tokens.dart';

class SettingsGeneralPane extends StatelessWidget {
  const SettingsGeneralPane({
    super.key,
    required this.themeMode,
    required this.orbVisible,
    required this.primary,
    required this.pin,
    required this.onThemePicked,
    required this.onOrbVisible,
    required this.onCapture,
    required this.onCommit,
    this.error,
  });

  final ThemeMode themeMode;

  /// The orb's visibility as the main controller holds it (the launch
  /// arguments seed it; tray toggles push fresh values over the channel).
  final bool orbVisible;

  final HotkeyBinding primary;
  final HotkeyBinding pin;

  /// Apply a theme pick — the main controller's single entry (the pane
  /// paints the pick at once; the controller's reaction is the truth).
  final ValueChanged<ThemeMode> onThemePicked;

  /// Apply an orb-visibility flip — the main controller's single entry.
  final ValueChanged<bool> onOrbVisible;

  /// Capture started or ended — the main engine unregisters both product
  /// chords for the duration so this window can hear the press.
  final ValueChanged<bool> onCapture;

  /// A row finished a record / clear / restore: the parent writes the
  /// file and notifies the main engine. Collision and capture-not-done
  /// never reach here. Awaited so capture stays paused until the file
  /// is the new truth (a failed write still ends capture).
  final Future<void> Function(HotkeySlot slot, HotkeyBinding binding) onCommit;

  /// A failed write, painted under the hotkey card (the write lives in
  /// this window, so the error does too).
  final String? error;

  static const _themeOptions = [
    (ThemeMode.light, '浅色', Icons.light_mode_outlined, 'settings-theme-light'),
    (ThemeMode.dark, '深色', Icons.dark_mode_outlined, 'settings-theme-dark'),
    (ThemeMode.system, '跟随系统', Icons.monitor_rounded, 'settings-theme-system'),
  ];

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('通用', style: SrType.title.copyWith(color: pal.textPrimary)),
        const SizedBox(height: 16),
        SrCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '主题',
                style: SrType.body.copyWith(
                  color: pal.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '两个窗口与快捷面板同步生效',
                style: SrType.micro.copyWith(color: pal.textTertiary),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final (mode, label, icon, key) in _themeOptions)
                    Expanded(
                      child: Padding(
                        // The row of three shares the width; the last
                        // segment keeps no trailing gap.
                        padding: const EdgeInsets.only(right: 6),
                        child: _ThemeSeg(
                          key: Key(key),
                          icon: icon,
                          label: label,
                          selected: themeMode == mode,
                          onTap: () => onThemePicked(mode),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SrCard(
          child: Row(
            children: [
              Icon(
                Icons.blur_circular_rounded,
                size: 16,
                color: pal.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '显示悬浮球',
                      style: SrType.body.copyWith(color: pal.textPrimary),
                    ),
                    Text(
                      '隐藏后点击托盘图标或勾选托盘菜单即可唤回',
                      style: SrType.micro.copyWith(color: pal.textTertiary),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const Key('settings-orb-visible'),
                value: orbVisible,
                onChanged: onOrbVisible,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _HotkeyCard(
          primary: primary,
          pin: pin,
          error: error,
          onCapture: onCapture,
          onCommit: onCommit,
        ),
      ],
    );
  }
}

/// The two product-hotkey rows plus the occupancy notice. Capture
/// state lives here: a domain switch or a window close disposes the
/// card and hands the chords back.
class _HotkeyCard extends StatefulWidget {
  const _HotkeyCard({
    required this.primary,
    required this.pin,
    required this.onCapture,
    required this.onCommit,
    this.error,
  });

  final HotkeyBinding primary;
  final HotkeyBinding pin;
  final String? error;
  final ValueChanged<bool> onCapture;
  final Future<void> Function(HotkeySlot slot, HotkeyBinding binding) onCommit;

  @override
  State<_HotkeyCard> createState() => _HotkeyCardState();
}

class _HotkeyCardState extends State<_HotkeyCard> {
  HotkeySlot? _capturing;

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    if (_capturing != null) widget.onCapture(false);
    super.dispose();
  }

  void _begin(HotkeySlot slot) {
    if (_capturing == slot) {
      _endCapture();
      return;
    }
    if (_capturing == null) {
      HardwareKeyboard.instance.addHandler(_handleKey);
      widget.onCapture(true);
    }
    setState(() => _capturing = slot);
  }

  void _endCapture() {
    if (_capturing == null) return;
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _capturing = null;
    widget.onCapture(false);
    setState(() {});
  }

  bool _handleKey(KeyEvent event) {
    final slot = _capturing;
    if (slot == null || event is! KeyDownEvent) return false;
    final binding = HotkeyBinding.fromPress(
      key: event.physicalKey,
      pressed: HardwareKeyboard.instance.physicalKeysPressed,
    );
    if (binding == null) return true; // keep waiting
    final other = slot == HotkeySlot.primary ? widget.pin : widget.primary;
    if (binding.conflictsWith(other)) return true; // keep waiting
    unawaited(_finish(slot, binding));
    return true;
  }

  Future<void> _finish(HotkeySlot slot, HotkeyBinding binding) async {
    await widget.onCommit(slot, binding);
    if (mounted && _capturing == slot) _endCapture();
  }

  void _clear(HotkeySlot slot) {
    if (_capturing != null) _endCapture();
    unawaited(widget.onCommit(slot, const HotkeyBinding.none()));
  }

  void _restore(HotkeySlot slot) {
    final next = HotkeyBinding.defaultFor(slot);
    final other = slot == HotkeySlot.primary ? widget.pin : widget.primary;
    if (next.conflictsWith(other)) return;
    if (_capturing != null) _endCapture();
    unawaited(widget.onCommit(slot, next));
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '热键',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '点行录制,合法和弦即改;清空后主流程只靠球、钉入在聆听中不可用',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 12),
          _HotkeyRow(
            slot: HotkeySlot.primary,
            title: '主流程',
            caption: '开始录入 / 结束录入 / 确认粘贴',
            binding: widget.primary,
            capturing: _capturing == HotkeySlot.primary,
            onTap: () => _begin(HotkeySlot.primary),
            onClear: () => _clear(HotkeySlot.primary),
            onRestore: () => _restore(HotkeySlot.primary),
          ),
          const SizedBox(height: 8),
          _HotkeyRow(
            slot: HotkeySlot.pin,
            title: '钉入',
            caption: '仅聆听中有效,空闲还给系统',
            binding: widget.pin,
            capturing: _capturing == HotkeySlot.pin,
            onTap: () => _begin(HotkeySlot.pin),
            onClear: () => _clear(HotkeySlot.pin),
            onRestore: () => _restore(HotkeySlot.pin),
          ),
          const SizedBox(height: 10),
          Text(
            key: const Key('settings-hotkey-hint'),
            '若按下无反应,该组合可能已被其他程序占用',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          if (widget.error != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.error!,
              key: const Key('settings-hotkey-error'),
              style: SrType.caption.copyWith(color: pal.live),
            ),
          ],
        ],
      ),
    );
  }
}

class _HotkeyRow extends StatelessWidget {
  const _HotkeyRow({
    required this.slot,
    required this.title,
    required this.caption,
    required this.binding,
    required this.capturing,
    required this.onTap,
    required this.onClear,
    required this.onRestore,
  });

  final HotkeySlot slot;
  final String title;
  final String caption;
  final HotkeyBinding binding;
  final bool capturing;
  final VoidCallback onTap;
  final VoidCallback onClear;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final keyName = slot == HotkeySlot.primary ? 'primary' : 'pin';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: SrType.body.copyWith(color: pal.textPrimary)),
        Text(caption, style: SrType.micro.copyWith(color: pal.textTertiary)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SrHover(
                builder: (hover) => GestureDetector(
                  key: Key('settings-hotkey-$keyName'),
                  onTap: onTap,
                  child: AnimatedContainer(
                    duration: SrMotion.fast,
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: capturing
                          ? pal.accentSoft
                          : (hover ? pal.surfaceOverlay : pal.surfaceRaised),
                      borderRadius: BorderRadius.circular(SrRadius.control),
                      border: Border.all(
                        color: capturing
                            ? pal.accent.withValues(alpha: 0.55)
                            : pal.hairline,
                      ),
                    ),
                    child: Text(
                      capturing ? '按下组合键…' : binding.label,
                      style: (capturing ? SrType.caption : SrType.kbd).copyWith(
                        color: capturing ? pal.accentText : pal.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (!capturing) ...[
              const SizedBox(width: 8),
              _RowAction(
                key: Key('settings-hotkey-$keyName-clear'),
                label: '清空',
                onTap: onClear,
              ),
              const SizedBox(width: 4),
              _RowAction(
                key: Key('settings-hotkey-$keyName-restore'),
                label: '恢复默认',
                onTap: onRestore,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Text(
            label,
            style: SrType.micro.copyWith(
              color: hover ? pal.textPrimary : pal.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

/// One theme tri-state segment, the quick panel's switcher's shape:
/// fixed height, icon + label, centered — the row of three shares the
/// width.
class _ThemeSeg extends StatelessWidget {
  const _ThemeSeg({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SrMotion.fast,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? pal.accentSoft
                : (hover ? pal.surfaceOverlay : pal.surfaceRaised),
            borderRadius: BorderRadius.circular(SrRadius.control),
            border: Border.all(
              color: selected
                  ? pal.accent.withValues(alpha: 0.55)
                  : pal.hairline,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? pal.accentText : pal.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: SrType.caption.copyWith(
                  color: selected ? pal.accentText : pal.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
