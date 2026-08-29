/// The 模型与连接 domain: the effective `[llm]` and `[asr]` sections as
/// editable forms. One save per card writes the editor's whole model
/// through the bridge (section-preserving into the layer files) and
/// repaints from the re-read view — the file's truth, not the ask.
///
/// The LLM vendor chips are PRESETS: clicking one adopts that vendor's
/// default base_url (unconditionally — an endpoint switch is the point
/// of the click) and its default model only when the current name is
/// empty or happens to be some vendor's default, so a customized model
/// never gets clobbered. The chip also selects the dialect (vendor).
///
/// The ASR card is isomorphic to the `[asr]` schema (ADR-0009): the
/// provider chip switches which vendor sub-section paints, while the
/// common segment (provider / model / language / base_url / the
/// Bearer-family key) stays constant. Switching the provider prefills
/// the model the same preset way and NEVER clears another vendor's
/// fields — they ride along untouched, hidden but preserved.
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

/// The LLM vendor chips' labels, in display order.
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

/// The ASR provider chips' labels, in display order (the ADR-0009
/// enum; every sub-section paints, adapter or not — the caption below
/// the chips says which are live).
const _asrProviders = ['aliyun', 'volcengine', 'tencent', 'openai', 'azure'];

/// Each ASR provider's default model — what a chip click prefills when
/// the field is empty or holds some provider's default.
const _asrModelPresets = <String, String>{
  'aliyun': 'qwen3-asr-flash-realtime',
  'volcengine': 'volc.seedasr.sauc.duration',
  'tencent': '16k_zh_en',
  'openai': 'gpt-4o-transcribe',
  'azure': 'azure-speech',
};

bool _isSomeAsrDefault(String model) =>
    _asrModelPresets.values.contains(model);

/// The providers whose cloud adapter is built: everything else carries
/// fields in the schema but cannot stream yet.
const _asrAdapted = {'aliyun', 'volcengine'};

/// The providers that read the common Bearer key pair (the others keep
/// their credentials in their own sub-section).
const _asrBearerFamily = {'aliyun', 'openai', 'azure'};

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

  // LLM fields. The key block is one controller per vendor: a key
  // authenticates exactly one vendor, so each chip binds its own pair
  // and a switch never carries (or loses) another vendor's key
  // (ADR-0011) — same rule as the ASR card's vendor sub-fields.
  late final TextEditingController _llmBaseUrl = TextEditingController();
  late final TextEditingController _llmModel = TextEditingController();
  static const _llmVendors = ['deepseek', 'volcengine', 'qwen', 'openai'];
  final Map<String, TextEditingController> _llmKeys = {
    for (final vendor in _llmVendors) vendor: TextEditingController(),
  };
  final Map<String, KeyInfo> _llmKeyInfos = {
    for (final vendor in _llmVendors) vendor: const KeyInfo(status: KeyPlacement.unset),
  };
  String _llmVendor = 'deepseek';
  KeyInfo get _llmKeyInfo => _llmKeyInfos[_llmVendor] ?? const KeyInfo(status: KeyPlacement.unset);
  TextEditingController get _llmKey => _llmKeys[_llmVendor]!;

  // ASR fields: the common segment, then one group per vendor
  // sub-section — a provider switch repaints, never clears.
  late final TextEditingController _asrModel = TextEditingController();
  late final TextEditingController _asrLanguage = TextEditingController();
  late final TextEditingController _asrBaseUrl = TextEditingController();
  late final TextEditingController _asrKey = TextEditingController();
  String _asrProvider = 'aliyun';
  KeyInfo _asrKeyInfo = const KeyInfo(status: KeyPlacement.unset);
  String? _asrEndpoint;

  late final TextEditingController _asrWorkspace = TextEditingController();
  late final TextEditingController _asrRegion = TextEditingController();

  late final TextEditingController _asrVolcAppId = TextEditingController();
  late final TextEditingController _asrVolcResourceId = TextEditingController();
  late final TextEditingController _asrVolcAccessKey = TextEditingController();
  KeyInfo _asrVolcKeyInfo = const KeyInfo(status: KeyPlacement.unset);

  late final TextEditingController _asrTencentAppId = TextEditingController();
  late final TextEditingController _asrTencentSecretId = TextEditingController();
  late final TextEditingController _asrTencentSecretKey = TextEditingController();
  KeyInfo _asrTencentIdInfo = const KeyInfo(status: KeyPlacement.unset);
  KeyInfo _asrTencentKeyInfo = const KeyInfo(status: KeyPlacement.unset);

  late final TextEditingController _asrAzureRegion = TextEditingController();
  late final TextEditingController _asrAzureEndpointId = TextEditingController();

  /// Latest-wins token for the endpoint preview: a slower earlier
  /// refresh must not overwrite a newer one.
  int _asrEndpointToken = 0;

  /// Recompute the endpoint preview from the form as it stands — every
  /// edit to the fields the URL derives from and every provider chip
  /// click, never only on save.
  void _refreshAsrEndpoint() {
    final token = ++_asrEndpointToken;
    widget.store
        .asrEndpoint(
          provider: _asrProvider,
          model: _asrModel.text,
          baseUrl: _asrBaseUrl.text,
          workspaceId: _asrWorkspace.text,
          region: _asrRegion.text,
        )
        .then((endpoint) {
          if (!mounted || token != _asrEndpointToken) return;
          setState(() => _asrEndpoint = endpoint);
        })
        .catchError((Object _) {}); // keep the last good preview
  }

  @override
  void initState() {
    super.initState();
    for (final controller in [_asrModel, _asrBaseUrl, _asrWorkspace, _asrRegion]) {
      controller.addListener(_refreshAsrEndpoint);
    }
    _reload();
  }

  @override
  void dispose() {
    for (final controller in [
      _llmBaseUrl,
      _llmModel,
      ..._llmKeys.values,
      _asrModel,
      _asrLanguage,
      _asrBaseUrl,
      _asrKey,
      _asrWorkspace,
      _asrRegion,
      _asrVolcAppId,
      _asrVolcResourceId,
      _asrVolcAccessKey,
      _asrTencentAppId,
      _asrTencentSecretId,
      _asrTencentSecretKey,
      _asrAzureRegion,
      _asrAzureEndpointId,
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

  /// Adopt the LLM view's truth into the form: the endpoint fields, and
  /// every vendor's key pair (a local-file key echoes into that vendor's
  /// field — the diff base; an env or unset key leaves it empty).
  void _adoptLlm(LlmConnection llm) {
    _llmVendor = llm.vendor;
    _llmBaseUrl.text = llm.baseUrl;
    _llmModel.text = llm.model;
    for (final entry in llm.keys.entries) {
      final controller = _llmKeys[entry.key];
      if (controller == null) continue;
      controller.text = entry.value.storedKey ?? '';
      _llmKeyInfos[entry.key] = entry.value;
    }
  }

  /// Adopt the file's truth into the form. A local-file key echoes into
  /// the field (the diff base); an env or unset key leaves it empty.
  void _adopt(LlmConnection llm, AsrConnection asr) {
    _adoptLlm(llm);

    _asrProvider = asr.provider;
    _asrModel.text = asr.model;
    _asrLanguage.text = asr.language;
    _asrBaseUrl.text = asr.baseUrl ?? '';
    _asrKey.text = asr.key.storedKey ?? '';
    _asrKeyInfo = asr.key;
    _asrEndpoint = asr.endpoint;

    _asrWorkspace.text = asr.aliyun.workspaceId ?? '';
    _asrRegion.text = asr.aliyun.region;

    _asrVolcAppId.text = asr.volcengine.appId ?? '';
    _asrVolcResourceId.text = asr.volcengine.resourceId;
    _asrVolcAccessKey.text = asr.volcengine.accessKey.storedKey ?? '';
    _asrVolcKeyInfo = asr.volcengine.accessKey;

    _asrTencentAppId.text = asr.tencent.appId ?? '';
    _asrTencentSecretId.text = asr.tencent.secretId.storedKey ?? '';
    _asrTencentIdInfo = asr.tencent.secretId;
    _asrTencentSecretKey.text = asr.tencent.secretKey.storedKey ?? '';
    _asrTencentKeyInfo = asr.tencent.secretKey;

    _asrAzureRegion.text = asr.azure.region ?? '';
    _asrAzureEndpointId.text = asr.azure.endpointId ?? '';
  }

  /// A chip click: the preset's base_url unconditionally, its model only
  /// when the current name is empty or some vendor's default.
  void _applyVendorPreset(String vendor) {
    final preset = _presets[vendor]!;
    setState(() {
      _llmVendor = vendor;
      // The key block re-binds to this vendor's own controller on the
      // rebuild — another vendor's key never carries across (ADR-0011).
      _llmBaseUrl.text = preset.baseUrl;
      if (_llmModel.text.trim().isEmpty || _isSomeVendorDefault(_llmModel.text.trim())) {
        _llmModel.text = preset.model;
      }
    });
  }

  /// An ASR provider chip click: switch the painted sub-section and
  /// prefill the model when it is empty or holds some provider's
  /// default. Another vendor's fields are NOT cleared — they ride
  /// along, hidden but preserved (ADR-0009).
  void _applyAsrProvider(String provider) {
    setState(() {
      _asrProvider = provider;
      if (_asrModel.text.trim().isEmpty || _isSomeAsrDefault(_asrModel.text.trim())) {
        _asrModel.text = _asrModelPresets[provider]!;
      }
    });
    // The preview follows the chip immediately (the model prefill above
    // already refreshed it when it replaced the text).
    _refreshAsrEndpoint();
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
        _adoptLlm(saved);
        _error = null;
        _savedNote = '修正模型已保存';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '修正模型保存失败:$e');
      return;
    }
    await _applyConnections();
  }

  /// Hand the just-saved files to the live engine (ADR-0010). A refusal
  /// keeps everything saved and painted but flags that the engine still
  /// runs the previous providers — the next session keeps working with
  /// them either way.
  Future<void> _applyConnections() async {
    try {
      await widget.store.applyConnections();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '已保存,但引擎沿用上一配置:$e');
    }
  }

  /// One key diff per secret the ACTIVE provider paints; a declined
  /// clear confirm aborts the whole save. The hidden vendors' secrets
  /// ride along as Keep.
  Future<AsrEdit?> _asrEdit() async {
    final commonKey = _asrBearerFamily.contains(_asrProvider)
        ? await _keyDiff(_asrKey, _asrKeyInfo, '语音识别')
        : const ApiKeyKeep();
    if (commonKey == null) return null;
    final volcKey = _asrProvider == 'volcengine'
        ? await _keyDiff(_asrVolcAccessKey, _asrVolcKeyInfo, '语音识别')
        : const ApiKeyKeep();
    if (volcKey == null) return null;
    final tencentId = _asrProvider == 'tencent'
        ? await _keyDiff(_asrTencentSecretId, _asrTencentIdInfo, '语音识别')
        : const ApiKeyKeep();
    if (tencentId == null) return null;
    final tencentKey = _asrProvider == 'tencent'
        ? await _keyDiff(_asrTencentSecretKey, _asrTencentKeyInfo, '语音识别')
        : const ApiKeyKeep();
    if (tencentKey == null) return null;

    String? optional(String text) =>
        text.trim().isEmpty ? null : text;
    return AsrEdit(
      provider: _asrProvider,
      model: _asrModel.text,
      language: _asrLanguage.text,
      baseUrl: optional(_asrBaseUrl.text),
      apiKey: commonKey,
      aliyun: AsrAliyunEdit(
        workspaceId: optional(_asrWorkspace.text),
        region: _asrRegion.text,
      ),
      volcengine: AsrVolcengineEdit(
        appId: optional(_asrVolcAppId.text),
        resourceId: _asrVolcResourceId.text,
        accessKey: volcKey,
      ),
      tencent: AsrTencentEdit(
        appId: optional(_asrTencentAppId.text),
        secretId: tencentId,
        secretKey: tencentKey,
      ),
      azure: AsrAzureEdit(
        region: optional(_asrAzureRegion.text),
        endpointId: optional(_asrAzureEndpointId.text),
      ),
    );
  }

  Future<void> _saveAsr() async {
    final edit = await _asrEdit();
    if (edit == null) return;
    try {
      final saved = await widget.store.saveAsr(edit: edit);
      if (!mounted) return;
      setState(() {
        _asrProvider = saved.provider;
        _asrModel.text = saved.model;
        _asrLanguage.text = saved.language;
        _asrBaseUrl.text = saved.baseUrl ?? '';
        _asrKey.text = saved.key.storedKey ?? '';
        _asrKeyInfo = saved.key;
        _asrEndpoint = saved.endpoint;
        _asrWorkspace.text = saved.aliyun.workspaceId ?? '';
        _asrRegion.text = saved.aliyun.region;
        _asrVolcAppId.text = saved.volcengine.appId ?? '';
        _asrVolcResourceId.text = saved.volcengine.resourceId;
        _asrVolcAccessKey.text = saved.volcengine.accessKey.storedKey ?? '';
        _asrVolcKeyInfo = saved.volcengine.accessKey;
        _asrTencentAppId.text = saved.tencent.appId ?? '';
        _asrTencentSecretId.text = saved.tencent.secretId.storedKey ?? '';
        _asrTencentIdInfo = saved.tencent.secretId;
        _asrTencentSecretKey.text = saved.tencent.secretKey.storedKey ?? '';
        _asrTencentKeyInfo = saved.tencent.secretKey;
        _asrAzureRegion.text = saved.azure.region ?? '';
        _asrAzureEndpointId.text = saved.azure.endpointId ?? '';
        _error = null;
        _savedNote = '语音识别已保存';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '语音识别保存失败:$e');
      return;
    }
    await _applyConnections();
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
              '保存后写入配置文件,下一场会话生效',
              key: const Key('settings-conn-effective-note'),
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
            provider: _asrProvider,
            onProvider: _applyAsrProvider,
            model: _asrModel,
            language: _asrLanguage,
            baseUrl: _asrBaseUrl,
            keyField: _asrKey,
            keyInfo: _asrKeyInfo,
            workspace: _asrWorkspace,
            region: _asrRegion,
            volcAppId: _asrVolcAppId,
            volcResourceId: _asrVolcResourceId,
            volcAccessKey: _asrVolcAccessKey,
            volcKeyInfo: _asrVolcKeyInfo,
            tencentAppId: _asrTencentAppId,
            tencentSecretId: _asrTencentSecretId,
            tencentIdInfo: _asrTencentIdInfo,
            tencentSecretKey: _asrTencentSecretKey,
            tencentKeyInfo: _asrTencentKeyInfo,
            azureRegion: _asrAzureRegion,
            azureEndpointId: _asrAzureEndpointId,
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
/// save. [id] names the field for the block's test keys; [title] labels
/// the secret (the sub-section keys are not all "api keys").
class _KeyBlock extends StatefulWidget {
  const _KeyBlock({
    required this.id,
    required this.field,
    required this.keyInfo,
    this.title = 'API 密钥',
  });

  final String id;
  final TextEditingController field;
  final KeyInfo keyInfo;
  final String title;

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
        Text(widget.title, style: SrType.micro.copyWith(color: pal.textTertiary)),
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

/// A chip set recipe (the history pane's retention-chip shape), shared
/// by the LLM vendor chips and the ASR provider chips.
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.testKey,
    required this.chips,
    required this.selected,
    required this.onSelect,
  });

  /// The row's own test key.
  final String testKey;
  final List<String> chips;
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
        for (final chip in chips)
          SrHover(
            builder: (hover) => GestureDetector(
              onTap: () => onSelect(chip),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                key: Key('$testKey:$chip'),
                duration: SrMotion.fade,
                curve: SrMotion.curveFade,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: chip == selected
                      ? pal.accentSoft
                      : pal.surfaceOverlay.withValues(alpha: hover ? 1 : 0),
                  borderRadius: BorderRadius.circular(SrRadius.control),
                  border: Border.all(
                    color: chip == selected
                        ? pal.accent.withValues(alpha: 0.6)
                        : pal.hairline,
                  ),
                ),
                child: Text(
                  chip,
                  style: SrType.caption.copyWith(
                    color: chip == selected
                        ? pal.accentText
                        : pal.textSecondary,
                    fontWeight: chip == selected
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
          _ChipRow(
            testKey: 'settings-conn-llm-vendors',
            chips: _vendors,
            selected: vendor,
            onSelect: onVendor,
          ),
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

/// The ASR card: the common segment's fields always, then the active
/// provider's sub-section fields (the schema's shape, ADR-0009).
class _AsrCard extends StatelessWidget {
  const _AsrCard({
    required this.provider,
    required this.onProvider,
    required this.model,
    required this.language,
    required this.baseUrl,
    required this.keyField,
    required this.keyInfo,
    required this.workspace,
    required this.region,
    required this.volcAppId,
    required this.volcResourceId,
    required this.volcAccessKey,
    required this.volcKeyInfo,
    required this.tencentAppId,
    required this.tencentSecretId,
    required this.tencentIdInfo,
    required this.tencentSecretKey,
    required this.tencentKeyInfo,
    required this.azureRegion,
    required this.azureEndpointId,
    required this.endpoint,
    required this.onSave,
  });

  final String provider;
  final ValueChanged<String> onProvider;

  // Common segment.
  final TextEditingController model;
  final TextEditingController language;
  final TextEditingController baseUrl;
  final TextEditingController keyField;
  final KeyInfo keyInfo;

  // [asr.aliyun]
  final TextEditingController workspace;
  final TextEditingController region;

  // [asr.volcengine]
  final TextEditingController volcAppId;
  final TextEditingController volcResourceId;
  final TextEditingController volcAccessKey;
  final KeyInfo volcKeyInfo;

  // [asr.tencent]
  final TextEditingController tencentAppId;
  final TextEditingController tencentSecretId;
  final KeyInfo tencentIdInfo;
  final TextEditingController tencentSecretKey;
  final KeyInfo tencentKeyInfo;

  // [asr.azure]
  final TextEditingController azureRegion;
  final TextEditingController azureEndpointId;

  /// The resolved endpoint preview; null for providers without an
  /// adapter yet.
  final String? endpoint;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final adapted = _asrAdapted.contains(provider);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '语音识别',
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '无凭据时仅保留麦克风语义(说话状态与静音),不做云端转写',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 14),
          Text('服务商(点击预填模型)', style: SrType.micro.copyWith(color: pal.textTertiary)),
          const SizedBox(height: 6),
          _ChipRow(
            testKey: 'settings-conn-asr-providers',
            chips: _asrProviders,
            selected: provider,
            onSelect: onProvider,
          ),
          if (!adapted) ...[
            const SizedBox(height: 6),
            Text(
              provider == 'tencent'
                  ? '腾讯云适配器排在后续工单;凭据就绪并重启将无法启用云端识别'
                  : '该供应商适配器未排期;凭据就绪并重启将无法启用云端识别',
              key: const Key('settings-conn-asr-unadapted'),
              style: SrType.micro.copyWith(color: pal.textSecondary),
            ),
          ],
          const SizedBox(height: 12),
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
                  key: const Key('settings-conn-asr-baseurl'),
                  controller: baseUrl,
                  label: 'base_url 全量覆盖(可选)',
                  monospace: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._subFields(context),
          const SizedBox(height: 10),
          Text(
            '当前端点:${endpoint ?? '—'}',
            key: const Key('settings-conn-asr-endpoint'),
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 12),
          if (_asrBearerFamily.contains(provider))
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

  /// The active provider's sub-section fields, between the common
  /// fields and the endpoint preview.
  List<Widget> _subFields(BuildContext context) {
    switch (provider) {
      case 'aliyun':
        return [
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
                  key: const Key('settings-conn-asr-region'),
                  controller: region,
                  label: '区域',
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ];
      case 'volcengine':
        return [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: SrField(
                  key: const Key('settings-conn-asr-volc-appid'),
                  controller: volcAppId,
                  label: 'App ID',
                  monospace: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SrField(
                  key: const Key('settings-conn-asr-volc-resource'),
                  controller: volcResourceId,
                  label: '资源 ID(即模型档位)',
                  monospace: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _KeyBlock(
            id: 'asr-volc',
            field: volcAccessKey,
            keyInfo: volcKeyInfo,
            title: 'Access Token',
          ),
          const SizedBox(height: 4),
        ];
      case 'tencent':
        return [
          SrField(
            key: const Key('settings-conn-asr-tencent-appid'),
            controller: tencentAppId,
            label: 'App ID',
            monospace: true,
          ),
          const SizedBox(height: 12),
          _KeyBlock(
            id: 'asr-tencent-id',
            field: tencentSecretId,
            keyInfo: tencentIdInfo,
            title: 'SecretId',
          ),
          const SizedBox(height: 12),
          _KeyBlock(
            id: 'asr-tencent-key',
            field: tencentSecretKey,
            keyInfo: tencentKeyInfo,
            title: 'SecretKey(签名密钥)',
          ),
          const SizedBox(height: 4),
        ];
      case 'azure':
        return [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: SrField(
                  key: const Key('settings-conn-asr-azure-region'),
                  controller: azureRegion,
                  label: '区域',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SrField(
                  key: const Key('settings-conn-asr-azure-endpoint'),
                  controller: azureEndpointId,
                  label: 'endpoint_id(自定义语音,可选)',
                  monospace: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ];
      default: // openai: no vendor-specific fields.
        return [const SizedBox(height: 4)];
    }
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
