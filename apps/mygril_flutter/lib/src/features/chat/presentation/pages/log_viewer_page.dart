import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/api_logger.dart';
import '../../../../core/app_logger.dart';
import '../../../../core/theme/tokens.dart';

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _logScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.text),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '日志中心',
          style: TextStyle(
            color: colors.text,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '导出并复制到剪贴板',
            icon: Icon(Icons.file_download_outlined, color: colors.text),
            onPressed: _exportLogs,
          ),
          IconButton(
            tooltip: '清空日志',
            icon: Icon(Icons.delete_outline, color: colors.text),
            onPressed: _confirmClearLogs,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final colors = context.moeColors;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      padding: const EdgeInsets.all(12),
      child: ValueListenableBuilder<List<ApiLogEntry>>(
        valueListenable: ApiLogger.entries,
        builder: (context, apiLogs, _) {
          return ValueListenableBuilder<List<LogEntry>>(
            valueListenable: AppLogger.entries,
            builder: (context, systemLogs, __) {
              final content = _buildCombinedLogText(apiLogs, systemLogs);

              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

              if (content.isEmpty) {
                return Center(
                  child: Text(
                    '暂无日志',
                    style: TextStyle(color: colors.textSecondary),
                  ),
                );
              }

              return SingleChildScrollView(
                controller: _logScrollController,
                child: SelectableText(
                  content,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                    color: colors.text,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _buildCombinedLogText(List<ApiLogEntry> apiLogs, List<LogEntry> systemLogs) {
    final buffer = StringBuffer();

    if (apiLogs.isNotEmpty) {
      buffer.writeln('=== API 请求 ===');
      for (final log in apiLogs) {
        buffer.writeln(_formatApiLogAsText(log));
      }
      buffer.writeln();
    }

    if (systemLogs.isNotEmpty) {
      buffer.writeln('=== 系统日志 ===');
      for (final log in systemLogs) {
        buffer.writeln(_formatLogAsText(log));
      }
    }

    return buffer.toString().trim();
  }

  String _formatLogAsText(LogEntry log) {
    final indent = '  ' * log.depth;
    final traceInfo = log.traceId != null ? '[Trace:${log.traceId}] ' : '';

    String metadataStr = '';
    if (log.metadata != null && log.metadata!.isNotEmpty) {
      try {
        metadataStr = ' | metadata: ${jsonEncode(log.metadata)}';
      } catch (_) {
        metadataStr = ' | metadata: ${log.metadata}';
      }
    }

    return '${log.formattedTime} [${log.level.label}] [${log.source}] $traceInfo$indent${log.message}$metadataStr';
  }

  String _formatApiLogAsText(ApiLogEntry log) {
    final time = _formatDateTime(log.time);
    final status = log.status?.toString() ?? '--';
    final result = log.ok ? '✓' : '✗';
    final reqSize = log.requestBody.isEmpty ? '无' : '${log.requestBody.length}B';
    final resSize = log.responseBody.isEmpty ? '无' : '${log.responseBody.length}B';
    final bodySizeInfo = ' [req:$reqSize res:$resSize]';

    return '[$time] [${log.method}] $status ${log.durationMs}ms $result ${log.url}$bodySizeInfo';
  }

  String _formatDateTime(DateTime time) {
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }

  void _exportLogs() {
    final content = _buildCombinedLogText(ApiLogger.entries.value, AppLogger.entries.value);
    if (content.isEmpty) {
      _showSnackBar('暂无日志可导出');
      return;
    }
    _copyToClipboard(content);
    _showSnackBar('已复制到剪贴板');
  }

  void _confirmClearLogs() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确认要清空所有日志吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _clearLogs();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  void _clearLogs() {
    ApiLogger.clear();
    AppLogger.clear();
    setState(() {});
    _showSnackBar('日志已清空');
  }

  void _scrollToBottom() {
    if (!_logScrollController.hasClients) return;
    _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
