library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'trace_models.dart';

typedef TraceRootDirResolver = Future<Directory> Function();
typedef TraceNowProvider = DateTime Function();

class TraceStore {
  TraceStore({
    TraceRootDirResolver? rootDirResolver,
    TraceNowProvider? nowProvider,
  })  : _rootDirResolver = rootDirResolver ?? _defaultRootDirResolver,
        _nowProvider = nowProvider ?? DateTime.now;

  static final TraceStore instance = TraceStore();

  static const String _logDirName = 'logs';
  static const String _traceDirName = 'trace';
  static const String _payloadDirName = 'payload';
  static const String _indexPrefix = 'index_';

  final TraceRootDirResolver _rootDirResolver;
  final TraceNowProvider _nowProvider;

  final ValueNotifier<List<TraceEvent>> entries =
      ValueNotifier<List<TraceEvent>>(<TraceEvent>[]);

  final Map<String, _TraceRuntimeState> _runtimeStates =
      <String, _TraceRuntimeState>{};
  final List<TraceEvent> _preInitBuffer = <TraceEvent>[];

  Future<void> _writeChain = Future<void>.value();
  Completer<void>? _initCompleter;
  bool _initialized = false;
  bool _storageAvailable = true;
  String? _cachedTraceDirPath;
  String? _cachedPayloadRootDirPath;
  String? _cachedIndexFilePath;
  int? _cachedDateKey;
  int _payloadFileSeq = 0;

  static Future<Directory> _defaultRootDirResolver() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/$_logDirName');
  }

  Future<void> initialize() async {
    if (_initialized) return;
    if (_initCompleter != null) return _initCompleter!.future;

    final completer = Completer<void>();
    _initCompleter = completer;

    try {
      await _resolveTodayIndexPath();
    } catch (e) {
      _storageAvailable = false;
      if (kDebugMode) {
        debugPrint('TraceStore initialize failed: $e');
      }
    } finally {
      _initialized = true;
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (_storageAvailable && _preInitBuffer.isNotEmpty) {
        final buffered = List<TraceEvent>.from(_preInitBuffer);
        _preInitBuffer.clear();
        for (final event in buffered) {
          _enqueueWrite(event);
        }
      }
    }
  }

  Future<TraceContext> startTurn({
    required String sessionId,
    required String turnId,
    String source = 'ChatActions',
    Map<String, dynamic>? meta,
  }) async {
    await initialize();
    final now = _nowProvider();
    final traceId = 'tr_${now.microsecondsSinceEpoch}';

    _runtimeStates[traceId] = _TraceRuntimeState(
      sessionId: sessionId,
      turnId: turnId,
      nextEventSeq: 0,
    );

    await record(
      traceId: traceId,
      stage: TraceStage.turnStarted,
      status: TraceEventStatus.success,
      source: source,
      meta: meta,
      startedAt: now,
      endedAt: now,
      durationMs: 0,
    );

    return TraceContext(
      traceId: traceId,
      sessionId: sessionId,
      turnId: turnId,
    );
  }

  Future<TraceEvent> record({
    required String traceId,
    required TraceStage stage,
    TraceEventStatus status = TraceEventStatus.success,
    String source = 'Unknown',
    int roundIndex = 0,
    Map<String, dynamic>? payloadRef,
    Map<String, dynamic>? meta,
    DateTime? startedAt,
    DateTime? endedAt,
    int? durationMs,
    String? sessionId,
    String? turnId,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    final state = _runtimeStates.putIfAbsent(
      traceId,
      () => _TraceRuntimeState(
        sessionId: sessionId ?? '',
        turnId: turnId ?? '',
        nextEventSeq: 0,
      ),
    );
    if (sessionId != null && sessionId.isNotEmpty) {
      state.sessionId = sessionId;
    }
    if (turnId != null && turnId.isNotEmpty) {
      state.turnId = turnId;
    }

    final now = _nowProvider();
    final safeStart = startedAt ?? now;
    final safeEnd = endedAt ?? now;
    final computedDuration = durationMs ??
        (safeEnd.isAfter(safeStart)
            ? safeEnd.difference(safeStart).inMilliseconds
            : 0);

    final event = TraceEvent(
      traceId: traceId,
      sessionId: state.sessionId,
      turnId: state.turnId,
      roundIndex: roundIndex,
      eventSeq: ++state.nextEventSeq,
      stage: stage.value,
      status: status.value,
      source: source,
      startedAt: safeStart,
      endedAt: safeEnd,
      durationMs: computedDuration,
      payloadRef:
          payloadRef == null ? null : Map<String, dynamic>.from(payloadRef),
      meta: meta == null ? null : Map<String, dynamic>.from(meta),
    );

    final list = List<TraceEvent>.from(entries.value)..add(event);
    if (list.length > 400) {
      list.removeRange(0, list.length - 400);
    }
    entries.value = list;

    if (_storageAvailable) {
      if (_initialized) {
        _enqueueWrite(event);
      } else {
        _preInitBuffer.add(event);
      }
    }

    return event;
  }

  Future<List<TraceEvent>> readEventsByTraceId(String traceId) async {
    await initialize();
    if (!_storageAvailable) {
      return entries.value.where((e) => e.traceId == traceId).toList()
        ..sort((a, b) => a.eventSeq.compareTo(b.eventSeq));
    }

    final traceDirPath = await _resolveTraceDirPath();
    final traceDir = Directory(traceDirPath);
    if (!await traceDir.exists()) {
      return <TraceEvent>[];
    }

    final files = <File>[];
    await for (final entity in traceDir.list()) {
      if (entity is File &&
          entity.path.endsWith('.jsonl') &&
          entity.path.contains(_indexPrefix)) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final events = <TraceEvent>[];
    for (final file in files) {
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          final event = TraceEvent.fromJson(json);
          if (event.traceId == traceId) {
            events.add(event);
          }
        } catch (_) {
          // 跳过损坏行，防止单行污染整份导出
        }
      }
    }

    events.sort((a, b) => a.eventSeq.compareTo(b.eventSeq));
    return events;
  }

  Future<List<TraceEvent>> readRecentEvents({int maxDays = 7}) async {
    await initialize();
    if (!_storageAvailable) {
      final inMemory = List<TraceEvent>.from(entries.value)
        ..sort((a, b) {
          final byStart = a.startedAt.compareTo(b.startedAt);
          if (byStart != 0) return byStart;
          return a.eventSeq.compareTo(b.eventSeq);
        });
      return inMemory;
    }

    final traceDirPath = await _resolveTraceDirPath();
    final traceDir = Directory(traceDirPath);
    if (!await traceDir.exists()) {
      return <TraceEvent>[];
    }

    final files = <File>[];
    final cutoff = _nowProvider().subtract(Duration(days: maxDays));
    await for (final entity in traceDir.list()) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      final fileName = entity.path.split(Platform.pathSeparator).last;
      if (!fileName.startsWith(_indexPrefix)) continue;
      final match = RegExp(r'^index_(\d{4})-(\d{2})-(\d{2})\.jsonl$')
          .firstMatch(fileName);
      if (match != null) {
        final fileDate = DateTime(
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
          int.parse(match.group(3)!),
        );
        if (fileDate.isBefore(cutoff)) {
          continue;
        }
      }
      files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final events = <TraceEvent>[];
    for (final file in files) {
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          events.add(TraceEvent.fromJson(json));
        } catch (_) {
          // 跳过损坏行，防止单行污染整份读取
        }
      }
    }
    events.sort((a, b) {
      final byStart = a.startedAt.compareTo(b.startedAt);
      if (byStart != 0) return byStart;
      final byTrace = a.traceId.compareTo(b.traceId);
      if (byTrace != 0) return byTrace;
      return a.eventSeq.compareTo(b.eventSeq);
    });
    return events;
  }

  Future<Map<String, dynamic>?> writePayload({
    required String traceId,
    required String sessionId,
    required String turnId,
    required String stage,
    required String source,
    required Map<String, dynamic> payload,
    int? roundIndex,
    DateTime? now,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    if (!_storageAvailable) {
      return null;
    }

    final ts = now ?? _nowProvider();
    final dayTag =
        '${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')}';
    final stageTag = _sanitizeFileSegment(stage);
    final traceTag = _sanitizeFileSegment(traceId);
    final turnTag = _sanitizeFileSegment(turnId);
    final seqTag = (++_payloadFileSeq).toString().padLeft(4, '0');
    final fileName =
        'payload_${ts.microsecondsSinceEpoch}_${seqTag}_${traceTag}_$turnTag'
        '${roundIndex == null ? '' : '_r$roundIndex'}_$stageTag.json';
    final dayDirPath = await _resolvePayloadDayDirPath(dayTag);
    final fullPath = '$dayDirPath/$fileName';
    final relativePath = '$_payloadDirName/$dayTag/$fileName';

    final envelope = <String, dynamic>{
      'schema': 'trace_payload_v1',
      'traceId': traceId,
      'sessionId': sessionId,
      'turnId': turnId,
      if (roundIndex != null) 'roundIndex': roundIndex,
      'stage': stage,
      'source': source,
      'createdAt': ts.toIso8601String(),
      'payload': payload,
    };
    final content = const JsonEncoder.withIndent('  ').convert(envelope);

    try {
      final file = File(fullPath);
      await file.writeAsString(content, flush: true);
      return <String, dynamic>{
        'tracePayload': <String, dynamic>{
          'version': 1,
          'path': relativePath,
          'createdAt': ts.toIso8601String(),
          'sizeBytes': content.length,
          'stage': stage,
          'source': source,
        },
      };
    } catch (e) {
      _storageAvailable = false;
      if (kDebugMode) {
        debugPrint('TraceStore payload write failed: $e');
      }
      return null;
    }
  }

  Future<Map<String, dynamic>?> readPayloadByRef(
      Map<String, dynamic>? payloadRef) async {
    await initialize();
    if (payloadRef == null || payloadRef.isEmpty) return null;
    final payloadMeta = payloadRef['tracePayload'];
    if (payloadMeta is! Map) return null;
    final payloadMap = payloadMeta.cast<String, dynamic>();
    final relativePath = payloadMap['path']?.toString() ?? '';
    if (relativePath.trim().isEmpty) return null;

    final file = await _resolvePayloadFile(relativePath);
    if (file == null || !await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> tryResolveTraceDirPath() async {
    await initialize();
    if (!_storageAvailable) return null;
    return _resolveTraceDirPath();
  }

  Future<void> waitForPendingWrites() async {
    await _writeChain;
  }

  @visibleForTesting
  List<TraceEvent> debugInMemoryEvents() =>
      List<TraceEvent>.from(entries.value);

  @visibleForTesting
  void debugResetForTest() {
    _runtimeStates.clear();
    _preInitBuffer.clear();
    entries.value = <TraceEvent>[];
    _writeChain = Future<void>.value();
    _initCompleter = null;
    _initialized = false;
    _storageAvailable = true;
    _cachedTraceDirPath = null;
    _cachedPayloadRootDirPath = null;
    _cachedIndexFilePath = null;
    _cachedDateKey = null;
    _payloadFileSeq = 0;
  }

  void _enqueueWrite(TraceEvent event) {
    final line = '${jsonEncode(event.toJson())}\n';
    _writeChain = _writeChain.then((_) => _appendLine(line));
  }

  Future<void> _appendLine(String line) async {
    try {
      final path = await _resolveTodayIndexPath();
      final file = File(path);
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (e) {
      _storageAvailable = false;
      if (kDebugMode) {
        debugPrint('TraceStore append failed: $e');
      }
    }
  }

  Future<String> _resolveTraceDirPath() async {
    if (_cachedTraceDirPath != null) return _cachedTraceDirPath!;

    final root = await _rootDirResolver();
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    final traceDir = Directory('${root.path}/$_traceDirName');
    if (!await traceDir.exists()) {
      await traceDir.create(recursive: true);
    }
    _cachedTraceDirPath = traceDir.path;
    return _cachedTraceDirPath!;
  }

  Future<String> _resolvePayloadRootDirPath() async {
    if (_cachedPayloadRootDirPath != null) return _cachedPayloadRootDirPath!;
    final traceDirPath = await _resolveTraceDirPath();
    final payloadRoot = Directory('$traceDirPath/$_payloadDirName');
    if (!await payloadRoot.exists()) {
      await payloadRoot.create(recursive: true);
    }
    _cachedPayloadRootDirPath = payloadRoot.path;
    return _cachedPayloadRootDirPath!;
  }

  Future<String> _resolvePayloadDayDirPath(String dayTag) async {
    final payloadRootPath = await _resolvePayloadRootDirPath();
    final dayDir = Directory('$payloadRootPath/$dayTag');
    if (!await dayDir.exists()) {
      await dayDir.create(recursive: true);
    }
    return dayDir.path;
  }

  Future<File?> _resolvePayloadFile(String refPath) async {
    final normalized = refPath.replaceAll('\\', '/').trim();
    if (normalized.isEmpty) return null;
    if (normalized.startsWith('/') || normalized.contains(':')) {
      return File(normalized);
    }
    final traceDirPath = await _resolveTraceDirPath();
    if (normalized.startsWith('$_payloadDirName/')) {
      return File('$traceDirPath/$normalized');
    }
    return File('$traceDirPath/$_payloadDirName/$normalized');
  }

  String _sanitizeFileSegment(String raw) {
    final safe = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return safe.isEmpty ? 'unknown' : safe;
  }

  Future<String> _resolveTodayIndexPath() async {
    final now = _nowProvider();
    final dateKey = now.year * 10000 + now.month * 100 + now.day;
    if (_cachedDateKey != null && _cachedDateKey != dateKey) {
      _cachedIndexFilePath = null;
    }
    if (_cachedIndexFilePath != null) {
      return _cachedIndexFilePath!;
    }

    final traceDirPath = await _resolveTraceDirPath();
    final fileName =
        '$_indexPrefix${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.jsonl';
    _cachedIndexFilePath = '$traceDirPath/$fileName';
    _cachedDateKey = dateKey;
    return _cachedIndexFilePath!;
  }
}

class _TraceRuntimeState {
  String sessionId;
  String turnId;
  int nextEventSeq;

  _TraceRuntimeState({
    required this.sessionId,
    required this.turnId,
    required this.nextEventSeq,
  });
}
