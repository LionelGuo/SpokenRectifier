/// The 模型与连接 domain: the effective `[llm]` and `[asr]` sections as
/// editable forms. One save per card writes the editor's whole model
/// through the bridge (section-preserving into the layer files) and
/// repaints from the re-read view — the file's truth, not the ask.
///
/// The LLM card is the OPEN shape (ADR-0019): the endpoint as three
/// fields plus the format trio (the one behavioral axis), the resident
/// request-body box, and the 「设置思考字段」 switch governing the
/// thinking pair. The seven chips are PRESETS read from the engine-side
/// single source over the bridge (never copied here): a click stamps
/// that preset's format, base_url (unconditionally — an endpoint switch
/// is the point of the click), model (only when the current name is
/// empty or still some preset's, so a hand-edited name survives), the
/// switch, and the two thinking shares. The resident box is never
/// stamped — it is not a preset field. The last chip 自定义 is the
/// BLANK preset: it clears the endpoint, the switch, and both thinking
/// shares, keeps the format, and prefills nothing.
///
/// A broken thinking group refuses every save (the ratchet cannot
/// rewrite a group it cannot read), so the card says so and holds the
/// save button until the file is hand-fixed.
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
/// An environment key never echoes a value: the field starts empty,
/// and typing would store a new local key. Each save hands the files
/// to the live engine (ADR-0010); a refused adoption keeps them saved
/// and the engine on its previous providers until the next launch.

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard, SrField;
import '../design/hover.dart';
import '../design/toast.dart';
import '../design/tokens.dart';
import '../errors.dart';
import 'connection_store.dart';

/// The blank seventh chip (ADR-0018's custom slot, kept by ADR-0019
/// item 5): it names a key slot and a blank preset, never a preset row.
const _customVendor = 'custom';
const _vendorLabels = {_customVendor: '自定义'};

/// The format trio (ADR-0019 item 1): the one behavioral axis. A
/// protocol constant, not preset content — the preset rows that carry
/// it come over the bridge.
const _formats = ['openai_chat', 'anthropic', 'gemini'];

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

bool _isSomeAsrDefault(String model) => _asrModelPresets.values.contains(model);

/// The providers whose cloud adapter is built: everything else carries
/// fields in the schema but cannot stream yet.
const _asrAdapted = {'aliyun', 'volcengine', 'tencent'};

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
  bool _loaded = false;

  // LLM fields. The key block is one controller per vendor, made on
  // demand: a key authenticates exactly one vendor, so each chip binds
  // its own pair and a switch never carries (or loses) another vendor's
  // key (ADR-0011). The vendor list is the preset port's plus the
  // custom slot — nothing here hard-codes it.
  late final TextEditingController _llmBaseUrl = TextEditingController();
  late final TextEditingController _llmModel = TextEditingController();
  late final TextEditingController _llmBody = TextEditingController();
  late final TextEditingController _llmThinkingOn = TextEditingController();
  late final TextEditingController _llmThinkingOff = TextEditingController();
  final Map<String, TextEditingController> _llmKeys = {};
  final Map<String, KeyInfo> _llmKeyInfos = {};

  /// The preset rows, read once from the bridge's read-only port
  /// (ADR-0019 item 5). Empty until the first load lands.
  List<LlmPreset> _presets = const [];
  String _llmVendor = 'deepseek';
  String _llmFormat = 'openai_chat';
  bool _llmThinkingFields = false;

  /// The loaded group's reading: drives the refusal a broken group
  /// forces on every save.
  String _llmThinkingState = 'unconfigured';

  /// The chip row: every preset, then the blank custom seventh.
  List<String> get _llmVendors => [
    for (final preset in _presets) preset.name,
    _customVendor,
  ];

  TextEditingController _llmKey(String vendor) =>
      _llmKeys.putIfAbsent(vendor, TextEditingController.new);

  KeyInfo get _llmKeyInfo =>
      _llmKeyInfos[_llmVendor] ?? const KeyInfo(status: KeyPlacement.unset);

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
  late final TextEditingController _asrTencentSecretId =
      TextEditingController();
  late final TextEditingController _asrTencentSecretKey =
      TextEditingController();
  KeyInfo _asrTencentIdInfo = const KeyInfo(status: KeyPlacement.unset);
  KeyInfo _asrTencentKeyInfo = const KeyInfo(status: KeyPlacement.unset);

  late final TextEditingController _asrAzureRegion = TextEditingController();
  late final TextEditingController _asrAzureEndpointId =
      TextEditingController();

  /// Latest-wins token for the endpoint preview: a slower earlier
  /// refresh must not overwrite a newer one.
  int _asrEndpointToken = 0;

  /// Recompute the endpoint preview from the form as it stands — every
  /// edit to the fields the URL derives from and every provider chip
  /// click, never only on save.
  void _refreshAsrEndpoint() {
    final token = ++_asrEndpointToken;
    final appId = _asrTencentAppId.text.trim().isEmpty
        ? null
        : _asrTencentAppId.text;
    widget.store
        .asrEndpoint(
          provider: _asrProvider,
          model: _asrModel.text,
          baseUrl: _asrBaseUrl.text,
          workspaceId: _asrWorkspace.text,
          region: _asrRegion.text,
          appId: appId,
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
    for (final controller in [
      _asrModel,
      _asrBaseUrl,
      _asrWorkspace,
      _asrRegion,
      _asrTencentAppId,
    ]) {
      controller.addListener(_refreshAsrEndpoint);
    }
    _reload();
  }

  @override
  void dispose() {
    for (final controller in [
      _llmBaseUrl,
      _llmModel,
      _llmBody,
      _llmThinkingOn,
      _llmThinkingOff,
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
      final (config, presets) = await (
        widget.store.load(),
        widget.store.presets(),
      ).wait;
      if (!mounted) return;
      setState(() {
        _presets = presets;
        _adopt(config.llm, config.asr);
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loaded = true);
      logRawError('err_conn_load', e);
      SrToast.of(context).show('连接配置读取失败', tone: SrToastTone.error);
    }
  }

  /// Adopt the LLM view's truth into the form: the endpoint fields, the
  /// format axis, the thinking group (switch, reading, three boxes), and
  /// every vendor's key pair (a local-file key echoes into that vendor's
  /// field — the diff base; an env or unset key leaves it empty).
  void _adoptLlm(LlmConnection llm) {
    _llmVendor = llm.vendor;
    _llmBaseUrl.text = llm.baseUrl;
    _llmModel.text = llm.model;
    _llmFormat = llm.format;
    _llmThinkingState = llm.thinkingState;
    _llmThinkingFields = llm.thinkingFields;
    _llmBody.text = llm.bodyJson ?? '';
    _llmThinkingOn.text = llm.thinkingOnJson ?? '';
    _llmThinkingOff.text = llm.thinkingOffJson ?? '';
    for (final entry in llm.keys.entries) {
      _llmKey(entry.key).text = entry.value.storedKey ?? '';
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

  /// A chip click stamps the preset (ADR-0019 item 5): format, base_url
  /// unconditionally, the model only when the current name is empty or
  /// still some preset's, the switch, and both thinking shares. The
  /// resident box is NOT a preset field and is never stamped.
  ///
  /// The blank custom chip clears the endpoint, the switch, and both
  /// thinking shares, keeps the current format, and prefills nothing.
  void _applyVendorPreset(String vendor) {
    setState(() {
      _llmVendor = vendor;
      if (vendor == _customVendor) {
        _llmBaseUrl.text = '';
        _llmModel.text = '';
        _llmThinkingFields = false;
        _llmThinkingOn.text = '';
        _llmThinkingOff.text = '';
        return;
      }
      final preset = _presets.firstWhere((row) => row.name == vendor);
      // The key block re-binds to this vendor's own controller on the
      // rebuild — another vendor's key never carries across (ADR-0011).
      _llmFormat = preset.format;
      _llmBaseUrl.text = preset.baseUrl;
      if (_llmModel.text.trim().isEmpty ||
          _isSomePresetModel(_llmModel.text.trim())) {
        _llmModel.text = preset.model;
      }
      _llmThinkingFields = preset.thinkingFields;
      _llmThinkingOn.text = preset.thinkingOnJson;
      _llmThinkingOff.text = preset.thinkingOffJson;
    });
  }

  /// Whether [model] is a name some preset would have written — the
  /// values a chip click may freely replace (a hand-edited name is
  /// never one of them).
  bool _isSomePresetModel(String model) =>
      _presets.any((preset) => preset.model == model);

  /// An ASR provider chip click: switch the painted sub-section and
  /// prefill the model when it is empty or holds some provider's
  /// default. Another vendor's fields are NOT cleared — they ride
  /// along, hidden but preserved (ADR-0009).
  void _applyAsrProvider(String provider) {
    setState(() {
      _asrProvider = provider;
      if (_asrModel.text.trim().isEmpty ||
          _isSomeAsrDefault(_asrModel.text.trim())) {
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
    final key = await _keyDiff(_llmKey(_llmVendor), _llmKeyInfo, '修正模型');
    if (key == null) return;
    // The boxes' text rides verbatim (blank = unset); the Rust save
    // refuses a bad box, and an on switch with an empty on-share,
    // before writing anything (ADR-0018's shape rule, ADR-0019 item 2).
    String? box(TextEditingController field) =>
        field.text.trim().isEmpty ? null : field.text;
    try {
      final saved = await widget.store.saveLlm(
        edit: LlmEdit(
          vendor: _llmVendor,
          baseUrl: _llmBaseUrl.text,
          model: _llmModel.text,
          format: _llmFormat,
          thinkingFields: _llmThinkingFields,
          bodyJson: box(_llmBody),
          thinkingOnJson: box(_llmThinkingOn),
          thinkingOffJson: box(_llmThinkingOff),
          apiKey: key,
        ),
      );
      if (!mounted) return;
      setState(() => _adoptLlm(saved));
      SrToast.of(context).show('已保存', tone: SrToastTone.success);
    } catch (e) {
      if (!mounted) return;
      logRawError('err_conn_llm_save', e);
      SrToast.of(context).show('保存失败', tone: SrToastTone.error);
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
      logRawError('note_conn_engine_kept', e);
      SrToast.of(context).show('已保存', tone: SrToastTone.error);
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

    String? optional(String text) => text.trim().isEmpty ? null : text;
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
      });
      SrToast.of(context).show('已保存', tone: SrToastTone.success);
    } catch (e) {
      if (!mounted) return;
      logRawError('err_conn_asr_save', e);
      SrToast.of(context).show('保存失败', tone: SrToastTone.error);
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
        Text('模型与连接', style: SrType.title.copyWith(color: pal.textPrimary)),
        const SizedBox(height: 16),
        if (!_loaded)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          _LlmCard(
            vendors: _llmVendors,
            vendor: _llmVendor,
            onVendor: _applyVendorPreset,
            baseUrl: _llmBaseUrl,
            model: _llmModel,
            format: _llmFormat,
            onFormat: (format) => setState(() => _llmFormat = format),
            body: _llmBody,
            thinkingFields: _llmThinkingFields,
            thinkingState: _llmThinkingState,
            onThinkingFields: (on) => setState(() => _llmThinkingFields = on),
            thinkingOn: _llmThinkingOn,
            thinkingOff: _llmThinkingOff,
            keyField: _llmKey(_llmVendor),
            onSave: _llmThinkingState == 'broken' ? null : _saveLlm,
          ),
          const SizedBox(height: 16),
          _AsrCard(
            provider: _asrProvider,
            onProvider: _applyAsrProvider,
            model: _asrModel,
            language: _asrLanguage,
            baseUrl: _asrBaseUrl,
            keyField: _asrKey,
            workspace: _asrWorkspace,
            region: _asrRegion,
            volcAppId: _asrVolcAppId,
            volcResourceId: _asrVolcResourceId,
            volcAccessKey: _asrVolcAccessKey,
            tencentAppId: _asrTencentAppId,
            tencentSecretId: _asrTencentSecretId,
            tencentSecretKey: _asrTencentSecretKey,
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

/// The key block (ADR-0008, 2026-08-28 revision): the secret's title and
/// the diff-echo field (a local-file key paints masked; the eye toggles
/// plain text). The placement status line and both hints are retired
/// (copy.md conn-20/21/23/24) — clearing a saved key rides the save's
/// confirm alone. [id] names the field for the block's test keys;
/// [title] labels the secret (the sub-section keys are not all "api
/// keys").
class _KeyBlock extends StatefulWidget {
  const _KeyBlock({
    required this.id,
    required this.field,
    this.title = 'API 密钥',
  });

  final String id;
  final TextEditingController field;
  final String title;

  @override
  State<_KeyBlock> createState() => _KeyBlockState();
}

class _KeyBlockState extends State<_KeyBlock> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.title,
          style: SrType.micro.copyWith(color: pal.textTertiary),
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
/// by the LLM vendor chips, the dialect chips, and the ASR provider
/// chips. A chip's test key rides its wire name even when its label
/// differs (the custom vendor chip).
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.testKey,
    required this.chips,
    required this.selected,
    required this.onSelect,
    this.labels = const {},
  });

  /// The row's own test key.
  final String testKey;
  final List<String> chips;
  final String selected;
  final ValueChanged<String> onSelect;

  /// Display labels by wire name; chips without one label themselves.
  final Map<String, String> labels;

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
                  labels[chip] ?? chip,
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
    required this.vendors,
    required this.vendor,
    required this.onVendor,
    required this.baseUrl,
    required this.model,
    required this.format,
    required this.onFormat,
    required this.body,
    required this.thinkingFields,
    required this.thinkingState,
    required this.onThinkingFields,
    required this.thinkingOn,
    required this.thinkingOff,
    required this.keyField,
    required this.onSave,
  });

  /// The chip row: the preset port's names, custom last.
  final List<String> vendors;
  final String vendor;
  final ValueChanged<String> onVendor;
  final TextEditingController baseUrl;
  final TextEditingController model;

  /// The format axis (ADR-0019 item 1) and its trio.
  final String format;
  final ValueChanged<String> onFormat;

  /// The three overlay boxes: the resident one always live, the thinking
  /// pair governed by [thinkingFields].
  final TextEditingController body;
  final bool thinkingFields;
  final ValueChanged<bool> onThinkingFields;
  final TextEditingController thinkingOn;
  final TextEditingController thinkingOff;

  /// The loaded group's reading: `broken` holds the save button (every
  /// save is refused until the file is hand-fixed).
  final String thinkingState;

  final TextEditingController keyField;

  /// Null while the group is broken: a disabled button, never a click
  /// that is certain to fail.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final broken = thinkingState == 'broken';
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
            '配置用于修正的模型API接口',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 14),
          Text(
            '服务商',
            key: const Key('settings-conn-llm-vendor-caption'),
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 6),
          _ChipRow(
            testKey: 'settings-conn-llm-vendors',
            chips: vendors,
            selected: vendor,
            onSelect: onVendor,
            labels: _vendorLabels,
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
          Text(
            '接口格式',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 6),
          _ChipRow(
            testKey: 'settings-conn-llm-format',
            chips: _formats,
            selected: format,
            onSelect: onFormat,
          ),
          const SizedBox(height: 12),
          SrField(
            key: const Key('settings-conn-llm-body'),
            controller: body,
            label: '请求体JSON覆写',
            monospace: true,
            maxLines: 4,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  '设置思考字段',
                  style: SrType.caption.copyWith(color: pal.textSecondary),
                ),
              ),
              Switch(
                key: const Key('settings-conn-llm-thinking-fields'),
                value: thinkingFields,
                onChanged: onThinkingFields,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // One static caption either way (copy.md conn-12..15): the
          // broken branch only swaps the tone — the detail lives in the
          // file the user is about to hand-fix, not on the card.
          if (broken)
            Text(
              '思考字段配置有误',
              key: const Key('settings-conn-llm-thinking-broken'),
              style: SrType.micro.copyWith(color: pal.live),
            )
          else
            Text(
              '编辑模型供应商的模型思考配置字段',
              key: const Key('settings-conn-llm-thinking-note'),
              style: SrType.micro.copyWith(color: pal.textTertiary),
            ),
          const SizedBox(height: 10),
          // Disabled in place, never hidden: off is a stance, so both
          // shares stay painted and still ride the save.
          AnimatedOpacity(
            duration: SrMotion.fade,
            curve: SrMotion.curveFade,
            opacity: thinkingFields ? 1 : 0.5,
            child: AbsorbPointer(
              absorbing: !thinkingFields,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SrField(
                      key: const Key('settings-conn-llm-thinking-on'),
                      controller: thinkingOn,
                      label: '开思考',
                      monospace: true,
                      maxLines: 4,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SrField(
                      key: const Key('settings-conn-llm-thinking-off'),
                      controller: thinkingOff,
                      label: '关思考',
                      monospace: true,
                      maxLines: 4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _KeyBlock(id: 'llm', field: keyField),
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
    required this.workspace,
    required this.region,
    required this.volcAppId,
    required this.volcResourceId,
    required this.volcAccessKey,
    required this.tencentAppId,
    required this.tencentSecretId,
    required this.tencentSecretKey,
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

  // [asr.aliyun]
  final TextEditingController workspace;
  final TextEditingController region;

  // [asr.volcengine]
  final TextEditingController volcAppId;
  final TextEditingController volcResourceId;
  final TextEditingController volcAccessKey;

  // [asr.tencent]
  final TextEditingController tencentAppId;
  final TextEditingController tencentSecretId;
  final TextEditingController tencentSecretKey;

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
            '未配置凭据时不做云端转写，仅显示说话状态',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 14),
          Text(
            '服务商',
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
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
              '该供应商暂未接入，暂不支持云端识别',
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
                  label: 'base_url 覆写',
                  monospace: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._subFields(context),
          const SizedBox(height: 10),
          Text(
            '当前端点：${endpoint ?? '—'}',
            key: const Key('settings-conn-asr-endpoint'),
            style: SrType.micro.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 12),
          if (_asrBearerFamily.contains(provider))
            _KeyBlock(id: 'asr', field: keyField),
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
                  label: 'workspace_id',
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
                  label: '资源 ID',
                  monospace: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _KeyBlock(
            id: 'asr-volc',
            field: volcAccessKey,
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
            title: 'SecretId',
          ),
          const SizedBox(height: 12),
          _KeyBlock(
            id: 'asr-tencent-key',
            field: tencentSecretKey,
            title: 'SecretKey',
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
                  label: 'endpoint_id',
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
                '清除密钥？',
                style: SrType.title.copyWith(color: pal.textPrimary),
              ),
              const SizedBox(height: 12),
              Text(
                '该操作将删除 $section 已保存的 API 密钥，未配置环境变量时该服务将停用。',
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
