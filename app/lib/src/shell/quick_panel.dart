/// The quick panel: same footprint, same position, mutually exclusive
/// with the session window (同形同位互斥). High-frequency settings and
/// actions only — full configuration lives in the settings window
/// (ticket 17; its entry button and the library-management entries stay
/// hidden until that window exists). The orb doubles as the close
/// button; Esc closes (the stage owns the keyboard while no field has
/// it).
///
/// Sections (spec §4.3): scenario quick-pick chips (the third picker —
/// chip, tray and here all share [SpeechController.selectScenario]),
/// quick terms (append/remove against the dictionary file, live for the
/// next session), recent history (copy the raw transcript / re-rectify
/// it), passage mode (engine-seamed, applies from the next session on),
/// and the theme tri-state (writes the app-owned ui.toml — the
/// read/write loop). The orb-visibility switch lives in the tray only.
///
/// The body's trailing edge dissolves into the card surface toward the
/// anchor (✕): a bottom scrim fades scrolling content out before it can
/// crowd the button zone, while the orb itself paints above it (stage
/// stack) and stays crisp.

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../app_state.dart';
import '../design/tokens.dart';
import '../rust/api.dart' show BridgeHistoryEntry;
import 'window_stage.dart';

class QuickPanel extends StatefulWidget {
  const QuickPanel({
    super.key,
    required this.controller,
    required this.exiting,
  });

  final SpeechController controller;
  final bool exiting;

  @override
  State<QuickPanel> createState() => _QuickPanelState();
}

class _QuickPanelState extends State<QuickPanel> {
  final _termInput = TextEditingController();

  SpeechController get c => widget.controller;

  @override
  void dispose() {
    _termInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return PanelBody(
      exiting: widget.exiting,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // Corner-band row: aligns to the concentric content capsule
            // (SrSpace.cornerInset). Vertical 20 puts the 16px title's
            // visual top (~24) on the capsule's D=16 arc.
            padding: const EdgeInsets.fromLTRB(
              SrSpace.cornerInset,
              20,
              SrSpace.cornerInset,
              12,
            ),
            child: Row(
              children: [
                Text(
                  '快捷设置',
                  style: SrType.title.copyWith(color: pal.textPrimary),
                ),
                const SizedBox(width: SrSpace.sm),
                Text(
                  'Esc 关闭',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: pal.hairline),
          Expanded(
            // Bottom corners clip to the card arc: scrolling content can
            // never bleed past the rounded card (the window-bleed-zero
            // principle, applied to the card's own edges).
            child: ClipRRect(
              borderRadius: BorderRadius.vertical(
                bottom: Radius.circular(SrRadius.panel),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ListView(
                      // Straight-edge body content: contentInset. The
                      // trailing anchor clearance (96) pairs with the
                      // bottom scrim's height below — at end-of-scroll the
                      // last row rests exactly at the scrim's top edge,
                      // never inside the fade.
                      padding: const EdgeInsets.fromLTRB(
                        SrSpace.contentInset,
                        12,
                        SrSpace.contentInset,
                        0,
                      ),
                      children: [
                        // An empty library hides the section entirely: a lone
                        // 默认 chip has nothing to pick between.
                        if (c.scenarios.isNotEmpty) ...[
                          _sectionLabel(pal, '场景'),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _SelectableChip(
                                key: const Key('quick-scenario-default'),
                                label: '默认',
                                selected: c.selectedScenario == null,
                                onTap: () => c.selectScenario(null),
                              ),
                              for (final scenario in c.scenarios)
                                _SelectableChip(
                                  key: Key('quick-scenario:${scenario.name}'),
                                  label: scenario.name,
                                  selected: c.selectedScenario == scenario.name,
                                  onTap: () => c.selectScenario(scenario.name),
                                ),
                            ],
                          ),
                          const SizedBox(height: 20),
                        ],
                        _sectionLabel(pal, '术语速加'),
                        Row(
                          children: [
                            Expanded(
                              child: _TermField(
                                controller: _termInput,
                                onAdd: _addTerm,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _AddButton(onTap: () => _addTerm(_termInput.text)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (c.terms.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final term in c.terms)
                                _TermChip(
                                  label: term,
                                  onRemoved: () => c.removeQuickTerm(term),
                                ),
                            ],
                          ),
                        const SizedBox(height: 20),
                        _sectionLabel(pal, '历史'),
                        if (c.recentHistory.isEmpty)
                          Padding(
                            key: const Key('quick-history-empty'),
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '暂无历史记录',
                              style: SrType.micro.copyWith(
                                color: pal.textTertiary,
                              ),
                            ),
                          )
                        else
                          for (final entry in c.recentHistory)
                            _HistoryRow(
                              entry: entry,
                              onRerectify: c.rerectifyHistory,
                            ),
                        const SizedBox(height: 20),
                        _sectionLabel(pal, '输入'),
                        _SwitchRow(
                          icon: Icons.notes_rounded,
                          label: '篇章模式',
                          caption: '停顿仅分段,不结束会话',
                          value: c.passageMode,
                          onChanged: c.setPassageMode,
                        ),
                        const SizedBox(height: 20),
                        _sectionLabel(pal, '外观'),
                        _ThemeRow(controller: c),
                        // Anchor zone clearance.
                        const SizedBox(height: SrGeometry.anchorInset * 2),
                      ],
                    ),
                  ),
                  // The anchor-zone fade: surface-colored, fully opaque
                  // at the card's bottom edge and transparent by the top
                  // of the anchor clearance (96). Content scrolling toward
                  // the ✕ dissolves into the card instead of crowding the
                  // button; over the empty surface below short content it
                  // paints surface-on-surface and is invisible. The orb
                  // sits above (stage stack), so the ✕ stays crisp.
                  Positioned(
                    key: const Key('quick-bottom-fade'),
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: SrGeometry.anchorInset * 2,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              pal.surface,
                              pal.surface,
                              pal.surface.withValues(alpha: 0),
                            ],
                            stops: const [0.0, 0.25, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Add the given text as a term and keep the field ready for the
  /// next one (rapid entry stays in the field).
  void _addTerm(String text) {
    if (text.trim().isEmpty) return;
    _termInput.clear();
    c.addQuickTerm(text);
  }

  Widget _sectionLabel(SrPalette pal, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: SrType.caption.copyWith(color: pal.textTertiary)),
  );
}

/// One history row's timestamp: today shows the clock, yesterday says
/// so, older stamps carry the date (year only when it differs).
String formatHistoryStamp({required DateTime at, required DateTime now}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(at.hour)}:${two(at.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  if (day == today) return clock;
  if (day == today.subtract(const Duration(days: 1))) return '昨天 $clock';
  if (at.year == now.year) return '${at.month}月${at.day}日 $clock';
  return '${at.year}年${at.month}月${at.day}日 $clock';
}

// ---------------------------------------------------------------------------
// Rows & controls
// ---------------------------------------------------------------------------

/// The shared hover machinery (MouseRegion + flag) every control below
/// was copying; the builder gets the flag and paints its own hover
/// states off the token palette.
class _Hover extends StatefulWidget {
  const _Hover({required this.builder});

  final Widget Function(bool hover) builder;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.builder(_hover),
    );
  }
}

/// The shared chip cascade: the scenario quick-picks and the theme
/// segments paint identically, differing only in layout density. Chips
/// keep the plain control radius: the capsule is a corner-band
/// privilege (spec §3).
BoxDecoration _chipBox(
  SrPalette pal, {
  required bool selected,
  required bool hover,
}) => BoxDecoration(
  color: selected
      ? pal.accentSoft
      : (hover ? pal.surfaceOverlay : pal.surfaceRaised),
  borderRadius: BorderRadius.circular(SrRadius.control),
  border: Border.all(
    color: selected ? pal.accent.withValues(alpha: 0.55) : pal.hairline,
  ),
);

TextStyle _chipText(SrPalette pal, {required bool selected}) =>
    SrType.caption.copyWith(
      color: selected ? pal.accentText : pal.textSecondary,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
    );

/// A scenario quick-pick chip (dense, text only).
class _SelectableChip extends StatelessWidget {
  const _SelectableChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return _Hover(
      builder: (hover) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SrMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: _chipBox(pal, selected: selected, hover: hover),
          child: Text(label, style: _chipText(pal, selected: selected)),
        ),
      ),
    );
  }
}

/// One theme tri-state segment (fixed height, icon + label, centered —
/// the row of three shares the width).
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
    return _Hover(
      builder: (hover) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SrMotion.fast,
          height: 34,
          alignment: Alignment.center,
          decoration: _chipBox(pal, selected: selected, hover: hover),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? pal.accentText : pal.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(label, style: _chipText(pal, selected: selected)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The term row's shared height: the field's decorator and the add
/// button paint one aligned 34px row. A tight SizedBox alone lets the
/// decorator center at its intrinsic height (a few px short of the
/// button), so the input constraints pin the decorator itself.
const _termRowHeight = 34.0;

class _TermField extends StatelessWidget {
  const _TermField({required this.controller, required this.onAdd});

  final TextEditingController controller;
  final ValueChanged<String> onAdd;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SizedBox(
      height: _termRowHeight,
      child: TextField(
        key: const Key('quick-term-field'),
        controller: controller,
        style: SrType.caption.copyWith(color: pal.textPrimary),
        cursorColor: pal.accent,
        decoration: InputDecoration(
          isDense: true,
          constraints: const BoxConstraints(
            minHeight: _termRowHeight,
            maxHeight: _termRowHeight,
          ),
          hintText: '添加术语,回车确认',
          hintStyle: SrType.caption.copyWith(color: pal.textTertiary),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          filled: true,
          fillColor: pal.surfaceOverlay,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(SrRadius.control),
            borderSide: BorderSide(color: pal.hairline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(SrRadius.control),
            borderSide: BorderSide(color: pal.accent.withValues(alpha: 0.6)),
          ),
        ),
        // Enter commits the term (an IME composition commits instead,
        // the field's default semantics); the add button walks the same
        // callback.
        onSubmitted: onAdd,
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return _Hover(
      builder: (hover) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SrMotion.fast,
          width: _termRowHeight,
          height: _termRowHeight,
          decoration: BoxDecoration(
            color: hover ? pal.accent : pal.accentSoft,
            borderRadius: BorderRadius.circular(SrRadius.control),
          ),
          child: Icon(
            key: const Key('quick-term-add'),
            Icons.add_rounded,
            size: 18,
            color: hover ? pal.onAccent : pal.accentText,
          ),
        ),
      ),
    );
  }
}

class _TermChip extends StatelessWidget {
  const _TermChip({required this.label, required this.onRemoved});

  final String label;
  final VoidCallback onRemoved;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return _Hover(
      builder: (hover) => AnimatedContainer(
        duration: SrMotion.fast,
        padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
        decoration: BoxDecoration(
          color: pal.surfaceRaised,
          borderRadius: BorderRadius.circular(SrRadius.control),
          border: Border.all(color: pal.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: SrType.caption.copyWith(color: pal.textSecondary),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              key: Key('quick-term-remove:$label'),
              onTap: onRemoved,
              child: Icon(
                Icons.close,
                size: 12,
                color: hover ? pal.live : pal.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.onRerectify});

  final BridgeHistoryEntry entry;
  final ValueChanged<String> onRerectify;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final stamp = formatHistoryStamp(
      at: DateTime.fromMillisecondsSinceEpoch(entry.createdAtMs.toInt()),
      now: DateTime.now(),
    );
    return _Hover(
      builder: (hover) => AnimatedContainer(
        duration: SrMotion.fast,
        curve: SrMotion.curveMicro,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        // One hover treatment: a single raised fill. A fill PLUS a
        // hairline stroke reads as two stacked rectangles fighting
        // (round-3 feedback), so the stroke stays out entirely.
        decoration: BoxDecoration(
          color: hover ? pal.surfaceRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(SrRadius.control),
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
                ],
              ),
            ),
            // 悬停显复制/重修 (spec §4.3): the actions ride every row but
            // fade in/out under the pointer — no layout pop, and the
            // transcript keeps a constant ellipsis width. Pointer events
            // stay off while faded.
            IgnorePointer(
              ignoring: !hover,
              child: AnimatedOpacity(
                key: Key('quick-history-actions:${entry.id}'),
                duration: SrMotion.fast,
                curve: SrMotion.curveMicro,
                opacity: hover ? 1 : 0,
                child: Row(
                  children: [
                    _HistoryAction(
                      key: Key('quick-history-copy:${entry.id}'),
                      icon: Icons.copy_rounded,
                      tooltip: '复制原文',
                      onTap: () => Clipboard.setData(
                        ClipboardData(text: entry.rawTranscript),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _HistoryAction(
                      key: Key('quick-history-rerectify:${entry.id}'),
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
    );
  }
}

class _HistoryAction extends StatelessWidget {
  const _HistoryAction({
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
    return _Hover(
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

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.caption,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String caption;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: pal.textSecondary),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: SrType.body.copyWith(color: pal.textPrimary)),
            Text(
              caption,
              style: SrType.micro.copyWith(color: pal.textTertiary),
            ),
          ],
        ),
        const Spacer(),
        Switch(
          key: const Key('quick-passage'),
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({required this.controller});

  final SpeechController controller;

  static const _options = [
    (ThemeMode.light, '浅色', Icons.light_mode_outlined, 'quick-theme-light'),
    (ThemeMode.dark, '深色', Icons.dark_mode_outlined, 'quick-theme-dark'),
    (ThemeMode.system, '系统', Icons.monitor_rounded, 'quick-theme-system'),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (mode, label, icon, key) in _options)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _ThemeSeg(
                key: Key(key),
                icon: icon,
                label: label,
                selected: controller.themeMode == mode,
                onTap: () => controller.setThemeMode(mode),
              ),
            ),
          ),
      ],
    );
  }
}
