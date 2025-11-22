import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../data/auto_reply_trigger.dart';
import '../../data/auto_reply_trigger_controller.dart';
import '../widgets/auto_reply_trigger_form.dart';

class AutoReplyTriggerListPage extends ConsumerWidget {
  const AutoReplyTriggerListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<AutoReplyTriggerEvent?>(
      autoReplyTriggerEventProvider,
      (previous, next) {
        if (next == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_eventText(next))),
        );
        ref.read(autoReplyTriggerEventProvider.notifier).state = null;
      },
    );

    final triggersAsync = ref.watch(autoReplyTriggersProvider);
    final controller = ref.read(autoReplyTriggersProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('待触发列表'),
        backgroundColor: moeSurface,
        foregroundColor: moeText,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            height: borderWidth,
            color: moeBorderLight,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: moePrimary,
        onPressed: () => showCreateAutoReplyTriggerSheet(context, ref),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      backgroundColor: moeSurface,
      body: triggersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (triggers) {
          final pending = triggers
              .where((t) => t.status != AutoReplyTriggerStatus.completed)
              .toList()
            ..sort((a, b) => a.nextFireAt.compareTo(b.nextFireAt));
          if (pending.isEmpty) {
            return _buildEmptyState();
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: pending.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, index) {
              final trigger = pending[index];
              final statusColor = _colorForStatus(trigger.status);
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: moeSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: moeBorderLight),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.02),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
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
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: moeText,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding:
                                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: statusColor.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(12),
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
                                style: const TextStyle(fontSize: 13, color: moeTextSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => controller.fireNow(trigger.id),
                          icon: const Icon(Icons.flash_on, size: 18),
                          label: const Text('立即触发'),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: () => controller.togglePause(trigger.id),
                          icon: Icon(
                            trigger.status == AutoReplyTriggerStatus.paused
                                ? Icons.play_arrow
                                : Icons.pause,
                            size: 18,
                          ),
                          label: Text(trigger.status == AutoReplyTriggerStatus.paused ? '恢复' : '暂停'),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '删除',
                          onPressed: () => controller.deleteTrigger(trigger.id),
                          icon: const Icon(Icons.delete_outline),
                          color: moeMuted,
                        )
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

  Color _colorForStatus(AutoReplyTriggerStatus status) {
    switch (status) {
      case AutoReplyTriggerStatus.scheduled:
        return moePrimary;
      case AutoReplyTriggerStatus.paused:
        return moeMuted;
      case AutoReplyTriggerStatus.completed:
        return const Color(0xFF9E9E9E);
    }
  }

  String _labelForStatus(AutoReplyTriggerStatus status) {
    switch (status) {
      case AutoReplyTriggerStatus.scheduled:
        return '等待触发';
      case AutoReplyTriggerStatus.paused:
        return '已暂停';
      case AutoReplyTriggerStatus.completed:
        return '已完成';
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: moeBorderLight.withOpacity(0.4),
              borderRadius: BorderRadius.circular(36),
            ),
            child: const Icon(Icons.inbox_outlined, size: 32, color: moeMuted),
          ),
          const SizedBox(height: 12),
          const Text(
            '目前没有待触发的提醒',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: moeText),
          ),
          const SizedBox(height: 8),
          const Text(
            'AI 会在需要时自动创建，你也可以手动添加新的触发器。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: moeTextSecondary, height: 1.4),
          ),
        ],
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
