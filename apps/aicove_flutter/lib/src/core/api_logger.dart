import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 截断长文本，保留头尾
///
/// 用于日志中显示长提示词时，只保留头尾部分，中间用省略号代替
/// [text] 原始文本
/// [maxLength] 最大长度（默认100）
/// [headRatio] 头部占比（默认0.6，即头部占60%）
String truncateLongText(String text,
    {int maxLength = 100, double headRatio = 0.6}) {
  if (text.length <= maxLength) return text;

  final headLen = (maxLength * headRatio).round();
  final tailLen = maxLength - headLen - 5; // 5 是省略号 "..." 的预留

  if (tailLen <= 0) {
    return '${text.substring(0, maxLength - 3)}...';
  }

  return '${text.substring(0, headLen)}...${text.substring(text.length - tailLen)}';
}

class ApiLogEntry {
  final DateTime time;
  final String method;
  final String url;
  final int? status;
  final int durationMs;
  final String requestBody;
  final String responseBody;
  final bool ok;

  /// AI 原始完整回复（未截断，用于调试）
  final String? rawAiResponse;

  /// AI 收到的原始上下文（完整消息列表，JSON 格式）
  final String? rawContext;

  /// 直连请求的完整 JSON 请求体（不截断）
  final String? rawRequestBody;

  /// 直连请求的完整 JSON 响应体（不截断）
  final String? rawResponseBody;

  /// 解析后的 tool_calls（JSON 字符串）
  final String? rawToolCalls;
  final String? sessionId;
  final String? turnId;
  final int? roundIndex;
  final String? eventType;
  final String? rawToolResults;
  final String? finalReply;

  /// 是否为 AI 对话日志（用于筛选）
  bool get isConversation =>
      rawAiResponse != null ||
      rawContext != null ||
      rawRequestBody != null ||
      rawResponseBody != null ||
      rawToolCalls != null ||
      rawToolResults != null ||
      finalReply != null ||
      turnId != null ||
      sessionId != null;

  const ApiLogEntry({
    required this.time,
    required this.method,
    required this.url,
    required this.status,
    required this.durationMs,
    required this.requestBody,
    required this.responseBody,
    required this.ok,
    this.rawAiResponse,
    this.rawContext,
    this.rawRequestBody,
    this.rawResponseBody,
    this.rawToolCalls,
    this.sessionId,
    this.turnId,
    this.roundIndex,
    this.eventType,
    this.rawToolResults,
    this.finalReply,
  });

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'time': time.toIso8601String(),
      'method': method,
      'url': url,
      'status': status,
      'durationMs': durationMs,
      'requestBody': requestBody,
      'responseBody': responseBody,
      'ok': ok,
      if (rawAiResponse != null) 'rawAiResponse': rawAiResponse,
      if (rawContext != null) 'rawContext': rawContext,
      if (rawRequestBody != null) 'rawRequestBody': rawRequestBody,
      if (rawResponseBody != null) 'rawResponseBody': rawResponseBody,
      if (rawToolCalls != null) 'rawToolCalls': rawToolCalls,
      if (sessionId != null) 'sessionId': sessionId,
      if (turnId != null) 'turnId': turnId,
      if (roundIndex != null) 'roundIndex': roundIndex,
      if (eventType != null) 'eventType': eventType,
      if (rawToolResults != null) 'rawToolResults': rawToolResults,
      if (finalReply != null) 'finalReply': finalReply,
    };
  }

  /// 从 JSON 创建
  factory ApiLogEntry.fromJson(Map<String, dynamic> json) {
    return ApiLogEntry(
      time: DateTime.parse(json['time'] as String),
      method: json['method'] as String,
      url: json['url'] as String,
      status: json['status'] as int?,
      durationMs: json['durationMs'] as int,
      requestBody: json['requestBody'] as String? ?? '',
      responseBody: json['responseBody'] as String? ?? '',
      ok: json['ok'] as bool,
      rawAiResponse: json['rawAiResponse'] as String?,
      rawContext: json['rawContext'] as String?,
      rawRequestBody: json['rawRequestBody'] as String?,
      rawResponseBody: json['rawResponseBody'] as String?,
      rawToolCalls: json['rawToolCalls'] as String?,
      sessionId: json['sessionId'] as String?,
      turnId: json['turnId'] as String?,
      roundIndex: json['roundIndex'] as int?,
      eventType: json['eventType'] as String?,
      rawToolResults: json['rawToolResults'] as String?,
      finalReply: json['finalReply'] as String?,
    );
  }
}

/// API 日志管理器
///
/// 特性：
/// - 实时写入文件，不丢失日志
/// - 写入队列保证顺序，避免并发问题
/// - 初始化前的日志会被缓冲，初始化后批量写入
/// - 缓存文件路径，避免重复计算
class ApiLogger {
  static final ValueNotifier<List<ApiLogEntry>> entries =
      ValueNotifier<List<ApiLogEntry>>(<ApiLogEntry>[]);
  static const int _max = 200;
  static const String _logDirName = 'logs';

  // 初始化状态
  static bool _initialized = false;
  static Completer<void>? _initCompleter;

  // 文件路径缓存
  static String? _cachedLogDirPath;
  static String? _cachedTodayFilePath;
  static int? _cachedFileDay; // 缓存的日期（用于检测跨天）

  // 写入队列
  static final List<ApiLogEntry> _writeQueue = [];
  static bool _isWriting = false;

  // 初始化前的缓冲区
  static final List<ApiLogEntry> _preInitBuffer = [];

  /// 获取日志存储目录（带缓存）
  static Future<String> _getLogDirPath() async {
    if (_cachedLogDirPath != null) return _cachedLogDirPath!;

    final appDir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${appDir.path}/$_logDirName');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    _cachedLogDirPath = logDir.path;
    return _cachedLogDirPath!;
  }

  /// 获取当天的API日志文件路径（带缓存，自动处理跨天）
  static Future<String> _getTodayLogFilePath() async {
    final now = DateTime.now();
    final today = now.day;

    // 如果日期变了，清除缓存
    if (_cachedFileDay != null && _cachedFileDay != today) {
      _cachedTodayFilePath = null;
    }

    if (_cachedTodayFilePath != null) return _cachedTodayFilePath!;

    final logDirPath = await _getLogDirPath();
    final fileName =
        'api_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.jsonl';
    _cachedTodayFilePath = '$logDirPath/$fileName';
    _cachedFileDay = today;
    return _cachedTodayFilePath!;
  }

  /// 初始化日志系统
  ///
  /// 只准备好文件路径，不加载历史日志到内存。
  /// 内存中只保留本次 session 的日志，历史日志通过 LogHistoryService 查看。
  static Future<void> initialize() async {
    if (_initialized) return;

    // 防止重复初始化
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }
    _initCompleter = Completer<void>();

    try {
      // 预热文件路径缓存，确保目录存在
      await _getTodayLogFilePath();

      _initialized = true;
      _initCompleter!.complete();

      // 将初始化前缓冲的日志写入文件
      if (_preInitBuffer.isNotEmpty) {
        final buffered = List<ApiLogEntry>.from(_preInitBuffer);
        _preInitBuffer.clear();
        for (final entry in buffered) {
          _enqueueWrite(entry);
        }
      }
    } catch (e) {
      _initialized = true; // 即使失败也标记为已初始化，避免死循环
      _initCompleter!.complete();
      if (kDebugMode) {
        debugPrint('ApiLogger 初始化失败: $e');
      }
    }
  }

  /// 将日志加入写入队列
  static void _enqueueWrite(ApiLogEntry entry) {
    _writeQueue.add(entry);
    _processWriteQueue();
  }

  /// 处理写入队列（单一协程顺序写入）
  static Future<void> _processWriteQueue() async {
    if (_isWriting || _writeQueue.isEmpty) return;

    _isWriting = true;
    try {
      while (_writeQueue.isNotEmpty) {
        final entry = _writeQueue.removeAt(0);
        await _writeToFile(entry);
      }
    } finally {
      _isWriting = false;
    }
  }

  /// 实际写入文件
  static Future<void> _writeToFile(ApiLogEntry entry) async {
    try {
      final filePath = await _getTodayLogFilePath();
      final file = File(filePath);
      final line = '${jsonEncode(entry.toJson())}\n';
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('API日志写入文件失败: $e');
      }
    }
  }

  static void add(ApiLogEntry e) {
    // 1. 更新内存中的日志列表
    final list = List<ApiLogEntry>.from(entries.value);
    list.add(e);
    if (list.length > _max) {
      list.removeRange(0, list.length - _max);
    }
    entries.value = list;

    // 2. 写入文件
    if (_initialized) {
      // 已初始化：直接加入写入队列
      _enqueueWrite(e);
    } else {
      // 未初始化：先缓冲，等初始化完成后再写入
      _preInitBuffer.add(e);
    }
  }

  static void clear() {
    entries.value = <ApiLogEntry>[];
  }

  static String safeSnippet(String s, {int max = 800}) {
    String out = s;
    // 屏蔽常见敏感字段
    out = out.replaceAllMapped(
        RegExp(r'("api_key"\s*:\s*")([^"\\]{4,})(")', multiLine: true),
        (m) => '${m.group(1)}***${m.group(3)}');
    out = out.replaceAllMapped(
        RegExp(r'(sk-)[A-Za-z0-9]{8,}'), (m) => '${m.group(1)}****');

    // 尝试解析 JSON 并截断 system 角色的长提示词
    try {
      final decoded = jsonDecode(out);
      if (decoded is Map<String, dynamic>) {
        _truncateSystemPrompts(decoded);
        out = jsonEncode(decoded);
      }
    } catch (_) {
      // 解析失败则保持原样
    }

    if (out.length > max) {
      return '${out.substring(0, max)}…';
    }
    return out;
  }

  /// 递归截断 messages 中 system 角色的长提示词
  static void _truncateSystemPrompts(Map<String, dynamic> data) {
    // 处理 messages 数组
    final messages = data['messages'];
    if (messages is List) {
      for (final msg in messages) {
        if (msg is Map<String, dynamic>) {
          final role = msg['role'];
          if (role == 'system') {
            final content = msg['content'];
            if (content is String && content.length > 100) {
              msg['content'] = truncateLongText(content, maxLength: 100);
            }
          }
        }
      }
    }

    // 处理 history 数组（兼容旧格式）
    final history = data['history'];
    if (history is List) {
      for (final msg in history) {
        if (msg is Map<String, dynamic>) {
          final role = msg['role'];
          if (role == 'system') {
            final content = msg['content'];
            if (content is String && content.length > 100) {
              msg['content'] = truncateLongText(content, maxLength: 100);
            }
          }
        }
      }
    }
  }

  static String prettyJson(String s) {
    try {
      final obj = jsonDecode(s);
      return const JsonEncoder.withIndent('  ').convert(obj);
    } catch (_) {
      return s;
    }
  }
}
