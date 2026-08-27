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

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../app_state.dart';
import '../design/tokens.dart';
import '../rust/api.dart' show BridgeHistoryEntry;
import 'window_stage.dart';

class QuickPanel extends StatefulWidget {
  const QuickPanel({super.key, required this.controller, required this.exiting});

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
            child: ListView(
              // Straight-edge body content: contentInset. The trailing
              // anchor clearance (96) already exceeds the corner band's
              // depth (40), so the last row owes no extra corner duty.
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
                      child: _TermField(pal: pal, controller: _termInput),
                    ),
                    const SizedBox(width: 8),
                    _AddButton(
                      pal: pal,
                      onTap: () => _addTerm(),
                    ),
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
                          pal: pal,
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
                      style: SrType.micro.copyWith(color: pal.textTertiary),
                    ),
                  )
                else
                  for (final entry in c.recentHistory)
                    _HistoryRow(pal: pal, entry: entry),
                const SizedBox(height: 20),
                _sectionLabel(pal, '输入'),
                _SwitchRow(
                  pal: pal,
                  icon: Icons.notes_rounded,
                  label: '篇章模式',
                  caption: '停顿仅分段,不结束会话',
                  value: c.passageMode,
                  onChanged: c.setPassageMode,
                ),
                const SizedBox(height: 20),
                _sectionLabel(pal, '外观'),
                _ThemeRow(controller: c, pal: pal),
                // Anchor zone clearance.
                const SizedBox(height: SrGeometry.anchorInset * 2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Add the field's text as a term and keep the field ready for the
  /// next one (rapid entry stays in the field).
  void _addTerm() {
    final text = _termInput.text;
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

class _SelectableChip extends StatefulWidget {
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
  State<_SelectableChip> createState() => _SelectableChipState();
}

class _SelectableChipState extends State<_SelectableChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: SrMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: widget.selected
                ? pal.accentSoft
                : (_hover ? pal.surfaceOverlay : pal.surfaceRaised),
            // Chips keep the plain control radius — the capsule is a
            // corner-band privilege (spec §3).
            borderRadius: BorderRadius.circular(SrRadius.control),
            border: Border.all(
              color: widget.selected
                  ? pal.accent.withValues(alpha: 0.55)
                  : pal.hairline,
            ),
          ),
          child: Text(
            widget.label,
            style: SrType.caption.copyWith(
              color: widget.selected ? pal.accentText : pal.textSecondary,
              fontWeight: widget.selected
                  ? FontWeight.w600
                  : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _TermField extends StatelessWidget {
  const _TermField({required this.pal, required this.controller});

  final SrPalette pal;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: TextField(
        key: const Key('quick-term-field'),
        controller: controller,
        style: SrType.caption.copyWith(color: pal.textPrimary),
        cursorColor: pal.accent,
        decoration: InputDecoration(
          isDense: true,
          hintText: '添加术语,回车确认',
          hintStyle: SrType.caption.copyWith(color: pal.textTertiary),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
        // Enter commits the term (IME composition commits instead, the
        // field's default); the add button shares _addTerm through the
        // owning state.
        onSubmitted: (_) => _submit(context),
      ),
    );
  }

  void _submit(BuildContext context) {
    // Same path as the add button: keep the widget tree's one writer.
    final state = context.findAncestorStateOfType<_QuickPanelState>();
    state?._addTerm();
  }
}

class _AddButton extends StatefulWidget {
  const _AddButton({required this.pal, required this.onTap});

  final SrPalette pal;
  final VoidCallback onTap;

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final pal = widget.pal;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: SrMotion.fast,
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: _hover ? pal.accent : pal.accentSoft,
            borderRadius: BorderRadius.circular(SrRadius.control),
          ),
          child: Icon(
            key: const Key('quick-term-add'),
            Icons.add_rounded,
            size: 18,
            color: _hover ? pal.onAccent : pal.accentText,
          ),
        ),
      ),
    );
  }
}

class _TermChip extends StatefulWidget {
  const _TermChip({
    required this.pal,
    required this.label,
    required this.onRemoved,
  });

  final SrPalette pal;
  final String label;
  final VoidCallback onRemoved;

  @override
  State<_TermChip> createState() => _TermChipState();
}

class _TermChipState extends State<_TermChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final pal = widget.pal;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
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
              widget.label,
              style: SrType.caption.copyWith(color: pal.textSecondary),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              key: Key('quick-term-remove:${widget.label}'),
              onTap: widget.onRemoved,
              child: Icon(
                Icons.close,
                size: 12,
                color: _hover ? pal.live : pal.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({required this.pal, required this.entry});

  final SrPalette pal;
  final BridgeHistoryEntry entry;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  bool _hover = false;

  SpeechController get _controller => context.findAncestorStateOfType<_QuickPanelState>()!.widget.controller;

  @override
  Widget build(BuildContext context) {
    final pal = widget.pal;
    final entry = widget.entry;
    final stamp = formatHistoryStamp(
      at: DateTime.fromMillisecondsSinceEpoch(entry.createdAtMs.toInt()),
      now: DateTime.now(),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: SrMotion.fast,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _hover ? pal.surfaceRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(SrRadius.control),
          border: Border.all(color: _hover ? pal.hairline : Colors.transparent),
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
            // 悬停显复制/重修 (spec §4.3): the actions exist only under
            // the pointer, so the resting rows stay quiet.
            if (_hover) ...[
              _HistoryAction(
                key: Key('quick-history-copy:${entry.id}'),
                pal: pal,
                icon: Icons.copy_rounded,
                tooltip: '复制原文',
                onTap: () => Clipboard.setData(
                  ClipboardData(text: entry.rawTranscript),
                ),
              ),
              const SizedBox(width: 10),
              _HistoryAction(
                key: Key('quick-history-rerectify:${entry.id}'),
                pal: pal,
                icon: Icons.refresh_rounded,
                tooltip: '重新修正',
                onTap: () => _controller.rerectifyHistory(entry.rawTranscript),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HistoryAction extends StatefulWidget {
  const _HistoryAction({
    super.key,
    required this.pal,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final SrPalette pal;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_HistoryAction> createState() => _HistoryActionState();
}

class _HistoryActionState extends State<_HistoryAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final pal = widget.pal;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: SrMotion.tooltipWait,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Icon(
            widget.icon,
            size: 15,
            color: _hover ? pal.accentText : pal.textTertiary,
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.pal,
    required this.icon,
    required this.label,
    required this.caption,
    required this.value,
    required this.onChanged,
  });

  final SrPalette pal;
  final IconData icon;
  final String label;
  final String caption;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
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
        Switch(key: const Key('quick-passage'), value: value, onChanged: onChanged),
      ],
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({required this.controller, required this.pal});

  final SpeechController controller;
  final SrPalette pal;

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
                pal: pal,
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

class _ThemeSeg extends StatefulWidget {
  const _ThemeSeg({
    super.key,
    required this.pal,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final SrPalette pal;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ThemeSeg> createState() => _ThemeSegState();
}

class _ThemeSegState extends State<_ThemeSeg> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final pal = widget.pal;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: SrMotion.fast,
          height: 34,
          decoration: BoxDecoration(
            color: widget.selected
                ? pal.accentSoft
                : (_hover ? pal.surfaceOverlay : pal.surfaceRaised),
            borderRadius: BorderRadius.circular(SrRadius.control),
            border: Border.all(
              color: widget.selected
                  ? pal.accent.withValues(alpha: 0.55)
                  : pal.hairline,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: widget.selected ? pal.accentText : pal.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: SrType.caption.copyWith(
                  color: widget.selected ? pal.accentText : pal.textSecondary,
                  fontWeight: widget.selected
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
