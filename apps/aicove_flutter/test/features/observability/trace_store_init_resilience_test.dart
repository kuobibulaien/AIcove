import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';

void main() {
  test(
    'batches normal events and flushes across days, on failure and before reads',
    () async {
      final root = await Directory.systemTemp.createTemp('trace_batch');
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime(2026, 1, 1);
      final store = TraceStore(
        rootDirResolver: () async => root,
        nowProvider: () => now,
      );
      addTearDown(store.flush);
      final dayOne = File('${root.path}/trace/index_2026-01-01.jsonl');
      final dayTwo = File('${root.path}/trace/index_2026-01-02.jsonl');
      Future<void> record([
        TraceEventStatus status = TraceEventStatus.success,
      ]) async {
        await store.record(
          traceId: 'batch',
          stage: TraceStage.turnStarted,
          status: status,
        );
      }

      await record();
      await record();
      expect(dayOne.existsSync(), isFalse);
      now = DateTime(2026, 1, 2);
      await record();
      await record(TraceEventStatus.failed);
      expect(await dayOne.readAsLines(), hasLength(2));
      expect(await dayTwo.readAsLines(), hasLength(2));
      await record();
      expect(
        (await store.readEventsByTraceId('batch')).map((e) => e.eventSeq),
        [1, 2, 3, 4, 5],
      );
    },
  );

  test('initialize failure should not block trace recording flow', () async {
    final store = TraceStore(
      rootDirResolver: () async => throw const FileSystemException('boom'),
    );

    await store.initialize();
    final context = await store.startTurn(
      sessionId: 'session_fail',
      turnId: 'turn_fail',
    );

    await store.record(
      traceId: context.traceId,
      stage: TraceStage.turnFailed,
      status: TraceEventStatus.failed,
      source: 'test',
      meta: {'error': 'network timeout'},
    );

    final memoryEvents = store.debugInMemoryEvents();
    expect(memoryEvents, isNotEmpty);
    expect(memoryEvents.first.stage, TraceStage.turnStarted.value);
    expect(memoryEvents.last.stage, TraceStage.turnFailed.value);
  });
}
