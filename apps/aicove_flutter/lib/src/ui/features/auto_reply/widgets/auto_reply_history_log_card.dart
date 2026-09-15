import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../features/auto_reply/data/auto_reply_trigger.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class AutoReplyHistoryLogCard extends StatelessWidget {
  const AutoReplyHistoryLogCard({
    super.key,
    required this.logs,
    required this.loading,
    required this.onRefresh,
    this.maxItems = 50,
  });

  final List<AutoReplyTriggerLog> logs;
  final bool loading;
  final VoidCallback onRefresh;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final displayLogs = logs.take(maxItems).toList(growable: false);

    return MoeSettingsGroup(
      padding: MoeSettingsLayout.contentPadding,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '历史触发器日志',
                    style: TextStyle(fontWeight: MoeFontWeights.emphasis),
                  ),
                ),
                IconButton(
                  tooltip: '刷新日志',
                  onPressed: loading ? null : onRefresh,
                  icon: loading
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(colors.primary),
                          ),
                        )
                      : Icon(Icons.refresh, color: colors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '这里会记录系统默认唤醒、后台 Agent 行为、触发器生命周期和实际发送结果。本地最多保留最近 200 条，当前展示最近 ${displayLogs.length} 条。',
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            _buildLegend(context),
            const SizedBox(height: 12),
            if (loading && logs.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: MoeLoadingIndicator(),
                ),
              )
            else if (displayLogs.isEmpty)
              const MoeEmptyState(
                icon: Icons.inbox_outlined,
                title: '还没有历史日志',
                description: '等后台 Agent 运行、触发器创建或默认唤醒发生后，这里就会出现记录。',
              )
            else
              Column(
                children: [
                  for (var index = 0; index < displayLogs.length; index++) ...[
                    _HistoryLogTile(log: displayLogs[index]),
                    if (index != displayLogs.length - 1)
                      Divider(
                        height: borderWidth,
                        thickness: borderWidth,
                        color: colors.borderLight,
                      ),
                  ],
                ],
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildLegend(BuildContext context) {
    final colors = context.moeColors;
    final items = <({String label, Color color})>[
      (label: '默认唤醒', color: colors.primary),
      (label: '分析决策', color: const Color(0xFF7E57C2)),
      (label: '触发器', color: const Color(0xFFFFA726)),
      (label: '后台 Agent', color: const Color(0xFF26A69A)),
      (label: '发送结果', color: const Color(0xFF66BB6A)),
      (label: '后台兜底', color: const Color(0xFF42A5F5)),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: MoeG2Decoration(
              radius: 10,
              color: item.color.withValues(alpha: 0.12),
              border: Border.all(color: item.color.withValues(alpha: 0.2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.text,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _HistoryLogTile extends StatelessWidget {
  const _HistoryLogTile({required this.log});

  final AutoReplyTriggerLog log;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final accentColor = _accentColor(colors);
    final metadataText = log.metadata.isEmpty
        ? ''
        : const JsonEncoder.withIndent('  ').convert(log.metadata);

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
        childrenPadding: const EdgeInsets.only(bottom: 12),
        title: Text(
          log.message,
          style: TextStyle(
            fontSize: 14,
            fontWeight: MoeFontWeights.emphasis,
            color: colors.text,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _formatDateTime(log.occurredAt),
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
              _MetaChip(label: _labelForCategory(), color: accentColor),
              if (log.title?.trim().isNotEmpty == true)
                _MetaChip(label: log.title!.trim(), color: colors.primary),
              if (log.success != null)
                _MetaChip(
                  label: log.success! ? '成功' : '失败',
                  color: log.success! ? colors.toastSuccess : colors.toastError,
                ),
              if (log.level != AutoReplyTriggerLogLevel.info)
                _MetaChip(
                  label: log.level == AutoReplyTriggerLogLevel.error
                      ? '错误'
                      : '警告',
                  color: log.level == AutoReplyTriggerLogLevel.error
                      ? colors.toastError
                      : const Color(0xFFFFA726),
                ),
            ],
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: MoeG2Decoration(
              radius: 10,
              color: colors.surfaceAlt,
              border: Border.all(color: colors.borderLight),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow(label: '事件编码', value: log.event),
                if (log.triggerId?.trim().isNotEmpty == true)
                  _DetailRow(label: 'Trigger ID', value: log.triggerId!.trim()),
                if (log.conversationId?.trim().isNotEmpty == true)
                  _DetailRow(
                    label: 'Conversation ID',
                    value: log.conversationId!.trim(),
                  ),
                if (log.source != null)
                  _DetailRow(label: '来源', value: _labelForSource(log.source!)),
                if (metadataText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '详细元数据',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: MoeFontWeights.emphasis,
                      color: colors.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    metadataText,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: colors.textSecondary,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _accentColor(MoeColors colors) {
    if (log.level == AutoReplyTriggerLogLevel.error) {
      return colors.toastError;
    }
    if (log.level == AutoReplyTriggerLogLevel.warning) {
      return const Color(0xFFFFA726);
    }
    switch (log.category) {
      case AutoReplyTriggerLogCategory.wakeup:
        return colors.primary;
      case AutoReplyTriggerLogCategory.analyzer:
        return const Color(0xFF7E57C2);
      case AutoReplyTriggerLogCategory.trigger:
        return const Color(0xFFFFA726);
      case AutoReplyTriggerLogCategory.agent:
        return const Color(0xFF26A69A);
      case AutoReplyTriggerLogCategory.delivery:
        return log.success == false ? colors.toastError : colors.toastSuccess;
      case AutoReplyTriggerLogCategory.background:
        return const Color(0xFF42A5F5);
    }
  }

  String _labelForCategory() {
    switch (log.category) {
      case AutoReplyTriggerLogCategory.wakeup:
        return '默认唤醒';
      case AutoReplyTriggerLogCategory.analyzer:
        return '分析决策';
      case AutoReplyTriggerLogCategory.trigger:
        return '触发器';
      case AutoReplyTriggerLogCategory.agent:
        return '后台 Agent';
      case AutoReplyTriggerLogCategory.delivery:
        return '发送结果';
      case AutoReplyTriggerLogCategory.background:
        return '后台兜底';
    }
  }

  String _labelForSource(TriggerSource source) {
    switch (source) {
      case TriggerSource.userManual:
        return '用户手动';
      case TriggerSource.userRequest:
        return '用户要求 AI 创建';
      case TriggerSource.aiScheduler:
        return 'AI 调度器';
      case TriggerSource.systemPreset:
        return '系统预设';
    }
  }

  String _formatDateTime(DateTime time) {
    final local = time.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute:$second';
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: MoeG2Decoration(
        radius: 8,
        color: color.withValues(alpha: 0.12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: MoeFontWeights.emphasis,
          color: color,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: colors.textSecondary,
          ),
          children: [
            TextSpan(
              text: '$label：',
              style: TextStyle(
                fontWeight: MoeFontWeights.emphasis,
                color: colors.text,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}
