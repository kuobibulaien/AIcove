import 'package:flutter/material.dart';

import '../../../../../features/observability/trace_models.dart';
import '../../../../../features/observability/trace_query_service.dart';
import '../../../../shared/effects/smooth_clip.dart';
import '../../../../theme/tokens.dart';
import '../log_formatters.dart';
import '../trace_payload_panel.dart';
import '../trace_timeline_panel.dart';

class LogViewerTraceConversationView extends StatelessWidget {
  const LogViewerTraceConversationView({
    super.key,
    required this.turns,
    required this.selectedTurn,
    required this.selectedEvent,
    required this.selectedTracePayload,
    required this.traceLoading,
    required this.tracePayloadLoading,
    required this.eventsForTurn,
    required this.onSelectTurn,
    required this.onSelectEvent,
    required this.onOpenEventDetail,
  });

  final List<TraceTurnSummary> turns;
  final TraceTurnSummary? selectedTurn;
  final TraceEvent? selectedEvent;
  final Map<String, dynamic>? selectedTracePayload;
  final bool traceLoading;
  final bool tracePayloadLoading;
  final List<TraceEvent> Function(String traceId) eventsForTurn;
  final ValueChanged<TraceTurnSummary> onSelectTurn;
  final ValueChanged<TraceEvent> onSelectEvent;
  final ValueChanged<TraceEvent> onOpenEventDetail;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    if (traceLoading && turns.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (turns.isEmpty) {
      return Center(
        child: Text(
          '暂无 Trace 对话日志',
          style: TextStyle(color: colors.textSecondary),
        ),
      );
    }

    final activeTurn = turns.firstWhere(
      (turn) => turn.traceId == selectedTurn?.traceId,
      orElse: () => turns.first,
    );
    final events = TraceQueryService.buildTimelineEvents(
        eventsForTurn(activeTurn.traceId));
    final resolvedSelectedEvent = events.isEmpty
        ? null
        : events.firstWhere(
            (event) =>
                event.traceId == selectedEvent?.traceId &&
                event.eventSeq == selectedEvent?.eventSeq,
            orElse: () => events.first,
          );
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= 1040;

    if (!isWide) {
      return Column(
        children: [
          _TraceTurnDropdown(
            turns: turns,
            activeTurn: activeTurn,
            onSelectTurn: onSelectTurn,
          ),
          Expanded(
            child: TraceTimelinePanel(
              events: events,
              selectedEvent: resolvedSelectedEvent,
              onSelect: onOpenEventDetail,
              isLoading: traceLoading,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        SizedBox(
          width: 320,
          child: _TraceTurnList(
            turns: turns,
            activeTurn: activeTurn,
            onSelectTurn: onSelectTurn,
          ),
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
            selectedEvent: resolvedSelectedEvent,
            onSelect: onSelectEvent,
            isLoading: traceLoading,
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
            selectedEvent: resolvedSelectedEvent,
            payloadEnvelope: selectedTracePayload,
            isLoading: tracePayloadLoading,
          ),
        ),
      ],
    );
  }
}

class _TraceTurnDropdown extends StatelessWidget {
  const _TraceTurnDropdown({
    required this.turns,
    required this.activeTurn,
    required this.onSelectTurn,
  });

  final List<TraceTurnSummary> turns;
  final TraceTurnSummary activeTurn;
  final ValueChanged<TraceTurnSummary> onSelectTurn;

  @override
  Widget build(BuildContext context) {
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
              onSelectTurn(match.first);
            }
          },
        ),
      ),
    );
  }
}

class _TraceTurnList extends StatelessWidget {
  const _TraceTurnList({
    required this.turns,
    required this.activeTurn,
    required this.onSelectTurn,
  });

  final List<TraceTurnSummary> turns;
  final TraceTurnSummary activeTurn;
  final ValueChanged<TraceTurnSummary> onSelectTurn;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: turns.length,
      itemBuilder: (context, index) {
        final turn = turns[index];
        return _TraceTurnItem(
          turn: turn,
          selected: turn.traceId == activeTurn.traceId,
          onTap: () => onSelectTurn(turn),
        );
      },
    );
  }
}

class _TraceTurnItem extends StatelessWidget {
  const _TraceTurnItem({
    required this.turn,
    required this.selected,
    required this.onTap,
  });

  final TraceTurnSummary turn;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final statusColor = turn.status == TraceEventStatus.failed.value
        ? Colors.red
        : (turn.status == TraceEventStatus.running.value
            ? Colors.orange
            : Colors.green);
    final zhStatus = statusToZh(turn.status);

    return GestureDetector(
      onTap: onTap,
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
}

String _buildTraceTurnTitle(TraceTurnSummary turn) {
  final time = formatTime(turn.startedAt);
  return '$time · ${turn.roundCount}轮 · ${statusToZh(turn.status)}';
}
