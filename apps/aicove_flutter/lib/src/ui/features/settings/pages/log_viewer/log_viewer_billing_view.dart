import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../features/observability/token_usage_ledger.dart';
import '../../../../shared/effects/smooth_clip.dart';
import '../../../../shared/widgets/index.dart';
import '../../../../theme/tokens.dart';
import '../../widgets/model_row_tile.dart' show showModelPricingSheet;
import '../log_formatters.dart' show formatDurationLabel;

/// 友好的中文用量数字格式化（如 840、3,420、12.8 万、1.24 亿）
String formatFriendlyTokenCount(int count) {
  if (count <= 0) return '0';
  if (count < 1000) return '$count';
  if (count < 10000) {
    final s = '$count';
    return '${s.substring(0, 1)},${s.substring(1)}';
  }
  if (count < 100000000) {
    final wan = count / 10000.0;
    final raw = wan >= 100
        ? wan.toStringAsFixed(1)
        : wan.toStringAsFixed(2);
    final trimmed = raw
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return '$trimmed 万';
  }
  final yi = count / 100000000.0;
  final trimmed = yi
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return '$trimmed 亿';
}

/// 精确整数千分位格式化（展开详情中使用）
String formatExactCount(int count) {
  final raw = '$count';
  if (raw.length <= 3) return raw;
  final buf = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    if (i > 0 && (raw.length - i) % 3 == 0) buf.write(',');
    buf.write(raw[i]);
  }
  return buf.toString();
}

/// 单币种微元金额格式化（小于 1 元保留最多 4 位有效小数，1 元及以上保留 2 位）
String formatCurrencyMicros(int micros, String currency) {
  final symbol = currency == 'CNY' ? '¥' : '\$';
  if (micros <= 0) return '${symbol}0.00';
  final value = micros / 1000000.0;
  if (value >= 1.0) {
    return '$symbol${value.toStringAsFixed(2)}';
  }
  final raw = value.toStringAsFixed(4);
  final trimmed = raw.replaceFirst(RegExp(r'0+$'), '');
  final dotIdx = trimmed.indexOf('.');
  final decimals = dotIdx < 0 ? 0 : trimmed.length - dotIdx - 1;
  if (decimals < 2) {
    return '$symbol${value.toStringAsFixed(2)}';
  }
  return '$symbol$trimmed';
}

/// 双币种汇总金额格式化
String formatCombinedCost({
  required int usdCostMicros,
  required int cnyCostMicros,
  required int requestCount,
  required int unpricedRequestCount,
}) {
  if (requestCount > 0 &&
      usdCostMicros == 0 &&
      cnyCostMicros == 0 &&
      unpricedRequestCount == requestCount) {
    return '暂未设置单价';
  }
  if (cnyCostMicros > 0 && usdCostMicros > 0) {
    return '${formatCurrencyMicros(cnyCostMicros, 'CNY')} + '
        '${formatCurrencyMicros(usdCostMicros, 'USD')}';
  }
  if (cnyCostMicros > 0) {
    return formatCurrencyMicros(cnyCostMicros, 'CNY');
  }
  if (usdCostMicros > 0) {
    return formatCurrencyMicros(usdCostMicros, 'USD');
  }
  return '¥0.00';
}

/// 供「模型管理」入口展示今日简短摘要
String formatTodayUsageQuickSummary(UsageOverview? overview) {
  if (overview == null || overview.requestCount == 0) {
    return '查看花费明细';
  }
  if (overview.cnyCostMicros > 0 || overview.usdCostMicros > 0) {
    return '今日 ${formatCombinedCost(
      usdCostMicros: overview.usdCostMicros,
      cnyCostMicros: overview.cnyCostMicros,
      requestCount: overview.requestCount,
      unpricedRequestCount: overview.unpricedRequestCount,
    )}';
  }
  return '今日 ${formatFriendlyTokenCount(overview.totalTokens)}';
}

class LogViewerBillingView extends ConsumerStatefulWidget {
  const LogViewerBillingView({
    super.key,
    required this.range,
    required this.groupBy,
    required this.deviceId,
    required this.onRangeChanged,
    required this.onGroupByChanged,
    required this.onDeviceChanged,
  });

  final UsageTimeRange range;
  final UsageGroupBy groupBy;
  final String? deviceId;
  final ValueChanged<UsageTimeRange> onRangeChanged;
  final ValueChanged<UsageGroupBy> onGroupByChanged;
  final ValueChanged<String?> onDeviceChanged;

  @override
  ConsumerState<LogViewerBillingView> createState() =>
      _LogViewerBillingViewState();
}

class _LogViewerBillingViewState extends ConsumerState<LogViewerBillingView> {
  final Set<String> _expandedIds = <String>{};

  static String _rangeLabel(UsageTimeRange range) => switch (range) {
    UsageTimeRange.today => '今天',
    UsageTimeRange.days7 => '近 7 天',
    UsageTimeRange.days30 => '近 30 天',
    UsageTimeRange.all => '全部',
  };

  static String _groupByLabel(UsageGroupBy by) => switch (by) {
    UsageGroupBy.model => '按模型',
    UsageGroupBy.conversation => '按角色',
    UsageGroupBy.purpose => '按用途',
    UsageGroupBy.device => '按设备',
  };

  @override
  Widget build(BuildContext context) {
    final overviewAsync = ref.watch(
      tokenUsageOverviewProvider((
        range: widget.range,
        groupBy: widget.groupBy,
        deviceId: widget.deviceId,
      )),
    );
    final entriesAsync = ref.watch(
      tokenUsageEntriesProvider((
        range: widget.range,
        deviceId: widget.deviceId,
        limit: 200,
      )),
    );

    final overview = overviewAsync.valueOrNull;
    final entries = entriesAsync.valueOrNull ?? const <UsageEntryView>[];
    final devices = overview?.availableDevices ?? const <UsageDevice>[];
    final lastPricingSyncAt = ref
        .watch(officialPricingSyncTimeProvider)
        .valueOrNull;

    return Column(
      children: [
        MoeFilterChipBar<UsageTimeRange>(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          items: [
            for (final item in UsageTimeRange.values)
              MoeFilterItem(value: item, label: _rangeLabel(item)),
          ],
          selectedValue: widget.range,
          onSelected: widget.onRangeChanged,
        ),
        if (devices.length > 1)
          MoeFilterChipBar<String?>(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            items: [
              const MoeFilterItem<String?>(value: null, label: '全部设备'),
              for (final dev in devices)
                MoeFilterItem<String?>(
                  value: dev.deviceId,
                  label: dev.isLocal
                      ? '${dev.deviceName}（本机）'
                      : dev.deviceName,
                ),
            ],
            selectedValue: widget.deviceId,
            onSelected: widget.onDeviceChanged,
          ),
        Expanded(
          child: overviewAsync.isLoading && overview == null
              ? const Center(child: MoeLoadingIndicator(message: '正在统计账单...'))
              : _buildScrollContent(
                  context,
                  overview,
                  entries,
                  lastPricingSyncAt: lastPricingSyncAt,
                ),
        ),
      ],
    );
  }

  Widget _buildScrollContent(
    BuildContext context,
    UsageOverview? overview,
    List<UsageEntryView> entries, {
    DateTime? lastPricingSyncAt,
  }) {
    if (overview == null || (overview.requestCount == 0 && entries.isEmpty)) {
      return const MoeEmptyState(
        icon: Icons.receipt_long_outlined,
        title: '还没有用量记录',
        description: '聊天、整理记忆或角色主动发消息后，每次调用的字数用量和预估花费都会记在这里。',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 820;
        final colors = context.moeColors;

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          itemCount: entries.isEmpty ? 2 : entries.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isWide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: _OverviewSummaryCard(
                            overview: overview,
                            lastPricingSyncAt: lastPricingSyncAt,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 6,
                          child: _BreakdownCard(
                            overview: overview,
                            groupBy: widget.groupBy,
                            onGroupByChanged: widget.onGroupByChanged,
                            groupByLabel: _groupByLabel,
                          ),
                        ),
                      ],
                    )
                  else ...[
                    _OverviewSummaryCard(
                      overview: overview,
                      lastPricingSyncAt: lastPricingSyncAt,
                    ),
                    const SizedBox(height: 12),
                    _BreakdownCard(
                      overview: overview,
                      groupBy: widget.groupBy,
                      onGroupByChanged: widget.onGroupByChanged,
                      groupByLabel: _groupByLabel,
                    ),
                  ],
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Row(
                      children: [
                        Text(
                          '最近账单明细',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: MoeFontWeights.emphasis,
                            color: colors.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        if (entries.isNotEmpty)
                          Text(
                            '显示最近 ${entries.length} 笔',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            }
            if (entries.isEmpty) {
              return MoeContentSurface(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: Text(
                    '当前来自其他设备的汇总账单已计入上方总览，逐笔明细在对应设备上保留。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: colors.muted),
                  ),
                ),
              );
            }
            final item = entries[index - 1];
            return _BillingEntryTile(
              item: item,
              expanded: _expandedIds.contains(item.id),
              onToggle: () {
                setState(() {
                  if (_expandedIds.contains(item.id)) {
                    _expandedIds.remove(item.id);
                  } else {
                    _expandedIds.add(item.id);
                  }
                });
              },
            );
          },
        );
      },
    );
  }
}

class _OverviewSummaryCard extends StatelessWidget {
  const _OverviewSummaryCard({
    required this.overview,
    this.lastPricingSyncAt,
  });

  final UsageOverview overview;
  final DateTime? lastPricingSyncAt;

  static String _formatSyncTime(DateTime time) {
    final local = time.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final costText = formatCombinedCost(
      usdCostMicros: overview.usdCostMicros,
      cnyCostMicros: overview.cnyCostMicros,
      requestCount: overview.requestCount,
      unpricedRequestCount: overview.unpricedRequestCount,
    );
    final allUnpriced =
        overview.requestCount > 0 &&
        overview.unpricedRequestCount == overview.requestCount;
    final partialUnpriced =
        overview.unpricedRequestCount > 0 && !allUnpriced;
    final cacheHitPct = overview.inputTokens > 0
        ? ((overview.cachedInputTokens * 100.0) / overview.inputTokens)
              .round()
              .clamp(0, 100)
        : 0;

    return MoeContentSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '预估总花费',
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            costText,
            style: TextStyle(
              fontSize: allUnpriced ? 20 : 28,
              height: 1.2,
              fontWeight: MoeFontWeights.emphasis,
              color: allUnpriced ? colors.textSecondary : colors.text,
            ),
          ),
          if (allUnpriced)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '在「按模型」列表点右侧「设单价」，填好后历史记录也会自动换算',
                style: TextStyle(fontSize: 12, color: colors.muted, height: 1.4),
              ),
            )
          else if (partialUnpriced)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '另有 ${overview.unpricedRequestCount} 次调用的模型暂未设置单价',
                style: TextStyle(fontSize: 12, color: colors.muted),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _MetricTile(
                  label: '总用量',
                  value: formatFriendlyTokenCount(overview.totalTokens),
                  subtext: overview.reasoningTokens > 0
                      ? '含思考 ${formatFriendlyTokenCount(overview.reasoningTokens)}'
                      : '输入与输出合计',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricTile(
                  label: '输入 / 输出',
                  value:
                      '${formatFriendlyTokenCount(overview.inputTokens)} / '
                      '${formatFriendlyTokenCount(overview.outputTokens)}',
                  subtext: '发给模型 / 模型回复',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _MetricTile(
                  label: '缓存省流',
                  value: overview.cachedInputTokens > 0
                      ? '${formatFriendlyTokenCount(overview.cachedInputTokens)} ($cacheHitPct%)'
                      : '暂无命中',
                  subtext: overview.cachedInputTokens > 0
                      ? '重复上下文已享折扣'
                      : '视渠道支持情况生效',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricTile(
                  label: '调用次数',
                  value: '${overview.requestCount} 次',
                  subtext: overview.estimatedCount > 0
                      ? '含 ${overview.estimatedCount} 次本地估算'
                      : '全部来自真实账单',
                ),
              ),
            ],
          ),
          if (lastPricingSyncAt != null) ...[
            const SizedBox(height: 10),
            Text(
              '官方参考单价已于 ${_formatSyncTime(lastPricingSyncAt!)} 更新',
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.subtext,
  });

  final String label;
  final String value;
  final String subtext;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeInsetSurface(
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: colors.muted),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtext,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _BreakdownCard extends ConsumerWidget {
  const _BreakdownCard({
    required this.overview,
    required this.groupBy,
    required this.onGroupByChanged,
    required this.groupByLabel,
  });

  final UsageOverview overview;
  final UsageGroupBy groupBy;
  final ValueChanged<UsageGroupBy> onGroupByChanged;
  final String Function(UsageGroupBy) groupByLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final groups = overview.groups;

    return MoeContentSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '用量排行',
            style: TextStyle(
              fontSize: 14,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final option in UsageGroupBy.values)
                MoeChoiceChip(
                  label: groupByLabel(option),
                  selected: groupBy == option,
                  onTap: () => onGroupByChanged(option),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  '暂无分类数据',
                  style: TextStyle(fontSize: 13, color: colors.muted),
                ),
              ),
            )
          else
            for (var i = 0; i < groups.length; i++) ...[
              _BreakdownRow(
                item: groups[i],
                isModelGroup: groupBy == UsageGroupBy.model,
                onEditPrice:
                    groupBy == UsageGroupBy.model &&
                        groups[i].rawModelId != null
                    ? () => showModelPricingSheet(
                        context,
                        ref,
                        providerId: groups[i].providerId ?? '',
                        modelId: groups[i].rawModelId!,
                      )
                    : null,
              ),
              if (i != groups.length - 1) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.item,
    required this.isModelGroup,
    this.onEditPrice,
  });

  final UsageGroupItem item;
  final bool isModelGroup;
  final VoidCallback? onEditPrice;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final totalTokens = item.inputTokens + item.outputTokens;
    final hasCost = item.cnyCostMicros > 0 || item.usdCostMicros > 0;
    final costLabel = hasCost
        ? formatCombinedCost(
            usdCostMicros: item.usdCostMicros,
            cnyCostMicros: item.cnyCostMicros,
            requestCount: item.requestCount,
            unpricedRequestCount: item.isUnpricedModel ? item.requestCount : 0,
          )
        : (item.isUnpricedModel ? '未设单价' : '¥0.00');

    final rowContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: MoeFontWeights.emphasis,
                        color: colors.text,
                      ),
                    ),
                  ),
                  if (item.subtitle != null &&
                      item.subtitle!.trim().isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(
                      item.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isModelGroup && item.isUnpricedModel && onEditPrice != null)
              GestureDetector(
                onTap: onEditPrice,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '设单价',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: MoeFontWeights.emphasis,
                      color: context.moeAccentInk,
                    ),
                  ),
                ),
              )
            else
              Text(
                costLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: MoeFontWeights.emphasis,
                  color: hasCost ? colors.text : colors.muted,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              '${item.requestCount} 次 · 用量 ${formatFriendlyTokenCount(totalTokens)}',
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
            if (item.cachedInputTokens > 0) ...[
              const SizedBox(width: 8),
              Text(
                '缓存 ${formatFriendlyTokenCount(item.cachedInputTokens)}',
                style: TextStyle(fontSize: 11, color: colors.muted),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: item.shareRatio.clamp(0.02, 1.0),
            minHeight: 5,
            backgroundColor: colors.borderLight,
            valueColor: AlwaysStoppedAnimation<Color>(
              colors.primary.withValues(alpha: 0.78),
            ),
          ),
        ),
      ],
    );

    if (onEditPrice == null) return rowContent;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onEditPrice,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: rowContent,
      ),
    );
  }
}

class _BillingEntryTile extends StatelessWidget {
  const _BillingEntryTile({
    required this.item,
    required this.expanded,
    required this.onToggle,
  });

  final UsageEntryView item;
  final bool expanded;
  final VoidCallback onToggle;

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '$hh:$mm';
    }
    final mon = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$mon-$day $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final actorLabel =
        item.conversationTitle?.trim().isNotEmpty == true
        ? '${item.conversationTitle} · ${item.purposeTitle}'
        : item.purposeTitle;
    final modelLabel =
        item.modelDisplayName?.trim().isNotEmpty == true
        ? item.modelDisplayName!
        : item.rawModelId;
    final costText = item.priced && item.costMicros != null && item.currency != null
        ? formatCurrencyMicros(item.costMicros!, item.currency!)
        : '未设单价';

    return GestureDetector(
      onTap: onToggle,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: MoeG2Decoration(
          radius: MoeSmoothRadii.sm,
          color: colors.componentBackground,
          border: Border.all(color: colors.borderLight, width: borderWidth),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            actorLabel,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: MoeFontWeights.emphasis,
                              color: colors.text,
                            ),
                          ),
                          if (item.isRemote && item.deviceName.isNotEmpty)
                            _TagPill(label: '来自 ${item.deviceName}'),
                          if (item.isEstimated)
                            const _TagPill(label: '估算'),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$modelLabel · ${_formatDateTime(item.createdAtDateTime)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      costText,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: MoeFontWeights.emphasis,
                        color: item.priced ? colors.text : colors.muted,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '用量 ${formatFriendlyTokenCount(item.totalTokens)}',
                      style: TextStyle(fontSize: 11, color: colors.muted),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    _DetailPair(
                      label: '渠道',
                      value: item.providerDisplayName ?? item.providerId,
                    ),
                    _DetailPair(
                      label: '输入用量',
                      value: formatExactCount(item.inputTokens),
                    ),
                    if (item.cachedInputTokens > 0)
                      _DetailPair(
                        label: '缓存命中',
                        value: formatExactCount(item.cachedInputTokens),
                      ),
                    if (item.usage.cacheWriteTokens > 0)
                      _DetailPair(
                        label: '缓存新建',
                        value: formatExactCount(item.usage.cacheWriteTokens),
                      ),
                    _DetailPair(
                      label: '输出用量',
                      value: formatExactCount(item.outputTokens),
                    ),
                    if (item.usage.reasoningTokens > 0)
                      _DetailPair(
                        label: '思考用量',
                        value: formatExactCount(item.usage.reasoningTokens),
                      ),
                    if (item.entry.durationMs != null)
                      _DetailPair(
                        label: '耗时',
                        value: formatDurationLabel(item.entry.durationMs),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TagPill extends StatelessWidget {
  const _TagPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.borderLight,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: colors.textSecondary),
      ),
    );
  }
}

class _DetailPair extends StatelessWidget {
  const _DetailPair({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return RichText(
      text: TextSpan(
        style: DefaultTextStyle.of(context).style.copyWith(fontSize: 12),
        children: [
          TextSpan(
            text: '$label：',
            style: TextStyle(color: colors.muted),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
              color: colors.text,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
        ],
      ),
    );
  }
}
