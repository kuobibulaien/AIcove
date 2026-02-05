import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/chat/data/auto_reply_trigger.dart';
import '../../../../features/chat/data/auto_reply_trigger_controller.dart';
import '../../../../features/chat/presentation/widgets/auto_reply_trigger_form.dart';

class AutoReplyTriggerListPage extends ConsumerWidget {
  const AutoReplyTriggerListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;

    ref.listen<AutoReplyTriggerEvent?>(
      autoReplyTriggerEventProvider,
      (previous, next) {
        if (next == null) return;
        MoeToast.info(context, _eventText(next));
        ref.read(autoReplyTriggerEventProvider.notifier).state = null;
      },
    );

    final triggersAsync = ref.watch(autoReplyTriggersProvider);
    final controller = ref.read(autoReplyTriggersProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('待触发列表'),
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            height: borderWidth,
            color: colors.borderLight,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: colors.primary,
        onPressed: () => showCreateAutoReplyTriggerSheet(context, ref),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      backgroundColor: colors.surface,
      body: triggersAsync.when(
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
          final pending = triggers
              .where((t) => t.isActive || t.status == AutoReplyTriggerStatus.paused)
              .toList()
            ..sort((a, b) => a.nextFireAt.compareTo(b.nextFireAt));
          if (pending.isEmpty) {
            return _buildEmptyState(colors);
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: pending.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, index) {
              final trigger = pending[index];
              final statusColor = _colorForStatus(trigger.status, colors);
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: MoeG2Decoration(
                  radius: MoeSmoothRadii.sm,
                  color: colors.componentBackground,
                  border: Border.all(color: colors.borderLight),
                  boxShadow: MoeShadows.soft,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: MoeG2Decoration(
                            radius: 20,
                            color: statusColor.withValues(alpha: 0.12),
                          ),
                          child: Icon(
                            _iconForType(trigger.type),
                            color: statusColor,
                          ),
                        ),
                        const SizedBox(width: 12),
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
                                        fontWeight: FontWeight.w600,
                                        color: colors.text,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding:
                                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: MoeG2Decoration(
                                      radius: 12,
                                      color: statusColor.withValues(alpha: 0.12),
                                    ),
                                    child: Text(
                                      _labelForStatus(trigger.status),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: statusColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '下次触发：${_formatDateTime(trigger.nextFireAt)}',
                                style: TextStyle(fontSize: 13, color: colors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        MoeSecondaryButton(
                          label: '立即触发',
                          icon: Icons.flash_on,
                          onPressed: () => controller.fireNow(trigger.id),
                          size: MoeSecondaryButtonSize.sm,
                        ),
                        const SizedBox(width: 8),
                        MoeSecondaryButton(
                          label: trigger.status == AutoReplyTriggerStatus.paused ? '恢复' : '暂停',
                          icon: trigger.status == AutoReplyTriggerStatus.paused
                              ? Icons.play_arrow
                              : Icons.pause,
                          onPressed: () => controller.togglePause(trigger.id),
                          size: MoeSecondaryButtonSize.sm,
                        ),
                        const Spacer(),
                        MoeIconButton(
                          icon: Icons.delete_outline,
                          onTap: () => controller.deleteTrigger(trigger.id),
                          semanticLabel: '删除',
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
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
        return '已作废：${event.title}${event.reason != null ? '（${event.reason}）' : ''}';
    }
  }

  IconData _iconForType(AutoReplyTriggerType type) {
    switch (type) {
      case AutoReplyTriggerType.delay:
        return Icons.timer_outlined;
      case AutoReplyTriggerType.fixed:
        return Icons.alarm;
    }
  }

  Color _colorForStatus(AutoReplyTriggerStatus status, MoeColors colors) {
    switch (status) {
      case AutoReplyTriggerStatus.created:
      case AutoReplyTriggerStatus.pending:
        return colors.primary;
      case AutoReplyTriggerStatus.preparing:
        return const Color(0xFFFFA726); // 橙色，正在准备
      case AutoReplyTriggerStatus.prepared:
        return const Color(0xFF66BB6A); // 绿色，就绪
      case AutoReplyTriggerStatus.paused:
        return colors.muted;
      case AutoReplyTriggerStatus.fired:
        return const Color(0xFF9E9E9E);
      case AutoReplyTriggerStatus.expired:
        return const Color(0xFFEF5350); // 红色，已作废
      case AutoReplyTriggerStatus.deleted:
        return const Color(0xFF9E9E9E);
    }
  }

  String _labelForStatus(AutoReplyTriggerStatus status) {
    switch (status) {
      case AutoReplyTriggerStatus.created:
        return '已创建';
      case AutoReplyTriggerStatus.preparing:
        return '准备中';
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

  Widget _buildEmptyState(MoeColors colors) {
    return Center(
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
