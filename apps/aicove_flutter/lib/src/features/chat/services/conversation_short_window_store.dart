import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../../core/database/database.dart' as db;
import '../../../core/database/converters/database_converters.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/models/message_block.dart';
import '../domain/message.dart';
import 'chat_frontend_message_projection_service.dart';

const int kConversationTimelineSeedMessageCount = 20;

class ConversationTimelineWindowState {
  const ConversationTimelineWindowState({
    required this.messages,
    required this.hasMoreMessages,
  });

  final List<Message> messages;
  final bool hasMoreMessages;
}

/// Frontend-only timeline cache.
///
/// 数据库继续保存 raw message；这里仅缓存“已投影好的前端消息窗口”。
class ConversationTimelineCache {
  ConversationTimelineCache(this._ref);

  final Ref _ref;
  final Map<String, _ConversationTimelineSnapshot> _snapshotsByConversation =
      <String, _ConversationTimelineSnapshot>{};
  final Map<String, StreamController<void>> _changeControllers =
      <String, StreamController<void>>{};
  final Map<String, Future<void>> _conversationTasks = <String, Future<void>>{};
  final Map<String, Future<void>> _snapshotUpgradeTasks =
      <String, Future<void>>{};

  ConversationTimelineWindowState? peekWindow({
    required String conversationId,
    required int limit,
  }) {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return const ConversationTimelineWindowState(
        messages: <Message>[],
        hasMoreMessages: false,
      );
    }

    final snapshot = _snapshotsByConversation[normalizedConversationId];
    if (snapshot == null) {
      return null;
    }
    _scheduleSnapshotUpgradeIfNeeded(normalizedConversationId, snapshot);
    return _buildWindow(
      snapshot,
      limit: limit,
    );
  }

  Stream<ConversationTimelineWindowState> watchWindow({
    required String conversationId,
    required int limit,
  }) async* {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      yield const ConversationTimelineWindowState(
        messages: <Message>[],
        hasMoreMessages: false,
      );
      return;
    }

    final normalizedLimit = limit < 1 ? 1 : limit;
    yield await _resolveWindow(
      normalizedConversationId,
      limit: normalizedLimit,
    );

    final controller = _controllerFor(normalizedConversationId);
    yield* controller.stream.asyncMap((_) {
      return _resolveWindow(
        normalizedConversationId,
        limit: normalizedLimit,
      );
    });
  }

  Future<void> upsertMessage({
    required String conversationId,
    required Message message,
  }) {
    return upsertMessages(
      conversationId: conversationId,
      messages: <Message>[message],
    );
  }

  Future<void> upsertMessages({
    required String conversationId,
    required List<Message> messages,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty || messages.isEmpty) {
      return;
    }

    await _runConversationTask(normalizedConversationId, () async {
      final current = await _ensureConversationReadyUnlocked(
        normalizedConversationId,
        minMessages: kConversationTimelineSeedMessageCount,
      );
      final mergedById = <String, Message>{
        for (final message in current.messages) message.id: message,
      };
      for (final message in messages) {
        mergedById[message.id] = message;
      }

      final normalizedMessages = _normalizeMessages(mergedById.values);
      final next = await _persistSnapshotUnlocked(
        _ConversationTimelineSnapshot(
          conversationId: normalizedConversationId,
          messages: normalizedMessages,
          hasMoreMessages: current.hasMoreMessages,
          oldestRawCursor: current.oldestRawCursor ??
              _estimateOldestRawCursor(normalizedMessages),
          loadedRawMessageCount: current.loadedRawMessageCount > 0
              ? current.loadedRawMessageCount
              : _estimateLoadedRawMessageCount(normalizedMessages),
        ),
      );
      _snapshotsByConversation[normalizedConversationId] = next;
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<void> replaceMessages({
    required String conversationId,
    List<String> removeMessageIds = const <String>[],
    List<Message> messages = const <Message>[],
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return;
    }

    final normalizedRemoveIds = removeMessageIds
        .map((messageId) => messageId.trim())
        .where((messageId) => messageId.isNotEmpty)
        .toSet();
    if (normalizedRemoveIds.isEmpty && messages.isEmpty) {
      return;
    }

    await _runConversationTask(normalizedConversationId, () async {
      final current = await _ensureConversationReadyUnlocked(
        normalizedConversationId,
        minMessages: kConversationTimelineSeedMessageCount,
      );
      final mergedById = <String, Message>{
        for (final message in current.messages)
          if (!normalizedRemoveIds.contains(message.id)) message.id: message,
      };
      for (final message in messages) {
        mergedById[message.id] = message;
      }

      final normalizedMessages = _normalizeMessages(mergedById.values);
      final next = await _persistSnapshotUnlocked(
        _ConversationTimelineSnapshot(
          conversationId: normalizedConversationId,
          messages: normalizedMessages,
          hasMoreMessages: current.hasMoreMessages,
          oldestRawCursor: current.oldestRawCursor ??
              _estimateOldestRawCursor(normalizedMessages),
          loadedRawMessageCount: current.loadedRawMessageCount > 0
              ? current.loadedRawMessageCount
              : _estimateLoadedRawMessageCount(normalizedMessages),
        ),
      );
      _snapshotsByConversation[normalizedConversationId] = next;
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<int> loadOlderMessages({
    required String conversationId,
    int pageSize = kConversationTimelineSeedMessageCount,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return 0;
    }

    final normalizedPageSize = pageSize < 1 ? 1 : pageSize;
    return _runConversationTask(normalizedConversationId, () async {
      final current = await _ensureConversationReadyUnlocked(
        normalizedConversationId,
        minMessages: kConversationTimelineSeedMessageCount,
      );
      final oldestCursor = current.oldestRawCursor;
      if (oldestCursor == null ||
          current.messages.isEmpty ||
          !current.hasMoreMessages) {
        return 0;
      }

      final olderPage = await _loadOlderPageFromDb(
        normalizedConversationId,
        beforeCursor: oldestCursor,
        pageSize: normalizedPageSize,
      );
      if (olderPage.messages.isEmpty) {
        if (current.hasMoreMessages) {
          final next = await _persistSnapshotUnlocked(
            current.copyWith(hasMoreMessages: false),
          );
          _snapshotsByConversation[normalizedConversationId] = next;
          _notifyConversationChanged(normalizedConversationId);
        }
        return 0;
      }

      final nextMessages = _normalizeMessages(<Message>[
        ...olderPage.messages,
        ...current.messages,
      ]);
      final next = await _persistSnapshotUnlocked(
        current.copyWith(
          messages: nextMessages,
          hasMoreMessages: olderPage.hasMoreMessages,
          oldestRawCursor: olderPage.oldestRawCursor ?? current.oldestRawCursor,
          loadedRawMessageCount:
              current.loadedRawMessageCount + olderPage.loadedRawMessageCount,
        ),
      );
      _snapshotsByConversation[normalizedConversationId] = next;
      _notifyConversationChanged(normalizedConversationId);
      return olderPage.loadedRawMessageCount;
    });
  }

  Future<void> reloadConversationFromRawStore(
    String conversationId, {
    int? targetMessageCount,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return;
    }

    await _runConversationTask(normalizedConversationId, () async {
      final current = _snapshotsByConversation[normalizedConversationId];
      final normalizedTargetCount = targetMessageCount == null
          ? _maxInt(
              kConversationTimelineSeedMessageCount,
              current?.loadedRawMessageCount ?? 0,
            )
          : targetMessageCount < 1
              ? 1
              : targetMessageCount;

      final rebuilt = await _loadRecentSnapshotFromDb(
        normalizedConversationId,
        targetCount: normalizedTargetCount,
      );
      final next = await _persistSnapshotUnlocked(rebuilt);
      _snapshotsByConversation[normalizedConversationId] = next;
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<void> clearConversation(String conversationId) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return;
    }

    await _runConversationTask(normalizedConversationId, () async {
      _snapshotsByConversation[normalizedConversationId] =
          _ConversationTimelineSnapshot(
        conversationId: normalizedConversationId,
        messages: const <Message>[],
        hasMoreMessages: false,
        oldestRawCursor: null,
        loadedRawMessageCount: 0,
      );
      await _ref
          .read(messageProjectionMappingRepositoryProvider)
          .deleteByConversation(normalizedConversationId);
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<void> deleteConversation(String conversationId) {
    return clearConversation(conversationId);
  }

  Future<List<Message>> loadCachedMessages(String conversationId) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return const <Message>[];
    }
    final snapshot = await _loadSnapshot(normalizedConversationId);
    return List<Message>.unmodifiable(snapshot.messages);
  }

  Future<int> loadCachedMessageCount(String conversationId) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return 0;
    }
    final snapshot = await _loadSnapshot(normalizedConversationId);
    return snapshot.loadedRawMessageCount;
  }

  Future<Message?> findCachedMessageById(
    String messageId, {
    String? conversationId,
  }) async {
    final normalizedMessageId = messageId.trim();
    if (normalizedMessageId.isEmpty) {
      return null;
    }

    final normalizedConversationId = conversationId?.trim();
    if (normalizedConversationId != null &&
        normalizedConversationId.isNotEmpty) {
      final messages = await loadCachedMessages(normalizedConversationId);
      for (final message in messages) {
        if (message.id == normalizedMessageId) {
          return message;
        }
      }
      return null;
    }

    for (final snapshot in _snapshotsByConversation.values) {
      for (final message in snapshot.messages) {
        if (message.id == normalizedMessageId) {
          return message;
        }
      }
    }
    return null;
  }

  void dispose() {
    for (final controller in _changeControllers.values) {
      unawaited(controller.close());
    }
    _changeControllers.clear();
  }

  Future<ConversationTimelineWindowState> _resolveWindow(
    String conversationId, {
    required int limit,
  }) async {
    final snapshot = await _loadSnapshot(conversationId);
    return _buildWindow(snapshot, limit: limit);
  }

  Future<_ConversationTimelineSnapshot> _loadSnapshot(String conversationId) {
    return _runConversationTask(
      conversationId,
      () => _loadSnapshotUnlocked(conversationId),
    );
  }

  Future<_ConversationTimelineSnapshot> _loadSnapshotUnlocked(
    String conversationId,
  ) async {
    var snapshot = _snapshotsByConversation[conversationId];
    snapshot ??= await _loadRecentSnapshotFromDb(
      conversationId,
      targetCount: kConversationTimelineSeedMessageCount,
    );

    _snapshotsByConversation[conversationId] = snapshot;
    _scheduleSnapshotUpgradeIfNeeded(conversationId, snapshot);
    return snapshot;
  }

  Future<_ConversationTimelineSnapshot> _ensureConversationReadyUnlocked(
    String conversationId, {
    required int minMessages,
  }) async {
    final normalizedMinMessages = minMessages < 1 ? 1 : minMessages;
    var snapshot = _snapshotsByConversation[conversationId];
    snapshot ??= await _loadRecentSnapshotFromDb(
      conversationId,
      targetCount: kConversationTimelineSeedMessageCount,
    );

    if (snapshot.loadedRawMessageCount < normalizedMinMessages &&
        snapshot.hasMoreMessages) {
      snapshot = await _expandSnapshotFromDb(
        snapshot,
        minMessages: normalizedMinMessages,
      );
    }

    _snapshotsByConversation[conversationId] = snapshot;
    _scheduleSnapshotUpgradeIfNeeded(conversationId, snapshot);
    return snapshot;
  }

  void _scheduleSnapshotUpgradeIfNeeded(
    String conversationId,
    _ConversationTimelineSnapshot snapshot,
  ) {
    if (!_snapshotNeedsImageDimensionUpgrade(snapshot) ||
        _snapshotUpgradeTasks.containsKey(conversationId)) {
      return;
    }

    late final Future<void> task;
    task = _runConversationTask(conversationId, () async {
      final current = _snapshotsByConversation[conversationId] ?? snapshot;
      if (!_snapshotNeedsImageDimensionUpgrade(current)) {
        return;
      }
      final next = await _persistSnapshotUnlocked(current);
      _snapshotsByConversation[conversationId] = next;
      _notifyConversationChanged(conversationId);
    }).whenComplete(() {
      if (identical(_snapshotUpgradeTasks[conversationId], task)) {
        _snapshotUpgradeTasks.remove(conversationId);
      }
    });
    _snapshotUpgradeTasks[conversationId] = task;
  }

  Future<_ConversationTimelineSnapshot> _expandSnapshotFromDb(
    _ConversationTimelineSnapshot snapshot, {
    required int minMessages,
  }) async {
    var current = snapshot;
    while (current.loadedRawMessageCount < minMessages &&
        current.hasMoreMessages) {
      final oldestCursor = current.oldestRawCursor;
      if (oldestCursor == null || current.messages.isEmpty) {
        current = current.copyWith(hasMoreMessages: false);
        break;
      }

      final page = await _loadOlderPageFromDb(
        current.conversationId,
        beforeCursor: oldestCursor,
        pageSize: _maxInt(5, minMessages - current.loadedRawMessageCount),
      );
      if (page.messages.isEmpty) {
        current = current.copyWith(hasMoreMessages: false);
        break;
      }
      current = current.copyWith(
        messages: _normalizeMessages(
          <Message>[
            ...page.messages,
            ...current.messages,
          ],
        ),
        hasMoreMessages: page.hasMoreMessages,
        oldestRawCursor: page.oldestRawCursor ?? current.oldestRawCursor,
        loadedRawMessageCount:
            current.loadedRawMessageCount + page.loadedRawMessageCount,
      );
    }

    return _persistSnapshotUnlocked(current);
  }

  Future<_ConversationTimelineSnapshot> _loadRecentSnapshotFromDb(
    String conversationId, {
    required int targetCount,
  }) async {
    final normalizedTargetCount = targetCount < 1 ? 1 : targetCount;
    final dbMessages =
        await _ref.read(messageRepositoryProvider).getByConversationStable(
              conversationId,
              limit: normalizedTargetCount + 1,
            );
    final hasMoreMessages = dbMessages.length > normalizedTargetCount;
    final trimmedDbMessages = hasMoreMessages
        ? dbMessages.take(normalizedTargetCount).toList(growable: false)
        : dbMessages;
    final orderedDbMessages =
        trimmedDbMessages.reversed.toList(growable: false);
    final orderedMessages = await _buildMessagesFromDb(orderedDbMessages);

    return _ConversationTimelineSnapshot(
      conversationId: conversationId,
      messages: orderedMessages,
      hasMoreMessages: hasMoreMessages,
      oldestRawCursor: _rawCursorFromDbMessage(
        orderedDbMessages.isEmpty ? null : orderedDbMessages.first,
      ),
      loadedRawMessageCount: orderedDbMessages.length,
    );
  }

  Future<_OlderPageResult> _loadOlderPageFromDb(
    String conversationId, {
    required _RawMessageCursor beforeCursor,
    required int pageSize,
  }) async {
    final normalizedPageSize = pageSize < 1 ? 1 : pageSize;
    final dbMessages =
        await _ref.read(messageRepositoryProvider).getByConversationStable(
              conversationId,
              limit: normalizedPageSize + 1,
              beforeTime: beforeCursor.createdAt.millisecondsSinceEpoch,
              beforeId: beforeCursor.messageId,
            );
    final hasMoreMessages = dbMessages.length > normalizedPageSize;
    final trimmedDbMessages = hasMoreMessages
        ? dbMessages.take(normalizedPageSize).toList(growable: false)
        : dbMessages;
    final orderedDbMessages =
        trimmedDbMessages.reversed.toList(growable: false);
    final orderedMessages = await _buildMessagesFromDb(orderedDbMessages);

    return _OlderPageResult(
      messages: orderedMessages,
      hasMoreMessages: hasMoreMessages,
      oldestRawCursor: _rawCursorFromDbMessage(
        orderedDbMessages.isEmpty ? null : orderedDbMessages.first,
      ),
      loadedRawMessageCount: orderedDbMessages.length,
    );
  }

  Future<_ConversationTimelineSnapshot> _persistSnapshotUnlocked(
    _ConversationTimelineSnapshot snapshot,
  ) async {
    final upgradedMessages = await _upgradeSnapshotMessages(snapshot.messages);
    final normalizedMessages = _normalizeMessages(upgradedMessages);
    final normalizedSnapshot = _ConversationTimelineSnapshot(
      conversationId: snapshot.conversationId,
      messages: normalizedMessages,
      hasMoreMessages: snapshot.hasMoreMessages &&
          (normalizedMessages.isNotEmpty || snapshot.oldestRawCursor != null),
      oldestRawCursor: snapshot.oldestRawCursor ??
          _estimateOldestRawCursor(normalizedMessages),
      loadedRawMessageCount: snapshot.loadedRawMessageCount > 0
          ? snapshot.loadedRawMessageCount
          : _estimateLoadedRawMessageCount(normalizedMessages),
    );
    await _syncProjectionMappingsUnlocked(normalizedSnapshot);
    return normalizedSnapshot;
  }

  Future<List<Message>> _upgradeSnapshotMessages(
    Iterable<Message> messages,
  ) async {
    final upgraded = <Message>[];
    for (final message in messages) {
      final blocks = message.blocks;
      if (blocks == null || blocks.isEmpty) {
        upgraded.add(message);
        continue;
      }

      var changed = false;
      final nextBlocks = <MessageBlock>[];
      for (final block in blocks) {
        if (block is ImageBlock && !_hasImageDimensions(block)) {
          final dimensions = await _resolveImageDimensions(block);
          if (dimensions != null) {
            changed = true;
            nextBlocks.add(
              ImageBlock(
                id: block.id,
                messageId: block.messageId,
                url: block.url,
                localPath: block.localPath,
                base64: block.base64,
                width: dimensions.width,
                height: dimensions.height,
                prompt: block.prompt,
                status: block.status,
              ),
            );
            continue;
          }
        }
        nextBlocks.add(block);
      }

      upgraded.add(changed ? message.copyWith(blocks: nextBlocks) : message);
    }
    return upgraded;
  }

  bool _snapshotNeedsImageDimensionUpgrade(
    _ConversationTimelineSnapshot snapshot,
  ) {
    for (final message in snapshot.messages) {
      final blocks = message.blocks;
      if (blocks == null) continue;
      for (final block in blocks) {
        if (block is ImageBlock && !_hasImageDimensions(block)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _hasImageDimensions(ImageBlock block) {
    final width = block.width;
    final height = block.height;
    return width != null && width > 0 && height != null && height > 0;
  }

  Future<({int width, int height})?> _resolveImageDimensions(
    ImageBlock block,
  ) async {
    if (_hasImageDimensions(block)) {
      return (width: block.width!, height: block.height!);
    }

    final localPath = block.localPath?.trim();
    if (localPath != null && localPath.isNotEmpty) {
      final file = File(localPath);
      if (await file.exists()) {
        try {
          final bytes = await file.readAsBytes();
          final decoded = img.decodeImage(bytes);
          if (decoded != null) {
            return (width: decoded.width, height: decoded.height);
          }
        } on Object {
          // ignore
        }
      }
    }

    final blockUrl = block.url?.trim();
    if (blockUrl != null && blockUrl.startsWith('file://')) {
      final file = File(Uri.parse(blockUrl).toFilePath());
      if (await file.exists()) {
        try {
          final bytes = await file.readAsBytes();
          final decoded = img.decodeImage(bytes);
          if (decoded != null) {
            return (width: decoded.width, height: decoded.height);
          }
        } on Object {
          // ignore
        }
      }
    }

    final base64Value = block.base64?.trim();
    if (base64Value != null && base64Value.isNotEmpty) {
      try {
        final bytes = _decodeMaybeDataUrl(base64Value);
        final decoded = img.decodeImage(Uint8List.fromList(bytes));
        if (decoded != null) {
          return (width: decoded.width, height: decoded.height);
        }
      } on Object {
        // ignore
      }
    }

    return null;
  }

  List<int> _decodeMaybeDataUrl(String value) {
    if (value.startsWith('data:')) {
      final commaIndex = value.indexOf(',');
      if (commaIndex > 0) {
        return base64Decode(value.substring(commaIndex + 1));
      }
    }
    return base64Decode(value);
  }

  Future<List<Message>> _buildMessagesFromDb(
      List<db.Message> dbMessages) async {
    if (dbMessages.isEmpty) {
      return const <Message>[];
    }

    final messageIds =
        dbMessages.map((message) => message.id).toList(growable: false);
    final dbBlocks =
        await _ref.read(messageBlockRepositoryProvider).getByMessages(
              messageIds,
            );
    final blocksByMessageId = <String, List<MessageBlock>>{};
    for (final dbBlock in dbBlocks) {
      final block = MessageBlockConverter.fromDb(dbBlock);
      if (block == null) {
        continue;
      }
      blocksByMessageId
          .putIfAbsent(dbBlock.messageId, () => <MessageBlock>[])
          .add(block);
    }

    final rawMessages = <Message>[
      for (final dbMessage in dbMessages)
        MessageConverter.fromDb(
          dbMessage,
          blocks: blocksByMessageId[dbMessage.id],
        ),
    ];
    return _ref
        .read(chatFrontendMessageProjectionServiceProvider)
        .projectMessages(rawMessages);
  }

  Future<void> _syncProjectionMappingsUnlocked(
    _ConversationTimelineSnapshot snapshot,
  ) async {
    final segmentIndexesByRawMessageId = <String, int>{};
    final mappingsByRawMessageId =
        <String, List<db.MessageProjectionMappingsCompanion>>{};
    for (final message in snapshot.messages) {
      final rawMessageId = message.sourceMessageId?.trim();
      if (rawMessageId == null || rawMessageId.isEmpty) {
        continue;
      }
      final segmentIndex = segmentIndexesByRawMessageId.update(
        rawMessageId,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      mappingsByRawMessageId
          .putIfAbsent(
            rawMessageId,
            () => <db.MessageProjectionMappingsCompanion>[],
          )
          .add(
            db.MessageProjectionMappingsCompanion.insert(
              id: '$rawMessageId::${message.id}',
              conversationId: snapshot.conversationId,
              rawMessageId: rawMessageId,
              projectedMessageId: message.id,
              projectionKind: Value(_projectionKindFor(message)),
              segmentIndex: Value(segmentIndex),
              projectionVersion: const Value(null),
              createdAt: message.createdAt.millisecondsSinceEpoch,
            ),
          );
    }
    final repository = _ref.read(messageProjectionMappingRepositoryProvider);
    for (final entry in mappingsByRawMessageId.entries) {
      await repository.replaceForRawMessage(
        rawMessageId: entry.key,
        mappings: entry.value,
      );
    }
  }

  _RawMessageCursor? _rawCursorFromDbMessage(db.Message? message) {
    if (message == null) {
      return null;
    }
    return _RawMessageCursor(
      messageId: message.id,
      createdAt: DateTime.fromMillisecondsSinceEpoch(message.createdAt),
    );
  }

  _RawMessageCursor? _estimateOldestRawCursor(Iterable<Message> messages) {
    for (final message in messages) {
      final rawMessageId = (message.sourceMessageId?.trim().isNotEmpty ?? false)
          ? message.sourceMessageId!.trim()
          : message.id;
      if (rawMessageId.trim().isEmpty) {
        continue;
      }
      return _RawMessageCursor(
        messageId: rawMessageId,
        createdAt: message.createdAt,
      );
    }
    return null;
  }

  int _estimateLoadedRawMessageCount(Iterable<Message> messages) {
    final rawMessageIds = <String>{};
    for (final message in messages) {
      final rawMessageId = (message.sourceMessageId?.trim().isNotEmpty ?? false)
          ? message.sourceMessageId!.trim()
          : message.id.trim();
      if (rawMessageId.isNotEmpty) {
        rawMessageIds.add(rawMessageId);
      }
    }
    return rawMessageIds.length;
  }

  StreamController<void> _controllerFor(String conversationId) {
    return _changeControllers.putIfAbsent(
      conversationId,
      () => StreamController<void>.broadcast(),
    );
  }

  void _notifyConversationChanged(String conversationId) {
    final controller = _changeControllers[conversationId];
    if (controller == null || controller.isClosed) {
      return;
    }
    controller.add(null);
  }

  Future<T> _runConversationTask<T>(
    String conversationId,
    Future<T> Function() action,
  ) {
    final previousTask =
        _conversationTasks[conversationId] ?? Future<void>.value();
    final completer = Completer<T>();
    late final Future<void> currentTask;
    currentTask = previousTask.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }).whenComplete(() {
      if (identical(_conversationTasks[conversationId], currentTask)) {
        _conversationTasks.remove(conversationId);
      }
    });
    _conversationTasks[conversationId] = currentTask;
    return completer.future;
  }
}

class _OlderPageResult {
  const _OlderPageResult({
    required this.messages,
    required this.hasMoreMessages,
    required this.oldestRawCursor,
    required this.loadedRawMessageCount,
  });

  final List<Message> messages;
  final bool hasMoreMessages;
  final _RawMessageCursor? oldestRawCursor;
  final int loadedRawMessageCount;
}

class _ConversationTimelineSnapshot {
  const _ConversationTimelineSnapshot({
    required this.conversationId,
    required this.messages,
    required this.hasMoreMessages,
    required this.oldestRawCursor,
    required this.loadedRawMessageCount,
  });

  final String conversationId;
  final List<Message> messages;
  final bool hasMoreMessages;
  final _RawMessageCursor? oldestRawCursor;
  final int loadedRawMessageCount;

  _ConversationTimelineSnapshot copyWith({
    List<Message>? messages,
    bool? hasMoreMessages,
    _RawMessageCursor? oldestRawCursor,
    int? loadedRawMessageCount,
  }) {
    return _ConversationTimelineSnapshot(
      conversationId: conversationId,
      messages: messages ?? this.messages,
      hasMoreMessages: hasMoreMessages ?? this.hasMoreMessages,
      oldestRawCursor: oldestRawCursor ?? this.oldestRawCursor,
      loadedRawMessageCount:
          loadedRawMessageCount ?? this.loadedRawMessageCount,
    );
  }
}

class _RawMessageCursor {
  const _RawMessageCursor({
    required this.messageId,
    required this.createdAt,
  });

  final String messageId;
  final DateTime createdAt;
}

ConversationTimelineWindowState _buildWindow(
  _ConversationTimelineSnapshot snapshot, {
  required int limit,
}) {
  final normalizedLimit = limit < 1 ? 1 : limit;
  final visibleMessages = List<Message>.unmodifiable(
    _selectNewestProjectedMessagesByRawWindow(
      snapshot.messages,
      rawMessageLimit: normalizedLimit,
    ),
  );
  return ConversationTimelineWindowState(
    messages: visibleMessages,
    hasMoreMessages: snapshot.hasMoreMessages ||
        snapshot.loadedRawMessageCount > normalizedLimit,
  );
}

List<Message> _selectNewestProjectedMessagesByRawWindow(
  List<Message> messages, {
  required int rawMessageLimit,
}) {
  if (messages.isEmpty) {
    return const <Message>[];
  }

  final normalizedLimit = rawMessageLimit < 1 ? 1 : rawMessageLimit;
  final selectedRawIds = <String>{};
  var firstSelectedIndex = messages.length;
  for (var index = messages.length - 1; index >= 0; index -= 1) {
    final rawId = _messageRawSourceId(messages[index]);
    if (selectedRawIds.add(rawId)) {
      firstSelectedIndex = index;
      if (selectedRawIds.length >= normalizedLimit) {
        break;
      }
    } else if (selectedRawIds.isNotEmpty) {
      firstSelectedIndex = index;
    }
  }

  if (selectedRawIds.isEmpty) {
    return const <Message>[];
  }

  return <Message>[
    for (var index = firstSelectedIndex; index < messages.length; index += 1)
      if (selectedRawIds.contains(_messageRawSourceId(messages[index])))
        messages[index],
  ];
}

String _messageRawSourceId(Message message) {
  final sourceMessageId = message.sourceMessageId?.trim();
  if (sourceMessageId != null && sourceMessageId.isNotEmpty) {
    return sourceMessageId;
  }
  return message.id.trim();
}

List<Message> _normalizeMessages(Iterable<Message> messages) {
  final deduped = <String, ({int index, Message message})>{};
  var index = 0;
  for (final message in messages) {
    deduped[message.id] = (index: index, message: message);
    index += 1;
  }
  final normalizedEntries = deduped.values.toList(growable: false)
    ..sort((left, right) {
      final byTime = left.message.createdAt.compareTo(right.message.createdAt);
      if (byTime != 0) {
        return byTime;
      }
      return left.index.compareTo(right.index);
    });
  return <Message>[
    for (final entry in normalizedEntries) entry.message,
  ];
}

int _maxInt(int left, int right) => left > right ? left : right;

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

final conversationTimelineCacheProvider =
    Provider<ConversationTimelineCache>((ref) {
  final store = ConversationTimelineCache(ref);
  ref.onDispose(store.dispose);
  return store;
});
