/// The settings window's navigation domains (设置窗口域骨架, ticket 17).
///
/// Seven entries: the tickets and the design spec each counted six but
/// disagreed on the split — spec §4.4 omits 保真评测 (ticket 18), the
/// ticket merges 术语/模型与连接 that ticket 19 fills separately. The
/// union is the sidebar; the six non-scenario domains are empty-state
/// placeholders until 18/19 land.

library;

import 'package:flutter/material.dart';

enum SettingsDomain {
  scenarios,
  fidelity,
  history,
  terms,
  connection,
  advanced,
  about,
}

extension SettingsDomainX on SettingsDomain {
  String get label => switch (this) {
    SettingsDomain.scenarios => '场景库',
    SettingsDomain.fidelity => '保真评测',
    SettingsDomain.history => '历史',
    SettingsDomain.terms => '术语',
    SettingsDomain.connection => '模型与连接',
    SettingsDomain.advanced => '高级',
    SettingsDomain.about => '关于',
  };

  IconData get icon => switch (this) {
    SettingsDomain.scenarios => Icons.style_outlined,
    SettingsDomain.fidelity => Icons.fact_check_outlined,
    SettingsDomain.history => Icons.history_rounded,
    SettingsDomain.terms => Icons.spellcheck_rounded,
    SettingsDomain.connection => Icons.cloud_outlined,
    SettingsDomain.advanced => Icons.tune_rounded,
    SettingsDomain.about => Icons.info_outline_rounded,
  };
}

/// Parse a domain from its enum name (the window-arguments wire format);
/// unknown names fall back to the first domain.
SettingsDomain settingsDomainFromName(String? name) =>
    SettingsDomain.values.firstWhere(
      (domain) => domain.name == name,
      orElse: () => SettingsDomain.scenarios,
    );
