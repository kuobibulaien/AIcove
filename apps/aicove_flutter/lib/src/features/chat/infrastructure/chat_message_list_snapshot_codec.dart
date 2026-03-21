import '../../../core/models/message_block.dart';
import '../application/chat_message_list_queries.dart';
import '../domain/message.dart';
import '../../../ui/features/chat/widgets/chat_message_list_items.dart';

class ChatMessageListSnapshotData {
  const ChatMessageListSnapshotData({
    required this.items,
    required this.messages,
    required this.hasMoreMessages,
    required this.visibleTurnCount,
    this.lastMessagePreview,
    this.lastMessageTime,
  });

  final List<ChatMessageListItem> items;
  final List<Message> messages;
  final bool hasMoreMessages;
  final int visibleTurnCount;
  final String? lastMessagePreview;
  final DateTime? lastMessageTime;
}

List<Map<String, dynamic>> serializeChatMessageListSnapshot({
  required List<ChatMessageListItem> listItems,
  required List<Message> sourceMessages,
  required int visibleTurnCount,
  required bool hasMoreMessages,
}) {
  final lastMessage = sourceMessages.isNotEmpty ? sourceMessages.last : null;
  return [
    <String, dynamic>{
      'type': 'meta',
      'hasMoreMessages': hasMoreMessages,
      'visibleTurnCount': visibleTurnCount,
      'lastMessagePreview': lastMessage?.displayText,
      'lastMessageTime': lastMessage?.createdAt.millisecondsSinceEpoch,
    },
    for (final item in listItems)
      if (item is ChatTimeDividerItem)
        <String, dynamic>{
          'type': 'time',
          'time': item.time.millisecondsSinceEpoch,
        }
      else if (item is ChatNewTopicDividerItem)
        const <String, dynamic>{'type': 'new_topic'}
      else if (item is ChatMessageItem)
        <String, dynamic>{
          'type': 'message',
          'messageId': item.message.id,
          'message': _serializeMessage(item.message),
          'showCorner': item.showCorner,
          'showAvatar': item.showAvatar,
        }
      else if (item is ChatChunkedMessageItem)
        <String, dynamic>{
          'type': 'chunk',
          'messageId': item.originalMessage.id,
          'message': _serializeMessage(item.originalMessage),
          'chunkText': item.chunkText,
          'chunkIndex': item.chunkIndex,
          'totalChunks': item.totalChunks,
          'showCorner': item.showCorner,
          'showAvatar': item.showAvatar,
        },
  ];
}

ChatMessageListSnapshotData? deserializeChatMessageListSnapshot(
  List<Map<String, dynamic>> rawItems, {
  required List<Message> liveMessages,
}) {
  final messagesById = <String, Message>{
    for (final message in liveMessages) message.id: message,
  };
  final restored = <ChatMessageListItem>[];
  final restoredMessages = <String, Message>{};
  var hasMoreMessages = true;
  var visibleTurnCount = 0;
  String? lastMessagePreview;
  DateTime? lastMessageTime;

  for (final raw in rawItems) {
    final type = raw['type'] as String?;
    switch (type) {
      case 'meta':
        hasMoreMessages = raw['hasMoreMessages'] != false;
        visibleTurnCount = _readInt(raw['visibleTurnCount']) ??
            _readInt(raw['visibleMessageCount']) ??
            0;
        lastMessagePreview = raw['lastMessagePreview'] as String?;
        final rawTime = _readInt(raw['lastMessageTime']);
        if (rawTime != null) {
          lastMessageTime = DateTime.fromMillisecondsSinceEpoch(rawTime);
        }
        break;
      case 'time':
        final timestamp = _readInt(raw['time']);
        if (timestamp == null) {
          return null;
        }
        restored.add(ChatTimeDividerItem(
            DateTime.fromMillisecondsSinceEpoch(timestamp)));
        break;
      case 'new_topic':
        restored.add(const ChatNewTopicDividerItem());
        break;
      case 'message':
        final messageId = raw['messageId'] as String?;
        final message = _resolvePersistentMessage(
          raw['message'],
          messageId: messageId,
          liveMessagesById: messagesById,
          restoredMessagesById: restoredMessages,
        );
        if (message == null) {
          return null;
        }
        restored.add(
          ChatMessageItem(
            message,
            showCorner: raw['showCorner'] == true,
            showAvatar: raw['showAvatar'] != false,
          ),
        );
        break;
      case 'chunk':
        final messageId = raw['messageId'] as String?;
        final message = _resolvePersistentMessage(
          raw['message'],
          messageId: messageId,
          liveMessagesById: messagesById,
          restoredMessagesById: restoredMessages,
        );
        final chunkText = raw['chunkText'] as String?;
        final chunkIndex = _readInt(raw['chunkIndex']);
        final totalChunks = _readInt(raw['totalChunks']);
        if (message == null ||
            chunkText == null ||
            chunkIndex == null ||
            totalChunks == null) {
          return null;
        }
        restored.add(
          ChatChunkedMessageItem(
            originalMessage: message,
            chunkText: chunkText,
            chunkIndex: chunkIndex,
            totalChunks: totalChunks,
            showCorner: raw['showCorner'] == true,
            showAvatar: raw['showAvatar'] != false,
          ),
        );
        break;
      default:
        return null;
    }
  }

  final orderedMessages = restoredMessages.values.toList(growable: false)
    ..sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      if (byTime != 0) {
        return byTime;
      }
      return a.id.compareTo(b.id);
    });
  return ChatMessageListSnapshotData(
    items: restored,
    messages: orderedMessages,
    hasMoreMessages: hasMoreMessages,
    visibleTurnCount: visibleTurnCount > 0
        ? visibleTurnCount
        : countChatMessageListConversationTurns(orderedMessages),
    lastMessagePreview: lastMessagePreview,
    lastMessageTime: lastMessageTime,
  );
}

List<Map<String, dynamic>>? normalizeChatMessageListSnapshotRawItems(
  Iterable<Object?> rawItems,
) {
  final normalized = <Map<String, dynamic>>[];
  for (final item in rawItems) {
    if (item is! Map) {
      return null;
    }
    normalized.add(Map<String, dynamic>.from(item));
  }
  return List<Map<String, dynamic>>.unmodifiable(normalized);
}

bool chatMessageListSnapshotMatchesExpected(
  ChatMessageListSnapshotData snapshot, {
  String? expectedLastMessagePreview,
  DateTime? expectedLastMessageTime,
}) {
  if (expectedLastMessageTime != null &&
      snapshot.lastMessageTime != null &&
      expectedLastMessageTime.millisecondsSinceEpoch !=
          snapshot.lastMessageTime!.millisecondsSinceEpoch) {
    return false;
  }

  final normalizedExpectedPreview = expectedLastMessagePreview?.trim();
  if (normalizedExpectedPreview != null &&
      normalizedExpectedPreview.isNotEmpty &&
      snapshot.lastMessagePreview != null &&
      normalizedExpectedPreview != snapshot.lastMessagePreview!.trim()) {
    return false;
  }

  return true;
}

bool chatMessageListSnapshotMatchesTimelineTail(
  ChatMessageListSnapshotData snapshot,
  List<Message> sourceMessages,
) {
  if (sourceMessages.isEmpty) {
    return false;
  }

  final currentTail = sourceMessages.last;
  final snapshotTime = snapshot.lastMessageTime ??
      (snapshot.messages.isNotEmpty ? snapshot.messages.last.createdAt : null);
  if (snapshotTime != null &&
      snapshotTime.millisecondsSinceEpoch !=
          currentTail.createdAt.millisecondsSinceEpoch) {
    return false;
  }

  final snapshotPreview =
      (snapshot.lastMessagePreview ?? currentTail.displayText).trim();
  return snapshotPreview == currentTail.displayText.trim();
}

Map<String, dynamic> _serializeMessage(Message message) {
  return <String, dynamic>{
    'id': message.id,
    'role': message.role,
    'content': message.content,
    'createdAt': message.createdAt.millisecondsSinceEpoch,
    'status': message.status,
    'blocks': [
      for (final block in message.blocks ?? const <MessageBlock>[])
        block.toJson(),
    ],
  };
}

Message? _resolvePersistentMessage(
  Object? rawMessage, {
  required String? messageId,
  required Map<String, Message> liveMessagesById,
  required Map<String, Message> restoredMessagesById,
}) {
  if (messageId != null) {
    final liveMessage = liveMessagesById[messageId];
    if (liveMessage != null) {
      restoredMessagesById.putIfAbsent(messageId, () => liveMessage);
      return liveMessage;
    }
  }
  if (rawMessage is! Map) {
    return null;
  }
  final restoredMessage =
      _deserializeMessage(Map<String, dynamic>.from(rawMessage));
  if (restoredMessage == null) {
    return null;
  }
  restoredMessagesById.putIfAbsent(restoredMessage.id, () => restoredMessage);
  return restoredMessage;
}

Message? _deserializeMessage(Map<String, dynamic> raw) {
  final id = raw['id'] as String?;
  final role = raw['role'] as String?;
  final content = raw['content'] as String?;
  final createdAt = _readInt(raw['createdAt']);
  if (id == null || role == null || content == null || createdAt == null) {
    return null;
  }

  final blocks = <MessageBlock>[];
  final rawBlocks = raw['blocks'];
  if (rawBlocks is List) {
    for (final block in rawBlocks) {
      if (block is! Map) {
        return null;
      }
      try {
        blocks.add(MessageBlock.fromJson(Map<String, dynamic>.from(block)));
      } catch (_) {
        return null;
      }
    }
  }

  return Message(
    id: id,
    role: role,
    content: content,
    blocks: blocks.isEmpty ? null : blocks,
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
    status: raw['status'] as String?,
  );
}

int? _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}
