import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';

void main() {
  group('TraceStore event order', () {
    test('eventSeq should be monotonic within one trace', () async {
      final temp = await Directory.systemTemp.createTemp('trace_store_order_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final store = TraceStore(rootDirResolver: () async => temp);
      await store.initialize();
      final context =
          await store.startTurn(sessionId: 'session_1', turnId: 'turn_1');
      await store.record(
        traceId: context.traceId,
        stage: TraceStage.historyPrepared,
        source: 'test',
      );
      await store.record(
        traceId: context.traceId,
        stage: TraceStage.apiConfigReady,
        source: 'test',
      );
      await store.waitForPendingWrites();

      final events = await store.readEventsByTraceId(context.traceId);
      expect(events.map((e) => e.eventSeq).toList(), [1, 2, 3]);
      expect(events.map((e) => e.stage).toList(), [
        TraceStage.turnStarted.value,
        TraceStage.historyPrepared.value,
        TraceStage.apiConfigReady.value,
      ]);
    });

    test('concurrent record should remain ordered and continuous', () async {
      final temp =
          await Directory.systemTemp.createTemp('trace_store_concurrent_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final store = TraceStore(rootDirResolver: () async => temp);
      await store.initialize();
      final context =
          await store.startTurn(sessionId: 'session_2', turnId: 'turn_2');

      final futures = <Future<void>>[];
      for (var i = 0; i < 40; i++) {
        futures.add(
          Future<void>(() async {
            await store.record(
              traceId: context.traceId,
              stage: TraceStage.modelRequestSent,
              source: 'test',
              roundIndex: 1,
              meta: {'i': i},
            );
          }),
        );
      }
      await Future.wait(futures);
      await store.waitForPendingWrites();

      final events = await store.readEventsByTraceId(context.traceId);
      final seqs = events.map((e) => e.eventSeq).toList();
      final expected = List<int>.generate(events.length, (index) => index + 1);
      expect(seqs, expected);
      expect(seqs.toSet().length, seqs.length);
    });
  });
}
