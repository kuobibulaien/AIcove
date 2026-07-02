import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 日志历史文件信息
class LogHistoryFile {
  final String fileName;
  final DateTime createdAt;
  final int size;
  final String filePath;
  final String type; // 'app' 或 'api'

  LogHistoryFile({
    required this.fileName,
    required this.createdAt,
    required this.size,
    required this.filePath,
    this.type = 'unknown',
  });

  /// 格式化的创建时间
  String get formattedTime {
    return '${createdAt.year}-${createdAt.month.toString().padLeft(2, '0')}-${createdAt.day.toString().padLeft(2, '0')}';
  }

  /// 格式化的文件大小
  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 类型显示名称
  String get typeLabel {
    switch (type) {
      case 'app':
        return '应用日志';
      case 'api':
        return 'API日志';
      default:
        return '历史日志';
    }
  }
}

/// 日志历史服务
///
/// 负责管理历史日志文件的读取和清理
/// 注：日志现在实时保存到 logs/ 目录，不再需要在后台手动保存
class LogHistoryService {
  static const String _logDirName = 'logs'; // 新的实时日志目录
  static const String _oldLogDirName = 'log_history'; // 旧的手动保存目录（兼容）
  static const String _traceDirName = 'trace';
  static const int _retentionDays = 7;

  /// 获取日志存储目录
  static Future<Directory> _getLogDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${appDir.path}/$_logDirName');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    return logDir;
  }

  /// 获取旧日志目录（兼容）
  static Future<Directory?> _getOldLogDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${appDir.path}/$_oldLogDirName');
    if (await logDir.exists()) {
      return logDir;
    }
    return null;
  }

  /// 【已废弃】保存当前日志到文件
  ///
  /// 现在日志已改为实时写入文件，此方法保留用于兼容旧代码，
  /// 实际不会执行任何操作（因为日志已经保存了）
  @Deprecated('日志已改为实时保存，此方法不再需要调用')
  static Future<String?> saveCurrentLogs() async {
    // 日志已经实时保存到文件，无需额外操作
    return null;
  }

  /// 获取所有历史日志文件列表
  static Future<List<LogHistoryFile>> getHistoryFiles() async {
    final files = <LogHistoryFile>[];

    // 1. 读取新的实时日志文件（app_*.jsonl 和 api_*.jsonl）
    final logDir = await _getLogDir();
    await for (final entity in logDir.list()) {
      if (entity is File) {
        final fileName = entity.path.split(Platform.pathSeparator).last;

        // 解析应用日志: app_2026-01-28.jsonl
        final appMatch =
            RegExp(r'app_(\d{4})-(\d{2})-(\d{2})\.jsonl').firstMatch(fileName);
        if (appMatch != null) {
          final stat = await entity.stat();
          files.add(LogHistoryFile(
            fileName: fileName,
            createdAt: DateTime(
              int.parse(appMatch.group(1)!),
              int.parse(appMatch.group(2)!),
              int.parse(appMatch.group(3)!),
            ),
            size: stat.size,
            filePath: entity.path,
            type: 'app',
          ));
          continue;
        }

        // 解析API日志: api_2026-01-28.jsonl
        final apiMatch =
            RegExp(r'api_(\d{4})-(\d{2})-(\d{2})\.jsonl').firstMatch(fileName);
        if (apiMatch != null) {
          final stat = await entity.stat();
          files.add(LogHistoryFile(
            fileName: fileName,
            createdAt: DateTime(
              int.parse(apiMatch.group(1)!),
              int.parse(apiMatch.group(2)!),
              int.parse(apiMatch.group(3)!),
            ),
            size: stat.size,
            filePath: entity.path,
            type: 'api',
          ));
        }
      }
    }

    // 2. 兼容旧的历史日志文件（log_*.json）
    final oldLogDir = await _getOldLogDir();
    if (oldLogDir != null) {
      await for (final entity in oldLogDir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final stat = await entity.stat();
          final fileName = entity.path.split(Platform.pathSeparator).last;

          DateTime? createdAt;
          final match = RegExp(
                  r'log_(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})\.json')
              .firstMatch(fileName);
          if (match != null) {
            createdAt = DateTime(
              int.parse(match.group(1)!),
              int.parse(match.group(2)!),
              int.parse(match.group(3)!),
              int.parse(match.group(4)!),
              int.parse(match.group(5)!),
              int.parse(match.group(6)!),
            );
          }

          files.add(LogHistoryFile(
            fileName: fileName,
            createdAt: createdAt ?? stat.modified,
            size: stat.size,
            filePath: entity.path,
            type: 'legacy',
          ));
        }
      }
    }

    // 按日期排序（新的在前）
    files.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return files;
  }

  /// 读取历史日志文件内容
  static Future<Map<String, dynamic>?> readHistoryFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final fileName = filePath.split(Platform.pathSeparator).last;

      // 处理新的 JSONL 格式（app_*.jsonl 或 api_*.jsonl）
      if (filePath.endsWith('.jsonl')) {
        final lines = await file.readAsLines();
        final entries = <Map<String, dynamic>>[];

        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            entries.add(jsonDecode(line) as Map<String, dynamic>);
          } catch (_) {
            // 跳过损坏的行
          }
        }

        // 判断是应用日志还是API日志
        final isApiLog = fileName.startsWith('api_');

        if (isApiLog) {
          return {
            'savedAt': DateTime.now().toIso8601String(),
            'apiLogs': entries,
            'appLogs': <Map<String, dynamic>>[],
          };
        } else {
          return {
            'savedAt': DateTime.now().toIso8601String(),
            'apiLogs': <Map<String, dynamic>>[],
            'appLogs': entries,
          };
        }
      }

      // 处理旧的 JSON 格式
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// 删除指定的历史日志文件
  static Future<bool> deleteHistoryFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 清理过期的日志文件（超过7天）
  static Future<int> cleanExpiredLogs() async {
    int deletedCount = 0;
    final now = DateTime.now();
    final expireDate = now.subtract(const Duration(days: _retentionDays));

    // 清理新的日志文件
    final logDir = await _getLogDir();
    await for (final entity in logDir.list()) {
      if (entity is File && entity.path.endsWith('.jsonl')) {
        final fileName = entity.path.split(Platform.pathSeparator).last;
        final match = RegExp(r'(app|api)_(\d{4})-(\d{2})-(\d{2})\.jsonl')
            .firstMatch(fileName);
        if (match != null) {
          final fileDate = DateTime(
            int.parse(match.group(2)!),
            int.parse(match.group(3)!),
            int.parse(match.group(4)!),
          );
          if (fileDate.isBefore(expireDate)) {
            await entity.delete();
            deletedCount++;
          }
        }
      }
    }

    // 清理 Trace 日志文件（index_YYYY-MM-DD.jsonl）与导出文件
    final traceDir = Directory('${logDir.path}/$_traceDirName');
    if (await traceDir.exists()) {
      await for (final entity in traceDir.list(recursive: true)) {
        if (entity is! File) continue;
        final fileName = entity.path.split(Platform.pathSeparator).last;
        if (fileName.endsWith('.jsonl') && fileName.startsWith('index_')) {
          final match = RegExp(r'index_(\d{4})-(\d{2})-(\d{2})\.jsonl')
              .firstMatch(fileName);
          if (match != null) {
            final fileDate = DateTime(
              int.parse(match.group(1)!),
              int.parse(match.group(2)!),
              int.parse(match.group(3)!),
            );
            if (fileDate.isBefore(expireDate)) {
              await entity.delete();
              deletedCount++;
            }
            continue;
          }
        }

        // Payload 文件优先按目录日期清理：trace/payload/YYYY-MM-DD/*.json
        final normalizedPath = entity.path.replaceAll('\\', '/').toLowerCase();
        final payloadMatch =
            RegExp(r'/trace/payload/(\d{4})-(\d{2})-(\d{2})/').firstMatch(
          normalizedPath,
        );
        if (payloadMatch != null) {
          final fileDate = DateTime(
            int.parse(payloadMatch.group(1)!),
            int.parse(payloadMatch.group(2)!),
            int.parse(payloadMatch.group(3)!),
          );
          if (fileDate.isBefore(expireDate)) {
            await entity.delete();
            deletedCount++;
          }
          continue;
        }

        // 导出文件按修改时间清理（文件名可能不固定）
        final stat = await entity.stat();
        if (stat.modified.isBefore(expireDate)) {
          await entity.delete();
          deletedCount++;
        }
      }
    }

    // 清理旧的历史日志文件
    final oldLogDir = await _getOldLogDir();
    if (oldLogDir != null) {
      await for (final entity in oldLogDir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final fileName = entity.path.split(Platform.pathSeparator).last;
          final match =
              RegExp(r'log_(\d{4})-(\d{2})-(\d{2})_').firstMatch(fileName);
          if (match != null) {
            final fileDate = DateTime(
              int.parse(match.group(1)!),
              int.parse(match.group(2)!),
              int.parse(match.group(3)!),
            );
            if (fileDate.isBefore(expireDate)) {
              await entity.delete();
              deletedCount++;
            }
          }
        }
      }
    }

    return deletedCount;
  }

  /// 清理所有历史日志
  static Future<int> clearAllHistory() async {
    int deletedCount = 0;

    // 清理新的日志文件
    final logDir = await _getLogDir();
    await for (final entity in logDir.list()) {
      if (entity is File && entity.path.endsWith('.jsonl')) {
        await entity.delete();
        deletedCount++;
      }
    }

    // 清理 Trace 目录下的索引与导出文件
    final traceDir = Directory('${logDir.path}/$_traceDirName');
    if (await traceDir.exists()) {
      await for (final entity in traceDir.list(recursive: true)) {
        if (entity is File &&
            (entity.path.endsWith('.jsonl') || entity.path.endsWith('.json'))) {
          await entity.delete();
          deletedCount++;
        }
      }
    }

    // 清理旧的历史日志文件
    final oldLogDir = await _getOldLogDir();
    if (oldLogDir != null) {
      await for (final entity in oldLogDir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          await entity.delete();
          deletedCount++;
        }
      }
    }

    return deletedCount;
  }
}
