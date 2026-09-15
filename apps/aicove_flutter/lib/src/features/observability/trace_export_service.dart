library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/app_logger.dart';
import 'frontend_diagnostics_port.dart';
import 'trace_models.dart';
import 'trace_store.dart';

class TraceExportAdapter implements TraceExportPort {
  const TraceExportAdapter();

  @override
  Future<String?> exportTurn(String traceId) async {
    final file = await TraceExportService.exportTrace(traceId: traceId);
    return file?.readAsString();
  }
}

class TraceExportService {
  static const String _logDirName = 'logs';
  static const String _traceDirName = 'trace';
  static const String _exportDirName = 'exports';

  static Future<File?> exportTrace({
    required String traceId,
    bool redactSensitive = true,
    TraceStore? traceStore,
    Directory? debugLogDir,
  }) async {
    final store = traceStore ?? TraceStore.instance;
    await store.waitForPendingWrites();
    final events = await store.readEventsByTraceId(traceId);
    if (events.isEmpty) return null;

    final first = events.first;
    final apiLogs = await _loadApiLogsForTurn(
      sessionId: first.sessionId,
      turnId: first.turnId,
      redactSensitive: redactSensitive,
      debugLogDir: debugLogDir,
    );
    final tracePayloads = await _loadTracePayloads(
      events: events,
      store: store,
      redactSensitive: redactSensitive,
    );

    final payload = <String, dynamic>{
      'traceId': traceId,
      'sessionId': first.sessionId,
      'turnId': first.turnId,
      'exportedAt': DateTime.now().toIso8601String(),
      'events': [
        for (final event in events)
          redactSensitive ? _redactSensitive(event.toJson()) : event.toJson(),
      ],
      'apiLogs': apiLogs,
      'appLogs': await _loadAppLogsForTurn(
        first,
        redactSensitive: redactSensitive,
        debugLogDir: debugLogDir,
      ),
      'tracePayloads': tracePayloads,
    };

    final exportDir = await _resolveExportDir(debugLogDir: debugLogDir);
    final fileName =
        'trace_export_${_sanitizeForFileName(traceId)}_${DateTime.now().millisecondsSinceEpoch}.json';
    final file = File('${exportDir.path}/$fileName');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    return file;
  }

  static Future<List<Map<String, dynamic>>> _loadAppLogsForTurn(
      TraceEvent first,
      {required bool redactSensitive,
      Directory? debugLogDir}) async {
    // 等待诊断微任务入内存；文件队列尚未写完时由内存补齐。
    await Future<void>.delayed(Duration.zero);
    final logDir = await _resolveLogDir(debugLogDir: debugLogDir);
    final candidates = <String, Map<String, dynamic>>{};
    void add(Map<String, dynamic> log) {
      candidates[jsonEncode(log)] = log;
    }

    if (await logDir.exists()) {
      await for (final file in logDir.list()) {
        if (file is! File ||
            !file.path.split(Platform.pathSeparator).last.startsWith('app_') ||
            !file.path.endsWith('.jsonl')) {
          continue;
        }
        for (final line in await file.readAsLines()) {
          try {
            add((jsonDecode(line) as Map).cast<String, dynamic>());
          } catch (_) {/* 跳过损坏行。 */}
        }
      }
    }
    for (final log in AppLogger.entries.value) {
      add(log.toJson());
    }
    Map metadata(Map<String, dynamic> log) =>
        log['metadata'] is Map ? log['metadata'] as Map : const {};
    bool related(Map<String, dynamic> log) {
      final meta = metadata(log);
      final explicitTrace = log['traceId'] ?? meta['traceId'];
      if (explicitTrace is String && explicitTrace.isNotEmpty) {
        return explicitTrace == first.traceId;
      }
      return meta['conversationId'] == first.sessionId &&
          meta['turnId'] == first.turnId;
    }

    final operationIds = candidates.values
        .where(related)
        .map((log) => metadata(log)['operationId'])
        .whereType<String>()
        .toSet();
    final logs = candidates.values
        .where((log) =>
            related(log) || operationIds.contains(metadata(log)['operationId']))
        .toList()
      ..sort((a, b) =>
          (a['time'] ?? '').toString().compareTo((b['time'] ?? '').toString()));
    return logs
        .map((log) => redactSensitive ? _redactSensitive(log) : log)
        .toList();
  }

  static Future<List<Map<String, dynamic>>> _loadApiLogsForTurn({
    required String sessionId,
    required String turnId,
    required bool redactSensitive,
    Directory? debugLogDir,
  }) async {
    final logDir = await _resolveLogDir(debugLogDir: debugLogDir);
    if (!await logDir.exists()) return <Map<String, dynamic>>[];

    final files = <File>[];
    await for (final entity in logDir.list()) {
      if (entity is File &&
          entity.path.endsWith('.jsonl') &&
          entity.path.contains('${Platform.pathSeparator}api_')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final out = <Map<String, dynamic>>[];
    for (final file in files) {
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          final logSessionId = (json['sessionId'] ?? '').toString();
          final logTurnId = (json['turnId'] ?? '').toString();
          if (logSessionId != sessionId || logTurnId != turnId) {
            continue;
          }
          out.add(redactSensitive ? _redactSensitive(json) : json);
        } catch (_) {
          // 忽略损坏行
        }
      }
    }
    return out;
  }

  static Future<List<Map<String, dynamic>>> _loadTracePayloads({
    required List<TraceEvent> events,
    required TraceStore store,
    required bool redactSensitive,
  }) async {
    final out = <Map<String, dynamic>>[];
    for (final event in events) {
      if (event.payloadRef == null) continue;
      final payload = await store.readPayloadByRef(event.payloadRef);
      if (payload == null) continue;
      out.add({
        'traceId': event.traceId,
        'eventSeq': event.eventSeq,
        'stage': event.stage,
        'payload': redactSensitive ? _redactSensitive(payload) : payload,
      });
    }
    return out;
  }

  static Future<Directory> _resolveLogDir({Directory? debugLogDir}) async {
    if (debugLogDir != null) {
      if (!await debugLogDir.exists()) {
        await debugLogDir.create(recursive: true);
      }
      return debugLogDir;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${appDir.path}/$_logDirName');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    return logDir;
  }

  static Future<Directory> _resolveExportDir({Directory? debugLogDir}) async {
    final logDir = await _resolveLogDir(debugLogDir: debugLogDir);
    final traceDir = Directory('${logDir.path}/$_traceDirName');
    if (!await traceDir.exists()) {
      await traceDir.create(recursive: true);
    }
    final exportDir = Directory('${traceDir.path}/$_exportDirName');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    return exportDir;
  }

  static String _sanitizeForFileName(String raw) {
    final out = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return out.isEmpty ? 'trace' : out;
  }

  static Map<String, dynamic> _redactSensitive(Map<String, dynamic> input) {
    final output = <String, dynamic>{};
    for (final entry in input.entries) {
      final key = entry.key.toLowerCase();
      final value = entry.value;
      if (_isSensitiveKey(key)) {
        output[entry.key] = '***';
        continue;
      }
      output[entry.key] = value is String && _isDiagnosticStructure(key, value)
          ? value
          : _redactAny(value);
    }
    return output;
  }

  // 电话号码兜底规则不能吞掉系统生成的关联编号和标准时间戳。
  // 严格限定字段和格式；不能仅凭字段叫 id/time 就放行任意字符串。
  static bool _isDiagnosticStructure(String key, String value) {
    if (key == 'traceid' && RegExp(r'^tr_\d{13,20}$').hasMatch(value)) {
      return true;
    }
    if (const {'operationid', 'parentoperationid', 'pageinstanceid'}
            .contains(key) &&
        RegExp(r'^ui_\d{13,20}_\d{1,10}$').hasMatch(value)) {
      return true;
    }
    if (key == 'apprunid' &&
        RegExp(r'^run_\d{13,20}_\d{1,10}$').hasMatch(value)) {
      return true;
    }
    if (const {'messageid', 'turnid', 'sourcemessageid'}.contains(key) &&
        RegExp(r'^(?:msg|raw_msg|tts_evt)_\d{13,20}_\d{1,10}$')
            .hasMatch(value)) {
      return true;
    }
    return const {'time', 'startedat', 'endedat', 'createdat', 'exportedat'}
            .contains(key) &&
        RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?$')
            .hasMatch(value) &&
        DateTime.tryParse(value) != null;
  }

  static dynamic _redactAny(dynamic value) {
    if (value is Map<String, dynamic>) {
      return _redactSensitive(value);
    }
    if (value is Map) {
      return _redactSensitive(value.cast<String, dynamic>());
    }
    if (value is List) {
      return value.map(_redactAny).toList(growable: false);
    }
    if (value is String) {
      return _redactString(value);
    }
    return value;
  }

  static bool _isSensitiveKey(String key) {
    return key.contains('api_key') ||
        key == 'authorization' ||
        key.contains('cookie') ||
        key.contains('token') ||
        key.contains('password') ||
        key.contains('secret') ||
        key.contains('email') ||
        key.contains('phone');
  }

  static String _redactString(String value) {
    var out = value;
    out = out.replaceAllMapped(
      RegExp(r'(Bearer\s+)[A-Za-z0-9\-_\.]+', caseSensitive: false),
      (m) => '${m.group(1)}***',
    );
    out = out.replaceAllMapped(
      RegExp(r'"api_key"\s*:\s*"[^"]+"', caseSensitive: false),
      (_) => '"api_key":"***"',
    );
    out = out.replaceAllMapped(
      RegExp(
        r'([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})',
        caseSensitive: false,
      ),
      (_) => '***@***',
    );
    out = out.replaceAllMapped(
      RegExp(r'(\+?\d[\d\s\-]{7,}\d)'),
      (_) => '***',
    );
    return out;
  }
}
