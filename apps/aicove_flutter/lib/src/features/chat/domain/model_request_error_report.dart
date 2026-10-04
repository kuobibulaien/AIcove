import 'dart:convert';

import '../../../core/app_logger.dart';

/// 模型请求失败的报错整理：弹窗主文案取主要原因，复制按钮导出本轮完整日志。
class ModelRequestErrorReport {
  ModelRequestErrorReport._();

  static const int _maxSummaryLength = 300;

  static const Map<int, String> _statusHints = {
    400: '请求参数错误',
    401: '鉴权失败，请检查 API Key',
    402: '账户余额不足',
    403: '没有访问权限',
    404: '接口地址或模型不存在',
    408: '请求超时',
    413: '请求内容过大',
    422: '请求参数无法处理',
    429: '请求过于频繁或额度不足',
    500: '服务端内部错误',
    502: '网关错误',
    503: '服务暂时不可用',
    504: '网关超时',
  };

  /// 从原始异常文本中提取一句主要原因。
  static String summarize(String rawError) {
    final text = _stripExceptionPrefix(rawError.trim());
    if (text.isEmpty) {
      return '未知错误';
    }

    final httpMatch =
        RegExp(r'^HTTP\s+(\d{3})\s*:?\s*(.*)$', dotAll: true).firstMatch(text);
    if (httpMatch != null) {
      final status = int.parse(httpMatch.group(1)!);
      final hint = _statusHints[status] ??
          (status >= 500 ? '服务端错误' : (status >= 400 ? '请求被拒绝' : null));
      final message = _extractBodyMessage(httpMatch.group(2) ?? '');
      final head = hint == null ? 'HTTP $status' : 'HTTP $status $hint';
      return message.isEmpty ? head : '$head：$message';
    }

    final sseMatch =
        RegExp(r'^SSE error:\s*(.*)$', dotAll: true).firstMatch(text);
    if (sseMatch != null) {
      return '流式返回错误：${_truncate(_collapse(sseMatch.group(1) ?? ''))}';
    }

    final lower = text.toLowerCase();
    if (lower.contains('timeoutexception') || lower.contains('timed out')) {
      return '请求超时：${_firstLine(text)}';
    }
    if (lower.contains('handshakeexception') ||
        lower.contains('certificate_verify_failed')) {
      return 'TLS 握手失败：${_firstLine(text)}';
    }
    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('connection closed') ||
        lower.contains('clientexception')) {
      return '网络连接失败：${_firstLine(text)}';
    }
    return _firstLine(text);
  }

  /// 拼出本轮完整报错日志，供用户一键复制。
  static String buildFullLog({
    required String failedModelName,
    required String nextModelName,
    required String errorMessage,
    String? errorDetail,
    DateTime? roundStartedAt,
    required DateTime failedAt,
    required List<LogEntry> logEntries,
  }) {
    final roundEntries = roundStartedAt == null
        ? const <LogEntry>[]
        : logEntries
            .where((entry) => !entry.time.isBefore(roundStartedAt))
            .toList(growable: false);

    final buffer = StringBuffer()
      ..writeln('AIcove 模型请求报错日志（本轮）')
      ..writeln('失败时间：${failedAt.toIso8601String()}')
      ..writeln('失败模型：$failedModelName')
      ..writeln('下一个模型：$nextModelName')
      ..writeln('主要原因：${summarize(errorMessage)}')
      ..writeln()
      ..writeln('== 完整报错 ==')
      ..writeln(errorDetail?.trim().isNotEmpty == true
          ? errorDetail!.trim()
          : errorMessage.trim());

    buffer.writeln();
    if (roundStartedAt == null) {
      buffer.writeln('== 本轮日志 ==');
      buffer.writeln('（未记录本轮开始时间）');
    } else {
      buffer.writeln(
        '== 本轮日志（${roundEntries.length} 条，'
        '自 ${roundStartedAt.toIso8601String()} 起）==',
      );
      for (final entry in roundEntries) {
        buffer.writeln(_formatEntry(entry));
      }
    }
    return buffer.toString().trimRight();
  }

  static String _formatEntry(LogEntry entry) {
    final location =
        entry.file == null ? entry.source : '${entry.source}/${entry.file}';
    final trace = entry.traceId == null ? '' : ' [trace:${entry.traceId}]';
    final line = StringBuffer(
      '${entry.time.toIso8601String()} ${entry.level.label} '
      '$location$trace: ${entry.message}',
    );
    final metadata = entry.metadata;
    if (metadata != null && metadata.isNotEmpty) {
      line.write(' ');
      line.write(_encodeMetadata(metadata));
    }
    return line.toString();
  }

  static String _encodeMetadata(Map<String, dynamic> metadata) {
    try {
      return jsonEncode(metadata, toEncodable: (value) => value.toString());
    } catch (_) {
      return metadata.toString();
    }
  }

  static String _stripExceptionPrefix(String text) {
    var result = text;
    const prefixes = [
      'Exception: ',
      'ApiError: ',
      'Bad state: ',
      'Unsupported operation: ',
      'Invalid argument(s): ',
    ];
    var changed = true;
    while (changed) {
      changed = false;
      for (final prefix in prefixes) {
        if (result.startsWith(prefix)) {
          result = result.substring(prefix.length).trimLeft();
          changed = true;
        }
      }
    }
    return result;
  }

  static String _extractBodyMessage(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    try {
      final message = _messageFromJson(jsonDecode(trimmed));
      if (message != null && message.trim().isNotEmpty) {
        return _truncate(_collapse(message));
      }
    } catch (_) {
      // 非 JSON 响应体，按纯文本处理。
    }
    final plain = trimmed.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return _truncate(_collapse(plain));
  }

  static String? _messageFromJson(Object? decoded) {
    if (decoded is String) {
      return decoded;
    }
    if (decoded is List) {
      return decoded.isEmpty ? null : _messageFromJson(decoded.first);
    }
    if (decoded is! Map) {
      return null;
    }
    for (final key in const ['error', 'message', 'detail', 'msg', 'errors']) {
      final value = decoded[key];
      if (value == null) continue;
      final message = _messageFromJson(value);
      if (message != null && message.trim().isNotEmpty) {
        return message;
      }
    }
    return null;
  }

  static String _firstLine(String text) {
    final line = text.split('\n').firstWhere(
          (part) => part.trim().isNotEmpty,
          orElse: () => text,
        );
    return _truncate(line.trim());
  }

  static String _collapse(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _truncate(String text) => text.length <= _maxSummaryLength
      ? text
      : '${text.substring(0, _maxSummaryLength)}…';
}
