import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../application/chat_edit.dart';
import '../application/chat_media_regeneration.dart';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart' as db;
import '../../../core/database/database_provider.dart';
import '../../../core/database/converters/database_converters.dart';
import '../../../core/models/message_block.dart';
import '../../../core/media/embedded_media_store.dart';
import '../../../core/sync/cloud_local_write.dart';
import '../../../core/models/block_status.dart';
import '../../conversation_state/providers/conversation_state_providers.dart';
import '../../plugins/domain/plugin_content.dart';
import '../domain/message.dart';
import '../domain/chat_timeline_deletion.dart';
import '../domain/conversation_context_window.dart';
import 'chat_frontend_message_projection_service.dart';
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

  final loadedMessages = _normalizeConversationTurnMessages(
    currentMessages,
  ).toList(growable: true);
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

List<Message> _normalizeConversationTurnMessages(Iterable<Message> messages) {
  final indexedMessages = <({int index, Message message})>[];
  var index = 0;
  for (final message in messages) {
    indexedMessages.add((index: index, message: message));
    index += 1;
  }
  indexedMessages.sort((left, right) {
    final byTime = left.message.createdAt.compareTo(right.message.createdAt);
    if (byTime != 0) {
      return byTime;
    }
    return left.index.compareTo(right.index);
  });
  return <Message>[
    for (final entry in indexedMessages) entry.message,
  ];
}

class ChatHistoryStore {
  ChatHistoryStore(this._ref);

  final Ref _ref;

  db.AppDatabase get _db => _ref.read(databaseProvider);

  Future<({List<db.Message> messages, String version, String? boundary})>
      _editRevision(String conversationId) async {
    final conversation =
        await _ref.read(conversationRepositoryProvider).getById(conversationId);
    if (conversation == null || conversation.deletedAt != null) {
      throw StateError('会话已不存在，未更改历史');
    }
    final messages = await _ref
        .read(messageRepositoryProvider)
        .getAllByConversationOrderedStable(conversationId);
    final blocks = await _ref
        .read(messageBlockRepositoryProvider)
        .getByMessages(messages.map((m) => m.id).toList());
    blocks.sort((a, b) => a.id.compareTo(b.id));
    final version = sha256
        .convert(utf8.encode(jsonEncode([
          conversation.contextStartMessageId,
          messages.map((m) => m.toJson()).toList(),
          blocks.map((b) => b.toJson()).toList(),
        ])))
        .toString();
    return (
      messages: messages,
      version: version,
      boundary: conversation.contextStartMessageId
    );
  }

  int _editAnchorIndex(
      List<db.Message> messages, String messageId, String? boundary) {
    final index =
        messages.indexWhere((m) => m.id == messageId && m.role == 'user');
    if (index < 0) throw StateError('原用户消息已变化，请重新选择编辑');
    if (boundary != null && boundary.isNotEmpty) {
      final boundaryIndex = messages.indexWhere((m) => m.id == boundary);
      if (boundaryIndex < 0 || index <= boundaryIndex) {
        throw StateError('暂不支持编辑旧话题，请在当前话题重新发送');
      }
    }
    return index;
  }

  Future<ChatEditDraft> prepareEdit(String conversationId, String messageId) {
    return _db.transaction(() async {
      final revision = await _editRevision(conversationId);
      final index =
          _editAnchorIndex(revision.messages, messageId, revision.boundary);
      final original =
          await _buildRawMessageFromDbMessage(revision.messages[index]);
      return ChatEditDraft(
          conversationId: conversationId,
          messageId: messageId,
          historyVersion: revision.version,
          originalMessage: original);
    });
  }

  /// 唯一提交点：只按DB raw顺序截断；缓存/映射不是分支依据。
  Future<void> commitEdit(ChatEditDraft draft, Message replacement) async {
    for (final block in replacement.blocks ?? const <MessageBlock>[]) {
      final path = block is ImageBlock
          ? block.localPath
          : block is FileBlock
              ? block.filePath
              : null;
      if (path != null && (path.trim().isEmpty || !await File(path).exists())) {
        throw StateError('附件已不存在，原历史和编辑草稿均保留');
      }
    }
    await _db.transaction(() async {
      final revision = await _editRevision(draft.conversationId);
      if (revision.version != draft.historyVersion) {
        throw StateError('聊天记录已变化，未提交修改；请取消后重新编辑');
      }
      final index = _editAnchorIndex(
          revision.messages, draft.messageId, revision.boundary);
      final repo = _ref.read(messageRepositoryProvider);
      if (replacement.role != 'user' ||
          await repo.getById(replacement.id) != null) {
        throw StateError('新消息无效，未更改历史');
      }
      final ids = revision.messages.skip(index).map((m) => m.id).toList();
      final now = DateTime.now().millisecondsSinceEpoch;
      await _ref
          .read(messageBlockRepositoryProvider)
          .softDeleteByMessages(ids, now);
      await repo.softDeleteMany(
          ids, now, now + const Duration(days: 30).inMilliseconds);
      await _ref
          .read(messageProjectionMappingRepositoryProvider)
          .deleteByRawMessages(ids);
      await _upsertSingleMessage(draft.conversationId, replacement);
      await _ref.read(conversationRepositoryProvider).updateSummary(
          draft.conversationId,
          replacement.displayText,
          replacement.createdAt.millisecondsSinceEpoch);
    });
  }

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

  Future<void> recoverInterruptedUserMessages(
    String conversationId, {
    required bool Function(String messageId) isActiveSend,
  }) async {
    final recovered = await _ref
        .read(messageRepositoryProvider)
        .recoverInterruptedUserMessages(
          conversationId,
          isActiveSend: isActiveSend,
        );
    if (recovered.isEmpty) return;

    // Patch only affected messages: reloading the entire timeline would drop
    // a different, still-live send's transient assistant placeholders.
    final messages = <Message>[];
    for (final id in recovered) {
      messages.addAll(await _loadFrontendMessagesForMessageId(
        id,
        conversationId: conversationId,
      ));
    }
    if (messages.isNotEmpty) {
      await _ref.read(conversationTimelineCacheProvider).upsertMessages(
            conversationId: conversationId,
            messages: messages,
          );
    }
  }

  Future<List<Message>> loadCanonicalContextMessages(
    String conversationId, {
    int limit = 30,
  }) async {
    final conversation =
        await _ref.read(conversationRepositoryProvider).getById(conversationId);
    final allMessages = await loadAllRawMessages(conversationId);
    return _sliceCanonicalContextWindow(
      allMessages: allMessages,
      contextStartId: conversation?.contextStartMessageId,
      limit: limit,
    );
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

  Future<bool> isRawMessageActive({
    required String conversationId,
    required String messageId,
  }) async {
    final normalizedConversationId = conversationId.trim();
    final normalizedMessageId = messageId.trim();
    if (normalizedConversationId.isEmpty || normalizedMessageId.isEmpty) {
      return false;
    }
    final message =
        await _ref.read(messageRepositoryProvider).getById(normalizedMessageId);
    return message != null &&
        message.conversationId == normalizedConversationId &&
        message.deletedAt == null &&
        message.replacedBy == null;
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

  /// [updatePreview] false keeps the conversation list preview, for messages
  /// that are never shown (task control events).
  Future<void> appendUserMessage({
    required String conversationId,
    required Message message,
    required String displayText,
    bool updatePreview = true,
  }) async {
    await _clearStaleShortWindowIfConversationEmpty(conversationId);
    await _upsertMessages(
      conversationId: conversationId,
      messages: [message],
      previewText: displayText,
      previewTime: message.createdAt,
      updatePreview: updatePreview,
    );
  }

  Future<void> appendAssistantMessages({
    required String conversationId,
    required String userMessageId,
    required List<Message> messages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
  }) async {
    messages = markNewVoicesUnread(messages);
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

  /// Publishes enrichment as one existing raw-message snapshot. The compare
  /// prevents a slow plugin result from resurrecting or overwriting a synced edit.
  Future<bool> completeBackgroundMessageSnapshot({
    required db.Message original,
    required Message processedRaw,
    required List<Message> projectedMessages,
  }) async {
    if (projectedMessages.isEmpty) {
      throw StateError('Empty background projection');
    }
    final projected = _normalizeProjectedMessagesForStorage(
      rawMessageId: original.id,
      rawCreatedAt: DateTime.fromMillisecondsSinceEpoch(original.createdAt),
      messages: markNewVoicesUnread(projectedMessages),
    );
    // Preparation is complete: persist its resolved display text (including
    // failed-media text fallbacks), while rawReplyText remains model history.
    // Ready media positions are captured by the existing supplement insert ops.
    final displayText = StringBuffer();
    for (final message in projected) {
      final blocks = message.blocks;
      if (blocks == null || blocks.isEmpty) {
        displayText.write(message.content);
      } else {
        for (final block in blocks) {
          if (block is TextBlock) displayText.write(block.content);
          if (block is EmojiBlock) {
            final tag = block.matchedTag;
            if (tag != null && tag.isNotEmpty) {
              displayText.write('<sticker tag="${const HtmlEscape(HtmlEscapeMode.attribute).convert(tag)}"/>');
            }
          }
        }
      }
    }
    final resolvedRaw = processedRaw.copyWith(rawPayload: {
      ...?processedRaw.rawPayload,
      'displayReplyText': displayText.toString(),
      'processedText': displayText.toString(),
    });
    final enriched = _rawWithFrontendMessages(resolvedRaw, projected);
    final payload = ChatMessageProjectionCodec.removeProjectedMessages({
      ...Map<String, dynamic>.from(
        jsonDecode(original.rawPayload ?? '{}') as Map,
      ),
      ...?enriched.rawPayload,
      'bg_reprocessed': true,
    });
    final encoded = await EmbeddedMediaStore.shared.compactJson(
      jsonEncode(payload),
    );
    final committed = await cloudLocalWrite(
      () => _db.transaction(() async {
        final current = await _ref
            .read(messageRepositoryProvider)
            .getById(original.id);
        if (current == null ||
            current.deletedAt != null ||
            current.replacedBy != null ||
            current.rawPayload != original.rawPayload ||
            current.content != original.content ||
            current.createdAt != original.createdAt) {
          return false;
        }
        await (_db.update(_db.messages)..where((m) => m.id.equals(original.id)))
            .write(db.MessagesCompanion(rawPayload: Value(encoded)));
        await _syncProjectionMappingsForRawMessage(
          conversationId: original.conversationId,
          rawMessageId: original.id,
          projectedMessages: projected,
        );
        return true;
      }),
    );
    if (committed) {
      final cache = _ref.read(conversationTimelineCacheProvider);
      if (cache.isRawChangeInLoadedWindow(
        original.conversationId,
        original.id,
        original.createdAt,
      )) {
        final cached = await cache.loadCachedMessages(original.conversationId);
        // Patch this raw only; an unrelated foreground send may have transient
        // stream bubbles that a full database reload would discard.
        await cache.replaceMessagesTransient(
          conversationId: original.conversationId,
          removeMessageIds: [
            for (final message in cached)
              if (message.sourceMessageIdOrSelf == original.id) message.id,
          ],
          messages: projected,
        );
      }
    }
    return committed;
  }

  Future<void> appendAssistantRawMessage({
    required String conversationId,
    required String userMessageId,
    required Message rawMessage,
    required List<Message> projectedMessages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
    bool updateSummary = true,
    FutureOr<bool> Function()? shouldCommit,
  }) async {
    rawMessage = markNewVoicesUnread([rawMessage]).single;
    projectedMessages = markNewVoicesUnread(projectedMessages);
    Future<bool> commit() => _db.transaction(() async {
      if (shouldCommit != null && !await shouldCommit()) return false;
      final msgRepo = _ref.read(messageRepositoryProvider);
      if (userMessageId.trim().isNotEmpty) {
        await msgRepo.updateStatus(userMessageId, 'sent');
      }
      // The generation lives in memory; a stop during the await above is not
      // serialized by this transaction.
      if (shouldCommit != null && !await shouldCommit()) return false;
      await _upsertSingleMessage(
        conversationId,
        rawMessage.copyWith(
          rawPayload: ChatMessageProjectionCodec.removeProjectedMessages(
            rawMessage.rawPayload,
          ),
        ),
      );
      if (!updateSummary) return true;
      await _ref.read(conversationRepositoryProvider).updateSummary(
            conversationId,
            lastMessagePreview,
            rawMessage.createdAt.millisecondsSinceEpoch,
          );
      return true;
    });
    final committed = await cloudLocalWrite(commit);
    if (!committed) return;
    // 原文提交之后把会话状态算到链尾（ADR0071）；失败只记日志，下次读取自愈。
    unawaited(
      _ref.read(conversationStatePortProvider).refresh(conversationId),
    );

    if (projectedMessages.isNotEmpty) {
      await _syncProjectionMappingsForRawMessage(
        conversationId: conversationId,
        rawMessageId: rawMessage.id,
        projectedMessages: projectedMessages,
        shouldCommit: shouldCommit,
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
      final timelineCache = _ref.read(conversationTimelineCacheProvider);
      // 映射表已是 replace 语义；短窗时间线也必须清掉同 raw 的旧投影，
      // 否则流式收尾的多段文本 + 再次 deliver 的正文会叠成 3 条气泡。
      // 清旧与写新必须在同一次 replaceMessages 内完成：拆成两步会让订阅者
      // 观察到「同 raw 气泡全部消失」的中间帧，且第二步失败会留下半完成态。
      final staleIds = <String>[];
      if (projectedMessages.isNotEmpty) {
        final cached = await timelineCache.loadCachedMessages(conversationId);
        staleIds.addAll(<String>[
          for (final message in cached)
            if (message.sourceMessageId == rawMessage.id &&
                projectedMessages.every((keep) => keep.id != message.id))
              message.id,
        ]);
      }
      final shortWindowMessages = <Message>[
        ...updatedUserMessages,
        ...projectedMessages,
      ];
      if (shouldCommit != null && !await shouldCommit()) return;
      await timelineCache.replaceMessages(
        conversationId: conversationId,
        removeMessageIds: staleIds,
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
    FutureOr<bool> Function()? shouldCommit,
  }) async {
    message = markNewVoicesUnread([message]).single;
    final projectedMessage =
        await _normalizeProjectedMessageForFrontendMutation(
      conversationId: conversationId,
      message: message,
    );
    if (_isPendingImagePlaceholder(projectedMessage ?? message)) {
      if (shouldCommit != null && !await shouldCommit()) return;
      await _ref.read(conversationTimelineCacheProvider).replaceMessagesTransient(
        conversationId: conversationId, messages: [projectedMessage ?? message]);
      return;
    }
    if (projectedMessage != null) {
      if (shouldCommit != null && !await shouldCommit()) return;
      await _ref.read(conversationTimelineCacheProvider).upsertMessage(
            conversationId: conversationId,
            message: projectedMessage,
          );
      // A clear may land while the cache write is queued; it does not clear
      // the summary again afterwards.
      if (shouldCommit != null && !await shouldCommit()) return;
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
      shouldCommit: shouldCommit,
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
    FutureOr<bool> Function()? shouldCommit,
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
      rebuilt.addAll((slotMessages[0] ?? const <Message>[]).map((message) =>
        _atPendingImageAnchor(message, anchorMessages.first.createdAt)));
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
        final imageTime = leadingRelatedCount > 0
            ? bucket[leadingRelatedCount - 1].createdAt : anchorMessage.createdAt;
        rebuilt.addAll((slotMessages[i + 1] ?? const <Message>[]).map((message) =>
          _atPendingImageAnchor(message, imageTime)));
        rebuilt.addAll(bucket.skip(leadingRelatedCount));
      }
    }

    if (shouldCommit != null && !await shouldCommit()) return;
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

  Future<MediaRegenerationTarget> loadMediaRegenerationTarget({
    required String conversationId,
    required String messageId,
    required String blockId,
  }) async {
    final message = await loadFrontendMessageById(messageId,
        conversationId: conversationId);
    if (message == null ||
        message.id != messageId ||
        message.role != 'assistant' ||
        message.status == 'sending' ||
        _ref
            .read(conversationTimelineCacheProvider)
            .isMessageHidden(conversationId, message) ||
        !await isRawMessageActive(
            conversationId: conversationId,
            messageId: message.sourceMessageIdOrSelf)) {
      throw StateError('原消息已失效，无法重新生成媒体');
    }
    final block = message.blocks?.where((b) => b.id == blockId).firstOrNull;
    if (block == null ||
        !MediaRegenerationTarget.canRegenerate(message, block)) {
      throw StateError('此媒体缺少生成原文或尚未完成，无法重新生成');
    }
    final raw = await loadMessageById(message.sourceMessageIdOrSelf,
        conversationId: conversationId, preferProjection: false);
    if (raw == null || raw.role != 'assistant') {
      throw StateError('原消息已失效，无法重新生成媒体');
    }
    return MediaRegenerationTarget(
        message: message,
        block: block,
        rawRevision: _mediaRegenerationRevision(raw));
  }

  String _mediaRegenerationRevision(Message raw) => sha256
      .convert(utf8.encode(jsonEncode([
        raw.content,
        raw.status,
        raw.rawPayload,
        for (final block in raw.blocks ?? <MessageBlock>[])
          (block.toJson()
            ..remove('createdAt')
            ..remove('width')
            ..remove('height'))
      ])))
      .toString();

  /// Commit only after generation succeeds. Persist before publishing to the UI.
  Future<void> replaceGeneratedMedia({
    required String conversationId,
    required MediaRegenerationTarget target,
    required GeneratedChatMedia result,
  }) async {
    late Message replacement;
    await _db.transaction(() async {
      final current = await loadMediaRegenerationTarget(
          conversationId: conversationId,
          messageId: target.message.id,
          blockId: target.block.id);
      if (current.rawRevision != target.rawRevision ||
          !MediaRegenerationTarget.sameSource(current.block, target.block)) {
        throw StateError('原消息已改变，未覆盖现有媒体');
      }
      final generated = result.replace(current.block);
      MessageBlock replaceBlock(MessageBlock original) =>
          _preserveMediaBlockIdentity(original, generated);
      replacement = current.message.copyWith(blocks: [
        for (final block in current.message.blocks!)
          if (block.id == current.block.id) replaceBlock(block) else block,
      ]);
      final rawId = current.message.sourceMessageIdOrSelf;
      final raw = (await loadMessageById(rawId,
          conversationId: conversationId, preferProjection: false))!;
      if (_isProjectedFrontendMessage(current.message)) {
        // Rebuild all siblings from the persisted raw payload, not the short
        // viewport window, so replacing old media cannot drop other parts.
        final siblings = _projectRawMessagesForFrontendSurface([raw]);
        if (!siblings.any((m) => m.id == current.message.id)) {
          throw StateError('原媒体尚未保存完成，请稍后重试');
        }
        final next = [
          for (final sibling in siblings)
            sibling.copyWith(blocks: [
              for (final block in sibling.blocks ?? const <MessageBlock>[])
                if (block.id == current.block.id && MediaRegenerationTarget.sameSource(block, current.block))
                  replaceBlock(block)
                else block,
            ]),
        ];
        final updatedRaw =
            _replaceRawMediaAttachment(
              raw, siblings, current.message, current.block, replaceBlock);
        await _upsertSingleMessage(
            conversationId, _rawWithReplacedMedia(updatedRaw, next));
      } else {
        await _upsertSingleMessage(
            conversationId, raw.copyWith(blocks: replacement.blocks));
      }
    });
    await _ref
        .read(conversationTimelineCacheProvider)
        .upsertMessage(conversationId: conversationId, message: replacement);
  }

  /// Persist the selected page version before publishing it to the timeline.
  Future<void> selectImageVersion({
    required String conversationId,
    required String messageId,
    required String blockId,
    required int versionIndex,
  }) async {
    late Message replacement;
    await _db.transaction(() async {
      final candidate = await loadFrontendMessageById(
        messageId,
        conversationId: conversationId,
      );
      if (candidate == null ||
          candidate.id != messageId ||
          !await isRawMessageActive(
            conversationId: conversationId,
            messageId: candidate.sourceMessageIdOrSelf,
          )) {
        throw StateError('原消息已失效，无法切换图片版本');
      }
      final raw = (await loadMessageById(
        candidate.sourceMessageIdOrSelf,
        conversationId: conversationId,
        preferProjection: false,
      ))!;
      // The viewport can be stale or incomplete. Resolve the page and all its
      // siblings from the current persisted raw inside the same transaction.
      final siblings = _projectRawMessagesForFrontendSurface([raw]);
      final message = siblings.where((m) => m.id == messageId).firstOrNull;
      final block = message?.blocks?.where((b) => b.id == blockId).firstOrNull;
      if (message == null ||
          message.role != 'assistant' ||
          message.status == 'sending' ||
          block is! ImageBlock ||
          _ref
              .read(conversationTimelineCacheProvider)
              .isMessageHidden(conversationId, message)) {
        throw StateError('原图片已失效，无法切换图片版本');
      }
      final selected = block.withActiveVersion(versionIndex);
      replacement = message.copyWith(blocks: [
        for (final current in message.blocks!)
          if (current.id == blockId) selected else current,
      ]);
      if (_isProjectedFrontendMessage(message)) {
        final updatedRaw = _replaceRawMediaAttachment(
          raw,
          siblings,
          message,
          block,
          (current) => _preserveMediaBlockIdentity(current, selected),
        );
        final next = [
          for (final sibling in siblings)
            if (sibling.id == messageId) replacement else sibling,
        ];
        await _upsertSingleMessage(
          conversationId,
          _rawWithReplacedMedia(updatedRaw, next),
        );
      } else {
        await _upsertSingleMessage(
          conversationId,
          raw.copyWith(blocks: replacement.blocks),
        );
      }
    });
    if (await isRawMessageActive(
      conversationId: conversationId,
      messageId: replacement.sourceMessageIdOrSelf,
    )) {
      await _ref.read(conversationTimelineCacheProvider).upsertMessage(
        conversationId: conversationId,
        message: replacement,
      );
    }
  }

  MessageBlock _preserveMediaBlockIdentity(
    MessageBlock original,
    MessageBlock replacement,
  ) =>
      MessageBlock.fromJson({
        ...replacement.toJson(),
        'id': original.id,
        'messageId': original.messageId,
        'createdAt': original.createdAt.toIso8601String(),
      });

  Message _rawWithReplacedMedia(Message raw, List<Message> siblings) {
    if (ChatMessageProjectionCodec.hasProjectionSemantics(raw.rawPayload)) {
      return _rawWithFrontendMessages(raw, siblings);
    }
    // Legacy snapshots may group text, several images and audio in one bubble.
    // Keep that shape and its IDs instead of migrating it into single-media
    // supplement ops. Mixed raw blocks need no display-payload conversion.
    return raw.rawPayload?['projectedMessages'] is List
        ? raw.copyWith(
            rawPayload: ChatMessageProjectionCodec.copyWithProjectedMessages(
              raw.rawPayload, siblings),
          )
        : raw;
  }

  /// 把挂断后整理好的摘要补进通话气泡（ADR0074 决定 4）。
  ///
  /// 只在气泡仍然有效、仍是这通电话时写：已删、被编辑替换或块已变化就放弃。
  /// 只改这一块，不改会话预览和时间。返回是否写入。
  Future<bool> attachCallSummary({
    required String conversationId,
    required String messageId,
    required String callId,
    required String summary,
  }) async {
    Message? updated;
    await _db.transaction(() async {
      if (!await isRawMessageActive(
        conversationId: conversationId,
        messageId: messageId,
      )) {
        return;
      }
      final raw = await loadMessageById(
        messageId,
        conversationId: conversationId,
        preferProjection: false,
      );
      final blocks = raw?.blocks;
      final index = blocks?.indexWhere(
            (b) => b is CallRecordBlock && b.callId == callId,
          ) ??
          -1;
      if (raw == null || index < 0) return;
      final block = (blocks![index] as CallRecordBlock).withSummary(summary);
      updated = raw.copyWith(
        content: block.content,
        blocks: [...blocks]..[index] = block,
      );
      await _upsertSingleMessage(conversationId, updated!);
    });
    final message = updated;
    if (message == null) return false;
    // 事务之后又被删掉的，不再放回聊天缓存。
    if (!await isRawMessageActive(
      conversationId: conversationId,
      messageId: messageId,
    )) {
      return true;
    }
    final frontend = _projectRawMessagesForFrontendSurface([message]);
    await _ref.read(conversationTimelineCacheProvider).upsertMessages(
          conversationId: conversationId,
          messages: frontend.isNotEmpty ? frontend : [message],
        );
    return true;
  }

  Message _replaceRawMediaAttachment(Message raw, List<Message> siblings,
      Message targetMessage, MessageBlock targetBlock,
      MessageBlock Function(MessageBlock) replace) {
    bool matches(MessageBlock block) =>
        MediaRegenerationTarget.sameSource(block, targetBlock);
    final candidates = (raw.blocks ?? <MessageBlock>[]).where(matches).toList();
    if (candidates.isEmpty) return raw;

    // Repeated uses of one source are distinct media occurrences.
    var occurrence = 0;
    for (final sibling in siblings) {
      final blocks = (sibling.id == targetMessage.id
              ? targetMessage.blocks
              : sibling.blocks) ??
          <MessageBlock>[];
      for (final block in blocks) {
        if (sibling.id == targetMessage.id && block.id == targetBlock.id) {
          if (occurrence >= candidates.length) {
            throw StateError('原媒体来源已改变，未覆盖现有媒体');
          }
          final original = candidates[occurrence];
          return raw.copyWith(blocks: [
            for (final rawBlock in raw.blocks!)
              if (rawBlock.id == original.id)
                replace(rawBlock)
              else
                rawBlock,
          ]);
        }
        if (matches(block)) occurrence++;
      }
    }
    throw StateError('原媒体来源已改变，未覆盖现有媒体');
  }

  Future<void> updateMessage({
    required String conversationId,
    required Message message,
    String? lastMessagePreview,
    FutureOr<bool> Function()? shouldCommit,
  }) async {
    final projectedMessage =
        await _normalizeProjectedMessageForFrontendMutation(
      conversationId: conversationId,
      message: message,
    );
    if (_isPendingImagePlaceholder(projectedMessage ?? message)) {
      if (shouldCommit != null && !await shouldCommit()) return;
      await _ref.read(conversationTimelineCacheProvider).replaceMessagesTransient(
        conversationId: conversationId, messages: [projectedMessage ?? message]);
      return;
    }
    if (projectedMessage != null) {
      if (shouldCommit != null && !await shouldCommit()) return;
      await _ref.read(conversationTimelineCacheProvider).upsertMessage(
            conversationId: conversationId,
            message: projectedMessage,
          );
      // A clear may land while the cache write is queued; it does not clear
      // the summary again afterwards.
      if (shouldCommit != null && !await shouldCommit()) return;
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
        textReplacement: projectedMessage,
      );
      return;
    }

    final committed = await _db.transaction(() async {
      if (shouldCommit != null && !await shouldCommit()) return false;
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
      return true;
    });
    if (!committed || (shouldCommit != null && !await shouldCommit())) return;
    final frontendMessages =
        _projectRawMessagesForFrontendSurface(<Message>[message]);
    await _ref.read(conversationTimelineCacheProvider).upsertMessages(
          conversationId: conversationId,
          messages: frontendMessages.isNotEmpty
              ? frontendMessages
              : <Message>[message],
        );
  }

  /// Edits only an active raw text message. Rich replies must keep using
  /// their dedicated editors so semantic payloads and display cannot diverge.
  Future<Message> updateRawMessageText({
    required String conversationId,
    required String messageId,
    String? content,
    String? oldText,
    String? newText,
    FutureOr<void> Function()? ensureWritable,
  }) async {
    final updated = await _db.transaction(() async {
      await ensureWritable?.call();
      final owner = await _ref
          .read(conversationRepositoryProvider)
          .getById(conversationId);
      final row = await _ref.read(messageRepositoryProvider).getById(messageId);
      if (owner == null ||
          owner.deletedAt != null ||
          owner.isHidden ||
          row == null ||
          row.conversationId != conversationId ||
          row.deletedAt != null ||
          row.replacedBy != null ||
          row.status == 'sending') {
        throw StateError('消息不存在、不属于这个角色或正在生成，未修改');
      }
      final raw = await _buildRawMessageFromDbMessage(row);
      final storedBlocks = await _ref
          .read(messageBlockRepositoryProvider)
          .getByMessage(messageId);
      if (raw == null ||
          storedBlocks.length != (raw.blocks?.length ?? 0) ||
          (raw.role != 'user' && raw.role != 'assistant') ||
          (raw.blocks?.length ?? 0) > 1 ||
          (raw.blocks?.isNotEmpty == true &&
              (raw.blocks!.single.runtimeType != TextBlock ||
                  (raw.blocks!.single as TextBlock).content != raw.content))) {
        throw StateError('这条消息包含附件、工具步骤或复杂显示内容，不能直接修改正文');
      }
      // Ordinary assistant replies carry this payload too. Keep their raw,
      // processed and display copies aligned instead of rejecting all replies.
      final payload = raw.rawPayload;
      Map<String, dynamic>? nextPayload;
      const textFields = {'rawReplyText', 'displayReplyText', 'processedText'};
      const emptyFields = {
        'pluginEvents',
        'pluginContents',
        'toolAudioResults',
        'toolCalls',
        'rawToolResults',
        'projectedMessages',
        'supplementInsertOps',
      };
      const metadataFields = {
        'version',
        'runStatus',
        'stopReason',
        'reasoning',
        'hiddenThoughtParts',
      };
      bool empty(Object? value) =>
          value == null || (value is List && value.isEmpty);
      if (payload?.isNotEmpty == true) {
        if (raw.role != 'assistant' ||
            payload!.keys.any(
              (key) =>
                  !textFields.contains(key) &&
                  !emptyFields.contains(key) &&
                  !metadataFields.contains(key) &&
                  key != 'replyRounds',
            ) ||
            textFields.any(
              (key) => payload.containsKey(key) && payload[key] != raw.content,
            ) ||
            emptyFields.any((key) => !empty(payload[key]))) {
          throw StateError('这条回复包含工具、附件或与原文不同的显示内容，不能直接修改正文');
        }
        final rounds = payload['replyRounds'];
        if (rounds != null &&
            (rounds is! List ||
                rounds.length > 1 ||
                rounds.any(
                  (round) =>
                      round is! Map ||
                      round.keys.any(
                        (key) => !const {
                          'replyText',
                          'rawText',
                          'processedText',
                          'reasoning',
                          'pluginEvents',
                          'pluginContents',
                          'toolCallIds',
                        }.contains(key),
                      ) ||
                      const ['replyText', 'rawText', 'processedText'].any(
                        (key) =>
                            round.containsKey(key) && round[key] != raw.content,
                      ) ||
                      const [
                        'pluginEvents',
                        'pluginContents',
                        'toolCallIds',
                      ].any((key) => !empty(round[key])),
                ))) {
          throw StateError('这条回复包含多轮或复杂显示内容，不能直接修改正文');
        }
        nextPayload = Map<String, dynamic>.from(payload);
      }
      String text;
      if (content != null && oldText == null && newText == null) {
        text = content;
      } else if (content == null &&
          oldText != null &&
          oldText.isNotEmpty &&
          newText != null) {
        final index = raw.content.indexOf(oldText);
        if (index < 0 || raw.content.indexOf(oldText, index + 1) >= 0) {
          throw StateError('要替换的原文必须精确出现一次，未修改');
        }
        text = raw.content.replaceFirst(oldText, newText);
      } else {
        throw ArgumentError('请提供完整 content，或同时提供 old_text 和 new_text');
      }
      if (text.trim().isEmpty) throw ArgumentError('消息正文不能为空');
      if (nextPayload != null) {
        for (final key in textFields) {
          if (nextPayload.containsKey(key)) nextPayload[key] = text;
        }
        if (nextPayload['replyRounds'] is List) {
          nextPayload['replyRounds'] = [
            for (final round in nextPayload['replyRounds'] as List)
              {
                ...Map<String, dynamic>.from(round as Map),
                for (final key in const [
                  'replyText',
                  'rawText',
                  'processedText',
                ])
                  if (round.containsKey(key)) key: text,
              },
          ];
        }
      }
      await ensureWritable?.call();
      final next = raw.copyWith(
        content: text,
        rawPayload: nextPayload,
        blocks: raw.blocks
            ?.map((block) => (block as TextBlock).copyWith(content: text))
            .toList(),
      );
      await (_db.update(
        _db.messages,
      )..where((m) => m.id.equals(messageId))).write(
        db.MessagesCompanion(
          content: Value(text),
          rawPayload: Value(
            next.rawPayload == null ? null : jsonEncode(next.rawPayload),
          ),
        ),
      );
      for (final block in storedBlocks) {
        final data = Map<String, dynamic>.from(jsonDecode(block.data) as Map);
        data['content'] = text;
        await (_db.update(_db.messageBlocks)..where(
              (b) => b.id.equals(block.id) & b.messageId.equals(messageId),
            ))
            .write(db.MessageBlocksCompanion(data: Value(jsonEncode(data))));
      }
      // An edit to an old message must not become the conversation preview.
      await _refreshSummary(conversationId);
      return next;
    });
    await _removeMessagesFromShortWindowByRawIds(
      conversationId: conversationId,
      rawMessageIds: {messageId},
    );
    final projected = _projectRawMessagesForFrontendSurface([updated]);
    await _ref
        .read(conversationTimelineCacheProvider)
        .upsertMessages(
          conversationId: conversationId,
          messages: projected.isEmpty ? [updated] : projected,
        );
    return updated;
  }

  Future<void> hideMessagesInFrontendTimeline(
    String conversationId,
    List<String> messageIds, {
    List<String> pieceIds = const <String>[],
  }) async {
    if (messageIds.isEmpty && pieceIds.isEmpty) {
      return;
    }

    final frontendMessages = await _loadBestEffortFrontendMessages(
      conversationId,
    );
    final frontendMessagesById = <String, Message>{
      for (final message in frontendMessages) message.id: message,
    };
    final hiddenRawMessageIds = <String>{};
    final hiddenProjectedMessageIds = <String>{};

    for (final messageId in messageIds) {
      final normalizedMessageId = messageId.trim();
      if (normalizedMessageId.isEmpty) {
        continue;
      }
      final message =
          frontendMessagesById[normalizedMessageId] ??
          await _loadBestEffortFrontendMessageById(
            normalizedMessageId,
            conversationId: conversationId,
          );
      if (message == null) {
        continue;
      }
      if (_isProjectedFrontendMessage(message)) {
        hiddenProjectedMessageIds.add(message.id);
      } else {
        hiddenRawMessageIds.add(message.id);
      }
    }

    if (hiddenRawMessageIds.isEmpty &&
        hiddenProjectedMessageIds.isEmpty &&
        pieceIds.isEmpty) {
      return;
    }

    await _ref
        .read(conversationTimelineCacheProvider)
        .hideMessages(
          conversationId: conversationId,
          rawMessageIds: hiddenRawMessageIds.toList(growable: false),
          pieceIds: pieceIds,
          projectedMessageIds: hiddenProjectedMessageIds.toList(
            growable: false,
          ),
        );
  }

  /// Resolve document-mode anchors against the complete canonical history.
  Future<Set<String>> resolveTimelineDeleteRawMessageIds(
    String conversationId,
    ChatTimelineDeletePlan plan,
  ) async {
    final ids = plan.rawMessageIdsToDelete.toSet();
    if (plan.turnAnchorMessageIdsToDelete.isEmpty) return ids;
    final allRaw = await loadAllRawMessages(conversationId);
    for (final anchor in plan.turnAnchorMessageIdsToDelete) {
      final rawId = await _timelineEntryRawMessageId(conversationId, anchor);
      final index = allRaw.indexWhere((message) => message.id == rawId);
      if (index < 0) continue;
      ids.add(allRaw[index].id);
      if (allRaw[index].role != 'assistant') continue;
      var left = index;
      var right = index;
      while (left > 0 && allRaw[left - 1].role != 'user') {
        left--;
      }
      while (right + 1 < allRaw.length && allRaw[right + 1].role != 'user') {
        right++;
      }
      ids.addAll(allRaw.sublist(left, right + 1).map((message) => message.id));
    }
    return ids;
  }

  Future<String> _timelineEntryRawMessageId(
    String conversationId,
    String id,
  ) async {
    final parentId = ChatTimelinePieceId.parentMessageIdOf(id) ?? id;
    final cached = await _ref
        .read(conversationTimelineCacheProvider)
        .findCachedMessageById(parentId, conversationId: conversationId);
    if (cached != null) {
      return ChatTimelinePieceId.rawMessageIdOf(
        parentId,
        explicitSourceId: cached.sourceMessageId,
      );
    }
    final mapping = await _ref
        .read(messageProjectionMappingRepositoryProvider)
        .getByProjectedMessageId(parentId, conversationId: conversationId);
    return ChatTimelinePieceId.rawMessageIdOf(
      parentId,
      explicitSourceId: mapping?.rawMessageId,
    );
  }

  Future<void> executeTimelineDeletePlan(
    String conversationId,
    ChatTimelineDeletePlan plan,
  ) async {
    final rawIds = await resolveTimelineDeleteRawMessageIds(
      conversationId,
      plan,
    );
    // Resolve aliases before soft deletion removes their projection mappings.
    final projectedIds = <String>[];
    final pieceIds = <String>[];
    for (final id in plan.projectedMessageIdsToHide) {
      if (!rawIds.contains(
        await _timelineEntryRawMessageId(conversationId, id),
      )) {
        projectedIds.add(id);
      }
    }
    for (final id in plan.pieceIdsToHide) {
      if (!rawIds.contains(
        await _timelineEntryRawMessageId(conversationId, id),
      )) {
        pieceIds.add(id);
      }
    }
    if (rawIds.isNotEmpty) {
      await softDeleteMessages(
        conversationId,
        rawIds.toList(),
        shiftContextStartIfDeleted: true,
      );
    }
    if (projectedIds.isNotEmpty || pieceIds.isNotEmpty) {
      await hideMessagesInFrontendTimeline(
        conversationId,
        projectedIds,
        pieceIds: pieceIds,
      );
    }
  }

  Future<void> softDeleteMessages(
    String conversationId,
    List<String> messageIds, {
    bool clearContextStartIfDeleted = false,
    bool shiftContextStartIfDeleted = false,
  }) async {
    if (messageIds.isEmpty) return;
    final timelineCache = _ref.read(conversationTimelineCacheProvider);
    final allFrontendMessages = await _loadBestEffortFrontendMessages(
      conversationId,
    );
    final frontendMessagesById = <String, Message>{
      for (final message in allFrontendMessages) message.id: message,
    };
    final projectedMessages = <Message>[];
    for (final id in messageIds) {
      final message =
          frontendMessagesById[id] ??
          await _loadBestEffortFrontendMessageById(
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
    final projectedOnlyIdSet = projectedOnlyIds.toSet();
    final rawDeleteIds = <String>{
      for (final id in messageIds)
        if (!projectedOnlyIdSet.contains(id)) id,
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
        final frontendIds = frontendIdsByRaw[rawMessageId];
        if (frontendIds == null ||
            frontendIds.isEmpty ||
            frontendIds.difference(deleteIds).isEmpty) {
          rawDeleteIds.add(rawMessageId);
          return;
        }
        rawMessageIdsToResync.add(rawMessageId);
      });
    }
    if (projectedOnlyIds.isNotEmpty) {
      final hiddenTextIds = [
        for (final message in projectedMessages)
          if (rawMessageIdsToResync.contains(message.sourceMessageId) &&
              !(message.blocks?.any(
                    (block) =>
                        block is ImageBlock ||
                        block is AudioBlock ||
                        block is EmojiBlock,
                  ) ??
                  false))
            message.id,
      ];
      if (hiddenTextIds.isNotEmpty) {
        await timelineCache.hideMessages(
          conversationId: conversationId,
          projectedMessageIds: hiddenTextIds,
        );
      }
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
    final mappingRepo = _ref.read(messageProjectionMappingRepositoryProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000;

    await _db.transaction(() async {
      final ownedRows =
          await (_db.select(_db.messages)..where(
                (t) =>
                    t.conversationId.equals(conversationId) &
                    t.id.isIn(rawDeleteIds) &
                    t.deletedAt.isNull(),
              ))
              .get();
      rawDeleteIds.retainAll(ownedRows.map((row) => row.id));
      if (rawDeleteIds.isEmpty) return;
      final conv = await convRepo.getById(conversationId);
      if (conv != null &&
          rawDeleteIds.contains(conv.contextStartMessageId) &&
          (clearContextStartIfDeleted || shiftContextStartIfDeleted)) {
        String? previousId;
        if (!clearContextStartIfDeleted) {
          final ordered =
              await (_db.select(_db.messages)
                    ..where((t) => t.conversationId.equals(conversationId))
                    ..orderBy([
                      (t) => OrderingTerm.asc(t.createdAt),
                      (t) => OrderingTerm.asc(t.id),
                    ]))
                  .get();
          for (final row in ordered) {
            if (row.id == conv.contextStartMessageId) break;
            if (row.deletedAt == null &&
                row.replacedBy == null &&
                !rawDeleteIds.contains(row.id)) {
              previousId = row.id;
            }
          }
        }
        await (_db.update(
          _db.conversations,
        )..where((t) => t.id.equals(conversationId))).write(
          db.ConversationsCompanion(contextStartMessageId: Value(previousId)),
        );
      }
      final rawDeleteIdList = rawDeleteIds.toList(growable: false);
      await blockRepo.softDeleteByMessages(rawDeleteIdList, now);
      await msgRepo.softDeleteMany(rawDeleteIdList, now, purgeAt);
    });
    if (rawDeleteIds.isEmpty) return;
    await timelineCache.clearHiddenEntriesForRawMessages(
      conversationId: conversationId,
      rawMessageIds: rawDeleteIds,
    );
    await mappingRepo.deleteByRawMessages(rawDeleteIds.toList(growable: false));
    await _removeMessagesFromShortWindowByRawIds(
      conversationId: conversationId,
      rawMessageIds: rawDeleteIds,
    );
    await _refreshSummary(conversationId);
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
    final commit = await prepareTruncateAfterMessage(
      conversationId: conversationId,
      anchorMessageId: anchorMessageId,
    );
    await commit();
  }

  /// 先记下锚点之后的消息，调用返回的回调才真正删除。
  ///
  /// 删除范围在准备时就固定，之后写入时间线的流式占位不会被一起删掉。
  Future<Future<void> Function()> prepareTruncateAfterMessage({
    required String conversationId,
    required String anchorMessageId,
  }) async {
    final lookup = await _loadFrontendMessagesForRangeLookup(
      conversationId: conversationId,
      anchorMessageId: anchorMessageId,
    );
    final range = lookup.range;
    if (range == null) return () async {};
    final anchorMessages = List<Message>.unmodifiable(
      lookup.messages.sublist(range.$1, range.$2 + 1),
    );
    final ids = [
      for (final message in lookup.messages.skip(range.$2 + 1)) message.id,
    ];
    return () async {
      await softDeleteMessages(conversationId, ids);
      await _restoreShortWindowMessagesIfMissing(
        conversationId: conversationId,
        messages: anchorMessages,
      );
    };
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
    bool updatePreview = true,
    FutureOr<bool> Function()? shouldCommit,
  }) async {
    if (messages.isEmpty) return;
    final frontendMessages = _projectRawMessagesForFrontendSurface(messages);
    final effectiveTailMessage =
        frontendMessages.isNotEmpty ? frontendMessages.last : messages.last;
    final effectivePreviewTime = frontendMessages.isNotEmpty
        ? effectiveTailMessage.createdAt
        : previewTime;
    final committed = await _db.transaction(() async {
      if (shouldCommit != null && !await shouldCommit()) return false;
      for (final message in messages) {
        await _upsertSingleMessage(conversationId, message);
      }
      if (!updatePreview) return true;
      await _ref.read(conversationRepositoryProvider).updateSummary(
            conversationId,
            effectiveTailMessage.displayText.isNotEmpty
                ? effectiveTailMessage.displayText
                : previewText,
            effectivePreviewTime.millisecondsSinceEpoch,
          );
      return true;
    });
    if (!committed || (shouldCommit != null && !await shouldCommit())) return;
    await _ref.read(conversationTimelineCacheProvider).upsertMessages(
          conversationId: conversationId,
          messages: frontendMessages.isNotEmpty ? frontendMessages : messages,
        );
  }

  Future<void> _clearStaleShortWindowIfConversationEmpty(
    String conversationId,
  ) async {
    final timelineCache = _ref.read(conversationTimelineCacheProvider);
    final staleMessages =
        await timelineCache.loadCachedMessages(conversationId);
    if (staleMessages.isEmpty) {
      return;
    }
    final messageCount =
        await _ref.read(messageRepositoryProvider).countByConversation(
              conversationId,
            );
    if (messageCount > 0) {
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

    // 补写调用方不一定有外层事务：消息与所有内容块必须原子替换。
    // 已有外层事务时使用嵌套事务，外层失败仍会回滚本次写入。
    await _db.transaction(() async {
      await msgRepo.upsert(
        MessageConverter.toCompanion(message, conversationId),
      );
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
    });
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

  List<Message> _projectRawMessages(List<Message> rawMessages) =>
      _projectRawMessagesForFrontendSurface(rawMessages);

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

  List<Message> _sliceCanonicalContextWindow({
    required List<Message> allMessages,
    required String? contextStartId,
    required int limit,
  }) {
    final contextWindow = sliceConversationContext(allMessages, contextStartId);

    if (limit <= 0 || contextWindow.length <= limit) {
      return contextWindow;
    }
    return contextWindow.sublist(contextWindow.length - limit);
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

  Future<void> syncRawSupplementsFromTimeline({
    required String conversationId,
    required Set<String> rawMessageIds,
  }) {
    return _syncRawSupplementsFromTimeline(
      conversationId: conversationId,
      rawMessageIds: rawMessageIds,
    );
  }

  Future<void> _syncRawSupplementsFromTimeline({
    required String conversationId,
    required Set<String> rawMessageIds,
    Message? textReplacement,
  }) async {
    if (rawMessageIds.isEmpty) {
      return;
    }
    await cloudLocalWrite(() async {
      final timelineMessages = await _ref
          .read(conversationTimelineCacheProvider)
          .loadCachedMessages(conversationId);
      await _db.transaction(() async {
        for (final rawMessageId in rawMessageIds) {
          // Read canonical storage inside both locks. A deleted raw must never
          // fall back to a stale timeline snapshot and be written back.
          final current = await _ref
              .read(messageRepositoryProvider)
              .getById(rawMessageId);
          if (current == null ||
              current.conversationId != conversationId ||
              current.deletedAt != null ||
              current.replacedBy != null) {
            continue;
          }
          var rawMessage = await _buildRawMessageFromDbMessage(current);
          if (rawMessage == null) continue;
          if (textReplacement != null) {
            rawMessage = _withProjectedTextReplacement(rawMessage, textReplacement);
          }
          final sourceTimelineMessages = <Message>[
            for (final message in timelineMessages)
              if (message.sourceMessageId == rawMessageId) message,
          ];
          final nextRaw =
              _rawWithFrontendMessages(rawMessage, sourceTimelineMessages);
          if (textReplacement == null &&
              nextRaw.content == rawMessage.content &&
              jsonEncode(nextRaw.rawPayload) == jsonEncode(rawMessage.rawPayload)) {
            continue;
          }
          await _upsertSingleMessage(conversationId, nextRaw);
        }
      });
    });
  }
  Message _withProjectedTextReplacement(Message raw, Message replacement) {
    if (replacement.blocks?.any((block) => block is! TextBlock) ?? false)
      return raw;
    final payload = raw.rawPayload;
    final display = ChatMessageProjectionCodec.displayReplyText(payload);
    if (display == null) return raw;
    final projected = _ref
        .read(chatFrontendMessageProjectionServiceProvider)
        .projectMessage(raw);
    final before = projected.where((m) => m.id == replacement.id).firstOrNull;
    final oldText = before == null ? '' : _extractText(before);
    final newText = _extractText(replacement);
    if (oldText.isEmpty || oldText == newText || !display.contains(oldText))
      return raw;
    final next = <String, dynamic>{...payload!};
    next['displayReplyText'] = display.replaceFirst(oldText, newText);
    final processed = ChatMessageProjectionCodec.processedText(payload);
    if (processed != null)
      next['processedText'] = processed.replaceFirst(oldText, newText);
    final rounds = payload['replyRounds'];
    final roundMatch = RegExp(
      '${RegExp.escape(raw.id)}__proj_r(\\d+)_',
    ).firstMatch(replacement.id);
    final roundIndex = roundMatch == null
        ? null
        : int.tryParse(roundMatch.group(1)!);
    if (rounds is List && roundIndex != null) {
      next['replyRounds'] = [
        for (final (index, value) in rounds.indexed)
          if (index == roundIndex && value is Map)
            {
              ...value,
              if (value['replyText'] is String)
                'replyText': (value['replyText'] as String).replaceFirst(
                  oldText,
                  newText,
                ),
              if (value['processedText'] is String)
                'processedText': (value['processedText'] as String)
                    .replaceFirst(oldText, newText),
            }
          else
            value,
      ];
      for (final field in ['replyText', 'processedText']) {
        next[field == 'replyText' ? 'displayReplyText' : field] =
            (next['replyRounds'] as List)
                .whereType<Map>()
                .map((round) => (round[field] as String? ?? '').trim())
                .where((text) => text.isNotEmpty)
                .join('\n');
      }
    }
    return raw.copyWith(rawPayload: next);
  }

  Message _rawWithFrontendMessages(
    Message rawMessage,
    List<Message> sourceTimelineMessages,
  ) {
    final normalizedTimelineMessages = _normalizeProjectedMessagesForStorage(
      rawMessageId: rawMessage.id,
      rawCreatedAt: rawMessage.createdAt,
      messages: sourceTimelineMessages,
    );
    final nextPluginContents = _collectSemanticPluginContents(
      sourceTimelineMessages,
    );
    final nextToolAudioResults = _collectSemanticToolAudioResults(
      sourceTimelineMessages,
    );
    final nextSupplementInsertOps = _collectSupplementInsertOps(
      sourceTimelineMessages,
    );
    final normalizedRawPayload =
        ChatMessageProjectionCodec.copyWithSupplementInsertOps(
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
        );
    // Semantic payloads reproject on every device. Only truly legacy rows
    // without a reconstructable field retain a display-only fallback.
    final nextRawPayload =
        ChatMessageProjectionCodec.hasProjectionSemantics(normalizedRawPayload)
        ? ChatMessageProjectionCodec.removeProjectedMessages(
            normalizedRawPayload,
          )
        : ChatMessageProjectionCodec.copyWithProjectedMessages(
            normalizedRawPayload,
            normalizedTimelineMessages,
          );
    return rawMessage.copyWith(rawPayload: nextRawPayload);
  }
  List<Message> _normalizeProjectedMessagesForStorage({
    required String rawMessageId,
    required DateTime rawCreatedAt,
    required List<Message> messages,
  }) {
    Message normalize(Message message) {
      final blocks = message.blocks;
      var content = message.content;
      final normalizedBlocks = blocks == null
          ? null
          : <MessageBlock>[
              for (final block in blocks)
                if (block is AudioBlock &&
                    (block.url.trim().isEmpty ||
                        block.status == BlockStatus.pending) &&
                    (block.text?.trim().isNotEmpty ?? false))
                  TextBlock(
                    id: block.id,
                    messageId: message.id,
                    content: block.text!.trim(),
                    status: BlockStatus.success,
                    createdAt: block.createdAt,
                  )
                else if (!_isUnresolvedImageBlock(block))
                  block,
            ];
      if (content.trim().isEmpty &&
          blocks?.length == 1 &&
          blocks!.single is AudioBlock &&
          normalizedBlocks!.single is TextBlock) {
        content = (normalizedBlocks.single as TextBlock).content;
      }
      return message.copyWith(
        sourceMessageId: rawMessageId,
        createdAt: rawCreatedAt,
        content: content,
        blocks: normalizedBlocks,
        rawPayload: null,
      );
    }

    return messages.map(normalize).where((message) =>
      message.content.trim().isNotEmpty || message.blocks?.isNotEmpty == true).toList(growable: false);
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
    final separator = messageId.lastIndexOf('__proj_');
    if (separator > 0) {
      final raw = await loadMessageById(
        messageId.substring(0, separator),
        conversationId: conversationId,
        preferProjection: false,
      );
      if (raw != null) {
        final projected = _projectRawMessagesForFrontendSurface([raw]);
        for (final message in projected) {
          if (message.id == messageId) return message;
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
    FutureOr<bool> Function()? shouldCommit,
  }) async {
    final normalizedRawMessageId = rawMessageId.trim();
    if (normalizedRawMessageId.isEmpty) {
      return;
    }
    if (projectedMessages.every((m) => ChatMessageProjectionCodec.isCanonicalProjectionId(normalizedRawMessageId, m.id))) {
      return;
    }
    final normalizedProjectedMessages = <Message>[
      for (final message in projectedMessages)
        if (message.id.trim().isNotEmpty)
          message.sourceMessageId == normalizedRawMessageId
              ? message
              : message.copyWith(sourceMessageId: normalizedRawMessageId),
    ];
    await _db.transaction(() async {
      if (shouldCommit != null && !await shouldCommit()) return;
      if (shouldCommit != null &&
          !await isRawMessageActive(
            conversationId: conversationId,
            messageId: normalizedRawMessageId,
          )) {
        return;
      }
      await _ref
          .read(messageProjectionMappingRepositoryProvider)
          .replaceForRawMessage(
            rawMessageId: normalizedRawMessageId,
            mappings: <db.MessageProjectionMappingsCompanion>[
              for (
                var index = 0;
                index < normalizedProjectedMessages.length;
                index += 1
              )
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
    });
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

  List<PluginContent> _collectSemanticPluginContents(List<Message> messages) => [
    for (final message in messages)
      for (final block in message.blocks ?? const <MessageBlock>[])
        if (block is ImageBlock && block.status != BlockStatus.pending &&
            ((block.localPath?.trim().isNotEmpty ?? false) || block.versions.isNotEmpty))
          PluginImageContent(block.localPath ?? '', caption: block.prompt,
            generationSnapshot: block.generationSnapshot,
            versions: block.versions, activeVersionIndex: block.activeVersionIndex,
            width: block.width, height: block.height),
  ];

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
      if (audioUrl.isEmpty || block.status == BlockStatus.pending) {
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
      final imageBlocks = message.blocks?.whereType<ImageBlock>().toList() ?? const <ImageBlock>[];
      if (imageBlocks.isNotEmpty) {
        for (var imageIndex = 0; imageIndex < imageBlocks.length; imageIndex++) {
          final op = _buildStoredSupplementInsertOp(
            message.copyWith(id: imageIndex == 0 ? message.id : '${message.id}__image_$imageIndex',
              blocks: [imageBlocks[imageIndex]]),
            textCharsBefore: textCharsBefore,
            forceAppendToTail: !_hasLaterTextMessage(messages, index));
          if (op != null) ops.add(op);
        }
      } else {
        final op = _buildStoredSupplementInsertOp(message,
          textCharsBefore: textCharsBefore,
          forceAppendToTail: !_hasLaterTextMessage(messages, index));
        if (op != null) ops.add(op);
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
      if (block.status == BlockStatus.pending ||
          ((localPath == null || localPath.isEmpty) && block.versions.isEmpty &&
              block.status != BlockStatus.error)) {
        return null;
      }
      return StoredSupplementInsertOp(
        kind: 'image',
        status: block.status,
        textCharsBefore: textCharsBefore,
        forceAppendToTail: forceAppendToTail,
        localPath: localPath,
        width: block.width, height: block.height,
        legacyMessageId: message.id, legacyBlockId: block.id,
        prompt: block.prompt,
        generationSnapshot: block.generationSnapshot,
        versions: block.versions,
        activeVersionIndex: block.activeVersionIndex,
      );
    }
    if (block is AudioBlock) {
      final audioUrl = block.url.trim();
      if (audioUrl.isEmpty || block.status == BlockStatus.pending) {
        return null;
      }
      return StoredSupplementInsertOp(
        kind: 'audio',
        textCharsBefore: textCharsBefore,
        forceAppendToTail: forceAppendToTail,
        audioUrl: audioUrl,
        text: block.text?.trim(),
        unread: block.unread,
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

/// 新回复落库时把已就绪的语音标为未读。只在追加新消息时调用：
/// 历史投影重建不经过这里，旧语音不会被误标。
List<Message> markNewVoicesUnread(List<Message> messages) => [
      for (final message in messages)
        if (message.role == 'assistant' &&
            (message.blocks?.any(_isFreshVoice) ?? false))
          message.copyWith(blocks: [
            for (final block in message.blocks!)
              if (_isFreshVoice(block))
                (block as AudioBlock).withUnread(true)
              else
                block,
          ])
        else
          message,
    ];

bool _isFreshVoice(MessageBlock block) =>
    block is AudioBlock &&
    !block.unread &&
    block.url.trim().isNotEmpty &&
    block.status == BlockStatus.success;

bool _isUnresolvedImageBlock(MessageBlock block) => block is ImageBlock &&
    block.status == BlockStatus.pending &&
    (block.localPath?.trim().isEmpty ?? true) &&
    (block.url?.trim().isEmpty ?? true) &&
    (block.base64?.trim().isEmpty ?? true);

bool _isPendingImagePlaceholder(Message message) =>
    message.content.trim().isEmpty && message.blocks?.isNotEmpty == true &&
    message.blocks!.every(_isUnresolvedImageBlock);

Message _atPendingImageAnchor(Message message, DateTime time) =>
    _isPendingImagePlaceholder(message) ? message.copyWith(createdAt: time) : message;
