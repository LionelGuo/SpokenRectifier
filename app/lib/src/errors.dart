/// Error presentation (ui-copy [错误点位清单与短句键位]):
///
/// - Dynamic engine messages (bridge Error events, startSession /
///   createEngine throws) collapse to one of five buckets via a
///   substring heuristic. The original text never reaches the screen.
/// - Every short-sentence site logs the raw exception through
///   [logRawError] so the console still holds the diagnosis.
///
/// Short sentences themselves stay inlined at the call sites (copy.md
/// is the later review surface; this file is the classifier, not a
/// strings table).

library;

import 'package:flutter/foundation.dart' show debugPrint;

/// Logs the raw exception at [site] so a short-sentence UI still has
/// a full diagnosis in the console. The only logging seam this effort
/// adds — there is no tracing crate and no log file yet.
void logRawError(String site, Object error) {
  debugPrint('[sr-error][$site] $error');
}

/// Classifies an engine-side raw message (or exception) into the
/// on-screen short sentence. Order is timeout → audio → credentials
/// → insert → network → other, matching the inventory's 0.1 table:
/// `rectify timed out` must beat the network `timed out` substring,
/// and `device` must beat a later network match. The insert buckets
/// (小修 25) keep the three failure faces distinct — no target found
/// (nothing touched), a failed paste (the text IS on the clipboard,
/// the manual Ctrl+V fallback is live), and everything else insertion
/// touches — because「服务出错」 on an insert failure sends the user
/// hunting a network that is fine.
String classifyEngineError(Object error) {
  final haystack = error.toString().toLowerCase();
  if (haystack.contains('rectify timed out')) {
    return '修正超时，请重试';
  }
  if (_matches(haystack, const [
    'input device',
    'input config',
    'input stream',
    'capture thread',
    'device',
  ])) {
    return '音频设备异常，请检查麦克风';
  }
  if (_matches(haystack, const [
    '401',
    '403',
    'unauthorized',
    'forbidden',
    'signature',
    'sign check',
    'api key',
    'api_key',
    'credential',
  ])) {
    return '凭据无效，请检查密钥';
  }
  if (haystack.contains('no target window')) {
    return '未找到插入目标，请先点选目标窗口';
  }
  if (haystack.contains('paste keystroke failed')) {
    return '插入失败，可手动 Ctrl+V';
  }
  if (_matches(haystack, const [
    'clipboard set failed',
    'typing failed',
  ])) {
    return '插入失败，请重试';
  }
  if (_matches(haystack, const [
    'timed out',
    'timeout',
    'connection failed',
    'error sending request',
    'dns',
    'refused',
    'reset',
    'unreachable',
    'reconnecting timed out',
    'request to',
    'stream read failed',
  ])) {
    return '网络异常，请检查连接';
  }
  return '服务出错，请重试';
}

/// Formats a per-case eval execution failure. The classified bucket
/// stays in the console via the caller's [logRawError]; the card
/// never interpolates it (copy.md err_eval_case).
String classifyEvalCaseError(Object _) => '执行失败，详情请见日志';

bool _matches(String haystack, List<String> needles) {
  for (final needle in needles) {
    if (haystack.contains(needle)) return true;
  }
  return false;
}
