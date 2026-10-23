import 'package:flutter/material.dart';

import 'chat_message_list_items.dart';

/// One muted line under a reply that ended early, styled like the errand
/// waiting bar so both read as the run's state rather than the persona's words.
class ChatRunStatusLine extends StatelessWidget {
  const ChatRunStatusLine({
    super.key,
    required this.status,
    required this.textColor,
  });

  final ChatRunStatus status;
  final Color textColor;

  IconData get _icon => switch (status) {
    ChatRunStatus.truncated => Icons.content_cut,
    ChatRunStatus.waitingForUser => Icons.help_outline,
    ChatRunStatus.cancelled => Icons.stop_circle_outlined,
    ChatRunStatus.failed => Icons.error_outline,
  };

  @override
  Widget build(BuildContext context) {
    final color = textColor.withValues(alpha: 0.6);
    return Semantics(
      label: status.label,
      child: Padding(
        key: ValueKey('run-status-${status.name}'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 12, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                status.label,
                style: TextStyle(color: color, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
