import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart' as db;
import '../../../core/database/database_provider.dart';
import '../../../core/database/converters/database_converters.dart';
import '../../../core/models/message_block.dart';
import '../../plugins/domain/plugin_content.dart';
import '../domain/message.dart';
import 'chat_frontend_message_projection_service.dart';
import 'chat_message_processor.dart';
import 'chat_message_projection_codec.dart';
import 'chat_types.dart';
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

  Future<List<Message>> loadCachedTimelineMessages(String conversationId) {
    return _ref
        .read(conversationTimelineCacheProvider)
        .loadCachedMessages(conversationId);
  }

  Future<List<Message>> loadProjectedMessagesFromRawStore(
    String conversationId,
  ) async {
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

  Future<List<Message>> loadRecentProjectedMessages(
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
      return _ref.read(conversationTimelineCacheProvider).findCachedMessageById(
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
    return _loadBestEffortFrontendMessageById(
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
    await _clearStaleShortWindowIfConversationEmpty(conversationId);
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
      await _ref.read(conversationTimelineCacheProvider).upsertMessages(
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
    await _db.transaction(() async {
      final msgRepo = _ref.read(messageRepositoryProvider);
      if (userMessageId.trim().isNotEmpty) {
        await msgRepo.updateStatus(userMessageId, 'sent');
      }
      await _upsertSingleMessage(
        conversationId,
        rawMessage.copyWith(
          rawPayload: ChatMessageProjectionCodec.removeProjectedMessages(
            rawMessage.rawPayload,
          ),
        ),
      );
      await _ref.read(conversationRepositoryProvider).updateSummary(
            conversationId,
            lastMessagePreview,
            rawMessage.createdAt.millisecondsSinceEpoch,
          );
    });

    if (projectedMessages.isNotEmpty) {
      await _syncProjectionMappingsForRawMessage(
        conversationId: conversationId,
        rawMessageId: rawMessage.id,
        projectedMessages: projectedMessages,
      );
    }

    if (!updateShortWindow) {
      return;
    }

    final updatedUserMessages = userMessageId.trim().isEmpty
        ? const <Message>[]
        : await _loadFrontendMessagesForMessageId(
            userMessageId,
            conversationId: conversationId,
          );

    if (updatedUserMessages.isNotEmpty || projectedMessages.isNotEmpty) {
      final shortWindowMessages = <Message>[
        ...updatedUserMessages,
        ...projectedMessages,
      ];
      await _ref.read(conversationTimelineCacheProvider).upsertMessages(
            conversationId: conversationId,
            messages: shortWindowMessages,
          );
      await _syncRawSupplementsFromTimeline(
        conversationId: conversationId,
        rawMessageIds: {rawMessage.id},
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
      await _ref.read(conversationTimelineCacheProvider).upsertMessage(
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
      await _syncRawSupplementsFromTimeline(
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
    final timelineCache = _ref.read(conversationTimelineCacheProvider);
    final allMessages = await timelineCache.loadCachedMessages(conversationId);
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
      final anchorMessages = <Message>[
        for (final id in existingAnchorIds)
          if (messageById[id] case final message?) message,
      ];
      final anchorSourceIds = <String>{
        for (final anchor in anchorMessages)
          if (anchor.sourceMessageId?.trim().isNotEmpty ?? false)
            anchor.sourceMessageId!.trim(),
      };
      for (final entry in slotMessages.entries) {
        slotMessages[entry.key] = <Message>[
          for (final message in entry.value)
            _inheritProjectionSourceFromAnchor(
              message,
              anchorMessages: anchorMessages,
            ),
        ];
      }
      final slotBuckets = List<List<Message>>.generate(
        existingAnchorIds.length + 1,
        (_) => <Message>[],
      );
      var currentSlot = 0;
      for (final message in allMessages) {
        final order = anchorOrder[message.id];
        if (order != null) {
          currentSlot = order + 1;
          continue;
        }
        slotBuckets[currentSlot].add(message);
      }
      rebuilt.addAll(slotBuckets[0]);
      rebuilt.addAll(slotMessages[0] ?? const <Message>[]);
      for (var i = 0; i < existingAnchorIds.length; i++) {
        final anchorMessage = messageById[existingAnchorIds[i]];
        if (anchorMessage == null) {
          continue;
        }
        rebuilt.add(anchorMessage);
        final bucket = slotBuckets[i + 1];
        final leadingRelatedCount = _countLeadingRelatedMessages(
          bucket,
          anchorSourceIds: anchorSourceIds,
        );
        rebuilt.addAll(bucket.take(leadingRelatedCount));
        rebuilt.addAll(slotMessages[i + 1] ?? const <Message>[]);
        rebuilt.addAll(bucket.skip(leadingRelatedCount));
      }
    }

    await timelineCache.replaceMessages(
      conversationId: conversationId,
      removeMessageIds: [
        for (final message in allMessages) message.id,
      ],
      messages: rebuilt,
    );
    await _syncRawSupplementsFromTimeline(
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
      await _ref.read(conversationTimelineCacheProvider).upsertMessages(
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
      await _ref.read(conversationTimelineCacheProvider).upsertMessage(
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
      await _syncRawSupplementsFromTimeline(
        conversationId: conversationId,
        rawMessageIds: {projectedMessage.sourceMessageId!},
      );
      return;
    }

    await _db.transaction(() async {
      await _upsertSingleMessage(conversationId, message);
      final frontendMessages =
          _projectRawMessagesForFrontendSurface(<Message>[message]);
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
    final frontendMessages =
        _projectRawMessagesForFrontendSurface(<Message>[message]);
    await _ref.read(conversationTimelineCacheProvider).upsertMessages(
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
    final timelineCache = _ref.read(conversationTimelineCacheProvider);
    final projectedMessages = <Message>[];
    final allFrontendMessages = await _loadBestEffortFrontendMessages(
      conversationId,
    );
    for (final id in messageIds) {
      final message = await _loadBestEffortFrontendMessageById(
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
    final rawDeleteIds = <String>{
      for (final id in messageIds)
        if (!projectedOnlyIds.contains(id)) id,
    };
    final projectedDeleteIdsByRaw = <String, Set<String>>{};
    for (final message in projectedMessages) {
      if (!_isProjectedFrontendMessage(message)) {
        continue;
      }
      final rawMessageId = message.sourceMessageId?.trim();
      if (rawMessageId == null || rawMessageId.isEmpty) {
        continue;
      }
      projectedDeleteIdsByRaw
          .putIfAbsent(rawMessageId, () => <String>{})
          .add(message.id);
    }
    final rawMessageIdsToResync = <String>{};
    if (projectedDeleteIdsByRaw.isNotEmpty) {
      final frontendIdsByRaw = <String, Set<String>>{};
      for (final message in allFrontendMessages) {
        final rawMessageId = message.sourceMessageId?.trim();
        if (rawMessageId == null || rawMessageId.isEmpty) {
          continue;
        }
        frontendIdsByRaw
            .putIfAbsent(rawMessageId, () => <String>{})
            .add(message.id);
      }
      projectedDeleteIdsByRaw.forEach((rawMessageId, deleteIds) {
        final deleteMessages = projectedMessages
            .where((message) =>
                message.sourceMessageId == rawMessageId &&
                deleteIds.contains(message.id))
            .toList(growable: false);
        if (deleteMessages
            .any((message) => !_isSemanticSupplementMessage(message))) {
          rawDeleteIds.add(rawMessageId);
          return;
        }
        final frontendIds = frontendIdsByRaw[rawMessageId];
        if (frontendIds != null &&
            frontendIds.isNotEmpty &&
            frontendIds.difference(deleteIds).isEmpty) {
          rawDeleteIds.add(rawMessageId);
          return;
        }
        rawMessageIdsToResync.add(rawMessageId);
      });
    }
    if (projectedOnlyIds.isNotEmpty) {
      await timelineCache.replaceMessages(
        conversationId: conversationId,
        removeMessageIds: projectedOnlyIds,
      );
      if (rawMessageIdsToResync.isNotEmpty) {
        await _syncRawSupplementsFromTimeline(
          conversationId: conversationId,
          rawMessageIds: rawMessageIdsToResync,
        );
      }
      await _refreshSummaryFromShortWindow(conversationId);
    }
    if (rawDeleteIds.isEmpty) {
      return;
    }
    final msgRepo = _ref.read(messageRepositoryProvider);
    final blockRepo = _ref.read(messageBlockRepositoryProvider);
    final convRepo = _ref.read(conversationRepositoryProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000;

    final rawDeleteIdList = rawDeleteIds.toList(growable: false);
    final blocks = await blockRepo.getByMessages(rawDeleteIdList);
    for (final block in blocks) {
      await blockRepo.softDelete(block.id, now);
    }
    for (final id in rawDeleteIdList) {
      await msgRepo.softDelete(id, now, purgeAt);
      await _ref
          .read(messageProjectionMappingRepositoryProvider)
          .deleteByRawMessage(id);
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
      rawMessageIds: rawDeleteIds,
    );
    await _refreshSummaryFromShortWindow(conversationId);
  }

  Future<void> truncateFromMessage({
    required String conversationId,
    required String fromMessageId,
  }) async {
    final lookup = await _loadFrontendMessagesForRangeLookup(
      conversationId: conversationId,
      anchorMessageId: fromMessageId,
    );
    final range = lookup.range;
    if (range == null) return;
    final ids = [
      for (final message in lookup.messages.skip(range.$1)) message.id,
    ];
    await softDeleteMessages(conversationId, ids);
  }

  Future<void> truncateAfterMessage({
    required String conversationId,
    required String anchorMessageId,
  }) async {
    final lookup = await _loadFrontendMessagesForRangeLookup(
      conversationId: conversationId,
      anchorMessageId: anchorMessageId,
    );
    final range = lookup.range;
    if (range == null) return;
    final anchorMessages = List<Message>.unmodifiable(
      lookup.messages.sublist(range.$1, range.$2 + 1),
    );
    final ids = [
      for (final message in lookup.messages.skip(range.$2 + 1)) message.id,
    ];
    await softDeleteMessages(conversationId, ids);
    await _restoreShortWindowMessagesIfMissing(
      conversationId: conversationId,
      messages: anchorMessages,
    );
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
    final frontendMessages = _projectRawMessagesForFrontendSurface(messages);
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
    await _ref.read(conversationTimelineCacheProvider).upsertMessages(
          conversationId: conversationId,
          messages: frontendMessages.isNotEmpty ? frontendMessages : messages,
        );
  }

  Future<void> _clearStaleShortWindowIfConversationEmpty(
    String conversationId,
  ) async {
    final messageCount =
        await _ref.read(messageRepositoryProvider).countByConversation(
              conversationId,
            );
    if (messageCount > 0) {
      return;
    }
    final timelineCache = _ref.read(conversationTimelineCacheProvider);
    final staleMessages =
        await timelineCache.loadCachedMessages(conversationId);
    if (staleMessages.isEmpty) {
      return;
    }
    await timelineCache.replaceMessages(
      conversationId: conversationId,
      removeMessageIds: [
        for (final message in staleMessages) message.id,
      ],
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

    final timelineCache = _ref.read(conversationTimelineCacheProvider);
    final currentFrontendMessages =
        await timelineCache.loadCachedMessages(conversationId);
    final nextFrontendMessages =
        _projectRawMessagesForFrontendSurface(messages);
    await timelineCache.replaceMessages(
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
        await _ref.read(conversationTimelineCacheProvider).loadCachedMessages(
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

    final timelineCache = _ref.read(conversationTimelineCacheProvider);
    final currentMessages = await timelineCache.loadCachedMessages(
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

    await timelineCache.replaceMessages(
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
    final projectionService =
        _ref.read(chatFrontendMessageProjectionServiceProvider);
    return <Message>[
      for (final rawMessage in rawMessages)
        ..._projectRawMessageForPersistedHistory(
          rawMessage,
          projectionService: projectionService,
        ),
    ];
  }

  List<Message> _projectRawMessagesForFrontendSurface(
      List<Message> rawMessages) {
    if (rawMessages.isEmpty) {
      return const <Message>[];
    }
    final projectionService =
        _ref.read(chatFrontendMessageProjectionServiceProvider);
    return projectionService.projectMessages(rawMessages);
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

  bool _isSemanticSupplementMessage(Message message) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) {
      return false;
    }
    final block = blocks.single;
    if (block is ImageBlock) {
      return (block.localPath?.trim().isNotEmpty ?? false) ||
          (block.url?.trim().isNotEmpty ?? false) ||
          (block.base64?.trim().isNotEmpty ?? false);
    }
    if (block is AudioBlock) {
      return block.url.trim().isNotEmpty;
    }
    return false;
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
        .read(conversationTimelineCacheProvider)
        .findCachedMessageById(message.id, conversationId: conversationId);
    final inheritedSourceMessageId = existing?.sourceMessageId?.trim();
    if (inheritedSourceMessageId == null ||
        inheritedSourceMessageId.isEmpty ||
        inheritedSourceMessageId == message.id) {
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
        final projectedMessages =
            _projectRawMessagesForFrontendSurface(<Message>[rawMessage]);
        if (projectedMessages.isNotEmpty) {
          return projectedMessages;
        }
        return <Message>[rawMessage];
      }
    }

    final message = await _ref
        .read(conversationTimelineCacheProvider)
        .findCachedMessageById(
          normalizedMessageId,
          conversationId: conversationId,
        );
    return message == null ? const <Message>[] : <Message>[message];
  }

  Future<void> _syncRawSupplementsFromTimeline({
    required String conversationId,
    required Set<String> rawMessageIds,
  }) async {
    if (rawMessageIds.isEmpty) {
      return;
    }
    final timelineMessages =
        await _ref.read(conversationTimelineCacheProvider).loadCachedMessages(
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
      final sourceTimelineMessages = <Message>[
        for (final message in timelineMessages)
          if (message.sourceMessageId == rawMessageId) message,
      ];
      final nextPluginContents =
          _collectSemanticPluginContents(sourceTimelineMessages);
      final nextToolAudioResults =
          _collectSemanticToolAudioResults(sourceTimelineMessages);
      final nextSupplementInsertOps =
          _collectSupplementInsertOps(sourceTimelineMessages);
      await _upsertSingleMessage(
        conversationId,
        rawMessage.copyWith(
          rawPayload: ChatMessageProjectionCodec.copyWithSupplementInsertOps(
            ChatMessageProjectionCodec.copyWithToolAudioResults(
              ChatMessageProjectionCodec.copyWithPluginContents(
                ChatMessageProjectionCodec.removeProjectedMessages(
                  rawMessage.rawPayload,
                ),
                nextPluginContents,
              ),
              nextToolAudioResults,
            ),
            nextSupplementInsertOps,
          ),
        ),
      );
    }
  }

  Future<List<Message>> _loadBestEffortFrontendMessages(
    String conversationId,
  ) async {
    final frontendMessages = await loadCachedTimelineMessages(conversationId);
    if (frontendMessages.isNotEmpty) {
      return frontendMessages;
    }
    final rawMessages = await loadAllRawMessages(conversationId);
    return _projectRawMessagesForFrontendSurface(rawMessages);
  }

  Future<({List<Message> messages, (int, int)? range})>
      _loadFrontendMessagesForRangeLookup({
    required String conversationId,
    required String anchorMessageId,
  }) async {
    final frontendMessages = await _loadBestEffortFrontendMessages(
      conversationId,
    );
    final frontendRange = _findMessageRangeByIdOrSource(
      frontendMessages,
      anchorMessageId,
    );
    if (frontendRange != null) {
      return (
        messages: frontendMessages,
        range: frontendRange,
      );
    }

    final rawMessages = await loadAllRawMessages(conversationId);
    final projectedMessages =
        _projectRawMessagesForFrontendSurface(rawMessages);
    return (
      messages: projectedMessages,
      range: _findMessageRangeByIdOrSource(
        projectedMessages,
        anchorMessageId,
      ),
    );
  }

  Future<void> _restoreShortWindowMessagesIfMissing({
    required String conversationId,
    required List<Message> messages,
  }) async {
    if (messages.isEmpty) {
      return;
    }

    final timelineCache = _ref.read(conversationTimelineCacheProvider);
    final currentMessages = await timelineCache.loadCachedMessages(
      conversationId,
    );
    final currentIds = {
      for (final message in currentMessages) message.id,
    };
    final missingMessages = <Message>[
      for (final message in messages)
        if (!currentIds.contains(message.id)) message,
    ];
    if (missingMessages.isEmpty) {
      return;
    }

    await timelineCache.upsertMessages(
      conversationId: conversationId,
      messages: missingMessages,
    );
  }

  Future<Message?> _loadBestEffortFrontendMessageById(
    String messageId, {
    String? conversationId,
  }) async {
    final frontendMessage = await _ref
        .read(conversationTimelineCacheProvider)
        .findCachedMessageById(
          messageId,
          conversationId: conversationId,
        );
    if (frontendMessage != null) {
      return frontendMessage;
    }
    if (conversationId != null && conversationId.trim().isNotEmpty) {
      final rawMessages = await loadAllRawMessages(conversationId);
      final frontendMessages =
          _projectRawMessagesForFrontendSurface(rawMessages);
      for (final message in frontendMessages) {
        if (message.id == messageId) {
          return message;
        }
      }
    }
    final mapping = await _ref
        .read(messageProjectionMappingRepositoryProvider)
        .getByProjectedMessageId(
          messageId,
          conversationId: conversationId,
        );
    if (mapping != null) {
      final rawMessage = await loadMessageById(
        mapping.rawMessageId,
        conversationId: conversationId,
        preferProjection: false,
      );
      if (rawMessage != null) {
        final projectedMessages =
            _projectRawMessagesForFrontendSurface(<Message>[rawMessage]);
        if (projectedMessages.isNotEmpty) {
          final segmentIndex = mapping.segmentIndex;
          if (segmentIndex >= 0 && segmentIndex < projectedMessages.length) {
            return projectedMessages[segmentIndex];
          }
          return projectedMessages.last;
        }
        return rawMessage;
      }
    }
    return loadMessageById(
      messageId,
      conversationId: conversationId,
    );
  }

  Future<void> _syncProjectionMappingsForRawMessage({
    required String conversationId,
    required String rawMessageId,
    required List<Message> projectedMessages,
  }) async {
    final normalizedRawMessageId = rawMessageId.trim();
    if (normalizedRawMessageId.isEmpty) {
      return;
    }
    final normalizedProjectedMessages = <Message>[
      for (final message in projectedMessages)
        if (message.id.trim().isNotEmpty)
          message.sourceMessageId == normalizedRawMessageId
              ? message
              : message.copyWith(sourceMessageId: normalizedRawMessageId),
    ];
    await _ref
        .read(messageProjectionMappingRepositoryProvider)
        .replaceForRawMessage(
      rawMessageId: normalizedRawMessageId,
      mappings: <db.MessageProjectionMappingsCompanion>[
        for (var index = 0;
            index < normalizedProjectedMessages.length;
            index += 1)
          db.MessageProjectionMappingsCompanion.insert(
            id: '$normalizedRawMessageId::${normalizedProjectedMessages[index].id}',
            conversationId: conversationId,
            rawMessageId: normalizedRawMessageId,
            projectedMessageId: normalizedProjectedMessages[index].id,
            projectionKind: Value(
              _projectionKindFor(normalizedProjectedMessages[index]),
            ),
            segmentIndex: Value(index),
            projectionVersion: const Value(null),
            createdAt: normalizedProjectedMessages[index]
                .createdAt
                .millisecondsSinceEpoch,
          ),
      ],
    );
  }

  (int, int)? _findMessageRangeByIdOrSource(
    List<Message> messages,
    String messageId,
  ) {
    final normalizedMessageId = messageId.trim();
    if (normalizedMessageId.isEmpty || messages.isEmpty) {
      return null;
    }

    var firstIndex = -1;
    var lastIndex = -1;
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      final sourceMessageId = message.sourceMessageId?.trim();
      final matches = message.id == normalizedMessageId ||
          (sourceMessageId != null && sourceMessageId == normalizedMessageId);
      if (!matches) continue;
      firstIndex = firstIndex >= 0 ? firstIndex : index;
      lastIndex = index;
    }

    if (firstIndex < 0 || lastIndex < 0) {
      return null;
    }
    return (firstIndex, lastIndex);
  }

  List<Message> _projectRawMessageForPersistedHistory(
    Message rawMessage, {
    required ChatFrontendMessageProjectionService projectionService,
  }) {
    if (rawMessage.role != 'assistant') {
      return <Message>[_projectRawPassthroughMessage(rawMessage)];
    }
    final projected = projectionService.projectMessage(rawMessage);
    final collapsed = _collapseAssistantPureTextProjection(
      rawMessage,
      projectedMessages: projected,
    );
    return collapsed ?? projected;
  }

  Message _projectRawPassthroughMessage(Message message) {
    return message.copyWith(
      sourceMessageId: message.sourceMessageId ?? message.id,
      rawPayload: null,
    );
  }

  List<Message>? _collapseAssistantPureTextProjection(
    Message rawMessage, {
    required List<Message> projectedMessages,
  }) {
    if (projectedMessages.length <= 1) {
      return null;
    }
    if (_shouldPreserveAssistantProjectionSegments(rawMessage)) {
      return null;
    }
    if (projectedMessages
        .any((message) => !_isPureTextPersistedMessage(message))) {
      return null;
    }

    final rebuilt = _rebuildAssistantMessagesFromPayload(rawMessage);
    if (rebuilt.length == 1 && _isPureTextPersistedMessage(rebuilt.single)) {
      return rebuilt;
    }

    final combinedText =
        projectedMessages.map(_extractText).map((value) => value.trim()).join();
    if (combinedText.isEmpty) {
      return null;
    }

    return <Message>[
      Message.text(
        id: projectedMessages.first.id,
        role: 'assistant',
        sourceMessageId: rawMessage.id,
        content: combinedText,
        createdAt: projectedMessages.first.createdAt,
        status: 'sent',
      ),
    ];
  }

  bool _shouldPreserveAssistantProjectionSegments(Message rawMessage) {
    final payload = rawMessage.rawPayload;
    if (payload != null) {
      final hasMultimodalEvents =
          ChatMessageProjectionCodec.pluginEvents(payload).any((event) =>
              event.type == 'tts_convert' ||
              event.type == 'sticker_convert' ||
              event.type == 'image_generate');
      if (hasMultimodalEvents) {
        return true;
      }
    }

    final rawReplyText =
        ChatMessageProjectionCodec.rawReplyText(payload) ?? rawMessage.content;
    return rawReplyText.contains('<tts>') || rawReplyText.contains('<image>');
  }

  List<Message> _rebuildAssistantMessagesFromPayload(Message rawMessage) {
    final payload = rawMessage.rawPayload;
    if (payload == null) {
      return const <Message>[];
    }
    final rebuilt = const ChatMessageProcessor().buildAssistantMessages(
      replyText: ChatMessageProjectionCodec.rawReplyText(payload) ??
          rawMessage.content,
      processedText: ChatMessageProjectionCodec.processedText(payload) ?? '',
      pluginEvents: ChatMessageProjectionCodec.pluginEvents(payload),
      contents: ChatMessageProjectionCodec.pluginContents(payload),
      toolAudioResults: ChatMessageProjectionCodec.toolAudioResults(payload),
      toolCalls: ChatMessageProjectionCodec.toolCalls(payload),
      rawToolResults: ChatMessageProjectionCodec.rawToolResults(payload),
    );
    return <Message>[
      for (final message in rebuilt.messages)
        message.copyWith(
          sourceMessageId: rawMessage.id,
          rawPayload: null,
        ),
    ];
  }

  bool _isPureTextPersistedMessage(Message message) {
    final blocks = message.blocks;
    if (blocks == null || blocks.isEmpty) {
      return message.content.trim().isNotEmpty;
    }
    var hasText = false;
    for (final block in blocks) {
      if (block is TextBlock) {
        if (block.content.trim().isNotEmpty) {
          hasText = true;
        }
        continue;
      }
      return false;
    }
    return hasText;
  }

  List<PluginContent> _collectSemanticPluginContents(
    List<Message> messages,
  ) {
    final contents = <PluginContent>[];
    for (final message in messages) {
      final blocks = message.blocks;
      if (blocks == null || blocks.length != 1) {
        continue;
      }
      final block = blocks.single;
      if (block is! ImageBlock) {
        continue;
      }
      final localPath = block.localPath?.trim();
      if (localPath == null || localPath.isEmpty) {
        continue;
      }
      contents.add(
        PluginImageContent(
          localPath,
          caption: block.prompt,
        ),
      );
    }
    return contents;
  }

  List<ToolAudioResult> _collectSemanticToolAudioResults(
    List<Message> messages,
  ) {
    final results = <ToolAudioResult>[];
    for (final message in messages) {
      final blocks = message.blocks;
      if (blocks == null || blocks.length != 1) {
        continue;
      }
      final block = blocks.single;
      if (block is! AudioBlock) {
        continue;
      }
      final audioUrl = block.url.trim();
      if (audioUrl.isEmpty || block.status == 'pending') {
        continue;
      }
      results.add(
        ToolAudioResult(
          audioUrl: audioUrl,
          text: block.text?.trim() ?? '',
        ),
      );
    }
    return results;
  }

  List<StoredSupplementInsertOp> _collectSupplementInsertOps(
    List<Message> messages,
  ) {
    if (messages.isEmpty) {
      return const <StoredSupplementInsertOp>[];
    }
    final ops = <StoredSupplementInsertOp>[];
    var textCharsBefore = 0;
    for (var index = 0; index < messages.length; index += 1) {
      final message = messages[index];
      final op = _buildStoredSupplementInsertOp(
        message,
        textCharsBefore: textCharsBefore,
        forceAppendToTail: !_hasLaterTextMessage(messages, index),
      );
      if (op != null) {
        ops.add(op);
      }
      textCharsBefore += _normalizedTextLength(_extractText(message));
    }
    return ops;
  }

  StoredSupplementInsertOp? _buildStoredSupplementInsertOp(
    Message message, {
    required int textCharsBefore,
    required bool forceAppendToTail,
  }) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) {
      return null;
    }
    final block = blocks.single;
    if (block is ImageBlock) {
      final localPath = block.localPath?.trim();
      if (localPath == null || localPath.isEmpty) {
        return null;
      }
      return StoredSupplementInsertOp(
        kind: 'image',
        textCharsBefore: textCharsBefore,
        forceAppendToTail: forceAppendToTail,
        localPath: localPath,
        prompt: block.prompt,
      );
    }
    if (block is AudioBlock) {
      final audioUrl = block.url.trim();
      if (audioUrl.isEmpty || block.status == 'pending') {
        return null;
      }
      return StoredSupplementInsertOp(
        kind: 'audio',
        textCharsBefore: textCharsBefore,
        forceAppendToTail: forceAppendToTail,
        audioUrl: audioUrl,
        text: block.text?.trim(),
      );
    }
    return null;
  }

  bool _hasLaterTextMessage(List<Message> messages, int index) {
    for (var cursor = index + 1; cursor < messages.length; cursor += 1) {
      if (_normalizedTextLength(_extractText(messages[cursor])) > 0) {
        return true;
      }
    }
    return false;
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

int _countLeadingRelatedMessages(
  List<Message> messages, {
  required Set<String> anchorSourceIds,
}) {
  if (messages.isEmpty || anchorSourceIds.isEmpty) {
    return 0;
  }
  var count = 0;
  for (final message in messages) {
    final sourceMessageId = message.sourceMessageId?.trim();
    if (sourceMessageId == null || !anchorSourceIds.contains(sourceMessageId)) {
      break;
    }
    count += 1;
  }
  return count;
}

String _projectionKindFor(Message message) {
  final blocks = message.blocks;
  if (blocks != null && blocks.isNotEmpty) {
    final first = blocks.first;
    if (first is ImageBlock) return 'image';
    if (first is AudioBlock) return 'audio';
    if (first is EmojiBlock) return 'emoji';
    if (first is FileBlock) return 'file';
    if (first is ToolBlock) return 'tool';
  }
  return 'text';
}

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
