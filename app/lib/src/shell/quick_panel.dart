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
/// row / re-rectify it under a picked scenario), the three rectify
/// tiers as first-level sections (全量修正模式 / 轻修模式 / 快速模式 —
/// the settings window's 修正 page's three cards, one section each,
/// pick-to-save over the same [RectifyBehaviorStore]), and the theme
/// tri-state (writes the app-owned ui.toml — the read/write loop). The
/// orb-visibility switch lives in the tray only.
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
import '../design/controls.dart' show SrHoverTintIcon, SrPressFill;
import '../design/hover.dart';
import '../design/toast.dart';
import '../design/tokens.dart';
import '../errors.dart';
import '../rust/api.dart' show BridgeHistoryEntry, BridgeScenario;
import '../settings/rectify_store.dart';
import '../settings/settings_domain.dart';
import 'history_retrieval.dart'
    show HistoryRerectify, showScenarioRerectifyMenu;
import 'window_stage.dart';

class QuickPanel extends StatefulWidget {
  const QuickPanel({
    super.key,
    required this.controller,
    required this.exiting,
    this.onOpenSettings,
    required this.form,
    required this.rectifyStore,
  });

  final SpeechController controller;
  final bool exiting;

  /// The rectify tiers' persistence — the SAME store the settings
  /// window's 修正 page edits (the theme precedent: one key, both
  /// surfaces). Injectable so widget tests run with the in-memory
  /// fake.
  final RectifyBehaviorStore rectifyStore;

  /// The settings window's doorway: every management entry row calls it
  /// with the domain to land on. Null in tests that only exercise the
  /// panel's own behavior.
  final void Function(SettingsDomain domain)? onOpenSettings;

  /// The quadrant form (12 号票): the per-axis values every chrome
  /// obligation derives from — the header reserve, the scroll fades,
  /// and the list paddings re-derive continuously as the panel switches
  /// corners, in step with the card (同步、只移不消失).
  final PanelForm form;

  @override
  State<QuickPanel> createState() => _QuickPanelState();
}

class _QuickPanelState extends State<QuickPanel> {
  final _termInput = TextEditingController();
  int _toastedErrorSeq = 0;

  /// The rectify tiers' snapshot for PAINT (ticket 02's channel (b)):
  /// loaded once when the panel mounts, refreshed by every save's
  /// receipt — the files' truth, never a locally-guessed default. Null
  /// until the load lands (or forever, on a refused read): the three
  /// sections stay hidden and the rest of the panel works.
  RectifyBehavior? _rectify;

  SpeechController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    _loadRectify();
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

  /// Read the tiers' snapshot for the panel's first paint. A refused
  /// read toasts and leaves the sections hidden — the panel's other
  /// sections are not hostage to one unreadable file.
  Future<void> _loadRectify() async {
    try {
      final behavior = await widget.rectifyStore.load();
      if (!mounted) return;
      setState(() => _rectify = behavior);
    } catch (e) {
      if (!mounted) return;
      logRawError('err_quick_rectify_load', e);
      SrToast.of(context).show('修正设置读取失败', tone: SrToastTone.error);
    }
  }

  /// A point-select (a switch flip, a chip tap): paint the pick at
  /// once, then commit it over a FRESH read — the one field changed,
  /// the whole model written (ticket 02's channel (b), read-modify-
  /// write). A settings window open beside this panel never loses an
  /// edit to a whole-model overwrite; the receipt repaints from the
  /// files' truth. A refused write leaves the pick painted (a re-tap
  /// is the retry — the 修正 pane's own contract), and the post-save
  /// engine adoption follows the pane's minus the toast: a pick never
  /// toasts (14 号票), so a refused adoption keeps the files silently —
  /// the raw reason rides the log.
  Future<void> _pickRectify(RectifyPick pick) async {
    final painted = _rectify;
    if (painted == null) return;
    setState(() => _rectify = pick(painted));
    final RectifyBehavior next;
    try {
      next = pick(await widget.rectifyStore.load());
    } catch (e) {
      if (!mounted) return;
      logRawError('err_quick_rectify_reread', e);
      SrToast.of(context).show('保存失败', tone: SrToastTone.error);
      return;
    }
    try {
      final saved = await widget.rectifyStore.save(next);
      if (!mounted) return;
      setState(() => _rectify = saved);
    } catch (e) {
      if (!mounted) return;
      logRawError('err_quick_rectify_save', e);
      SrToast.of(context).show('保存失败', tone: SrToastTone.error);
      return;
    }
    try {
      await widget.rectifyStore.applyConnections();
    } catch (e) {
      // Saved but not adopted — silent here (a pick never toasts,
      // 14 号票): the engine keeps the previous config, the raw
      // reason goes to the log.
      logRawError('note_quick_rectify_engine_kept', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final Widget header = AnimatedBuilder(
      // The header hands its orb-side reserve over continuously (12
      // 号票): both reserves always mounted, widths scaling with the
      // form — the title cluster between them TRANSLATES (整簇平移让位),
      // it never disappears.
      animation: widget.form,
      builder: (context, _) => Padding(
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
            // 左上 (downRight) full weight: the orb (✕) owns this row's
            // start — the title yields as one unit (让位按簇).
            SizedBox(width: widget.form.headerReserve(leading: true)),
            Text('快捷设置', style: SrType.title.copyWith(color: pal.textPrimary)),
            // 右上 (downLeft) full weight: the orb owns this row's end —
            // the header reserve (56), one contract with the session
            // window's header (the footer keeps 48; the header band is the
            // ring-bearing row; spec §3 义务层).
            SizedBox(width: widget.form.headerReserve(leading: false)),
          ],
        ),
      ),
    );
    // The header row is display-only (02 号票 abolished the header move
    // grip — the anchor button is the panel's one move affordance).
    return PanelBody(
      exiting: widget.exiting,
      form: widget.form,
      // The pinned top band (钉边裁切): the header row plus its divider
      // ride the card's current visual top as it grows out of the disc.
      header: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Divider(height: 1, thickness: 1, color: pal.hairline),
        ],
      ),
      // No footer band: the list stretches to the card's current visual
      // bottom and clips to the remaining height.
      body: ClipRRect(
        // Bottom corners clip to the card arc: scrolling content can
        // never bleed past the rounded card (the window-bleed-zero
        // principle, applied to the card's own edges).
        borderRadius: BorderRadius.vertical(
          bottom: Radius.circular(SrRadius.panel),
        ),
        child: AnimatedBuilder(
          // The body's anchor obligations interpolate with the form
          // (12 号票): head padding 12↔48, tail clearance 96·gu, and
          // the two fades hand over by OPACITY — surface over surface,
          // the one "disappearance" that is not a control.
          animation: widget.form,
          builder: (context, _) => Stack(
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
                    widget.form.bodyTopPad,
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
                      _DirectivePreviewRow(
                        icon: Icons.public_rounded,
                        tooltip: '全局指令',
                        text: c.globalDirective!,
                        testKey: 'quick-global',
                        domain: SettingsDomain.scenarios,
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
                      label: '编辑场景',
                      domain: SettingsDomain.scenarios,
                      onOpen: _openSettings,
                    ),
                    _sectionGap(pal),
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
                    _sectionGap(pal),
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
                        _HistoryRow(
                          entry: entry,
                          scenarios: c.scenarios,
                          onRerectify: c.rerectifyHistory,
                        ),
                    const SizedBox(height: 8),
                    _EntryRow(
                      key: const Key('quick-open-settings:history'),
                      label: '全部历史与管理',
                      domain: SettingsDomain.history,
                      onOpen: _openSettings,
                    ),
                    // The rectify mirror (quick-panel-additions 02): the
                    // settings page's three cards as three FIRST-LEVEL
                    // sections, pick-to-save over the same store. The
                    // whole block stays hidden until the load lands (or
                    // forever on a refused read) — the neighboring
                    // sections are not hostage to it.
                    if (_rectify case final RectifyBehavior rectify) ...[
                      _sectionGap(pal),
                      _sectionLabel(pal, '全量修正模式'),
                      _RectifyTierSection(
                        tier: _RectifyTier.full,
                        behavior: rectify,
                        onPick: _pickRectify,
                        onOpen: _openSettings,
                      ),
                      _sectionGap(pal),
                      _sectionLabel(pal, '轻修模式'),
                      _RectifyTierSection(
                        tier: _RectifyTier.lightTouch,
                        behavior: rectify,
                        onPick: _pickRectify,
                        onOpen: _openSettings,
                      ),
                      _sectionGap(pal),
                      _sectionLabel(pal, '快速模式'),
                      _RectifyTierSection(
                        tier: _RectifyTier.quick,
                        behavior: rectify,
                        onPick: _pickRectify,
                        onOpen: _openSettings,
                      ),
                    ],
                    _sectionGap(pal),
                    _sectionLabel(pal, '外观'),
                    _ThemeRow(controller: c),
                    _sectionGap(pal),
                    _sectionLabel(pal, '设置入口'),
                    _EntryRow(
                      key: const Key('quick-open-settings:general'),
                      label: '打开设置',
                      domain: SettingsDomain.general,
                      onOpen: _openSettings,
                    ),
                    // Anchor zone clearance — scaled by how much the
                    // anchor sits at the bottom edge (up-growth): the
                    // orb's whole footprint rides this band. A
                    // top-anchored orb's obligations live at the list's
                    // head (fade + padding above); the tail keeps the
                    // standing md floor (小修 13) — a zero tail let the
                    // last entry row kiss the card's bottom edge.
                    SizedBox(
                      key: const Key('quick-tail-clearance'),
                      height: widget.form.bodyTailPad,
                    ),
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
              // carries its fade only while the anchor sits on it
              // (mounted at zero weight otherwise), and a vertical
              // switch CROSSES them over by opacity alone.
              if (widget.form.gu > 0.001)
                Positioned(
                  key: const Key('quick-bottom-fade'),
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: SrGeometry.anchorInset * 2,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: widget.form.gu,
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
                ),
              if (widget.form.gu < 0.999)
                Positioned(
                  key: const Key('quick-top-fade'),
                  left: 0,
                  right: 0,
                  top: 0,
                  height: SrGeometry.anchorInset,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: (1 - widget.form.gu).clamp(0.0, 1.0),
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
                ),
            ],
          ),
        ),
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
    // The click's destination IS the settings window: collapse the
    // panel quietly (no foreground hand-back to the insertion target,
    // which would race the settings window's own focus and could leave
    // it behind). The panel and the settings window stay independent —
    // 小修 17.
    c.closeQuick(handBackFocus: false);
    widget.onOpenSettings?.call(domain);
  }

  Widget _sectionLabel(SrPalette pal, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: SrType.caption.copyWith(color: pal.textTertiary)),
  );

  /// Review round 2 (quick-panel-additions 02): the sections ran
  /// together — a hairline with air on each side separates every pair
  /// now (height 33 ≈ the old 20px gap plus the line's own breathing
  /// room).
  Widget _sectionGap(SrPalette pal) =>
      Divider(height: 33, thickness: 1, color: pal.hairline);
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

/// The shared chip cascade: the scenario quick-picks and the theme
/// segments paint identically, differing only in layout density. Chips
/// keep the plain control radius: the capsule is a corner-band
/// privilege (spec §3).
BoxDecoration _chipBox(SrPalette pal, {required bool hover}) => BoxDecoration(
  color: hover ? pal.surfaceOverlay : pal.surfaceRaised,
  borderRadius: BorderRadius.circular(SrRadius.control),
  border: Border.all(color: pal.hairline),
);

/// The selection's blue, drawn OVER the base as its own layer so the
/// crossfade only ever animates its own alpha: lerping the selected fill
/// straight into the neutral one sweeps through a heavier, darker fill
/// mid-flight — on the chip being DEselected that read as an unpressed
/// darken, which belongs to the press alone (26 号票 真机 round).
BoxDecoration _chipWash(SrPalette pal, {required bool selected}) =>
    BoxDecoration(
      color: selected ? pal.accentSoft : pal.accentSoft.withValues(alpha: 0),
      borderRadius: BorderRadius.circular(SrRadius.control),
      border: Border.all(
        color: selected
            ? pal.accent.withValues(alpha: 0.55)
            : pal.accent.withValues(alpha: 0),
      ),
    );

TextStyle _chipText(SrPalette pal, {required bool selected}) =>
    SrType.caption.copyWith(
      color: selected ? pal.accentText : pal.textSecondary,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
    );

/// A read-only directive preview row (the global directive's shape,
/// ticket 22): what is currently in force, one truncated line (the
/// tooltip names it, the full text does not fit), with the settings
/// jump on its right — one button per row, each landing on the domain
/// where the directive's editor lives (the same mechanism the
/// 编辑场景… entry uses). Hidden entirely while unset. [dimmed] stages
/// 启用修正-off's extra layer on the quick tier's row (§4.4: the
/// directive is unused then — dim, not hide).
class _DirectivePreviewRow extends StatelessWidget {
  const _DirectivePreviewRow({
    required this.icon,
    required this.tooltip,
    required this.text,
    required this.testKey,
    required this.domain,
    required this.onOpen,
    this.dimmed = false,
  });

  final IconData icon;
  final String tooltip;
  final String text;

  /// The row's key base: the text paints '$testKey-preview', the
  /// settings button '$testKey-open'.
  final String testKey;
  final SettingsDomain domain;
  final ValueChanged<SettingsDomain> onOpen;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return IgnorePointer(
      ignoring: dimmed,
      child: AnimatedOpacity(
        duration: SrMotion.fade,
        curve: SrMotion.curveFade,
        opacity: dimmed ? 0.5 : 1,
        child: SrHover(
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
                Icon(icon, size: 14, color: pal.textTertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Tooltip(
                    message: tooltip,
                    waitDuration: SrMotion.tooltipWait,
                    child: Text(
                      text,
                      key: Key('$testKey-preview'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SrType.caption.copyWith(color: pal.textSecondary),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  key: Key('$testKey-open'),
                  onTap: () => onOpen(domain),
                  child: Tooltip(
                    message: '编辑$tooltip',
                    waitDuration: SrMotion.tooltipWait,
                    child: SrHoverTintIcon(
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
      builder: (hover) => SrPress(
        builder: (pressed) => GestureDetector(
          onTap: () => onOpen(domain),
          child: SrPressFill(
            // Around the padded box — full-bleed scrim (26 号票 真机).
            pressed: pressed,
            radius: BorderRadius.circular(SrRadius.control),
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
                  SrHoverTintIcon(
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
        ),
      ),
    );
  }
}

/// A scenario quick-pick chip (dense, text only) — also the thinking
/// policy trio's body. [enabled] stages §4.4's connection-thinking
/// cascade: a disabled chip stays laid out but swallows hits and dims.
class _SelectableChip extends StatelessWidget {
  const _SelectableChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        duration: SrMotion.fade,
        curve: SrMotion.curveFade,
        opacity: enabled ? 1 : 0.45,
        child: SrHover(
          builder: (hover) => SrPress(
            builder: (pressed) => GestureDetector(
              onTap: onTap,
              child: SrPressFill(
                // Press darkens at pointer-down (fast, full-bleed);
                // the blue highlight stays with the selection state
                // (26 号票 真机 round).
                pressed: pressed,
                radius: BorderRadius.circular(SrRadius.control),
                child: AnimatedContainer(
                  // The selection is a discrete switch: it rides the surface
                  // fade (hover's fill shares the container, so it eases on
                  // the same window — 26 号票's two-tier rule).
                  duration: SrMotion.fade,
                  curve: SrMotion.curveFade,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: _chipBox(pal, hover: hover),
                  foregroundDecoration: _chipWash(pal, selected: selected),
                  child: AnimatedDefaultTextStyle(
                    duration: SrMotion.fade,
                    curve: SrMotion.curveFade,
                    style: _chipText(pal, selected: selected),
                    child: Text(label),
                  ),
                ),
              ),
            ),
          ),
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
      builder: (hover) => SrPress(
        builder: (pressed) => GestureDetector(
          onTap: onTap,
          child: SrPressFill(
            // Press darkens at pointer-down; the highlight follows the
            // selection state (26 号票 真机 round).
            pressed: pressed,
            radius: BorderRadius.circular(SrRadius.control),
            child: AnimatedContainer(
              // Selection = discrete switch → the surface fade (26 号票).
              duration: SrMotion.fade,
              curve: SrMotion.curveFade,
              height: 34,
              alignment: Alignment.center,
              decoration: _chipBox(pal, hover: hover),
              foregroundDecoration: _chipWash(pal, selected: selected),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // The tint micro-recipe rides the selection, not the
                  // pointer: selected IS the "hovered" tone here.
                  SrHoverTintIcon(
                    icon: icon,
                    size: 14,
                    hover: selected,
                    resting: pal.textSecondary,
                    hovered: pal.accentText,
                  ),
                  const SizedBox(width: 5),
                  AnimatedDefaultTextStyle(
                    duration: SrMotion.fade,
                    curve: SrMotion.curveFade,
                    style: _chipText(pal, selected: selected),
                    child: Text(label),
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
              hintText: '添加术语',
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
      builder: (hover) => SrPress(
        builder: (pressed) => GestureDetector(
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
            child: SrPressFill(
              pressed: pressed,
              radius: BorderRadius.circular(SrRadius.control),
              child: SrHoverTintIcon(
                key: const Key('quick-term-add'),
                icon: Icons.add_rounded,
                size: 18,
                hover: hover,
                resting: pal.accentText,
                hovered: pal.onAccent,
              ),
            ),
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
              child: SrHoverTintIcon(
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
          child: SrHoverTintIcon(
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
    await onRerectify(
      entry.rawTranscript,
      style: pick,
      sourceSessionId: entry.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SrHover(
      builder: (hover) => Tooltip(
        message: '指定场景重新修正',
        waitDuration: SrMotion.tooltipWait,
        child: GestureDetector(
          onTap: () => _open(context),
          child: SrHoverTintIcon(
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

/// A switch row in the panel's zero-caption form (quick-panel-additions
/// round 1): icon + bare label + Switch — the explanation text lives in
/// the settings window, the panel is the accelerator.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: pal.textSecondary),
        const SizedBox(width: 10),
        Text(label, style: SrType.body.copyWith(color: pal.textPrimary)),
        const Spacer(),
        Switch(value: value, onChanged: onChanged),
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
    (ThemeMode.system, '跟随系统', Icons.monitor_rounded, 'quick-theme-system'),
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

// ---------------------------------------------------------------------------
// The rectify tier sections (quick-panel-additions 02)
// ---------------------------------------------------------------------------

/// One point-select's single-field change, applied over whatever model
/// it is handed — the snapshot for the optimistic paint, a FRESH read
/// for the commit (channel (b): exactly one field moves, everything
/// else rides the read).
typedef RectifyPick = RectifyBehavior Function(RectifyBehavior behavior);

/// The thinking trio's PANEL-side copy (rounds 3+4): bare chips, no
/// 「思考策略」 field label (a micro label would read as another
/// section title), and shorter wording than the settings window's
/// 始终开启/仅包含占位图钉时开启/始终关闭 — the settings copy stays as
/// it is; the two surfaces are allowed their own register.
const _panelPolicyLabels = {
  'always': '开启思考',
  'placeholders': '仅含占位图钉时思考',
  'off': '关闭思考',
};

/// Which settings-page rectify card a section mirrors. The three tiers
/// stand as first-level panel sections (round 1 dropped the 修正
/// umbrella), control-for-control forms of the cards with §4.4's
/// cascades mirrored: 轻修 master off = tail disabled not hidden, 快速
/// master off = whole section disabled, 启用修正 off = the directive
/// preview row dimmed again, connection thinking off = both chip rows
/// disabled.
enum _RectifyTier { full, lightTouch, quick }

class _RectifyTierSection extends StatelessWidget {
  const _RectifyTierSection({
    required this.tier,
    required this.behavior,
    required this.onPick,
    required this.onOpen,
  });

  final _RectifyTier tier;
  final RectifyBehavior behavior;
  final ValueChanged<RectifyPick> onPick;
  final ValueChanged<SettingsDomain> onOpen;

  @override
  Widget build(BuildContext context) {
    return switch (tier) {
      _RectifyTier.full => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _prefillRow(
            testKey: 'quick-rectify-full-prefill',
            value: behavior.fullPrefill,
            onChanged: (on) => onPick((b) => b.copyWith(fullPrefill: on)),
          ),
          const SizedBox(height: 8),
          _thinkingRow(
            testKey: 'quick-rectify-full-policy',
            selected: behavior.fullThinkingPolicy,
            onSelect: (policy) =>
                onPick((b) => b.copyWith(fullThinkingPolicy: policy)),
          ),
        ],
      ),
      _RectifyTier.lightTouch => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SwitchRow(
            key: const Key('quick-rectify-light-enabled'),
            icon: Icons.auto_fix_high_outlined,
            label: '启用轻修模式',
            value: behavior.lightTouchEnabled,
            onChanged: (on) => onPick((b) => b.copyWith(lightTouchEnabled: on)),
          ),
          _cascade(
            !behavior.lightTouchEnabled,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                _prefillRow(
                  testKey: 'quick-rectify-light-prefill',
                  value: behavior.lightTouchPrefill,
                  onChanged: (on) =>
                      onPick((b) => b.copyWith(lightTouchPrefill: on)),
                ),
                const SizedBox(height: 8),
                _thinkingRow(
                  testKey: 'quick-rectify-light-policy',
                  selected: behavior.lightTouchThinkingPolicy,
                  onSelect: (policy) => onPick(
                    (b) => b.copyWith(lightTouchThinkingPolicy: policy),
                  ),
                ),
                if (behavior.lightTouchExtraDirective case final text?) ...[
                  const SizedBox(height: 8),
                  _DirectivePreviewRow(
                    icon: Icons.edit_note_rounded,
                    tooltip: '轻修额外指令',
                    text: text,
                    testKey: 'quick-rectify-light',
                    domain: SettingsDomain.rectify,
                    onOpen: onOpen,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      _RectifyTier.quick => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SwitchRow(
            key: const Key('quick-rectify-quick-enabled'),
            icon: Icons.bolt_rounded,
            label: '启用快速模式',
            value: behavior.quickEnabled,
            onChanged: (on) => onPick((b) => b.copyWith(quickEnabled: on)),
          ),
          _cascade(
            !behavior.quickEnabled,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                _SwitchRow(
                  key: const Key('quick-rectify-quick-rectify'),
                  icon: Icons.task_alt_rounded,
                  label: '启用修正',
                  value: behavior.quickRectify,
                  onChanged: (on) =>
                      onPick((b) => b.copyWith(quickRectify: on)),
                ),
                if (behavior.quickExtraDirective case final text?) ...[
                  const SizedBox(height: 8),
                  _DirectivePreviewRow(
                    icon: Icons.edit_note_rounded,
                    tooltip: '快速额外指令',
                    text: text,
                    testKey: 'quick-rectify-quick',
                    domain: SettingsDomain.rectify,
                    onOpen: onOpen,
                    // 启用修正 off = the directive is unused: dim, not hide.
                    dimmed: !behavior.quickRectify,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    };
  }

  Widget _prefillRow({
    required String testKey,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => _SwitchRow(
    key: Key(testKey),
    icon: Icons.push_pin_rounded,
    label: '预填',
    value: value,
    onChanged: onChanged,
  );

  /// Round 3: no 「思考策略」 field label — the trio hangs bare under
  /// the section's own rows.
  Widget _thinkingRow({
    required String testKey,
    required String selected,
    required ValueChanged<String> onSelect,
  }) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final policy in rectifyPolicies)
        _SelectableChip(
          key: Key('$testKey:$policy'),
          label: _panelPolicyLabels[policy] ?? policy,
          selected: selected == policy,
          // §4.4: the connection domain's thinking fields gate both
          // tiers' chips (ADR-0019 item 3) — unselectable while inert,
          // recovery lives in 模型与连接.
          enabled: !behavior.thinkingDisabled,
          onTap: () => onSelect(policy),
        ),
    ],
  );

  /// §4.4's disabled-not-hidden: dim + swallow hits, keep the rows laid
  /// out (values still paint, still ride every whole-model write).
  Widget _cascade(bool disabled, Widget child) => AnimatedOpacity(
    duration: SrMotion.fade,
    curve: SrMotion.curveFade,
    opacity: disabled ? 0.45 : 1,
    child: IgnorePointer(ignoring: disabled, child: child),
  );
}
