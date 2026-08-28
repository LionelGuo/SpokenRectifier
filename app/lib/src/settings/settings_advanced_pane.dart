/// The 高级 domain: the session and insertion latency parameters,
/// read-only (ADR-0007 — the 定案: latency-class knobs stay a file
/// escape hatch). They are engine-construction-time values with no
/// runtime switch (only passage mode has one, and it already lives in
/// the quick panel), so a GUI form over them would promise the
/// hot-reload nothing delivers. The pane shows what runs right now and
/// opens the config file for the edit; changes apply on the next launch.

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard;
import '../design/tokens.dart';
import 'system_store.dart';

class SettingsAdvancedPane extends StatefulWidget {
  const SettingsAdvancedPane({super.key, required this.store});

  final SystemStore store;

  @override
  State<SettingsAdvancedPane> createState() => _SettingsAdvancedPaneState();
}

class _SettingsAdvancedPaneState extends State<SettingsAdvancedPane> {
  EngineTiming? _engine;
  InsertionTiming? _insertion;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final config = await widget.store.loadAdvanced();
      if (!mounted) return;
      setState(() {
        _engine = config.engine;
        _insertion = config.insertion;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '参数读取失败:$e');
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
    final insertion = _insertion;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('高级', style: SrType.title.copyWith(color: pal.textPrimary)),
            const SizedBox(width: 10),
            Text(
              '低频参数:此处只读,修改走配置文件',
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
        const SizedBox(height: 16),
        if (engine == null || insertion == null)
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
                  '篇章模式的开关住在快捷面板;以下参数为构建期值,重启生效',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
                const SizedBox(height: 10),
                _TimingRow(
                  key: const Key('settings-advanced-passage'),
                  label: '篇章模式',
                  value: engine.passageMode ? '开启' : '关闭',
                ),
                _TimingRow(
                  key: const Key('settings-advanced-paragraph-silence'),
                  label: '分段静音 paragraph_silence_ms',
                  value: '${engine.paragraphSilenceMs} ms',
                ),
                _TimingRow(
                  key: const Key('settings-advanced-session-end-silence'),
                  label: '自动结束静音 session_end_silence_ms',
                  value: '${engine.sessionEndSilenceMs} ms',
                ),
                _TimingRow(
                  key: const Key('settings-advanced-rectify-timeout'),
                  label: '修正超时 rectify_timeout_ms',
                  value: '${engine.rectifyTimeoutMs} ms',
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
                  '确认文本到达目标窗口的方式与节奏',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
                const SizedBox(height: 10),
                _TimingRow(
                  key: const Key('settings-advanced-insertion-mode'),
                  label: '插入方式 mode',
                  value: switch (insertion.mode) {
                    'typing' => '逐字键入',
                    _ => '剪贴板粘贴',
                  },
                ),
                _TimingRow(
                  key: const Key('settings-advanced-focus-settle'),
                  label: '焦点等待 focus_settle_ms',
                  value: '${insertion.focusSettleMs} ms',
                ),
                _TimingRow(
                  key: const Key('settings-advanced-paste-settle'),
                  label: '粘贴等待 paste_settle_ms',
                  value: '${insertion.pasteSettleMs} ms',
                ),
                _TimingRow(
                  key: const Key('settings-advanced-typing-delay'),
                  label: '键入间隔 typing_delay_ms',
                  value: '${insertion.typingDelayMs} ms',
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              SrButton(
                key: const Key('settings-advanced-open-config'),
                primary: true,
                label: '打开配置文件',
                onTap: _openConfig,
              ),
              const SizedBox(width: 10),
              Text(
                '在文件中修改并保存;下次启动生效',
                style: SrType.micro.copyWith(color: pal.textTertiary),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _TimingRow extends StatelessWidget {
  const _TimingRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: SrType.caption.copyWith(color: pal.textSecondary),
            ),
          ),
          Text(
            value,
            style: SrType.caption.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
