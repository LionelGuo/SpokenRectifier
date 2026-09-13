/// The 修正 domain: the `[rectify]` behavior as two cards — 全量修正 on
/// top (the default path), 轻修 below with its master switch and
/// threshold riding the same `[rectify.light_touch]` section (ADR-0015,
/// the layout map's ruling).
///
/// PICK-TO-SAVE: every Switch flip and chip click commits at once, and
/// every commit writes the editor's WHOLE model — the two inputs (the
/// threshold, the extra directive) contribute their COMMITTED values,
/// never the unsaved drafts sitting in their fields; only the light
/// card's explicit save button writes those (validate the threshold,
/// blank the directive to unset). A master-switch-off light card
/// disables its whole tail without hiding it — the values still paint,
/// still ride every whole-model write, and the file keeps the keys
/// (runtime just stops consulting them).
///
/// The thinking-off × prefill-on warning is a STATEMENT, not a block
/// (ADR-0015): it lights live per tier from the form as painted —
/// including a combination that loaded that way from the files — and
/// saving that combination is always allowed. The light tier's warning
/// silences with its master switch (a disabled tier consumes nothing).
///
/// Every save hands the files to the live engine through the same
/// adoption the connection domain's saves take (ADR-0010, scope
/// extended to `[rectify]`): the NEXT attempt — first stop, reroll, a
/// history re-rectify — runs the new behavior; an in-flight attempt is
/// untouched. A refused adoption keeps the files saved and says so in
/// the banner. Hand-edited files still need a restart — or the next
/// save from ANY domain, which re-reads the files wholesale.

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard, SrField;
import '../design/hover.dart';
import '../design/tokens.dart';
import 'rectify_store.dart';

/// The thinking-policy chips' display labels, by wire name
/// (always / placeholders / off, ADR-0015).
const _policyLabels = {'always': '始终', 'placeholders': '仅占位符', 'off': '关闭'};

/// The warning a 思考关 ∩ 预填开 tier paints (the layout map's exact
/// wording): a statement of consequence, never a refusal.
const _comboWarning = '思考已关、预填仍开:占位符吸收依赖思考,关思考后预填初值多为空、需手动填写;此组合仍可使用。';

class SettingsRectifyPane extends StatefulWidget {
  const SettingsRectifyPane({super.key, required this.store});

  final RectifyBehaviorStore store;

  @override
  State<SettingsRectifyPane> createState() => _SettingsRectifyPaneState();
}

class _SettingsRectifyPaneState extends State<SettingsRectifyPane> {
  RectifyBehavior? _model;
  bool _loaded = false;
  String? _error;
  String? _savedNote;

  // The picks paint from these live copies so a tap lands (and the
  // warning lights) the same frame; _model holds the committed truth
  // the inputs diff against and failed saves fall back to reading.
  late String _fullPolicy;
  late bool _fullPrefill;
  late bool _ltEnabled;
  late String _ltPolicy;
  late bool _ltPrefill;

  late final TextEditingController _threshold = TextEditingController();
  late final TextEditingController _extra = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The dirty check re-runs on every keystroke (the save button's
    // enable follows), without threading onChanged through SrField.
    _threshold.addListener(_onInput);
    _extra.addListener(_onInput);
    _reload();
  }

  @override
  void dispose() {
    _threshold.dispose();
    _extra.dispose();
    super.dispose();
  }

  void _onInput() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    try {
      final behavior = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _adopt(behavior);
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = '修正设置读取失败:$e';
      });
    }
  }

  /// Adopt the files' truth: the picks, and (for the committed inputs)
  /// the fields' baseline. The listeners stay off while the text is
  /// written so a setState-in-setState doesn't fire from `_onInput`.
  void _adopt(RectifyBehavior behavior) {
    _model = behavior;
    _fullPolicy = behavior.fullThinkingPolicy;
    _fullPrefill = behavior.fullPrefill;
    _ltEnabled = behavior.lightTouchEnabled;
    _ltPolicy = behavior.lightTouchThinkingPolicy;
    _ltPrefill = behavior.lightTouchPrefill;
    _threshold.removeListener(_onInput);
    _extra.removeListener(_onInput);
    _threshold.text = '${behavior.lightTouchMaxChars}';
    _extra.text = behavior.lightTouchExtraDirective ?? '';
    _threshold.addListener(_onInput);
    _extra.addListener(_onInput);
  }

  /// The whole model as the form's PICKS stand, over the committed
  /// inputs — what a pick (a flip, a chip) commits.
  RectifyBehavior get _liveModel => _model!.copyWith(
    fullThinkingPolicy: _fullPolicy,
    fullPrefill: _fullPrefill,
    lightTouchEnabled: _ltEnabled,
    lightTouchThinkingPolicy: _ltPolicy,
    lightTouchPrefill: _ltPrefill,
  );

  /// True while either input field holds text the committed truth
  /// doesn't (the save button's enable; the pick path never consults
  /// it — drafts are never swept along).
  bool get _inputsDirty =>
      _threshold.text.trim() != '${_model!.lightTouchMaxChars}' ||
      _extra.text.trim() != (_model!.lightTouchExtraDirective ?? '');

  /// A pick: paint the flip at once, then commit the whole model with
  /// the inputs left at their committed values.
  void _pick(RectifyBehavior update) {
    setState(() {
      _fullPolicy = update.fullThinkingPolicy;
      _fullPrefill = update.fullPrefill;
      _ltEnabled = update.lightTouchEnabled;
      _ltPolicy = update.lightTouchThinkingPolicy;
      _ltPrefill = update.lightTouchPrefill;
    });
    _save(_liveModel, reseedInputs: false);
  }

  /// The light card's explicit save: validate the threshold, blank the
  /// directive to unset, commit the whole model with the picks as they
  /// paint.
  Future<void> _saveInputs() async {
    final text = _threshold.text.trim();
    final value = int.tryParse(text);
    if (value == null || value < 1) {
      setState(() => _error = '轻修字数阈需为不小于 1 的整数(当前:$text)');
      return;
    }
    final extra = _extra.text.trim();
    await _save(
      _liveModel.copyWith(
        lightTouchMaxChars: value,
        lightTouchExtraDirective: extra.isEmpty ? null : extra,
      ),
      reseedInputs: true,
    );
  }

  /// Commit the whole model, adopt the re-read truth, then hand the
  /// files to the live engine (ADR-0010). [reseedInputs] re-baselines
  /// the two input fields — only the explicit save path changes what
  /// they hold.
  Future<void> _save(RectifyBehavior next, {required bool reseedInputs}) async {
    try {
      final saved = await widget.store.save(next);
      if (!mounted) return;
      setState(() {
        _model = saved;
        _fullPolicy = saved.fullThinkingPolicy;
        _fullPrefill = saved.fullPrefill;
        _ltEnabled = saved.lightTouchEnabled;
        _ltPolicy = saved.lightTouchThinkingPolicy;
        _ltPrefill = saved.lightTouchPrefill;
        if (reseedInputs) {
          _threshold.removeListener(_onInput);
          _extra.removeListener(_onInput);
          _threshold.text = '${saved.lightTouchMaxChars}';
          _extra.text = saved.lightTouchExtraDirective ?? '';
          _threshold.addListener(_onInput);
          _extra.addListener(_onInput);
        }
        _error = null;
        _savedNote = '已保存,下一次修正尝试生效';
      });
    } catch (e) {
      if (!mounted) return;
      // The file refused the write: the picks keep painting what the
      // user chose (a re-tap is the retry), the inputs keep their text.
      setState(() => _error = '修正设置保存失败:$e');
      return;
    }
    try {
      await widget.store.applyConnections();
    } catch (e) {
      if (!mounted) return;
      // Saved but not adopted: the engine keeps the previous config
      // (the connection domain's banner contract, ADR-0010).
      setState(() => _error = '已保存,但引擎沿用上一配置:$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final model = _model;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('修正', style: SrType.title.copyWith(color: pal.textPrimary)),
            const SizedBox(width: 10),
            Text(
              '按强度分档配置修正行为;保存写入 [rectify.*] 配置层',
              key: const Key('settings-rectify-note'),
              style: SrType.caption.copyWith(color: pal.textTertiary),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const Key('settings-rectify-error'),
            style: SrType.caption.copyWith(color: pal.live),
          ),
        ],
        if (_savedNote != null) ...[
          const SizedBox(height: 12),
          Text(
            _savedNote!,
            key: const Key('settings-rectify-saved'),
            style: SrType.caption.copyWith(color: pal.textSecondary),
          ),
        ],
        const SizedBox(height: 16),
        if (!_loaded || model == null)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          _FullCard(
            policy: _fullPolicy,
            prefill: _fullPrefill,
            onPolicy: (policy) =>
                _pick(_liveModel.copyWith(fullThinkingPolicy: policy)),
            onPrefill: (on) => _pick(_liveModel.copyWith(fullPrefill: on)),
          ),
          const SizedBox(height: 16),
          _LightCard(
            enabled: _ltEnabled,
            policy: _ltPolicy,
            prefill: _ltPrefill,
            threshold: _threshold,
            extra: _extra,
            inputsDirty: _inputsDirty,
            onEnabled: (on) =>
                _pick(_liveModel.copyWith(lightTouchEnabled: on)),
            onPolicy: (policy) =>
                _pick(_liveModel.copyWith(lightTouchThinkingPolicy: policy)),
            onPrefill: (on) =>
                _pick(_liveModel.copyWith(lightTouchPrefill: on)),
            onSaveInputs: _saveInputs,
          ),
          const SizedBox(height: 20),
          Text(
            '直接改配置文件需重启生效;期间在任意设置域保存一次也会一并采用',
            key: const Key('settings-rectify-hand-edit'),
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
        ],
      ],
    );
  }
}

/// 全量修正 `[rectify.full]`: the prefill switch and the thinking
/// chips, both pick-to-save, with the tier's combination warning under
/// the chips.
class _FullCard extends StatelessWidget {
  const _FullCard({
    required this.policy,
    required this.prefill,
    required this.onPolicy,
    required this.onPrefill,
  });

  final String policy;
  final bool prefill;
  final ValueChanged<String> onPolicy;
  final ValueChanged<bool> onPrefill;

  bool get _warns => policy == 'off' && prefill;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '全量修正 [rectify.full]',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '篇章级重组与压缩提密;轻修关闭或口语段超阈时使用',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 10),
          _PrefillRow(value: prefill, onChanged: onPrefill),
          const SizedBox(height: 12),
          Text('思考策略', style: SrType.micro.copyWith(color: pal.textTertiary)),
          const SizedBox(height: 6),
          _PolicyChips(
            testKey: 'settings-rectify-full-policy',
            selected: policy,
            onSelect: onPolicy,
          ),
          if (_warns) ...[
            const SizedBox(height: 6),
            Text(
              _comboWarning,
              key: const Key('settings-rectify-full-warning'),
              style: SrType.caption.copyWith(color: pal.live),
            ),
          ],
        ],
      ),
    );
  }
}

/// 轻修 `[rectify.light_touch]`: the master switch first (always live),
/// then the whole tail — threshold, prefill, thinking, extra directive,
/// the shared save button — disabled in place while the switch is off:
/// values stay visible, keys stay saved, the tier's warning silences.
class _LightCard extends StatelessWidget {
  const _LightCard({
    required this.enabled,
    required this.policy,
    required this.prefill,
    required this.threshold,
    required this.extra,
    required this.inputsDirty,
    required this.onEnabled,
    required this.onPolicy,
    required this.onPrefill,
    required this.onSaveInputs,
  });

  final bool enabled;
  final String policy;
  final bool prefill;
  final TextEditingController threshold;
  final TextEditingController extra;
  final bool inputsDirty;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<String> onPolicy;
  final ValueChanged<bool> onPrefill;
  final VoidCallback onSaveInputs;

  bool get _warns => enabled && policy == 'off' && prefill;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '轻修 [rectify.light_touch]',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '去口头语、应用口头更正,不改篇章结构与措辞',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '启用轻修',
                  style: SrType.caption.copyWith(color: pal.textSecondary),
                ),
              ),
              Switch(
                key: const Key('settings-rectify-light-enabled'),
                value: enabled,
                onChanged: onEnabled,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '关闭时一律全量修正;开启时短于字数阈的口语段走轻修',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 12),
          // Disabled in place, never hidden: the tail grays out under
          // one pointer shield so its values keep painting.
          AnimatedOpacity(
            duration: SrMotion.fade,
            curve: SrMotion.curveFade,
            opacity: enabled ? 1 : 0.5,
            child: AbsorbPointer(
              absorbing: !enabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SrField(
                    key: const Key('settings-rectify-light-threshold'),
                    controller: threshold,
                    label: '轻修字数阈(字)',
                    monospace: true,
                  ),
                  const SizedBox(height: 12),
                  _PrefillRow(
                    value: prefill,
                    onChanged: onPrefill,
                    testKey: 'settings-rectify-light-prefill',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '思考策略',
                    style: SrType.micro.copyWith(color: pal.textTertiary),
                  ),
                  const SizedBox(height: 6),
                  _PolicyChips(
                    testKey: 'settings-rectify-light-policy',
                    selected: policy,
                    onSelect: onPolicy,
                  ),
                  if (_warns) ...[
                    const SizedBox(height: 6),
                    Text(
                      _comboWarning,
                      key: const Key('settings-rectify-light-warning'),
                      style: SrType.caption.copyWith(color: pal.live),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    '轻修额外指令',
                    style: SrType.caption.copyWith(color: pal.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '仅在走轻修时注入,只塑形式与语气;留空则不注入',
                    style: SrType.micro.copyWith(color: pal.textTertiary),
                  ),
                  const SizedBox(height: 6),
                  KeyedSubtree(
                    key: const Key('settings-rectify-light-extra'),
                    child: TextField(
                      controller: extra,
                      minLines: 2,
                      maxLines: 5,
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
                        hintText: '例:保留技术术语原文',
                        hintStyle: SrType.body.copyWith(
                          color: pal.textTertiary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // One button for both inputs (the advanced domain's
                  // one-card-one-button rule); quiet until there is
                  // something to commit — disabled is a no-op, never a
                  // hidden button.
                  SrButton(
                    key: const Key('settings-rectify-light-save'),
                    primary: inputsDirty,
                    label: '保存轻修设置',
                    onTap: inputsDirty ? onSaveInputs : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The 预填 row both cards share (the advanced domain's passage-switch
/// recipe): the label and the switch on one line, the explanation under.
class _PrefillRow extends StatelessWidget {
  const _PrefillRow({
    required this.value,
    required this.onChanged,
    this.testKey = 'settings-rectify-full-prefill',
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// The switch's test key (the two cards' rows must not collide).
  final String testKey;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '预填',
                style: SrType.caption.copyWith(color: pal.textSecondary),
              ),
            ),
            Switch(key: Key(testKey), value: value, onChanged: onChanged),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '开启后,紧邻占位符的完整名词短语整块吸收为填写槽初值',
          style: SrType.micro.copyWith(color: pal.textTertiary),
        ),
      ],
    );
  }
}

/// The thinking-policy chip trio (the advanced domain's mode-chips
/// recipe): 始终 / 仅占位符 / 关闭 over the wire names.
class _PolicyChips extends StatelessWidget {
  const _PolicyChips({
    required this.testKey,
    required this.selected,
    required this.onSelect,
  });

  final String testKey;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Wrap(
      key: Key(testKey),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final policy in rectifyPolicies)
          SrHover(
            builder: (hover) => GestureDetector(
              onTap: () => onSelect(policy),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                key: Key('$testKey:$policy'),
                duration: SrMotion.fade,
                curve: SrMotion.curveFade,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: policy == selected
                      ? pal.accentSoft
                      : pal.surfaceOverlay.withValues(alpha: hover ? 1 : 0),
                  borderRadius: BorderRadius.circular(SrRadius.control),
                  border: Border.all(
                    color: policy == selected
                        ? pal.accent.withValues(alpha: 0.6)
                        : pal.hairline,
                  ),
                ),
                child: Text(
                  _policyLabels[policy] ?? policy,
                  style: SrType.caption.copyWith(
                    color: policy == selected
                        ? pal.accentText
                        : pal.textSecondary,
                    fontWeight: policy == selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
