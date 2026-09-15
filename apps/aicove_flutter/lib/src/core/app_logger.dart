import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 日志级别
enum LogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warning(2, 'WARNING'),
  error(3, 'ERROR'),
  critical(4, 'CRITICAL');

  final int value;
  final String label;
  const LogLevel(this.value, this.label);
}

/// 日志条目
class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String source; // 来源模块，如 "Core", "TTS", "runners"
  final String? file; // 具体文件名，如 "tts_service.dart"
  final String message;
  final Map<String, dynamic>? metadata; // 额外的元数据
  final String? traceId; // 追踪ID，用于关联同一事件流的日志
  final int depth; // 层级深度，用于缩进显示

  const LogEntry({
    required this.time,
    required this.level,
    required this.source,
    this.file,
    required this.message,
    this.metadata,
    this.traceId,
    this.depth = 0,
  });

  /// 格式化时间戳
  String get formattedTime {
    return '[${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}]';
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'time': time.toIso8601String(),
      'level': level.label,
      'source': source,
      'file': file,
      'message': message,
      'metadata': metadata,
      'traceId': traceId,
      'depth': depth,
    };
  }

  /// 从 JSON 创建
  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      time: DateTime.parse(json['time'] as String),
      level: LogLevel.values.firstWhere(
        (l) => l.label == json['level'],
        orElse: () => LogLevel.info,
      ),
      source: json['source'] as String,
      file: json['file'] as String?,
      message: json['message'] as String,
      metadata: json['metadata'] as Map<String, dynamic>?,
      traceId: json['traceId'] as String?,
      depth: (json['depth'] as int?) ?? 0,
    );
  }
}

/// 应用日志管理器
///
/// 特性：
/// - 实时写入文件，不丢失日志
/// - 写入队列保证顺序，避免并发问题
/// - 初始化前的日志会被缓冲，初始化后批量写入
/// - 缓存文件路径，避免重复计算
class AppLogger {
  static final ValueNotifier<List<LogEntry>> entries =
      ValueNotifier<List<LogEntry>>(<LogEntry>[]);
  static const int maxEntries = 1000; // 内存中最多保存 1000 条日志
  static const String _logDirName = 'logs';

  /// 最小日志级别（低于此级别的日志会被丢弃）
  /// 默认 debug 模式下输出所有，release 模式下只输出 info 及以上
  static LogLevel minLevel = kDebugMode ? LogLevel.debug : LogLevel.info;

  // 初始化状态
  static bool _initialized = false;
  static Completer<void>? _initCompleter;

  // 文件路径缓存
  static String? _cachedLogDirPath;
  static String? _cachedTodayFilePath;
  static int? _cachedFileDay; // 缓存的日期（用于检测跨天）

  // 写入队列
  static const int _writeBatchSize = 32;
  static final ListQueue<LogEntry> _writeQueue = ListQueue<LogEntry>();
  static bool _isWriting = false;
  static int _writtenEntries = 0;
  static int _failedWriteEntries = 0;
  static String? _lastWriteErrorType;

  /// 只是已知写入状态，不是“强杀也零丢失”的承诺。不得为报告健康再次写日志。
  static Map<String, Object?> get diagnosticHealth => {
        'initialized': _initialized,
        'queued': _writeQueue.length + _preInitBuffer.length,
        'writing': _isWriting,
        'writtenEntries': _writtenEntries,
        'failedEntries': _failedWriteEntries,
        if (_lastWriteErrorType != null) 'lastErrorType': _lastWriteErrorType,
      };

  // 初始化前的缓冲区
  static final List<LogEntry> _preInitBuffer = [];

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

  /// 获取当天的日志文件路径（带缓存，自动处理跨天）
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
        'app_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.jsonl';
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
        final buffered = List<LogEntry>.from(_preInitBuffer);
        _preInitBuffer.clear();
        for (final entry in buffered) {
          _enqueueWrite(entry);
        }
      }
    } catch (e) {
      _lastWriteErrorType = e.runtimeType.toString();
      _initialized = true; // 即使失败也标记为已初始化，避免死循环
      _initCompleter!.complete();
      if (kDebugMode) {
        debugPrint('AppLogger 初始化失败: $e');
      }
    }
  }

  /// 将日志加入写入队列
  static void _enqueueWrite(LogEntry entry) {
    _writeQueue.addLast(entry);
    _processWriteQueue();
  }

  /// 处理写入队列（单一协程顺序写入）
  static Future<void> _processWriteQueue() async {
    if (_isWriting || _writeQueue.isEmpty) return;

    _isWriting = true;
    try {
      while (_writeQueue.isNotEmpty) {
        final batch = <LogEntry>[];
        while (_writeQueue.isNotEmpty && batch.length < _writeBatchSize) {
          batch.add(_writeQueue.removeFirst());
        }
        await _writeBatchToFile(batch);
      }
    } finally {
      _isWriting = false;
    }
  }

  /// 批量写入文件，降低频繁 flush 导致的卡顿
  static Future<void> _writeBatchToFile(List<LogEntry> batch) async {
    if (batch.isEmpty) return;
    try {
      final filePath = await _getTodayLogFilePath();
      final file = File(filePath);
      final buffer = StringBuffer();
      for (final entry in batch) {
        buffer.writeln(jsonEncode(entry.toJson()));
      }
      await file.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
      _writtenEntries += batch.length;
    } catch (e) {
      _failedWriteEntries += batch.length;
      _lastWriteErrorType = e.runtimeType.toString();
      if (kDebugMode) {
        debugPrint('日志写入文件失败: $e');
      }
    }
  }

  /// 添加日志
  static void add(LogEntry entry) {
    // 0. 级别过滤：低于最小级别的日志直接丢弃
    if (entry.level.value < minLevel.value) return;

    // 1. 更新内存中的日志列表
    final list = List<LogEntry>.from(entries.value);
    list.add(entry);
    if (list.length > maxEntries) {
      list.removeRange(0, list.length - maxEntries);
    }
    entries.value = list;

    // 2. 写入文件
    if (_initialized) {
      // 已初始化：直接加入写入队列
      _enqueueWrite(entry);
    } else {
      // 未初始化：先缓冲，等初始化完成后再写入
      _preInitBuffer.add(entry);
    }

    // 3. 在开发模式下同时输出到控制台
    if (kDebugMode) {
      _printFormattedLog(entry);
    }
  }

  /// 格式化并打印日志（支持层级缩进和追踪ID）
  static void _printFormattedLog(LogEntry entry) {
    final indent = '  ' * entry.depth; // 每层缩进2个空格
    final traceInfo = entry.traceId != null ? '[Trace:${entry.traceId}] ' : '';
    final location = entry.file ?? entry.source; // 优先显示文件名
    final prefix =
        '${entry.formattedTime} [${entry.level.label}] [$location] $traceInfo$indent';
    debugPrint('$prefix${entry.message}');
  }

  /// 记录 DEBUG 级别日志
  static void debug(String source, String message,
      {String? file,
      Map<String, dynamic>? metadata,
      String? traceId,
      int depth = 0}) {
    add(LogEntry(
      time: DateTime.now(),
      level: LogLevel.debug,
      source: source,
      file: file,
      message: message,
      metadata: metadata,
      traceId: traceId,
      depth: depth,
    ));
  }

  /// 记录 INFO 级别日志
  static void info(String source, String message,
      {String? file,
      Map<String, dynamic>? metadata,
      String? traceId,
      int depth = 0}) {
    add(LogEntry(
      time: DateTime.now(),
      level: LogLevel.info,
      source: source,
      file: file,
      message: message,
      metadata: metadata,
      traceId: traceId,
      depth: depth,
    ));
  }

  /// 记录 WARNING 级别日志
  static void warning(String source, String message,
      {String? file,
      Map<String, dynamic>? metadata,
      String? traceId,
      int depth = 0}) {
    add(LogEntry(
      time: DateTime.now(),
      level: LogLevel.warning,
      source: source,
      file: file,
      message: message,
      metadata: metadata,
      traceId: traceId,
      depth: depth,
    ));
  }

  /// 记录 ERROR 级别日志
  static void error(String source, String message,
      {String? file,
      Map<String, dynamic>? metadata,
      String? traceId,
      int depth = 0}) {
    add(LogEntry(
      time: DateTime.now(),
      level: LogLevel.error,
      source: source,
      file: file,
      message: message,
      metadata: metadata,
      traceId: traceId,
      depth: depth,
    ));
  }

  /// 记录 CRITICAL 级别日志
  static void critical(String source, String message,
      {String? file,
      Map<String, dynamic>? metadata,
      String? traceId,
      int depth = 0}) {
    add(LogEntry(
      time: DateTime.now(),
      level: LogLevel.critical,
      source: source,
      file: file,
      message: message,
      metadata: metadata,
      traceId: traceId,
      depth: depth,
    ));
  }

  /// 清空日志
  static void clear() {
    entries.value = <LogEntry>[];
  }

  /// 导出日志为 JSON 字符串
  static String exportToJson() {
    final data = entries.value.map((e) => e.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// 从 JSON 导入日志
  static void importFromJson(String json) {
    try {
      final List<dynamic> data = jsonDecode(json) as List<dynamic>;
      final logs = data
          .map((item) => LogEntry.fromJson(item as Map<String, dynamic>))
          .toList();
      entries.value = logs;
    } catch (e) {
      error('AppLogger', '导入日志失败: $e');
    }
  }

  /// 创建一个新的追踪日志器
  ///
  /// 用于追踪一个完整的事件流，自动记录开始、结束时间和耗时
  ///
  /// 示例：
  /// ```dart
  /// final trace = AppLogger.startTrace('发送消息', source: 'ChatPage', file: 'chat_page.dart');
  /// trace.info('开始调用API');
  ///
  /// // 创建子追踪
  /// final apiTrace = trace.startChild('API调用');
  /// apiTrace.info('请求已发送');
  /// // ... 执行操作
  /// apiTrace.end(); // 自动计算耗时并记录
  ///
  /// trace.end(); // 结束追踪
  /// ```
  static TraceLogger startTrace(String name,
      {String? source,
      String? file,
      String? traceId,
      LogLevel level = LogLevel.info,
      bool compact = true}) {
    return TraceLogger(
      name: name,
      source: source ?? 'App',
      file: file,
      traceId: traceId,
      level: level,
      compact: compact,
    );
  }
}

/// 追踪ID生成器
class _TraceIdGenerator {
  static final _random = Random();
  static const _chars = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// 生成一个短的追踪ID（8位字符）
  static String generate() {
    return List.generate(8, (_) => _chars[_random.nextInt(_chars.length)])
        .join();
  }
}

/// 追踪日志器
///
/// 用于追踪一个完整的事件流，支持：
/// - 自动生成追踪ID
/// - 层级嵌套（子追踪）
/// - 自动计时和耗时统计
/// - 可视化的层级缩进显示
class TraceLogger {
  final String traceId;
  final String name;
  final String source;
  final String? file;
  final LogLevel level;
  final int depth;
  final DateTime startTime;
  final TraceLogger? parent;
  final bool compact;
  final List<String> _notes = <String>[];

  TraceLogger({
    required this.name,
    required this.source,
    this.file,
    this.level = LogLevel.info,
    String? traceId,
    this.depth = 0,
    this.parent,
    this.compact = true,
  })  : traceId = traceId ?? _TraceIdGenerator.generate(),
        startTime = DateTime.now() {
    if (!compact) {
      // 记录开始日志
      _log(level, '▶ 开始: $name');
    }
  }

  /// 记录日志（使用当前追踪的上下文）
  void _log(LogLevel logLevel, String message,
      {Map<String, dynamic>? metadata}) {
    AppLogger.add(LogEntry(
      time: DateTime.now(),
      level: logLevel,
      source: source,
      file: file,
      message: message,
      metadata: metadata,
      traceId: traceId,
      depth: depth,
    ));
  }

  /// 记录一个不会立即输出的关键点，便于在结束时统一展示
  void note(String label, {Map<String, dynamic>? metadata}) {
    final extra = _inlineMetadata(metadata);
    final text = extra.isEmpty ? label : '$label ($extra)';
    _notes.add(text);
    if (!compact) {
      _log(LogLevel.debug, text);
    }
  }

  /// 记录 DEBUG 日志
  void debug(String message, {Map<String, dynamic>? metadata}) {
    _log(LogLevel.debug, message, metadata: metadata);
  }

  /// 记录 INFO 日志
  void info(String message, {Map<String, dynamic>? metadata}) {
    _log(LogLevel.info, message, metadata: metadata);
  }

  /// 记录 WARNING 日志
  void warning(String message, {Map<String, dynamic>? metadata}) {
    _log(LogLevel.warning, message, metadata: metadata);
  }

  /// 记录 ERROR 日志
  void error(String message, {Map<String, dynamic>? metadata}) {
    _log(LogLevel.error, message, metadata: metadata);
  }

  /// 记录 CRITICAL 日志
  void critical(String message, {Map<String, dynamic>? metadata}) {
    _log(LogLevel.critical, message, metadata: metadata);
  }

  /// 创建子追踪（用于嵌套的操作）
  ///
  /// 子追踪会继承父追踪的 traceId，但层级深度会+1
  TraceLogger startChild(String childName,
      {String? childSource, String? childFile}) {
    return TraceLogger(
      name: childName,
      source: childSource ?? source,
      file: childFile ?? file,
      level: level,
      traceId: traceId, // 继承父追踪的ID
      depth: depth + 1, // 层级加深
      parent: this,
      compact: compact,
    );
  }

  /// 结束追踪，自动计算并记录耗时
  void end({String? additionalMessage}) {
    final duration = DateTime.now().difference(startTime);
    final durationText = _formatDuration(duration);
    final buffer = StringBuffer();
    if (compact) {
      buffer.write('◀ $name (耗时: $durationText)');
    } else {
      buffer.write('◀ 完成: $name (耗时: $durationText)');
    }
    if (additionalMessage != null && additionalMessage.isNotEmpty) {
      buffer.write(' - $additionalMessage');
    }
    if (_notes.isNotEmpty) {
      buffer.write(' | ');
      buffer.write(_notes.join(' · '));
    }
    _log(level, buffer.toString());
  }

  /// 格式化耗时显示
  String _formatDuration(Duration duration) {
    if (duration.inSeconds < 1) {
      return '${duration.inMilliseconds}ms';
    } else if (duration.inMinutes < 1) {
      final sec = duration.inMilliseconds / 1000;
      return '${sec.toStringAsFixed(2)}s';
    } else {
      final min = duration.inMinutes;
      final sec = duration.inSeconds % 60;
      return '${min}m${sec}s';
    }
  }

  String _inlineMetadata(Map<String, dynamic>? metadata) {
    if (metadata == null || metadata.isEmpty) {
      return '';
    }
    final parts = <String>[];
    metadata.forEach((key, value) {
      parts.add('$key=${_shortValue(value)}');
    });
    return parts.join(', ');
  }

  String _shortValue(Object? value) {
    final text = value?.toString() ?? 'null';
    if (text.length <= 80) {
      return text;
    }
    return '${text.substring(0, 80)}…';
  }
}
