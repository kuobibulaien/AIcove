/// Domain ↔ Database 转换器
library;

import 'dart:convert';
import 'package:drift/drift.dart';
import '../database.dart' as db;
import '../../../features/chat/domain/conversation.dart' as domain;
import '../../../features/chat/domain/message.dart' as domain;
import '../../../core/models/message_block.dart';

/// 会话转换器
class ConversationConverter {
  /// Domain → Database Companion
  static db.ConversationsCompanion toCompanion(domain.Conversation c) {
    return db.ConversationsCompanion(
      id: Value(c.id),
      title: Value(c.title),
      displayName: Value(c.displayName),
      avatarUrl: Value(c.avatarUrl),
      characterImage: Value(c.characterImage),
      selfAddress: Value(c.selfAddress),
      addressUser: Value(c.addressUser),
      voiceFile: Value(c.voiceFile),
      personaPrompt: Value(c.personaPrompt),
      defaultProvider: Value(c.defaultProvider),
      sessionProvider: Value(c.sessionProvider),
      isPinned: Value(c.isPinned),
      isFavorite: Value(c.isFavorite),
      isMuted: Value(c.isMuted),
      notificationSound: Value(c.notificationSound),
      lastMessage: Value(c.lastMessage),
      lastMessageTime: Value(c.lastMessageTime?.millisecondsSinceEpoch),
      unreadCount: Value(c.unreadCount),
      createdAt: Value(c.createdAt.millisecondsSinceEpoch),
      updatedAt: Value(c.updatedAt.millisecondsSinceEpoch),
    );
  }

  /// Database → Domain（不含消息）
  static domain.Conversation fromDb(db.Conversation c, {List<domain.Message>? messages}) {
    return domain.Conversation(
      id: c.id,
      title: c.title,
      displayName: c.displayName,
      avatarUrl: c.avatarUrl,
      characterImage: c.characterImage,
      selfAddress: c.selfAddress,
      addressUser: c.addressUser,
      voiceFile: c.voiceFile,
      personaPrompt: c.personaPrompt,
      defaultProvider: c.defaultProvider,
      sessionProvider: c.sessionProvider,
      isPinned: c.isPinned,
      isFavorite: c.isFavorite,
      isMuted: c.isMuted,
      notificationSound: c.notificationSound,
      lastMessage: c.lastMessage,
      lastMessageTime: c.lastMessageTime != null
          ? DateTime.fromMillisecondsSinceEpoch(c.lastMessageTime!)
          : null,
      unreadCount: c.unreadCount,
      createdAt: DateTime.fromMillisecondsSinceEpoch(c.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(c.updatedAt),
      messages: messages ?? const [],
    );
  }
}

/// 消息转换器
class MessageConverter {
  /// Domain → Database Companion
  static db.MessagesCompanion toCompanion(domain.Message m, String conversationId) {
    return db.MessagesCompanion(
      id: Value(m.id),
      conversationId: Value(conversationId),
      role: Value(m.role),
      content: Value(m.content),
      status: Value(m.status ?? 'sent'),
      createdAt: Value(m.createdAt.millisecondsSinceEpoch),
    );
  }

  /// Database → Domain
  static domain.Message fromDb(db.Message m, {List<MessageBlock>? blocks}) {
    return domain.Message(
      id: m.id,
      role: m.role,
      content: m.content,
      status: m.status,
      blocks: blocks,
      createdAt: DateTime.fromMillisecondsSinceEpoch(m.createdAt),
    );
  }
}

/// 消息块转换器
class MessageBlockConverter {
  /// Domain → Database Companion
  static db.MessageBlocksCompanion toCompanion(MessageBlock b, String messageId, int sortOrder) {
    return db.MessageBlocksCompanion(
      id: Value(b.id),
      messageId: Value(messageId),
      type: Value(_getBlockType(b)),
      status: Value(b.status.name),
      data: Value(jsonEncode(b.toJson())),
      sortOrder: Value(sortOrder),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    );
  }

  /// Database → Domain
  static MessageBlock? fromDb(db.MessageBlock b) {
    try {
      final data = jsonDecode(b.data) as Map<String, dynamic>;
      return MessageBlock.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  static String _getBlockType(MessageBlock b) {
    if (b is TextBlock) return 'mainText';
    if (b is ImageBlock) return 'image';
    if (b is AudioBlock) return 'audio';
    if (b is EmojiBlock) return 'emoji';
    if (b is ToolBlock) return 'tool';
    if (b is ThinkingBlock) return 'thinking';
    return 'unknown';
  }
}
