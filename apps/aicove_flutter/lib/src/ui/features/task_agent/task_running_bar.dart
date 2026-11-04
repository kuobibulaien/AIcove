import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/task_agent/domain/agent_task.dart';
import '../../../features/task_agent/task_agent_providers.dart';
import '../../shared/widgets/index.dart';
import 'task_agent_pages.dart';

const _pollInterval = Duration(seconds: 2);

/// The quiet waiting line for a `delegate_task` errand while it is still
/// queued or running. The user can keep chatting meanwhile; once the task
/// settles the line disappears and the persona's own reply carries the result
/// (the receipt itself stays out of the chat).
class TaskRunningBar extends ConsumerStatefulWidget {
  const TaskRunningBar({
    super.key,
    required this.taskId,
    required this.textColor,
  });

  final String taskId;
  final Color textColor;

  @override
  ConsumerState<TaskRunningBar> createState() => _TaskRunningBarState();
}

class _TaskRunningBarState extends ConsumerState<TaskRunningBar>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncTimer(tickerEnabled: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer(tickerEnabled: TickerMode.valuesOf(context).enabled);
  }

  @override
  void didUpdateWidget(TaskRunningBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId) {
      _settled = false;
      _syncTimer(tickerEnabled: TickerMode.valuesOf(context).enabled);
    }
  }

  void _syncTimer({required bool tickerEnabled}) {
    if (!tickerEnabled || !_isForeground || _settled) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(_pollInterval, (_) => _poll());
  }

  /// Polling only makes sense while the app is visible; `null` means the
  /// binding has not reported a state yet, which is treated as foreground.
  bool get _isForeground => switch (WidgetsBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => false,
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncTimer(tickerEnabled: TickerMode.valuesOf(context).enabled);
    // Catch up at once on return instead of waiting for the next tick.
    if (state == AppLifecycleState.resumed && !_settled) _poll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  /// Re-reads the task while it is still pending; stops once it settles.
  void _poll() {
    final asyncTask = ref.read(agentTaskByIdProvider(widget.taskId));
    if (asyncTask.isLoading) return;
    final status = asyncTask.valueOrNull?.status;
    if (status != null && _isPending(status)) {
      ref.invalidate(agentTaskByIdProvider(widget.taskId));
    } else {
      _settled = true;
      _timer?.cancel();
      _timer = null;
    }
  }

  static bool _isPending(AgentTaskStatus status) =>
      status == AgentTaskStatus.queued || status == AgentTaskStatus.running;

  @override
  Widget build(BuildContext context) {
    final task = ref.watch(agentTaskByIdProvider(widget.taskId)).valueOrNull;
    if (task == null || !_isPending(task.status)) return const SizedBox.shrink();

    final color = widget.textColor;
    final label = task.status == AgentTaskStatus.queued ? '排队中' : '处理中';
    return Semantics(
      button: true,
      label: '后台任务$label，点击查看详情',
      child: InkWell(
        key: ValueKey('task-running-${widget.taskId}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => MoeWorkspace.open(
          context,
          TaskDetailPage(taskId: widget.taskId),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: color.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '后台$label…',
                  style: TextStyle(
                    color: color.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
