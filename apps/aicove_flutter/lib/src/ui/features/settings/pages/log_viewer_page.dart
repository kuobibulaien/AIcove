import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/api_logger.dart' show ApiLogEntry, ApiLogger;
import '../../../../core/app_logger.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../features/observability/trace_models.dart';
import '../../../../features/observability/trace_query_service.dart';
import '../../../../features/observability/trace_store.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import 'collapsible_selectable_text.dart';
import 'context_image_preview_extractor.dart';
import 'log_formatters.dart';
import 'log_history_list_page.dart';
import 'log_models.dart';
import 'trace_payload_panel.dart';
import 'trace_timeline_panel.dart';

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  static const String _hideBeforeTimeKey = 'log_viewer_hide_before_time';
  static const String _logLevelFilterKey = 'log_viewer_level_filter';
  static const String _logTypeFilterKey = 'log_viewer_type_filter';
  static const int _contextPreviewLimit = 4;
  static const int _contextPreviewCacheMax = 48;

  final ScrollController _scrollController = ScrollController();
  final Set<int> _expandedIndices = {};
  final Set<int> _selectedIndices = {};
  final Map<String, ContextImagePreviewBatch> _contextImagePreviewCache =
      <String, ContextImagePreviewBatch>{};
  bool _isSelectionMode = false;
  DateTime? _hideBeforeTime;
  int _lastLogCount = 0;
  LogLevelFilter _levelFilter = LogLevelFilter.all;
  LogTypeFilter _typeFilter = LogTypeFilter.all;
  bool _showRawStreamEvents = false;
  bool _traceLoading = false;
  List<TraceEvent> _traceEvents = <TraceEvent>[];
  TraceTurnSummary? _selectedTraceTurn;
  TraceEvent? _selectedTraceEvent;
  Map<String, dynamic>? _selectedTracePayload;
  bool _tracePayloadLoading = false;
  int _tracePayloadToken = 0;

  @override
  void initState() {
    super.initState();
    _loadHideBeforeTime();
    _loadLevelFilter();
    _loadTypeFilter();
    _loadTraceEvents();
    TraceStore.instance.entries.addListener(_onTraceEntriesChanged);
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
      final filter = LogTypeFilter.values[index];
      setState(() => _typeFilter = filter);
      if (filter == LogTypeFilter.conversation) {
        _loadTraceEvents();
      }
    }
  }

  Future<void> _saveTypeFilter(LogTypeFilter filter) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_logTypeFilterKey, filter.index);
  }

  void _onTraceEntriesChanged() {
    final liveEvents = TraceStore.instance.entries.value;
    if (liveEvents.isEmpty) return;
    final merged = <String, TraceEvent>{
      for (final event in _traceEvents) _traceEventKey(event): event,
    };
    for (final event in liveEvents) {
      merged[_traceEventKey(event)] = event;
    }
    final list = merged.values.toList();
    if (list.length == _traceEvents.length) return;
    setState(() {
      _traceEvents = list;
    });
    _ensureTraceSelection();
  }

  Future<void> _loadTraceEvents() async {
    if (_traceLoading) return;
    setState(() {
      _traceLoading = true;
    });
    try {
      final events = await TraceStore.instance.readRecentEvents(maxDays: 7);
      if (!mounted) return;
      setState(() {
        _traceEvents = events;
        _traceLoading = false;
      });
      _ensureTraceSelection();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _traceLoading = false;
      });
    }
  }

  String _traceEventKey(TraceEvent event) =>
      '${event.traceId}#${event.eventSeq}';

  void _ensureTraceSelection() {
    final turns = TraceQueryService.aggregateTurns(_filteredTraceEvents());
    if (turns.isEmpty) {
      final changed = _selectedTraceTurn != null ||
          _selectedTraceEvent != null ||
          _selectedTracePayload != null ||
          _tracePayloadLoading;
      if (changed) {
        setState(() {
          _selectedTraceTurn = null;
          _selectedTraceEvent = null;
          _selectedTracePayload = null;
          _tracePayloadLoading = false;
        });
      }
      return;
    }

    TraceTurnSummary selectedTurn = turns.first;
    if (_selectedTraceTurn != null) {
      final matched =
          turns.where((e) => e.traceId == _selectedTraceTurn!.traceId);
      if (matched.isNotEmpty) {
        selectedTurn = matched.first;
      }
    }
    _selectedTraceTurn = selectedTurn;

    final events = _eventsForTurn(selectedTurn.traceId);
    if (events.isEmpty) {
      _selectedTraceEvent = null;
      _selectedTracePayload = null;
      _tracePayloadLoading = false;
      return;
    }

    TraceEvent selectedEvent = events.first;
    if (_selectedTraceEvent != null) {
      final matched = events.where((e) =>
          e.traceId == _selectedTraceEvent!.traceId &&
          e.eventSeq == _selectedTraceEvent!.eventSeq);
      if (matched.isNotEmpty) {
        selectedEvent = matched.first;
      }
    } else {
      final withPayload = events.where((e) => e.payloadRef != null);
      if (withPayload.isNotEmpty) {
        selectedEvent = withPayload.first;
      }
    }

    final turnChanged = _selectedTraceTurn?.traceId != selectedTurn.traceId;
    final eventChanged =
        _selectedTraceEvent?.traceId != selectedEvent.traceId ||
            _selectedTraceEvent?.eventSeq != selectedEvent.eventSeq;

    if (turnChanged || eventChanged) {
      setState(() {
        _selectedTraceTurn = selectedTurn;
        _selectedTraceEvent = selectedEvent;
      });
    }
    if (eventChanged) {
      unawaited(_loadTracePayload(selectedEvent));
    }
  }

  void _selectTraceTurn(TraceTurnSummary turn) {
    if (_selectedTraceTurn?.traceId == turn.traceId) return;
    setState(() {
      _selectedTraceTurn = turn;
      final events = _eventsForTurn(turn.traceId);
      _selectedTraceEvent = events.isEmpty
          ? null
          : events.firstWhere(
              (event) => event.payloadRef != null,
              orElse: () => events.first,
            );
    });
    unawaited(_loadTracePayload(_selectedTraceEvent));
  }

  void _selectTraceEvent(TraceEvent event) {
    final changed = _selectedTraceEvent?.traceId != event.traceId ||
        _selectedTraceEvent?.eventSeq != event.eventSeq;
    if (!changed) return;
    setState(() {
      _selectedTraceEvent = event;
    });
    unawaited(_loadTracePayload(event));
  }

  Future<void> _loadTracePayload(TraceEvent? event) async {
    final token = ++_tracePayloadToken;
    if (event == null) {
      setState(() {
        _selectedTracePayload = null;
        _tracePayloadLoading = false;
      });
      return;
    }
    setState(() {
      _tracePayloadLoading = true;
      _selectedTracePayload = null;
    });
    Map<String, dynamic>? payload;
    try {
      payload = await TraceStore.instance.readPayloadByRef(event.payloadRef);
    } catch (_) {
      payload = null;
    }
    if (!mounted || token != _tracePayloadToken) return;
    setState(() {
      _selectedTracePayload = payload;
      _tracePayloadLoading = false;
    });
  }

  /// 窄屏下点击事件→底部弹窗展示详情
  Future<void> _showEventDetailSheet(TraceEvent event) async {
    setState(() => _selectedTraceEvent = event);
    Map<String, dynamic>? payload;
    try {
      payload = await TraceStore.instance.readPayloadByRef(event.payloadRef);
    } catch (_) {}
    if (!mounted) return;
    final colors = context.moeColors;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.85,
        child: Column(
          children: [
            // 拖动手柄
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.muted,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Expanded(
              child: TracePayloadPanel(
                selectedEvent: event,
                payloadEnvelope: payload,
                isLoading: false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<TraceEvent> _filteredTraceEvents() {
    final events = _traceEvents.where((event) {
      if (_hideBeforeTime == null) return true;
      return !event.startedAt.isBefore(_hideBeforeTime!);
    }).toList();
    return events;
  }

  List<TraceEvent> _eventsForTurn(String traceId) {
    final events = _filteredTraceEvents()
        .where((event) => event.traceId == traceId)
        .toList();
    return TraceQueryService.sortEvents(events);
  }

  ContextImagePreviewBatch _resolveContextImagePreviewBatch(
      String? rawRequestBody) {
    final raw = rawRequestBody?.trim() ?? '';
    if (raw.isEmpty) return ContextImagePreviewBatch.empty;

    final key = '${raw.length}:${raw.hashCode}';
    final cached = _contextImagePreviewCache[key];
    if (cached != null) return cached;

    final batch = extractContextImagePreviewsFromRequestBody(
      raw,
      limit: _contextPreviewLimit,
    );
    if (_contextImagePreviewCache.length >= _contextPreviewCacheMax) {
      _contextImagePreviewCache.remove(_contextImagePreviewCache.keys.first);
    }
    _contextImagePreviewCache[key] = batch;
    return batch;
  }

  @override
  void dispose() {
    TraceStore.instance.entries.removeListener(_onTraceEntriesChanged);
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
                    return _buildTraceConversationView();
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

  Widget _buildTraceConversationView() {
    final colors = context.moeColors;
    final turns = TraceQueryService.aggregateTurns(_filteredTraceEvents());

    if (_traceLoading && turns.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (turns.isEmpty) {
      return Center(
        child: Text('暂无 Trace 对话日志',
            style: TextStyle(color: colors.textSecondary)),
      );
    }

    final activeTurn = turns.firstWhere(
      (turn) => turn.traceId == _selectedTraceTurn?.traceId,
      orElse: () => turns.first,
    );
    final events = TraceQueryService.buildTimelineEvents(
        _eventsForTurn(activeTurn.traceId));
    final TraceEvent? selectedEvent = events.isEmpty
        ? null
        : events.firstWhere(
            (event) =>
                event.traceId == _selectedTraceEvent?.traceId &&
                event.eventSeq == _selectedTraceEvent?.eventSeq,
            orElse: () => events.first,
          );
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= 1040;

    if (!isWide) {
      return Column(
        children: [
          _buildTraceTurnDropdown(turns, activeTurn),
          Expanded(
            child: TraceTimelinePanel(
              events: events,
              selectedEvent: selectedEvent,
              onSelect: (event) => _showEventDetailSheet(event),
              isLoading: _traceLoading,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        SizedBox(
          width: 320,
          child: _buildTraceTurnList(turns, activeTurn),
        ),
        VerticalDivider(
          width: 1,
          thickness: 0.5,
          color: colors.borderLight,
        ),
        Expanded(
          flex: 4,
          child: TraceTimelinePanel(
            events: events,
            selectedEvent: selectedEvent,
            onSelect: _selectTraceEvent,
            isLoading: _traceLoading,
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 0.5,
          color: colors.borderLight,
        ),
        Expanded(
          flex: 5,
          child: TracePayloadPanel(
            selectedEvent: selectedEvent,
            payloadEnvelope: _selectedTracePayload,
            isLoading: _tracePayloadLoading,
          ),
        ),
      ],
    );
  }

  Widget _buildTraceTurnDropdown(
    List<TraceTurnSummary> turns,
    TraceTurnSummary activeTurn,
  ) {
    final colors = context.moeColors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          bottom: BorderSide(color: colors.borderLight, width: 0.5),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: activeTurn.traceId,
          items: [
            for (final turn in turns)
              DropdownMenuItem<String>(
                value: turn.traceId,
                child: Text(
                  _buildTraceTurnTitle(turn),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.text, fontSize: 12),
                ),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            final match = turns.where((turn) => turn.traceId == value);
            if (match.isNotEmpty) {
              _selectTraceTurn(match.first);
            }
          },
        ),
      ),
    );
  }

  Widget _buildTraceTurnList(
    List<TraceTurnSummary> turns,
    TraceTurnSummary activeTurn,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: turns.length,
      itemBuilder: (context, index) {
        final turn = turns[index];
        return _buildTraceTurnItem(
          turn: turn,
          selected: turn.traceId == activeTurn.traceId,
        );
      },
    );
  }

  Widget _buildTraceTurnItem({
    required TraceTurnSummary turn,
    required bool selected,
  }) {
    final colors = context.moeColors;
    final statusColor = turn.status == TraceEventStatus.failed.value
        ? Colors.red
        : (turn.status == TraceEventStatus.running.value
            ? Colors.orange
            : Colors.green);
    final zhStatus = statusToZh(turn.status);
    return GestureDetector(
      onTap: () => _selectTraceTurn(turn),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: MoeG2Decoration(
          radius: 10,
          color: selected
              ? colors.primary.withValues(alpha: 0.12)
              : colors.componentBackground,
          border: Border.all(
            color: selected ? colors.primary : colors.borderLight,
            width: borderWidth,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _buildTraceTurnTitle(turn),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 12,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    zhStatus,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${turn.roundCount}轮请求 · ${turn.toolCallCount}次工具调用 · 耗时${formatDurationLabel(turn.totalDurationMs)}',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'ID: ${turn.turnId.length > 24 ? '${turn.turnId.substring(0, 24)}...' : turn.turnId}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.muted,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _buildTraceTurnTitle(TraceTurnSummary turn) {
    final time = formatTime(turn.startedAt);
    return '$time · ${turn.roundCount}轮 · ${statusToZh(turn.status)}';
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
                    if (filter == LogTypeFilter.conversation) {
                      _loadTraceEvents();
                    }
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
    final rawRequestBody = requestLog?.rawRequestBody;
    final contextImageBatch = _resolveContextImagePreviewBatch(rawRequestBody);
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
    final requestBodyText = rawRequestBody?.trim();
    final requestToolCatalogText =
        _extractToolCatalogFromRawRequestBody(rawRequestBody);
    final shouldShowRawResponseSection =
        !isStreamEnvelope || _showRawStreamEvents;
    final rawResponseJson =
        shouldShowRawResponseSection ? prettyJson(rawResponseBody) : null;
    final mergedStreamText = streamPreview?.hasMergedText == true
        ? streamPreview!.mergedText
        : '(空)';
    final streamPreviewTitle = streamPreview == null
        ? null
        : '流式回包（按轮聚合后的文本，${streamPreview.eventCount}个事件'
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
          if (contextImageBatch.items.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildContextImagePreviewSection(contextImageBatch),
          ],
          const SizedBox(height: 8),
          _buildConversationSection(
            title: '上下文消息（messages，不含 tools）',
            content: contextText,
          ),
          if (requestBodyText != null && requestBodyText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _buildConversationSection(
              title: 'AI 第一视角原始请求串（rawRequestBody 原文）',
              content: requestBodyText,
              collapsedLines: 16,
            ),
          ],
          if (requestToolCatalogText != null &&
              requestToolCatalogText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _buildConversationSection(
              title: '本轮可用工具清单（从 rawRequestBody 提取）',
              content: requestToolCatalogText,
            ),
          ],
          if (isStreamEnvelope && streamPreviewTitle != null) ...[
            const SizedBox(height: 6),
            _buildConversationSection(
              title: streamPreviewTitle,
              content: mergedStreamText,
            ),
          ],
          if (rawResponseJson != null && rawResponseJson.trim().isNotEmpty) ...[
            if (shouldShowRawResponseSection) ...[
              const SizedBox(height: 6),
              _buildConversationSection(
                title: isStreamEnvelope
                    ? '流式回包原始事件（JSON，按轮汇总）'
                    : 'AI 原始 JSON 响应（模型回包）',
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

  Widget _buildContextImagePreviewSection(ContextImagePreviewBatch batch) {
    final colors = context.moeColors;
    final title = batch.hasMore
        ? '模型看到的图片缩略图（至少${batch.totalCount}张，展示前${batch.items.length}张）'
        : '模型看到的图片缩略图（共${batch.totalCount}张）';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: Colors.deepPurple,
            fontSize: 10,
            fontFamily: 'monospace',
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (var i = 0; i < batch.items.length; i++)
              _buildContextImagePreviewTile(batch.items[i], i),
          ],
        ),
        if (batch.hasMore)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '其余图片未展开，避免日志页卡顿。',
              style: TextStyle(
                color: colors.muted,
                fontSize: 10,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildContextImagePreviewTile(ContextImagePreview item, int index) {
    final colors = context.moeColors;
    final sourceLabel = switch (item.kind) {
      ContextImagePreviewKind.dataUri => 'data',
      ContextImagePreviewKind.remoteUrl => 'url',
      ContextImagePreviewKind.fileUrl => 'file',
    };

    final media = _buildContextImagePreviewMedia(item);

    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 92,
            height: 92,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.borderLight, width: borderWidth),
            ),
            child: SmoothClipRRect(
              radius: 8,
              child: SizedBox.expand(child: media),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '#${index + 1} · $sourceLabel',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextImagePreviewMedia(ContextImagePreview item) {
    final colors = context.moeColors;
    if (item.kind == ContextImagePreviewKind.remoteUrl) {
      return Image.network(
        item.value,
        fit: BoxFit.cover,
        cacheWidth: 200,
        cacheHeight: 200,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, __, ___) => _buildContextImageFallback(colors),
      );
    }

    if (item.isDataImage) {
      final bytes = decodeDataImage(item.value);
      if (bytes != null && bytes.isNotEmpty) {
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: 200,
          cacheHeight: 200,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, __, ___) => _buildContextImageFallback(colors),
        );
      }
      return _buildContextImageFallback(colors);
    }

    return _buildContextImageFallback(colors, hint: 'file://');
  }

  Widget _buildContextImageFallback(
    MoeColors colors, {
    String hint = '无法预览',
  }) {
    return ColoredBox(
      color: colors.surface.withValues(alpha: 0.75),
      child: Center(
        child: Text(
          hint,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.muted,
            fontSize: 10,
          ),
        ),
      ),
    );
  }

  String? _extractToolCatalogFromRawRequestBody(String? rawRequestBody) {
    final requestBody = _decodeJsonMap(rawRequestBody);
    if (requestBody == null) return null;
    final rawTools = requestBody['tools'];
    if (rawTools is! List || rawTools.isEmpty) return null;

    final catalog = <Map<String, dynamic>>[];
    var catalogIndex = 0;

    void addCatalogEntry({
      required String source,
      String? type,
      String? name,
      dynamic description,
      dynamic parameters,
      dynamic raw,
    }) {
      catalog.add({
        'index': catalogIndex++,
        'source': source,
        'type': type ?? 'function',
        if (name != null && name.trim().isNotEmpty) 'name': name,
        if (description != null) 'description': description,
        if (parameters != null) 'parameters': parameters,
        if (raw != null) 'raw': raw,
      });
    }

    for (final rawTool in rawTools) {
      if (rawTool is! Map) continue;
      final tool = rawTool.cast<String, dynamic>();
      final function = tool['function'];
      if (function is Map) {
        final fn = function.cast<String, dynamic>();
        addCatalogEntry(
          source: 'openai.tools',
          type: tool['type']?.toString(),
          name: fn['name']?.toString(),
          description: fn['description'],
          parameters: fn['parameters'],
        );
        continue;
      }

      final declarations = tool['functionDeclarations'];
      if (declarations is List && declarations.isNotEmpty) {
        for (final rawDeclaration in declarations) {
          if (rawDeclaration is! Map) continue;
          final declaration = rawDeclaration.cast<String, dynamic>();
          addCatalogEntry(
            source: 'gemini.functionDeclarations',
            type: 'function',
            name: declaration['name']?.toString(),
            description: declaration['description'],
            parameters: declaration['parameters'],
          );
        }
        continue;
      }

      final toolName = tool['name']?.toString();
      final toolParameters = tool['input_schema'] ?? tool['parameters'];
      if (toolName != null && toolName.trim().isNotEmpty) {
        addCatalogEntry(
          source: 'provider.tools',
          type: tool['type']?.toString() ?? 'function',
          name: toolName,
          description: tool['description'],
          parameters: toolParameters,
        );
        continue;
      }

      addCatalogEntry(
        source: 'provider.tools',
        type: tool['type']?.toString(),
        raw: tool,
      );
    }

    if (catalog.isEmpty) return null;
    return const JsonEncoder.withIndent('  ').convert(catalog);
  }

  Map<String, dynamic>? _decodeJsonMap(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
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
    TraceStore.instance.entries.value = <TraceEvent>[];
    _contextImagePreviewCache.clear();
    _expandedIndices.clear();
    _selectedIndices.clear();
    _isSelectionMode = false;
    _hideBeforeTime = null;
    _traceEvents = <TraceEvent>[];
    _selectedTraceTurn = null;
    _selectedTraceEvent = null;
    _selectedTracePayload = null;
    _tracePayloadLoading = false;
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
    _ensureTraceSelection();
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
