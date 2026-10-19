import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/task_agent/domain/agent_task.dart';
import '../../../features/task_agent/task_agent_providers.dart';
import '../../../core/models/message_block.dart';
import '../../shared/widgets/index.dart';
import '../../theme/tokens.dart';

String agentTaskStatusLabel(AgentTaskStatus status) => switch (status) {
  AgentTaskStatus.queued => '排队中',
  AgentTaskStatus.running => '进行中',
  AgentTaskStatus.needsInput => '等你回答',
  AgentTaskStatus.done => '已完成',
  AgentTaskStatus.failed => '失败',
  AgentTaskStatus.cancelled => '已取消',
  AgentTaskStatus.interrupted => '已中断',
};

String taskReceiptStatusLabel(TaskReceiptStatus status) => switch (status) {
  TaskReceiptStatus.done => '已完成',
  TaskReceiptStatus.failed => '失败',
  TaskReceiptStatus.needsInput => '需要你回答',
  TaskReceiptStatus.cancelled => '已取消',
  TaskReceiptStatus.interrupted => '已中断',
};

/// Background tasks of this device with the kill switch (ADR0088 §8).
class TaskListPage extends ConsumerWidget {
  const TaskListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final tasks = ref.watch(agentTaskListProvider);
    final enabled = ref.watch(taskAgentEnabledProvider).valueOrNull ?? true;
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '后台任务', showBackButton: true),
      body: MoeSettingsContent(
        child: Builder(
          builder: (bodyContext) => ListView(
            padding: moeUnderBarPadding(
              bodyContext,
              MoeSettingsLayout.verticalListPadding,
            ),
            children: [
              MoeSettingsGroup(
                children: [
                  MoeSettingsRow(
                    key: const ValueKey('task-agent-switch'),
                    icon: Icons.power_settings_new,
                    label: '允许后台办事',
                    subtitle: enabled
                        ? '角色可以把查资料、整理文件交给后台助手'
                        : '已关闭：新任务不会执行，等待中的任务已冻结',
                    trailingType: MoeSettingsRowTrailing.switchControl,
                    switchValue: enabled,
                    onSwitchChanged: (value) => _setEnabled(ref, value),
                    showDivider: false,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              tasks.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => MoeEmptyState(
                  icon: Icons.error_outline,
                  title: '任务加载失败',
                  description: '$error',
                ),
                data: (items) => items.isEmpty
                    ? const MoeEmptyState(
                        icon: Icons.task_alt,
                        title: '还没有后台任务',
                        description: '聊天时让角色帮你查东西，就会出现在这里。',
                      )
                    : MoeSettingsGroup(
                        children: [
                          for (final (index, task) in items.indexed)
                            MoeSettingsRow(
                              key: ValueKey('task-${task.id}'),
                              icon: _iconOf(task.status),
                              label: task.instruction,
                              labelMaxLines: 1,
                              subtitle: [
                                agentTaskStatusLabel(task.status),
                                if (task.frozen) '已冻结',
                              ].join(' · '),
                              showDivider: index < items.length - 1,
                              onTap: () => MoeWorkspace.open(
                                context,
                                TaskDetailPage(taskId: task.id),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _setEnabled(WidgetRef ref, bool value) async {
    final service = await ref.read(taskAgentServiceProvider.future);
    await service.setEnabled(value);
    ref
      ..invalidate(taskAgentEnabledProvider)
      ..invalidate(agentTaskListProvider);
  }
}

typedef _TaskDetail = ({
  AgentTask? task,
  String? log,
  TaskReceiptBlock? receipt,
});

IconData _iconOf(AgentTaskStatus status) => switch (status) {
  AgentTaskStatus.queued => Icons.schedule,
  AgentTaskStatus.running => Icons.autorenew,
  AgentTaskStatus.needsInput => Icons.help_outline,
  AgentTaskStatus.done => Icons.task_alt,
  AgentTaskStatus.failed => Icons.error_outline,
  AgentTaskStatus.cancelled => Icons.block,
  AgentTaskStatus.interrupted => Icons.pause_circle_outline,
};

/// One task: on the executing device its state, actions and full process;
/// elsewhere only its newest receipt in the chat history.
class TaskDetailPage extends ConsumerStatefulWidget {
  const TaskDetailPage({super.key, required this.taskId, this.receipt});

  final String taskId;
  final TaskReceiptBlock? receipt;

  @override
  ConsumerState<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends ConsumerState<TaskDetailPage> {
  late Future<_TaskDetail> _data = _load();

  Future<_TaskDetail> _load() async {
    final service = await ref.read(taskAgentServiceProvider.future);
    final task = await service.store.get(widget.taskId);
    final receipt =
        await service.store.latestReceipt(widget.taskId) ?? widget.receipt;
    return (
      task: task,
      log: task == null ? null : await service.process.log(task.id),
      receipt: receipt,
    );
  }

  void _reload() {
    ref.invalidate(agentTaskListProvider);
    setState(() {
      _data = _load();
    });
  }

  Future<void> _cancel() async {
    final service = await ref.read(taskAgentServiceProvider.future);
    await service.cancel(
      taskId: widget.taskId,
      controlId: 'ctl_ui_${DateTime.now().microsecondsSinceEpoch}',
    );
    if (mounted) _reload();
  }

  Future<void> _resume() async {
    final service = await ref.read(taskAgentServiceProvider.future);
    await service.resume(widget.taskId);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '任务详情', showBackButton: true),
      body: FutureBuilder<_TaskDetail>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return MoeEmptyState(
              icon: Icons.error_outline,
              title: '读取失败',
              description: '${snapshot.error}',
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final (:task, :log, :receipt) = data;
          return ListView(
            padding: moeUnderBarPadding(context, const EdgeInsets.all(16)),
            children: [
              if (task != null) ...[
                _section(colors, '任务', task.instruction),
                _section(
                  colors,
                  '状态',
                  [
                    agentTaskStatusLabel(task.status),
                    if (task.frozen) '已冻结（后台办事关闭时停下，需要手动继续）',
                    if (task.sideEffectUncertain) '外部请求可能已经生效',
                  ].join('\n'),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (!task.status.isTerminal)
                      MoeSecondaryButton(
                        key: const ValueKey('task-cancel'),
                        label: '取消任务',
                        onPressed: _cancel,
                      ),
                    if (task.frozen && !task.status.isTerminal)
                      MoeSecondaryButton(
                        key: const ValueKey('task-resume'),
                        label: '继续',
                        onPressed: _resume,
                      ),
                  ],
                ),
              ] else ...[
                _section(colors, '说明', '这个任务在另一台设备上执行，这里只有回执。'),
                // ADR0088 §6: an open task whose executor we cannot see.
                if (receipt != null &&
                    receipt.receiptStatus == TaskReceiptStatus.needsInput)
                  _section(
                    colors,
                    '状态',
                    '执行设备离线或未同步\n回答或取消会在它上线后处理。',
                  ),
              ],
              if (receipt != null) ...[
                _section(
                  colors,
                  '回执 · ${taskReceiptStatusLabel(receipt.receiptStatus)}',
                  [
                    if (receipt.summary.isNotEmpty) receipt.summary,
                    if (receipt.question != null) '问题：${receipt.question}',
                    for (final artifact in receipt.artifacts)
                      '文件：${artifact.path}',
                  ].join('\n'),
                ),
              ],
              if (log != null && log.isNotEmpty) _section(colors, '完整过程', log),
            ],
          );
        },
      ),
    );
  }

  Widget _section(MoeColors colors, String title, String body) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: MoeFontWeights.emphasis,
            color: colors.primary,
          ),
        ),
        const SizedBox(height: 6),
        SelectableText(body, style: const TextStyle(height: 1.5)),
      ],
    ),
  );
}
