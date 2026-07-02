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
    expect((exported['apiLogs'] as List).length, 1);
    expect((exported['tracePayloads'] as List).length, 1);
    final tracePayload =
        (exported['tracePayloads'] as List).first as Map<String, dynamic>;
    final payload = tracePayload['payload'] as Map<String, dynamic>;
    expect(payload['payload']['rawRequestBody'], isNot(contains('test_token')));
    final apiLog = (exported['apiLogs'] as List).first as Map<String, dynamic>;
    expect((apiLog['requestBody'] as String).contains('test_token'), isFalse);
  });
}
