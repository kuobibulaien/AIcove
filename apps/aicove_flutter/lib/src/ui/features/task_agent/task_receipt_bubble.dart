import 'package:flutter/material.dart';

import '../../../core/models/message_block.dart';
import '../../shared/widgets/index.dart';
import 'task_agent_pages.dart';

/// A task receipt in the chat: status, summary and, for a question, what
/// the background helper asked. Opens the task (ADR0088 §4).
class TaskReceiptBubble extends StatelessWidget {
  const TaskReceiptBubble({
    super.key,
    required this.receipt,
    required this.textColor,
  });

  final TaskReceiptBlock receipt;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final status = taskReceiptStatusLabel(receipt.receiptStatus);
    final muted = textColor.withValues(alpha: 0.75);
    return Semantics(
      button: true,
      label: '后台任务$status，点击查看详情',
      child: InkWell(
        key: ValueKey('task-receipt-${receipt.receiptId}'),
        onTap: () => MoeWorkspace.open(
          context,
          TaskDetailPage(taskId: receipt.taskId, receipt: receipt),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: textColor.withValues(alpha: 0.12),
                ),
                child: Icon(_icon, size: 18, color: textColor),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '后台任务 · $status',
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (receipt.summary.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        receipt.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: muted, fontSize: 13),
                      ),
                    ],
                    if (receipt.question case final question?) ...[
                      const SizedBox(height: 2),
                      Text(
                        '问：$question',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: textColor, fontSize: 13),
                      ),
                    ],
                    if (receipt.artifacts.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        '改动了 ${receipt.artifacts.length} 个文件',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                    if (receipt.sideEffectUncertain) ...[
                      const SizedBox(height: 2),
                      Text(
                        '外部请求可能已经生效',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }

  IconData get _icon => switch (receipt.receiptStatus) {
    TaskReceiptStatus.done => Icons.task_alt,
    TaskReceiptStatus.failed => Icons.error_outline,
    TaskReceiptStatus.needsInput => Icons.help_outline,
    TaskReceiptStatus.cancelled => Icons.block,
    TaskReceiptStatus.interrupted => Icons.pause_circle_outline,
  };
}
