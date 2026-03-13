import 'package:flutter/material.dart';

import '../../../../features/observability/trace_models.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/theme/tokens.dart';
import 'log_formatters.dart'
    show stageToZh, statusToZh, stageIcon, formatDurationLabel;

/// 时间线面板 —— 按事件顺序展示一次对话中的各阶段
class TraceTimelinePanel extends StatelessWidget {
  const TraceTimelinePanel({
    super.key,
    required this.events,
    required this.selectedEvent,
    required this.onSelect,
    this.isLoading = false,
  });

  final List<TraceEvent> events;
  final TraceEvent? selectedEvent;
  final ValueChanged<TraceEvent> onSelect;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final visibleEvents = _resolveVisibleEvents();
    final hiddenCount = events.length - visibleEvents.length;
    final toolFinishDurations = _collectToolFinishDurations();

    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (visibleEvents.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timeline, size: 40, color: colors.muted),
            const SizedBox(height: 8),
            Text('暂无事件记录',
                style: TextStyle(color: colors.textSecondary, fontSize: 13)),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (hiddenCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '已折叠 $hiddenCount 个空节点',
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 10,
                ),
              ),
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(10),
            itemCount: visibleEvents.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (context, index) => _buildEventCard(
              context,
              visibleEvents[index],
              toolFinishDurations,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEventCard(
    BuildContext context,
    TraceEvent event,
    Map<String, int> toolFinishDurations,
  ) {
    final colors = context.moeColors;
    final selected = selectedEvent?.traceId == event.traceId &&
        selectedEvent?.eventSeq == event.eventSeq;
    final statusColor = _statusColor(event.status, colors);
    final isFailed = event.status == TraceEventStatus.failed.value;
    final zhName = stageToZh(event.stage);
    final zhStatus = statusToZh(event.status);
    final icon = stageIcon(event.stage);
    final subtitle = _buildSubtitle(event, toolFinishDurations);

    return GestureDetector(
      onTap: () => onSelect(event),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: (selected ? colors.primary : statusColor)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                size: 15,
                color: selected ? colors.primary : statusColor,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    zhName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isFailed ? Colors.red : colors.text,
                      fontSize: 12,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
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
      ),
    );
  }

  Color _statusColor(String status, MoeColors colors) {
    if (status == TraceEventStatus.failed.value) return Colors.red;
    if (status == TraceEventStatus.running.value) return Colors.orange;
    return Colors.green;
  }

  List<TraceEvent> _resolveVisibleEvents() {
    if (events.isEmpty) return const <TraceEvent>[];

    final aggregatedToolRounds = <String>{};
    for (final event in events) {
      if (_isAggregatedToolFinish(event)) {
        aggregatedToolRounds.add(_toolRoundKey(event));
      }
    }

    final visible = <TraceEvent>[];
    for (final event in events) {
      if (_shouldShowEvent(event, aggregatedToolRounds)) {
        visible.add(event);
      }
    }
    return visible.isEmpty ? events : visible;
  }

  bool _shouldShowEvent(TraceEvent event, Set<String> aggregatedToolRounds) {
    if (event.status != TraceEventStatus.success.value) {
      return true;
    }

    if (event.stage == TraceStage.toolExecStarted.value) {
      return false;
    }

    if (event.stage == TraceStage.toolExecFinished.value &&
        aggregatedToolRounds.contains(_toolRoundKey(event)) &&
        !_isAggregatedToolFinish(event)) {
      return false;
    }

    if (_markerStages.contains(event.stage) &&
        !_hasPayload(event) &&
        event.durationMs <= 0) {
      return false;
    }

    if (_hasPayload(event) || event.durationMs > 0) {
      return true;
    }

    if (event.stage == TraceStage.toolCallDetected.value) {
      final names = event.meta?['names'];
      return names is List && names.isNotEmpty;
    }

    return _alwaysVisibleStages.contains(event.stage);
  }

  Map<String, int> _collectToolFinishDurations() {
    final durations = <String, int>{};
    for (final event in events) {
      if (event.stage != TraceStage.toolExecFinished.value) continue;
      final current = durations[_toolRoundKey(event)] ?? 0;
      final next = event.durationMs > 0 ? current + event.durationMs : current;
      durations[_toolRoundKey(event)] = next;
    }
    return durations;
  }

  bool _hasPayload(TraceEvent event) =>
      event.payloadRef != null && event.payloadRef!.isNotEmpty;

  bool _isAggregatedToolFinish(TraceEvent event) {
    return event.stage == TraceStage.toolExecFinished.value &&
        _hasPayload(event) &&
        event.meta?['aggregated'] == true;
  }

  String _toolRoundKey(TraceEvent event) =>
      '${event.traceId}:${event.roundIndex}:${event.stage}';

  String _buildSubtitle(
    TraceEvent event,
    Map<String, int> toolFinishDurations,
  ) {
    final parts = <String>[
      _roundLabel(event.roundIndex),
      _formatTime(event.startedAt),
      formatDurationLabel(_displayDuration(event, toolFinishDurations)),
    ];
    final summary = _buildSummary(event);
    if (summary.isNotEmpty) {
      parts.add(summary);
    }
    return parts.join(' · ');
  }

  String _roundLabel(int roundIndex) {
    if (roundIndex <= 0) return '准备阶段';
    return '第${roundIndex}轮';
  }

  int _displayDuration(
    TraceEvent event,
    Map<String, int> toolFinishDurations,
  ) {
    if (_isAggregatedToolFinish(event)) {
      final merged = toolFinishDurations[_toolRoundKey(event)] ?? 0;
      if (merged > 0) {
        return merged;
      }
    }
    return event.durationMs;
  }

  String _buildSummary(TraceEvent event) {
    final meta = event.meta;
    if (meta == null || meta.isEmpty) return '';

    final error = _firstText(<dynamic>[
      meta['error'],
      meta['responseSnippet'],
    ]);
    if (error.isNotEmpty) {
      return _truncate(error, 24);
    }

    final names = meta['names'];
    if (names is List && names.isNotEmpty) {
      final joined = names
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .take(2)
          .join(', ');
      if (joined.isNotEmpty) {
        return _truncate(joined, 20);
      }
    }

    final parts = <String>[];
    final toolCalls = _safeInt(meta['toolCalls']) ?? _safeInt(meta['count']);
    final toolResults = _safeInt(meta['toolResults']);
    final textLength = _safeInt(meta['textLength']);
    final statusCode = _safeInt(meta['statusCode']);

    if (toolCalls != null && toolCalls > 0) {
      parts.add('${toolCalls}个工具');
    }
    if (toolResults != null && toolResults > 0) {
      parts.add('${toolResults}条结果');
    }
    if (textLength != null && textLength > 0) {
      parts.add('${textLength}字');
    }
    if (parts.isEmpty && statusCode != null && statusCode > 0) {
      parts.add('HTTP $statusCode');
    }

    return parts.join(' · ');
  }

  String _firstText(Iterable<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  int? _safeInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }

  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }

  String _formatTime(DateTime value) {
    return '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}:'
        '${value.second.toString().padLeft(2, '0')}';
  }
}

final Set<String> _alwaysVisibleStages = <String>{
  TraceStage.turnCompleted.value,
  TraceStage.turnFailed.value,
  TraceStage.messageDelivered.value,
  TraceStage.finalReplyReady.value,
};

final Set<String> _markerStages = <String>{
  TraceStage.turnStarted.value,
  TraceStage.userMessagePersisted.value,
  TraceStage.historyPrepared.value,
  TraceStage.apiConfigReady.value,
  TraceStage.roundRequestBuilt.value,
  TraceStage.modelRequestSent.value,
  TraceStage.roundCompleted.value,
};
