import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/api_logger.dart' show truncateLongText;
import '../../../../core/app_logger.dart' show LogLevel;
import '../../../../core/log_history_service.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import 'collapsible_selectable_text.dart';
import 'log_formatters.dart';
import 'log_models.dart';

/// 历史日志详情页面
class LogHistoryDetailPage extends StatefulWidget {
  final LogHistoryFile file;

  const LogHistoryDetailPage({super.key, required this.file});

  @override
  State<LogHistoryDetailPage> createState() => _LogHistoryDetailPageState();
}

class _LogHistoryDetailPageState extends State<LogHistoryDetailPage> {
  Map<String, dynamic>? _data;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final data = await LogHistoryService.readHistoryFile(widget.file.filePath);
    if (mounted) {
      setState(() {
        _data = data;
        _isLoading = false;
      });
    }
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
          widget.file.formattedTime,
          style: TextStyle(
            color: colors.text,
            fontSize: 18,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '复制全部',
            icon: Icon(Icons.copy, color: colors.text),
            onPressed: _copyAll,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final colors = context.moeColors;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_data == null) {
      return Center(
        child: Text('无法读取日志文件', style: TextStyle(color: colors.textSecondary)),
      );
    }

    final entries = _buildEntries();
    if (entries.isEmpty) {
      return Center(
        child: Text('日志为空', style: TextStyle(color: colors.textSecondary)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: entries.length,
      itemBuilder: (context, index) => _buildLogItem(entries[index], index),
    );
  }

  List<UnifiedLogEntry> _buildEntries() {
    if (_data == null) return [];

    final entries = <UnifiedLogEntry>[];

    // 解析 API 日志
    final apiLogs = _data!['apiLogs'] as List? ?? [];
    for (final log in apiLogs) {
      if (log is! Map<String, dynamic>) continue;
      final time =
          DateTime.tryParse((log['time'] ?? '').toString()) ?? DateTime.now();
      final isConversation = _isHistoryConversationLog(log);
      final title = isConversation
          ? _formatHistoryConversationTitle(log)
          : '[API] ${log['method'] ?? '--'} ${log['status'] ?? '--'} ${shortenUrl((log['url'] ?? '').toString())}';
      entries.add(UnifiedLogEntry(
        time: time,
        title: title,
        extraContent: isConversation
            ? _formatHistoryConversationExtra(log)
            : _formatApiExtra(log),
        fullContent: isConversation
            ? _formatHistoryConversationFull(log)
            : _formatApiFull(log),
        isApiLog: true,
        isConversation: isConversation,
        rawAiResponse: historyString(log['rawAiResponse']),
        rawContext: historyString(log['rawContext']),
      ));
    }

    // 解析系统日志
    final appLogs = _data!['appLogs'] as List? ?? [];
    for (final log in appLogs) {
      if (log is! Map<String, dynamic>) continue;
      final time =
          DateTime.tryParse((log['time'] ?? '').toString()) ?? DateTime.now();
      final level = parseLogLevel(log['level']);
      final title =
          '[${level.label}] [${log['source'] ?? '--'}] ${log['message'] ?? ''}';
      entries.add(UnifiedLogEntry(
        time: time,
        title: title,
        extraContent: formatMetadata(log['metadata']),
        fullContent: _formatSystemFull(log, level),
        level: level,
      ));
    }

    entries.sort((a, b) => a.time.compareTo(b.time));
    return entries;
  }

  bool _isHistoryConversationLog(Map<String, dynamic> log) {
    bool hasValue(dynamic value) {
      final text = value?.toString().trim() ?? '';
      return text.isNotEmpty;
    }

    return hasValue(log['rawAiResponse']) ||
        hasValue(log['rawContext']) ||
        hasValue(log['rawRequestBody']) ||
        hasValue(log['rawResponseBody']) ||
        hasValue(log['rawToolCalls']) ||
        hasValue(log['rawToolResults']) ||
        hasValue(log['finalReply']) ||
        hasValue(log['turnId']) ||
        hasValue(log['sessionId']);
  }

  String? _formatApiExtra(Map<String, dynamic> log) {
    final parts = <String>[];
    final req = (log['requestBody'] ?? '').toString();
    final res = (log['responseBody'] ?? '').toString();
    if (req.isNotEmpty) parts.add('请求: ${preview(req, 100)}');
    if (res.isNotEmpty) parts.add('响应: ${preview(res, 100)}');
    return parts.isEmpty ? null : parts.join('\n');
  }

  String _formatApiFull(Map<String, dynamic> log) {
    final buffer = StringBuffer();
    buffer.writeln('[API] ${log['method']} ${log['url']}');
    buffer.writeln(
        '状态: ${log['status'] ?? '--'} | 耗时: ${log['durationMs']}ms');
    final reqBody = (log['requestBody'] ?? '').toString();
    if (reqBody.isNotEmpty) {
      buffer.writeln('--- 请求体 ---');
      buffer.writeln(_truncateSystemPromptsInJsonForHistory(reqBody));
    }
    final resBody = (log['responseBody'] ?? '').toString();
    if (resBody.isNotEmpty) {
      buffer.writeln('--- 响应体 ---');
      buffer.writeln(resBody);
    }
    return buffer.toString().trim();
  }

  String _formatHistoryConversationTitle(Map<String, dynamic> log) {
    final direction = historyDirection(log);
    final roundIndex = historyInt(log['roundIndex']);
    final roundText = roundIndex != null ? '（第$roundIndex轮）' : '';
    if (direction == 'AI -> 用户') {
      return '[对话] AI -> 用户（最终回复）';
    }
    return '[对话] $direction$roundText';
  }

  String? _formatHistoryConversationExtra(Map<String, dynamic> log) {
    final direction = historyDirection(log);
    final duration = historyDurationLabel(log);
    final roundIndex = historyInt(log['roundIndex']);
    final toolCallCount = historyCountJsonItems(log['rawToolCalls']);
    final toolResultCount = historyCountJsonItems(log['rawToolResults']);
    final contextCount = historyContextCount(log['rawContext']);
    final finalReply = historyString(log['finalReply']);
    final aiReply = historyString(log['rawAiResponse']);

    final parts = <String>[
      '方向: $direction',
      if (roundIndex != null) '轮次: 第$roundIndex轮',
      '耗时: $duration',
      if (contextCount > 0) '上下文: $contextCount条',
      if (toolCallCount > 0) '工具调用: $toolCallCount次',
      if (toolResultCount > 0) '工具返回: $toolResultCount条',
      if (finalReply != null) '最终回复: ${preview(finalReply, 120)}',
      if (finalReply == null && aiReply != null)
        'AI回复: ${preview(aiReply, 120)}',
    ];

    return parts.join('\n');
  }

  String _formatHistoryConversationFull(Map<String, dynamic> log) {
    final buffer = StringBuffer();
    final direction = historyDirection(log);
    final roundIndex = historyInt(log['roundIndex']);
    final roundText = roundIndex != null ? '第$roundIndex轮' : '未标记轮次';

    buffer.writeln('[对话] $direction | $roundText');
    buffer.writeln(
        '状态: ${log['status'] ?? '--'} | 耗时: ${historyDurationLabel(log)}');

    final ctx = historyString(log['rawContext']);
    final toolCalls = historyString(log['rawToolCalls']);
    final toolResults = historyString(log['rawToolResults']);
    final rawAi = historyString(log['rawAiResponse']);
    final finalReply = historyString(log['finalReply']);

    if (ctx != null) {
      buffer.writeln('\n--- AI 实际收到的完整上下文 ---');
      buffer.writeln(tryFormatJson(ctx));
    }
    if (toolCalls != null) {
      buffer.writeln('\n--- AI -> 工具调用 ---');
      buffer.writeln(tryFormatJson(toolCalls));
    }
    if (toolResults != null) {
      buffer.writeln('\n--- 工具 -> AI 返回 ---');
      buffer.writeln(tryFormatJson(toolResults));
    }
    if (rawAi != null) {
      buffer.writeln('\n--- AI 原始回复 ---');
      buffer.writeln(rawAi);
    }
    if (finalReply != null) {
      buffer.writeln('\n--- 最终展示给用户的回复 ---');
      buffer.writeln(finalReply);
    }

    return buffer.toString().trim();
  }

  /// 截断 JSON 中的系统提示词（历史日志用）
  String _truncateSystemPromptsInJsonForHistory(String jsonStr) {
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
      // 解析失败则返回原文
    }
    return jsonStr;
  }

  String _formatSystemFull(Map<String, dynamic> log, LogLevel level) {
    final buffer = StringBuffer();
    buffer.write('[${level.label}] [${log['source']}] ${log['message']}');
    final metadata = log['metadata'];
    if (metadata != null && metadata is Map && metadata.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('--- metadata ---');
      buffer.write(formatMetadata(metadata) ?? metadata.toString());
    }
    return buffer.toString();
  }

  Widget _buildLogItem(UnifiedLogEntry entry, int index) {
    final colors = context.moeColors;
    final needsFold = entry.needsFold;

    Color levelColor = colors.textSecondary;
    if (entry.level != null) {
      switch (entry.level!) {
        case LogLevel.error:
        case LogLevel.critical:
          levelColor = Colors.red;
          break;
        case LogLevel.warning:
          levelColor = Colors.orange;
          break;
        case LogLevel.info:
          levelColor = colors.primary;
          break;
        case LogLevel.debug:
          levelColor = colors.textSecondary;
          break;
      }
    }
    if (entry.isApiLog) levelColor = Colors.teal;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: MoeG2Decoration(
        radius: 8,
        color: colors.componentBackground,
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  formatTime(entry.time),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: colors.muted,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.title,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: levelColor,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          if (needsFold) ...[
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: colors.borderLight, width: borderWidth),
              ),
              child: CollapsibleSelectableText(
                key: ValueKey(
                    'history_${index}_${entry.extraContent.hashCode}'),
                content: entry.extraContent!,
                collapsedLines: 10,
                toggleColor: colors.primary,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  height: 1.35,
                  color: colors.text,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _copyAll() async {
    final entries = _buildEntries();
    if (entries.isEmpty) {
      MoeToast.info(context, '暂无日志可复制');
      return;
    }

    final buffer = StringBuffer();
    for (final entry in entries) {
      buffer.writeln(entry.fullContent);
      buffer.writeln('---');
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    if (mounted) {
      MoeToast.success(context, '已复制 ${entries.length} 条日志');
    }
  }
}
