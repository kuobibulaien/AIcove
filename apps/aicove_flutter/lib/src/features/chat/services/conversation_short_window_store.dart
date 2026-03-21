import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/database/database.dart' as db;
import '../../../core/database/converters/database_converters.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/models/message_block.dart';
import '../domain/message.dart';

const int kConversationShortWindowSeedMessageCount = 5;
const int kConversationShortWindowBudgetBytes = 50 * 1024 * 1024;
const String kConversationShortWindowRootDirectoryName =
    'conversation_short_windows';
const String _kConversationShortWindowFileName = 'window.json';
const String _kConversationShortWindowMediaDirectoryName = 'media';
const int _kConversationShortWindowFileVersion = 1;

class ConversationShortWindowState {
  const ConversationShortWindowState({
    required this.messages,
    required this.hasMoreMessages,
  });

  final List<Message> messages;
  final bool hasMoreMessages;
}

class ConversationShortWindowStore {
  ConversationShortWindowStore(this._ref);

  final Ref _ref;
  final Map<String, _ConversationShortWindowSnapshot> _snapshotsByConversation =
      <String, _ConversationShortWindowSnapshot>{};
  final Map<String, StreamController<void>> _changeControllers =
      <String, StreamController<void>>{};
  final Map<String, Future<void>> _conversationTasks = <String, Future<void>>{};
  Future<void> _budgetTask = Future<void>.value();
  Future<Directory>? _rootDirectoryFuture;

  Stream<ConversationShortWindowState> watchWindow({
    required String conversationId,
    required int limit,
  }) async* {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      yield const ConversationShortWindowState(
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

  Future<void> warmupConversations(Iterable<String> conversationIds) async {
    final uniqueConversationIds = <String>{
      for (final conversationId in conversationIds)
        if (conversationId.trim().isNotEmpty) conversationId.trim(),
    };
    for (final conversationId in uniqueConversationIds) {
      try {
        await _ensureConversationReady(
          conversationId,
          minMessages: kConversationShortWindowSeedMessageCount,
        );
      } catch (_) {
        // 预热失败不阻断应用主流程。
      }
    }
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
        minMessages: kConversationShortWindowSeedMessageCount,
      );
      final mergedById = <String, Message>{
        for (final message in current.messages) message.id: message,
      };
      for (final message in messages) {
        mergedById[message.id] = message;
      }

      final next = await _persistSnapshotUnlocked(
        _ConversationShortWindowSnapshot(
          conversationId: normalizedConversationId,
          messages: _normalizeMessages(mergedById.values),
          hasMoreMessages: current.hasMoreMessages,
        ),
      );
      _snapshotsByConversation[normalizedConversationId] = next;
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<void> syncConversation(
    String conversationId, {
    int? targetMessageCount,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return;
    }

    await _runConversationTask(normalizedConversationId, () async {
      final current = _snapshotsByConversation[normalizedConversationId] ??
          await _readSnapshotFromDiskUnlocked(normalizedConversationId);
      final normalizedTargetCount = targetMessageCount == null
          ? _maxInt(
              kConversationShortWindowSeedMessageCount,
              current?.messages.length ?? 0,
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
          _ConversationShortWindowSnapshot(
        conversationId: normalizedConversationId,
        messages: const <Message>[],
        hasMoreMessages: false,
      );
      await _deleteConversationDirectoryUnlocked(normalizedConversationId);
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<void> deleteConversation(String conversationId) {
    return clearConversation(conversationId);
  }

  void dispose() {
    for (final controller in _changeControllers.values) {
      unawaited(controller.close());
    }
    _changeControllers.clear();
  }

  Future<ConversationShortWindowState> _resolveWindow(
    String conversationId, {
    required int limit,
  }) async {
    final snapshot = await _ensureConversationReady(
      conversationId,
      minMessages: limit,
    );
    return _buildWindow(snapshot, limit: limit);
  }

  Future<_ConversationShortWindowSnapshot> _ensureConversationReady(
    String conversationId, {
    required int minMessages,
  }) {
    return _runConversationTask(
      conversationId,
      () => _ensureConversationReadyUnlocked(
        conversationId,
        minMessages: minMessages,
      ),
    );
  }

  Future<_ConversationShortWindowSnapshot> _ensureConversationReadyUnlocked(
    String conversationId, {
    required int minMessages,
  }) async {
    final normalizedMinMessages = minMessages < 1 ? 1 : minMessages;
    var snapshot = _snapshotsByConversation[conversationId] ??
        await _readSnapshotFromDiskUnlocked(conversationId);
    if (snapshot == null) {
      snapshot = await _persistSnapshotUnlocked(
        await _loadRecentSnapshotFromDb(
          conversationId,
          targetCount: _maxInt(
            kConversationShortWindowSeedMessageCount,
            normalizedMinMessages,
          ),
        ),
      );
    }

    if (snapshot.messages.length < normalizedMinMessages &&
        snapshot.hasMoreMessages) {
      snapshot = await _expandSnapshotFromDb(
        snapshot,
        minMessages: normalizedMinMessages,
      );
    }

    _snapshotsByConversation[conversationId] = snapshot;
    return snapshot;
  }

  Future<_ConversationShortWindowSnapshot> _expandSnapshotFromDb(
    _ConversationShortWindowSnapshot snapshot, {
    required int minMessages,
  }) async {
    var current = snapshot;
    while (current.messages.length < minMessages && current.hasMoreMessages) {
      if (current.messages.isEmpty) {
        current = current.copyWith(hasMoreMessages: false);
        break;
      }
      final oldestMessage = current.messages.first;
      final page = await _loadOlderPageFromDb(
        current.conversationId,
        beforeCreatedAt: oldestMessage.createdAt,
        beforeId: oldestMessage.id,
        pageSize: _maxInt(5, minMessages - current.messages.length),
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
      );
    }

    return _persistSnapshotUnlocked(current);
  }

  Future<_ConversationShortWindowSnapshot> _loadRecentSnapshotFromDb(
    String conversationId, {
    required int targetCount,
  }) async {
    final normalizedTargetCount = targetCount < 1 ? 1 : targetCount;
    final dbMessages =
        await _ref.read(messageRepositoryProvider).getByConversationStable(
              conversationId,
              limit: normalizedTargetCount + 1,
            );
    final orderedMessages = await _buildMessagesFromDb(
      dbMessages.reversed.toList(growable: false),
    );
    final hasMoreMessages = orderedMessages.length > normalizedTargetCount;
    final trimmedMessages = hasMoreMessages
        ? orderedMessages.sublist(
            orderedMessages.length - normalizedTargetCount,
          )
        : orderedMessages;

    return _ConversationShortWindowSnapshot(
      conversationId: conversationId,
      messages: trimmedMessages,
      hasMoreMessages: hasMoreMessages,
    );
  }

  Future<_OlderPageResult> _loadOlderPageFromDb(
    String conversationId, {
    required DateTime beforeCreatedAt,
    required String beforeId,
    required int pageSize,
  }) async {
    final normalizedPageSize = pageSize < 1 ? 1 : pageSize;
    final dbMessages =
        await _ref.read(messageRepositoryProvider).getByConversationStable(
              conversationId,
              limit: normalizedPageSize + 1,
              beforeTime: beforeCreatedAt.millisecondsSinceEpoch,
              beforeId: beforeId,
            );
    final orderedMessages = await _buildMessagesFromDb(
      dbMessages.reversed.toList(growable: false),
    );
    final hasMoreMessages = orderedMessages.length > normalizedPageSize;
    final trimmedMessages = hasMoreMessages
        ? orderedMessages.sublist(orderedMessages.length - normalizedPageSize)
        : orderedMessages;

    return _OlderPageResult(
      messages: trimmedMessages,
      hasMoreMessages: hasMoreMessages,
    );
  }

  Future<_ConversationShortWindowSnapshot> _persistSnapshotUnlocked(
    _ConversationShortWindowSnapshot snapshot, {
    bool allowBudgetEnforcement = true,
  }) async {
    final localizedMessages = <Message>[];
    for (final message in snapshot.messages) {
      localizedMessages.add(
        await _localizeMessageForSnapshot(
          snapshot.conversationId,
          message,
        ),
      );
    }

    final normalizedSnapshot = _ConversationShortWindowSnapshot(
      conversationId: snapshot.conversationId,
      messages: _normalizeMessages(localizedMessages),
      hasMoreMessages: snapshot.hasMoreMessages && localizedMessages.isNotEmpty,
    );

    final directory = await _conversationDirectory(snapshot.conversationId);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final file = File(
      p.join(directory.path, _kConversationShortWindowFileName),
    );
    final payload = <String, dynamic>{
      'version': _kConversationShortWindowFileVersion,
      'conversationId': normalizedSnapshot.conversationId,
      'hasMoreMessages': normalizedSnapshot.hasMoreMessages,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'messages': <Map<String, dynamic>>[
        for (final message in normalizedSnapshot.messages)
          _serializeMessage(message),
      ],
    };
    await file.writeAsString(
      jsonEncode(payload),
      flush: true,
    );
    await _deleteUnreferencedMediaUnlocked(normalizedSnapshot);

    if (allowBudgetEnforcement) {
      unawaited(_scheduleBudgetEnforcement());
    }
    return normalizedSnapshot;
  }

  Future<Message> _localizeMessageForSnapshot(
    String conversationId,
    Message message,
  ) async {
    final blocks = message.blocks;
    if (blocks == null || blocks.isEmpty) {
      return message;
    }

    final localizedBlocks = <MessageBlock>[];
    for (final block in blocks) {
      localizedBlocks.add(
        await _localizeBlockForSnapshot(
          conversationId,
          block,
        ),
      );
    }
    return message.copyWith(blocks: localizedBlocks);
  }

  Future<MessageBlock> _localizeBlockForSnapshot(
    String conversationId,
    MessageBlock block,
  ) async {
    if (block is ImageBlock) {
      final localizedPath = await _resolveImageLocalPath(
        conversationId,
        block,
      );
      return ImageBlock(
        id: block.id,
        messageId: block.messageId,
        url: localizedPath == null ? block.url : null,
        localPath: localizedPath ?? block.localPath,
        base64: localizedPath == null ? block.base64 : null,
        width: block.width,
        height: block.height,
        prompt: block.prompt,
        status: block.status,
      );
    }
    if (block is AudioBlock) {
      final localizedUrl = await _resolveAudioSource(
        conversationId,
        block,
      );
      return AudioBlock(
        id: block.id,
        messageId: block.messageId,
        url: localizedUrl,
        text: block.text,
        durationSeconds: block.durationSeconds,
        status: block.status,
      );
    }
    if (block is FileBlock) {
      final localizedPath = await _copyLocalMediaFile(
        conversationId,
        sourcePath: block.filePath,
        targetStem: '${block.messageId}_${block.id}_file',
      );
      return FileBlock(
        id: block.id,
        messageId: block.messageId,
        fileName: block.fileName,
        fileSize: block.fileSize,
        mimeType: block.mimeType,
        filePath: localizedPath ?? block.filePath,
        status: block.status,
      );
    }
    if (block is EmojiBlock) {
      final localizedPath = await _copyLocalMediaFile(
        conversationId,
        sourcePath: block.path,
        targetStem: '${block.messageId}_${block.id}_emoji',
      );
      return EmojiBlock(
        id: block.id,
        messageId: block.messageId,
        emojiId: block.emojiId,
        path: localizedPath ?? block.path,
        matchedTag: block.matchedTag,
        originalText: block.originalText,
        status: block.status,
      );
    }
    return block;
  }

  Future<String?> _resolveImageLocalPath(
    String conversationId,
    ImageBlock block,
  ) async {
    final localPath = block.localPath?.trim();
    if (localPath != null && localPath.isNotEmpty) {
      return _copyLocalMediaFile(
        conversationId,
        sourcePath: localPath,
        targetStem: '${block.messageId}_${block.id}_image',
      );
    }

    final blockUrl = block.url?.trim();
    if (blockUrl != null && blockUrl.isNotEmpty && _isFileUrl(blockUrl)) {
      return _copyLocalMediaFile(
        conversationId,
        sourcePath: _toFilePath(blockUrl),
        targetStem: '${block.messageId}_${block.id}_image',
      );
    }

    final base64Value = block.base64?.trim();
    if (base64Value != null && base64Value.isNotEmpty) {
      try {
        final bytes = base64Decode(base64Value);
        return _writeBytesToConversationMedia(
          conversationId,
          bytes: bytes,
          targetStem: '${block.messageId}_${block.id}_image',
          extension: '.jpg',
        );
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  Future<String> _resolveAudioSource(
    String conversationId,
    AudioBlock block,
  ) async {
    final rawUrl = block.url.trim();
    if (rawUrl.isEmpty) return rawUrl;

    final dataUrl = _parseDataUrl(rawUrl);
    if (dataUrl != null) {
      final ext = _guessExtensionFromMime(
        dataUrl.mimeType,
        fallback: '.bin',
      );
      return _writeBytesToConversationMedia(
        conversationId,
        bytes: dataUrl.bytes,
        targetStem: '${block.messageId}_${block.id}_audio',
        extension: ext,
      );
    }

    if (_isFileUrl(rawUrl)) {
      final localizedPath = await _copyLocalMediaFile(
        conversationId,
        sourcePath: _toFilePath(rawUrl),
        targetStem: '${block.messageId}_${block.id}_audio',
      );
      return localizedPath ?? rawUrl;
    }

    if (_looksLikeAbsoluteFilePath(rawUrl)) {
      final localizedPath = await _copyLocalMediaFile(
        conversationId,
        sourcePath: rawUrl,
        targetStem: '${block.messageId}_${block.id}_audio',
      );
      return localizedPath ?? rawUrl;
    }

    return rawUrl;
  }

  Future<String?> _copyLocalMediaFile(
    String conversationId, {
    required String sourcePath,
    required String targetStem,
  }) async {
    final normalizedSourcePath = sourcePath.trim();
    if (normalizedSourcePath.isEmpty ||
        !_looksLikeAbsoluteFilePath(normalizedSourcePath)) {
      return null;
    }
    final sourceFile = File(normalizedSourcePath);
    if (!await sourceFile.exists()) {
      return null;
    }

    final mediaDirectory = await _conversationMediaDirectory(conversationId);
    if (!await mediaDirectory.exists()) {
      await mediaDirectory.create(recursive: true);
    }

    final extension = p.extension(sourceFile.path);
    final targetPath = p.join(
      mediaDirectory.path,
      '$targetStem$extension',
    );
    final normalizedTargetPath = _normalizePathKey(targetPath);
    if (_normalizePathKey(sourceFile.path) == normalizedTargetPath) {
      return sourceFile.path;
    }

    final targetFile = File(targetPath);
    if (await targetFile.exists()) {
      final sourceLength = await sourceFile.length();
      final targetLength = await targetFile.length();
      if (sourceLength == targetLength) {
        return targetFile.path;
      }
      await targetFile.delete();
    }

    await sourceFile.copy(targetFile.path);
    return targetFile.path;
  }

  Future<String> _writeBytesToConversationMedia(
    String conversationId, {
    required List<int> bytes,
    required String targetStem,
    required String extension,
  }) async {
    final mediaDirectory = await _conversationMediaDirectory(conversationId);
    if (!await mediaDirectory.exists()) {
      await mediaDirectory.create(recursive: true);
    }

    final normalizedExtension = extension.isEmpty
        ? ''
        : extension.startsWith('.')
            ? extension
            : '.$extension';
    final targetFile = File(
      p.join(
        mediaDirectory.path,
        '$targetStem$normalizedExtension',
      ),
    );

    if (await targetFile.exists()) {
      final existingLength = await targetFile.length();
      if (existingLength == bytes.length) {
        return targetFile.path;
      }
      await targetFile.delete();
    }

    await targetFile.writeAsBytes(bytes, flush: true);
    return targetFile.path;
  }

  Future<void> _deleteUnreferencedMediaUnlocked(
    _ConversationShortWindowSnapshot snapshot,
  ) async {
    final mediaDirectory = await _conversationMediaDirectory(
      snapshot.conversationId,
    );
    if (!await mediaDirectory.exists()) return;

    final referencedFiles = <String>{
      for (final message in snapshot.messages)
        ..._collectReferencedLocalFiles(
          message,
          mediaRootPath: mediaDirectory.path,
        ),
    };

    await for (final entity in mediaDirectory.list()) {
      if (entity is! File) continue;
      final normalizedPath = _normalizePathKey(entity.path);
      if (referencedFiles.contains(normalizedPath)) {
        continue;
      }
      await entity.delete();
    }
  }

  Set<String> _collectReferencedLocalFiles(
    Message message, {
    required String mediaRootPath,
  }) {
    final files = <String>{};
    final blocks = message.blocks;
    if (blocks == null) return files;

    for (final block in blocks) {
      if (block is ImageBlock) {
        final localPath = block.localPath?.trim();
        if (localPath != null &&
            localPath.isNotEmpty &&
            _isWithinDirectory(localPath, mediaRootPath)) {
          files.add(_normalizePathKey(localPath));
        }
      } else if (block is AudioBlock) {
        final audioPath = block.url.trim();
        if (_looksLikeAbsoluteFilePath(audioPath) &&
            _isWithinDirectory(audioPath, mediaRootPath)) {
          files.add(_normalizePathKey(audioPath));
        }
      } else if (block is FileBlock) {
        final filePath = block.filePath.trim();
        if (_looksLikeAbsoluteFilePath(filePath) &&
            _isWithinDirectory(filePath, mediaRootPath)) {
          files.add(_normalizePathKey(filePath));
        }
      } else if (block is EmojiBlock) {
        final emojiPath = block.path.trim();
        if (_looksLikeAbsoluteFilePath(emojiPath) &&
            _isWithinDirectory(emojiPath, mediaRootPath)) {
          files.add(_normalizePathKey(emojiPath));
        }
      }
    }

    return files;
  }

  Future<_ConversationShortWindowSnapshot?> _readSnapshotFromDiskUnlocked(
    String conversationId,
  ) async {
    final file = await _conversationSnapshotFile(conversationId);
    if (!await file.exists()) {
      return null;
    }

    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) {
        return null;
      }
      return _deserializeSnapshot(
        Map<String, dynamic>.from(raw),
        expectedConversationId: conversationId,
      );
    } catch (_) {
      return null;
    }
  }

  _ConversationShortWindowSnapshot? _deserializeSnapshot(
    Map<String, dynamic> raw, {
    required String expectedConversationId,
  }) {
    final conversationId = raw['conversationId'] as String?;
    if (conversationId == null || conversationId != expectedConversationId) {
      return null;
    }

    final rawMessages = raw['messages'];
    if (rawMessages is! List) {
      return null;
    }

    final messages = <Message>[];
    for (final item in rawMessages) {
      if (item is! Map) {
        return null;
      }
      final message = _deserializeMessage(Map<String, dynamic>.from(item));
      if (message == null) {
        return null;
      }
      messages.add(message);
    }

    return _ConversationShortWindowSnapshot(
      conversationId: conversationId,
      messages: _normalizeMessages(messages),
      hasMoreMessages: raw['hasMoreMessages'] == true,
    );
  }

  Future<void> _deleteConversationDirectoryUnlocked(
    String conversationId,
  ) async {
    final directory = await _conversationDirectory(conversationId);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _scheduleBudgetEnforcement() {
    _budgetTask = _budgetTask.catchError((_) {}).then((_) async {
      try {
        final rootDirectory = await _rootDirectory();
        if (!await rootDirectory.exists()) {
          return;
        }

        final totalBytes = await _directorySize(rootDirectory);
        if (totalBytes <= kConversationShortWindowBudgetBytes) {
          return;
        }

        final conversationIds = await _listPersistedConversationIds();
        for (final conversationId in conversationIds) {
          await _runConversationTask(conversationId, () async {
            final compacted = await _loadRecentSnapshotFromDb(
              conversationId,
              targetCount: kConversationShortWindowSeedMessageCount,
            );
            final next = await _persistSnapshotUnlocked(
              compacted,
              allowBudgetEnforcement: false,
            );
            _snapshotsByConversation[conversationId] = next;
            _notifyConversationChanged(conversationId);
          });
        }
      } on FileSystemException {
        return;
      }
    });
    return _budgetTask;
  }

  Future<List<String>> _listPersistedConversationIds() async {
    final ids = <String>{
      ..._snapshotsByConversation.keys,
    };
    final rootDirectory = await _rootDirectory();
    if (!await rootDirectory.exists()) {
      return ids.toList(growable: false);
    }

    await for (final entity in rootDirectory.list()) {
      if (entity is! Directory) continue;
      final file = File(
        p.join(entity.path, _kConversationShortWindowFileName),
      );
      if (!await file.exists()) continue;
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is! Map) continue;
        final conversationId = raw['conversationId'] as String?;
        if (conversationId == null || conversationId.trim().isEmpty) {
          continue;
        }
        ids.add(conversationId.trim());
      } catch (_) {
        continue;
      }
    }
    return ids.toList(growable: false);
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

    return <Message>[
      for (final dbMessage in dbMessages)
        MessageConverter.fromDb(
          dbMessage,
          blocks: blocksByMessageId[dbMessage.id],
        ),
    ];
  }

  Future<Directory> _rootDirectory() {
    final existingFuture = _rootDirectoryFuture;
    if (existingFuture != null) {
      return existingFuture;
    }
    final nextFuture = () async {
      final appDirectory = await getApplicationDocumentsDirectory();
      final rootDirectory = Directory(
        p.join(
          appDirectory.path,
          kConversationShortWindowRootDirectoryName,
        ),
      );
      if (!await rootDirectory.exists()) {
        await rootDirectory.create(recursive: true);
      }
      return rootDirectory;
    }();
    _rootDirectoryFuture = nextFuture;
    return nextFuture;
  }

  Future<Directory> _conversationDirectory(String conversationId) async {
    final rootDirectory = await _rootDirectory();
    return Directory(
      p.join(rootDirectory.path, _encodeConversationId(conversationId)),
    );
  }

  Future<Directory> _conversationMediaDirectory(String conversationId) async {
    final directory = await _conversationDirectory(conversationId);
    return Directory(
      p.join(directory.path, _kConversationShortWindowMediaDirectoryName),
    );
  }

  Future<File> _conversationSnapshotFile(String conversationId) async {
    final directory = await _conversationDirectory(conversationId);
    return File(
      p.join(directory.path, _kConversationShortWindowFileName),
    );
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
  });

  final List<Message> messages;
  final bool hasMoreMessages;
}

class _ConversationShortWindowSnapshot {
  const _ConversationShortWindowSnapshot({
    required this.conversationId,
    required this.messages,
    required this.hasMoreMessages,
  });

  final String conversationId;
  final List<Message> messages;
  final bool hasMoreMessages;

  _ConversationShortWindowSnapshot copyWith({
    List<Message>? messages,
    bool? hasMoreMessages,
  }) {
    return _ConversationShortWindowSnapshot(
      conversationId: conversationId,
      messages: messages ?? this.messages,
      hasMoreMessages: hasMoreMessages ?? this.hasMoreMessages,
    );
  }
}

ConversationShortWindowState _buildWindow(
  _ConversationShortWindowSnapshot snapshot, {
  required int limit,
}) {
  final normalizedLimit = limit < 1 ? 1 : limit;
  final startIndex = snapshot.messages.length > normalizedLimit
      ? snapshot.messages.length - normalizedLimit
      : 0;
  final visibleMessages = List<Message>.unmodifiable(
    snapshot.messages.sublist(startIndex),
  );
  return ConversationShortWindowState(
    messages: visibleMessages,
    hasMoreMessages: snapshot.hasMoreMessages || startIndex > 0,
  );
}

List<Message> _normalizeMessages(Iterable<Message> messages) {
  final deduped = <String, Message>{};
  for (final message in messages) {
    deduped[message.id] = message;
  }
  final normalized = deduped.values.toList(growable: false)
    ..sort((left, right) {
      final byTime = left.createdAt.compareTo(right.createdAt);
      if (byTime != 0) {
        return byTime;
      }
      return left.id.compareTo(right.id);
    });
  return normalized;
}

Map<String, dynamic> _serializeMessage(Message message) {
  return <String, dynamic>{
    'id': message.id,
    'role': message.role,
    'content': message.content,
    'createdAt': message.createdAt.millisecondsSinceEpoch,
    'status': message.status,
    'blocks': <Map<String, dynamic>>[
      for (final block in message.blocks ?? const <MessageBlock>[])
        block.toJson(),
    ],
  };
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
    for (final rawBlock in rawBlocks) {
      if (rawBlock is! Map) {
        return null;
      }
      try {
        blocks.add(
          MessageBlock.fromJson(Map<String, dynamic>.from(rawBlock)),
        );
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

String _encodeConversationId(String conversationId) {
  return base64UrlEncode(utf8.encode(conversationId)).replaceAll('=', '');
}

bool _isFileUrl(String value) => value.startsWith('file://');

bool _looksLikeAbsoluteFilePath(String value) {
  if (value.trim().isEmpty) {
    return false;
  }
  return p.isAbsolute(value);
}

String _toFilePath(String fileUrl) {
  return Uri.parse(fileUrl).toFilePath();
}

bool _isWithinDirectory(String filePath, String directoryPath) {
  final normalizedFilePath = p.normalize(filePath);
  final normalizedDirectoryPath = p.normalize(directoryPath);
  return p.isWithin(normalizedDirectoryPath, normalizedFilePath) ||
      _normalizePathKey(normalizedFilePath) ==
          _normalizePathKey(normalizedDirectoryPath);
}

String _normalizePathKey(String value) {
  return p.normalize(value).toLowerCase();
}

int _maxInt(int left, int right) => left > right ? left : right;

class _DecodedDataUrl {
  const _DecodedDataUrl({
    required this.mimeType,
    required this.bytes,
  });

  final String mimeType;
  final List<int> bytes;
}

_DecodedDataUrl? _parseDataUrl(String value) {
  if (!value.startsWith('data:')) {
    return null;
  }
  final commaIndex = value.indexOf(',');
  if (commaIndex <= 'data:'.length) {
    return null;
  }
  final meta = value.substring('data:'.length, commaIndex);
  final parts = meta.split(';');
  final mimeType = parts.isNotEmpty && parts.first.trim().isNotEmpty
      ? parts.first.trim()
      : 'application/octet-stream';
  final isBase64 = parts.any((part) => part.toLowerCase() == 'base64');
  if (!isBase64) {
    return null;
  }
  try {
    final bytes = base64Decode(value.substring(commaIndex + 1));
    return _DecodedDataUrl(
      mimeType: mimeType,
      bytes: bytes,
    );
  } catch (_) {
    return null;
  }
}

String _guessExtensionFromMime(
  String mimeType, {
  required String fallback,
}) {
  final normalized = mimeType.toLowerCase();
  if (normalized.contains('png')) return '.png';
  if (normalized.contains('jpeg') || normalized.contains('jpg')) return '.jpg';
  if (normalized.contains('webp')) return '.webp';
  if (normalized.contains('gif')) return '.gif';
  if (normalized.contains('wav')) return '.wav';
  if (normalized.contains('mpeg') || normalized.contains('mp3')) return '.mp3';
  if (normalized.contains('ogg')) return '.ogg';
  if (normalized.contains('aac')) return '.aac';
  if (normalized.contains('m4a') || normalized.contains('mp4')) return '.m4a';
  return fallback.startsWith('.') ? fallback : '.$fallback';
}

Future<int> _directorySize(Directory directory) async {
  var total = 0;
  try {
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) continue;
      try {
        total += await entity.length();
      } on FileSystemException {
        continue;
      }
    }
  } on FileSystemException {
    return total;
  }
  return total;
}

final conversationShortWindowStoreProvider =
    Provider<ConversationShortWindowStore>((ref) {
  final store = ConversationShortWindowStore(ref);
  ref.onDispose(store.dispose);
  return store;
});
