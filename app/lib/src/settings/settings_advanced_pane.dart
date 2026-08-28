/// The 高级 domain: the session and insertion latency parameters as an
/// editable form (ADR-0007, revised 2026-08-28 — the original read-only
/// escape hatch gave way once the runtime paths landed). Saving writes
/// the layer files (still the truth across launches) and hands the new
/// values to the live collaborators at once:
///
/// - Engine timings (paragraph_silence_ms / session_end_silence_ms /
///   rectify_timeout_ms) go through a runtime command, and each session
///   snapshots what it opens with — a save applies from the NEXT
///   session on (the SetPassageMode precedent), so a threshold never
///   shifts under a running session. The passage-mode switch stays in
///   the quick panel; the form shows it read-only.
/// - Insertion timings (mode + the three settles/delays) swap into the
///   live inserter — true real-time: the very next confirm runs with
///   them.
///
/// The config file remains the escape hatch for everything here.

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard, SrField;
import '../design/hover.dart';
import '../design/tokens.dart';
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
  String _insertionMode = 'paste';
  String? _error;
  String? _savedNote;
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
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = '参数读取失败:$e';
      });
    }
  }

  /// Adopt the file's truth into the form (the passage mode paints
  /// read-only — its switch lives in the quick panel). Each save adopts
  /// only its own half, so the other card's in-progress edits survive.
  void _adopt(EngineTiming engine, InsertionTiming insertion) {
    _adoptEngine(engine);
    _adoptInsertion(insertion);
  }

  void _adoptEngine(EngineTiming engine) {
    _engine = engine;
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
      final saved = await widget.store.saveEngineTiming(
        paragraphSilenceMs: paragraph,
        sessionEndSilenceMs: sessionEnd,
        rectifyTimeoutMs: timeout,
      );
      if (!mounted) return;
      setState(() {
        _adoptEngine(saved);
        _error = null;
        _savedNote = '会话参数已保存,下一会话生效';
      });
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '会话参数保存失败:$e');
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
      setState(() {
        _adoptInsertion(saved);
        _error = null;
        _savedNote = '插入参数已保存,即时生效';
      });
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '插入参数保存失败:$e');
    }
  }

  Future<void> _openConfig() async {
    try {
      await widget.store.openConfigFile();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '无法打开配置文件:$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final engine = _engine;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('高级', style: SrType.title.copyWith(color: pal.textPrimary)),
            const SizedBox(width: 10),
            Text(
              '低频参数:保存写入配置文件;会话参数下一会话生效,插入参数即时生效',
              style: SrType.caption.copyWith(color: pal.textTertiary),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const Key('settings-advanced-error'),
            style: SrType.caption.copyWith(color: pal.live),
          ),
        ],
        if (_savedNote != null) ...[
          const SizedBox(height: 12),
          Text(
            _savedNote!,
            key: const Key('settings-advanced-saved'),
            style: SrType.caption.copyWith(color: pal.textSecondary),
          ),
        ],
        const SizedBox(height: 16),
        if (!_loaded || engine == null)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          SrCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '会话语义 [engine]',
                  style: SrType.body.copyWith(
                    color: pal.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '运行时命令即时下发;每个会话按开启时的快照运行,下一会话生效',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '篇章模式(开关住在快捷面板)',
                        style: SrType.caption.copyWith(color: pal.textSecondary),
                      ),
                    ),
                    Text(
                      engine.passageMode ? '开启' : '关闭',
                      key: const Key('settings-advanced-passage'),
                      style: SrType.caption.copyWith(
                        color: pal.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-paragraph-silence'),
                        controller: _paragraphSilence,
                        label: '分段静音 ms',
                        monospace: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-session-end-silence'),
                        controller: _sessionEndSilence,
                        label: '自动结束静音 ms',
                        monospace: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-rectify-timeout'),
                        controller: _rectifyTimeout,
                        label: '修正超时 ms',
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
                  '文本插入 [insertion]',
                  style: SrType.body.copyWith(
                    color: pal.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '确认文本到达目标窗口的方式与节奏;保存即生效(下一次插入即用新值)',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
                const SizedBox(height: 10),
                Text('插入方式', style: SrType.micro.copyWith(color: pal.textTertiary)),
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
                        label: '焦点等待 ms',
                        monospace: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-paste-settle'),
                        controller: _pasteSettle,
                        label: '粘贴等待 ms',
                        monospace: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SrField(
                        key: const Key('settings-advanced-typing-delay'),
                        controller: _typingDelay,
                        label: '键入间隔 ms',
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
          Row(
            children: [
              SrButton(
                key: const Key('settings-advanced-open-config'),
                label: '打开配置文件',
                onTap: _openConfig,
              ),
              const SizedBox(width: 10),
              Text(
                '文件仍是真相:直接改文件后,重启或在此保存一次即可生效',
                style: SrType.micro.copyWith(color: pal.textTertiary),
              ),
            ],
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
            builder: (hover) => GestureDetector(
              onTap: () => onSelect(value),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                key: Key('settings-advanced-insertion-mode:$value'),
                duration: SrMotion.fade,
                curve: SrMotion.curveFade,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: value == selected
                      ? pal.accentSoft
                      : pal.surfaceOverlay.withValues(alpha: hover ? 1 : 0),
                  borderRadius: BorderRadius.circular(SrRadius.control),
                  border: Border.all(
                    color: value == selected
                        ? pal.accent.withValues(alpha: 0.6)
                        : pal.hairline,
                  ),
                ),
                child: Text(
                  label,
                  style: SrType.caption.copyWith(
                    color: value == selected
                        ? pal.accentText
                        : pal.textSecondary,
                    fontWeight: value == selected
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
