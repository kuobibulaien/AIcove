import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/api_logger.dart'
    show ApiLogEntry, ApiLogger, truncateLongText;
import '../../../../core/app_logger.dart';
import '../../../../core/log_history_service.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';

/// 统一的日志条目（合并 API 日志和系统日志）
class _UnifiedLogEntry {
  final DateTime time;
  final String title; // 简短标题（一行显示）
  final String? extraContent; // 额外内容（metadata 等，不重复标题）
  final String fullContent; // 完整内容（用于复制）
  final LogLevel? level;
  final bool isApiLog;
  final bool isConversation; // 是否为 AI 对话日志

  /// AI 原始回复（完整）
  final String? rawAiResponse;

  /// AI 收到的原始上下文（完整）
  final String? rawContext;

  _UnifiedLogEntry({
    required this.time,
    required this.title,
    this.extraContent,
    required this.fullContent,
    this.level,
    this.isApiLog = false,
    this.isConversation = false,
    this.rawAiResponse,
    this.rawContext,
  });

  /// 是否需要折叠（有额外内容才需要）
  bool get needsFold => extraContent != null && extraContent!.isNotEmpty;
}

class _ConversationRoundLog {
  final int roundIndex;
  final ApiLogEntry? requestLog;
  final ApiLogEntry? toolLog;

  const _ConversationRoundLog({
    required this.roundIndex,
    this.requestLog,
    this.toolLog,
  });
}

class _ConversationTurnLog {
  final String turnKey;
  final String? sessionId;
  final String? turnId;
  final DateTime startedAt;
  final List<_ConversationRoundLog> rounds;
  final ApiLogEntry? finalLog;

  const _ConversationTurnLog({
    required this.turnKey,
    required this.sessionId,
    required this.turnId,
    required this.startedAt,
    required this.rounds,
    this.finalLog,
  });
}

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

/// 日志类型筛选选项
enum LogTypeFilter {
  all('全部'),
  conversation('对话'),
  api('API'),
  system('系统');

  const LogTypeFilter(this.label);
  final String label;
}

/// 日志级别筛选选项
enum LogLevelFilter {
  all('全部', null),
  info('INFO+', LogLevel.info),
  warning('WARNING+', LogLevel.warning),
  error('ERROR+', LogLevel.error);

  const LogLevelFilter(this.label, this.minLevel);
  final String label;
  final LogLevel? minLevel; // null 表示显示全部
}

class _LogViewerPageState extends State<LogViewerPage> {
  static const String _hideBeforeTimeKey = 'log_viewer_hide_before_time';
  static const String _logLevelFilterKey = 'log_viewer_level_filter';
  static const String _logTypeFilterKey = 'log_viewer_type_filter';

  final ScrollController _scrollController = ScrollController();
  final Set<int> _expandedIndices = {};
  final Set<int> _selectedIndices = {};
  bool _isSelectionMode = false;
  DateTime? _hideBeforeTime; // 隐藏此时间之前的日志（用于"新建日志"功能）
  int _lastLogCount = 0; // 记录上次日志数量，用于判断是否需要滚动到底部
  LogLevelFilter _levelFilter = LogLevelFilter.all; // 日志级别筛选
  LogTypeFilter _typeFilter = LogTypeFilter.all; // 日志类型筛选

  @override
  void initState() {
    super.initState();
    _loadHideBeforeTime();
    _loadLevelFilter();
    _loadTypeFilter();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  /// 从持久化存储加载 hideBeforeTime
  Future<void> _loadHideBeforeTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_hideBeforeTimeKey);
    if (timestamp != null) {
      setState(() {
        _hideBeforeTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      });
    }
  }

  /// 保存 hideBeforeTime 到持久化存储
  Future<void> _saveHideBeforeTime(DateTime? time) async {
    final prefs = await SharedPreferences.getInstance();
    if (time != null) {
      await prefs.setInt(_hideBeforeTimeKey, time.millisecondsSinceEpoch);
    } else {
      await prefs.remove(_hideBeforeTimeKey);
    }
  }

  /// 从持久化存储加载日志级别筛选
  Future<void> _loadLevelFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_logLevelFilterKey) ?? 0;
    if (index >= 0 && index < LogLevelFilter.values.length) {
      setState(() {
        _levelFilter = LogLevelFilter.values[index];
      });
    }
  }

  /// 保存日志级别筛选到持久化存储
  Future<void> _saveLevelFilter(LogLevelFilter filter) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_logLevelFilterKey, filter.index);
  }

  /// 从持久化存储加载日志类型筛选
  Future<void> _loadTypeFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_logTypeFilterKey) ?? 0;
    if (index >= 0 && index < LogTypeFilter.values.length) {
      setState(() {
        _typeFilter = LogTypeFilter.values[index];
      });
    }
  }

  /// 保存日志类型筛选到持久化存储
  Future<void> _saveTypeFilter(LogTypeFilter filter) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_logTypeFilterKey, filter.index);
  }

  @override
  void dispose() {
    _scrollController.dispose();
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
        leading: _isSelectionMode
            ? IconButton(
                icon: Icon(Icons.close, color: colors.text),
                onPressed: _exitSelectionMode,
              )
            : IconButton(
                icon: Icon(Icons.arrow_back, color: colors.text),
                onPressed: () => Navigator.of(context).pop(),
              ),
        title: Text(
          _isSelectionMode ? '已选择 ${_selectedIndices.length} 条' : '日志中心',
          style: TextStyle(
            color: colors.text,
            fontSize: 18,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        actions: _isSelectionMode
            ? [
                IconButton(
                  tooltip: '全选',
                  icon: Icon(Icons.select_all, color: colors.text),
                  onPressed: _selectAll,
                ),
                IconButton(
                  tooltip: '复制选中',
                  icon: Icon(Icons.copy, color: colors.primary),
                  onPressed: _copySelected,
                ),
              ]
            : [
                IconButton(
                  tooltip: '新建日志',
                  icon: Icon(Icons.add_circle_outline, color: colors.text),
                  onPressed: _startNewSession,
                ),
                IconButton(
                  tooltip: '历史日志',
                  icon: Icon(Icons.history, color: colors.text),
                  onPressed: _showHistoryLogs,
                ),
                IconButton(
                  tooltip: '导出全部',
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

    return Column(
      children: [
        // 日志级别筛选栏
        _buildFilterBar(),
        // 日志列表
        Expanded(
          child: ValueListenableBuilder<List<ApiLogEntry>>(
            valueListenable: ApiLogger.entries,
            builder: (context, apiLogs, _) {
              return ValueListenableBuilder<List<LogEntry>>(
                valueListenable: AppLogger.entries,
                builder: (context, systemLogs, __) {
                  if (_typeFilter == LogTypeFilter.conversation) {
                    final turns = _buildConversationTurns(apiLogs);

                    if (turns.length > _lastLogCount) {
                      _lastLogCount = turns.length;
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _scrollToBottom());
                    } else if (turns.length < _lastLogCount) {
                      _lastLogCount = turns.length;
                    }

                    if (turns.isEmpty) {
                      return Center(
                        child: Text(
                          '暂无对话日志',
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      );
                    }

                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: turns.length,
                      itemBuilder: (context, index) =>
                          _buildConversationTurnItem(turns[index], index),
                    );
                  }

                  final entries = _buildUnifiedEntries(apiLogs, systemLogs);

                  // 只有当日志数量增加时才滚动到底部（新日志到来）
                  if (entries.length > _lastLogCount) {
                    _lastLogCount = entries.length;
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _scrollToBottom());
                  } else if (entries.length < _lastLogCount) {
                    // 日志被清空或减少时，更新计数但不滚动
                    _lastLogCount = entries.length;
                  }

                  if (entries.isEmpty) {
                    return Center(
                      child: Text(
                        '暂无日志',
                        style: TextStyle(color: colors.textSecondary),
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      return _buildLogItem(
                          entries[index], index, entries.length);
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// 构建日志筛选栏
  Widget _buildFilterBar() {
    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          bottom: BorderSide(color: colors.borderLight, width: 0.5),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 类型筛选（对话/API/系统）
            ...LogTypeFilter.values.map((filter) {
              final isSelected = _typeFilter == filter;
              // 对话标签使用特殊颜色
              final chipColor = filter == LogTypeFilter.conversation
                  ? Colors.deepPurple
                  : colors.primary;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _typeFilter = filter;
                      _expandedIndices.clear();
                      _selectedIndices.clear();
                      _isSelectionMode = false;
                    });
                    _saveTypeFilter(filter);
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color:
                          isSelected ? chipColor : colors.componentBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? chipColor : colors.borderLight,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      filter.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected ? Colors.white : colors.textSecondary,
                        fontWeight: isSelected
                            ? MoeFontWeights.emphasis
                            : MoeFontWeights.normal,
                      ),
                    ),
                  ),
                ),
              );
            }),
            // 分隔符
            Container(
              width: 1,
              height: 20,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: colors.borderLight,
            ),
            // 级别筛选（仅对系统日志有效）
            ...LogLevelFilter.values.map((filter) {
              final isSelected = _levelFilter == filter;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _levelFilter = filter;
                      _expandedIndices.clear();
                      _selectedIndices.clear();
                      _isSelectionMode = false;
                    });
                    _saveLevelFilter(filter);
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? colors.primary
                          : colors.componentBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? colors.primary : colors.borderLight,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      filter.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected ? Colors.white : colors.textSecondary,
                        fontWeight: isSelected
                            ? MoeFontWeights.emphasis
                            : MoeFontWeights.normal,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// 合并并按时间排序所有日志
  List<_ConversationTurnLog> _buildConversationTurns(
      List<ApiLogEntry> apiLogs) {
    final hideTime = _hideBeforeTime;
    final logs = apiLogs
        .where((log) => log.isConversation)
        .where((log) => hideTime == null || !log.time.isBefore(hideTime))
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

    final turns = <_ConversationTurnLog>[];
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
      final rounds = <_ConversationRoundLog>[
        for (final roundIndex in roundIndexes)
          _ConversationRoundLog(
            roundIndex: roundIndex,
            requestLog: roundRequestLogs[roundIndex],
            toolLog: roundToolLogs[roundIndex],
          )
      ];

      turns.add(_ConversationTurnLog(
        turnKey: entry.key,
        sessionId: _firstNonEmpty(turnLogs.map((e) => e.sessionId)),
        turnId: _firstNonEmpty(turnLogs.map((e) => e.turnId)),
        startedAt: turnLogs.first.time,
        rounds: rounds,
        finalLog: finalLog,
      ));
    }

    turns.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return turns;
  }

  String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }

  Widget _buildConversationTurnItem(_ConversationTurnLog turn, int index) {
    final colors = context.moeColors;
    final meta = <String>[
      _formatTime(turn.startedAt),
      if (turn.turnId != null) 'turn=${turn.turnId}',
      if (turn.sessionId != null) 'session=${turn.sessionId}',
      if (turn.turnId == null) turn.turnKey,
    ].join(' | ');
    final finalReply = _resolveFinalReply(turn);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: MoeG2Decoration(
        radius: 10,
        color: colors.componentBackground,
        border: Border.all(
          color: Colors.deepPurple.withValues(alpha: 0.35),
          width: borderWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Turn ${index + 1} (${turn.rounds.length} rounds)',
            style: const TextStyle(
              color: Colors.deepPurple,
              fontSize: 12,
              fontWeight: MoeFontWeights.emphasis,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            meta,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 10),
          ...[
            for (var i = 0; i < turn.rounds.length; i++) ...[
              _buildConversationRoundItem(turn.rounds[i]),
              if (i != turn.rounds.length - 1) const SizedBox(height: 8),
            ],
          ],
          if (finalReply.isNotEmpty) ...[
            const SizedBox(height: 10),
            _buildConversationSection(
              title: 'Final reply delivered to user',
              content: finalReply,
              titleColor: Colors.green,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildConversationRoundItem(_ConversationRoundLog round) {
    final colors = context.moeColors;
    final requestLog = round.requestLog;
    final toolLog = round.toolLog;
    final contextText = _prettyJson(requestLog?.rawContext) ?? '(empty)';
    final toolCallsText =
        _prettyJson(toolLog?.rawToolCalls ?? requestLog?.rawToolCalls) ??
            '(none)';
    final toolResultsText = _prettyJson(toolLog?.rawToolResults) ?? '(none)';
    final aiReply = requestLog?.rawAiResponse?.trim().isNotEmpty == true
        ? requestLog!.rawAiResponse!
        : '(empty)';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: MoeG2Decoration(
        radius: 8,
        color: colors.surface.withValues(alpha: 0.6),
        border: Border.all(
          color: Colors.deepPurple.withValues(alpha: 0.25),
          width: borderWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Round ${round.roundIndex}',
                style: const TextStyle(
                  color: Colors.deepPurple,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
              const Spacer(),
              Text(
                _formatTime((requestLog ?? toolLog)?.time ?? DateTime.now()),
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildConversationSection(
            title: 'Full context received by AI',
            content: contextText,
          ),
          const SizedBox(height: 6),
          _buildConversationSection(
            title: 'AI -> Tool Calls',
            content: toolCallsText,
          ),
          const SizedBox(height: 6),
          _buildConversationSection(
            title: 'Tool -> AI Results',
            content: toolResultsText,
          ),
          const SizedBox(height: 6),
          _buildConversationSection(
            title: 'Raw AI response',
            content: aiReply,
          ),
        ],
      ),
    );
  }

  Widget _buildConversationSection({
    required String title,
    required String content,
    Color? titleColor,
  }) {
    final colors = context.moeColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: titleColor ?? colors.textSecondary,
            fontSize: 10,
            fontFamily: 'monospace',
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(height: 3),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: colors.borderLight, width: borderWidth),
          ),
          child: SelectableText(
            content,
            style: TextStyle(
              color: colors.text,
              fontSize: 10,
              height: 1.35,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }

  String _resolveFinalReply(_ConversationTurnLog turn) {
    final finalReply = turn.finalLog?.finalReply?.trim();
    if (finalReply != null && finalReply.isNotEmpty) {
      return finalReply;
    }

    final finalRawReply = turn.finalLog?.rawAiResponse?.trim();
    if (finalRawReply != null && finalRawReply.isNotEmpty) {
      return finalRawReply;
    }

    for (var i = turn.rounds.length - 1; i >= 0; i--) {
      final text = turn.rounds[i].requestLog?.rawAiResponse?.trim();
      if (text != null && text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  String? _prettyJson(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }

  List<_UnifiedLogEntry> _buildUnifiedEntries(
    List<ApiLogEntry> apiLogs,
    List<LogEntry> systemLogs,
  ) {
    final entries = <_UnifiedLogEntry>[];
    final hideTime = _hideBeforeTime;
    final minLevel = _levelFilter.minLevel;
    final typeFilter = _typeFilter;

    // 转换 API 日志
    for (final log in apiLogs) {
      // 过滤掉隐藏时间之前的日志
      if (hideTime != null && log.time.isBefore(hideTime)) continue;

      final isConversation = log.isConversation;

      // 类型筛选
      if (typeFilter == LogTypeFilter.conversation && !isConversation) continue;
      if (typeFilter == LogTypeFilter.api && isConversation) continue;
      if (typeFilter == LogTypeFilter.system) continue; // 系统筛选不显示 API 日志

      // 对话日志使用特殊标题格式
      final title = isConversation
          ? '[对话] ${log.status ?? '--'} ${_shortenUrl(log.url)}'
          : '[API] ${log.method} ${log.status ?? '--'} ${_shortenUrl(log.url)}';

      // 对话日志显示原始对话内容，普通 API 日志显示请求/响应摘要
      final extra = isConversation
          ? _formatConversationExtra(log)
          : _formatApiLogExtra(log);

      entries.add(_UnifiedLogEntry(
        time: log.time,
        title: title,
        extraContent: extra,
        fullContent: _formatApiLogFull(log),
        isApiLog: true,
        isConversation: isConversation,
        rawAiResponse: log.rawAiResponse,
        rawContext: log.rawContext,
      ));
    }

    // 转换系统日志（仅在非对话/非API筛选时显示）
    if (typeFilter == LogTypeFilter.all || typeFilter == LogTypeFilter.system) {
      for (final log in systemLogs) {
        // 过滤掉隐藏时间之前的日志
        if (hideTime != null && log.time.isBefore(hideTime)) continue;

        // 根据级别筛选过滤日志
        if (minLevel != null && log.level.value < minLevel.value) continue;

        final title = '[${log.level.label}] [${log.source}] ${log.message}';
        final extra = _formatMetadata(log.metadata);
        entries.add(_UnifiedLogEntry(
          time: log.time,
          title: title,
          extraContent: extra,
          fullContent: _formatSystemLogFull(log),
          level: log.level,
        ));
      }
    }

    // 按时间排序
    entries.sort((a, b) => a.time.compareTo(b.time));

    return entries;
  }

  /// 格式化对话日志的额外内容（显示原始对话）
  String? _formatConversationExtra(ApiLogEntry log) {
    final parts = <String>[];

    // 显示 AI 回复
    if (log.rawAiResponse != null && log.rawAiResponse!.isNotEmpty) {
      final preview = log.rawAiResponse!.length > 200
          ? '${log.rawAiResponse!.substring(0, 200)}...'
          : log.rawAiResponse!;
      parts.add('AI回复: $preview');
    }

    // 显示上下文消息数量
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

  String _shortenUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    // 只显示 path，去掉 query
    final path = uri.path;
    if (path.length > 30) {
      return '...${path.substring(path.length - 27)}';
    }
    return path;
  }

  /// API 日志的额外内容（请求体、响应体摘要）
  String? _formatApiLogExtra(ApiLogEntry log) {
    final parts = <String>[];

    if (log.requestBody.isNotEmpty) {
      final preview = _jsonPreview(log.requestBody, 100);
      parts.add('请求: $preview');
    }

    if (log.responseBody.isNotEmpty) {
      final preview = _jsonPreview(log.responseBody, 100);
      parts.add('响应: $preview');
    }

    return parts.isEmpty ? null : parts.join('\n');
  }

  /// JSON 预览（截取前 N 个字符）
  String _jsonPreview(String text, int maxLen) {
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

  /// 格式化 metadata（只显示额外内容，不重复标题）
  String? _formatMetadata(Map<String, dynamic>? metadata) {
    if (metadata == null || metadata.isEmpty) return null;
    try {
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(metadata);
    } catch (_) {
      return metadata.toString();
    }
  }

  String _formatApiLogFull(ApiLogEntry log) {
    final buffer = StringBuffer();
    final time = _formatTime(log.time);

    // 对话日志使用特殊格式
    if (log.isConversation) {
      buffer.writeln('[$time] [对话] ${log.url}');
      buffer.writeln(
          '状态: ${log.status ?? '--'} | 耗时: ${log.durationMs}ms | 结果: ${log.ok ? '成功' : '失败'}');

      // 显示完整的上下文消息
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
              // 多模态消息
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
          buffer.writeln(log.rawContext);
        }
      }

      // 显示完整的 AI 回复
      if (log.rawAiResponse != null && log.rawAiResponse!.isNotEmpty) {
        buffer.writeln('\n========== AI原始回复 ==========');
        buffer.writeln(log.rawAiResponse);
      }

      return buffer.toString().trim();
    }

    // 普通 API 日志保持原有格式
    buffer.writeln('[$time] [API] ${log.method} ${log.url}');
    buffer.writeln(
        '状态: ${log.status ?? '--'} | 耗时: ${log.durationMs}ms | 结果: ${log.ok ? '成功' : '失败'}');

    if (log.requestBody.isNotEmpty) {
      buffer.writeln('--- 请求体 ---');
      buffer.writeln(_truncateSystemPromptsInJson(log.requestBody));
    }

    if (log.responseBody.isNotEmpty) {
      buffer.writeln('--- 响应体 ---');
      buffer.writeln(_tryFormatJson(log.responseBody));
    }

    return buffer.toString().trim();
  }

  /// 截断 JSON 中的系统提示词（用于复制时）
  String _truncateSystemPromptsInJson(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        // 处理 messages 数组
        final messages = decoded['messages'];
        if (messages is List) {
          for (final msg in messages) {
            if (msg is Map<String, dynamic> && msg['role'] == 'system') {
              final content = msg['content'];
              if (content is String && content.length > 100) {
                msg['content'] = truncateLongText(content, maxLength: 100);
              }
            }
          }
        }
        // 处理 history 数组
        final history = decoded['history'];
        if (history is List) {
          for (final msg in history) {
            if (msg is Map<String, dynamic> && msg['role'] == 'system') {
              final content = msg['content'];
              if (content is String && content.length > 100) {
                msg['content'] = truncateLongText(content, maxLength: 100);
              }
            }
          }
        }
        return const JsonEncoder.withIndent('  ').convert(decoded);
      }
    } catch (_) {
      // 解析失败则尝试普通格式化
    }
    return _tryFormatJson(jsonStr);
  }

  String _formatSystemLogFull(LogEntry log) {
    final buffer = StringBuffer();
    buffer.write(
        '[${log.formattedTime}] [${log.level.label}] [${log.source}] ${log.message}');

    if (log.metadata != null && log.metadata!.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('--- metadata ---');
      try {
        const encoder = JsonEncoder.withIndent('  ');
        buffer.write(encoder.convert(log.metadata));
      } catch (_) {
        buffer.write(log.metadata.toString());
      }
    }

    return buffer.toString();
  }

  String _tryFormatJson(String text) {
    try {
      final decoded = jsonDecode(text);
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(decoded);
    } catch (_) {
      return text;
    }
  }

  Widget _buildLogItem(_UnifiedLogEntry entry, int index, int total) {
    final colors = context.moeColors;
    final isExpanded = _expandedIndices.contains(index);
    final isSelected = _selectedIndices.contains(index);
    final needsFold = entry.needsFold;

    // 根据日志类型和级别设置颜色
    Color levelColor = colors.textSecondary;
    if (entry.isConversation) {
      // 对话日志使用紫色
      levelColor = Colors.deepPurple;
    } else if (entry.level != null) {
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
    } else if (entry.isApiLog) {
      levelColor = Colors.teal;
    }

    return GestureDetector(
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(index);
        } else if (needsFold) {
          setState(() {
            if (isExpanded) {
              _expandedIndices.remove(index);
            } else {
              _expandedIndices.add(index);
            }
          });
        }
      },
      onLongPress: () {
        if (!_isSelectionMode) {
          setState(() {
            _isSelectionMode = true;
            _selectedIndices.add(index);
          });
          HapticFeedback.mediumImpact();
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: MoeG2Decoration(
          radius: 8,
          color: isSelected
              ? colors.primary.withValues(alpha: 0.15)
              : colors.componentBackground,
          border: Border.all(
            color: isSelected ? colors.primary : colors.borderLight,
            width: borderWidth,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行（始终显示）
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 选择模式下的勾选框
                if (_isSelectionMode) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      color: isSelected ? colors.primary : colors.textSecondary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // 时间
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _formatTime(entry.time),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: colors.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // 标题（允许多行显示）
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
                // 折叠指示器（只有需要折叠的才显示）
                if (needsFold && !_isSelectionMode)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: colors.muted,
                      size: 16,
                    ),
                  ),
              ],
            ),
            // 额外内容区（折叠/展开）
            if (needsFold) ...[
              const SizedBox(height: 4),
              if (isExpanded)
                // 展开时显示完整 extraContent
                SelectableText(
                  entry.extraContent!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    height: 1.4,
                    color: colors.text,
                  ),
                )
              else
                // 折叠时显示预览（最多 2 行）
                Text(
                  entry.extraContent!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    height: 1.3,
                    color: colors.textSecondary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }

  void _toggleSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
        if (_selectedIndices.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _selectAll() {
    final entries = _buildUnifiedEntries(
      ApiLogger.entries.value,
      AppLogger.entries.value,
    );
    setState(() {
      if (_selectedIndices.length == entries.length) {
        // 如果已全选，则取消全选
        _selectedIndices.clear();
      } else {
        // 全选
        _selectedIndices.clear();
        for (var i = 0; i < entries.length; i++) {
          _selectedIndices.add(i);
        }
      }
    });
  }

  Future<void> _copySelected() async {
    if (_selectedIndices.isEmpty) {
      MoeToast.info(context, '请先选择日志条目');
      return;
    }

    final entries = _buildUnifiedEntries(
      ApiLogger.entries.value,
      AppLogger.entries.value,
    );

    final sortedIndices = _selectedIndices.toList()..sort();
    final buffer = StringBuffer();

    for (final index in sortedIndices) {
      if (index < entries.length) {
        buffer.writeln(entries[index].fullContent);
        buffer.writeln('---');
      }
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    if (mounted) {
      MoeToast.success(context, '已复制 ${_selectedIndices.length} 条日志');
      _exitSelectionMode();
    }
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedIndices.clear();
    });
  }

  Future<void> _exportLogs() async {
    final entries = _buildUnifiedEntries(
      ApiLogger.entries.value,
      AppLogger.entries.value,
    );

    if (entries.isEmpty) {
      MoeToast.info(context, '暂无日志可导出');
      return;
    }

    final buffer = StringBuffer();
    for (final entry in entries) {
      buffer.writeln(entry.fullContent);
      buffer.writeln('---');
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    if (mounted) {
      MoeToast.success(context, '已复制 ${entries.length} 条日志到剪贴板');
    }
  }

  void _confirmClearLogs() async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '清空日志',
      message: '确认要清空所有日志吗？',
      cancelText: '取消',
      confirmText: '清空',
      isDanger: true,
    );
    if (confirmed == true) {
      _clearLogs();
    }
  }

  void _clearLogs() {
    ApiLogger.clear();
    AppLogger.clear();
    _expandedIndices.clear();
    _selectedIndices.clear();
    _isSelectionMode = false;
    _hideBeforeTime = null;
    _saveHideBeforeTime(null); // 清除持久化的时间戳
    setState(() {});
    MoeToast.success(context, '日志已清空');
  }

  void _startNewSession() {
    final now = DateTime.now();
    setState(() {
      _hideBeforeTime = now;
      _expandedIndices.clear();
      _selectedIndices.clear();
    });
    _saveHideBeforeTime(now);
    MoeToast.brief(context, '已开始新的日志会话');
  }

  void _showHistoryLogs() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LogHistoryListPage()),
    );
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }
}

/// 历史日志列表页面
class LogHistoryListPage extends StatefulWidget {
  const LogHistoryListPage({super.key});

  @override
  State<LogHistoryListPage> createState() => _LogHistoryListPageState();
}

class _LogHistoryListPageState extends State<LogHistoryListPage> {
  List<LogHistoryFile> _files = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() => _isLoading = true);
    try {
      final files = await LogHistoryService.getHistoryFiles();
      if (mounted) {
        setState(() {
          _files = files;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        MoeToast.error(context, '加载历史日志失败');
      }
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
          '历史日志',
          style: TextStyle(
            color: colors.text,
            fontSize: 18,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        actions: [
          if (_files.isNotEmpty)
            IconButton(
              tooltip: '清空全部',
              icon: Icon(Icons.delete_sweep, color: colors.text),
              onPressed: _confirmClearAll,
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

    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 48, color: colors.muted),
            const SizedBox(height: 12),
            Text('暂无历史日志', style: TextStyle(color: colors.textSecondary)),
            const SizedBox(height: 8),
            Text(
              '日志会实时自动保存',
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _files.length,
      itemBuilder: (context, index) => _buildFileItem(_files[index]),
    );
  }

  Widget _buildFileItem(LogHistoryFile file) {
    final colors = context.moeColors;

    // 根据类型设置图标和颜色
    IconData typeIcon;
    Color typeColor;
    switch (file.type) {
      case 'app':
        typeIcon = Icons.article_outlined;
        typeColor = Colors.blue;
        break;
      case 'api':
        typeIcon = Icons.api_outlined;
        typeColor = Colors.teal;
        break;
      case 'legacy':
        typeIcon = Icons.history_outlined;
        typeColor = Colors.orange;
        break;
      default:
        typeIcon = Icons.description_outlined;
        typeColor = colors.primary;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: MoeG2Decoration(
        radius: 8,
        color: colors.componentBackground,
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      child: ListTile(
        leading: Icon(typeIcon, color: typeColor),
        title: Text(
          file.formattedTime,
          style: TextStyle(color: colors.text, fontSize: 14),
        ),
        subtitle: Text(
          '${file.typeLabel} · ${file.formattedSize}',
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon:
                  Icon(Icons.visibility_outlined, color: colors.text, size: 20),
              onPressed: () => _viewFile(file),
              tooltip: '查看',
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: colors.muted, size: 20),
              onPressed: () => _deleteFile(file),
              tooltip: '删除',
            ),
          ],
        ),
        onTap: () => _viewFile(file),
      ),
    );
  }

  void _viewFile(LogHistoryFile file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LogHistoryDetailPage(file: file),
      ),
    );
  }

  Future<void> _deleteFile(LogHistoryFile file) async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '删除日志',
      message: '确认删除 ${file.formattedTime} 的日志吗？',
      cancelText: '取消',
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed == true) {
      await LogHistoryService.deleteHistoryFile(file.filePath);
      _loadFiles();
      if (mounted) {
        MoeToast.success(context, '已删除');
      }
    }
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '清空历史日志',
      message: '确认清空所有历史日志吗？此操作不可恢复。',
      cancelText: '取消',
      confirmText: '清空',
      isDanger: true,
    );
    if (confirmed == true) {
      final count = await LogHistoryService.clearAllHistory();
      _loadFiles();
      if (mounted) {
        MoeToast.success(context, '已清空 $count 个日志文件');
      }
    }
  }
}

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
  final Set<int> _expandedIndices = {};

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

  List<_UnifiedLogEntry> _buildEntries() {
    if (_data == null) return [];

    final entries = <_UnifiedLogEntry>[];

    // 解析 API 日志
    final apiLogs = _data!['apiLogs'] as List? ?? [];
    for (final log in apiLogs) {
      if (log is! Map<String, dynamic>) continue;
      final time =
          DateTime.tryParse((log['time'] ?? '').toString()) ?? DateTime.now();
      final title =
          '[API] ${log['method'] ?? '--'} ${log['status'] ?? '--'} ${_shortenUrl((log['url'] ?? '').toString())}';
      entries.add(_UnifiedLogEntry(
        time: time,
        title: title,
        extraContent: _formatApiExtra(log),
        fullContent: _formatApiFull(log),
        isApiLog: true,
      ));
    }

    // 解析系统日志
    final appLogs = _data!['appLogs'] as List? ?? [];
    for (final log in appLogs) {
      if (log is! Map<String, dynamic>) continue;
      final time =
          DateTime.tryParse((log['time'] ?? '').toString()) ?? DateTime.now();
      final level = _parseLogLevel(log['level']);
      final title =
          '[${level.label}] [${log['source'] ?? '--'}] ${log['message'] ?? ''}';
      entries.add(_UnifiedLogEntry(
        time: time,
        title: title,
        extraContent: _formatMetadata(log['metadata']),
        fullContent: _formatSystemFull(log, level),
        level: level,
      ));
    }

    entries.sort((a, b) => a.time.compareTo(b.time));
    return entries;
  }

  LogLevel _parseLogLevel(dynamic rawLevel) {
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

  String _shortenUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final path = uri.path;
    if (path.length > 30) return '...${path.substring(path.length - 27)}';
    return path;
  }

  String? _formatApiExtra(Map<String, dynamic> log) {
    final parts = <String>[];
    final req = (log['requestBody'] ?? '').toString();
    final res = (log['responseBody'] ?? '').toString();
    if (req.isNotEmpty) parts.add('请求: ${_preview(req, 100)}');
    if (res.isNotEmpty) parts.add('响应: ${_preview(res, 100)}');
    return parts.isEmpty ? null : parts.join('\n');
  }

  String _preview(String text, int max) {
    if (text.length <= max) return text;
    return '${text.substring(0, max)}...';
  }

  String _formatApiFull(Map<String, dynamic> log) {
    final buffer = StringBuffer();
    buffer.writeln('[API] ${log['method']} ${log['url']}');
    buffer.writeln('状态: ${log['status'] ?? '--'} | 耗时: ${log['durationMs']}ms');
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

  /// 截断 JSON 中的系统提示词（历史日志用）
  String _truncateSystemPromptsInJsonForHistory(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        // 处理 messages 数组
        final messages = decoded['messages'];
        if (messages is List) {
          for (final msg in messages) {
            if (msg is Map<String, dynamic> && msg['role'] == 'system') {
              final content = msg['content'];
              if (content is String && content.length > 100) {
                msg['content'] = truncateLongText(content, maxLength: 100);
              }
            }
          }
        }
        // 处理 history 数组
        final history = decoded['history'];
        if (history is List) {
          for (final msg in history) {
            if (msg is Map<String, dynamic> && msg['role'] == 'system') {
              final content = msg['content'];
              if (content is String && content.length > 100) {
                msg['content'] = truncateLongText(content, maxLength: 100);
              }
            }
          }
        }
        return const JsonEncoder.withIndent('  ').convert(decoded);
      }
    } catch (_) {
      // 解析失败则返回原文
    }
    return jsonStr;
  }

  String? _formatMetadata(dynamic metadata) {
    if (metadata == null) return null;
    if (metadata is Map && metadata.isEmpty) return null;
    try {
      return const JsonEncoder.withIndent('  ').convert(metadata);
    } catch (_) {
      return metadata.toString();
    }
  }

  String _formatSystemFull(Map<String, dynamic> log, LogLevel level) {
    final buffer = StringBuffer();
    buffer.write('[${level.label}] [${log['source']}] ${log['message']}');
    final metadata = log['metadata'];
    if (metadata != null && metadata is Map && metadata.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('--- metadata ---');
      try {
        buffer.write(const JsonEncoder.withIndent('  ').convert(metadata));
      } catch (_) {
        buffer.write(metadata.toString());
      }
    }
    return buffer.toString();
  }

  Widget _buildLogItem(_UnifiedLogEntry entry, int index) {
    final colors = context.moeColors;
    final isExpanded = _expandedIndices.contains(index);
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

    return GestureDetector(
      onTap: needsFold
          ? () => setState(() {
                if (isExpanded) {
                  _expandedIndices.remove(index);
                } else {
                  _expandedIndices.add(index);
                }
              })
          : null,
      child: Container(
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
                    _formatTime(entry.time),
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
                if (needsFold)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: colors.muted,
                      size: 16,
                    ),
                  ),
              ],
            ),
            if (needsFold) ...[
              const SizedBox(height: 4),
              if (isExpanded)
                SelectableText(
                  entry.extraContent!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    height: 1.4,
                    color: colors.text,
                  ),
                )
              else
                Text(
                  entry.extraContent!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    height: 1.3,
                    color: colors.textSecondary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
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
