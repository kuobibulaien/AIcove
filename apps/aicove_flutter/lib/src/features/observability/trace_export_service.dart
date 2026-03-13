library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'trace_models.dart';
import 'trace_store.dart';

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
      output[entry.key] = _redactAny(value);
    }
    return output;
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
