import 'dart:convert';

import '../../../../core/api_logger.dart'
    show ApiLogEntry, truncateLongText;
import '../../../../core/app_logger.dart' show LogEntry, LogLevel;
import 'log_models.dart';

// ─────────────────────────────────────────────
//  base64 图片数据安全截断（修复卡死 bug）
// ─────────────────────────────────────────────

/// 检测并截断 JSON 字符串中的 base64 图片数据。
///
/// 多模态消息里 image_url 的 data URI 可能几 MB，
/// 直接丢给 TextPainter 排版会导致 UI 主线程卡死。
/// 本函数把 base64 有效负载替换为简短占位，保留结构可读性。
String sanitizeBase64InJson(String jsonStr) {
  // 快速检测：没有 data: 前缀就不可能有 base64 data URI
  if (!jsonStr.contains('data:')) return jsonStr;

  // 匹配 data URI 格式: "data:<mime>;base64,<payload>"
  // 保留 mime 信息，截断 payload
  return jsonStr.replaceAllMapped(
    RegExp(r'data:(image/[^;]+);base64,[A-Za-z0-9+/=]{100,}'),
    (m) {
      final mime = m.group(1) ?? 'image/*';
      return 'data:$mime;base64,[... 图片数据已省略 ...]';
    },
  );
}

/// 对解码后的消息列表做 base64 清理（用于 _prettyJson 之前）。
///
/// 直接操作解码后的对象比正则更可靠：
/// 遍历消息列表，把 image_url 中的 data URI 截断。
dynamic sanitizeBase64InDecoded(dynamic decoded) {
  if (decoded is List) {
    return decoded.map(sanitizeBase64InDecoded).toList();
  }
  if (decoded is Map<String, dynamic>) {
    final result = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (entry.key == 'url' && entry.value is String) {
        final url = entry.value as String;
        if (url.startsWith('data:') && url.contains(';base64,')) {
          final prefix = url.substring(0, url.indexOf(';base64,'));
          result[entry.key] = '$prefix;base64,[... 图片数据已省略 ...]';
          continue;
        }
      }
      result[entry.key] = sanitizeBase64InDecoded(entry.value);
    }
    return result;
  }
  return decoded;
}

// ─────────────────────────────────────────────
//  通用格式化工具
// ─────────────────────────────────────────────

String formatTime(DateTime time) {
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}

String shortenUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final path = uri.path;
  if (path.length > 30) {
    return '...${path.substring(path.length - 27)}';
  }
  return path;
}

/// 美化 JSON 字符串，同时截断其中的 base64 图片数据。
String? prettyJson(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    final sanitized = sanitizeBase64InDecoded(decoded);
    return const JsonEncoder.withIndent('  ').convert(sanitized);
  } catch (_) {
    return sanitizeBase64InJson(raw);
  }
}

String tryFormatJson(String text) {
  try {
    final decoded = jsonDecode(text);
    final sanitized = sanitizeBase64InDecoded(decoded);
    return const JsonEncoder.withIndent('  ').convert(sanitized);
  } catch (_) {
    return sanitizeBase64InJson(text);
  }
}

/// JSON 预览（截取前 N 个字符）
String jsonPreview(String text, int maxLen) {
  try {
    final decoded = jsonDecode(text);
    final formatted = jsonEncode(decoded);
    if (formatted.length <= maxLen) return formatted;
    return '${formatted.substring(0, maxLen)}...';
  } catch (_) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}...';
  }
}

/// 格式化 metadata
String? formatMetadata(dynamic metadata) {
  if (metadata == null) return null;
  if (metadata is Map && metadata.isEmpty) return null;
  try {
    return const JsonEncoder.withIndent('  ').convert(metadata);
  } catch (_) {
    return metadata.toString();
  }
}

int countJsonItems(String? raw) {
  if (raw == null) return 0;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 0;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is List) return decoded.length;
    if (decoded is Map<String, dynamic>) {
      final toolCalls = decoded['tool_calls'];
      if (toolCalls is List) return toolCalls.length;
    }
    return 1;
  } catch (_) {
    return 1;
  }
}

String formatDurationLabel(int? durationMs) {
  if (durationMs == null || durationMs < 0) return '未知';
  if (durationMs < 1000) return '${durationMs}ms';
  final seconds = durationMs / 1000.0;
  if (seconds < 60) {
    final fixed = seconds >= 10 ? 1 : 2;
    return '${seconds.toStringAsFixed(fixed)}s';
  }
  final minutes = seconds / 60.0;
  if (minutes < 60) return '${minutes.toStringAsFixed(1)}min';
  final hours = minutes / 60.0;
  return '${hours.toStringAsFixed(1)}h';
}

String? firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// 截断 JSON 中的系统提示词（用于复制时）
String truncateSystemPromptsInJson(String jsonStr) {
  try {
    final decoded = jsonDecode(jsonStr);
    if (decoded is Map<String, dynamic>) {
      void truncateSystemMessages(List? messages) {
        if (messages == null) return;
        for (final msg in messages) {
          if (msg is Map<String, dynamic> && msg['role'] == 'system') {
            final content = msg['content'];
            if (content is String && content.length > 100) {
              msg['content'] = truncateLongText(content, maxLength: 100);
            }
          }
        }
      }

      truncateSystemMessages(decoded['messages'] as List?);
      truncateSystemMessages(decoded['history'] as List?);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    }
  } catch (_) {
    // 解析失败则尝试普通格式化
  }
  return tryFormatJson(jsonStr);
}

// ─────────────────────────────────────────────
//  实时日志相关的格式化
// ─────────────────────────────────────────────

/// 对话日志的额外内容
String? formatConversationExtra(ApiLogEntry log) {
  final parts = <String>[];

  if (log.rawAiResponse != null && log.rawAiResponse!.isNotEmpty) {
    final preview = log.rawAiResponse!.length > 200
        ? '${log.rawAiResponse!.substring(0, 200)}...'
        : log.rawAiResponse!;
    parts.add('AI回复: $preview');
  }

  if (log.rawContext != null && log.rawContext!.isNotEmpty) {
    try {
      final messages = jsonDecode(log.rawContext!) as List;
      parts.add('上下文: ${messages.length}条消息');
    } catch (_) {
      parts.add('上下文: (解析失败)');
    }
  }

  return parts.isEmpty ? null : parts.join('\n');
}

/// API 日志的额外内容
String? formatApiLogExtra(ApiLogEntry log) {
  final parts = <String>[];

  if (log.requestBody.isNotEmpty) {
    parts.add('请求: ${jsonPreview(log.requestBody, 100)}');
  }
  if (log.responseBody.isNotEmpty) {
    parts.add('响应: ${jsonPreview(log.responseBody, 100)}');
  }

  return parts.isEmpty ? null : parts.join('\n');
}

/// API 日志的完整格式（用于复制）
String formatApiLogFull(ApiLogEntry log) {
  final buffer = StringBuffer();
  final time = formatTime(log.time);

  if (log.isConversation) {
    buffer.writeln('[$time] [对话] ${log.url}');
    buffer.writeln(
        '状态: ${log.status ?? '--'} | 耗时: ${log.durationMs}ms | 结果: ${log.ok ? '成功' : '失败'}');

    if (log.rawContext != null && log.rawContext!.isNotEmpty) {
      buffer.writeln('\n========== 发送给AI的上下文 ==========');
      try {
        final messages = jsonDecode(log.rawContext!) as List;
        for (var i = 0; i < messages.length; i++) {
          final msg = messages[i] as Map<String, dynamic>;
          final role = msg['role'] ?? 'unknown';
          final content = msg['content'];
          buffer.writeln('\n--- [$role] (第${i + 1}条) ---');
          if (content is String) {
            buffer.writeln(content);
          } else if (content is List) {
            for (final part in content) {
              if (part is Map<String, dynamic>) {
                if (part['type'] == 'text') {
                  buffer.writeln(part['text'] ?? '');
                } else {
                  buffer.writeln('[${part['type']}]');
                }
              }
            }
          } else {
            buffer.writeln(content?.toString() ?? '');
          }
        }
      } catch (e) {
        buffer.writeln('(解析失败: $e)');
        buffer.writeln(sanitizeBase64InJson(log.rawContext!));
      }
    }

    if (log.rawAiResponse != null && log.rawAiResponse!.isNotEmpty) {
      buffer.writeln('\n========== AI原始回复 ==========');
      buffer.writeln(log.rawAiResponse);
    }

    return buffer.toString().trim();
  }

  buffer.writeln('[$time] [API] ${log.method} ${log.url}');
  buffer.writeln(
      '状态: ${log.status ?? '--'} | 耗时: ${log.durationMs}ms | 结果: ${log.ok ? '成功' : '失败'}');

  if (log.requestBody.isNotEmpty) {
    buffer.writeln('--- 请求体 ---');
    buffer.writeln(truncateSystemPromptsInJson(log.requestBody));
  }
  if (log.responseBody.isNotEmpty) {
    buffer.writeln('--- 响应体 ---');
    buffer.writeln(tryFormatJson(log.responseBody));
  }

  return buffer.toString().trim();
}

/// 系统日志的完整格式
String formatSystemLogFull(LogEntry log) {
  final buffer = StringBuffer();
  buffer.write(
      '[${log.formattedTime}] [${log.level.label}] [${log.source}] ${log.message}');

  if (log.metadata != null && log.metadata!.isNotEmpty) {
    buffer.writeln();
    buffer.writeln('--- metadata ---');
    buffer.write(formatMetadata(log.metadata) ?? log.metadata.toString());
  }

  return buffer.toString();
}

// ─────────────────────────────────────────────
//  会话 Turn 相关
// ─────────────────────────────────────────────

/// 从 API 日志构建会话 Turn 列表
List<ConversationTurnLog> buildConversationTurns(
  List<ApiLogEntry> apiLogs, {
  DateTime? hideBeforeTime,
}) {
  final logs = apiLogs
      .where((log) => log.isConversation)
      .where(
          (log) => hideBeforeTime == null || !log.time.isBefore(hideBeforeTime))
      .toList()
    ..sort((a, b) => a.time.compareTo(b.time));

  final grouped = <String, List<ApiLogEntry>>{};
  var legacyIndex = 0;
  for (final log in logs) {
    final turnId = log.turnId?.trim();
    final sessionId = log.sessionId?.trim();
    final key = (turnId != null && turnId.isNotEmpty)
        ? '${sessionId ?? ''}::$turnId'
        : 'legacy_${legacyIndex++}_${log.time.millisecondsSinceEpoch}';
    grouped.putIfAbsent(key, () => <ApiLogEntry>[]).add(log);
  }

  final turns = <ConversationTurnLog>[];
  for (final entry in grouped.entries) {
    final turnLogs = entry.value..sort((a, b) => a.time.compareTo(b.time));
    final roundRequestLogs = <int, ApiLogEntry>{};
    final roundToolLogs = <int, ApiLogEntry>{};
    ApiLogEntry? finalLog;

    for (final log in turnLogs) {
      final round = log.roundIndex ?? 1;
      final eventType = (log.eventType ?? '').trim();
      final hasToolResult =
          log.rawToolResults != null && log.rawToolResults!.isNotEmpty;
      final hasFinalReply =
          log.finalReply != null && log.finalReply!.isNotEmpty;

      if (eventType == 'final_response' || hasFinalReply) {
        finalLog = log;
        continue;
      }

      if (eventType == 'tool_execution' || hasToolResult) {
        roundToolLogs[round] = log;
      } else {
        roundRequestLogs[round] = log;
      }
    }

    final roundIndexes = <int>{
      ...roundRequestLogs.keys,
      ...roundToolLogs.keys,
    }.toList()
      ..sort();
    final rounds = <ConversationRoundLog>[
      for (final roundIndex in roundIndexes)
        ConversationRoundLog(
          roundIndex: roundIndex,
          requestLog: roundRequestLogs[roundIndex],
          toolLog: roundToolLogs[roundIndex],
        )
    ];

    turns.add(ConversationTurnLog(
      turnKey: entry.key,
      sessionId: firstNonEmpty(turnLogs.map((e) => e.sessionId)),
      turnId: firstNonEmpty(turnLogs.map((e) => e.turnId)),
      startedAt: turnLogs.first.time,
      rounds: rounds,
      finalLog: finalLog,
    ));
  }

  turns.sort((a, b) => a.startedAt.compareTo(b.startedAt));
  return turns;
}

/// 构建统一日志条目列表
List<UnifiedLogEntry> buildUnifiedEntries(
  List<ApiLogEntry> apiLogs,
  List<LogEntry> systemLogs, {
  DateTime? hideBeforeTime,
  LogLevelFilter levelFilter = LogLevelFilter.all,
  LogTypeFilter typeFilter = LogTypeFilter.all,
}) {
  final entries = <UnifiedLogEntry>[];
  final minLevel = levelFilter.minLevel;

  for (final log in apiLogs) {
    if (hideBeforeTime != null && log.time.isBefore(hideBeforeTime)) continue;

    final isConversation = log.isConversation;
    if (typeFilter == LogTypeFilter.conversation && !isConversation) continue;
    if (typeFilter == LogTypeFilter.api && isConversation) continue;
    if (typeFilter == LogTypeFilter.system) continue;

    final title = isConversation
        ? '[对话] ${log.status ?? '--'} ${shortenUrl(log.url)}'
        : '[API] ${log.method} ${log.status ?? '--'} ${shortenUrl(log.url)}';

    final extra = isConversation
        ? formatConversationExtra(log)
        : formatApiLogExtra(log);

    entries.add(UnifiedLogEntry(
      time: log.time,
      title: title,
      extraContent: extra,
      fullContent: formatApiLogFull(log),
      isApiLog: true,
      isConversation: isConversation,
      rawAiResponse: log.rawAiResponse,
      rawContext: log.rawContext,
    ));
  }

  if (typeFilter == LogTypeFilter.all || typeFilter == LogTypeFilter.system) {
    for (final log in systemLogs) {
      if (hideBeforeTime != null && log.time.isBefore(hideBeforeTime)) continue;
      if (minLevel != null && log.level.value < minLevel.value) continue;

      final title = '[${log.level.label}] [${log.source}] ${log.message}';
      entries.add(UnifiedLogEntry(
        time: log.time,
        title: title,
        extraContent: formatMetadata(log.metadata),
        fullContent: formatSystemLogFull(log),
        level: log.level,
      ));
    }
  }

  entries.sort((a, b) => a.time.compareTo(b.time));
  return entries;
}

// ─────────────────────────────────────────────
//  Turn 内部辅助
// ─────────────────────────────────────────────

int? resolvePrimaryDurationMs(ApiLogEntry? log) {
  if (log == null) return null;
  return log.durationMs > 0 ? log.durationMs : null;
}

int? resolveToolDurationMs({
  required ApiLogEntry? requestLog,
  required ApiLogEntry? toolLog,
}) {
  final direct = resolvePrimaryDurationMs(toolLog);
  if (direct != null) return direct;
  if (toolLog == null) return null;

  final startTime = requestLog?.time;
  if (startTime == null) return null;
  final diffMs = toolLog.time.difference(startTime).inMilliseconds;
  return diffMs > 0 ? diffMs : null;
}

int? resolveFinalDeliveryDurationMs(ConversationTurnLog turn) {
  final finalLog = turn.finalLog;
  if (finalLog == null) return null;

  final direct = resolvePrimaryDurationMs(finalLog);
  if (direct != null) return direct;

  final anchorTime = latestRoundLogTime(turn);
  if (anchorTime == null) return null;
  final diffMs = finalLog.time.difference(anchorTime).inMilliseconds;
  return diffMs > 0 ? diffMs : null;
}

DateTime? latestRoundLogTime(ConversationTurnLog turn) {
  DateTime? latest;
  for (final round in turn.rounds) {
    final requestTime = round.requestLog?.time;
    final toolTime = round.toolLog?.time;
    if (requestTime != null &&
        (latest == null || requestTime.isAfter(latest))) {
      latest = requestTime;
    }
    if (toolTime != null && (latest == null || toolTime.isAfter(latest))) {
      latest = toolTime;
    }
  }
  return latest;
}

String resolveFinalReply(ConversationTurnLog turn) {
  final finalReply = turn.finalLog?.finalReply?.trim();
  if (finalReply != null && finalReply.isNotEmpty) return finalReply;

  final finalRawReply = turn.finalLog?.rawAiResponse?.trim();
  if (finalRawReply != null && finalRawReply.isNotEmpty) return finalRawReply;

  for (var i = turn.rounds.length - 1; i >= 0; i--) {
    final text = turn.rounds[i].requestLog?.rawAiResponse?.trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return '';
}

// ─────────────────────────────────────────────
//  历史日志相关的格式化辅助
// ─────────────────────────────────────────────

String? historyString(dynamic value) {
  if (value == null) return null;
  final text = value.toString();
  return text.trim().isEmpty ? null : text;
}

int? historyInt(dynamic value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}

String historyDurationLabel(Map<String, dynamic> log) {
  final durationMs = historyInt(log['durationMs']);
  if (durationMs == null || durationMs < 0) return '未知';
  if (durationMs < 1000) return '${durationMs}ms';
  return '${(durationMs / 1000).toStringAsFixed(durationMs >= 10000 ? 1 : 2)}s';
}

int historyCountJsonItems(dynamic raw) {
  final text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return 0;
  try {
    final decoded = jsonDecode(text);
    if (decoded is List) return decoded.length;
    if (decoded is Map<String, dynamic>) {
      final toolCalls = decoded['tool_calls'];
      if (toolCalls is List) return toolCalls.length;
    }
    return 1;
  } catch (_) {
    return 1;
  }
}

int historyContextCount(dynamic rawContext) {
  final text = rawContext?.toString().trim() ?? '';
  if (text.isEmpty) return 0;
  try {
    final decoded = jsonDecode(text);
    if (decoded is List) return decoded.length;
    return 0;
  } catch (_) {
    return 0;
  }
}

String historyDirection(Map<String, dynamic> log) {
  final eventType = (log['eventType'] ?? '').toString().trim();
  final hasFinalReply = historyString(log['finalReply']) != null;
  if (eventType == 'final_response' || hasFinalReply) return 'AI -> 用户';
  if (eventType == 'tool_execution') return 'AI -> 工具';
  return '用户 -> AI';
}

LogLevel parseLogLevel(dynamic rawLevel) {
  if (rawLevel is int) {
    return LogLevel.values[_clampLogLevelIndex(rawLevel)];
  }

  if (rawLevel is String) {
    final normalized = rawLevel.trim();
    final parsedIndex = int.tryParse(normalized);
    if (parsedIndex != null) {
      return LogLevel.values[_clampLogLevelIndex(parsedIndex)];
    }

    final upper = normalized.toUpperCase();
    for (final level in LogLevel.values) {
      if (level.label == upper || level.name.toUpperCase() == upper) {
        return level;
      }
    }
  }

  return LogLevel.info;
}

int _clampLogLevelIndex(int index) {
  final maxIndex = LogLevel.values.length - 1;
  if (index < 0) return 0;
  if (index > maxIndex) return maxIndex;
  return index;
}

String preview(String text, int max) {
  if (text.length <= max) return text;
  return '${text.substring(0, max)}...';
}
