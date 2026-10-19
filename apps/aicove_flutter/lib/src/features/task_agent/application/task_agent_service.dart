import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation, KernelCancelledException;

import '../../../core/app_logger.dart';
import '../../../core/models/message_block.dart';
import '../data/agent_task_store.dart';
import '../data/task_process_record.dart';
import '../domain/agent_task.dart';
import 'task_agent_runner.dart';

typedef ResolveTaskCapabilities =
    Future<TaskAgentCapabilities> Function(
      AgentTask task,
      String runId,
      KernelCancellation cancellation,
    );

/// Writes a receipt as a chat message; called again with the same id after
/// a crash, so it must replace, not duplicate.
typedef WriteTaskReceipt = Future<void> Function(RecordedReceipt receipt);

/// Relays a receipt to the user in persona; false to retry later.
typedef RelayTaskReceipt =
    Future<bool> Function(String conversationId, TaskReceiptBlock receipt);

/// Result of `reply` / `cancel` on this device.
enum TaskControlOutcome {
  /// Applied to a task this device executes.
  applied,

  /// The task runs on another device; the caller stores a control event.
  remote,

  /// Not applicable (wrong state, unknown question, consumed before).
  ignored,
}

/// Runs errand tasks on the device that started them (ADR0088 §2–8):
/// queueing with a per-device limit, the state machine with receipts,
/// replies, cancellation, startup recovery and the kill switch. Lives in the
/// foreground isolate only.
class TaskAgentService {
  TaskAgentService({
    required this.store,
    required this.process,
    required this.runner,
    required this.capabilities,
    required this.writeReceipt,
    required this.relay,
    required this.findReceipt,
    required this.ownsConversation,
    required this.deviceId,
    this.preset = const TaskAgentPreset(),
    this.maxConcurrent = 3,
    String Function()? newId,
  }) : _newId = newId ?? _defaultId;

  final AgentTaskStore store;
  final TaskProcessRecord process;
  final TaskAgentRunner runner;
  final ResolveTaskCapabilities capabilities;
  final WriteTaskReceipt writeReceipt;
  final RelayTaskReceipt relay;

  /// Reads a receipt back from its written message (also one that arrived
  /// through sync); null when the message is not here yet.
  final Future<TaskReceiptBlock?> Function(String receiptId) findReceipt;
  final Future<bool> Function(String conversationId) ownsConversation;
  final Future<String> Function() deviceId;
  final TaskAgentPreset preset;
  final int maxConcurrent;
  final String Function() _newId;

  final Map<String, KernelCancellation> _running = {};
  final Map<String, Future<void>> _runs = {};
  final Set<String> _relaying = {};
  Future<void>? _pump;
  bool _pumpAgain = false;

  static int _counter = 0;
  static String _defaultId() =>
      'task_${DateTime.now().microsecondsSinceEpoch}_${_counter++}';

  /// Ids of tasks running on this device right now.
  Set<String> get running => Set.unmodifiable(_running.keys);

  /// Persists a queued task first, then schedules it; the same [requestKey]
  /// returns the task created before.
  Future<AgentTask> start({
    required String conversationId,
    required String instruction,
    String? requestKey,
    AgentTaskSource source = AgentTaskSource.chat,
    TaskReceiptNotify notify = TaskReceiptNotify.always,
  }) async {
    final (task, created) = await store.create(
      id: _newId(),
      requestKey: requestKey,
      conversationId: conversationId,
      instruction: instruction,
      source: source,
      notify: notify,
    );
    if (created) {
      await process.saveCheckpoint(
        task.id,
        TaskCheckpoint(transcript: TaskAgentRunner.firstTranscript(instruction)),
      );
    }
    await pump();
    return task;
  }

  /// Answers the open question of a waiting task.
  Future<TaskControlOutcome> reply({
    required String taskId,
    required String controlId,
    required String? answersReceiptId,
    required String answer,
  }) async {
    final task = await store.get(taskId);
    if (task == null) return TaskControlOutcome.remote;
    final checkpoint = await process.checkpoint(taskId);
    if (!await store.consumeReply(
      controlId: controlId,
      taskId: taskId,
      answersReceiptId: answersReceiptId,
    )) {
      return TaskControlOutcome.ignored;
    }
    if (checkpoint != null) {
      await process.saveCheckpoint(
        taskId,
        TaskCheckpoint(
          transcript: TaskAgentRunner.continueTranscript(
            previous: checkpoint.transcript,
            processLog: checkpoint.lastLog,
            question: checkpoint.question ?? '',
            answer: answer,
          ),
        ),
      );
    }
    await pump();
    return TaskControlOutcome.applied;
  }

  /// Cancels a queued, waiting or running task. A running one stops at the
  /// next check; its receipt is written once in-flight work has settled.
  Future<TaskControlOutcome> cancel({
    required String taskId,
    required String controlId,
  }) async {
    if (await store.get(taskId) == null) return TaskControlOutcome.remote;
    final task = await store.consumeCancel(controlId: controlId, taskId: taskId);
    if (task == null || task.status.isTerminal) return TaskControlOutcome.ignored;
    final running = _running[taskId];
    if (running != null) {
      running.cancel();
      await _runs[taskId];
      return TaskControlOutcome.applied;
    }
    final recorded = await store.finish(
      taskId,
      from: {AgentTaskStatus.queued, AgentTaskStatus.needsInput},
      to: AgentTaskStatus.cancelled,
      executorDevice: await deviceId(),
      summary: '任务已取消。',
    );
    if (recorded != null) await _publish(recorded);
    return TaskControlOutcome.applied;
  }

  /// Startup: interrupted runs get a receipt without replaying anything,
  /// unwritten receipts are written, queued tasks run and pending relays go
  /// out. Call once, before any task runs.
  Future<void> recover() async {
    await store.releaseStaleClaims();
    final device = await deviceId();
    for (final task in await store.byStatus(AgentTaskStatus.running)) {
      if (_running.containsKey(task.id)) continue;
      await store.finish(
        task.id,
        from: {AgentTaskStatus.running},
        to: AgentTaskStatus.interrupted,
        executorDevice: device,
        summary: '应用关闭时任务正在执行，已中断；做到一半的操作没有自动重做。',
      );
    }
    for (final receipt in await store.unwrittenReceipts()) {
      await _publish(receipt, relayNow: false);
    }
    await pump();
    await deliverPending();
  }

  /// Kill switch (ADR0088 §8). Off: running tasks are cancelled, queued and
  /// waiting ones frozen, relays and new runs stop. On: frozen tasks stay
  /// frozen until resumed by hand.
  Future<void> setEnabled(bool enabled) async {
    await store.setSwitch(enabled);
    if (!enabled) {
      for (final cancellation in _running.values) {
        cancellation.cancel();
      }
      await Future.wait(_runs.values);
    } else {
      await pump();
      await deliverPending();
    }
  }

  Future<bool> get enabled async => (await store.readSwitch()).$1;

  /// Lets a frozen task continue.
  Future<void> resume(String taskId) async {
    await store.unfreeze(taskId);
    await pump();
  }

  /// Starts queued tasks up to [maxConcurrent]; returns once they are
  /// started, not finished. Calls during a pass make it run once more.
  Future<void> pump() {
    final current = _pump;
    if (current != null) {
      _pumpAgain = true;
      return current;
    }
    return _pump = _drain().whenComplete(() => _pump = null);
  }

  Future<void> _drain() async {
    do {
      _pumpAgain = false;
      if (!await enabled) return;
      for (final task in await store.runnable()) {
        if (_running.length >= maxConcurrent) break;
        if (_running.containsKey(task.id)) continue;
        if (!await store.markRunning(task.id)) continue;
        final cancellation = KernelCancellation();
        _running[task.id] = cancellation;
        _runs[task.id] = _execute(task, cancellation).whenComplete(() {
          _running.remove(task.id);
          _runs.remove(task.id);
          unawaited(pump());
        });
      }
    } while (_pumpAgain);
  }

  /// Waits for everything started so far (tests).
  Future<void> idle() async {
    while (_pump != null || _runs.isNotEmpty) {
      await _pump;
      await Future.wait(_runs.values.toList());
    }
  }

  Future<void> _execute(AgentTask task, KernelCancellation cancellation) async {
    final runIndex = task.receiptSeq + 1;
    final runId = '${task.id}:$runIndex';
    final device = await deviceId();
    RecordedReceipt? recorded;
    try {
      final checkpoint =
          await process.checkpoint(task.id) ??
          TaskCheckpoint(
            transcript: TaskAgentRunner.firstTranscript(task.instruction),
          );
      final outcome = await runner.run(
        taskId: task.id,
        runId: runId,
        transcript: checkpoint.transcript,
        capabilities: await capabilities(task, runId, cancellation),
        preset: preset,
        cancellation: cancellation,
        onExternalStart: () => unawaited(store.markSideEffectUncertain(task.id)),
      );
      // The checkpoint goes first, so a reply after a crash still continues
      // from this run.
      await process.appendLog(task.id, '第 $runIndex 轮', outcome.processLog);
      await process.saveCheckpoint(
        task.id,
        TaskCheckpoint(
          transcript: checkpoint.transcript,
          lastLog: outcome.processLog,
          question: outcome.question,
        ),
      );
      recorded = await store.finish(
        task.id,
        from: {AgentTaskStatus.running},
        to: outcome.question == null
            ? AgentTaskStatus.done
            : AgentTaskStatus.needsInput,
        executorDevice: device,
        summary: outcome.summary,
        question: outcome.question,
        artifacts: outcome.artifacts,
      );
    } on KernelCancelledException {
      recorded = await store.finish(
        task.id,
        from: {AgentTaskStatus.running},
        to: AgentTaskStatus.cancelled,
        executorDevice: device,
        summary: '任务已取消。',
      );
    } catch (error, stack) {
      AppLogger.warning('TaskAgent', '杂活任务执行失败', metadata: {
        'task': task.id,
        'error': error.toString(),
        'stack': stack.toString().split('\n').take(4).join(' | '),
      });
      recorded = await store.finish(
        task.id,
        from: {AgentTaskStatus.running},
        to: AgentTaskStatus.failed,
        executorDevice: device,
        summary: '任务出错：${_brief(error)}',
      );
    }
    if (recorded != null) await _publish(recorded);
  }

  /// Writes the receipt message, then relays it when this device should.
  Future<void> _publish(RecordedReceipt recorded, {bool relayNow = true}) async {
    try {
      await writeReceipt(recorded);
      await store.markReceiptWritten(recorded.task.id, recorded.block.receiptId);
    } catch (error) {
      // Stays in the outbox; recovery writes it on the next start.
      AppLogger.warning('TaskAgent', '回执消息写入失败，下次启动补写', metadata: {
        'task': recorded.task.id,
        'error': error.toString(),
      });
      return;
    }
    if (relayNow && recorded.block.relays) {
      await deliver(recorded.block.receiptId, recorded.block);
    }
  }

  /// Relays every pending receipt this device is responsible for.
  Future<void> deliverPending() async {
    for (final receiptId in await store.pendingDeliveries()) {
      await deliver(receiptId);
    }
  }

  /// Relays one receipt if this device owns its conversation (ADR0084);
  /// otherwise it stays pending for the owner to pick up through sync.
  Future<void> deliver(String receiptId, [TaskReceiptBlock? block]) async {
    if (!await enabled || !_relaying.add(receiptId)) return;
    try {
      final target = await store.delivery(receiptId);
      if (target == null) return;
      final (taskId, conversationId) = target;
      if (!await ownsConversation(conversationId)) return;
      final receipt = block ?? await _receiptFromTask(taskId, receiptId);
      if (receipt == null) return;
      if (!await store.claimDelivery(receiptId)) return;
      var delivered = false;
      try {
        delivered = await relay(conversationId, receipt);
      } catch (error) {
        AppLogger.warning('TaskAgent', '回执转告失败，稍后重试', metadata: {
          'receipt': receiptId,
          'error': error.toString(),
        });
      }
      await store.completeDelivery(receiptId, delivered: delivered);
    } finally {
      _relaying.remove(receiptId);
    }
  }

  Future<TaskReceiptBlock?> _receiptFromTask(
    String taskId,
    String receiptId,
  ) async {
    for (final receipt in await store.unwrittenReceipts()) {
      if (receipt.block.receiptId == receiptId) return receipt.block;
    }
    return findReceipt(receiptId);
  }

  static String _brief(Object error) {
    final text = error.toString();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}
