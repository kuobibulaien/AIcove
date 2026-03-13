library;

enum TraceStage {
  turnStarted('TURN_STARTED'),
  userMessagePersisted('USER_MESSAGE_PERSISTED'),
  historyPrepared('HISTORY_PREPARED'),
  apiConfigReady('API_CONFIG_READY'),
  roundRequestBuilt('ROUND_REQUEST_BUILT'),
  modelRequestSent('MODEL_REQUEST_SENT'),
  modelResponseReceived('MODEL_RESPONSE_RECEIVED'),
  modelStreamAggregated('MODEL_STREAM_AGGREGATED'),
  toolCallDetected('TOOL_CALL_DETECTED'),
  toolExecStarted('TOOL_EXEC_STARTED'),
  toolExecFinished('TOOL_EXEC_FINISHED'),
  roundCompleted('ROUND_COMPLETED'),
  finalReplyReady('FINAL_REPLY_READY'),
  messageDelivered('MESSAGE_DELIVERED'),
  turnCompleted('TURN_COMPLETED'),
  turnFailed('TURN_FAILED');

  const TraceStage(this.value);
  final String value;
}

enum TraceEventStatus {
  success('success'),
  failed('failed'),
  running('running');

  const TraceEventStatus(this.value);
  final String value;
}

class TraceEvent {
  final String traceId;
  final String sessionId;
  final String turnId;
  final int roundIndex;
  final int eventSeq;
  final String stage;
  final String status;
  final String source;
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationMs;
  final Map<String, dynamic>? payloadRef;
  final Map<String, dynamic>? meta;

  const TraceEvent({
    required this.traceId,
    required this.sessionId,
    required this.turnId,
    required this.roundIndex,
    required this.eventSeq,
    required this.stage,
    required this.status,
    required this.source,
    required this.startedAt,
    required this.endedAt,
    required this.durationMs,
    this.payloadRef,
    this.meta,
  });

  Map<String, dynamic> toJson() {
    return {
      'traceId': traceId,
      'sessionId': sessionId,
      'turnId': turnId,
      'roundIndex': roundIndex,
      'eventSeq': eventSeq,
      'stage': stage,
      'status': status,
      'source': source,
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt.toIso8601String(),
      'durationMs': durationMs,
      if (payloadRef != null) 'payloadRef': payloadRef,
      if (meta != null) 'meta': meta,
    };
  }

  factory TraceEvent.fromJson(Map<String, dynamic> json) {
    return TraceEvent(
      traceId: (json['traceId'] ?? '').toString(),
      sessionId: (json['sessionId'] ?? '').toString(),
      turnId: (json['turnId'] ?? '').toString(),
      roundIndex: _readInt(json['roundIndex']),
      eventSeq: _readInt(json['eventSeq']),
      stage: (json['stage'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      startedAt: DateTime.tryParse((json['startedAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      endedAt: DateTime.tryParse((json['endedAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      durationMs: _readInt(json['durationMs']),
      payloadRef: _readMap(json['payloadRef']),
      meta: _readMap(json['meta']),
    );
  }

  static int _readInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString()) ?? 0;
  }

  static Map<String, dynamic>? _readMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return null;
  }
}

class TraceContext {
  final String traceId;
  final String sessionId;
  final String turnId;

  const TraceContext({
    required this.traceId,
    required this.sessionId,
    required this.turnId,
  });
}
