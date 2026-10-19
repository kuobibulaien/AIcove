import 'dart:async';

import '../../../core/app_logger.dart';
import '../../../core/models/message_block.dart';
import '../data/task_sync_scanner.dart';
import 'task_agent_service.dart';

/// Keeps the errand agent going in the foreground: recovery at start, then
/// a periodic pass that picks up receipts and controls from sync and retries
/// relays held back while the chat was generating.
class TaskAgentSupervisor {
  TaskAgentSupervisor({
    required this.service,
    required this.scanner,
    required this.loadBlocks,
    this.interval = const Duration(seconds: 60),
  });

  final Future<TaskAgentService> service;
  final TaskSyncScanner scanner;

  /// Blocks of a raw message; empty when it is gone.
  final Future<List<MessageBlock>> Function(String messageId) loadBlocks;
  final Duration interval;

  Timer? _timer;
  Future<void>? _scan;

  Future<void> start() async {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(scan()));
    try {
      await (await service).recover();
    } catch (error) {
      AppLogger.warning('TaskAgent', '杂活任务启动恢复失败', metadata: {
        'error': error.toString(),
      });
    }
    await scan();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass; overlapping calls share it.
  Future<void> scan() => _scan ??= _run().whenComplete(() => _scan = null);

  Future<void> _run() async {
    try {
      final tasks = await service;
      for (final (messageId, conversationId)
          in await scanner.receiptsWithoutDelivery()) {
        for (final block in await loadBlocks(messageId)) {
          if (block is TaskReceiptBlock && block.relays) {
            await tasks.store.addDelivery(
              receiptId: block.receiptId,
              taskId: block.taskId,
              conversationId: conversationId,
            );
          }
        }
      }
      for (final (messageId, conversationId)
          in await scanner.unconsumedControls()) {
        for (final block in await loadBlocks(messageId)) {
          if (block is! TaskControlBlock || !block.executable) continue;
          final task = await tasks.store.get(block.taskId);
          if (task == null || task.conversationId != conversationId) continue;
          switch (block.kind) {
            case TaskControlKind.reply:
              await tasks.reply(
                taskId: block.taskId,
                controlId: block.controlId,
                answersReceiptId: block.answersReceiptId,
                answer: block.text,
              );
            case TaskControlKind.cancel:
              await tasks.cancel(
                taskId: block.taskId,
                controlId: block.controlId,
              );
          }
        }
      }
      await tasks.deliverPending();
      await tasks.pump();
    } catch (error) {
      AppLogger.warning('TaskAgent', '杂活任务同步扫描失败', metadata: {
        'error': error.toString(),
      });
    }
  }
}
