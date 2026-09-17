/// Classifier coverage for the ui-copy 0.1 bucket table: order,
/// substring matching, and the eval-case wrapper. Pure functions —
/// no widget tree.

library;

import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/src/errors.dart';

void main() {
  group('classifyEngineError', () {
    test('rectify timeout beats a later network timed-out match', () {
      expect(
        classifyEngineError(
          'rectify timed out after the 25000 ms hard cap; retry or cancel',
        ),
        '修正超时,请重试',
      );
    });

    test('audio device messages from cpal / mic.rs', () {
      expect(classifyEngineError('no default input device'), '音频设备异常,请检查麦克风');
      expect(
        classifyEngineError('no usable input config: UnsupportedSampleRate'),
        '音频设备异常,请检查麦克风',
      );
      expect(
        classifyEngineError('input stream failed to start: DeviceNotAvailable'),
        '音频设备异常,请检查麦克风',
      );
      expect(
        classifyEngineError('failed to start capture thread: io'),
        '音频设备异常,请检查麦克风',
      );
    });

    test('credentials: 401/403 and api-key vocabulary', () {
      expect(
        classifyEngineError(
          'https://api.example/chat/completions returned 401: invalid_api_key',
        ),
        '凭据无效,请检查密钥',
      );
      expect(
        classifyEngineError('ASR handshake rejected: HTTP 403 Forbidden'),
        '凭据无效,请检查密钥',
      );
      expect(
        classifyEngineError(
          'add api_key under [llm] in spokenrectifier.local.toml',
        ),
        '凭据无效,请检查密钥',
      );
    });

    test('network: request / timeout / stream-read vocabulary', () {
      expect(
        classifyEngineError(
          'request to https://api.example failed: connection refused',
        ),
        '网络异常,请检查连接',
      );
      expect(
        classifyEngineError('stream read failed: unexpected eof'),
        '网络异常,请检查连接',
      );
      expect(classifyEngineError('connection failed: dns error'), '网络异常,请检查连接');
    });

    test('unrecognized messages fall to the other bucket', () {
      expect(
        classifyEngineError('ASR provider "tencent" has no adapter'),
        '服务出错,详情见日志',
      );
      expect(classifyEngineError(StateError('engine gone')), '服务出错,详情见日志');
    });

    test('matching is case-insensitive', () {
      expect(classifyEngineError('NO DEFAULT INPUT DEVICE'), '音频设备异常,请检查麦克风');
    });
  });

  test('classifyEvalCaseError wraps the bucket in 执行失败(...)', () {
    expect(classifyEvalCaseError('引擎返回 429:rate limited'), '执行失败(服务出错,详情见日志)');
    expect(
      classifyEvalCaseError('request to https://api.example failed: timeout'),
      '执行失败(网络异常,请检查连接)',
    );
  });
}
