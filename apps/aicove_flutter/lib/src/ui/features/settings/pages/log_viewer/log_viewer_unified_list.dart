import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../core/app_logger.dart' show LogLevel;
import '../../../../../core/utils/data_image.dart';
import '../../../../shared/effects/smooth_clip.dart';
import '../../../../shared/widgets/index.dart';
import '../../../../theme/tokens.dart';
import '../collapsible_selectable_text.dart';
import '../context_image_preview_extractor.dart';
import '../log_formatters.dart';
import '../log_models.dart';

class LogViewerUnifiedList extends StatelessWidget {
  const LogViewerUnifiedList({
    super.key,
    required this.entries,
    required this.scrollController,
    required this.expandedIndices,
    required this.selectedIndices,
    required this.isSelectionMode,
    required this.onToggleSelection,
    required this.onToggleExpansion,
    required this.onEnterSelectionMode,
  });

  final List<UnifiedLogEntry> entries;
  final ScrollController scrollController;
  final Set<int> expandedIndices;
  final Set<int> selectedIndices;
  final bool isSelectionMode;
  final ValueChanged<int> onToggleSelection;
  final ValueChanged<int> onToggleExpansion;
  final ValueChanged<int> onEnterSelectionMode;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    if (entries.isEmpty) {
      return const MoeEmptyState(
        icon: Icons.receipt_long_outlined,
        title: '当前筛选下暂无记录',
        description: '前端记录会在聊天操作后出现；以前的记录请打开历史日志。',
      );
    }

    final attentionCount = entries
        .where((entry) => (entry.level?.value ?? 0) >= LogLevel.warning.value)
        .length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '当前运行 · ${entries.length} 条记录 · $attentionCount 条需要关注\n'
              '“进入后／累计”是时间点，不代表动画耗时；展开查看阶段统计。',
              style: TextStyle(
                  color: colors.textSecondary, fontSize: 12, height: 1.5),
            )),
      ),
      Expanded(
          child: ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.all(16),
        itemCount: entries.length,
        itemBuilder: (context, index) => _LogViewerEntryItem(
          entry: entries[index],
          index: index,
          isExpanded: expandedIndices.contains(index),
          isSelected: selectedIndices.contains(index),
          isSelectionMode: isSelectionMode,
          onToggleSelection: () => onToggleSelection(index),
          onToggleExpansion: () => onToggleExpansion(index),
          onEnterSelectionMode: () => onEnterSelectionMode(index),
        ),
      )),
    ]);
  }
}

class LogViewerConversationList extends StatelessWidget {
  const LogViewerConversationList({
    super.key,
    required this.turns,
    required this.showRawStreamEvents,
    required this.scrollController,
    required this.contextImagePreviewResolver,
  });

  final List<ConversationTurnLog> turns;
  final bool showRawStreamEvents;
  final ScrollController scrollController;
  final ContextImagePreviewBatch Function(String? rawRequestBody)
      contextImagePreviewResolver;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    if (turns.isEmpty) {
      return Center(
        child: Text('暂无对话日志', style: TextStyle(color: colors.textSecondary)),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: turns.length,
      itemBuilder: (context, index) => _ConversationTurnCard(
        turn: turns[index],
        index: index,
        showRawStreamEvents: showRawStreamEvents,
        contextImagePreviewResolver: contextImagePreviewResolver,
      ),
    );
  }
}

class _LogViewerEntryItem extends StatelessWidget {
  const _LogViewerEntryItem({
    required this.entry,
    required this.index,
    required this.isExpanded,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onToggleSelection,
    required this.onToggleExpansion,
    required this.onEnterSelectionMode,
  });

  final UnifiedLogEntry entry;
  final int index;
  final bool isExpanded;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onToggleSelection;
  final VoidCallback onToggleExpansion;
  final VoidCallback onEnterSelectionMode;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final needsFold = entry.fullContent.isNotEmpty;
    final levelColor = _resolveLevelColor(colors, entry);

    return GestureDetector(
      onTap: () {
        if (isSelectionMode) {
          onToggleSelection();
        } else if (needsFold) {
          onToggleExpansion();
        }
      },
      onLongPress: () {
        if (!isSelectionMode) {
          onEnterSelectionMode();
          HapticFeedback.mediumImpact();
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: MoeG2Decoration(
          radius: MoeSmoothRadii.sm,
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
                if (isSelectionMode) ...[
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
                    '${entry.categoryLabel}\n${formatTime(entry.time)}',
                    style: TextStyle(
                        fontSize: 11, height: 1.5, color: colors.muted),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.title,
                    maxLines: isExpanded ? null : 3,
                    overflow: isExpanded ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: levelColor,
                      height: 1.5,
                    ),
                  ),
                ),
                if (needsFold && !isSelectionMode)
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
                  entry.fullContent,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.5,
                    color: colors.text,
                  ),
                )
              else
                Text(
                  '点开查看详情',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConversationTurnCard extends StatelessWidget {
  const _ConversationTurnCard({
    required this.turn,
    required this.index,
    required this.showRawStreamEvents,
    required this.contextImagePreviewResolver,
  });

  final ConversationTurnLog turn;
  final int index;
  final bool showRawStreamEvents;
  final ContextImagePreviewBatch Function(String? rawRequestBody)
      contextImagePreviewResolver;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final meta = <String>[
      '开始: ${formatTime(turn.startedAt)}',
      if (turn.turnId != null) 'turn=${turn.turnId}',
      if (turn.sessionId != null) 'session=${turn.sessionId}',
      if (turn.turnId == null) 'key=${turn.turnKey}',
    ].join(' | ');
    final rawFinalReply = resolveRawFinalReply(turn);
    final finalReply = resolveFinalReply(turn);
    final finalDeliveryDurationMs = resolveFinalDeliveryDurationMs(turn);
    final finalReplyTitle = rawFinalReply != null
        ? (finalDeliveryDurationMs != null
            ? '模型原始最终回复（按轮聚合原文，耗时：${formatDurationLabel(finalDeliveryDurationMs)}）'
            : '模型原始最终回复（按轮聚合原文）')
        : (finalDeliveryDurationMs != null
            ? '最终展示给用户的回复（耗时：${formatDurationLabel(finalDeliveryDurationMs)}）'
            : '最终展示给用户的回复');

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
              _ConversationRoundCard(
                round: turn.rounds[i],
                showRawStreamEvents: showRawStreamEvents,
                contextImagePreviewResolver: contextImagePreviewResolver,
              ),
              if (i != turn.rounds.length - 1) const SizedBox(height: 8),
            ],
          ],
          if (finalReply.isNotEmpty) ...[
            const SizedBox(height: 10),
            _ConversationSection(
              title: finalReplyTitle,
              content: finalReply,
              titleColor: Colors.green,
            ),
          ],
        ],
      ),
    );
  }
}

class _ConversationRoundCard extends StatelessWidget {
  const _ConversationRoundCard({
    required this.round,
    required this.showRawStreamEvents,
    required this.contextImagePreviewResolver,
  });

  final ConversationRoundLog round;
  final bool showRawStreamEvents;
  final ContextImagePreviewBatch Function(String? rawRequestBody)
      contextImagePreviewResolver;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final requestLog = round.requestLog;
    final toolLog = round.toolLog;
    final rawContext = requestLog?.rawContext;
    final rawRequestBody = requestLog?.rawRequestBody;
    final contextImageBatch = contextImagePreviewResolver(rawRequestBody);
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

    final contextText = prettyJson(rawContext) ?? '(空)';
    final requestBodyText = rawRequestBody?.trim();
    final requestToolCatalogText =
        _extractToolCatalogFromRawRequestBody(rawRequestBody);
    final shouldShowRawResponseSection =
        !isStreamEnvelope || showRawStreamEvents;
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
          _ConversationFlowSummary(
            contextCount: contextCount,
            toolCallCount: toolCallCount,
            toolResultCount: toolResultCount,
            aiReplyText: aiReply,
            modelDurationMs: modelDurationMs,
            toolDurationMs: toolDurationMs,
          ),
          if (contextImageBatch.items.isNotEmpty) ...[
            const SizedBox(height: 8),
            _ContextImagePreviewSection(batch: contextImageBatch),
          ],
          const SizedBox(height: 8),
          _ConversationSection(
            title: '上下文消息（messages，不含 tools）',
            content: contextText,
          ),
          if (requestBodyText != null && requestBodyText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _ConversationSection(
              title: 'AI 第一视角原始请求串（rawRequestBody 原文）',
              content: requestBodyText,
              collapsedLines: 16,
            ),
          ],
          if (requestToolCatalogText != null &&
              requestToolCatalogText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _ConversationSection(
              title: '本轮可用工具清单（从 rawRequestBody 提取）',
              content: requestToolCatalogText,
            ),
          ],
          if (isStreamEnvelope && streamPreviewTitle != null) ...[
            const SizedBox(height: 6),
            _ConversationSection(
              title: streamPreviewTitle,
              content: mergedStreamText,
            ),
          ],
          if (rawResponseJson != null && rawResponseJson.trim().isNotEmpty) ...[
            if (shouldShowRawResponseSection) ...[
              const SizedBox(height: 6),
              _ConversationSection(
                title: isStreamEnvelope
                    ? '流式回包原始事件（JSON，按轮汇总）'
                    : 'AI 原始 JSON 响应（模型回包）',
                content: rawResponseJson,
              ),
            ],
          ],
          if (toolTraceText != null && toolTraceText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _ConversationSection(
              title: '工具调用轨迹（含失败信息）',
              content: toolTraceText,
            ),
          ],
          if (isStreamEnvelope &&
              !hasNaturalReply &&
              toolTraceText != null &&
              toolTraceText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            const _ConversationSection(
              title: '本轮说明',
              content: '本轮无自然语言回复，主要用于工具调用。',
            ),
          ],
          if (toolCallCount > 0) ...[
            const SizedBox(height: 6),
            _ConversationSection(
              title: 'AI 请求调用的工具',
              content: toolCallsText,
            ),
          ],
          if (toolResultCount > 0) ...[
            const SizedBox(height: 6),
            _ConversationSection(
              title: '工具执行结果',
              content: toolResultsText,
            ),
          ],
          const SizedBox(height: 6),
          _ConversationSection(
            title: 'AI 回复的原文',
            content: aiReply,
          ),
        ],
      ),
    );
  }
}

class _ContextImagePreviewSection extends StatelessWidget {
  const _ContextImagePreviewSection({
    required this.batch,
  });

  final ContextImagePreviewBatch batch;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final title = batch.hasMore
        ? '模型看到的图片缩略图（至少${batch.totalCount}张，展示前${batch.items.length}张）'
        : '模型看到的图片缩略图（共${batch.totalCount}张）';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
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
              _ContextImagePreviewTile(
                item: batch.items[i],
                index: i,
              ),
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
}

class _ContextImagePreviewTile extends StatelessWidget {
  const _ContextImagePreviewTile({
    required this.item,
    required this.index,
  });

  final ContextImagePreview item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final sourceLabel = switch (item.kind) {
      ContextImagePreviewKind.dataUri => 'data',
      ContextImagePreviewKind.remoteUrl => 'url',
      ContextImagePreviewKind.fileUrl => 'file',
    };

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
              child: SizedBox.expand(
                child: _ContextImagePreviewMedia(item: item),
              ),
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
}

class _ContextImagePreviewMedia extends StatelessWidget {
  const _ContextImagePreviewMedia({
    required this.item,
  });

  final ContextImagePreview item;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    if (item.kind == ContextImagePreviewKind.remoteUrl) {
      return Image.network(
        item.value,
        fit: BoxFit.cover,
        cacheWidth: 200,
        cacheHeight: 200,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, __, ___) => _ContextImageFallback(colors: colors),
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
          errorBuilder: (_, __, ___) => _ContextImageFallback(colors: colors),
        );
      }
      return _ContextImageFallback(colors: colors);
    }

    return _ContextImageFallback(colors: colors, hint: 'file://');
  }
}

class _ContextImageFallback extends StatelessWidget {
  const _ContextImageFallback({
    required this.colors,
    this.hint = '无法预览',
  });

  final MoeColors colors;
  final String hint;

  @override
  Widget build(BuildContext context) {
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
}

class _ConversationSection extends StatelessWidget {
  const _ConversationSection({
    required this.title,
    required this.content,
    this.titleColor,
    this.collapsedLines = 10,
  });

  final String title;
  final String content;
  final Color? titleColor;
  final int collapsedLines;

  @override
  Widget build(BuildContext context) {
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
}

class _ConversationFlowSummary extends StatelessWidget {
  const _ConversationFlowSummary({
    required this.contextCount,
    required this.toolCallCount,
    required this.toolResultCount,
    required this.aiReplyText,
    required this.modelDurationMs,
    required this.toolDurationMs,
  });

  final int contextCount;
  final int toolCallCount;
  final int toolResultCount;
  final String aiReplyText;
  final int? modelDurationMs;
  final int? toolDurationMs;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final hasToolCall = toolCallCount > 0;
    final hasAiReply = aiReplyText != '(空)' && aiReplyText.isNotEmpty;
    final modelTime = formatDurationLabel(modelDurationMs);
    final steps = <String>[];

    if (contextCount > 0) {
      steps.add('收到 $contextCount 条上下文消息');
    } else {
      steps.add('上下文为空（可能有问题）');
    }

    steps.add('AI 思考并回复，耗时 $modelTime');

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
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${entry.key + 1}. ${entry.value}',
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
}

Color _resolveLevelColor(MoeColors colors, UnifiedLogEntry entry) {
  if (entry.level != null) {
    switch (entry.level!) {
      case LogLevel.error:
      case LogLevel.critical:
        return Colors.red;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.info:
        return colors.text;
      case LogLevel.debug:
        return colors.textSecondary;
    }
  }
  if (entry.isApiLog) {
    return Colors.teal;
  }
  return colors.textSecondary;
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
