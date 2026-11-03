import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/chat_providers.dart';
import '../../../../features/chat/domain/model_request_error_report.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../theme/tokens.dart';

/// A live footer outside message bubbles and the display projection cache.
/// Only this small subtree subscribes to tool activity, retries and the
/// conversation's last failure reason.
class ChatToolActivityLine extends ConsumerWidget {
  const ChatToolActivityLine({
    super.key,
    required this.conversationId,
    required this.documentStyle,
  });

  /// The list's own conversation, so a split view never shows another
  /// conversation's tool.
  final String conversationId;
  final bool documentStyle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final retry = ref.watch(conversationRetryStatusProvider(conversationId));
    final activity = ref.watch(conversationToolActivityProvider(conversationId));
    final error = ref.watch(conversationErrorProvider(conversationId));
    final colors = context.moeColors;
    final (IconData icon, String text, Color color, int maxLines) =
        retry != null
        ? (
            Icons.refresh,
            '请求没成功，正在自动重试（第 ${retry.attempt} 次，共 ${retry.maxAttempts} 次）',
            colors.muted.withValues(alpha: 0.6),
            1,
          )
        : activity != null
        ? (
            Icons.build_outlined,
            '正在调用 $activity',
            colors.muted.withValues(alpha: 0.6),
            1,
          )
        : error != null && error.isNotEmpty
        ? (
            Icons.error_outline,
            ModelRequestErrorReport.brief(error),
            Theme.of(context).colorScheme.error,
            2,
          )
        : (Icons.circle, '', colors.muted, 0);
    if (maxLines == 0) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('tool-activity'),
      padding: EdgeInsets.only(
        left: documentStyle ? 16 : MessageBubble.contactContentInset,
        right: 16,
        top: 4,
        bottom: 4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 12, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
