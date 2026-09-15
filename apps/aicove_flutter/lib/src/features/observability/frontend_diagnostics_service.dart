import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'diagnostic_error_summary.dart';

import '../../core/app_logger.dart';
import 'frontend_diagnostics_port.dart';

/// 复用应用日志存储，不另起数据库。采集不同步通知 UI、不依赖采集成功。
class FrontendDiagnosticsService implements FrontendDiagnosticsPort {
  FrontendDiagnosticsService({void Function(LogEntry)? sink})
      : _sink = sink ?? AppLogger.add;

  static final FrontendDiagnosticsService instance =
      FrontendDiagnosticsService();
  final void Function(LogEntry) _sink;
  final _pendingSends = <String, FrontendDiagnosticContext>{};
  final _turns = <String, FrontendDiagnosticContext>{};
  final _messages = <String, FrontendDiagnosticContext>{};
  final _once = <String>{};
  final _pending = ListQueue<LogEntry>();
  final String appRunId = 'run_${DateTime.now().microsecondsSinceEpoch}_$pid';
  final Stopwatch _runtimeClock = Stopwatch()..start();
  Map<String, Object?> _identity = const {'buildId': 'unknown'};
  int _eventSequence = 0;
  int _serial = 0;

  void setRuntimeIdentity(Map<String, Object?> identity) {
    _identity = Map.unmodifiable(identity);
    begin(FrontendStage.runtimeStarted);
  }

  Map<String, Object?> get _envelope => {
        'schemaVersion': 2,
        'appRunId': appRunId,
        'sequence': ++_eventSequence,
        'monotonicUs': _runtimeClock.elapsedMicroseconds,
        'pid': pid,
        'isolateId': Isolate.current.hashCode,
        'build': _identity,
        'writerHealth': AppLogger.diagnosticHealth,
      };
  bool _scheduled = false;
  int _dropped = 0;
  @override
  bool enabled = true;

  @override
  FrontendDiagnosticContext begin(FrontendStage stage,
      {String? conversationId}) {
    final context = FrontendDiagnosticContext(
      operationId: 'ui_${DateTime.now().microsecondsSinceEpoch}_${++_serial}',
      conversationId: conversationId,
    );
    if (enabled &&
        stage == FrontendStage.sendRequested &&
        conversationId != null) {
      _put(_pendingSends, conversationId, context, 32);
    }
    record(context, stage);
    return context;
  }

  @override
  FrontendDiagnosticContext child(
      FrontendDiagnosticContext? parent, FrontendStage stage,
      {String? conversationId, String? messageId}) {
    final context = FrontendDiagnosticContext(
      operationId: 'ui_${DateTime.now().microsecondsSinceEpoch}_${++_serial}',
      parentOperationId: parent?.operationId,
      conversationId: parent?.conversationId ?? conversationId,
      turnId: parent?.turnId,
      traceId: parent?.traceId,
    );
    record(context, stage,
        messageId: messageId,
        facts: const DiagnosticFacts(phase: DiagnosticPhase.start));
    return context;
  }

  @override
  FrontendDiagnosticContext linkTurn(
      {required String conversationId,
      required String turnId,
      required String traceId}) {
    final pending = _pendingSends.remove(conversationId);
    // 不把很久以前取消/未执行的操作误绑到下一轮。
    final context = (pending != null && pending.elapsedMs < 30000
            ? pending
            : FrontendDiagnosticContext(
                operationId:
                    'ui_${DateTime.now().microsecondsSinceEpoch}_${++_serial}',
                conversationId: conversationId,
              ))
        .linked(turnId, traceId);
    if (enabled) _put(_turns, turnId, context, 128);
    record(context, FrontendStage.turnLinked);
    return context;
  }

  @override
  FrontendDiagnosticContext? forTurn(String? turnId) =>
      enabled ? _turns[turnId] : null;

  @override
  void bindMessage(String messageId, FrontendDiagnosticContext? context) {
    if (!enabled || context == null) return;
    _put(_messages, messageId, context, 512);
  }

  @override
  FrontendDiagnosticContext? forMessage(String messageId) =>
      enabled ? _messages[messageId] : null;

  @override
  void record(
    FrontendDiagnosticContext? context,
    FrontendStage stage, {
    String? messageId,
    int? itemCount,
    bool once = false,
    Object? error,
    StackTrace? stackTrace,
    DiagnosticFacts? facts,
  }) {
    if (!enabled || context == null) return;
    final key = '${context.operationId}:${stage.name}:${messageId ?? ''}';
    if (once && !_once.add(key)) return;
    while (_once.length > 2048) {
      _once.remove(_once.first);
    }
    final metadata = <String, dynamic>{
      ..._envelope,
      if (context.parentOperationId != null)
        'parentOperationId': context.parentOperationId,
      if (facts != null) ...{
        'phase': facts.phase.name,
        if (facts.reason != null) 'reason': facts.reason!.name,
        if (facts.sourceMessageId != null)
          'sourceMessageId': facts.sourceMessageId,
        if (facts.pageInstanceId != null)
          'pageInstanceId': facts.pageInstanceId,
        'state': {
          for (final entry in facts.state.entries.take(32))
            if (RegExp(r'^[a-zA-Z][a-zA-Z0-9]{0,47}$').hasMatch(entry.key) &&
                (entry.value is bool ||
                    (entry.value is num && (entry.value as num).isFinite)))
              entry.key: entry.value,
        },
      },
      'category': 'frontend',
      'event': stage.name,
      'operationId': context.operationId,
      'elapsedMs': context.elapsedMs,
      if (context.conversationId != null)
        'conversationId': context.conversationId,
      if (context.turnId != null) 'turnId': context.turnId,
      if (context.traceId != null) 'traceId': context.traceId,
      if (messageId != null) 'messageId': messageId,
      if (itemCount != null) 'itemCount': itemCount,
      if (error != null) ...diagnosticErrorSummary(error, stackTrace),
      if (error == null && stackTrace != null)
        'codeLocations': _codeLocations(stackTrace),
    };
    if (_pending.length >= 128) {
      _pending.removeFirst();
      _dropped++;
    }
    _pending.add(LogEntry(
      time: DateTime.now(),
      level: stage.isError
          ? LogLevel.error
          : stage == FrontendStage.historyColdLoad &&
                  facts?.phase == DiagnosticPhase.end &&
                  context.elapsedMs >= 500
              ? LogLevel.warning
              : LogLevel.info,
      source: 'FrontendDiagnostics',
      message: stage.label,
      traceId: context.traceId,
      metadata: metadata,
    ));
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(_flush);
  }

  void _flush() {
    _scheduled = false;
    final batch = List<LogEntry>.from(_pending);
    _pending.clear();
    if (!enabled) return;
    for (final entry in batch) {
      try {
        _sink(entry);
      } catch (_) {
        _dropped++;
      }
    }
    if (_dropped > 0) {
      final count = _dropped;
      _dropped = 0;
      try {
        _sink(LogEntry(
            time: DateTime.now(),
            level: LogLevel.warning,
            source: 'FrontendDiagnostics',
            message: '部分诊断记录未保存',
            metadata: {
              ..._envelope,
              'category': 'frontend',
              'event': 'diagnosticLoss',
              'droppedCount': count
            }));
      } catch (_) {/* 日志故障不得再次触发异常采集，避免递归。 */}
    }
  }

  static List<String> _codeLocations(StackTrace stack) =>
      RegExp(r'(?:package:|dart:)[^\s)]+')
          .allMatches(stack.toString())
          .take(12)
          .map((m) => m.group(0)!)
          .toList(growable: false);

  static void _put<K, V>(Map<K, V> map, K key, V value, int limit) {
    map.remove(key);
    map[key] = value;
    while (map.length > limit) {
      map.remove(map.keys.first);
    }
  }
}
