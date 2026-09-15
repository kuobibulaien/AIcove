import '../../../core/models/message_block.dart';
import '../domain/message.dart';
import '../id_gen.dart';

/// Copies the selected visible records into one durable, attributed user turn.
Message buildForwardedChatMessage({
  required String sourceTitle,
  required List<Message> messages,
  required String note,
}) {
  if (messages.isEmpty) throw StateError('请先选择消息');
  final id = genId('forward');
  final record = ChatRecordBlock(
    messageId: id,
    sourceName: sourceTitle,
    entries: messages
        .map(
          (message) => ChatRecordEntry(
            sender: message.role == 'user' ? '用户' : sourceTitle,
            isUser: message.role == 'user',
            text: message.displayText,
            createdAt: message.createdAt,
            blocks: [
              for (final block in message.blocks ?? <MessageBlock>[])
                MessageBlock.fromJson({
                  ...block.toJson(),
                  'id': genId('forward_block'),
                  'messageId': id,
                }),
            ],
          ),
        )
        .toList(),
  );
  final blocks = <MessageBlock>[
    record,
    if (note.trim().isNotEmpty) TextBlock(messageId: id, content: note.trim()),
  ];
  return Message(
    id: id,
    role: 'user',
    content: blocks
        .whereType<TextBlock>()
        .map((block) => block.content)
        .join('\n\n'),
    blocks: blocks,
    createdAt: DateTime.now(),
    status: 'sending',
  );
}
