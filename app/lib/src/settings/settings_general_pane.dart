/// The 通用 domain: the shell's own knobs. The theme tri-state is a
/// mirror of the quick panel's switcher (same segments, same single
/// `setThemeMode` entry on the main controller — this pane's edit rides
/// the channel back, the write and the banner live on the main side);
/// the orb's visibility is the tray checkbox's sibling, persisted to
/// ui.toml the same way. The hotkey rows join here with their own
/// ticket (16).

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrCard;
import '../design/hover.dart';
import '../design/tokens.dart';

class SettingsGeneralPane extends StatelessWidget {
  const SettingsGeneralPane({
    super.key,
    required this.themeMode,
    required this.orbVisible,
    required this.onThemePicked,
    required this.onOrbVisible,
  });

  final ThemeMode themeMode;

  /// The orb's visibility as the main controller holds it (the launch
  /// arguments seed it; tray toggles push fresh values over the channel).
  final bool orbVisible;

  /// Apply a theme pick — the main controller's single entry (the pane
  /// paints the pick at once; the controller's reaction is the truth).
  final ValueChanged<ThemeMode> onThemePicked;

  /// Apply an orb-visibility flip — the main controller's single entry.
  final ValueChanged<bool> onOrbVisible;

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
      ],
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
