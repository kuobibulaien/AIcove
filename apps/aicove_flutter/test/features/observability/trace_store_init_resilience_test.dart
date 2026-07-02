import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';

void main() {
  test('initialize failure should not block trace recording flow', () async {
    final store = TraceStore(
      rootDirResolver: () async => throw FileSystemException('boom'),
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
