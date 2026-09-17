/// The quick panel: same footprint, same position, mutually exclusive
/// with the session window (同形同位互斥). High-frequency settings and
/// actions only — full configuration lives in the settings window
/// (ticket 17), whose entry rows (编辑场景 / 全部历史与管理 / 打开设置)
/// open it on the matching domain. The orb doubles as the close button;
/// Esc closes (the stage owns the keyboard while no field has it).
///
/// Sections (spec §4.3): scenario quick-pick chips (the third picker —
/// chip, tray and here all share [SpeechController.selectScenario]),
/// quick terms (append/remove against the dictionary file, live for the
/// next session), recent history (copy the rectified text shown on the
/// row / re-rectify it under a picked scenario), passage mode
/// (engine-seamed, applies from the next session on),
/// and the theme tri-state (writes the app-owned ui.toml — the
/// read/write loop). The orb-visibility switch lives in the tray only.
///
/// The body's anchor edge dissolves into the card surface toward the
/// orb (✕): a surface scrim fades scrolling content out before it can
/// crowd the anchor zone — at the bottom (96) while the orb grows the
/// panel up, at the top (48, flush under the header) while it grows
/// down — and the orb itself paints above it (stage stack), staying
/// crisp.

library;

// GrowthDirection hidden: the framework exports its own (a sliver
// token); this panel's is the orb-geometry one via window_stage.
import 'package:flutter/material.dart' hide GrowthDirection;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../app_state.dart';
import '../design/hover.dart';
import '../design/toast.dart';
import '../design/tokens.dart';
import '../rust/api.dart' show BridgeHistoryEntry, BridgeScenario;
import '../settings/settings_domain.dart';
import 'history_retrieval.dart'
    show HistoryRerectify, showScenarioRerectifyMenu;
import 'panel_gestures.dart';
import 'window_stage.dart';

class QuickPanel extends StatefulWidget {
  const QuickPanel({
    super.key,
    required this.controller,
    required this.exiting,
    this.onOpenSettings,
    required this.dir,
    this.grip,
  });

  final SpeechController controller;
  final bool exiting;

  /// The settings window's doorway: every management entry row calls it
  /// with the domain to land on. Null in tests that only exercise the
  /// panel's own behavior.
  final void Function(SettingsDomain domain)? onOpenSettings;

  /// Which corner the orb (✕) anchors: obligations follow the anchor's
  /// edge only (义务随锚点角走, spec §3) — the header keeps its orb-side
  /// reserve (56), and the scroll fade + clearance sit on the anchor's
  /// edge (bottom 96 while growing up, top 48 while growing down).
  final GrowthDirection dir;

  /// The header-row move grip (面板上沿拖动=整体移动); null in tests.
  final PanelGrip? grip;

  @override
  State<QuickPanel> createState() => _QuickPanelState();
}

class _QuickPanelState extends State<QuickPanel> {
  final _termInput = TextEditingController();
  int _toastedErrorSeq = 0;

  SpeechController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    // A pending error from before this panel opened (the orb's tooltip
    // carried it at idle) still toasts once the slot scope is mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _toastPendingError();
    });
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    _termInput.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    _toastPendingError();
    setState(() {});
  }

  /// A new [SpeechController.lastError] while this panel is up rides
  /// the stage-slot toast (the inline error card is retired).
  void _toastPendingError() {
    final seq = c.lastErrorSeq;
    final message = c.lastError;
    if (seq == _toastedErrorSeq || message == null) return;
    _toastedErrorSeq = seq;
    SrToast.of(context).show(message, tone: SrToastTone.error);
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    // The header row doubles as the move grip (面板上沿拖动): wrapped
    // when a grip is wired (production), bare in tests.
    final Widget header = Padding(
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
          // 左上 (downRight): the orb (✕) owns this row's start — the
          // title cluster (标题 + Esc 提示) yields as one unit (让位按簇).
          if (!widget.dir.growUp && !widget.dir.growLeft)
            const SizedBox(width: SrGeometry.anchorHeaderReserve),
          Text('快捷设置', style: SrType.title.copyWith(color: pal.textPrimary)),
          const SizedBox(width: SrSpace.sm),
          Text('Esc 关闭', style: SrType.micro.copyWith(color: pal.textTertiary)),
          // 右上 (downLeft): the orb owns this row's end — the header
          // reserve (56), one contract with the session window's header
          // (the footer keeps 48; the header band is the ring-bearing
          // row; spec §3 义务层).
          if (!widget.dir.growUp && widget.dir.growLeft)
            const SizedBox(width: SrGeometry.anchorHeaderReserve),
        ],
      ),
    );
    final grip = widget.grip;
    return PanelBody(
      exiting: widget.exiting,
      dir: widget.dir,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          grip == null ? header : PanelGripBar(grip: grip, child: header),
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
                      // leading/trailing anchor paddings pair with the
                      // fades below — at rest (or end-of-scroll) the first
                      // (last) row rests exactly at its fade's far edge,
                      // never inside the fade.
                      padding: EdgeInsets.fromLTRB(
                        SrSpace.contentInset,
                        widget.dir.growUp ? 12 : SrGeometry.anchorInset,
                        SrSpace.contentInset,
                        0,
                      ),
                      children: [
                        // The scenario section stays with an empty library:
                        // the picker row hides (a lone 默认 chip has nothing
                        // to pick between) but the editor entry remains the
                        // creation path into the settings window.
                        _sectionLabel(pal, '场景'),
                        // The global directive's preview row (ticket 22):
                        // shown only while one is set — with an empty
                        // library too, it is not a picker among scenarios.
                        if (c.globalDirective != null) ...[
                          _GlobalPreviewRow(
                            directive: c.globalDirective!,
                            onOpen: _openSettings,
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (c.scenarios.isNotEmpty) ...[
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
                          const SizedBox(height: 8),
                        ],
                        _EntryRow(
                          key: const Key('quick-open-settings:scenarios'),
                          label: '编辑场景…',
                          domain: SettingsDomain.scenarios,
                          onOpen: _openSettings,
                        ),
                        const SizedBox(height: 20),
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
                              scenarios: c.scenarios,
                              onRerectify: c.rerectifyHistory,
                            ),
                        const SizedBox(height: 8),
                        _EntryRow(
                          key: const Key('quick-open-settings:history'),
                          label: '全部历史与管理…',
                          domain: SettingsDomain.history,
                          onOpen: _openSettings,
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
                        const SizedBox(height: 20),
                        _sectionLabel(pal, '设置入口'),
                        _EntryRow(
                          key: const Key('quick-open-settings:general'),
                          label: '打开设置',
                          domain: SettingsDomain.general,
                          onOpen: _openSettings,
                        ),
                        // Anchor zone clearance — only while the anchor
                        // sits at the bottom edge (up-growth): the orb's
                        // whole footprint rides this band. A top-anchored
                        // orb's obligations live at the list's head (fade
                        // + padding above), so the tail carries none.
                        if (widget.dir.growUp)
                          const SizedBox(height: SrGeometry.anchorInset * 2),
                      ],
                    ),
                  ),
                  // The anchor-zone fades: surface-colored, fully opaque
                  // at the card's anchor edge and transparent by the
                  // matching clearance's far edge (bottom 96, top 48).
                  // Content scrolling toward the ✕ dissolves into the
                  // card instead of crowding the button; over the empty
                  // surface beside short content it paints
                  // surface-on-surface and is invisible. The orb sits
                  // above (stage stack), so the ✕ stays crisp. Each edge
                  // carries its fade only while the anchor sits on it.
                  if (widget.dir.growUp)
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
                  if (!widget.dir.growUp)
                    Positioned(
                      key: const Key('quick-top-fade'),
                      left: 0,
                      right: 0,
                      top: 0,
                      height: SrGeometry.anchorInset,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
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

  void _openSettings(SettingsDomain domain) {
    widget.onOpenSettings?.call(domain);
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

/// An icon whose color eases between its resting and hover tones over
/// the shared micro-feedback window, so no color snaps beside the box
/// fades happening around it.
class _HoverTintIcon extends StatelessWidget {
  const _HoverTintIcon({
    super.key,
    required this.icon,
    required this.size,
    required this.hover,
    required this.resting,
    required this.hovered,
  });

  final IconData icon;
  final double size;
  final bool hover;
  final Color resting;
  final Color hovered;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: resting, end: hover ? hovered : resting),
      duration: SrMotion.fast,
      curve: SrMotion.curveMicro,
      builder: (context, color, _) => Icon(icon, size: size, color: color),
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

/// The global directive's preview row (ticket 22): what is currently in
/// force, one truncated line (the tooltip names it, the full text does
/// not fit), with the settings jump on its right — the same mechanism
/// the 编辑场景… entry uses, landing on the scenario domain where the
/// directive's inline card lives. Hidden entirely while unset.
class _GlobalPreviewRow extends StatelessWidget {
  const _GlobalPreviewRow({required this.directive, required this.onOpen});

  final String directive;
  final ValueChanged<SettingsDomain> onOpen;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => AnimatedContainer(
        duration: SrMotion.fade,
        curve: SrMotion.curveFade,
        height: _termRowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: pal.surfaceRaised.withValues(alpha: hover ? 1 : 0),
          borderRadius: BorderRadius.circular(SrRadius.control),
          border: Border.all(color: pal.hairline),
        ),
        child: Row(
          children: [
            Icon(Icons.public_rounded, size: 14, color: pal.textTertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: '全局指令',
                waitDuration: SrMotion.tooltipWait,
                child: Text(
                  directive,
                  key: const Key('quick-global-preview'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SrType.caption.copyWith(color: pal.textSecondary),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              key: const Key('quick-global-open'),
              onTap: () => onOpen(SettingsDomain.scenarios),
              child: Tooltip(
                message: '编辑全局指令',
                waitDuration: SrMotion.tooltipWait,
                child: _HoverTintIcon(
                  icon: Icons.settings_outlined,
                  size: 15,
                  hover: hover,
                  resting: pal.textTertiary,
                  hovered: pal.accentText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A full-width management entry (编辑场景… / 全部历史与管理… /
/// 打开设置): a ghost row, outlined at rest like the term add button,
/// filling with raised on hover over the surface-fade window. Each row
/// opens the settings window on its domain.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.label,
    required this.domain,
    required this.onOpen,
  });

  final String label;
  final SettingsDomain domain;
  final ValueChanged<SettingsDomain> onOpen;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => GestureDetector(
        onTap: () => onOpen(domain),
        child: AnimatedContainer(
          duration: SrMotion.fade,
          curve: SrMotion.curveFade,
          height: _termRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: pal.surfaceRaised.withValues(alpha: hover ? 1 : 0),
            borderRadius: BorderRadius.circular(SrRadius.control),
            border: Border.all(color: pal.hairline),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: SrType.caption.copyWith(color: pal.textSecondary),
              ),
              const Spacer(),
              _HoverTintIcon(
                icon: Icons.chevron_right_rounded,
                size: 16,
                hover: hover,
                resting: pal.textTertiary,
                hovered: pal.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
    return SrHover(
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
    return SrHover(
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

/// The term row's shared height: the container-drawn field box and the
/// add button paint one aligned 34px row through the same BoxDecoration
/// painter.
const _termRowHeight = 34.0;

/// The term input's box is drawn by its container, not by the
/// InputDecorator: OutlineInputBorder sizes its PAINTED box to the
/// content metrics under real font metrics (pixel-scanned ≈25 logical
/// px inside a 34 logical slot on the machine — layout box and painted
/// box are different things), so every height constraint we pinned
/// never reached the painted border. The container approach shares
/// one painter (and thus one rasterization) with the add button and
/// the chips; the TextField inside stays chrome-less.
class _TermField extends StatefulWidget {
  const _TermField({required this.controller, required this.onAdd});

  final TextEditingController controller;
  final ValueChanged<String> onAdd;

  @override
  State<_TermField> createState() => _TermFieldState();
}

class _TermFieldState extends State<_TermField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return GestureDetector(
      // The chrome-less field only covers its text line; a tap
      // anywhere in the 34px box focuses it.
      onTap: _focus.requestFocus,
      behavior: HitTestBehavior.translucent,
      child: AnimatedContainer(
        duration: SrMotion.fast,
        curve: SrMotion.curveMicro,
        height: _termRowHeight,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: pal.surfaceOverlay,
          borderRadius: BorderRadius.circular(SrRadius.control),
          border: Border.all(
            color: _focus.hasFocus
                ? pal.accent.withValues(alpha: 0.6)
                : pal.hairline,
          ),
        ),
        child: SizedBox(
          width: double.infinity,
          child: TextField(
            key: const Key('quick-term-field'),
            controller: widget.controller,
            focusNode: _focus,
            style: SrType.caption.copyWith(color: pal.textPrimary),
            cursorColor: pal.accent,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
              enabledBorder: InputBorder.none,
              filled: false,
              hintText: '添加术语,回车确认',
              hintStyle: SrType.caption.copyWith(color: pal.textTertiary),
            ),
            // Enter commits the term (an IME composition commits
            // instead, the field's default semantics); the add button
            // walks the same callback.
            onSubmitted: widget.onAdd,
          ),
        ),
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
    return SrHover(
      builder: (hover) => GestureDetector(
        onTap: onTap,
        // Rest = outlined, the input's own visual family: a solid
        // accent-tinted block next the low-contrast input reads taller
        // than it is (round-3 feedback) — equal geometry, unequal
        // optical weight. Hover brings the solid accent, cross-faded by
        // the accent's own alpha (no transparent-lerp dark dip).
        child: AnimatedContainer(
          duration: SrMotion.fade,
          curve: SrMotion.curveFade,
          width: _termRowHeight,
          height: _termRowHeight,
          decoration: BoxDecoration(
            color: pal.accent.withValues(alpha: hover ? 1 : 0),
            borderRadius: BorderRadius.circular(SrRadius.control),
            border: Border.all(color: hover ? pal.accent : pal.hairline),
          ),
          child: _HoverTintIcon(
            key: const Key('quick-term-add'),
            icon: Icons.add_rounded,
            size: 18,
            hover: hover,
            resting: pal.accentText,
            hovered: pal.onAccent,
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
    return SrHover(
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
              child: _HoverTintIcon(
                icon: Icons.close,
                size: 12,
                hover: hover,
                resting: pal.textTertiary,
                hovered: pal.live,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.scenarios,
    required this.onRerectify,
  });

  final BridgeHistoryEntry entry;

  /// The scenario library, for the row's 指定场景重新修正 key — the same
  /// menu the settings window's history rows open (ticket 23; ticket 28
  /// adds the built-in 默认 item, so the key doubles as plain
  /// re-rectify and stays usable over an empty library).
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
      // The inter-row gap sits OUTSIDE the hover region: hover switches
      // exactly at the painted edge, not 6px past it.
      padding: const EdgeInsets.only(bottom: 6),
      child: SrHover(
        builder: (hover) => AnimatedContainer(
          duration: SrMotion.fade,
          curve: SrMotion.curveFade,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          // One hover treatment: the raised fill's OWN alpha eases in
          // and out (a clean cross-dissolve over the card). Lerping
          // toward Colors.transparent instead would pass through
          // black-tinted midpoints — Color.lerp drags RGB down along
          // with alpha — a dark flash mid-transition that reads as two
          // rectangles fighting. The surface-fade curve (not the micro
          // one) makes both directions read as a gradient.
          decoration: BoxDecoration(
            color: pal.surfaceRaised.withValues(alpha: hover ? 1 : 0),
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
                      // The rectified text is what this row is for
                      // (ticket 23): what you see is what 复制 lands.
                      entry.rectifiedText.replaceAll('\n', ' '),
                      key: Key('quick-history-rectified:${entry.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SrType.caption.copyWith(color: pal.textSecondary),
                    ),
                  ],
                ),
              ),
              // 悬停显复制/重修 (spec §4.3): the actions ride every row but
              // fade in/out under the pointer — no layout pop, and the
              // text keeps a constant ellipsis width. Pointer events stay
              // off while faded. Two keys (ticket 23): copy the rectified
              // text shown above, and 指定场景重新修正 — the same menu the
              // settings window's history rows open; the raw transcript
              // stays a settings-window view.
              IgnorePointer(
                ignoring: !hover,
                child: AnimatedOpacity(
                  key: Key('quick-history-actions:${entry.id}'),
                  duration: SrMotion.fade,
                  curve: SrMotion.curveFade,
                  opacity: hover ? 1 : 0,
                  child: Row(
                    children: [
                      _HistoryAction(
                        key: Key('quick-history-copy:${entry.id}'),
                        icon: Icons.copy_rounded,
                        tooltip: '复制修正文本',
                        onTap: () => Clipboard.setData(
                          ClipboardData(text: entry.rectifiedText),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _HistoryScenarioAction(
                        key: Key(
                          'quick-history-rerectify-scenario:${entry.id}',
                        ),
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
    return SrHover(
      builder: (hover) => Tooltip(
        message: tooltip,
        waitDuration: SrMotion.tooltipWait,
        child: GestureDetector(
          onTap: onTap,
          child: _HoverTintIcon(
            icon: icon,
            size: 15,
            hover: hover,
            resting: pal.textTertiary,
            hovered: pal.accentText,
          ),
        ),
      ),
    );
  }
}

/// The row's second key: 指定场景重新修正, opening the same shared
/// scenario menu the settings window's history rows use (ticket 23) —
/// 默认 plus the library, 默认 alone over an empty library (ticket 28).
/// Same shell as [_HistoryAction].
class _HistoryScenarioAction extends StatelessWidget {
  const _HistoryScenarioAction({
    super.key,
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
      itemKeyPrefix: 'quick-history-scenario-item',
    );
    if (pick == null) return;
    await onRerectify(entry.rawTranscript, style: pick);
  }

  @override
  Widget build(BuildContext context) {
    return SrHover(
      builder: (hover) => Tooltip(
        message: '指定场景重新修正',
        waitDuration: SrMotion.tooltipWait,
        child: GestureDetector(
          onTap: () => _open(context),
          child: _HoverTintIcon(
            icon: Icons.style_rounded,
            size: 15,
            hover: hover,
            resting: srPalette(context).textTertiary,
            hovered: srPalette(context).accentText,
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
