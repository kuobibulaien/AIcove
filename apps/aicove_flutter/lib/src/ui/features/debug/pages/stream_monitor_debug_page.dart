import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../features/chat/services/stream_monitor_service.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 调试工具：流式监控可视化
///
/// 展示流式尝试/成功/回退统计，便于定位“看起来没流式”的真实原因。
class StreamMonitorDebugPage extends StatefulWidget {
  const StreamMonitorDebugPage({super.key});

  @override
  State<StreamMonitorDebugPage> createState() => _StreamMonitorDebugPageState();
}

class _StreamMonitorDebugPageState extends State<StreamMonitorDebugPage> {
  bool _loading = true;
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSnapshot());
  }

  Future<void> _loadSnapshot() async {
    setState(() => _loading = true);
    try {
      await StreamMonitorService.ensureLoaded();
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _resetSnapshot() async {
    setState(() => _resetting = true);
    try {
      await StreamMonitorService.reset();
      if (mounted) {
        MoeToast.success(context, '流式监控数据已重置');
      }
    } catch (e) {
      if (mounted) {
        MoeToast.error(context, '重置失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _resetting = false);
      }
    }
  }

  String _formatPercent(double value) => '${(value * 100).toStringAsFixed(1)}%';

  String _formatDateTime(DateTime? time) {
    if (time == null) return '-';
    final local = time.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  String _reasonLabel(String reason) {
    switch (reason) {
      case 'unsupported_provider':
        return '不支持流式';
      case 'missing_api_key':
        return '缺少 API Key';
      case 'unauthorized':
        return '鉴权失败';
      case 'timeout':
        return '超时';
      case 'network':
        return '网络异常';
      case 'parse':
        return '解析异常';
      case 'unknown':
      default:
        return '未知错误';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '流式监控', showBackButton: true),
      body: ValueListenableBuilder<StreamMonitorSnapshot>(
        valueListenable: StreamMonitorService.snapshot,
        builder: (context, snapshot, _) {
          final reasons = snapshot.failureCounts.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_loading || _resetting)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: MoeG2Decoration(
                  radius: 12,
                  color: colors.surface,
                  border: Border.all(color: colors.borderLight),
                ),
                child: Text(
                  '说明：这里只统计“尝试流式 -> 成功流式 / 回退整段”的结果。'
                  '如果回退次数增加，优先看失败原因和最近错误。',
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ),
              const SizedBox(height: 12),
              MoeSettingsGroup(
                children: [
                  MoeSettingsRow(
                    icon: Icons.flag_outlined,
                    label: '流式尝试次数',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: '${snapshot.attemptCount}',
                  ),
                  MoeSettingsRow(
                    icon: Icons.check_circle_outline,
                    label: '流式成功次数',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: '${snapshot.successCount}',
                  ),
                  MoeSettingsRow(
                    icon: Icons.error_outline,
                    label: '回退次数',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: '${snapshot.fallbackCount}',
                  ),
                  MoeSettingsRow(
                    icon: Icons.percent_outlined,
                    label: '成功率',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: _formatPercent(snapshot.successRate),
                  ),
                  MoeSettingsRow(
                    icon: Icons.memory_outlined,
                    label: '最近模型',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: snapshot.lastModelFullId?.trim().isNotEmpty ==
                            true
                        ? snapshot.lastModelFullId!
                        : '-',
                    showDivider: false,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              MoeSettingsGroup(
                children: [
                  MoeSettingsRow(
                    icon: Icons.event_outlined,
                    label: '最近失败时间',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: _formatDateTime(snapshot.lastFailureAt),
                  ),
                  MoeSettingsRow(
                    icon: Icons.report_problem_outlined,
                    label: '最近失败原因',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: snapshot.lastFailureReason == null
                        ? '-'
                        : _reasonLabel(snapshot.lastFailureReason!.value),
                    showDivider: false,
                  ),
                ],
              ),
              if ((snapshot.lastFailureError ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: MoeG2Decoration(
                    radius: 12,
                    color: colors.surface,
                    border: Border.all(color: colors.borderLight),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '最近错误详情',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                          fontWeight: MoeFontWeights.emphasis,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        snapshot.lastFailureError!,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.text,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: MoeG2Decoration(
                  radius: 12,
                  color: colors.surface,
                  border: Border.all(color: colors.borderLight),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '失败原因分布',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textSecondary,
                        fontWeight: MoeFontWeights.emphasis,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (reasons.isEmpty)
                      Text(
                        '暂无回退记录',
                        style:
                            TextStyle(fontSize: 12, color: colors.textSecondary),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final item in reasons)
                            Chip(
                              label: Text(
                                '${_reasonLabel(item.key)} x${item.value}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: MoeSecondaryButton(
                      label: '刷新',
                      icon: Icons.refresh,
                      onPressed: _loading ? null : _loadSnapshot,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MoePrimaryButton(
                      label: '清空统计',
                      icon: Icons.delete_outline,
                      onPressed: _resetting ? null : _resetSnapshot,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}
