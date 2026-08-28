/// The 关于 domain: version, open-source info, and the open-config-file
/// entry migrated from the tray (the tray keeps its own item; both ride
/// the same bridge call — 同源, ticket 19).

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard;
import '../design/tokens.dart';
import 'system_store.dart';

class SettingsAboutPane extends StatefulWidget {
  const SettingsAboutPane({super.key, required this.store});

  final SystemStore store;

  @override
  State<SettingsAboutPane> createState() => _SettingsAboutPaneState();
}

class _SettingsAboutPaneState extends State<SettingsAboutPane> {
  AboutInfo? _about;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final about = await widget.store.loadAbout();
      if (!mounted) return;
      setState(() => _about = about);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '信息读取失败:$e');
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
    final about = _about;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('关于', style: SrType.title.copyWith(color: pal.textPrimary)),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const Key('settings-about-error'),
            style: SrType.caption.copyWith(color: pal.live),
          ),
        ],
        const SizedBox(height: 16),
        if (about == null)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          SrCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'SpokenRectifier',
                      style: SrType.title.copyWith(color: pal.textPrimary),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'v${about.version}',
                      key: const Key('settings-about-version'),
                      style: SrType.caption.copyWith(color: pal.textTertiary),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '把即兴说出的口语段修正为保真、高信息密度的书面文本的语音输入工具。',
                  style: SrType.caption.copyWith(color: pal.textSecondary),
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
                  '开源信息',
                  style: SrType.body.copyWith(
                    color: pal.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                _AboutRow(label: '许可证', value: about.license),
                _AboutRow(label: '仓库', value: about.repoUrl ?? '随开源发布公布'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SrCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '配置文件',
                  style: SrType.body.copyWith(
                    color: pal.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '分层配置:defaults → shared → local,local 恒胜;密钥只住在 local。',
                  style: SrType.micro.copyWith(color: pal.textTertiary),
                ),
                const SizedBox(height: 12),
                SrButton(
                  key: const Key('settings-about-open-config'),
                  primary: true,
                  label: '打开配置文件',
                  onTap: _openConfig,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: SrType.caption.copyWith(color: pal.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              key: Key('settings-about-$label'),
              style: SrType.caption.copyWith(color: pal.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
