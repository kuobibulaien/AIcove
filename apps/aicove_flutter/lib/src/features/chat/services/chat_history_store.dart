import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart' as db;
import '../../../core/database/database_provider.dart';
import '../../../core/database/converters/database_converters.dart';
import '../../../core/models/message_block.dart';
import '../domain/message.dart';
import 'chat_frontend_message_projection_service.dart';
import 'chat_message_projection_codec.dart';
import 'conversation_short_window_store.dart';

class ConversationMessageWindow {
  const ConversationMessageWindow({
    required this.messages,
    required this.hasMore,
  });

  final List<Message> messages;
  final bool hasMore;
}

class ConversationTurnWindow {
  const ConversationTurnWindow({
    required this.messages,
    required this.hasMoreMessages,
  });

  final List<Message> messages;
  final bool hasMoreMessages;
}

typedef LoadConversationOlderPage = Future<List<Message>> Function({
  required DateTime beforeCreatedAt,
  required String beforeId,
  required int limit,
});

const int kConversationTurnWindowFetchPageSize = 24;
const int kConversationTurnWindowMaxFetchPages = 4;

int countConversationTurns(List<Message> messages) {
  if (messages.isEmpty) return 0;
  final anchorCount = _countConversationTurnAnchors(messages);
  return anchorCount > 0 ? anchorCount : 1;
}

Future<ConversationTurnWindow> resolveConversationTurnWindow({
  required List<Message> currentMessages,
  required bool hasMoreMessages,
  required LoadConversationOlderPage loadOlderPage,
  required int targetTurnCount,
  int fetchPageSize = kConversationTurnWindowFetchPageSize,
  int maxFetchPages = kConversationTurnWindowMaxFetchPages,
}) async {
  if (currentMessages.isEmpty) {
    return const ConversationTurnWindow(
      messages: <Message>[],
      hasMoreMessages: false,
    );
  }

  final loadedMessages = List<Message>.from(currentMessages, growable: true)
    ..sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      if (byTime != 0) return byTime;
      return a.id.compareTo(b.id);
    });
  var canLoadMore = hasMoreMessages;
  var fetchedPages = 0;

  while (canLoadMore &&
      countConversationTurns(loadedMessages) < targetTurnCount &&
      fetchedPages < maxFetchPages) {
    final oldest = loadedMessages.first;
    final olderMessages = await loadOlderPage(
      beforeCreatedAt: oldest.createdAt,
      beforeId: oldest.id,
      limit: fetchPageSize,
    );
    if (olderMessages.isEmpty) {
      canLoadMore = false;
      break;
    }
    loadedMessages.insertAll(0, olderMessages);
    canLoadMore = olderMessages.length >= fetchPageSize;
    fetchedPages += 1;
  }

  final selectedMessages =
      _selectRecentTurnWindow(loadedMessages, targetTurnCount);
  final hasHiddenOlderMessages = selectedMessages.isNotEmpty &&
      selectedMessages.first.id != loadedMessages.first.id;

  return ConversationTurnWindow(
    messages: List<Message>.unmodifiable(selectedMessages),
    hasMoreMessages: hasHiddenOlderMessages || canLoadMore,
  );
}

int _countConversationTurnAnchors(List<Message> messages) {
  var count = 0;
  for (var i = 0; i < messages.length; i++) {
    if (_isConversationTurnAnchor(messages, i)) {
      count += 1;
    }
  }
  return count;
}

bool _isConversationTurnAnchor(List<Message> messages, int index) {
  if (index < 0 || index >= messages.length) return false;
  if (messages[index].role.trim() != 'user') return false;
  if (index == 0) return true;
  return messages[index - 1].role.trim() != 'user';
}

List<Message> _selectRecentTurnWindow(
  List<Message> messages,
  int targetTurnCount,
) {
  if (messages.isEmpty) return const <Message>[];

  var remainingTurns = targetTurnCount;
  var startIndex = 0;
  for (var i = messages.length - 1; i >= 0; i--) {
    if (!_isConversationTurnAnchor(messages, i)) {
      continue;
    }
    startIndex = i;
    remainingTurns -= 1;
    if (remainingTurns <= 0) {
      return List<Message>.from(
        messages.sublist(startIndex),
        growable: false,
      );
    }
  }

  return List<Message>.from(
    messages.sublist(startIndex),
    growable: false,
  );
}

class ChatHistoryStore {
  ChatHistoryStore(this._ref);

  final Ref _ref;

  db.AppDatabase get _db => _ref.read(databaseProvider);

  Future<List<Message>> loadFrontendMessages(String conversationId) {
    return _ref
        .read(conversationShortWindowStoreProvider)
        .loadAllMessages(conversationId);
  }

  Future<List<Message>> loadAllMessages(String conversationId) async {
    final rawMessages = await loadAllRawMessages(conversationId);
    return _projectRawMessages(rawMessages);
  }

  Future<List<Message>> loadAllRawMessages(String conversationId) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final dbMessages = await msgRepo.getAllByConversationOrderedStable(
      conversationId,
    );
    return _buildRawMessagesFromDb(dbMessages);
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
    return _buildProjectedMessagesFromDb(
      dbMessages.reversed.toList(growable: false),
    );
  }

  Future<Message?> loadMessageById(
    String messageId, {
    String? conversationId,
    bool preferProjection = true,
  }) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final dbMessage = await msgRepo.getById(messageId);
    if (dbMessage == null ||
        dbMessage.deletedAt != null ||
        dbMessage.replacedBy != null) {
      return _ref.read(conversationShortWindowStoreProvider).findMessageById(
            messageId,
            conversationId: conversationId,
          );
    }

    final rawMessage = await _buildRawMessageFromDbMessage(dbMessage);
    if (rawMessage == null || !preferProjection) {
      return rawMessage;
    }

    final projectedMessages = _projectRawMessages([rawMessage]);
    for (final projected in projectedMessages) {
      if (projected.id == messageId) {
        return projected;
      }
    }
    if (projectedMessages.length == 1) {
      return projectedMessages.first;
    }
    return rawMessage;
  }

  Future<Message?> loadFrontendMessageById(
    String messageId, {
    String? conversationId,
  }) {
    final normalizedMessageId = messageId.trim();
    if (normalizedMessageId.isEmpty) {
      return Future.value(null);
    }
    return _ref.read(conversationShortWindowStoreProvider).findMessageById(
          normalizedMessageId,
          conversationId: conversationId,
        );
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
    return _buildProjectedMessagesFromDb(
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
    bool updateShortWindow = true,
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

    final shortWindowUpdates = <Message>[...messages];
    if (userMessageId.trim().isNotEmpty) {
      final userMessages = await _loadFrontendMessagesForMessageId(
        userMessageId,
        conversationId: conversationId,
      );
      if (userMessages.isNotEmpty) {
        shortWindowUpdates.insertAll(0, userMessages);
      }
    }
    if (updateShortWindow && shortWindowUpdates.isNotEmpty) {
      await _ref.read(conversationShortWindowStoreProvider).upsertMessages(
            conversationId: conversationId,
            messages: shortWindowUpdates,
          );
    }
  }

  Future<void> appendAssistantRawMessage({
    required String conversationId,
    required String userMessageId,
    required Message rawMessage,
    required List<Message> projectedMessages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
  }) async {
    final persistedRawMessage = rawMessage.copyWith(
      rawPayload: ChatMessageProjectionCodec.copyWithProjectedMessages(
        rawMessage.rawPayload,
        projectedMessages,
      ),
    );
    List<Message> updatedUserMessages = const <Message>[];
    await _db.transaction(() async {
      final msgRepo = _ref.read(messageRepositoryProvider);
      if (userMessageId.trim().isNotEmpty) {
        await msgRepo.updateStatus(userMessageId, 'sent');
        updatedUserMessages = await _loadFrontendMessagesForMessageId(
          userMessageId,
          conversationId: conversationId,
        );
      }
      await _upsertSingleMessage(conversationId, persistedRawMessage);
      await _ref.read(conversationRepositoryProvider).updateSummary(
            conversationId,
            lastMessagePreview,
            persistedRawMessage.createdAt.millisecondsSinceEpoch,
          );
    });

    if (updatedUserMessages.isNotEmpty ||
        (updateShortWindow && projectedMessages.isNotEmpty)) {
      final shortWindowMessages = <Message>[
        ...updatedUserMessages,
        if (updateShortWindow) ...projectedMessages,
      ];
      await _ref.read(conversationShortWindowStoreProvider).upsertMessages(
            conversationId: conversationId,
            messages: shortWindowMessages,
          );
    }
  }

  Future<void> appendMessage({
    required String conversationId,
    required Message message,
    String? lastMessagePreview,
  }) async {
    final projectedMessage =
        await _normalizeProjectedMessageForFrontendMutation(
      conversationId: conversationId,
      message: message,
    );
    if (projectedMessage != null) {
      await _ref.read(conversationShortWindowStoreProvider).upsertMessage(
            conversationId: conversationId,
            message: projectedMessage,
          );
      if (lastMessagePreview != null) {
        await _ref.read(conversationRepositoryProvider).updateSummary(
              conversationId,
              lastMessagePreview,
              projectedMessage.createdAt.millisecondsSinceEpoch,
            );
      }
      await _syncRawProjectionFromShortWindow(
        conversationId: conversationId,
        rawMessageIds: {projectedMessage.sourceMessageId!},
      );
      return;
    }

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
    final shortWindowStore = _ref.read(conversationShortWindowStoreProvider);
    final allMessages = await shortWindowStore.loadAllMessages(conversationId);
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
      rebuilt.addAll(
        insertOps.map(
          (op) => _inheritProjectionSourceFromAnchor(
            op.message,
            anchorMessages: const <Message>[],
          ),
        ),
      );
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
        for (var i = 0; i < existingAnchorIds.length; i++)
          existingAnchorIds[i]: i,
      };
      final firstAnchorId = existingAnchorIds.first;
      final anchorMessages = <Message>[
        for (final id in existingAnchorIds)
          if (messageById[id] case final message?) message,
      ];
      for (final entry in slotMessages.entries) {
        slotMessages[entry.key] = <Message>[
          for (final message in entry.value)
            _inheritProjectionSourceFromAnchor(
              message,
              anchorMessages: anchorMessages,
            ),
        ];
      }
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

    await shortWindowStore.replaceMessages(
      conversationId: conversationId,
      removeMessageIds: [
        for (final message in allMessages) message.id,
      ],
      messages: rebuilt,
    );
    await _syncRawProjectionFromShortWindow(
      conversationId: conversationId,
      rawMessageIds: {
        for (final message in rebuilt)
          if (message.sourceMessageId?.trim().isNotEmpty ?? false)
            message.sourceMessageId!.trim(),
      },
    );
    await _refreshSummaryFromShortWindow(conversationId);
  }

  Future<void> markMessageStatus({
    required String conversationId,
    required String messageId,
    required String status,
  }) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    await msgRepo.updateStatus(messageId, status);

    if (status == 'failed') {
      final messages = await _loadFrontendMessagesForMessageId(
        messageId,
        conversationId: conversationId,
      );
      if (messages.isNotEmpty) {
        await _ref.read(conversationRepositoryProvider).updateSummary(
              conversationId,
              messages.last.displayText,
              messages.last.createdAt.millisecondsSinceEpoch,
            );
      }
    }

    final messages = await _loadFrontendMessagesForMessageId(
      messageId,
      conversationId: conversationId,
    );
    if (messages.isNotEmpty) {
      await _ref.read(conversationShortWindowStoreProvider).upsertMessages(
            conversationId: conversationId,
            messages: messages,
          );
    } else {
      await _removeMessagesFromShortWindowByRawIds(
        conversationId: conversationId,
        rawMessageIds: {messageId},
      );
      await _refreshSummaryFromShortWindow(conversationId);
    }
  }

  Future<void> updateMessage({
    required String conversationId,
    required Message message,
    String? lastMessagePreview,
  }) async {
    final projectedMessage =
        await _normalizeProjectedMessageForFrontendMutation(
      conversationId: conversationId,
      message: message,
    );
    if (projectedMessage != null) {
      await _ref.read(conversationShortWindowStoreProvider).upsertMessage(
            conversationId: conversationId,
            message: projectedMessage,
          );
      if (lastMessagePreview != null) {
        await _ref.read(conversationRepositoryProvider).updateSummary(
              conversationId,
              lastMessagePreview,
              projectedMessage.createdAt.millisecondsSinceEpoch,
            );
      }
      await _syncRawProjectionFromShortWindow(
        conversationId: conversationId,
        rawMessageIds: {projectedMessage.sourceMessageId!},
      );
      return;
    }

    await _db.transaction(() async {
      await _upsertSingleMessage(conversationId, message);
      final frontendMessages = _projectRawMessages(<Message>[message]);
      final effectiveTailMessage =
          frontendMessages.isNotEmpty ? frontendMessages.last : message;
      if (lastMessagePreview != null || frontendMessages.isNotEmpty) {
        await _ref.read(conversationRepositoryProvider).updateSummary(
              conversationId,
              lastMessagePreview ?? effectiveTailMessage.displayText,
              effectiveTailMessage.createdAt.millisecondsSinceEpoch,
            );
      }
    });
    final frontendMessages = _projectRawMessages(<Message>[message]);
    await _ref.read(conversationShortWindowStoreProvider).upsertMessages(
          conversationId: conversationId,
          messages: frontendMessages.isNotEmpty
              ? frontendMessages
              : <Message>[message],
        );
  }

  Future<void> softDeleteMessages(
    String conversationId,
    List<String> messageIds, {
    bool clearContextStartIfDeleted = false,
  }) async {
    if (messageIds.isEmpty) return;
    final shortWindowStore = _ref.read(conversationShortWindowStoreProvider);
    final projectedMessages = <Message>[];
    for (final id in messageIds) {
      final message = await shortWindowStore.findMessageById(
        id,
        conversationId: conversationId,
      );
      if (message != null) {
        projectedMessages.add(message);
      }
    }
    final projectedOnlyIds = <String>[
      for (final message in projectedMessages)
        if (_isProjectedFrontendMessage(message)) message.id,
    ];
    if (projectedOnlyIds.isNotEmpty) {
      await shortWindowStore.replaceMessages(
        conversationId: conversationId,
        removeMessageIds: projectedOnlyIds,
      );
      await _syncRawProjectionFromShortWindow(
        conversationId: conversationId,
        rawMessageIds: {
          for (final message in projectedMessages)
            if (message.sourceMessageId?.trim().isNotEmpty ?? false)
              message.sourceMessageId!.trim(),
        },
      );
      await _refreshSummaryFromShortWindow(conversationId);
    }

    final rawDeleteIds = [
      for (final id in messageIds)
        if (!projectedOnlyIds.contains(id)) id,
    ];
    if (rawDeleteIds.isEmpty) {
      return;
    }
    final msgRepo = _ref.read(messageRepositoryProvider);
    final blockRepo = _ref.read(messageBlockRepositoryProvider);
    final convRepo = _ref.read(conversationRepositoryProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000;

    final blocks = await blockRepo.getByMessages(rawDeleteIds);
    for (final block in blocks) {
      await blockRepo.softDelete(block.id, now);
    }
    for (final id in rawDeleteIds) {
      await msgRepo.softDelete(id, now, purgeAt);
    }
    await _refreshSummary(conversationId);

    if (clearContextStartIfDeleted) {
      final conv = await convRepo.getById(conversationId);
      if (conv != null &&
          conv.contextStartMessageId != null &&
          rawDeleteIds.contains(conv.contextStartMessageId)) {
        await (_db.update(_db.conversations)
              ..where((t) => t.id.equals(conversationId)))
            .write(const db.ConversationsCompanion(
          contextStartMessageId: Value(null),
        ));
      }
    }

    await _removeMessagesFromShortWindowByRawIds(
      conversationId: conversationId,
      rawMessageIds: rawDeleteIds.toSet(),
    );
    await _refreshSummaryFromShortWindow(conversationId);
  }

  Future<void> truncateFromMessage({
    required String conversationId,
    required String fromMessageId,
  }) async {
    final allMessages = await loadFrontendMessages(conversationId);
    final index =
        allMessages.indexWhere((message) => message.id == fromMessageId);
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
    final allMessages = await loadFrontendMessages(conversationId);
    final index =
        allMessages.indexWhere((message) => message.id == anchorMessageId);
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

  Future<void> _upsertMessages({
    required String conversationId,
    required List<Message> messages,
    required String previewText,
    required DateTime previewTime,
  }) async {
    if (messages.isEmpty) return;
    final frontendMessages = _projectRawMessages(messages);
    final effectiveTailMessage =
        frontendMessages.isNotEmpty ? frontendMessages.last : messages.last;
    final effectivePreviewTime = frontendMessages.isNotEmpty
        ? effectiveTailMessage.createdAt
        : previewTime;
    await _db.transaction(() async {
      for (final message in messages) {
        await _upsertSingleMessage(conversationId, message);
      }
      await _ref.read(conversationRepositoryProvider).updateSummary(
            conversationId,
            effectiveTailMessage.displayText.isNotEmpty
                ? effectiveTailMessage.displayText
                : previewText,
            effectivePreviewTime.millisecondsSinceEpoch,
          );
    });
    await _ref.read(conversationShortWindowStoreProvider).upsertMessages(
          conversationId: conversationId,
          messages: frontendMessages.isNotEmpty ? frontendMessages : messages,
        );
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

    final shortWindowStore = _ref.read(conversationShortWindowStoreProvider);
    final currentFrontendMessages =
        await shortWindowStore.loadAllMessages(conversationId);
    final nextFrontendMessages = _projectRawMessages(messages);
    await shortWindowStore.replaceMessages(
      conversationId: conversationId,
      removeMessageIds: [
        for (final message in currentFrontendMessages) message.id,
      ],
      messages:
          nextFrontendMessages.isNotEmpty ? nextFrontendMessages : messages,
    );
    await _refreshSummaryFromShortWindow(conversationId);
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

  Future<void> _refreshSummaryFromShortWindow(String conversationId) async {
    final convRepo = _ref.read(conversationRepositoryProvider);
    final messages =
        await _ref.read(conversationShortWindowStoreProvider).loadAllMessages(
              conversationId,
            );
    if (messages.isEmpty) {
      await convRepo.clearSummary(
        conversationId,
        DateTime.now().millisecondsSinceEpoch,
      );
      return;
    }
    final last = messages.last;
    await convRepo.updateSummary(
      conversationId,
      last.displayText,
      last.createdAt.millisecondsSinceEpoch,
    );
  }

  Future<void> _removeMessagesFromShortWindowByRawIds({
    required String conversationId,
    required Set<String> rawMessageIds,
  }) async {
    if (rawMessageIds.isEmpty) {
      return;
    }
    final normalizedRawIds = {
      for (final rawMessageId in rawMessageIds)
        if (rawMessageId.trim().isNotEmpty) rawMessageId.trim(),
    };
    if (normalizedRawIds.isEmpty) {
      return;
    }

    final shortWindowStore = _ref.read(conversationShortWindowStoreProvider);
    final currentMessages = await shortWindowStore.loadAllMessages(
      conversationId,
    );
    if (currentMessages.isEmpty) {
      return;
    }

    final removeMessageIds = <String>[
      for (final message in currentMessages)
        if (normalizedRawIds.contains(message.id) ||
            normalizedRawIds.contains(message.sourceMessageId?.trim()))
          message.id,
    ];
    if (removeMessageIds.isEmpty) {
      return;
    }

    await shortWindowStore.replaceMessages(
      conversationId: conversationId,
      removeMessageIds: removeMessageIds,
    );
  }

  Future<Message?> loadLastMessage(String conversationId) async {
    final msgRepo = _ref.read(messageRepositoryProvider);
    final dbMessage = await msgRepo.getLastMessageStable(conversationId);
    if (dbMessage == null) return null;
    final rawMessage = await _buildRawMessageFromDbMessage(dbMessage);
    if (rawMessage == null) return null;
    final projectedMessages = _projectRawMessages(<Message>[rawMessage]);
    if (projectedMessages.isNotEmpty) {
      return projectedMessages.last;
    }
    return rawMessage;
  }

  Future<List<Message>> _buildProjectedMessagesFromDb(
    List<db.Message> dbMessages,
  ) async {
    final rawMessages = await _buildRawMessagesFromDb(dbMessages);
    return _projectRawMessages(rawMessages);
  }

  List<Message> _projectRawMessages(List<Message> rawMessages) {
    return _ref
        .read(chatFrontendMessageProjectionServiceProvider)
        .projectMessages(rawMessages);
  }

  Future<List<Message>> _buildRawMessagesFromDb(
      List<db.Message> dbMessages) async {
    if (dbMessages.isEmpty) return const <Message>[];
    final blockRepo = _ref.read(messageBlockRepositoryProvider);
    final messageIds =
        dbMessages.map((message) => message.id).toList(growable: false);
    final dbBlocks = await blockRepo.getByMessages(messageIds);
    final blocksByMessageId = <String, List<MessageBlock>>{};
    for (final dbBlock in dbBlocks) {
      final block = MessageBlockConverter.fromDb(dbBlock);
      if (block == null) continue;
      blocksByMessageId
          .putIfAbsent(dbBlock.messageId, () => <MessageBlock>[])
          .add(block);
    }
    return [
      for (final dbMessage in dbMessages)
        MessageConverter.fromDb(
          dbMessage,
          blocks: blocksByMessageId[dbMessage.id],
        ),
    ];
  }

  Future<Message?> _buildRawMessageFromDbMessage(db.Message dbMessage) async {
    final blockRepo = _ref.read(messageBlockRepositoryProvider);
    final dbBlocks = await blockRepo.getByMessage(dbMessage.id);
    final blocks = <MessageBlock>[];
    for (final dbBlock in dbBlocks) {
      final block = MessageBlockConverter.fromDb(dbBlock);
      if (block != null) {
        blocks.add(block);
      }
    }
    return MessageConverter.fromDb(dbMessage, blocks: blocks);
  }

  bool _isProjectedFrontendMessage(Message message) {
    final sourceMessageId = message.sourceMessageId?.trim();
    return sourceMessageId != null &&
        sourceMessageId.isNotEmpty &&
        sourceMessageId != message.id;
  }

  Future<Message?> _normalizeProjectedMessageForFrontendMutation({
    required String conversationId,
    required Message message,
  }) async {
    final sourceMessageId = message.sourceMessageId?.trim();
    if (sourceMessageId != null &&
        sourceMessageId.isNotEmpty &&
        sourceMessageId != message.id) {
      return message;
    }
    final existing = await _ref
        .read(conversationShortWindowStoreProvider)
        .findMessageById(message.id, conversationId: conversationId);
    final inheritedSourceMessageId = existing?.sourceMessageId?.trim();
    if (inheritedSourceMessageId == null || inheritedSourceMessageId.isEmpty) {
      return null;
    }
    return message.copyWith(sourceMessageId: inheritedSourceMessageId);
  }

  Message _inheritProjectionSourceFromAnchor(
    Message message, {
    required List<Message> anchorMessages,
  }) {
    if (_isProjectedFrontendMessage(message)) {
      return message;
    }
    for (final anchor in anchorMessages) {
      final sourceMessageId = anchor.sourceMessageId?.trim();
      if (sourceMessageId == null || sourceMessageId.isEmpty) {
        continue;
      }
      return message.copyWith(sourceMessageId: sourceMessageId);
    }
    return message;
  }

  Future<List<Message>> _loadFrontendMessagesForMessageId(
    String messageId, {
    String? conversationId,
  }) async {
    final normalizedMessageId = messageId.trim();
    if (normalizedMessageId.isEmpty) {
      return const <Message>[];
    }

    final msgRepo = _ref.read(messageRepositoryProvider);
    final dbMessage = await msgRepo.getById(normalizedMessageId);
    if (dbMessage != null &&
        dbMessage.deletedAt == null &&
        dbMessage.replacedBy == null) {
      final rawMessage = await _buildRawMessageFromDbMessage(dbMessage);
      if (rawMessage != null) {
        final projectedMessages = _projectRawMessages(<Message>[rawMessage]);
        if (projectedMessages.isNotEmpty) {
          return projectedMessages;
        }
        return <Message>[rawMessage];
      }
    }

    final message =
        await _ref.read(conversationShortWindowStoreProvider).findMessageById(
              normalizedMessageId,
              conversationId: conversationId,
            );
    return message == null ? const <Message>[] : <Message>[message];
  }

  Future<void> _syncRawProjectionFromShortWindow({
    required String conversationId,
    required Set<String> rawMessageIds,
  }) async {
    if (rawMessageIds.isEmpty) {
      return;
    }
    final projectedMessages =
        await _ref.read(conversationShortWindowStoreProvider).loadAllMessages(
              conversationId,
            );
    for (final rawMessageId in rawMessageIds) {
      final rawMessage = await loadMessageById(
        rawMessageId,
        conversationId: conversationId,
        preferProjection: false,
      );
      if (rawMessage == null) {
        continue;
      }
      final nextProjectedMessages = <Message>[
        for (final message in projectedMessages)
          if (message.sourceMessageId == rawMessageId) message,
      ];
      await _upsertSingleMessage(
        conversationId,
        rawMessage.copyWith(
          rawPayload: ChatMessageProjectionCodec.copyWithProjectedMessages(
            rawMessage.rawPayload,
            nextProjectedMessages,
          ),
        ),
      );
    }
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
