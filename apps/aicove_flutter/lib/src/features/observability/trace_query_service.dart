library;

import 'trace_models.dart';

class TraceTurnSummary {
  final String traceId;
  final String sessionId;
  final String turnId;
  final DateTime startedAt;
  final DateTime endedAt;
  final int totalDurationMs;
  final int roundCount;
  final int eventCount;
  final int toolCallCount;
  final String status;

  const TraceTurnSummary({
    required this.traceId,
    required this.sessionId,
    required this.turnId,
    required this.startedAt,
    required this.endedAt,
    required this.totalDurationMs,
    required this.roundCount,
    required this.eventCount,
    required this.toolCallCount,
    required this.status,
  });

  bool get isFailed => status == TraceEventStatus.failed.value;
}

class TraceRoundSummary {
  final int roundIndex;
  final int eventCount;
  final List<String> stages;

  const TraceRoundSummary({
    required this.roundIndex,
    required this.eventCount,
    required this.stages,
  });
}

class TraceQueryService {
  static List<TraceTurnSummary> aggregateTurns(List<TraceEvent> events) {
    final grouped = <String, List<TraceEvent>>{};
    for (final event in events) {
      grouped.putIfAbsent(event.traceId, () => <TraceEvent>[]).add(event);
    }

    final turns = <TraceTurnSummary>[];
    for (final entry in grouped.entries) {
      final current = sortEvents(entry.value);
      if (current.isEmpty) continue;
      final first = current.first;
      final last = current.last;

      final roundIndexes = <int>{};
      var toolCallCount = 0;
      for (final event in current) {
        if (event.roundIndex > 0) {
          roundIndexes.add(event.roundIndex);
        }
        if (event.stage == TraceStage.toolCallDetected.value) {
          final count = _safeInt(event.meta?['count']) ?? 1;
          toolCallCount += count > 0 ? count : 1;
        }
      }
      final status = _resolveTurnStatus(current);

      turns.add(
        TraceTurnSummary(
          traceId: first.traceId,
          sessionId: first.sessionId,
          turnId: first.turnId,
          startedAt: first.startedAt,
          endedAt: last.endedAt,
          totalDurationMs:
              last.endedAt.difference(first.startedAt).inMilliseconds,
          roundCount: roundIndexes.isEmpty ? 1 : roundIndexes.length,
          eventCount: current.length,
          toolCallCount: toolCallCount,
          status: status,
        ),
      );
    }

    turns.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return turns;
  }

  static List<TraceEvent> sortEvents(List<TraceEvent> events) {
    final copy = List<TraceEvent>.from(events);
    copy.sort((a, b) {
      final bySeq = a.eventSeq.compareTo(b.eventSeq);
      if (bySeq != 0) return bySeq;
      return a.startedAt.compareTo(b.startedAt);
    });
    return copy;
  }

  static List<TraceEvent> buildTimelineEvents(List<TraceEvent> events) {
    return sortEvents(events);
  }

  static List<TraceRoundSummary> aggregateRounds(List<TraceEvent> events) {
    final grouped = <int, List<TraceEvent>>{};
    for (final event in events) {
      grouped.putIfAbsent(event.roundIndex, () => <TraceEvent>[]).add(event);
    }

    final rounds = <TraceRoundSummary>[];
    final indexes = grouped.keys.toList()..sort();
    for (final index in indexes) {
      final current = grouped[index]!
        ..sort((a, b) => a.eventSeq.compareTo(b.eventSeq));
      rounds.add(
        TraceRoundSummary(
          roundIndex: index,
          eventCount: current.length,
          stages: current.map((e) => e.stage).toList(growable: false),
        ),
      );
    }
    return rounds;
  }

  static int? _safeInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }

  static String _resolveTurnStatus(List<TraceEvent> events) {
    TraceEvent? terminalEvent;
    for (var i = events.length - 1; i >= 0; i--) {
      final event = events[i];
      if (event.stage == TraceStage.turnCompleted.value ||
          event.stage == TraceStage.turnFailed.value) {
        terminalEvent = event;
        break;
      }
    }

    if (terminalEvent != null) {
      if (terminalEvent.stage == TraceStage.turnFailed.value ||
          terminalEvent.status == TraceEventStatus.failed.value) {
        return TraceEventStatus.failed.value;
      }
      return TraceEventStatus.success.value;
    }

    final last = events.last;
    if (last.status == TraceEventStatus.failed.value) {
      return TraceEventStatus.failed.value;
    }
    return TraceEventStatus.running.value;
  }
}
