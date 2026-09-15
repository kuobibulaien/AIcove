import 'package:flutter/material.dart';

import '../../../../core/models/message_block.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../domain/message.dart';
import 'message_bubble.dart';

class ChatRecordBubble extends StatelessWidget {
  const ChatRecordBubble({
    super.key,
    required this.record,
    required this.textColor,
  });

  final ChatRecordBlock record;
  final Color textColor;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '用户与${record.sourceName}的聊天记录，${record.entries.length}条，点击查看',
    child: InkWell(
      key: ValueKey('chat-record-${record.id}'),
      onTap: () => MoeWorkspace.open(context, ChatRecordPage(record: record)),
      child: SizedBox(
        width: 260,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '与${record.sourceName}的聊天记录',
              style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            for (final entry in record.entries.take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${entry.sender}：${entry.text}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.8),
                    fontSize: 13,
                  ),
                ),
              ),
            Divider(color: textColor.withValues(alpha: 0.18)),
            Text(
              '聊天记录 · ${record.entries.length} 条',
              style: TextStyle(
                color: textColor.withValues(alpha: 0.8),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class ChatRecordPage extends StatelessWidget {
  const ChatRecordPage({super.key, required this.record});
  final ChatRecordBlock record;

  @override
  Widget build(BuildContext context) => MoePageScaffold(
    appBar: MoeAppBar(
      title: '与${record.sourceName}的聊天记录',
      showBackButton: true,
    ),
    body: ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: record.entries.length,
      itemBuilder: (context, index) {
        final entry = record.entries[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: MessageBubble(
            isMe: entry.isUser,
            displayName: entry.sender,
            showName: true,
            message: Message(
              id: '${record.id}_$index',
              role: entry.isUser ? 'user' : 'assistant',
              content: entry.text,
              blocks: entry.blocks,
              createdAt: entry.createdAt,
            ),
          ),
        );
      },
    ),
  );
}
