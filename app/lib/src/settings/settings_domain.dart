/// The settings window's navigation domains (设置窗口域骨架, ticket 17).
///
/// Nine entries — the sidebar IA map's final order: 通用 first (the home
/// domain every unknown name falls back to), then the daily domains with
/// 修正 third (the rectify behavior cards), 模型与连接, and the tail
/// (保真评测 before 高级/关于).

library;

import 'package:flutter/material.dart';

enum SettingsDomain {
  general,
  scenarios,
  rectify,
  history,
  terms,
  connection,
  fidelity,
  advanced,
  about,
}

extension SettingsDomainX on SettingsDomain {
  String get label => switch (this) {
    SettingsDomain.general => '通用',
    SettingsDomain.scenarios => '场景',
    SettingsDomain.rectify => '修正',
    SettingsDomain.history => '历史',
    SettingsDomain.terms => '术语',
    SettingsDomain.connection => '模型与连接',
    SettingsDomain.fidelity => '评测',
    SettingsDomain.advanced => '高级',
    SettingsDomain.about => '关于',
  };

  IconData get icon => switch (this) {
    SettingsDomain.general => Icons.settings_outlined,
    SettingsDomain.scenarios => Icons.style_outlined,
    SettingsDomain.rectify => Icons.auto_fix_high_outlined,
    SettingsDomain.history => Icons.history_rounded,
    SettingsDomain.terms => Icons.spellcheck_rounded,
    SettingsDomain.connection => Icons.cloud_outlined,
    SettingsDomain.fidelity => Icons.fact_check_outlined,
    SettingsDomain.advanced => Icons.tune_rounded,
    SettingsDomain.about => Icons.info_outline_rounded,
  };
}

/// Parse a domain from its enum name (the window-arguments wire format);
/// unknown names fall back to 通用, the sidebar's first domain.
SettingsDomain settingsDomainFromName(String? name) =>
    SettingsDomain.values.firstWhere(
      (domain) => domain.name == name,
      orElse: () => SettingsDomain.general,
    );
