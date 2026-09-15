import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/observability/trace_export_service.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';

void main() {
  test('exportTrace should export trace events and related api logs', () async {
    final temp = await Directory.systemTemp.createTemp('trace_export_test_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final store = TraceStore(
      rootDirResolver: () async => temp,
      nowProvider: () => DateTime(2026, 3, 2, 12, 0, 0),
    );
    await store.initialize();

    final context = await store.startTurn(sessionId: 'conv_1', turnId: 'msg_1');
    final tracePayloadRef = await store.writePayload(
      traceId: context.traceId,
      sessionId: context.sessionId,
      turnId: context.turnId,
      roundIndex: 1,
      stage: TraceStage.historyPrepared.value,
      source: 'test',
      payload: const {
        'rawContext': '[{"role":"user","content":"hello"}]',
        'rawRequestBody': '{"authorization":"Bearer test_token"}',
      },
    );
    await store.record(
      traceId: context.traceId,
      stage: TraceStage.historyPrepared,
      source: 'test',
      payloadRef: {
        'apiLog': {
          'file': 'api_2026-03-02.jsonl',
          'sessionId': 'conv_1',
          'turnId': 'msg_1',
          'roundIndex': 1,
          'eventType': 'round',
        },
        ...?tracePayloadRef,
      },
      roundIndex: 1,
    );
    await store.waitForPendingWrites();

    final apiFile = File('${temp.path}/api_2026-03-02.jsonl');
    await apiFile.writeAsString(
      '${jsonEncode({
            'time': DateTime(2026, 3, 2, 12, 0, 1).toIso8601String(),
            'method': 'POST',
            'url': 'https://api.example.com/chat',
            'status': 200,
            'durationMs': 120,
            'requestBody': '{"authorization":"Bearer test_token"}',
            'responseBody': '{"ok":true}',
            'ok': true,
            'sessionId': 'conv_1',
            'turnId': 'msg_1',
            'roundIndex': 1,
            'eventType': 'round',
          })}\n',
      flush: true,
    );

    final appFile = File('${temp.path}/app_2026-03-02.jsonl');
    await appFile.writeAsString([
      {
        'time': '2026-03-02T12:00:00',
        'source': 'FrontendDiagnostics',
        'message': '提交发送',
        'metadata': {
          'operationId': 'ui_1772424000000000_1',
          'parentOperationId': 'ui_1772424000000000_0',
          'appRunId': 'run_1772424000000000_123',
          'sourceMessageId': 'raw_msg_1772424000000000_0',
        }
      },
      {
        'time': '2026-03-02T12:00:01',
        'source': 'FrontendDiagnostics',
        'message': '已关联本轮对话',
        'traceId': context.traceId,
        'metadata': {
          'operationId': 'ui_1772424000000000_1',
          'authorization': 'Bearer secret'
        }
      },
      {
        'time': '2026-03-02T12:00:02',
        'source': 'FrontendDiagnostics',
        'traceId': 'another_retry_trace',
        'metadata': {
          'turnId': 'msg_1',
          'conversationId': 'conv_1',
          'operationId': 'another_op'
        },
      },
      {
        'time': '2026-03-02T12:00:02',
        'source': 'Other',
        'metadata': {'turnId': 'msg_1', 'conversationId': 'other_conversation'}
      },
    ].map(jsonEncode).join('\n'));

    final exportFile = await TraceExportService.exportTrace(
      traceId: context.traceId,
      traceStore: store,
      debugLogDir: temp,
      redactSensitive: true,
    );

    expect(exportFile, isNotNull);
    expect(await exportFile!.exists(), isTrue);
    final exported =
        jsonDecode(await exportFile.readAsString()) as Map<String, dynamic>;
    expect(exported['traceId'], context.traceId);
    expect((exported['events'] as List).isNotEmpty, isTrue);
    expect((exported['events'] as List).first['traceId'], context.traceId,
        reason: '脱敏不能抹掉系统生成的关联编号');
    expect((exported['appLogs'] as List).first['time'], '2026-03-02T12:00:00');
    expect((exported['apiLogs'] as List).length, 1);
    expect(exported['appLogs'], hasLength(2));
    expect((exported['appLogs'] as List).first['metadata']['operationId'],
        'ui_1772424000000000_1');
    final firstMetadata = (exported['appLogs'] as List).first['metadata'];
    expect(firstMetadata['parentOperationId'], 'ui_1772424000000000_0');
    expect(firstMetadata['appRunId'], 'run_1772424000000000_123');
    expect(firstMetadata['sourceMessageId'], 'raw_msg_1772424000000000_0');
    expect(jsonEncode(exported['appLogs']), isNot(contains('Bearer secret')));
    expect((exported['tracePayloads'] as List).length, 1);
    final tracePayload =
        (exported['tracePayloads'] as List).first as Map<String, dynamic>;
    final payload = tracePayload['payload'] as Map<String, dynamic>;
    expect(payload['payload']['rawRequestBody'], isNot(contains('test_token')));
    final apiLog = (exported['apiLogs'] as List).first as Map<String, dynamic>;
    expect((apiLog['requestBody'] as String).contains('test_token'), isFalse);
  });
}
