import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/api_logger.dart' show ApiLogEntry, ApiLogger;
import '../../../../core/app_logger.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import 'collapsible_selectable_text.dart';
import 'log_formatters.dart';
import 'log_history_list_page.dart';
import 'log_models.dart';

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  static const String _hideBeforeTimeKey = 'log_viewer_hide_before_time';
  static const String _logLevelFilterKey = 'log_viewer_level_filter';
  static const String _logTypeFilterKey = 'log_viewer_type_filter';

  final ScrollController _scrollController = ScrollController();
  final Set<int> _expandedIndices = {};
  final Set<int> _selectedIndices = {};
  bool _isSelectionMode = false;
  DateTime? _hideBeforeTime;
  int _lastLogCount = 0;
  LogLevelFilter _levelFilter = LogLevelFilter.all;
  LogTypeFilter _typeFilter = LogTypeFilter.all;
  bool _showRawStreamEvents = false;

  @override
  void initState() {
    super.initState();
    _loadHideBeforeTime();
    _loadLevelFilter();
    _loadTypeFilter();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _loadHideBeforeTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_hideBeforeTimeKey);
    if (timestamp != null) {
      setState(() {
        _hideBeforeTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      });
    }
  }

  Future<void> _saveHideBeforeTime(DateTime? time) async {
    final prefs = await SharedPreferences.getInstance();
    if (time != null) {
      await prefs.setInt(_hideBeforeTimeKey, time.millisecondsSinceEpoch);
    } else {
      await prefs.remove(_hideBeforeTimeKey);
    }
  }

  Future<void> _loadLevelFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_logLevelFilterKey) ?? 0;
    if (index >= 0 && index < LogLevelFilter.values.length) {
      setState(() => _levelFilter = LogLevelFilter.values[index]);
    }
  }

  Future<void> _saveLevelFilter(LogLevelFilter filter) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_logLevelFilterKey, filter.index);
  }

  Future<void> _loadTypeFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_logTypeFilterKey) ?? 0;
    if (index >= 0 && index < LogTypeFilter.values.length) {
      setState(() => _typeFilter = LogTypeFilter.values[index]);
    }
  }

  Future<void> _saveTypeFilter(LogTypeFilter filter) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_logTypeFilterKey, filter.index);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────
  //  build
  // ─────────────────────────────────────────

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
    return Column(
      children: [
        _buildFilterBar(),
        Expanded(
          child: ValueListenableBuilder<List<ApiLogEntry>>(
            valueListenable: ApiLogger.entries,
            builder: (context, apiLogs, _) {
              return ValueListenableBuilder<List<LogEntry>>(
                valueListenable: AppLogger.entries,
                builder: (context, systemLogs, __) {
                  if (_typeFilter == LogTypeFilter.conversation) {
                    return _buildConversationList(apiLogs);
                  }
                  return _buildUnifiedList(apiLogs, systemLogs);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildConversationList(List<ApiLogEntry> apiLogs) {
    final colors = context.moeColors;
    final turns = buildConversationTurns(
      apiLogs,
      hideBeforeTime: _hideBeforeTime,
    );

    if (turns.length > _lastLogCount) {
      _lastLogCount = turns.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else if (turns.length < _lastLogCount) {
      _lastLogCount = turns.length;
    }

    if (turns.isEmpty) {
      return Center(
        child: Text('暂无对话日志', style: TextStyle(color: colors.textSecondary)),
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

  Widget _buildUnifiedList(
      List<ApiLogEntry> apiLogs, List<LogEntry> systemLogs) {
    final colors = context.moeColors;
    final entries = buildUnifiedEntries(
      apiLogs,
      systemLogs,
      hideBeforeTime: _hideBeforeTime,
      levelFilter: _levelFilter,
      typeFilter: _typeFilter,
    );

    if (entries.length > _lastLogCount) {
      _lastLogCount = entries.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else if (entries.length < _lastLogCount) {
      _lastLogCount = entries.length;
    }

    if (entries.isEmpty) {
      return Center(
        child: Text('暂无日志', style: TextStyle(color: colors.textSecondary)),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: entries.length,
      itemBuilder: (context, index) =>
          _buildLogItem(entries[index], index, entries.length),
    );
  }

  // ─────────────────────────────────────────
  //  筛选栏
  // ─────────────────────────────────────────

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
            ...LogTypeFilter.values.map((filter) {
              final isSelected = _typeFilter == filter;
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
            Container(
              width: 1,
              height: 20,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: colors.borderLight,
            ),
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
            if (_typeFilter == LogTypeFilter.conversation) ...[
              Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: colors.borderLight,
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _showRawStreamEvents = !_showRawStreamEvents;
                    });
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _showRawStreamEvents
                          ? Colors.deepPurple
                          : colors.componentBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _showRawStreamEvents
                            ? Colors.deepPurple
                            : colors.borderLight,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      _showRawStreamEvents ? '原始流事件: 开' : '原始流事件: 关',
                      style: TextStyle(
                        fontSize: 12,
                        color: _showRawStreamEvents
                            ? Colors.white
                            : colors.textSecondary,
                        fontWeight: _showRawStreamEvents
                            ? MoeFontWeights.emphasis
                            : MoeFontWeights.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────
  //  对话 Turn 条目
  // ─────────────────────────────────────────

  Widget _buildConversationTurnItem(ConversationTurnLog turn, int index) {
    final colors = context.moeColors;
    final meta = <String>[
      '开始: ${formatTime(turn.startedAt)}',
      if (turn.turnId != null) 'turn=${turn.turnId}',
      if (turn.sessionId != null) 'session=${turn.sessionId}',
      if (turn.turnId == null) 'key=${turn.turnKey}',
    ].join(' | ');
    final finalReply = resolveFinalReply(turn);
    final finalDeliveryDurationMs = resolveFinalDeliveryDurationMs(turn);
    final finalReplyTitle = finalDeliveryDurationMs != null
        ? '最终展示给用户的回复（耗时：${formatDurationLabel(finalDeliveryDurationMs)}）'
        : '最终展示给用户的回复';

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
            '第${index + 1}轮会话（共${turn.rounds.length}轮）',
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
              title: finalReplyTitle,
              content: finalReply,
              titleColor: Colors.green,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildConversationRoundItem(ConversationRoundLog round) {
    final colors = context.moeColors;
    final requestLog = round.requestLog;
    final toolLog = round.toolLog;
    final rawContext = requestLog?.rawContext;
    final rawResponseBody = requestLog?.rawResponseBody;
    final rawToolCalls = toolLog?.rawToolCalls ?? requestLog?.rawToolCalls;
    final rawToolResults = toolLog?.rawToolResults;
    final streamPreview = parseStreamResponsePreview(rawResponseBody);
    final isStreamEnvelope = streamPreview != null;
    final toolTraceText = buildToolCallTraceText(
      rawToolCalls: rawToolCalls,
      rawToolResults: rawToolResults,
      rawResponseBody: rawResponseBody,
    );

    // prettyJson 内部会自动截断 base64 图片数据，不再卡死
    final contextText = prettyJson(rawContext) ?? '(空)';
    final rawResponseJson = prettyJson(rawResponseBody);
    final mergedStreamText = streamPreview?.hasMergedText == true
        ? streamPreview!.mergedText
        : '(空)';
    final streamPreviewTitle = streamPreview == null
        ? null
        : '流式回包（合并后文本，${streamPreview.eventCount}个事件'
            '${streamPreview.hasDoneMarker ? '，含[DONE]' : ''}'
            '${streamPreview.parseErrorCount > 0 ? '，${streamPreview.parseErrorCount}条解析失败' : ''}）';
    final toolCallsText = prettyJson(rawToolCalls) ?? '(无)';
    final toolResultsText = prettyJson(rawToolResults) ?? '(无)';
    final aiReply = requestLog?.rawAiResponse?.trim().isNotEmpty == true
        ? requestLog!.rawAiResponse!
        : '(空)';
    final hasNaturalReply = aiReply.trim().isNotEmpty && aiReply != '(空)';
    final toolCallCount = countJsonItems(rawToolCalls);
    final toolResultCount = countJsonItems(rawToolResults);
    final contextCount = countJsonItems(rawContext);
    final modelDurationMs = resolvePrimaryDurationMs(requestLog);
    final toolDurationMs =
        resolveToolDurationMs(requestLog: requestLog, toolLog: toolLog);

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
                '第${round.roundIndex}轮',
                style: const TextStyle(
                  color: Colors.deepPurple,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
              const Spacer(),
              Text(
                formatTime((requestLog ?? toolLog)?.time ?? DateTime.now()),
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildConversationFlowSummary(
            contextCount: contextCount,
            toolCallCount: toolCallCount,
            toolResultCount: toolResultCount,
            aiReplyText: aiReply,
            modelDurationMs: modelDurationMs,
            toolDurationMs: toolDurationMs,
          ),
          const SizedBox(height: 8),
          _buildConversationSection(
            title: '发送给 AI 的上下文（完整消息列表）',
            content: contextText,
          ),
          if (isStreamEnvelope && streamPreviewTitle != null) ...[
            const SizedBox(height: 6),
            _buildConversationSection(
              title: streamPreviewTitle,
              content: mergedStreamText,
            ),
          ],
          if (rawResponseJson != null && rawResponseJson.trim().isNotEmpty) ...[
            if (!isStreamEnvelope || _showRawStreamEvents) ...[
              const SizedBox(height: 6),
              _buildConversationSection(
                title:
                    isStreamEnvelope ? '流式回包原始事件（JSON）' : 'AI 原始 JSON 响应（模型回包）',
                content: rawResponseJson,
              ),
            ],
          ],
          if (toolTraceText != null && toolTraceText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _buildConversationSection(
              title: '工具调用轨迹（含失败信息）',
              content: toolTraceText,
            ),
          ],
          if (isStreamEnvelope &&
              !hasNaturalReply &&
              toolTraceText != null &&
              toolTraceText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _buildConversationSection(
              title: '本轮说明',
              content: '本轮无自然语言回复，主要用于工具调用。',
            ),
          ],
          if (toolCallCount > 0) ...[
            const SizedBox(height: 6),
            _buildConversationSection(
              title: 'AI 请求调用的工具',
              content: toolCallsText,
            ),
          ],
          if (toolResultCount > 0) ...[
            const SizedBox(height: 6),
            _buildConversationSection(
              title: '工具执行结果',
              content: toolResultsText,
            ),
          ],
          const SizedBox(height: 6),
          _buildConversationSection(
            title: 'AI 回复的原文',
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
    int collapsedLines = 10,
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
          child: CollapsibleSelectableText(
            key: ValueKey('$title:${content.hashCode}'),
            content: content,
            collapsedLines: collapsedLines,
            toggleColor: colors.primary,
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

  Widget _buildConversationFlowSummary({
    required int contextCount,
    required int toolCallCount,
    required int toolResultCount,
    required String aiReplyText,
    required int? modelDurationMs,
    required int? toolDurationMs,
  }) {
    final colors = context.moeColors;
    final hasToolCall = toolCallCount > 0;
    final hasAiReply = aiReplyText != '(空)' && aiReplyText.isNotEmpty;
    final modelTime = formatDurationLabel(modelDurationMs);

    // 构建流程描述：用人话讲清楚这一轮发生了什么
    final steps = <String>[];

    // 第一步：收到消息
    if (contextCount > 0) {
      steps.add('收到 $contextCount 条上下文消息');
    } else {
      steps.add('上下文为空（可能有问题）');
    }

    // 第二步：AI 思考并回复
    steps.add('AI 思考并回复，耗时 $modelTime');

    // 第三步：是否调用了工具
    if (hasToolCall) {
      final toolTime = formatDurationLabel(toolDurationMs);
      steps.add('AI 调用了 $toolCallCount 个工具，工具执行耗时 $toolTime');
      if (toolResultCount > 0) {
        steps.add('工具返回了 $toolResultCount 条结果');
      } else {
        steps.add('工具未返回结果（可能执行失败）');
      }
    } else {
      steps.add('本轮未调用工具，AI 直接回复');
    }

    // 第四步：AI 回复结果
    if (hasAiReply) {
      final replyPreview = aiReplyText.length > 60
          ? '${aiReplyText.substring(0, 60)}...'
          : aiReplyText;
      steps.add('AI 回复: $replyPreview');
    } else {
      steps.add('AI 未生成回复（异常）');
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '本轮概览',
            style: TextStyle(
              color: Colors.deepPurple,
              fontSize: 10,
              fontFamily: 'monospace',
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 4),
          ...steps.asMap().entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${e.key + 1}. ${e.value}',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 10,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────
  //  统一日志条目
  // ─────────────────────────────────────────

  Widget _buildLogItem(UnifiedLogEntry entry, int index, int total) {
    final colors = context.moeColors;
    final isExpanded = _expandedIndices.contains(index);
    final isSelected = _selectedIndices.contains(index);
    final needsFold = entry.needsFold;

    Color levelColor = colors.textSecondary;
    if (entry.isConversation) {
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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

  // ─────────────────────────────────────────
  //  操作方法
  // ─────────────────────────────────────────

  void _toggleSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
        if (_selectedIndices.isEmpty) _isSelectionMode = false;
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _selectAll() {
    final entries = buildUnifiedEntries(
      ApiLogger.entries.value,
      AppLogger.entries.value,
      hideBeforeTime: _hideBeforeTime,
      levelFilter: _levelFilter,
      typeFilter: _typeFilter,
    );
    setState(() {
      if (_selectedIndices.length == entries.length) {
        _selectedIndices.clear();
      } else {
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

    final entries = buildUnifiedEntries(
      ApiLogger.entries.value,
      AppLogger.entries.value,
      hideBeforeTime: _hideBeforeTime,
      levelFilter: _levelFilter,
      typeFilter: _typeFilter,
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
    final entries = buildUnifiedEntries(
      ApiLogger.entries.value,
      AppLogger.entries.value,
      hideBeforeTime: _hideBeforeTime,
      levelFilter: _levelFilter,
      typeFilter: _typeFilter,
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
    if (confirmed == true) _clearLogs();
  }

  void _clearLogs() {
    ApiLogger.clear();
    AppLogger.clear();
    _expandedIndices.clear();
    _selectedIndices.clear();
    _isSelectionMode = false;
    _hideBeforeTime = null;
    _saveHideBeforeTime(null);
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
