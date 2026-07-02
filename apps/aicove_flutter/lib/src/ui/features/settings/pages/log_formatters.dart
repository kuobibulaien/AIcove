import 'dart:convert';

import 'package:flutter/material.dart' show IconData, Icons;

import '../../../../core/api_logger.dart' show ApiLogEntry, truncateLongText;
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

/// 流式回包预览（用于日志中心默认展示）
class StreamResponsePreview {
  final String mergedText;
  final int eventCount;
  final int parseErrorCount;
  final bool hasDoneMarker;

  const StreamResponsePreview({
    required this.mergedText,
    required this.eventCount,
    required this.parseErrorCount,
    required this.hasDoneMarker,
  });

  bool get hasMergedText => mergedText.trim().isNotEmpty;
}

class ConversationRawResponseSection {
  final String title;
  final String content;
  final bool isCollapsedStream;

  const ConversationRawResponseSection({
    required this.title,
    required this.content,
    this.isCollapsedStream = false,
  });
}

/// 将 `rawResponseBody={"streamEvents":[...]}` 解析成可读预览。
///
/// 返回 `null` 代表不是流式事件包（例如普通一次性 JSON 回包）。
StreamResponsePreview? parseStreamResponsePreview(String? rawResponseBody) {
  if (rawResponseBody == null) return null;
  final trimmed = rawResponseBody.trim();
  if (trimmed.isEmpty) return null;

  dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return null;
  }

  if (decoded is! Map<String, dynamic>) return null;
  final streamEvents = decoded['streamEvents'];
  if (streamEvents is! List) return null;

  final merged = StringBuffer();
  var parseErrorCount = 0;
  var hasDoneMarker = false;

  for (final event in streamEvents) {
    if (event is String) {
      final marker = event.trim();
      if (marker == '[DONE]') {
        hasDoneMarker = true;
        continue;
      }
      try {
        final parsed = jsonDecode(marker);
        if (parsed is Map) {
          merged.write(
            _extractStreamTextFromEvent(_toStringKeyMap(parsed)),
          );
        } else {
          parseErrorCount++;
        }
      } catch (_) {
        parseErrorCount++;
      }
      continue;
    }

    if (event is Map) {
      final eventMap = _toStringKeyMap(event);
      if (eventMap['_parseError'] == true) {
        parseErrorCount++;
        continue;
      }
      merged.write(_extractStreamTextFromEvent(eventMap));
      continue;
    }

    parseErrorCount++;
  }

  return StreamResponsePreview(
    mergedText: merged.toString(),
    eventCount: streamEvents.length,
    parseErrorCount: parseErrorCount,
    hasDoneMarker: hasDoneMarker,
  );
}

ConversationRawResponseSection? buildConversationRawResponseSection(
  String? rawResponseBody, {
  bool includeRawStreamEvents = false,
}) {
  if (rawResponseBody == null) return null;
  final trimmed = rawResponseBody.trim();
  if (trimmed.isEmpty) return null;

  final streamPreview = parseStreamResponsePreview(trimmed);
  if (streamPreview == null) {
    return ConversationRawResponseSection(
      title: 'AI 原始 JSON 响应（模型回包）',
      content: tryFormatJson(trimmed),
    );
  }

  if (includeRawStreamEvents) {
    return ConversationRawResponseSection(
      title: '流式回包原始事件（JSON，按轮汇总）',
      content: tryFormatJson(trimmed),
    );
  }

  final summaryParts = <String>[
    '事件数: ${streamPreview.eventCount}',
    if (streamPreview.hasDoneMarker) '含 [DONE]',
    if (streamPreview.parseErrorCount > 0)
      '解析失败: ${streamPreview.parseErrorCount}条',
  ];

  final buffer = StringBuffer()
    ..writeln('原始流式事件已默认折叠，避免日常预览和导出被 streamEvents 刷屏。')
    ..writeln(summaryParts.join(' | '))
    ..writeln()
    ..writeln('--- 按轮聚合后的文本 ---')
    ..writeln(streamPreview.hasMergedText ? streamPreview.mergedText : '(空)');

  return ConversationRawResponseSection(
    title: '流式回包（默认折叠原始事件）',
    content: buffer.toString().trim(),
    isCollapsedStream: true,
  );
}

Map<String, dynamic> _toStringKeyMap(Map value) {
  return value.map(
    (key, val) => MapEntry(key.toString(), val),
  );
}

String _extractStreamTextFromEvent(Map<String, dynamic> event) {
  var handledChoice = false;
  String extracted = '';

  final choices = event['choices'];
  if (choices is List && choices.isNotEmpty) {
    final first = choices.first;
    if (first is Map) {
      handledChoice = true;
      final choiceMap = _toStringKeyMap(first);
      final delta = choiceMap['delta'];
      if (delta is Map) {
        final deltaMap = _toStringKeyMap(delta);
        extracted = _extractStreamingText(deltaMap['content']);
      }
      if (extracted.isEmpty) {
        final message = choiceMap['message'];
        if (message is Map) {
          final messageMap = _toStringKeyMap(message);
          extracted = _extractStreamingText(messageMap['content']);
        }
      }
    }
  }

  if (extracted.isNotEmpty) return extracted;

  if (!handledChoice) {
    final rootDelta = _extractStreamingText(event['delta']);
    if (rootDelta.isNotEmpty) return rootDelta;
    final rootContent = _extractStreamingText(event['content']);
    if (rootContent.isNotEmpty) return rootContent;
  }

  return '';
}

String _extractStreamingText(dynamic value) {
  if (value == null) return '';

  if (value is String) return value;

  if (value is List) {
    final buffer = StringBuffer();
    for (final item in value) {
      buffer.write(_extractStreamingText(item));
    }
    return buffer.toString();
  }

  if (value is Map) {
    final map = _toStringKeyMap(value);
    final directText = map['text'];
    if (directText is String && directText.isNotEmpty) {
      return directText;
    }
    final content = _extractStreamingText(map['content']);
    if (content.isNotEmpty) return content;
    final delta = _extractStreamingText(map['delta']);
    if (delta.isNotEmpty) return delta;
  }

  return '';
}

class _ToolCallTraceEntry {
  final String id;
  final String name;
  final dynamic arguments;

  const _ToolCallTraceEntry({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

class _ToolResultTraceEntry {
  final String toolCallId;
  final String name;
  final dynamic result;
  final bool isError;

  const _ToolResultTraceEntry({
    required this.toolCallId,
    required this.name,
    required this.result,
    required this.isError,
  });
}

class _StreamToolCallAccumulator {
  String id = '';
  String name = '';
  final StringBuffer argsBuffer = StringBuffer();

  dynamic buildArguments() {
    final raw = argsBuffer.toString().trim();
    if (raw.isEmpty) return const <String, dynamic>{};
    try {
      final parsed = jsonDecode(raw);
      return parsed;
    } catch (_) {
      return raw;
    }
  }
}

/// 构建“工具调用轨迹”文本，用于日志中心排障。
///
/// 数据来源优先级：
/// 1) `rawToolCalls` / `rawToolResults`（结构化字段）；
/// 2) `rawResponseBody.streamEvents`（流式事件兜底提取）。
String? buildToolCallTraceText({
  String? rawToolCalls,
  String? rawToolResults,
  String? rawResponseBody,
}) {
  final calls = _parseToolCalls(rawToolCalls, rawResponseBody: rawResponseBody);
  final results = _parseToolResults(rawToolResults);

  if (calls.isEmpty && results.isEmpty) return null;

  final idResultMap = <String, _ToolResultTraceEntry>{};
  final nameResultPool = <String, List<_ToolResultTraceEntry>>{};
  for (final result in results) {
    final id = result.toolCallId.trim();
    if (id.isNotEmpty) {
      idResultMap[id] = result;
    }
    final name = result.name.trim();
    if (name.isNotEmpty) {
      nameResultPool
          .putIfAbsent(name, () => <_ToolResultTraceEntry>[])
          .add(result);
    }
  }

  final consumed = <_ToolResultTraceEntry>{};
  final buffer = StringBuffer();

  for (var i = 0; i < calls.length; i++) {
    final call = calls[i];

    _ToolResultTraceEntry? matched;
    final callId = call.id.trim();
    if (callId.isNotEmpty) {
      matched = idResultMap[callId];
    }
    if (matched == null) {
      final pool = nameResultPool[call.name.trim()];
      if (pool != null && pool.isNotEmpty) {
        matched = pool.firstWhere(
          (item) => !consumed.contains(item),
          orElse: () => pool.first,
        );
      }
    }
    if (matched != null) {
      consumed.add(matched);
    }

    final status = matched == null ? '未返回结果' : (matched.isError ? '失败' : '成功');

    buffer.writeln('[调用 ${i + 1}] 状态: $status');
    buffer.writeln('id: ${call.id.isEmpty ? '(无)' : call.id}');
    buffer.writeln('工具: ${call.name.isEmpty ? '(未知)' : call.name}');
    buffer.writeln('参数:');
    buffer.writeln(_formatTraceValue(call.arguments));
    if (matched != null) {
      buffer.writeln('结果:');
      buffer.writeln(_formatTraceValue(matched.result));
    }
    if (i != calls.length - 1) {
      buffer.writeln();
    }
  }

  final orphanResults =
      results.where((item) => !consumed.contains(item)).toList(growable: false);
  if (orphanResults.isNotEmpty) {
    if (buffer.isNotEmpty) buffer.writeln();
    for (var i = 0; i < orphanResults.length; i++) {
      final item = orphanResults[i];
      buffer.writeln('[孤立结果 ${i + 1}] 状态: ${item.isError ? '失败' : '成功'}');
      buffer
          .writeln('id: ${item.toolCallId.isEmpty ? '(无)' : item.toolCallId}');
      buffer.writeln('工具: ${item.name.isEmpty ? '(未知)' : item.name}');
      buffer.writeln('结果:');
      buffer.writeln(_formatTraceValue(item.result));
      if (i != orphanResults.length - 1) {
        buffer.writeln();
      }
    }
  }

  final text = buffer.toString().trim();
  return text.isEmpty ? null : text;
}

List<_ToolCallTraceEntry> _parseToolCalls(
  String? rawToolCalls, {
  String? rawResponseBody,
}) {
  final directCalls = _parseToolCallsFromRawToolCalls(rawToolCalls);
  if (directCalls.isNotEmpty) return directCalls;
  return _parseToolCallsFromStreamEvents(rawResponseBody);
}

List<_ToolCallTraceEntry> _parseToolCallsFromRawToolCalls(
    String? rawToolCalls) {
  if (rawToolCalls == null || rawToolCalls.trim().isEmpty) {
    return const <_ToolCallTraceEntry>[];
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(rawToolCalls);
  } catch (_) {
    return const <_ToolCallTraceEntry>[];
  }
  if (decoded is! List) return const <_ToolCallTraceEntry>[];

  final calls = <_ToolCallTraceEntry>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final map = _toStringKeyMap(item);
    calls.add(_ToolCallTraceEntry(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      arguments: map['arguments'] ?? const <String, dynamic>{},
    ));
  }
  return calls;
}

List<_ToolCallTraceEntry> _parseToolCallsFromStreamEvents(
    String? rawResponseBody) {
  if (rawResponseBody == null || rawResponseBody.trim().isEmpty) {
    return const <_ToolCallTraceEntry>[];
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(rawResponseBody);
  } catch (_) {
    return const <_ToolCallTraceEntry>[];
  }
  if (decoded is! Map<String, dynamic>) return const <_ToolCallTraceEntry>[];
  final events = decoded['streamEvents'];
  if (events is! List) return const <_ToolCallTraceEntry>[];

  final accumulators = <String, _StreamToolCallAccumulator>{};
  final indexToKey = <String, String>{};
  var seq = 0;

  for (final event in events) {
    Map<String, dynamic>? map;
    if (event is Map) {
      map = _toStringKeyMap(event);
    } else if (event is String) {
      final text = event.trim();
      if (text.isEmpty || text == '[DONE]') continue;
      try {
        final parsed = jsonDecode(text);
        if (parsed is Map) {
          map = _toStringKeyMap(parsed);
        }
      } catch (_) {
        map = null;
      }
    }
    if (map == null) continue;

    for (final rawCall in _extractToolCallMapsFromEvent(map)) {
      final indexText = rawCall['index']?.toString().trim() ?? '';
      final id = rawCall['id']?.toString().trim() ?? '';
      final function = rawCall['function'];
      String name = '';
      String argsChunk = '';
      if (function is Map) {
        final functionMap = _toStringKeyMap(function);
        name = functionMap['name']?.toString().trim() ?? '';
        argsChunk = functionMap['arguments']?.toString() ?? '';
      }

      String key;
      final indexedKey = indexText.isNotEmpty ? indexToKey[indexText] : null;
      if (indexedKey != null) {
        key = indexedKey;
      } else if (id.isNotEmpty) {
        key = 'id:$id';
      } else if (indexText.isNotEmpty) {
        key = 'index:$indexText';
      } else {
        key = 'seq:${seq++}';
      }

      if (indexText.isNotEmpty) {
        indexToKey[indexText] = key;
      }

      final acc =
          accumulators.putIfAbsent(key, () => _StreamToolCallAccumulator());
      if (id.isNotEmpty) {
        acc.id = id;
      }
      if (acc.id.isEmpty && indexText.isNotEmpty) {
        acc.id = 'index_$indexText';
      }
      if (name.isNotEmpty) {
        acc.name = name;
      }
      if (argsChunk.isNotEmpty) {
        acc.argsBuffer.write(argsChunk);
      }
    }
  }

  final out = <_ToolCallTraceEntry>[];
  for (final acc in accumulators.values) {
    out.add(_ToolCallTraceEntry(
      id: acc.id,
      name: acc.name,
      arguments: acc.buildArguments(),
    ));
  }
  return out;
}

List<Map<String, dynamic>> _extractToolCallMapsFromEvent(
    Map<String, dynamic> event) {
  final out = <Map<String, dynamic>>[];

  void collect(dynamic value) {
    if (value is List) {
      for (final item in value) {
        if (item is Map) {
          out.add(_toStringKeyMap(item));
        }
      }
    }
  }

  final choices = event['choices'];
  if (choices is List && choices.isNotEmpty) {
    final first = choices.first;
    if (first is Map) {
      final choiceMap = _toStringKeyMap(first);
      final delta = choiceMap['delta'];
      if (delta is Map) {
        collect(_toStringKeyMap(delta)['tool_calls']);
      }
      final message = choiceMap['message'];
      if (message is Map) {
        collect(_toStringKeyMap(message)['tool_calls']);
      }
    }
  }

  collect(event['tool_calls']);
  return out;
}

List<_ToolResultTraceEntry> _parseToolResults(String? rawToolResults) {
  if (rawToolResults == null || rawToolResults.trim().isEmpty) {
    return const <_ToolResultTraceEntry>[];
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(rawToolResults);
  } catch (_) {
    return const <_ToolResultTraceEntry>[];
  }
  if (decoded is! List) return const <_ToolResultTraceEntry>[];

  final out = <_ToolResultTraceEntry>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final map = _toStringKeyMap(item);
    final rawResult = map['result']?.toString() ?? '';
    dynamic parsedResult = rawResult;
    try {
      parsedResult = jsonDecode(rawResult);
    } catch (_) {
      parsedResult = rawResult;
    }
    out.add(_ToolResultTraceEntry(
      toolCallId: map['toolCallId']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      result: parsedResult,
      isError: _detectToolResultError(parsedResult),
    ));
  }
  return out;
}

bool _detectToolResultError(dynamic result) {
  if (result is Map) {
    final map = _toStringKeyMap(result);
    final error = map['error'];
    if (error != null && error.toString().trim().isNotEmpty) return true;
    if (map['success'] == false) return true;
    final status = map['status']?.toString().toLowerCase() ?? '';
    if (status.contains('error') || status.contains('fail')) return true;
  }
  return false;
}

String _formatTraceValue(dynamic value) {
  String text;
  if (value is Map || value is List) {
    text = const JsonEncoder.withIndent('  ').convert(value);
  } else {
    text = value?.toString() ?? '';
  }
  if (text.length > 1800) {
    return truncateLongText(text, maxLength: 1800, headRatio: 0.7);
  }
  return text;
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

/// Stage 英文标识 → 中文展示名称（用于日志中心 UI）
String stageToZh(String stage) {
  const map = <String, String>{
    'TURN_STARTED': '开始处理',
    'USER_MESSAGE_PERSISTED': '消息已保存',
    'HISTORY_PREPARED': '历史准备完毕',
    'API_CONFIG_READY': '配置就绪',
    'ROUND_REQUEST_BUILT': '构建请求',
    'MODEL_REQUEST_SENT': '发送AI请求',
    'MODEL_RESPONSE_RECEIVED': 'AI回复收到',
    'MODEL_STREAM_AGGREGATED': 'AI流式回复汇总',
    'TOOL_CALL_DETECTED': '发现工具调用',
    'TOOL_EXEC_STARTED': '工具执行中',
    'TOOL_EXEC_FINISHED': '工具执行完毕',
    'ROUND_COMPLETED': '本轮完成',
    'FINAL_REPLY_READY': '最终回复就绪',
    'MESSAGE_DELIVERED': '消息已送达',
    'TURN_COMPLETED': '全部完成',
    'TURN_FAILED': '处理失败',
  };
  return map[stage] ?? stage;
}

/// Trace 状态英文 → 中文
String statusToZh(String status) {
  const map = <String, String>{
    'success': '成功',
    'failed': '失败',
    'running': '进行中',
  };
  return map[status] ?? status;
}

/// Stage → 对应图标
IconData stageIcon(String stage) {
  const map = <String, IconData>{
    'TURN_STARTED': Icons.play_circle_outline,
    'USER_MESSAGE_PERSISTED': Icons.save_outlined,
    'HISTORY_PREPARED': Icons.history,
    'API_CONFIG_READY': Icons.settings_outlined,
    'ROUND_REQUEST_BUILT': Icons.build_outlined,
    'MODEL_REQUEST_SENT': Icons.send,
    'MODEL_RESPONSE_RECEIVED': Icons.download_outlined,
    'MODEL_STREAM_AGGREGATED': Icons.downloading,
    'TOOL_CALL_DETECTED': Icons.handyman_outlined,
    'TOOL_EXEC_STARTED': Icons.hourglass_top,
    'TOOL_EXEC_FINISHED': Icons.check_circle_outline,
    'ROUND_COMPLETED': Icons.refresh,
    'FINAL_REPLY_READY': Icons.chat_bubble_outline,
    'MESSAGE_DELIVERED': Icons.mark_email_read_outlined,
    'TURN_COMPLETED': Icons.done_all,
    'TURN_FAILED': Icons.error_outline,
  };
  return map[stage] ?? Icons.circle_outlined;
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
    bool hasText(String? value) => value != null && value.trim().isNotEmpty;

    buffer.writeln('[$time] [对话] ${log.url}');
    final summaryParts = <String>[
      '状态: ${log.status ?? '--'}',
      '耗时: ${log.durationMs}ms',
      '结果: ${log.ok ? '成功' : '失败'}',
      if (log.roundIndex != null) '轮次: 第${log.roundIndex}轮',
      if (hasText(log.eventType)) '事件: ${log.eventType}',
    ];
    buffer.writeln(summaryParts.join(' | '));

    final traceParts = <String>[
      if (hasText(log.sessionId)) 'session=${log.sessionId}',
      if (hasText(log.turnId)) 'turn=${log.turnId}',
    ];
    if (traceParts.isNotEmpty) {
      buffer.writeln(traceParts.join(' | '));
    }

    void writeJsonSection(String title, String? value) {
      if (!hasText(value)) return;
      buffer.writeln('\n========== $title ==========');
      buffer.writeln(tryFormatJson(value!.trim()));
    }

    void writeTextSection(String title, String? value) {
      if (!hasText(value)) return;
      buffer.writeln('\n========== $title ==========');
      buffer.writeln(value!.trim());
    }

    writeJsonSection('AI 实际收到的完整上下文（messages）', log.rawContext);
    writeJsonSection('AI 实际发送的完整请求体（rawRequestBody）', log.rawRequestBody);
    final rawResponseSection =
        buildConversationRawResponseSection(log.rawResponseBody);
    if (rawResponseSection != null) {
      buffer.writeln('\n========== ${rawResponseSection.title} ==========');
      buffer.writeln(rawResponseSection.content);
    }
    writeJsonSection('AI -> 工具调用', log.rawToolCalls);
    writeJsonSection('工具 -> AI 返回', log.rawToolResults);
    writeTextSection('AI 原始回复', log.rawAiResponse);
    writeTextSection('最终展示给用户的回复', log.finalReply);

    final hasDetailedSections = hasText(log.rawContext) ||
        hasText(log.rawRequestBody) ||
        hasText(log.rawResponseBody) ||
        hasText(log.rawToolCalls) ||
        hasText(log.rawToolResults) ||
        hasText(log.rawAiResponse) ||
        hasText(log.finalReply);

    // 兼容旧日志：若没有详细字段，至少保留请求/响应摘要，避免导出为空壳。
    if (!hasDetailedSections) {
      if (log.requestBody.isNotEmpty) {
        buffer.writeln('\n--- 请求体（摘要） ---');
        buffer.writeln(tryFormatJson(log.requestBody));
      }
      if (log.responseBody.isNotEmpty) {
        buffer.writeln('\n--- 响应体（摘要） ---');
        buffer.writeln(tryFormatJson(log.responseBody));
      }
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

    final extra =
        isConversation ? formatConversationExtra(log) : formatApiLogExtra(log);

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
  final rawFinalReply = resolveRawFinalReply(turn);
  if (rawFinalReply != null) return rawFinalReply;

  final finalReply = turn.finalLog?.finalReply?.trim();
  if (finalReply != null && finalReply.isNotEmpty) return finalReply;

  return '';
}

String? resolveRawFinalReply(ConversationTurnLog turn) {
  for (var i = turn.rounds.length - 1; i >= 0; i--) {
    final text = turn.rounds[i].requestLog?.rawAiResponse?.trim();
    if (text != null && text.isNotEmpty) return text;
  }

  final finalRawReply = turn.finalLog?.rawAiResponse?.trim();
  if (finalRawReply != null && finalRawReply.isNotEmpty) return finalRawReply;

  return null;
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
