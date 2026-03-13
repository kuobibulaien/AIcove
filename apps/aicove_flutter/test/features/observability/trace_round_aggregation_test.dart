import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_query_service.dart';

void main() {
  test('TraceQueryService should aggregate rounds correctly', () {
    final events = <TraceEvent>[
      TraceEvent(
        traceId: 'tr_1',
        sessionId: 's1',
        turnId: 't1',
        roundIndex: 0,
        eventSeq: 1,
        stage: TraceStage.turnStarted.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 10, 0, 0),
        endedAt: DateTime(2026, 3, 2, 10, 0, 0),
        durationMs: 0,
      ),
      TraceEvent(
        traceId: 'tr_1',
        sessionId: 's1',
        turnId: 't1',
        roundIndex: 1,
        eventSeq: 2,
        stage: TraceStage.roundRequestBuilt.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 10, 0, 1),
        endedAt: DateTime(2026, 3, 2, 10, 0, 1),
        durationMs: 0,
      ),
      TraceEvent(
        traceId: 'tr_1',
        sessionId: 's1',
        turnId: 't1',
        roundIndex: 1,
        eventSeq: 3,
        stage: TraceStage.modelResponseReceived.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 10, 0, 2),
        endedAt: DateTime(2026, 3, 2, 10, 0, 2),
        durationMs: 0,
      ),
      TraceEvent(
        traceId: 'tr_1',
        sessionId: 's1',
        turnId: 't1',
        roundIndex: 2,
        eventSeq: 4,
        stage: TraceStage.toolCallDetected.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 10, 0, 3),
        endedAt: DateTime(2026, 3, 2, 10, 0, 3),
        durationMs: 0,
      ),
    ];

    final rounds = TraceQueryService.aggregateRounds(events);
    expect(rounds.length, 3);
    expect(rounds[0].roundIndex, 0);
    expect(rounds[0].eventCount, 1);
    expect(rounds[1].roundIndex, 1);
    expect(rounds[1].eventCount, 2);
    expect(rounds[1].stages, [
      TraceStage.roundRequestBuilt.value,
      TraceStage.modelResponseReceived.value,
    ]);
    expect(rounds[2].roundIndex, 2);
    expect(rounds[2].eventCount, 1);
    expect(rounds[2].stages, [TraceStage.toolCallDetected.value]);
  });

  test('TraceQueryService should aggregate turn summary and status', () {
    final events = <TraceEvent>[
      TraceEvent(
        traceId: 'tr_2',
        sessionId: 's2',
        turnId: 't2',
        roundIndex: 0,
        eventSeq: 1,
        stage: TraceStage.turnStarted.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 11, 0, 0),
        endedAt: DateTime(2026, 3, 2, 11, 0, 0),
        durationMs: 0,
      ),
      TraceEvent(
        traceId: 'tr_2',
        sessionId: 's2',
        turnId: 't2',
        roundIndex: 1,
        eventSeq: 2,
        stage: TraceStage.toolCallDetected.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 11, 0, 1),
        endedAt: DateTime(2026, 3, 2, 11, 0, 1),
        durationMs: 0,
        meta: const {'count': 2},
      ),
      TraceEvent(
        traceId: 'tr_2',
        sessionId: 's2',
        turnId: 't2',
        roundIndex: 1,
        eventSeq: 3,
        stage: TraceStage.turnCompleted.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 11, 0, 4),
        endedAt: DateTime(2026, 3, 2, 11, 0, 4),
        durationMs: 0,
      ),
    ];

    final turns = TraceQueryService.aggregateTurns(events);
    expect(turns.length, 1);
    expect(turns.first.traceId, 'tr_2');
    expect(turns.first.status, TraceEventStatus.success.value);
    expect(turns.first.toolCallCount, 2);
    expect(turns.first.roundCount, 1);
    expect(turns.first.totalDurationMs, 4000);
  });

  test('TraceQueryService should keep chronological order by eventSeq', () {
    final events = <TraceEvent>[
      TraceEvent(
        traceId: 'tr_3',
        sessionId: 's3',
        turnId: 't3',
        roundIndex: 0,
        eventSeq: 1,
        stage: TraceStage.turnStarted.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 0, 0),
        endedAt: DateTime(2026, 3, 2, 12, 0, 0),
        durationMs: 0,
      ),
      TraceEvent(
        traceId: 'tr_3',
        sessionId: 's3',
        turnId: 't3',
        roundIndex: 1,
        eventSeq: 2,
        stage: TraceStage.modelStreamAggregated.value,
        status: TraceEventStatus.failed.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 0, 1),
        endedAt: DateTime(2026, 3, 2, 12, 0, 1),
        durationMs: 0,
      ),
      TraceEvent(
        traceId: 'tr_3',
        sessionId: 's3',
        turnId: 't3',
        roundIndex: 0,
        eventSeq: 3,
        stage: TraceStage.turnCompleted.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 0, 2),
        endedAt: DateTime(2026, 3, 2, 12, 0, 2),
        durationMs: 0,
      ),
    ];

    final ordered = TraceQueryService.buildTimelineEvents(events);
    expect(
      ordered.map((event) => event.stage).toList(),
      <String>[
        TraceStage.turnStarted.value,
        TraceStage.modelStreamAggregated.value,
        TraceStage.turnCompleted.value,
      ],
    );
  });

  test('TraceQueryService should mark turn success after fallback completes', () {
    final events = <TraceEvent>[
      TraceEvent(
        traceId: 'tr_4',
        sessionId: 's4',
        turnId: 't4',
        roundIndex: 0,
        eventSeq: 1,
        stage: TraceStage.turnStarted.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 30, 0),
        endedAt: DateTime(2026, 3, 2, 12, 30, 0),
        durationMs: 0,
      ),
      TraceEvent(
        traceId: 'tr_4',
        sessionId: 's4',
        turnId: 't4',
        roundIndex: 1,
        eventSeq: 2,
        stage: TraceStage.modelStreamAggregated.value,
        status: TraceEventStatus.failed.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 30, 1),
        endedAt: DateTime(2026, 3, 2, 12, 30, 1),
        durationMs: 0,
      ),
      TraceEvent(
        traceId: 'tr_4',
        sessionId: 's4',
        turnId: 't4',
        roundIndex: 1,
        eventSeq: 3,
        stage: TraceStage.modelResponseReceived.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 30, 2),
        endedAt: DateTime(2026, 3, 2, 12, 30, 2),
        durationMs: 0,
      ),
      TraceEvent(
        traceId: 'tr_4',
        sessionId: 's4',
        turnId: 't4',
        roundIndex: 0,
        eventSeq: 4,
        stage: TraceStage.turnCompleted.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 30, 3),
        endedAt: DateTime(2026, 3, 2, 12, 30, 3),
        durationMs: 0,
      ),
    ];

    final turns = TraceQueryService.aggregateTurns(events);
    expect(turns, hasLength(1));
    expect(turns.first.status, TraceEventStatus.success.value);
  });
}
