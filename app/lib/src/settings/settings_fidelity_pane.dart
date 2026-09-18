/// The 保真评测 domain: one manual entry that runs the embedded golden
/// suite through the real LLM — live progress, then the pass rate
/// against the recorded baseline with the failure-category summary.
/// The run lives in [FidelityEvalController] (the settings window's
/// state), so switching domains keeps it; closing the window or
/// pressing 取消 stops it.

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrCard;
import '../design/tokens.dart';
import '../errors.dart';
import '../rust/api.dart' show BridgeEvalCaseDetail, BridgeEvalSummary;
import 'fidelity_eval.dart';

class SettingsFidelityPane extends StatelessWidget {
  const SettingsFidelityPane({super.key, required this.controller});

  final FidelityEvalController controller;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              Text(
                '保真评测',
                style: SrType.title.copyWith(color: pal.textPrimary),
              ),
              const SizedBox(width: 10),
              Text(
                '金样例回归:机器断言口头更正、术语逐字保留、零捏造',
                style: SrType.caption.copyWith(color: pal.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 16),
          switch (controller.phase) {
            FidelityEvalPhase.idle => _IdleCard(controller: controller),
            FidelityEvalPhase.running => _RunningCard(controller: controller),
            FidelityEvalPhase.failed => _FailedCard(controller: controller),
            FidelityEvalPhase.finished => _SummaryCard(controller: controller),
          },
        ],
      ),
    );
  }
}

class _IdleCard extends StatelessWidget {
  const _IdleCard({required this.controller});

  final FidelityEvalController controller;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '对内置金样例套件跑一轮完整修正,校验保真铁律。',
            style: SrType.body.copyWith(color: pal.textSecondary),
          ),
          const SizedBox(height: 10),
          Text(
            '走真实 LLM(约 1 分钟、约 2 万 token);全程不插入文本、不写入历史、不读本机词表,也不套用场景或全局指令。',
            style: SrType.caption.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 6),
          Text(
            '连接配置(格式与三份请求体 overlay)原样进评测,不可在此覆写;'
            '思考字段关/未配置时,评测请求同样不带思考键,对端用自家默认。',
            key: const Key('settings-eval-connection-inherited'),
            style: SrType.caption.copyWith(color: pal.textTertiary),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              SrButton(primary: true, label: '开始评测', onTap: controller.start),
            ],
          ),
        ],
      ),
    );
  }
}

class _RunningCard extends StatelessWidget {
  const _RunningCard({required this.controller});

  final FidelityEvalController controller;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final total = controller.total;
    final done = controller.done;
    final fraction = total == 0 ? 0.0 : done / total;
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                key: Key('settings-eval-spinner'),
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                key: const Key('settings-eval-progress'),
                total == 0 ? '评测准备中…' : '$done / $total',
                style: SrType.body.copyWith(
                  color: pal.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              if (controller.currentCase case final id?)
                Text(
                  id,
                  style: SrType.caption.copyWith(color: pal.textTertiary),
                ),
              const Spacer(),
              SrButton(label: '取消', onTap: controller.cancel),
            ],
          ),
          const SizedBox(height: 14),
          // The progress bar: hairline track, accent fill eased over the
          // shared fade token (no snap between cases).
          ClipRRect(
            borderRadius: BorderRadius.circular(SrRadius.control),
            child: SizedBox(
              height: 4,
              child: Stack(
                children: [
                  Container(color: pal.hairline),
                  FractionallySizedBox(
                    widthFactor: fraction,
                    child: AnimatedContainer(
                      duration: SrMotion.fade,
                      curve: SrMotion.curveFade,
                      color: pal.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FailedCard extends StatelessWidget {
  const _FailedCard({required this.controller});

  final FidelityEvalController controller;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 16, color: pal.live),
              const SizedBox(width: 8),
              Text(
                '评测未能完成',
                style: SrType.body.copyWith(
                  color: pal.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            key: const Key('settings-eval-failure'),
            controller.failure ?? '',
            style: SrType.caption.copyWith(color: pal.textSecondary),
          ),
          const SizedBox(height: 20),
          SrButton(primary: true, label: '重试', onTap: controller.start),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.controller});

  final FidelityEvalController controller;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final summary =
        controller.summary ??
        const BridgeEvalSummary(
          total: 0,
          passed: 0,
          failed: 0,
          execFailed: 0,
          ratePercent: 0,
          baselinePercent: 0,
          model: '',
          categories: [],
          failedCases: [],
        );
    // Against the baseline: same-or-better reads calm, worse reads live.
    final delta = summary.ratePercent - summary.baselinePercent;
    final versus = delta >= 0
        ? (delta < 0.05 ? '与基线持平' : '超出基线 ${delta.toStringAsFixed(1)} 个百分点')
        : '落后基线 ${(-delta).toStringAsFixed(1)} 个百分点';
    return Column(
      // Completed state fills the pane width: with `start`, cards that
      // hold only text (the failed cases) shrink-wrapped their content
      // while the summary card stretched merely by accident (its Row
      // owns a Spacer). Stretch makes every card full-width by rule —
      // the history domain's entry-row look (ticket 21).
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SrCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    key: const Key('settings-eval-rate'),
                    '${summary.ratePercent.toStringAsFixed(1)}%',
                    style: SrType.title.copyWith(
                      color: pal.textPrimary,
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      key: const Key('settings-eval-versus'),
                      versus,
                      style: SrType.caption.copyWith(
                        color: delta >= 0 ? pal.textSecondary : pal.live,
                      ),
                    ),
                  ),
                  const Spacer(),
                  SrButton(
                    primary: true,
                    label: '重新评测',
                    onTap: controller.start,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '通过 ${summary.passed} / ${summary.total}'
                '${summary.execFailed > 0 ? ' · 执行失败 ${summary.execFailed}' : ''}'
                ' · 基线 ${summary.baselinePercent.toStringAsFixed(1)}%'
                ' · ${summary.model}',
                style: SrType.caption.copyWith(color: pal.textTertiary),
              ),
              const SizedBox(height: 16),
              // 失败类别摘要: one row of counts, display order fixed by
              // the wire (zero counts included — an all-zero row is the
              // clean-run signal, not noise).
              Wrap(
                key: const Key('settings-eval-categories'),
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final category in summary.categories)
                    _CategoryChip(label: category.label, count: category.count),
                ],
              ),
            ],
          ),
        ),
        if (summary.failedCases.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('失败明细', style: SrType.caption.copyWith(color: pal.textTertiary)),
          const SizedBox(height: 8),
          for (final failed in summary.failedCases)
            Padding(
              // Row gap outside the card, like the history rows.
              padding: const EdgeInsets.only(bottom: 6),
              child: _FailedCaseCard(failed: failed),
            ),
        ] else ...[
          const SizedBox(height: 12),
          Text(
            '全部用例通过,无失败明细。',
            style: SrType.caption.copyWith(color: pal.textTertiary),
          ),
        ],
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    final hot = count > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: pal.surfaceOverlay,
        borderRadius: BorderRadius.circular(SrRadius.control),
      ),
      child: Text(
        key: Key('settings-eval-category:$label'),
        '$label $count',
        style: SrType.caption.copyWith(
          color: hot ? pal.live : pal.textTertiary,
          fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

class _FailedCaseCard extends StatelessWidget {
  const _FailedCaseCard({required this.failed});

  final BridgeEvalCaseDetail failed;

  /// Classifies and logs in one step so the card never paints the raw
  /// engine text. Rebuilds re-print the same line — a finished summary
  /// barely rebuilds, and a missed log is worse.
  static String _classifiedCaseError(String error) {
    logRawError('err_eval_case', error);
    return classifyEvalCaseError(error);
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrCard(
      key: Key('settings-eval-failed:${failed.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            failed.id,
            style: SrType.body.copyWith(
              color: pal.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          // An execution failure is classified into a bucket; the raw
          // engine text stays in the console, never on the card.
          if (failed.error case final error?) ...[
            Text(
              _classifiedCaseError(error),
              style: SrType.caption.copyWith(color: pal.live),
            ),
          ] else
            for (final verdict in failed.failures)
              Text(
                verdict,
                style: SrType.caption.copyWith(color: pal.textSecondary),
              ),
        ],
      ),
    );
  }
}
