import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/api_logger.dart' show ApiLogEntry, ApiLogger;
import '../../../../core/app_logger.dart';
import '../../../../features/observability/trace_models.dart';
import '../../../../features/observability/frontend_diagnostics_provider.dart';
import '../../../../features/observability/trace_query_service.dart';
import '../../../../features/observability/trace_store.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import 'log_viewer/log_viewer_trace_conversation_view.dart';
import 'log_viewer/log_viewer_unified_list.dart';
import 'log_formatters.dart';
import 'log_history_list_page.dart';
import 'log_models.dart';
import 'trace_payload_panel.dart';

typedef SaveLogFileCallback = Future<String?> Function({
  String? dialogTitle,
  String? fileName,
  String? initialDirectory,
  FileType type,
  List<String>? allowedExtensions,
  Uint8List? bytes,
  bool lockParentWindow,
});

class LogExportResult {
  final String fileName;
  final String? savedPath;
  final int entryCount;

  const LogExportResult({
    required this.fileName,
    required this.savedPath,
    required this.entryCount,
  });
}

class LogViewerExportService {
  const LogViewerExportService._();

  static String buildExportContent(Iterable<UnifiedLogEntry> entries) {
    final list = entries.toList(growable: false);
    final buffer = StringBuffer();
    for (var i = 0; i < list.length; i++) {
      buffer.writeln(list[i].fullContent);
      if (i != list.length - 1) {
        buffer.writeln('---');
      }
    }
    return buffer.toString().trim();
  }

  static String buildDefaultFileName({DateTime? now}) {
    final time = now ?? DateTime.now();
    final yyyy = time.year.toString().padLeft(4, '0');
    final mm = time.month.toString().padLeft(2, '0');
    final dd = time.day.toString().padLeft(2, '0');
    final hh = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    return 'aicove_logs_$yyyy$mm${dd}_$hh$min$ss.txt';
  }

  static Future<String?> resolveInitialDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return null;
    }

    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        final downloadsDir = Directory('$userProfile\\Downloads');
        if (await downloadsDir.exists()) {
          return downloadsDir.path;
        }
      }
    }

    final downloadsDir = await getDownloadsDirectory();
    if (downloadsDir != null && await downloadsDir.exists()) {
      return downloadsDir.path;
    }

    final documentsDir = await getApplicationDocumentsDirectory();
    return documentsDir.path;
  }

  static Future<LogExportResult?> exportEntries({
    required List<UnifiedLogEntry> entries,
    required SaveLogFileCallback saveFile,
    DateTime? now,
    String? initialDirectory,
    bool? writeBytesInPicker,
    Future<void> Function(String path, Uint8List bytes)? writeFileBytes,
  }) async {
    if (entries.isEmpty) return null;

    final content = buildExportContent(entries);
    final bytes = Uint8List.fromList(utf8.encode(content));
    final fileName = buildDefaultFileName(now: now);
    final pickerHandlesWrite =
        writeBytesInPicker ?? (Platform.isAndroid || Platform.isIOS);

    final savedPath = await saveFile(
      dialogTitle: '导出日志文件',
      fileName: fileName,
      initialDirectory: initialDirectory,
      type: FileType.custom,
      allowedExtensions: const ['txt'],
      bytes: pickerHandlesWrite ? bytes : null,
      lockParentWindow: true,
    );
    if (savedPath == null) {
      return null;
    }

    final normalizedPath = savedPath.trim().isEmpty ? null : savedPath.trim();
    if (!pickerHandlesWrite) {
      if (normalizedPath == null) {
        throw const FileSystemException('未获取到有效保存路径');
      }
      final writer = writeFileBytes ??
          (String path, Uint8List data) async =>
              File(path).writeAsBytes(data, flush: true);
      await writer(normalizedPath, bytes);
    }

    return LogExportResult(
      fileName: fileName,
      savedPath: normalizedPath,
      entryCount: entries.length,
    );
  }
}

class LogViewerPage extends ConsumerStatefulWidget {
  const LogViewerPage({super.key});

  @override
  ConsumerState<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends ConsumerState<LogViewerPage> {
  static const String _hideBeforeTimeKey = 'log_viewer_hide_before_time';
  static const String _logLevelFilterKey = 'log_viewer_level_filter';
  static const String _logTypeFilterKey = 'log_viewer_type_filter';
  final ScrollController _scrollController = ScrollController();
  final Set<int> _expandedIndices = {};
  final Set<int> _selectedIndices = {};
  bool _scrollToBottomScheduled = false;
  bool _isSelectionMode = false;
  DateTime? _hideBeforeTime;
  int _lastVisibleLogCount = 0;
  LogLevelFilter _levelFilter = LogLevelFilter.all;
  LogTypeFilter _typeFilter = LogTypeFilter.all;
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
    _scheduleScrollToBottom();
  }

  Future<void> _loadHideBeforeTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_hideBeforeTimeKey);
    if (timestamp != null) {
      setState(() {
        _hideBeforeTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      });
      _scheduleScrollToBottom();
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
      if (_typeFilter != LogTypeFilter.conversation) {
        _scheduleScrollToBottom();
      }
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
      } else {
        _scheduleScrollToBottom();
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
      useRootNavigator: true,
      useSafeArea: true,
      enableDrag: false,
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

    return MoePageScaffold(
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
                tooltip: '返回',
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
                  tooltip: '历史日志',
                  icon: Icon(Icons.history, color: colors.text),
                  onPressed: _showHistoryLogs,
                ),
                IconButton(
                  tooltip: _typeFilter == LogTypeFilter.conversation
                      ? '导出选中对话（含前端记录）'
                      : '导出当前筛选',
                  icon: Icon(Icons.file_download_outlined, color: colors.text),
                  onPressed: _exportLogs,
                ),
                Builder(
                  builder: (menuContext) => IconButton(
                    tooltip: '更多操作',
                    icon: Icon(Icons.more_horiz, color: colors.text),
                    onPressed: () => MoePopupMenu.show(
                      menuContext,
                      targetBox: menuContext.findRenderObject()! as RenderBox,
                      alignToEnd: true,
                      items: [
                        MoePopupMenuItem(
                          label: '记录前端响应（本次运行）',
                          checked: ref.read(frontendDiagnosticsProvider).enabled,
                          onTap: () {
                            final diagnostics = ref.read(frontendDiagnosticsProvider);
                            setState(() => diagnostics.enabled = !diagnostics.enabled);
                          },
                        ),
                        MoePopupMenuItem(label: '从现在开始看', onTap: _startNewSession),
                        MoePopupMenuItem(label: '清空当前列表', onTap: _confirmClearLogs),
                      ],
                    ),
                  ),
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
    final turns = TraceQueryService.aggregateTurns(_filteredTraceEvents());
    return LogViewerTraceConversationView(
      turns: turns,
      selectedTurn: _selectedTraceTurn,
      selectedEvent: _selectedTraceEvent,
      selectedTracePayload: _selectedTracePayload,
      traceLoading: _traceLoading,
      tracePayloadLoading: _tracePayloadLoading,
      eventsForTurn: _eventsForTurn,
      onSelectTurn: _selectTraceTurn,
      onSelectEvent: _selectTraceEvent,
      onOpenEventDetail: (event) {
        unawaited(_showEventDetailSheet(event));
      },
    );
  }

  Widget _buildUnifiedList(
    List<ApiLogEntry> apiLogs,
    List<LogEntry> systemLogs,
  ) {
    final entries = buildUnifiedEntries(
      apiLogs,
      systemLogs,
      hideBeforeTime: _hideBeforeTime,
      levelFilter: _levelFilter,
      typeFilter: _typeFilter,
    );
    _syncVisibleLogCount(entries.length);

    return LogViewerUnifiedList(
      entries: entries,
      scrollController: _scrollController,
      expandedIndices: _expandedIndices,
      selectedIndices: _selectedIndices,
      isSelectionMode: _isSelectionMode,
      onToggleSelection: _toggleSelection,
      onToggleExpansion: (index) {
        setState(() {
          if (_expandedIndices.contains(index)) {
            _expandedIndices.remove(index);
          } else {
            _expandedIndices.add(index);
          }
        });
      },
      onEnterSelectionMode: (index) {
        setState(() {
          _isSelectionMode = true;
          _selectedIndices.add(index);
        });
      },
    );
  }

  void _syncVisibleLogCount(int count) {
    if (count > _lastVisibleLogCount) {
      _lastVisibleLogCount = count;
      _scheduleScrollToBottom();
    } else if (count < _lastVisibleLogCount) {
      _lastVisibleLogCount = count;
    }
  }

  // ─────────────────────────────────────────
  //  筛选栏
  // ─────────────────────────────────────────

  Widget _buildFilterBar() {
    return Column(
      children: [
        MoeFilterChipBar<LogTypeFilter>(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          items: [
            for (final filter in const [
              LogTypeFilter.all,
              LogTypeFilter.frontend,
              LogTypeFilter.conversation,
              LogTypeFilter.api,
              LogTypeFilter.system
            ])
              MoeFilterItem(value: filter, label: filter.label),
          ],
          selectedValue: _typeFilter,
          onSelected: (filter) {
            setState(() {
              _typeFilter = filter;
              _expandedIndices.clear();
              _selectedIndices.clear();
              _isSelectionMode = false;
            });
            if (filter == LogTypeFilter.conversation) {
              _loadTraceEvents();
            } else {
              _scheduleScrollToBottom();
            }
            _saveTypeFilter(filter);
          },
        ),
        if (_typeFilter != LogTypeFilter.conversation)
          MoeFilterChipBar<LogLevelFilter>(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            items: [
              for (final filter in const [
                LogLevelFilter.all,
                LogLevelFilter.error,
                LogLevelFilter.warning,
                LogLevelFilter.info
              ])
                MoeFilterItem(value: filter, label: filter.label)
            ],
            selectedValue: _levelFilter,
            onSelected: (filter) {
              setState(() {
                _levelFilter = filter;
                _expandedIndices.clear();
                _selectedIndices.clear();
                _isSelectionMode = false;
              });
              _scheduleScrollToBottom();
              _saveLevelFilter(filter);
            },
          ),
      ],
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
    var entries = buildUnifiedEntries(
      ApiLogger.entries.value,
      AppLogger.entries.value,
      hideBeforeTime: _hideBeforeTime,
      levelFilter: _levelFilter,
      typeFilter: _typeFilter,
    );

    if (_typeFilter == LogTypeFilter.conversation) {
      final selected = _selectedTraceTurn;
      if (selected == null) {
        MoeToast.info(context, '先选择一轮对话');
        return;
      }
      try {
        final content =
            await ref.read(traceExportProvider).exportTurn(selected.traceId);
        if (!mounted) return;
        entries = content == null
            ? []
            : [
                UnifiedLogEntry(
                  time: DateTime.now(),
                  title: '完整对话诊断',
                  fullContent: content,
                )
              ];
      } catch (_) {
        if (mounted) MoeToast.error(context, '读取对话诊断失败，请重试');
        return;
      }
    }
    if (entries.isEmpty) {
      MoeToast.info(context, '暂无日志可导出');
      return;
    }

    try {
      final initialDirectory =
          await LogViewerExportService.resolveInitialDirectory();
      final result = await LogViewerExportService.exportEntries(
        entries: entries,
        initialDirectory: initialDirectory,
        saveFile: ({
          String? dialogTitle,
          String? fileName,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Uint8List? bytes,
          bool lockParentWindow = false,
        }) {
          return FilePicker.platform.saveFile(
            dialogTitle: dialogTitle,
            fileName: fileName,
            initialDirectory: initialDirectory,
            type: type,
            allowedExtensions: allowedExtensions,
            bytes: bytes,
            lockParentWindow: lockParentWindow,
          );
        },
      );

      if (!mounted || result == null) return;
      final location = result.savedPath ?? result.fileName;
      MoeToast.success(
        context,
        '${_typeFilter == LogTypeFilter.conversation ? '已导出完整对话诊断' : '已导出 ${result.entryCount} 条日志'}\n$location',
      );
    } catch (e) {
      if (!mounted) return;
      MoeToast.error(context, '导出失败: $e');
    }
  }

  void _confirmClearLogs() async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '清空当前列表',
      message: '只清空当前显示的记录，已保存的历史文件仍会保留。',
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
    MoeToast.success(context, '当前列表已清空，历史文件已保留');
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
    MoeToast.brief(context, '现在只显示此刻之后的记录');
  }

  void _showHistoryLogs() {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(page: const LogHistoryListPage()),
    );
  }

  void _scheduleScrollToBottom() {
    if (_typeFilter == LogTypeFilter.conversation || _scrollToBottomScheduled) {
      return;
    }
    _scrollToBottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scrollToBottomScheduled = false;
      await _scrollToBottomWhenReady();
    });
  }

  Future<void> _scrollToBottomWhenReady({int maxFrames = 6}) async {
    var lastMaxScrollExtent = -1.0;

    for (var i = 0; i < maxFrames; i++) {
      if (!mounted) return;

      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scrollController.hasClients) {
        continue;
      }

      final position = _scrollController.position;
      if (!position.hasContentDimensions) {
        continue;
      }

      final maxScrollExtent = position.maxScrollExtent;
      if ((position.pixels - maxScrollExtent).abs() > 1.0) {
        _scrollController.jumpTo(maxScrollExtent);
      }

      if ((maxScrollExtent - lastMaxScrollExtent).abs() <= 1.0) {
        return;
      }
      lastMaxScrollExtent = maxScrollExtent;
    }
  }
}
