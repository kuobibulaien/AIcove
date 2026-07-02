import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';

void main() {
  test('TraceStore should persist payload file and resolve by payloadRef',
      () async {
    final temp = await Directory.systemTemp.createTemp('trace_payload_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final store = TraceStore(
      rootDirResolver: () async => temp,
      nowProvider: () => DateTime(2026, 3, 2, 13, 0, 0),
    );
    await store.initialize();

    final context =
        await store.startTurn(sessionId: 'conv_1', turnId: 'turn_1');
    final payloadRef = await store.writePayload(
      traceId: context.traceId,
      sessionId: context.sessionId,
      turnId: context.turnId,
      roundIndex: 1,
      stage: TraceStage.modelResponseReceived.value,
      source: 'test',
      payload: const {
        'rawContext': '[{"role":"user","content":"hi"}]',
        'rawRequestBody': '{"model":"x"}',
      },
    );

    expect(payloadRef, isNotNull);
    expect(payloadRef!['tracePayload'], isA<Map>());
    final payloadMeta = payloadRef['tracePayload'] as Map;
    expect((payloadMeta['path'] as String).contains('payload/2026-03-02/'),
        isTrue);

    final loaded = await store.readPayloadByRef(payloadRef);
    expect(loaded, isNotNull);
    expect(loaded!['traceId'], context.traceId);
    final payload = loaded['payload'] as Map<String, dynamic>;
    expect(payload['rawContext'], isNotEmpty);
    expect(payload['rawRequestBody'], contains('"model"'));
  });
}
