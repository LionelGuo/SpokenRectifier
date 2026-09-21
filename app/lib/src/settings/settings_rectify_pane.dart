/// The 修正 domain: the `[rectify]` behavior as three cards — 全量修正 on
/// top (the default path), 轻修 below with its master switch and
/// threshold riding the same `[rectify.light_touch]` section (ADR-0015,
/// the layout map's ruling), then 快速模式 `[rectify.quick]` (ADR-0020)
/// with its own master switch, rectify gate, and extra directive. The
/// quick card has no thinking chips, no prefill, no threshold.
///
/// PICK-TO-SAVE: every Switch flip and chip click commits at once, and
/// every commit writes the editor's WHOLE model — the inputs (the
/// threshold, each extra directive) contribute their COMMITTED values,
/// never the unsaved drafts sitting in their fields; only each card's
/// explicit save button writes those (validate the threshold, blank the
/// directive to unset). A master-switch-off light or quick card
/// disables its whole tail without hiding it — the values still paint,
/// still ride every whole-model write, and the file keeps the keys
/// (runtime just stops consulting them). The quick card's extra field
/// further disables when 启用修正 is off (the directive is unused).
///
/// The thinking-off × prefill-on warning is a STATEMENT, not a block
/// (ADR-0015): it lights live per tier from the form as painted —
/// including a combination that loaded that way from the files — and
/// saving that combination is always allowed. The light tier's warning
/// silences with its master switch (a disabled tier consumes nothing).
///
/// The CONNECTION domain's thinking fields gate both cards (ADR-0019
/// item 3, design-spec §4.4): while its switch is off, its fields are
/// unconfigured, or its file is broken, the two policy chip rows go
/// unselectable and both combination warnings fall silent — the tier's
/// policies are unadopted either way, and a warning about a policy
/// nothing runs would read as a live consequence. Recovery is the
/// connection domain's switch or a fixed file; this pane only reads the
/// state, never writes it.
///
/// Every save hands the files to the live engine through the same
/// adoption the connection domain's saves take (ADR-0010, scope
/// extended to `[rectify]`): the NEXT attempt — first stop, reroll, a
/// history re-rectify — runs the new behavior; an in-flight attempt is
/// untouched. Hand-edited files still need a restart — or the next
/// save from ANY domain, which re-reads the files wholesale.
///
/// Toast policy (14 号票): a pick's own paint is its confirmation —
/// picks never toast, not for success nor a refused adoption. Only
/// the explicit save buttons confirm (「已保存」), and a refused
/// adoption replaces that with 「已保存，引擎沿用上一配置」 in the
/// error tone — icon and text must lean the same way.

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard, SrField, SrPressFill;
import '../design/hover.dart';
import '../design/toast.dart';
import '../design/tokens.dart';
import '../errors.dart';
import 'rectify_store.dart';

/// The thinking-policy chips' display labels, by wire name
/// (always / placeholders / off, ADR-0015).
const _policyLabels = {
  'always': '始终开启',
  'placeholders': '仅包含占位图钉时开启',
  'off': '始终关闭',
};

/// The warning a 思考关 ∩ 预填开 tier paints (the layout map's exact
/// wording): a statement of consequence, never a refusal.
const _comboWarning = '关闭模型思考可能降低预填质量';

/// What the two cards say while the connection domain's thinking fields
/// are inert — the same line on both, naming where the recovery lives.
const _thinkingDisabledNote =
    '连接域的思考字段未启用（关 / 未配置 / 坏配置），思考策略暂不可选；'
    '在「模型与连接」开启或修复后自动恢复。';

class SettingsRectifyPane extends StatefulWidget {
  const SettingsRectifyPane({super.key, required this.store});

  final RectifyBehaviorStore store;

  @override
  State<SettingsRectifyPane> createState() => _SettingsRectifyPaneState();
}

class _SettingsRectifyPaneState extends State<SettingsRectifyPane> {
  RectifyBehavior? _model;
  bool _loaded = false;

  // The picks paint from these live copies so a tap lands (and the
  // warning lights) the same frame; _model holds the committed truth
  // the inputs diff against and failed saves fall back to reading.
  late String _fullPolicy;
  late bool _fullPrefill;
  late bool _ltEnabled;
  late String _ltPolicy;
  late bool _ltPrefill;
  late bool _quickEnabled;
  late bool _quickRectify;

  late final TextEditingController _threshold = TextEditingController();
  late final TextEditingController _extra = TextEditingController();
  late final TextEditingController _quickExtra = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The dirty check re-runs on every keystroke (the save button's
    // enable follows), without threading onChanged through SrField.
    _threshold.addListener(_onInput);
    _extra.addListener(_onInput);
    _quickExtra.addListener(_onInput);
    _reload();
  }

  @override
  void dispose() {
    _threshold.dispose();
    _extra.dispose();
    _quickExtra.dispose();
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loaded = true);
      logRawError('err_rectify_load', e);
      SrToast.of(context).show('修正设置读取失败', tone: SrToastTone.error);
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
    _quickEnabled = behavior.quickEnabled;
    _quickRectify = behavior.quickRectify;
    _threshold.removeListener(_onInput);
    _extra.removeListener(_onInput);
    _quickExtra.removeListener(_onInput);
    _threshold.text = '${behavior.lightTouchMaxChars}';
    _extra.text = behavior.lightTouchExtraDirective ?? '';
    _quickExtra.text = behavior.quickExtraDirective ?? '';
    _threshold.addListener(_onInput);
    _extra.addListener(_onInput);
    _quickExtra.addListener(_onInput);
  }

  /// The whole model as the form's PICKS stand, over the committed
  /// inputs — what a pick (a flip, a chip) commits.
  RectifyBehavior get _liveModel => _model!.copyWith(
    fullThinkingPolicy: _fullPolicy,
    fullPrefill: _fullPrefill,
    lightTouchEnabled: _ltEnabled,
    lightTouchThinkingPolicy: _ltPolicy,
    lightTouchPrefill: _ltPrefill,
    quickEnabled: _quickEnabled,
    quickRectify: _quickRectify,
  );

  /// True while either light input field holds text the committed
  /// truth doesn't (the light save button's enable; the pick path
  /// never consults it — drafts are never swept along).
  bool get _inputsDirty =>
      _threshold.text.trim() != '${_model!.lightTouchMaxChars}' ||
      _extra.text.trim() != (_model!.lightTouchExtraDirective ?? '');

  /// The quick extra field's own dirty flag — a separate save, so a
  /// light pick never consumes this draft and a light save never
  /// reseeds it.
  bool get _quickInputsDirty =>
      _quickExtra.text.trim() != (_model!.quickExtraDirective ?? '');

  /// A pick: paint the flip at once, then commit the whole model with
  /// the inputs left at their committed values.
  void _pick(RectifyBehavior update) {
    setState(() {
      _fullPolicy = update.fullThinkingPolicy;
      _fullPrefill = update.fullPrefill;
      _ltEnabled = update.lightTouchEnabled;
      _ltPolicy = update.lightTouchThinkingPolicy;
      _ltPrefill = update.lightTouchPrefill;
      _quickEnabled = update.quickEnabled;
      _quickRectify = update.quickRectify;
    });
    _save(_liveModel);
  }

  /// The light card's explicit save: validate the threshold, blank the
  /// directive to unset, commit the whole model with the picks as they
  /// paint.
  Future<void> _saveInputs() async {
    final text = _threshold.text.trim();
    final value = int.tryParse(text);
    if (value == null || value < 1) {
      SrToast.of(context).show('阈值需为大于 0 的整数', tone: SrToastTone.error);
      return;
    }
    final extra = _extra.text.trim();
    await _save(
      _liveModel.copyWith(
        lightTouchMaxChars: value,
        lightTouchExtraDirective: extra.isEmpty ? null : extra,
      ),
      reseedLightInputs: true,
      announce: true,
    );
  }

  /// The quick card's explicit save: blank the directive to unset,
  /// commit the whole model with the picks as they paint. Does not
  /// touch the light inputs' drafts.
  Future<void> _saveQuickInputs() async {
    final extra = _quickExtra.text.trim();
    await _save(
      _liveModel.copyWith(quickExtraDirective: extra.isEmpty ? null : extra),
      reseedQuickExtra: true,
      announce: true,
    );
  }

  /// Commit the whole model, adopt the re-read truth, then hand the
  /// files to the live engine (ADR-0010). Each reseed flag re-baselines
  /// only that card's input fields — a pick never reseeds, and one
  /// card's save never consumes the other's draft. [announce] is the
  /// save buttons' flag: picks stay silent (their paint is the
  /// feedback), explicit saves confirm over the toast (14 号票).
  Future<void> _save(
    RectifyBehavior next, {
    bool reseedLightInputs = false,
    bool reseedQuickExtra = false,
    bool announce = false,
  }) async {
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
        _quickEnabled = saved.quickEnabled;
        _quickRectify = saved.quickRectify;
        if (reseedLightInputs) {
          _threshold.removeListener(_onInput);
          _extra.removeListener(_onInput);
          _threshold.text = '${saved.lightTouchMaxChars}';
          _extra.text = saved.lightTouchExtraDirective ?? '';
          _threshold.addListener(_onInput);
          _extra.addListener(_onInput);
        }
        if (reseedQuickExtra) {
          _quickExtra.removeListener(_onInput);
          _quickExtra.text = saved.quickExtraDirective ?? '';
          _quickExtra.addListener(_onInput);
        }
      });
      if (announce) {
        SrToast.of(context).show('已保存', tone: SrToastTone.success);
      }
    } catch (e) {
      if (!mounted) return;
      // The file refused the write: the picks keep painting what the
      // user chose (a re-tap is the retry), the inputs keep their text.
      logRawError('err_rectify_save', e);
      SrToast.of(context).show('保存失败', tone: SrToastTone.error);
      return;
    }
    try {
      await widget.store.applyConnections();
    } catch (e) {
      if (!mounted) return;
      // Saved but not adopted: the engine keeps the previous config
      // (ADR-0010). Only the save buttons say so — the copy names both
      // states so the error tone has a text that leans with it; a
      // pick stays silent (14 号票).
      logRawError('note_rectify_engine_kept', e);
      if (announce) {
        SrToast.of(context).show('已保存，引擎沿用上一配置', tone: SrToastTone.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final model = _model;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('修正', style: SrType.title.copyWith(color: pal.textPrimary)),
        const SizedBox(height: 16),
        if (!_loaded || model == null)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          _FullCard(
            policy: _fullPolicy,
            prefill: _fullPrefill,
            thinkingDisabled: model.thinkingDisabled,
            onPolicy: (policy) =>
                _pick(_liveModel.copyWith(fullThinkingPolicy: policy)),
            onPrefill: (on) => _pick(_liveModel.copyWith(fullPrefill: on)),
          ),
          const SizedBox(height: 16),
          _LightCard(
            enabled: _ltEnabled,
            policy: _ltPolicy,
            prefill: _ltPrefill,
            thinkingDisabled: model.thinkingDisabled,
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
          const SizedBox(height: 16),
          _QuickCard(
            enabled: _quickEnabled,
            rectify: _quickRectify,
            extra: _quickExtra,
            inputsDirty: _quickInputsDirty,
            onEnabled: (on) => _pick(_liveModel.copyWith(quickEnabled: on)),
            onRectify: (on) => _pick(_liveModel.copyWith(quickRectify: on)),
            onSaveInputs: _saveQuickInputs,
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
    required this.thinkingDisabled,
    required this.onPolicy,
    required this.onPrefill,
  });

  final String policy;
  final bool prefill;

  /// The connection domain's fields are inert: the chips go
  /// unselectable and the warning falls silent (ADR-0019 item 3).
  final bool thinkingDisabled;
  final ValueChanged<String> onPolicy;
  final ValueChanged<bool> onPrefill;

  bool get _warns => !thinkingDisabled && policy == 'off' && prefill;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '全量模式',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '对输入文本进行标准的语义过滤及篇章重组',
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
            enabled: !thinkingDisabled,
          ),
          if (thinkingDisabled) ...[
            const SizedBox(height: 6),
            Text(
              _thinkingDisabledNote,
              key: const Key('settings-rectify-full-thinking-off'),
              style: SrType.caption.copyWith(color: pal.textSecondary),
            ),
          ],
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
    required this.thinkingDisabled,
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

  /// The connection domain's fields are inert (ADR-0019 item 3): same
  /// rule as the full card's, on top of this card's own master switch.
  final bool thinkingDisabled;
  final TextEditingController threshold;
  final TextEditingController extra;
  final bool inputsDirty;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<String> onPolicy;
  final ValueChanged<bool> onPrefill;
  final VoidCallback onSaveInputs;

  bool get _warns => enabled && !thinkingDisabled && policy == 'off' && prefill;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '轻修模式',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '仅去除口头语，保留句式结构与措辞',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '启用轻修模式',
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
            '在字数低于阈值时允许启用轻修模式',
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
                    label: '轻修字数阈值',
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
                    enabled: !thinkingDisabled,
                  ),
                  if (thinkingDisabled) ...[
                    const SizedBox(height: 6),
                    Text(
                      _thinkingDisabledNote,
                      key: const Key('settings-rectify-light-thinking-off'),
                      style: SrType.caption.copyWith(color: pal.textSecondary),
                    ),
                  ],
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
                    '额外指令仅针对轻修模式生效',
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
                        hintText: '例：保留技术术语原文',
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

/// 快速模式 `[rectify.quick]`: the master switch first (always live),
/// then the tail — 启用修正, extra directive, its own save button —
/// disabled in place while the switch is off. The extra field further
/// disables when 启用修正 is off (the directive is unused then). No
/// thinking chips, no prefill, no threshold (ADR-0020).
class _QuickCard extends StatelessWidget {
  const _QuickCard({
    required this.enabled,
    required this.rectify,
    required this.extra,
    required this.inputsDirty,
    required this.onEnabled,
    required this.onRectify,
    required this.onSaveInputs,
  });

  final bool enabled;
  final bool rectify;
  final TextEditingController extra;
  final bool inputsDirty;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<bool> onRectify;
  final VoidCallback onSaveInputs;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '快速模式',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '开启后，按住主快捷键超过阈值松手即发送',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '启用快速模式',
                  style: SrType.caption.copyWith(color: pal.textSecondary),
                ),
              ),
              Switch(
                key: const Key('settings-rectify-quick-enabled'),
                value: enabled,
                onChanged: onEnabled,
              ),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedOpacity(
            duration: SrMotion.fade,
            curve: SrMotion.curveFade,
            opacity: enabled ? 1 : 0.5,
            child: AbsorbPointer(
              absorbing: !enabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '启用修正',
                          style: SrType.caption.copyWith(
                            color: pal.textSecondary,
                          ),
                        ),
                      ),
                      Switch(
                        key: const Key('settings-rectify-quick-rectify'),
                        value: rectify,
                        onChanged: onRectify,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '关闭后将直接发送原始语音转写',
                    style: SrType.micro.copyWith(color: pal.textTertiary),
                  ),
                  const SizedBox(height: 12),
                  AnimatedOpacity(
                    duration: SrMotion.fade,
                    curve: SrMotion.curveFade,
                    opacity: rectify ? 1 : 0.5,
                    child: AbsorbPointer(
                      absorbing: !rectify,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '快速额外指令',
                            style: SrType.caption.copyWith(
                              color: pal.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '额外指令仅在启用修正时生效',
                            style: SrType.micro.copyWith(
                              color: pal.textTertiary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          KeyedSubtree(
                            key: const Key('settings-rectify-quick-extra'),
                            child: TextField(
                              controller: extra,
                              minLines: 2,
                              maxLines: 5,
                              style: SrType.body.copyWith(
                                color: pal.textPrimary,
                              ),
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
                                hintText: '例：保留技术术语原文',
                                hintStyle: SrType.body.copyWith(
                                  color: pal.textTertiary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          SrButton(
                            key: const Key('settings-rectify-quick-save'),
                            primary: inputsDirty,
                            label: '保存快速设置',
                            onTap: inputsDirty ? onSaveInputs : null,
                          ),
                        ],
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
          '启用后占位图钉可自动预填初始值',
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
    this.enabled = true,
  });

  final String testKey;
  final String selected;
  final ValueChanged<String> onSelect;

  /// False while the connection's thinking fields are inert: the row
  /// dims in place and no chip answers a tap (ADR-0019 item 3).
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return AnimatedOpacity(
      duration: SrMotion.fade,
      curve: SrMotion.curveFade,
      opacity: enabled ? 1 : 0.5,
      child: Wrap(
        key: Key(testKey),
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final policy in rectifyPolicies)
            SrHover(
              builder: (hover) => SrPress(
                builder: (pressed) => GestureDetector(
                  onTap: enabled ? () => onSelect(policy) : null,
                  behavior: HitTestBehavior.opaque,
                  child: SrPressFill(
                    // Press darkens at pointer-down; the blue highlight
                    // follows the selection state. The scrim stays off
                    // while the row is inert — dim already says so.
                    pressed: pressed && enabled,
                    radius: BorderRadius.circular(SrRadius.control),
                    child: AnimatedContainer(
                      key: Key('$testKey:$policy'),
                      duration: SrMotion.fade,
                      curve: SrMotion.curveFade,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: pal.surfaceOverlay.withValues(
                          alpha: hover ? 1 : 0,
                        ),
                        borderRadius: BorderRadius.circular(SrRadius.control),
                        border: Border.all(color: pal.hairline),
                      ),
                      // The selection's blue rides its own alpha-only
                      // layer — a straight lerp into the neutral fill
                      // darkened the chip being deselected (26 号票 真机
                      // round).
                      foregroundDecoration: BoxDecoration(
                        color: policy == selected
                            ? pal.accentSoft
                            : pal.accentSoft.withValues(alpha: 0),
                        borderRadius: BorderRadius.circular(SrRadius.control),
                        border: Border.all(
                          color: policy == selected
                              ? pal.accent.withValues(alpha: 0.6)
                              : pal.accent.withValues(alpha: 0),
                        ),
                      ),
                      child: AnimatedDefaultTextStyle(
                        // The selection is a discrete switch: the label
                        // rides the same fade window as its box (26 号票).
                        duration: SrMotion.fade,
                        curve: SrMotion.curveFade,
                        style: SrType.caption.copyWith(
                          color: policy == selected
                              ? pal.accentText
                              : pal.textSecondary,
                          fontWeight: policy == selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                        child: Text(_policyLabels[policy] ?? policy),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
