import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart' as db;
import '../../../core/database/database_provider.dart';
import '../../../core/database/converters/database_converters.dart';
import '../../../core/models/message_block.dart';
import '../domain/message.dart';

class ConversationMessageWindow {
  const ConversationMessageWindow({
    required this.messages,
    required this.hasMore,
  });

  final List<Message> messages;
  final bool hasMore;
}

class ChatHistoryStore {
  ChatHistoryStore(this._ref);

  final Ref _ref;

  db.AppDatabase get _db => _ref.read(databaseProvider);

  Stream<ConversationMessageWindow> watchWindow({
    required String conversationId,
    required int limit,
  }) {
    final normalizedLimit = limit < 1 ? 1 : limit;
    return _watchDbWindow(
      conversationId: conversationId,
      limit: normalizedLimit + 1,
    ).asyncMap((dbMessages) async {
      final hasMore = dbMessages.length > normalizedLimit;
      final visibleDesc = hasMore
          ? dbMessages.take(normalizedLimit).toList(growable: false)
          : dbMessages;
      final messages = await _buildMessagesFromDb(
        visibleDesc.reversed.toList(growable: false),
      );
      return ConversationMessageWindow(messages: messages, hasMore: hasMore);
    });
  }

  Future<List<Message>> loadAllMessages(String conversationId) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final dbMessages = await msgRepo.getAllByConversationOrderedStable(
      conversationId,
    );
    return _buildMessagesFromDb(dbMessages);
  }

  Future<List<Message>> loadRecentMessages(
    String conversationId, {
    int limit = 30,
  }) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final dbMessages = await msgRepo.getByConversationStable(
      conversationId,
      limit: limit,
    );
    return _buildMessagesFromDb(
      dbMessages.reversed.toList(growable: false),
    );
  }

  Future<Message?> loadMessageById(String messageId) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final blockRepo = _ref.read(messageBlockRepositoryProvider);
    final dbMessage = await msgRepo.getById(messageId);
    if (dbMessage == null ||
        dbMessage.deletedAt != null ||
        dbMessage.replacedBy != null) {
      return null;
    }
    final dbBlocks = await blockRepo.getByMessage(messageId);
    final blocks = <MessageBlock>[];
    for (final dbBlock in dbBlocks) {
      final block = MessageBlockConverter.fromDb(dbBlock);
      if (block != null) {
        blocks.add(block);
      }
    }
    return MessageConverter.fromDb(dbMessage, blocks: blocks);
  }

  Future<List<Message>> loadMessagesBefore({
    required String conversationId,
    required DateTime beforeCreatedAt,
    required String beforeId,
    int limit = 30,
  }) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final dbMessages = await msgRepo.getByConversationStable(
      conversationId,
      limit: limit,
      beforeTime: beforeCreatedAt.millisecondsSinceEpoch,
      beforeId: beforeId,
    );
    return _buildMessagesFromDb(
      dbMessages.reversed.toList(growable: false),
    );
  }

  Future<Message?> getLastUserMessage(String conversationId) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final dbMessage = await msgRepo.getLastMessageByRole(
      conversationId,
      role: 'user',
    );
    if (dbMessage == null) return null;
    return loadMessageById(dbMessage.id);
  }

  Future<int> loadMessageCount(String conversationId) {
    return _ref.read(messageRepositoryProvider).countByConversation(
          conversationId,
        );
  }

  Future<void> appendUserMessage({
    required String conversationId,
    required Message message,
    required String displayText,
  }) async {
    await _upsertMessages(
      conversationId: conversationId,
      messages: [message],
      previewText: displayText,
      previewTime: message.createdAt,
    );
  }

  Future<void> appendAssistantMessages({
    required String conversationId,
    required String userMessageId,
    required List<Message> messages,
    required String lastMessagePreview,
  }) async {
    await _db.transaction(() async {
      final msgRepo = _ref.read(messageRepositoryProvider);
      if (userMessageId.trim().isNotEmpty) {
        await msgRepo.updateStatus(userMessageId, 'sent');
      }
      for (final message in messages) {
        await _upsertSingleMessage(conversationId, message);
      }
      if (messages.isNotEmpty) {
        final last = messages.last;
        await _ref.read(conversationRepositoryProvider).updateSummary(
              conversationId,
              lastMessagePreview,
              last.createdAt.millisecondsSinceEpoch,
            );
      }
    });
  }

  Future<void> appendMessage({
    required String conversationId,
    required Message message,
    String? lastMessagePreview,
  }) async {
    await _upsertMessages(
      conversationId: conversationId,
      messages: [message],
      previewText: lastMessagePreview ?? message.displayText,
      previewTime: message.createdAt,
    );
  }

  Future<void> insertMessagesAroundAnchor({
    required String conversationId,
    required List<String> anchorIds,
    required List<ConversationSupplementInsertOp> insertOps,
  }) async {
    if (insertOps.isEmpty) return;
    final allMessages = await loadAllMessages(conversationId);
    final messageById = <String, Message>{
      for (final message in allMessages) message.id: message,
    };
    final existingAnchorIds = <String>[
      for (final id in anchorIds)
        if (messageById.containsKey(id)) id,
    ];

    final rebuilt = <Message>[];
    if (existingAnchorIds.isEmpty) {
      rebuilt.addAll(allMessages);
      rebuilt.addAll(insertOps.map((op) => op.message));
    } else {
      final textChunkLengths = <int>[
        for (final id in existingAnchorIds)
          _normalizedTextLength(_extractText(messageById[id]!)),
      ];
      final slotMessages = <int, List<Message>>{};
      for (final op in insertOps) {
        final slot = resolveSupplementInsertSlot(
          textChunkLengths: textChunkLengths,
          textCharsBefore: op.textCharsBefore,
          forceAppendToTail: op.forceAppendToTail,
        );
        (slotMessages[slot] ??= <Message>[]).add(op.message);
      }

      final anchorOrder = <String, int>{
        for (var i = 0; i < existingAnchorIds.length; i++) existingAnchorIds[i]: i,
      };
      final firstAnchorId = existingAnchorIds.first;
      var insertedBeforeFirst = false;
      for (final message in allMessages) {
        if (!insertedBeforeFirst && message.id == firstAnchorId) {
          rebuilt.addAll(slotMessages[0] ?? const <Message>[]);
          insertedBeforeFirst = true;
        }
        rebuilt.add(message);
        final order = anchorOrder[message.id];
        if (order == null) continue;
        rebuilt.addAll(slotMessages[order + 1] ?? const <Message>[]);
      }
    }

    await _replaceConversationMessages(
      conversationId: conversationId,
      messages: rebuilt,
    );
  }

  Future<void> markMessageStatus({
    required String conversationId,
    required String messageId,
    required String status,
  }) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    await msgRepo.updateStatus(messageId, status);

    if (status == 'failed') {
      final message = await loadMessageById(messageId);
      if (message != null) {
        await _ref.read(conversationRepositoryProvider).updateSummary(
              conversationId,
              message.displayText,
              DateTime.now().millisecondsSinceEpoch,
            );
      }
    }
  }

  Future<void> updateMessage({
    required String conversationId,
    required Message message,
    String? lastMessagePreview,
  }) async {
    await _db.transaction(() async {
      await _upsertSingleMessage(conversationId, message);
      if (lastMessagePreview != null) {
        await _ref.read(conversationRepositoryProvider).updateSummary(
              conversationId,
              lastMessagePreview,
              DateTime.now().millisecondsSinceEpoch,
            );
      }
    });
  }

  Future<void> softDeleteMessages(
    String conversationId,
    List<String> messageIds, {
    bool clearContextStartIfDeleted = false,
  }) async {
    if (messageIds.isEmpty) return;
    final msgRepo = _ref.read(messageRepositoryProvider);
    final blockRepo = _ref.read(messageBlockRepositoryProvider);
    final convRepo = _ref.read(conversationRepositoryProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000;

    final blocks = await blockRepo.getByMessages(messageIds);
    for (final block in blocks) {
      await blockRepo.softDelete(block.id, now);
    }
    for (final id in messageIds) {
      await msgRepo.softDelete(id, now, purgeAt);
    }
    await _refreshSummary(conversationId);

    if (clearContextStartIfDeleted) {
      final conv = await convRepo.getById(conversationId);
      if (conv != null &&
          conv.contextStartMessageId != null &&
          messageIds.contains(conv.contextStartMessageId)) {
        await (_db.update(_db.conversations)
              ..where((t) => t.id.equals(conversationId)))
            .write(const db.ConversationsCompanion(
          contextStartMessageId: Value(null),
        ));
      }
    }
  }

  Future<void> truncateFromMessage({
    required String conversationId,
    required String fromMessageId,
  }) async {
    final allMessages = await loadAllMessages(conversationId);
    final index = allMessages.indexWhere((message) => message.id == fromMessageId);
    if (index < 0) return;
    final ids = [
      for (final message in allMessages.skip(index)) message.id,
    ];
    await softDeleteMessages(conversationId, ids);
  }

  Future<void> truncateAfterMessage({
    required String conversationId,
    required String anchorMessageId,
  }) async {
    final allMessages = await loadAllMessages(conversationId);
    final index = allMessages.indexWhere((message) => message.id == anchorMessageId);
    if (index < 0) return;
    final ids = [
      for (final message in allMessages.skip(index + 1)) message.id,
    ];
    await softDeleteMessages(conversationId, ids);
  }

  Future<void> replaceConversationMessages({
    required String conversationId,
    required List<Message> messages,
  }) {
    return _replaceConversationMessages(
      conversationId: conversationId,
      messages: messages,
    );
  }

  Stream<List<db.Message>> _watchDbWindow({
    required String conversationId,
    required int limit,
  }) {
    final query = _db.select(_db.messages)
      ..where((t) =>
          t.conversationId.equals(conversationId) &
          t.deletedAt.isNull() &
          t.replacedBy.isNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ])
      ..limit(limit);
    return query.watch();
  }

  Future<void> _upsertMessages({
    required String conversationId,
    required List<Message> messages,
    required String previewText,
    required DateTime previewTime,
  }) async {
    if (messages.isEmpty) return;
    await _db.transaction(() async {
      for (final message in messages) {
        await _upsertSingleMessage(conversationId, message);
      }
      await _ref.read(conversationRepositoryProvider).updateSummary(
            conversationId,
            previewText,
            previewTime.millisecondsSinceEpoch,
          );
    });
  }

  Future<void> _upsertSingleMessage(
    String conversationId,
    Message message,
  ) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final blockRepo = _ref.read(messageBlockRepositoryProvider);

    await msgRepo.upsert(MessageConverter.toCompanion(message, conversationId));
    await blockRepo.deleteByMessage(message.id);

    final blocks = message.blocks;
    if (blocks == null || blocks.isEmpty) {
      return;
    }

    for (var index = 0; index < blocks.length; index++) {
      await blockRepo.upsert(
        MessageBlockConverter.toCompanion(blocks[index], message.id, index),
      );
    }
  }

  Future<void> _replaceConversationMessages({
    required String conversationId,
    required List<Message> messages,
  }) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final blockRepo = _ref.read(messageBlockRepositoryProvider);
    final existingDbMessages = await msgRepo.getAllByConversationOrderedStable(
      conversationId,
    );
    final keepIds = messages.map((message) => message.id).toSet();
    final removeIds = [
      for (final message in existingDbMessages)
        if (!keepIds.contains(message.id)) message.id,
    ];

    await _db.transaction(() async {
      for (final message in messages) {
        await _upsertSingleMessage(conversationId, message);
      }
      if (removeIds.isNotEmpty) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final purgeAt = now + 30 * 24 * 60 * 60 * 1000;
        final blocks = await blockRepo.getByMessages(removeIds);
        for (final block in blocks) {
          await blockRepo.softDelete(block.id, now);
        }
        for (final id in removeIds) {
          await msgRepo.softDelete(id, now, purgeAt);
        }
      }
    });

    await _refreshSummary(conversationId);
  }

  Future<void> _refreshSummary(String conversationId) async {
    final convRepo = _ref.read(conversationRepositoryProvider);
    final last = await loadLastMessage(conversationId);
    if (last == null) {
      await convRepo.clearSummary(
        conversationId,
        DateTime.now().millisecondsSinceEpoch,
      );
      return;
    }
    await convRepo.updateSummary(
      conversationId,
      last.displayText,
      last.createdAt.millisecondsSinceEpoch,
    );
  }

  Future<Message?> loadLastMessage(String conversationId) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final dbMessage = await msgRepo.getLastMessageStable(conversationId);
    if (dbMessage == null) return null;
    return loadMessageById(dbMessage.id);
  }

  Future<List<Message>> _buildMessagesFromDb(List<db.Message> dbMessages) async {
    if (dbMessages.isEmpty) return const <Message>[];
    final blockRepo = _ref.read(messageBlockRepositoryProvider);
    final messageIds = dbMessages.map((message) => message.id).toList(growable: false);
    final dbBlocks = await blockRepo.getByMessages(messageIds);
    final blocksByMessageId = <String, List<MessageBlock>>{};
    for (final dbBlock in dbBlocks) {
      final block = MessageBlockConverter.fromDb(dbBlock);
      if (block == null) continue;
      blocksByMessageId.putIfAbsent(dbBlock.messageId, () => <MessageBlock>[]).add(block);
    }
    return [
      for (final dbMessage in dbMessages)
        MessageConverter.fromDb(
          dbMessage,
          blocks: blocksByMessageId[dbMessage.id],
        ),
    ];
  }
}

String _extractText(Message message) {
  final blocks = message.blocks;
  if (blocks != null && blocks.isNotEmpty) {
    final text =
        blocks.whereType<TextBlock>().map((block) => block.content).join();
    if (text.trim().isNotEmpty) {
      return text;
    }
  }
  return message.content;
}

int _normalizedTextLength(String text) =>
    text.replaceAll(RegExp(r'\s+'), '').length;

class ConversationSupplementInsertOp {
  const ConversationSupplementInsertOp({
    required this.textCharsBefore,
    required this.message,
    this.forceAppendToTail = false,
  });

  final int textCharsBefore;
  final Message message;
  final bool forceAppendToTail;
}

int resolveInsertSlotByChars({
  required List<int> textChunkLengths,
  required int textCharsBefore,
}) {
  if (textChunkLengths.isEmpty) return 0;
  if (textCharsBefore <= 0) return 0;

  var cumulative = 0;
  for (var index = 0; index < textChunkLengths.length; index++) {
    final length = textChunkLengths[index] < 0 ? 0 : textChunkLengths[index];
    cumulative += length;
    if (textCharsBefore <= cumulative) {
      return index + 1;
    }
  }
  return textChunkLengths.length;
}

int resolveSupplementInsertSlot({
  required List<int> textChunkLengths,
  required int textCharsBefore,
  bool forceAppendToTail = false,
}) {
  if (forceAppendToTail) {
    return textChunkLengths.length;
  }
  return resolveInsertSlotByChars(
    textChunkLengths: textChunkLengths,
    textCharsBefore: textCharsBefore,
  );
}

final chatHistoryStoreProvider = Provider<ChatHistoryStore>(
  ChatHistoryStore.new,
);
