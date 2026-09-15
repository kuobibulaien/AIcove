import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final diagnosticLogName =
    RegExp(r'^(?:(?:app|api|trace)_|trace/index_)(\d{4}-\d{2}-\d{2})\.jsonl$');
final _atom = RegExp(r'^[A-Za-z0-9_.:-]{1,160}$');
bool _isAtom(Object? value) => value is String && _atom.hasMatch(value);
bool _isNumber(Object? value) =>
    value is num && value.isFinite && value.abs() < 1e20;

Map<String, Object?> _numbers(Object? value) => value is Map
    ? {
        for (final entry in value.entries.take(40))
          if (_isAtom(entry.key) &&
              (entry.value is bool || _isNumber(entry.value)))
            entry.key as String: entry.value,
      }
    : {};

/// 与电脑采集器允许列表一致；离开应用沙箱之前即丢弃正文和未知字段。
Map<String, Object?>? sanitizeDiagnosticEntry(Object? entry, String name) {
  if (entry is! Map) return null;
  final rawTime = entry['time'] ?? entry['startedAt'];
  final time = rawTime is String ? DateTime.tryParse(rawTime) : null;
  if (time == null) return null;
  final result = <String, Object?>{'time': time.toUtc().toIso8601String()};
  void atoms(Map source, Map<String, Object?> target, List<String> keys) {
    for (final key in keys) {
      if (_isAtom(source[key])) target[key] = source[key];
    }
  }

  atoms(entry, result, ['level']);
  final meta = entry['metadata'];
  if (meta is Map && meta['category'] == 'frontend') {
    final safe = <String, Object?>{'category': 'frontend'};
    for (final key in [
      'schemaVersion',
      'sequence',
      'monotonicUs',
      'pid',
      'isolateId',
      'elapsedMs',
      'itemCount',
      'droppedCount',
      'timeoutMs',
      'rangeStart',
      'rangeEnd',
    ]) {
      if (_isNumber(meta[key])) safe[key] = meta[key];
    }
    atoms(meta, safe, [
      'appRunId',
      'event',
      'operationId',
      'parentOperationId',
      'conversationId',
      'traceId',
      'turnId',
      'messageId',
      'sourceMessageId',
      'pageInstanceId',
      'phase',
      'reason',
      'errorType',
    ]);
    for (final key in [
      'stackTruncated',
      'stackNonCodeFramesOmitted',
      'errorMessageOmitted',
    ]) {
      if (meta[key] is bool) safe[key] = meta[key];
    }
    final summary = meta['errorSummary'];
    if (const {
          'No element',
          'Too many elements',
          'Future already completed',
          'Cannot add new events after calling close',
          'timeout',
          'range_error',
          'free_form_message_omitted',
        }.contains(summary) ||
        summary is String &&
            RegExp(r'^platform:[A-Za-z_][A-Za-z0-9_]{0,47}$')
                .hasMatch(summary)) {
      safe['errorSummary'] = summary;
    }
    safe['state'] = _numbers(meta['state']);
    final health = _numbers(meta['writerHealth']);
    if (meta['writerHealth'] is Map) {
      atoms(meta['writerHealth'] as Map, health, ['lastErrorType']);
    }
    safe['writerHealth'] = health;
    final locations = meta['codeLocations'];
    if (locations is List) {
      safe['codeLocations'] = [
        for (final location in locations.take(64))
          if (location is String &&
              location.length <= 512 &&
              RegExp(r'^(?:package:|dart:)[A-Za-z0-9_./:-]+$')
                  .hasMatch(location))
            location,
      ];
    }
    final build = meta['build'];
    if (build is Map) {
      final safeBuild = _numbers(build);
      atoms(build, safeBuild, [
        'buildId',
        'buildType',
        'flutterMode',
        'versionName',
        'deviceModel',
        'identityScope',
        'identityErrorType',
      ]);
      safe['build'] = safeBuild;
    }
    result['metadata'] = safe;
  } else if (name.startsWith('trace')) {
    atoms(entry, result,
        ['traceId', 'sessionId', 'turnId', 'stage', 'status', 'source']);
    for (final key in ['roundIndex', 'eventSeq', 'durationMs']) {
      if (entry[key] is int) result[key] = entry[key];
    }
  } else if (name.startsWith('api_')) {
    atoms(entry, result, ['sessionId', 'turnId']);
    for (final key in [
      'ok',
      'status',
      'durationMs',
      'roundIndex',
      'eventSeq'
    ]) {
      if (entry[key] is int || entry[key] is bool) result[key] = entry[key];
    }
  } else {
    atoms(entry, result, ['traceId', 'source']);
  }
  return result;
}

/// 在工作 isolate 中执行。有界读取活动文件，缺失/截断如实写入 coverage。
Future<Uint8List> createDiagnosticBundle(String logDirectory,
    {DateTime? now,
    int maxFile = 16 * 1024 * 1024,
    int maxInput = 64 * 1024 * 1024,
    int maxOutput = 12 * 1024 * 1024,
    int maxLine = 512 * 1024,
    int maxRecords = 20000}) async {
  final collectedAt = now ?? DateTime.now();
  final earliest = collectedAt
      .subtract(const Duration(days: 7))
      .toIso8601String()
      .substring(0, 10);
  final root = Directory(logDirectory);
  final limits = <String>{};
  final files = <String, String>{};
  final candidates = <String>[];
  var inputBytes = 0;
  var outputBytes = 0;
  var malformedLines = 0;
  var recordCount = 0;
  if (await root.exists()) {
    for (final sub in ['', 'trace/']) {
      final dir = Directory('$logDirectory/$sub');
      if (await FileSystemEntity.type(dir.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = '$sub${entity.uri.pathSegments.last}';
        final match = diagnosticLogName.firstMatch(name);
        if (match != null && match[1]!.compareTo(earliest) >= 0) {
          candidates.add(name);
        }
      }
    }
  } else {
    limits.add('log_directory_missing');
  }
  candidates.sort((a, b) {
    final date = diagnosticLogName
        .firstMatch(b)![1]!
        .compareTo(diagnosticLogName.firstMatch(a)![1]!);
    return date != 0 ? date : a.compareTo(b);
  });
  for (final name in candidates) {
    if (inputBytes >= maxInput ||
        outputBytes >= maxOutput ||
        recordCount >= maxRecords) {
      limits.add('bundle_budget_reached');
      break;
    }
    final content = StringBuffer();
    try {
      final file = File('$logDirectory/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        limits.add('$name:file_unavailable');
        continue;
      }
      final handle = await file.open();
      late Uint8List bytes;
      var tail = false;
      try {
        final size = await handle.length();
        final allowed = (maxInput - inputBytes).clamp(0, maxFile);
        tail = size > allowed;
        if (tail) {
          await handle.setPosition(size - allowed);
          limits.add('$name:tail_read');
        }
        bytes = await handle.read(size.clamp(0, allowed));
      } finally {
        await handle.close();
      }
      inputBytes += bytes.length;
      var start = 0;
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != 10) continue;
        final lineStart = start;
        start = i + 1;
        if (tail && lineStart == 0) continue;
        if (i - lineStart > maxLine) {
          limits.add('$name:oversize_line');
          continue;
        }
        try {
          final entry = sanitizeDiagnosticEntry(
              jsonDecode(
                  utf8.decode(Uint8List.sublistView(bytes, lineStart, i))),
              name);
          if (entry == null) continue;
          final line = '${jsonEncode(entry)}\n';
          // Account for escaping in the outer JSON document as well.
          final size = utf8.encode(jsonEncode(line)).length;
          if (outputBytes + size > maxOutput || recordCount >= maxRecords) {
            limits.add('bundle_budget_reached');
            outputBytes = maxOutput;
            break;
          }
          content.write(line);
          outputBytes += size;
          recordCount++;
        } on FormatException {
          malformedLines++;
        }
      }
      if (start < bytes.length) limits.add('$name:incomplete_or_unread_tail');
      files[name] = content.toString();
    } on FileSystemException {
      limits.add('$name:read_failed');
    }
  }
  return Uint8List.fromList(utf8.encode(jsonEncode({
    'format': 'aicove-diagnostic-export',
    'formatVersion': 1,
    'collectedAt': collectedAt.toUtc().toIso8601String(),
    'files': files,
    'coverage': {
      'inputBytes': inputBytes,
      'malformedLines': malformedLines,
      'recordCount': recordCount,
      'limits': limits.toList()..sort(),
      'snapshotAtomic': false,
      'processMayStillBeWriting': true,
      'candidateFiles': candidates,
      'payloadPolicy': 'no_database_no_raw_payload_no_free_text',
      'originPolicy': 'exported_lines_not_original_file_line_numbers',
      'window': 'available_files_last_7_days',
    },
  })));
}
