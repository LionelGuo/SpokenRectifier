/// The 模型与连接 domain: the effective `[llm]` and `[asr]` sections as
/// editable forms. One save per card writes the editor's whole model
/// through the bridge (section-preserving into the layer files) and
/// repaints from the re-read view — the file's truth, not the ask. The
/// api_key never paints: only its placement does, the field writes a
/// replacement (only ever into the git-ignored local layer), and the
/// clear button removes it (falling back to the environment variable).
/// The engine adopts the config at its creation, so changes apply from
/// the next launch (the fidelity-eval run is the one place that adopts
/// them at once, building its own engine per run).

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard;
import '../design/hover.dart';
import '../design/tokens.dart';
import 'connection_store.dart';

/// The vendor chips' labels, in display order.
const _vendors = ['deepseek', 'volcengine', 'qwen', 'openai'];

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

  /// Adopt the file's truth into the form (the key fields always clear:
  /// the stored key never echoes back).
  void _adopt(LlmConnection llm, AsrConnection asr) {
    _llmVendor = llm.vendor;
    _llmBaseUrl.text = llm.baseUrl;
    _llmModel.text = llm.model;
    _llmKey.clear();
    _llmKeyInfo = llm.key;
    _asrModel.text = asr.model;
    _asrLanguage.text = asr.language;
    _asrRegion.text = asr.region;
    _asrWorkspace.text = asr.workspaceId ?? '';
    _asrBaseUrl.text = asr.baseUrl ?? '';
    _asrKey.clear();
    _asrKeyInfo = asr.key;
    _asrEndpoint = asr.endpoint;
  }

  ApiKeyEdit _keyEdit(TextEditingController field) {
    final typed = field.text.trim();
    return typed.isEmpty ? const ApiKeyKeep() : ApiKeySet(typed);
  }

  /// The clear button's destructive path: confirm once, then save with
  /// the key edit forced to Clear — a cleared field alone would read as
  /// Keep, so the override is explicit.
  Future<void> _clearKey(
    TextEditingController field,
    Future<void> Function({ApiKeyEdit keyOverride}) save,
  ) async {
    final section = field == _llmKey ? '修正模型' : '语音识别';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ConfirmClearDialog(section: section),
    );
    if (confirmed != true) return;
    field.clear();
    await save(keyOverride: const ApiKeyClear());
  }

  Future<void> _saveLlm({ApiKeyEdit? keyOverride}) async {
    try {
      final saved = await widget.store.saveLlm(
        vendor: _llmVendor,
        baseUrl: _llmBaseUrl.text,
        model: _llmModel.text,
        apiKey: keyOverride ?? _keyEdit(_llmKey),
      );
      if (!mounted) return;
      setState(() {
        _llmVendor = saved.vendor;
        _llmBaseUrl.text = saved.baseUrl;
        _llmModel.text = saved.model;
        _llmKey.clear();
        _llmKeyInfo = saved.key;
        _error = null;
        _savedNote = '修正模型已保存';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '修正模型保存失败:$e');
    }
  }

  Future<void> _saveAsr({ApiKeyEdit? keyOverride}) async {
    try {
      final saved = await widget.store.saveAsr(
        model: _asrModel.text,
        language: _asrLanguage.text,
        workspaceId: _asrWorkspace.text.trim().isEmpty
            ? null
            : _asrWorkspace.text,
        region: _asrRegion.text,
        baseUrl: _asrBaseUrl.text.trim().isEmpty ? null : _asrBaseUrl.text,
        apiKey: keyOverride ?? _keyEdit(_asrKey),
      );
      if (!mounted) return;
      setState(() {
        _asrModel.text = saved.model;
        _asrLanguage.text = saved.language;
        _asrRegion.text = saved.region;
        _asrWorkspace.text = saved.workspaceId ?? '';
        _asrBaseUrl.text = saved.baseUrl ?? '';
        _asrEndpoint = saved.endpoint;
        _asrKey.clear();
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
            Text(
              '模型与连接',
              style: SrType.title.copyWith(color: pal.textPrimary),
            ),
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
            onVendor: (vendor) => setState(() => _llmVendor = vendor),
            baseUrl: _llmBaseUrl,
            model: _llmModel,
            keyField: _llmKey,
            keyInfo: _llmKeyInfo,
            onSave: _saveLlm,
            onClearKey: () => _clearKey(_llmKey, _saveLlm),
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
            onClearKey: () => _clearKey(_asrKey, _saveAsr),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Field recipes
// ---------------------------------------------------------------------------

/// A labeled single-line field — the quick panel's term-row recipe: the
/// box is drawn by the container, the TextField inside is undecorated.
class _Field extends StatelessWidget {
  const _Field({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.monospace = false,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: SrType.micro.copyWith(color: pal.textTertiary)),
        const SizedBox(height: 4),
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: pal.surfaceOverlay,
            borderRadius: BorderRadius.circular(SrRadius.control),
            border: Border.all(color: pal.hairline),
          ),
          alignment: Alignment.centerLeft,
          child: TextField(
            key: fieldKey,
            controller: controller,
            obscureText: obscure,
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontFamily: monospace ? 'monospace' : null,
            ),
            cursorColor: pal.accent,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
              enabledBorder: InputBorder.none,
              hintText: hint,
              hintStyle: SrType.body.copyWith(color: pal.textTertiary),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }
}

/// The key block: the placement caption (never the key), a write-only
/// field, and the destructive clear. [id] names the section ('llm' /
/// 'asr') for the block's test keys.
class _KeyBlock extends StatelessWidget {
  const _KeyBlock({
    required this.id,
    required this.field,
    required this.keyInfo,
    required this.onClear,
  });

  final String id;
  final TextEditingController field;
  final KeyInfo keyInfo;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('API 密钥', style: SrType.micro.copyWith(color: pal.textTertiary)),
        const SizedBox(height: 4),
        Text(
          '${keyInfo.label};密钥只存于本机 local 文件',
          key: Key('settings-conn-key-status:$id'),
          style: SrType.micro.copyWith(color: pal.textSecondary),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _Field(
                fieldKey: Key('settings-conn-$id-key'),
                controller: field,
                label: '',
                hint: '留空保持不变;输入即替换',
                obscure: true,
                monospace: true,
              ),
            ),
            const SizedBox(width: 8),
            SrButton(
              key: Key('settings-conn-key-clear:$id'),
              label: '清除',
              onTap: onClear,
            ),
          ],
        ),
      ],
    );
  }
}

/// The vendor chip set (the history pane's retention-chip recipe).
class _VendorChips extends StatelessWidget {
  const _VendorChips({
    required this.selected,
    required this.onSelect,
  });

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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                    color: vendor == selected ? pal.accentText : pal.textSecondary,
                    fontWeight: vendor == selected ? FontWeight.w600 : FontWeight.w400,
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
    required this.onClearKey,
  });

  final String vendor;
  final ValueChanged<String> onVendor;
  final TextEditingController baseUrl;
  final TextEditingController model;
  final TextEditingController keyField;
  final KeyInfo keyInfo;
  final VoidCallback onSave;
  final VoidCallback onClearKey;

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
          Text('服务商', style: SrType.micro.copyWith(color: pal.textTertiary)),
          const SizedBox(height: 6),
          _VendorChips(selected: vendor, onSelect: onVendor),
          const SizedBox(height: 12),
          _Field(
            fieldKey: const Key('settings-conn-llm-baseurl'),
            controller: baseUrl,
            label: '端点 base_url',
            monospace: true,
          ),
          const SizedBox(height: 12),
          _Field(
            fieldKey: const Key('settings-conn-llm-model'),
            controller: model,
            label: '模型',
            monospace: true,
          ),
          const SizedBox(height: 12),
          _KeyBlock(
            id: 'llm',
            field: keyField,
            keyInfo: keyInfo,
            onClear: onClearKey,
          ),
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
    required this.onClearKey,
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
  final VoidCallback onClearKey;

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
          _Field(
            fieldKey: const Key('settings-conn-asr-model'),
            controller: model,
            label: '模型',
            monospace: true,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _Field(
                  fieldKey: const Key('settings-conn-asr-language'),
                  controller: language,
                  label: '识别语言',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Field(
                  fieldKey: const Key('settings-conn-asr-region'),
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
                child: _Field(
                  fieldKey: const Key('settings-conn-asr-workspace'),
                  controller: workspace,
                  label: 'workspace_id(可选)',
                  monospace: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Field(
                  fieldKey: const Key('settings-conn-asr-baseurl'),
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
          _KeyBlock(
            id: 'asr',
            field: keyField,
            keyInfo: keyInfo,
            onClear: onClearKey,
          ),
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
