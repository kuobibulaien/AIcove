import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/theme/moe_interaction_theme.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger_controller.dart';
import '../../../../features/auto_reply/presentation/widgets/auto_reply_trigger_form.dart';

class AutoReplyTriggerListPage extends ConsumerWidget {
  const AutoReplyTriggerListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;

    ref.listen<AutoReplyTriggerEvent?>(autoReplyTriggerEventProvider, (
      previous,
      next,
    ) {
      if (next == null) return;
      MoeToast.info(context, _eventText(next));
      ref.read(autoReplyTriggerEventProvider.notifier).state = null;
    });

    final triggersAsync = ref.watch(autoReplyTriggersProvider);
    final controller = ref.read(autoReplyTriggersProvider.notifier);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '待触发列表', showBackButton: true),
      floatingActionButton: MoeButtonSurface(
        shareParentSurface: false,
        width: 56,
        height: 56,
        radius: 16,
        tintColor: colors.primary,
        child: MoeIconButton(
          tooltip: '新建触发',
          icon: Icons.add,
          color: colors.text,
          minTouchTarget: 56,
          onTap: () => showCreateAutoReplyTriggerSheet(context, ref),
        ),
      ),
      backgroundColor: colors.surface,
      body: MoeSettingsContent(
        child: triggersAsync.when(
          loading: () => const Center(child: MoeLoadingIndicator()),
          error: (e, _) => Center(
            child: MoeEmptyState(
              icon: Icons.error_outline,
              title: '加载失败',
              description: '$e',
            ),
          ),
          data: (triggers) {
            // 显示活跃的触发器（排除已触发/已过期/已删除的）
            final pending =
                triggers
                    .where(
                      (t) =>
                          t.isActive ||
                          t.status == AutoReplyTriggerStatus.paused,
                    )
                    .toList()
                  ..sort((a, b) => a.nextFireAt.compareTo(b.nextFireAt));
            if (pending.isEmpty) {
              return _buildEmptyState();
            }
            return Builder(
              builder: (context) => ListView.separated(
                padding: moeUnderBarPadding(
                  context,
                  MoeSettingsLayout.verticalListPadding,
                ),
                itemCount: pending.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: MoeSettingsLayout.sectionGap),
                itemBuilder: (_, index) {
                  final trigger = pending[index];
                  final statusColor = _colorForStatus(trigger.status, colors);
                  return MoeSettingsGroup(
                    padding: MoeSettingsLayout.contentPadding,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            trigger.title,
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight:
                                                  MoeFontWeights.emphasis,
                                              color: colors.text,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: MoeG2Decoration(
                                            radius: 12,
                                            color: statusColor.withValues(
                                              alpha: 0.12,
                                            ),
                                          ),
                                          child: Text(
                                            _labelForStatus(trigger.status),
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight:
                                                  MoeFontWeights.emphasis,
                                              color: statusColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '下次触发：${_formatDateTime(trigger.nextFireAt)}',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              MoeSecondaryButton(
                                label: '立即触发',
                                onPressed: () => controller.fireNow(trigger.id),
                                size: MoeSecondaryButtonSize.sm,
                              ),
                              MoeSecondaryButton(
                                label:
                                    trigger.status ==
                                        AutoReplyTriggerStatus.paused
                                    ? '恢复'
                                    : '暂停',
                                onPressed: () =>
                                    controller.togglePause(trigger.id),
                                size: MoeSecondaryButtonSize.sm,
                              ),
                              MoeIconButton(
                                icon: Icons.delete_outline,
                                onTap: () =>
                                    controller.deleteTrigger(trigger.id),
                                semanticLabel: '删除',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  String _eventText(AutoReplyTriggerEvent event) {
    switch (event.type) {
      case AutoReplyTriggerEventType.created:
        return '已创建：${event.title}';
      case AutoReplyTriggerEventType.fired:
        return '已触发：${event.title}';
      case AutoReplyTriggerEventType.deleted:
        return '已删除：${event.title}';
      case AutoReplyTriggerEventType.paused:
        return '已暂停：${event.title}';
      case AutoReplyTriggerEventType.resumed:
        return '已恢复：${event.title}';
      case AutoReplyTriggerEventType.expired:
        return '已过期：${event.title}${event.reason != null ? '（${event.reason}）' : ''}';
    }
  }

  /// 进行中的触发器用强调色，已结束的一律弱化。
  Color _colorForStatus(AutoReplyTriggerStatus status, MoeColors colors) {
    switch (status) {
      case AutoReplyTriggerStatus.created:
      case AutoReplyTriggerStatus.pending:
      case AutoReplyTriggerStatus.prepared:
        return colors.primary;
      case AutoReplyTriggerStatus.paused:
      case AutoReplyTriggerStatus.fired:
      case AutoReplyTriggerStatus.expired:
      case AutoReplyTriggerStatus.deleted:
        return colors.muted;
    }
  }

  String _labelForStatus(AutoReplyTriggerStatus status) {
    switch (status) {
      case AutoReplyTriggerStatus.created:
        return '已创建';
      case AutoReplyTriggerStatus.prepared:
        return '已就绪';
      case AutoReplyTriggerStatus.pending:
        return '等待触发';
      case AutoReplyTriggerStatus.paused:
        return '已暂停';
      case AutoReplyTriggerStatus.fired:
        return '已触发';
      case AutoReplyTriggerStatus.expired:
        return '已作废';
      case AutoReplyTriggerStatus.deleted:
        return '已删除';
    }
  }

  Widget _buildEmptyState() {
    return const Center(
      child: MoeEmptyState(
        icon: Icons.inbox_outlined,
        title: '目前没有待触发的提醒',
        description: 'AI 会在需要时自动创建，你也可以手动添加新的触发器。',
      ),
    );
  }

  String _formatDateTime(DateTime time) {
    final local = time.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }
}
