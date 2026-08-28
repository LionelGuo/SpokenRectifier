/// The 模型与连接 domain: the effective `[llm]` and `[asr]` sections as
/// editable forms. One save per card writes the editor's whole model
/// through the bridge (section-preserving into the layer files) and
/// repaints from the re-read view — the file's truth, not the ask.
///
/// The vendor chips are PRESETS: clicking one adopts that vendor's
/// default base_url (unconditionally — an endpoint switch is the point
/// of the click) and its default model only when the current name is
/// empty or happens to be some vendor's default, so a customized model
/// never gets clobbered. The chip also selects the dialect (vendor).
///
/// The key block is DIFF-ECHO (ADR-0008, 2026-08-28 revision): a key
/// stored in the local file paints in the field masked by default (the
/// eye toggles plain text), and a save diffs the field against the
/// loaded value — unchanged keeps, a change replaces, and emptying a
/// saved key asks one confirm then clears (no standalone clear button).
/// An environment key never echoes a value: the field starts empty, the
/// status line names the variable, and typing would store a new local
/// key. The engine adopts the config at its creation, so changes apply
/// from the next launch (the fidelity-eval run is the one place that
/// adopts them at once, building its own engine per run).

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard, SrField;
import '../design/hover.dart';
import '../design/tokens.dart';
import 'connection_store.dart';

/// The vendor chips' labels, in display order.
const _vendors = ['deepseek', 'volcengine', 'qwen', 'openai'];

/// What one vendor chip prefills: the endpoint to switch to, and the
/// model to adopt only when the field is empty or holds some vendor's
/// default.
const _presets = <String, ({String baseUrl, String model})>{
  'deepseek': (baseUrl: 'https://api.deepseek.com', model: 'deepseek-v4-flash'),
  'volcengine': (
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    model: 'doubao-seed-2.0-lite',
  ),
  'qwen': (
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen3.5-flash',
  ),
  'openai': (baseUrl: 'https://api.openai.com/v1', model: 'gpt-5.2'),
};

/// The model names any preset would have written — the values a chip
/// click may freely replace (a customized name is never one of them).
bool _isSomeVendorDefault(String model) =>
    _presets.values.any((preset) => preset.model == model);

class SettingsConnectionPane extends StatefulWidget {
  const SettingsConnectionPane({super.key, required this.store});

  final ConnectionStore store;

  @override
  State<SettingsConnectionPane> createState() => _SettingsConnectionPaneState();
}

class _SettingsConnectionPaneState extends State<SettingsConnectionPane> {
  String? _error;
  String? _savedNote;
  bool _loaded = false;

  // LLM fields.
  late final TextEditingController _llmBaseUrl = TextEditingController();
  late final TextEditingController _llmModel = TextEditingController();
  late final TextEditingController _llmKey = TextEditingController();
  String _llmVendor = 'deepseek';
  KeyInfo _llmKeyInfo = const KeyInfo(status: KeyPlacement.unset);

  // ASR fields.
  late final TextEditingController _asrModel = TextEditingController();
  late final TextEditingController _asrLanguage = TextEditingController();
  late final TextEditingController _asrRegion = TextEditingController();
  late final TextEditingController _asrWorkspace = TextEditingController();
  late final TextEditingController _asrBaseUrl = TextEditingController();
  late final TextEditingController _asrKey = TextEditingController();
  String _asrEndpoint = '';
  KeyInfo _asrKeyInfo = const KeyInfo(status: KeyPlacement.unset);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    for (final controller in [
      _llmBaseUrl,
      _llmModel,
      _llmKey,
      _asrModel,
      _asrLanguage,
      _asrRegion,
      _asrWorkspace,
      _asrBaseUrl,
      _asrKey,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final config = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _adopt(config.llm, config.asr);
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = '连接配置读取失败:$e';
      });
    }
  }

  /// Adopt the file's truth into the form. A local-file key echoes into
  /// the field (the diff base); an env or unset key leaves it empty.
  void _adopt(LlmConnection llm, AsrConnection asr) {
    _llmVendor = llm.vendor;
    _llmBaseUrl.text = llm.baseUrl;
    _llmModel.text = llm.model;
    _llmKey.text = llm.key.storedKey ?? '';
    _llmKeyInfo = llm.key;
    _asrModel.text = asr.model;
    _asrLanguage.text = asr.language;
    _asrRegion.text = asr.region;
    _asrWorkspace.text = asr.workspaceId ?? '';
    _asrBaseUrl.text = asr.baseUrl ?? '';
    _asrKey.text = asr.key.storedKey ?? '';
    _asrKeyInfo = asr.key;
    _asrEndpoint = asr.endpoint;
  }

  /// A chip click: the preset's base_url unconditionally, its model only
  /// when the current name is empty or some vendor's default.
  void _applyVendorPreset(String vendor) {
    final preset = _presets[vendor]!;
    setState(() {
      _llmVendor = vendor;
      _llmBaseUrl.text = preset.baseUrl;
      if (_llmModel.text.trim().isEmpty || _isSomeVendorDefault(_llmModel.text.trim())) {
        _llmModel.text = preset.model;
      }
    });
  }

  /// Diff the key field against the loaded value. `null` aborts the
  /// whole save: the user emptied a saved key and declined the confirm.
  Future<ApiKeyEdit?> _keyDiff(
    TextEditingController field,
    KeyInfo info,
    String section,
  ) async {
    final typed = field.text.trim();
    final loaded = info.storedKey ?? '';
    if (typed == loaded) return const ApiKeyKeep();
    if (typed.isEmpty && loaded.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => _ConfirmClearDialog(section: section),
      );
      if (confirmed != true) return null;
      return const ApiKeyClear();
    }
    return ApiKeySet(typed);
  }

  Future<void> _saveLlm() async {
    final key = await _keyDiff(_llmKey, _llmKeyInfo, '修正模型');
    if (key == null) return;
    try {
      final saved = await widget.store.saveLlm(
        vendor: _llmVendor,
        baseUrl: _llmBaseUrl.text,
        model: _llmModel.text,
        apiKey: key,
      );
      if (!mounted) return;
      setState(() {
        _llmVendor = saved.vendor;
        _llmBaseUrl.text = saved.baseUrl;
        _llmModel.text = saved.model;
        _llmKey.text = saved.key.storedKey ?? '';
        _llmKeyInfo = saved.key;
        _error = null;
        _savedNote = '修正模型已保存';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '修正模型保存失败:$e');
    }
  }

  Future<void> _saveAsr() async {
    final key = await _keyDiff(_asrKey, _asrKeyInfo, '语音识别');
    if (key == null) return;
    try {
      final saved = await widget.store.saveAsr(
        model: _asrModel.text,
        language: _asrLanguage.text,
        workspaceId: _asrWorkspace.text.trim().isEmpty
            ? null
            : _asrWorkspace.text,
        region: _asrRegion.text,
        baseUrl: _asrBaseUrl.text.trim().isEmpty ? null : _asrBaseUrl.text,
        apiKey: key,
      );
      if (!mounted) return;
      setState(() {
        _asrModel.text = saved.model;
        _asrLanguage.text = saved.language;
        _asrRegion.text = saved.region;
        _asrWorkspace.text = saved.workspaceId ?? '';
        _asrBaseUrl.text = saved.baseUrl ?? '';
        _asrEndpoint = saved.endpoint;
        _asrKey.text = saved.key.storedKey ?? '';
        _asrKeyInfo = saved.key;
        _error = null;
        _savedNote = '语音识别已保存';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '语音识别保存失败:$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('模型与连接', style: SrType.title.copyWith(color: pal.textPrimary)),
            const SizedBox(width: 10),
            Text(
              '保存后写入配置文件,下次启动生效',
              key: const Key('settings-conn-restart-note'),
              style: SrType.caption.copyWith(color: pal.textTertiary),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const Key('settings-conn-error'),
            style: SrType.caption.copyWith(color: pal.live),
          ),
        ],
        if (_savedNote != null) ...[
          const SizedBox(height: 12),
          Text(
            _savedNote!,
            key: const Key('settings-conn-saved'),
            style: SrType.caption.copyWith(color: pal.textSecondary),
          ),
        ],
        const SizedBox(height: 16),
        if (!_loaded)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          _LlmCard(
            vendor: _llmVendor,
            onVendor: _applyVendorPreset,
            baseUrl: _llmBaseUrl,
            model: _llmModel,
            keyField: _llmKey,
            keyInfo: _llmKeyInfo,
            onSave: _saveLlm,
          ),
          const SizedBox(height: 16),
          _AsrCard(
            model: _asrModel,
            language: _asrLanguage,
            region: _asrRegion,
            workspace: _asrWorkspace,
            baseUrl: _asrBaseUrl,
            keyField: _asrKey,
            keyInfo: _asrKeyInfo,
            endpoint: _asrEndpoint,
            onSave: _saveAsr,
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Field recipes
// ---------------------------------------------------------------------------

/// The key block (ADR-0008, 2026-08-28 revision): the placement caption,
/// the diff-echo field (a local-file key paints masked; the eye toggles
/// plain text), and the hint that emptying a saved key clears it on
/// save. [id] names the section ('llm' / 'asr') for the block's test
/// keys.
class _KeyBlock extends StatefulWidget {
  const _KeyBlock({
    required this.id,
    required this.field,
    required this.keyInfo,
  });

  final String id;
  final TextEditingController field;
  final KeyInfo keyInfo;

  @override
  State<_KeyBlock> createState() => _KeyBlockState();
}

class _KeyBlockState extends State<_KeyBlock> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final fromEnv = widget.keyInfo.status == KeyPlacement.fromEnv;
    // An env key has no stored local value, so the 「只存于本机」 tail
    // would mislead; its status line says what typing does instead
    // (ADR-0008's exact wording).
    final status = fromEnv
        ? '${widget.keyInfo.label},输入即另存本机'
        : '${widget.keyInfo.label};密钥只存于本机 local 文件';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('API 密钥', style: SrType.micro.copyWith(color: pal.textTertiary)),
        const SizedBox(height: 4),
        Text(
          status,
          key: Key('settings-conn-key-status:${widget.id}'),
          style: SrType.micro.copyWith(color: pal.textSecondary),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SrField(
                key: Key('settings-conn-${widget.id}-key'),
                controller: widget.field,
                // No label: an empty one still reserves its line and
                // sinks the field below the eye icon's row center.
                hint: fromEnv ? '留空沿用环境变量' : '清空并保存即删除本机密钥',
                obscure: _obscured,
                monospace: true,
              ),
            ),
            const SizedBox(width: 8),
            SrHover(
              builder: (hover) => Tooltip(
                message: _obscured ? '显示密钥' : '隐藏密钥',
                waitDuration: SrMotion.tooltipWait,
                child: GestureDetector(
                  key: Key('settings-conn-key-eye:${widget.id}'),
                  onTap: () => setState(() => _obscured = !_obscured),
                  behavior: HitTestBehavior.opaque,
                  child: Icon(
                    _obscured
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 15,
                    color: hover ? pal.accentText : pal.textTertiary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The vendor chip set (the history pane's retention-chip recipe). The
/// chips are presets: the selected look marks the vendor whose dialect
/// the endpoint speaks.
class _VendorChips extends StatelessWidget {
  const _VendorChips({required this.selected, required this.onSelect});

  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Wrap(
      key: const Key('settings-conn-llm-vendors'),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final vendor in _vendors)
          SrHover(
            builder: (hover) => GestureDetector(
              onTap: () => onSelect(vendor),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                key: Key('settings-conn-llm-vendor:$vendor'),
                duration: SrMotion.fade,
                curve: SrMotion.curveFade,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: vendor == selected
                      ? pal.accentSoft
                      : pal.surfaceOverlay.withValues(alpha: hover ? 1 : 0),
                  borderRadius: BorderRadius.circular(SrRadius.control),
                  border: Border.all(
                    color: vendor == selected
                        ? pal.accent.withValues(alpha: 0.6)
                        : pal.hairline,
                  ),
                ),
                child: Text(
                  vendor,
                  style: SrType.caption.copyWith(
                    color: vendor == selected
                        ? pal.accentText
                        : pal.textSecondary,
                    fontWeight: vendor == selected
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

// ---------------------------------------------------------------------------
// The two cards
// ---------------------------------------------------------------------------

class _LlmCard extends StatelessWidget {
  const _LlmCard({
    required this.vendor,
    required this.onVendor,
    required this.baseUrl,
    required this.model,
    required this.keyField,
    required this.keyInfo,
    required this.onSave,
  });

  final String vendor;
  final ValueChanged<String> onVendor;
  final TextEditingController baseUrl;
  final TextEditingController model;
  final TextEditingController keyField;
  final KeyInfo keyInfo;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '修正模型',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '任意 OpenAI 兼容端点;轻修与全量修正共用同一模型',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 14),
          Text('服务商(点击预填端点)', style: SrType.micro.copyWith(color: pal.textTertiary)),
          const SizedBox(height: 6),
          _VendorChips(selected: vendor, onSelect: onVendor),
          const SizedBox(height: 12),
          SrField(
            key: const Key('settings-conn-llm-baseurl'),
            controller: baseUrl,
            label: '端点 base_url',
            monospace: true,
          ),
          const SizedBox(height: 12),
          SrField(
            key: const Key('settings-conn-llm-model'),
            controller: model,
            label: '模型',
            monospace: true,
          ),
          const SizedBox(height: 12),
          _KeyBlock(id: 'llm', field: keyField, keyInfo: keyInfo),
          const SizedBox(height: 14),
          SrButton(
            key: const Key('settings-conn-llm-save'),
            primary: true,
            label: '保存修正模型',
            onTap: onSave,
          ),
        ],
      ),
    );
  }
}

class _AsrCard extends StatelessWidget {
  const _AsrCard({
    required this.model,
    required this.language,
    required this.region,
    required this.workspace,
    required this.baseUrl,
    required this.keyField,
    required this.keyInfo,
    required this.endpoint,
    required this.onSave,
  });

  final TextEditingController model;
  final TextEditingController language;
  final TextEditingController region;
  final TextEditingController workspace;
  final TextEditingController baseUrl;
  final TextEditingController keyField;
  final KeyInfo keyInfo;
  final String endpoint;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '语音识别 · 阿里云',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '无密钥时仅保留麦克风语义(说话状态与静音),不做云端转写',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 14),
          SrField(
            key: const Key('settings-conn-asr-model'),
            controller: model,
            label: '模型',
            monospace: true,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: SrField(
                  key: const Key('settings-conn-asr-language'),
                  controller: language,
                  label: '识别语言',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SrField(
                  key: const Key('settings-conn-asr-region'),
                  controller: region,
                  label: '区域',
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
                  key: const Key('settings-conn-asr-workspace'),
                  controller: workspace,
                  label: 'workspace_id(可选)',
                  monospace: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SrField(
                  key: const Key('settings-conn-asr-baseurl'),
                  controller: baseUrl,
                  label: 'base_url 全量覆盖(可选)',
                  monospace: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '当前端点:$endpoint',
            key: const Key('settings-conn-asr-endpoint'),
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 12),
          _KeyBlock(id: 'asr', field: keyField, keyInfo: keyInfo),
          const SizedBox(height: 14),
          SrButton(
            key: const Key('settings-conn-asr-save'),
            primary: true,
            label: '保存语音识别',
            onTap: onSave,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The clear-key confirm (the history pane's dialog recipe)
// ---------------------------------------------------------------------------

class _ConfirmClearDialog extends StatelessWidget {
  const _ConfirmClearDialog({required this.section});

  /// Which section's key is going ('修正模型' / '语音识别').
  final String section;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '清除密钥?',
                style: SrType.title.copyWith(color: pal.textPrimary),
              ),
              const SizedBox(height: 12),
              Text(
                '将删除 $section 已保存的 API 密钥(仅本机 local 文件);'
                '未配置环境变量时该服务将停用。',
                style: SrType.caption.copyWith(color: pal.textSecondary),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SrButton(
                    key: const Key('settings-conn-clear-cancel'),
                    label: '取消',
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  SrButton(
                    key: const Key('settings-conn-clear-ok'),
                    label: '清除',
                    primary: true,
                    onTap: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
