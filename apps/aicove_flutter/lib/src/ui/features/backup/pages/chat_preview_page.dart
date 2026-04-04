import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/services/chat_history_store.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';

final _chatPreviewMessagesProvider =
    FutureProvider.family<List<Message>, String>((ref, conversationId) {
  return ref
      .read(chatHistoryStoreProvider)
      .loadProjectedMessagesFromRawStore(conversationId);
});

/// 只读聊天预览页面
class ChatPreviewPage extends ConsumerWidget {
  final Conversation conversation;

  const ChatPreviewPage({
    super.key,
    required this.conversation,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final messagesAsync =
        ref.watch(_chatPreviewMessagesProvider(conversation.id));

    return Scaffold(
      appBar: MoeAppBar(
        title: '${conversation.displayName} 聊天预览',
        showBackButton: true,
      ),
      body: Column(
        children: [
          // 只读提示
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  LucideIcons.eye,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  messagesAsync.when(
                    data: (messages) => '只读预览模式 · ${messages.length} 条消息',
                    loading: () => '只读预览模式 · 加载中',
                    error: (_, __) => '只读预览模式 · 加载失败',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          // 消息列表
          Expanded(
            child: messagesAsync.when(
              loading: () => const Center(child: MoeLoadingIndicator()),
              error: (e, _) => Center(child: Text('加载失败: $e')),
              data: (messages) {
                if (messages.isEmpty) {
                  return const MoeEmptyState(
                    icon: LucideIcons.messageSquare,
                    title: '暂无消息',
                    description: '该角色还没有聊天记录',
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return _buildMessageBubble(context, message);
                  },
                );
              },
            ),
          ),

          // 底部提示（没有输入框）
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.1),
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  LucideIcons.lock,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  '预览模式下无法发送消息',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(BuildContext context, Message message) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            // AI 头像
            CircleAvatar(
              radius: 16,
              backgroundImage: conversation.avatarUrl != null &&
                      conversation.avatarUrl!.isNotEmpty
                  ? (conversation.avatarUrl!.startsWith('assets/')
                      ? AssetImage(conversation.avatarUrl!) as ImageProvider
                      : FileImage(File(conversation.avatarUrl!)))
                  : null,
              child: conversation.avatarUrl == null ||
                      conversation.avatarUrl!.isEmpty
                  ? Text(
                      conversation.displayName.isNotEmpty
                          ? conversation.displayName[0]
                          : '?',
                      style: const TextStyle(fontSize: 12),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
          ],

          // 消息气泡
          Flexible(
            child: Builder(
              builder: (context) {
                final bubbleBorderRadius = SmoothBorderRadius.only(
                  topLeft: SmoothRadius(
                      cornerRadius: isUser ? 16 : 4, cornerSmoothing: 0.6),
                  topRight: SmoothRadius(
                      cornerRadius: isUser ? 4 : 16, cornerSmoothing: 0.6),
                  bottomLeft: const SmoothRadius(
                      cornerRadius: 16, cornerSmoothing: 0.6),
                  bottomRight: const SmoothRadius(
                      cornerRadius: 16, cornerSmoothing: 0.6),
                );

                return MoeG2ClipRRect.borderRadius(
                  borderRadius: bubbleBorderRadius,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.7,
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: MoeG2Decoration.borderRadius(
                      borderRadius: bubbleBorderRadius,
                      color: isUser
                          ? theme.colorScheme.primary
                          : theme.colorScheme.surfaceContainerHighest,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 文本内容
                        Text(
                          message.displayText,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: isUser
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.onSurface,
                          ),
                        ),

                        // 时间戳
                        const SizedBox(height: 4),
                        Text(
                          _formatTime(message.createdAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 10,
                            color: isUser
                                ? theme.colorScheme.onPrimary
                                    .withValues(alpha: 0.7)
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          if (isUser) ...[
            const SizedBox(width: 8),
            // 用户头像
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                LucideIcons.user,
                size: 16,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inDays > 0) {
      return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
