import 'dart:convert';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/observability/history_payload_stats.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_port.dart';

class _Clock implements Stopwatch {
  _Clock(this.ms);
  int ms;
  @override
  int get elapsedMilliseconds => ms;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('超过500ms的实际冷加载需要关注，旧动画累计时间不触发告警', () async {
    final logs = <LogEntry>[];
    final service = FrontendDiagnosticsService(sink: logs.add);
    final context =
        FrontendDiagnosticContext(operationId: 'slow', clock: _Clock(1065));
    service.record(context, FrontendStage.historyColdLoad,
        facts: const DiagnosticFacts(phase: DiagnosticPhase.end));
    service.record(context, FrontendStage.animationDecision,
        facts: const DiagnosticFacts(state: {'animate': false}));
    await Future<void>.delayed(Duration.zero);
    expect(logs.first.level, LogLevel.warning);
    expect(logs.last.level, LogLevel.info);
  });

  test('按固定分类统计字符串长度，不输出动态键名和内容', () {
    final stats = HistoryPayloadStats();
    stats.add({
      'rawReplyText': '中文😀',
      'rawToolResults': [
        {'result': 'x' * 2000000}
      ],
      'projectedMessages': [
        {
          'content': 'shown',
          'blocks': [
            {'base64': 'AAAA'}
          ]
        }
      ],
      'Authorization: SECRET': {'https://private.example': 'private-value'},
    });
    expect(stats.values['payloadReplyChars'], 4);
    expect(stats.values['payloadToolResultChars'], 2000000);
    expect(stats.values['payloadProjectionChars'], 9);
    expect(stats.values['payloadOtherChars'], 13);
    expect(stats.values['payloadScanTruncated'], false);
    expect(stats.values.values.every((value) => value is num || value is bool),
        true);
    final encoded = jsonEncode(stats.values);
    for (final secret in [
      'SECRET',
      'Authorization',
      'private',
      '中文',
      'shown',
      'AAAA'
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
  });

  test('节点和深度预算截断时明确标记，巨字符串只计算长度', () {
    final stats = HistoryPayloadStats(maxNodes: 3);
    stats.add({
      'rawToolResults': ['x' * 2000000, 'abc', 'not visited']
    });
    expect(stats.values['payloadToolResultChars'], 2000003);
    expect(stats.values['payloadScanNodes'], 3);
    expect(stats.values['payloadScanTruncated'], true);
    final deep = HistoryPayloadStats(maxDepth: 1);
    deep.add({
      'projectedMessages': [
        [
          ['unread']
        ]
      ]
    });
    expect(deep.values['payloadScanTruncated'], true);
    expect(deep.values['payloadProjectionChars'], 0);
  });

  test('动画关联旧消息保留trace，但使用本次视口的时钟', () {
    final old = FrontendDiagnosticContext(
        operationId: 'audio_old',
        clock: _Clock(2670),
        traceId: 'trace',
        turnId: 'turn');
    final clock = _Clock(6);
    final viewport =
        FrontendDiagnosticContext(operationId: 'viewport_new', clock: clock);
    final linked = viewport.withParent(old);
    expect(linked.operationId, 'viewport_new');
    expect(linked.parentOperationId, 'audio_old');
    expect(linked.traceId, 'trace');
    expect(linked.elapsedMs, 6);
    clock.ms = 16;
    expect(linked.elapsedMs, 16);
    expect(old.elapsedMs, 2670);
  });
}
