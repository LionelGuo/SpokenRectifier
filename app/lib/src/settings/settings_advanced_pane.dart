/// The 高级 domain: the session and insertion latency parameters as an
/// editable form (ADR-0007, revised 2026-08-28 — the original read-only
/// escape hatch gave way once the runtime paths landed). Saving writes
/// the layer files (still the truth across launches) and hands the new
/// values to the live collaborators at once:
///
/// - The engine card carries the passage-mode switch and the three
///   timings, all through runtime commands (SetPassageMode /
///   SetEngineTimings); each session snapshots what it opens with — a
///   save applies from the NEXT session on, so a threshold never shifts
///   under a running session. This switch is the persistent one (the
///   save writes `[engine]`); the quick panel keeps its instant,
///   runtime-only toggle.
/// - Insertion timings (mode + the three settles/delays) swap into the
///   live inserter — true real-time: the very next confirm runs with
///   them.
///
/// The config file remains the escape hatch for everything here.

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard, SrField, SrPressFill;
import '../design/hover.dart';
import '../design/toast.dart';
import '../design/tokens.dart';
import '../errors.dart';
import 'system_store.dart';

/// The insertion mode chips: value pair in display order.
const _insertionModes = [('paste', '剪贴板粘贴'), ('typing', '逐字键入')];

class SettingsAdvancedPane extends StatefulWidget {
  const SettingsAdvancedPane({super.key, required this.store});

  final SystemStore store;

  @override
  State<SettingsAdvancedPane> createState() => _SettingsAdvancedPaneState();
}

class _SettingsAdvancedPaneState extends State<SettingsAdvancedPane> {
  EngineTiming? _engine;
  bool _passageMode = true;
  String _insertionMode = 'paste';
  bool _loaded = false;

  late final TextEditingController _paragraphSilence = TextEditingController();
  late final TextEditingController _sessionEndSilence = TextEditingController();
  late final TextEditingController _rectifyTimeout = TextEditingController();
  late final TextEditingController _focusSettle = TextEditingController();
  late final TextEditingController _pasteSettle = TextEditingController();
  late final TextEditingController _typingDelay = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    for (final controller in [
      _paragraphSilence,
      _sessionEndSilence,
      _rectifyTimeout,
      _focusSettle,
      _pasteSettle,
      _typingDelay,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final config = await widget.store.loadAdvanced();
      if (!mounted) return;
      setState(() {
        _adopt(config.engine, config.insertion);
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loaded = true);
      logRawError('err_advanced_load', e);
      SrToast.of(context).show('参数读取失败', tone: SrToastTone.error);
    }
  }

  /// Adopt the file's truth into the form. Each save adopts only its
  /// own half, so the other card's in-progress edits survive.
  void _adopt(EngineTiming engine, InsertionTiming insertion) {
    _adoptEngine(engine);
    _adoptInsertion(insertion);
  }

  void _adoptEngine(EngineTiming engine) {
    _engine = engine;
    _passageMode = engine.passageMode;
    _paragraphSilence.text = '${engine.paragraphSilenceMs}';
    _sessionEndSilence.text = '${engine.sessionEndSilenceMs}';
    _rectifyTimeout.text = '${engine.rectifyTimeoutMs}';
  }

  void _adoptInsertion(InsertionTiming insertion) {
    _insertionMode = insertion.mode;
    _focusSettle.text = '${insertion.focusSettleMs}';
    _pasteSettle.text = '${insertion.pasteSettleMs}';
    _typingDelay.text = '${insertion.typingDelayMs}';
  }

  /// One non-negative integer field, or an error naming what's wrong.
  int _milliseconds(TextEditingController field, String label) {
    final text = field.text.trim();
    final value = int.tryParse(text);
    if (value == null || value < 0) {
      throw FormatException('$label 需为非负整数(当前:$text)');
    }
    return value;
  }

  Future<void> _saveEngine() async {
    try {
      final paragraph = _milliseconds(_paragraphSilence, '分段静音');
      final sessionEnd = _milliseconds(_sessionEndSilence, '自动结束静音');
      final timeout = _milliseconds(_rectifyTimeout, '修正超时');
      final saved = await widget.store.saveEngineSettings(
        passageMode: _passageMode,
        paragraphSilenceMs: paragraph,
        sessionEndSilenceMs: sessionEnd,
        rectifyTimeoutMs: timeout,
      );
      if (!mounted) return;
      setState(() => _adoptEngine(saved));
      SrToast.of(context).show('已保存', tone: SrToastTone.success);
    } on FormatException catch (e) {
      logRawError('err_advanced_session_format', e);
      SrToast.of(context).show('格式不正确', tone: SrToastTone.error);
    } catch (e) {
      if (!mounted) return;
      logRawError('err_advanced_session_save', e);
      SrToast.of(context).show('保存失败', tone: SrToastTone.error);
    }
  }

  Future<void> _saveInsertion() async {
    try {
      final mode = _insertionMode;
      final focus = _milliseconds(_focusSettle, '焦点等待');
      final paste = _milliseconds(_pasteSettle, '粘贴等待');
      final typing = _milliseconds(_typingDelay, '键入间隔');
      final saved = await widget.store.saveInsertionTiming(
        mode: mode,
        focusSettleMs: focus,
        pasteSettleMs: paste,
        typingDelayMs: typing,
      );
      if (!mounted) return;
      setState(() => _adoptInsertion(saved));
      SrToast.of(context).show('已保存', tone: SrToastTone.success);
    } on FormatException catch (e) {
      logRawError('err_advanced_insert_format', e);
      SrToast.of(context).show('格式不正确', tone: SrToastTone.error);
    } catch (e) {
      if (!mounted) return;
      logRawError('err_advanced_insert_save', e);
      SrToast.of(context).show('保存失败', tone: SrToastTone.error);
    }
  }

  Future<void> _openConfig() async {
    try {
      await widget.store.openConfigFile();
    } catch (e) {
      if (!mounted) return;
      logRawError('err_advanced_config_open', e);
      SrToast.of(context).show('打开失败', tone: SrToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final engine = _engine;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('高级', style: SrType.title.copyWith(color: pal.textPrimary)),
        const SizedBox(height: 16),
        if (!_loaded || engine == null)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          SrCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '会话参数',
                  style: SrType.body.copyWith(
                    color: pal.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '篇章模式',
                        style: SrType.caption.copyWith(
                          color: pal.textSecondary,
                        ),
                      ),
                    ),
                    Switch(
                      key: const Key('settings-advanced-passage'),
                      value: _passageMode,
                      onChanged: (on) => setState(() => _passageMode = on),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '讲话停顿时不结束会话，仅进行分段',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-paragraph-silence'),
                        controller: _paragraphSilence,
                        label: '分段静音（ms）',
                        monospace: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-session-end-silence'),
                        controller: _sessionEndSilence,
                        label: '自动结束静音（ms）',
                        monospace: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-rectify-timeout'),
                        controller: _rectifyTimeout,
                        label: '修正超时（ms）',
                        monospace: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SrButton(
                  key: const Key('settings-advanced-engine-save'),
                  primary: true,
                  label: '保存会话参数',
                  onTap: _saveEngine,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SrCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '文本插入',
                  style: SrType.body.copyWith(
                    color: pal.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '确认文本到达目标窗口的方式与节奏',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
                const SizedBox(height: 10),
                Text(
                  '插入方式',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
                const SizedBox(height: 6),
                _ModeChips(
                  selected: _insertionMode,
                  onSelect: (mode) => setState(() => _insertionMode = mode),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-focus-settle'),
                        controller: _focusSettle,
                        label: '焦点等待（ms）',
                        monospace: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-paste-settle'),
                        controller: _pasteSettle,
                        label: '粘贴等待（ms）',
                        monospace: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-typing-delay'),
                        controller: _typingDelay,
                        label: '键入间隔（ms）',
                        monospace: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SrButton(
                  key: const Key('settings-advanced-insertion-save'),
                  primary: true,
                  label: '保存插入参数',
                  onTap: _saveInsertion,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SrButton(
            key: const Key('settings-advanced-open-config'),
            label: '打开配置文件',
            onTap: _openConfig,
          ),
        ],
      ],
    );
  }
}

/// The insertion-mode chip pair (the connection pane's vendor-chip
/// recipe).
class _ModeChips extends StatelessWidget {
  const _ModeChips({required this.selected, required this.onSelect});

  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Wrap(
      key: const Key('settings-advanced-insertion-modes'),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (value, label) in _insertionModes)
          SrHover(
            builder: (hover) => SrPress(
              builder: (pressed) => GestureDetector(
                onTap: () => onSelect(value),
                behavior: HitTestBehavior.opaque,
                child: SrPressFill(
                  // Press darkens at pointer-down; the highlight follows
                  // the selection state (26 号票 真机 round).
                  pressed: pressed,
                  radius: BorderRadius.circular(SrRadius.control),
                  child: AnimatedContainer(
                    key: Key('settings-advanced-insertion-mode:$value'),
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
                    // The selection's blue rides its own alpha-only layer
                    // — a straight lerp into the neutral fill darkened
                    // the chip being deselected (26 号票 真机 round).
                    foregroundDecoration: BoxDecoration(
                      color: value == selected
                          ? pal.accentSoft
                          : pal.accentSoft.withValues(alpha: 0),
                      borderRadius: BorderRadius.circular(SrRadius.control),
                      border: Border.all(
                        color: value == selected
                            ? pal.accent.withValues(alpha: 0.6)
                            : pal.accent.withValues(alpha: 0),
                      ),
                    ),
                    child: AnimatedDefaultTextStyle(
                      // The selection is a discrete switch: the label rides
                      // the same fade window as its box (26 号票).
                      duration: SrMotion.fade,
                      curve: SrMotion.curveFade,
                      style: SrType.caption.copyWith(
                        color: value == selected
                            ? pal.accentText
                            : pal.textSecondary,
                        fontWeight: value == selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                      child: Text(label),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
