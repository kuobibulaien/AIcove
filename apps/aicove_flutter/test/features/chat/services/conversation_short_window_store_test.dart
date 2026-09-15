import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/repositories.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/chat/services/image_dimension_probe/image_dimension_probe.dart';
import 'package:aicove_flutter/src/features/chat/services/image_dimension_probe/probe_stub.dart'
    as probe_stub;

Future<void> _insertConversation(
  db.AppDatabase database,
  String conversationId,
  int timestamp,
) {
  return database
      .into(database.conversations)
      .insert(
        db.ConversationsCompanion.insert(
          id: conversationId,
          title: '测试会话',
          displayName: '测试会话',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
}

Future<void> _persistMessage(
  ProviderContainer container,
  String conversationId,
  Message message,
) async {
  final messageRepo = container.read(messageRepositoryProvider);
  final blockRepo = container.read(messageBlockRepositoryProvider);
  await messageRepo.upsert(
    MessageConverter.toCompanion(message, conversationId),
  );
  final blocks = message.blocks ?? const <MessageBlock>[];
  for (var index = 0; index < blocks.length; index++) {
    await blockRepo.upsert(
      MessageBlockConverter.toCompanion(blocks[index], message.id, index),
    );
  }
}

Future<File> _writeTestPng(
  String filePath, {
  required int width,
  required int height,
}) async {
  final image = img.Image(width: width, height: height);
  final bytes = img.encodePng(image);
  final file = File(filePath);
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

ImageDimensions _dims(int width, int height) => ImageDimensions(
  width: width,
  height: height,
  hitSource: ImageDimensionProbeSource.localPath,
);

/// 可脚本化 fake 探测：记录输入、支持第 N 次调用信号。
class _FakeProbe {
  _FakeProbe(this.handler);

  Future<ImageDimensions?> Function(ImageDimensionProbeInput input) handler;
  final List<ImageDimensionProbeInput> inputs = <ImageDimensionProbeInput>[];
  final Map<int, Completer<void>> _callSignals = <int, Completer<void>>{};

  int get callCount => inputs.length;

  Completer<void> signalAtCall(int callNumber) {
    final completer = _callSignals.putIfAbsent(callNumber, Completer<void>.new);
    // 注册时该调用若已发生，立即补发信号，避免注册时机竞态。
    if (inputs.length >= callNumber && !completer.isCompleted) {
      completer.complete();
    }
    return completer;
  }

  Future<ImageDimensions?> call(ImageDimensionProbeInput input) {
    inputs.add(input);
    final signal = _callSignals[inputs.length];
    if (signal != null && !signal.isCompleted) {
      signal.complete();
    }
    return handler(input);
  }
}

_FakeProbe _nullProbe() => _FakeProbe((_) async => null);

class _SpyMessageBlockRepository extends MessageBlockRepository {
  _SpyMessageBlockRepository(super.database);

  int casCallCount = 0;
  final List<String> casRowIds = <String>[];
  Object? Function(String rowId)? throwOnCas;

  @override
  Future<int> updateDataIfUnchanged({
    required String id,
    required String expectedData,
    required String newData,
  }) {
    casCallCount++;
    casRowIds.add(id);
    final error = throwOnCas?.call(id);
    if (error != null) {
      throw error;
    }
    return super.updateDataIfUnchanged(
      id: id,
      expectedData: expectedData,
      newData: newData,
    );
  }
}

class _SpyMappingRepository extends MessageProjectionMappingRepository {
  _SpyMappingRepository(super.database);

  int writeCallCount = 0;

  @override
  Future<void> upsert(db.MessageProjectionMappingsCompanion data) {
    writeCallCount++;
    return super.upsert(data);
  }

  @override
  Future<void> replaceForRawMessage({
    required String rawMessageId,
    required List<db.MessageProjectionMappingsCompanion> mappings,
  }) {
    writeCallCount++;
    return super.replaceForRawMessage(
      rawMessageId: rawMessageId,
      mappings: mappings,
    );
  }

  @override
  Future<void> replaceForConversation({
    required String conversationId,
    required List<db.MessageProjectionMappingsCompanion> mappings,
  }) {
    writeCallCount++;
    return super.replaceForConversation(
      conversationId: conversationId,
      mappings: mappings,
    );
  }
}

class _GatedMessageRepository extends MessageRepository {
  _GatedMessageRepository(super.database);

  Completer<void>? gate;
  Completer<void>? entered;

  @override
  Future<List<db.Message>> getByConversationForDisplay(
    String conversationId, {
    int limit = 50,
    int? beforeTime,
    String? beforeId,
  }) async {
    final currentGate = gate;
    if (currentGate != null) {
      final enteredSignal = entered;
      if (enteredSignal != null && !enteredSignal.isCompleted) {
        enteredSignal.complete();
      }
      await currentGate.future;
    }
    return super.getByConversationForDisplay(
      conversationId,
      limit: limit,
      beforeTime: beforeTime,
      beforeId: beforeId,
    );
  }
}

/// 订阅窗口流并记录事件；提供「等到第 N 个事件」的有界等待。
class _WindowRecorder {
  _WindowRecorder(Stream<ConversationTimelineWindowState> stream) {
    _subscription = stream.listen((event) {
      events.add(event);
      _waiters.remove(events.length)?.complete();
    });
  }

  late final StreamSubscription<ConversationTimelineWindowState> _subscription;
  final List<ConversationTimelineWindowState> events =
      <ConversationTimelineWindowState>[];
  final Map<int, Completer<void>> _waiters = <int, Completer<void>>{};

  Future<void> waitForEventCount(
    int count, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    if (events.length >= count) {
      return Future<void>.value();
    }
    final completer = _waiters.putIfAbsent(count, Completer<void>.new);
    return completer.future.timeout(timeout);
  }

  Future<void> close() => _subscription.cancel();
}

/// 等待维护队列收敛：以计数稳定为终止条件（非固定延迟轮询）。
///
/// 每轮入队一个读取任务（排在既有维护任务之后），完成即代表此前任务
/// 已结束；连续一轮计数无变化即收敛。
Future<void> _drainMaintenance(
  ConversationTimelineCache store,
  String conversationId, {
  int maxIterations = 10,
}) async {
  var lastSignature = -1;
  for (var i = 0; i < maxIterations; i += 1) {
    await store
        .loadCachedMessages(conversationId)
        .timeout(const Duration(seconds: 10));
    // 泵两拍事件循环，让维护尾处理与变更通知落地。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final signature =
        store.debugProbeCount * 1000003 + store.debugMaintenanceEnqueueCount;
    if (signature == lastSignature) {
      return;
    }
    lastSignature = signature;
  }
  fail('维护队列在 $maxIterations 轮内未收敛');
}

ProviderContainer _createTimelineContainer(
  db.AppDatabase database, {
  List<Override> overrides = const <Override>[],
}) {
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(database), ...overrides],
  );
  return container;
}

Message _projectedImageMessage({
  required String id,
  required String sourceMessageId,
  String? localPath,
  String? url,
  String? base64,
  required DateTime createdAt,
}) {
  return Message.fromBlocks(
    id: id,
    role: 'assistant',
    sourceMessageId: sourceMessageId,
    blocks: <MessageBlock>[
      ImageBlock(messageId: id, localPath: localPath, url: url, base64: base64),
    ],
    createdAt: createdAt,
  );
}

Future<Map<String, dynamic>> _readSingleImageRowData(
  ProviderContainer container,
  String rawMessageId, {
  String? rowId,
}) async {
  final rows = await container
      .read(messageBlockRepositoryProvider)
      .getByMessage(rawMessageId);
  final row = rowId == null
      ? rows.single
      : rows.firstWhere((candidate) => candidate.id == rowId);
  return jsonDecode(row.data) as Map<String, dynamic>;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tempDir;

  tearDown(() async {
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  test('无热缓存时应从数据库尾部 raw 消息构建前端时间线', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-seed', baseTime);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    for (var i = 1; i <= 24; i++) {
      await _persistMessage(
        container,
        'conv-seed',
        Message(
          id: 'm$i',
          role: i.isOdd ? 'user' : 'assistant',
          content: 'message-$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
        ),
      );
    }

    final store = container.read(conversationTimelineCacheProvider);
    final window = await store
        .watchWindow(conversationId: 'conv-seed', limit: 20)
        .first;

    expect(
      window.messages.map((message) => message.id).toList(),
      List<String>.generate(20, (index) => 'm${index + 5}', growable: false),
    );
    expect(window.hasMoreMessages, isTrue);
    expect(await store.loadCachedMessageCount('conv-seed'), 20);
  });

  test('loadOlderMessages 应按 raw 分页扩展前端缓存', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 30, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-page', baseTime);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    for (var i = 1; i <= 30; i++) {
      await _persistMessage(
        container,
        'conv-page',
        Message(
          id: 'm$i',
          role: i.isOdd ? 'user' : 'assistant',
          content: 'message-$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
        ),
      );
    }

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore(
      'conv-page',
      targetMessageCount: 20,
    );
    final addedCount = await store.loadOlderMessages(
      conversationId: 'conv-page',
      pageSize: 20,
    );

    expect(addedCount, 10);
    expect(
      (await store.loadCachedMessages(
        'conv-page',
      )).map((message) => message.id).toList(),
      List<String>.generate(30, (index) => 'm${index + 1}', growable: false),
    );

    final expandedWindow = await store
        .watchWindow(conversationId: 'conv-page', limit: 40)
        .first;
    expect(expandedWindow.hasMoreMessages, isFalse);
  });

  test('窗口应按 raw 消息数裁切，而不是按前端投影气泡数裁切', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 45, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-projection-window', baseTime);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-projection-window',
      Message.text(
        id: 'raw_old_user',
        role: 'user',
        content: '更早的一条用户消息',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );
    await _persistMessage(
      container,
      'conv-projection-window',
      Message.text(
        id: 'raw_mid_ai',
        role: 'assistant',
        content: '中间这条助手消息',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
      ),
    );
    await _persistMessage(
      container,
      'conv-projection-window',
      Message.fromBlocks(
        id: 'raw_latest_user_mixed',
        role: 'user',
        blocks: <MessageBlock>[
          TextBlock(messageId: 'raw_latest_user_mixed', content: '最新一条用户图文消息'),
          ImageBlock(
            messageId: 'raw_latest_user_mixed',
            localPath: r'C:\mock\latest_image.png',
            width: 120,
            height: 80,
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    final window = await store
        .watchWindow(conversationId: 'conv-projection-window', limit: 2)
        .first;

    expect(
      window.messages.map((message) => message.id).toList(),
      <String>[
        'raw_mid_ai',
        'raw_latest_user_mixed__proj_00_text',
        'raw_latest_user_mixed__proj_01_image',
      ],
      reason: '最近 2 条 raw 消息中，最后一条被前端拆成 2 个气泡时，窗口仍应完整保留这 2 条 raw 的全部投影。',
    );
    expect(window.hasMoreMessages, isTrue);
    expect(
      await store.loadCachedMessageCount('conv-projection-window'),
      3,
      reason: '缓存计数应以 raw 消息数为准，而不是投影后的气泡条数。',
    );
  });

  test('共享 pending source id 的流式占位在短窗里只占一个 raw 槽位', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 47, 0).millisecondsSinceEpoch;
    await _insertConversation(
      database,
      'conv-stream-placeholder-window',
      baseTime,
    );

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-stream-placeholder-window',
      Message.text(
        id: 'raw_old_user',
        role: 'user',
        content: '更早的一条用户消息',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );
    await _persistMessage(
      container,
      'conv-stream-placeholder-window',
      Message.text(
        id: 'raw_mid_ai',
        role: 'assistant',
        content: '短窗里应该保留的上一轮助手消息',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore(
      'conv-stream-placeholder-window',
      targetMessageCount: 20,
    );
    await store.replaceMessagesTransient(
      conversationId: 'conv-stream-placeholder-window',
      messages: <Message>[
        Message.text(
          id: 'stream_part_1',
          role: 'assistant',
          content: '第一段。',
          sourceMessageId: 'raw_msg_pending_stream',
          status: 'sending',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
        ),
        Message.text(
          id: 'stream_part_2',
          role: 'assistant',
          content: '第二段。',
          sourceMessageId: 'raw_msg_pending_stream',
          status: 'sending',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 4),
        ),
      ],
    );

    final window = await store
        .watchWindow(conversationId: 'conv-stream-placeholder-window', limit: 2)
        .first;

    expect(
      window.messages.map((message) => message.id).toList(),
      <String>['raw_mid_ai', 'stream_part_1', 'stream_part_2'],
      reason: '同一轮流式占位拆成多条前端气泡时，短窗应按共享 pending source id 把它们算作一个 raw 槽位。',
    );
    expect(window.hasMoreMessages, isTrue);
  });

  test('loadOlderMessages 返回值应按 raw 消息条数计算，而不是按投影气泡数计算', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 50, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-load-older-raw-count', baseTime);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-load-older-raw-count',
      Message.fromBlocks(
        id: 'raw_old_mixed',
        role: 'assistant',
        blocks: <MessageBlock>[
          TextBlock(messageId: 'raw_old_mixed', content: '更早的一条图文助手消息'),
          ImageBlock(
            messageId: 'raw_old_mixed',
            localPath: r'C:\mock\older_image.png',
            width: 96,
            height: 72,
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await _persistMessage(
        container,
        'conv-load-older-raw-count',
        Message.text(
          id: 'raw_seed_$i',
          role: i.isEven ? 'user' : 'assistant',
          content: 'seed-$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2 + i),
        ),
      );
    }

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore(
      'conv-load-older-raw-count',
      targetMessageCount: 20,
    );

    final addedCount = await store.loadOlderMessages(
      conversationId: 'conv-load-older-raw-count',
      pageSize: 1,
    );

    expect(addedCount, 1);
    expect(
      (await store.loadCachedMessages(
        'conv-load-older-raw-count',
      )).map((message) => message.id).toList(),
      <String>[
        'raw_old_mixed__proj_00_text',
        'raw_old_mixed__proj_01_image',
        for (var i = 0; i < 20; i++) 'raw_seed_$i',
      ],
    );
  });

  test('syncConversation 应按 raw 数据重建并清掉前端临时气泡', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 11, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-sync', baseTime);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-sync',
      Message(
        id: 'raw_1',
        role: 'assistant',
        content: 'raw assistant',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore(
      'conv-sync',
      targetMessageCount: 20,
    );
    await store.upsertMessage(
      conversationId: 'conv-sync',
      message: Message(
        id: 'proj_1',
        role: 'assistant',
        content: 'frontend only bubble',
        sourceMessageId: 'raw_1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
      ),
    );
    expect(
      (await store.loadCachedMessages(
        'conv-sync',
      )).map((message) => message.id),
      contains('proj_1'),
    );

    await store.reloadConversationFromRawStore(
      'conv-sync',
      targetMessageCount: 20,
    );

    expect(
      (await store.loadCachedMessages(
        'conv-sync',
      )).map((message) => message.id).toList(),
      <String>['raw_1'],
    );
  });

  test('前端缓存改动不应污染 raw 数据库消息', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 11, 30, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-separate', baseTime);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-separate',
      Message(
        id: 'raw_1',
        role: 'assistant',
        content: 'raw content',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore(
      'conv-separate',
      targetMessageCount: 20,
    );
    await store.replaceMessages(
      conversationId: 'conv-separate',
      removeMessageIds: const <String>['raw_1'],
      messages: <Message>[
        Message(
          id: 'proj_1',
          role: 'assistant',
          content: 'frontend override',
          sourceMessageId: 'raw_1',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      ],
    );

    expect(
      (await store.loadCachedMessages('conv-separate')).single.content,
      'frontend override',
    );
    expect(
      (await container
              .read(chatHistoryStoreProvider)
              .loadAllRawMessages('conv-separate'))
          .single
          .content,
      'raw content',
    );
  });

  test('transient replaceMessages 不应重写 raw projection mapping', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 11, 40, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-transient-replace', baseTime);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-transient-replace',
      Message(
        id: 'raw_1',
        role: 'assistant',
        content: 'raw content',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore(
      'conv-transient-replace',
      targetMessageCount: 20,
    );
    final mappingRepo = container.read(
      messageProjectionMappingRepositoryProvider,
    );
    final beforeMappings = await mappingRepo.getByRawMessage('raw_1');

    await store.replaceMessagesTransient(
      conversationId: 'conv-transient-replace',
      removeMessageIds: const <String>['raw_1'],
      messages: <Message>[
        Message(
          id: 'proj_streaming_1',
          role: 'assistant',
          content: 'streaming content',
          sourceMessageId: 'raw_1',
          status: 'sending',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      ],
    );

    expect(
      (await store.loadCachedMessages('conv-transient-replace')).single.id,
      'proj_streaming_1',
    );
    expect(
      await mappingRepo.getByRawMessage('raw_1'),
      beforeMappings,
      reason:
          '流式占位只应更新前台时间线，不应在每次 flush 时把 raw projection mapping 改写成临时 sending 气泡。',
    );
  });

  test('findMessageById 应优先返回当前前端缓存中的投影消息', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 12, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-find', baseTime);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-find',
      Message(
        id: 'raw_1',
        role: 'assistant',
        content: 'raw content',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.upsertMessage(
      conversationId: 'conv-find',
      message: Message(
        id: 'proj_1',
        role: 'assistant',
        content: 'frontend projection',
        sourceMessageId: 'raw_1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
      ),
    );

    final found = await store.findCachedMessageById(
      'proj_1',
      conversationId: 'conv-find',
    );

    expect(found, isNotNull);
    expect(found!.content, 'frontend projection');
  });

  test('本地图片尺寸应在后台补齐，而不阻塞首个时间线窗口返回', () async {
    tempDir = await Directory.systemTemp.createTemp('timeline_image_dim_');

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 12, 30, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-image', baseTime);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    final imageFile = await _writeTestPng(
      '${tempDir!.path}\\image.png',
      width: 64,
      height: 48,
    );
    await _persistMessage(
      container,
      'conv-image',
      Message.fromBlocks(
        id: 'img_1',
        role: 'assistant',
        blocks: <MessageBlock>[
          ImageBlock(
            messageId: 'img_1',
            localPath: imageFile.path,
            prompt: 'test image',
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    final firstWindow = await store
        .watchWindow(conversationId: 'conv-image', limit: 20)
        .first;
    final firstImageBlock =
        firstWindow.messages.single.blocks!.single as ImageBlock;
    expect(firstImageBlock.width, isNull);
    expect(firstImageBlock.height, isNull);

    ImageBlock? upgradedImageBlock;
    for (var i = 0; i < 40; i++) {
      final cachedMessages = await store.loadCachedMessages('conv-image');
      final candidate = cachedMessages.single.blocks!.single as ImageBlock;
      if (candidate.width != null && candidate.height != null) {
        upgradedImageBlock = candidate;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(upgradedImageBlock, isNotNull);
    final resolvedImageBlock = upgradedImageBlock!;
    expect(resolvedImageBlock.width, 64);
    expect(resolvedImageBlock.height, 48);
  });

  group('T1 维护收敛矩阵', () {
    test('仅 https 远程图不产生探测、不入队维护', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 9, 0, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t1-https', baseTime);

      final probe = _FakeProbe((_) async => _dims(9, 9));
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t1-https',
        Message.fromBlocks(
          id: 'img_https',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(
              messageId: 'img_https',
              url: 'https://example.com/remote.png',
            ),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t1-https');
      await _drainMaintenance(store, 'conv-t1-https');

      expect(probe.callCount, 0);
      expect(store.debugProbeCount, 0);
      expect(store.debugMaintenanceEnqueueCount, 0);
      final block =
          (await store.loadCachedMessages(
                'conv-t1-https',
              )).single.blocks!.single
              as ImageBlock;
      expect(block.width, isNull);
      expect(block.height, isNull);
    });

    test('丢失本地文件恰探测一次即收敛：无 DB 写、无快照替换、无通知', () async {
      tempDir = await Directory.systemTemp.createTemp('timeline_probe_');
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 9, 5, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t1-missing', baseTime);

      final probe = _nullProbe();
      final spyBlocks = _SpyMessageBlockRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t1-missing',
        Message.fromBlocks(
          id: 'img_missing',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(
              messageId: 'img_missing',
              localPath: '${tempDir!.path}/missing.png',
            ),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      final recorder = _WindowRecorder(
        store.watchWindow(conversationId: 'conv-t1-missing', limit: 20),
      );
      addTearDown(recorder.close);
      await recorder.waitForEventCount(1);
      await _drainMaintenance(store, 'conv-t1-missing');

      expect(store.debugProbeCount, 1, reason: '丢失文件恰好探测一次');
      expect(store.debugMaintenanceEnqueueCount, 1);
      expect(spyBlocks.casCallCount, 0, reason: '全败维护轮不写任何 DB');

      // 后续读取不再触发新探测。
      store.peekWindow(conversationId: 'conv-t1-missing', limit: 20);
      await store
          .watchWindow(conversationId: 'conv-t1-missing', limit: 20)
          .first;
      await _drainMaintenance(store, 'conv-t1-missing');

      expect(store.debugProbeCount, 1);
      expect(store.debugMaintenanceEnqueueCount, 1);
      expect(recorder.events.length, 1, reason: '全败维护轮不发通知（无自激）');
      final block =
          (await store.loadCachedMessages(
                'conv-t1-missing',
              )).single.blocks!.single
              as ImageBlock;
      expect(block.width, isNull);
    });

    test('损坏本地图恰探测一次即收敛（真实探测）', () async {
      tempDir = await Directory.systemTemp.createTemp('timeline_probe_');
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 9, 10, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t1-broken', baseTime);

      final brokenFile = File('${tempDir!.path}/broken.png');
      await brokenFile.writeAsBytes(
        List<int>.generate(128, (index) => index),
        flush: true,
      );

      final container = _createTimelineContainer(database);
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t1-broken',
        Message.fromBlocks(
          id: 'img_broken',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'img_broken', localPath: brokenFile.path),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t1-broken');
      await _drainMaintenance(store, 'conv-t1-broken');

      expect(store.debugProbeCount, 1);
      await store.loadCachedMessages('conv-t1-broken');
      await _drainMaintenance(store, 'conv-t1-broken');
      expect(store.debugProbeCount, 1, reason: '损坏图 attempted 后不再重试');
      final block =
          (await store.loadCachedMessages(
                'conv-t1-broken',
              )).single.blocks!.single
              as ImageBlock;
      expect(block.width, isNull);
    });

    test('成功探测补齐宽高＋恰一次通知＋CAS 写回 DB，新实例不再探测', () async {
      tempDir = await Directory.systemTemp.createTemp('timeline_probe_');
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 9, 15, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t1-ok', baseTime);

      final pngFile = await _writeTestPng(
        '${tempDir!.path}/one.png',
        width: 1,
        height: 1,
      );

      final container = _createTimelineContainer(database);
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t1-ok',
        Message.fromBlocks(
          id: 'img_ok',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'img_ok', localPath: pngFile.path),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      final recorder = _WindowRecorder(
        store.watchWindow(conversationId: 'conv-t1-ok', limit: 20),
      );
      addTearDown(recorder.close);

      await recorder.waitForEventCount(1);
      final firstBlock =
          recorder.events.first.messages.single.blocks!.single as ImageBlock;
      expect(firstBlock.width, isNull, reason: '首个窗口不等待探测');

      await recorder.waitForEventCount(2);
      final upgradedBlock =
          recorder.events.last.messages.single.blocks!.single as ImageBlock;
      expect(upgradedBlock.width, 1);
      expect(upgradedBlock.height, 1);
      expect(store.debugProbeCount, 1);

      final rowData = await _readSingleImageRowData(container, 'img_ok');
      expect(rowData['width'], 1, reason: '成功尺寸 CAS 写回 message_blocks');
      expect(rowData['height'], 1);
      expect(rowData['localPath'], pngFile.path, reason: '其余字段原样保留');

      // 模拟重启：同一数据库、新容器新缓存实例，装载后不再探测。
      final probe2 = _FakeProbe((_) async => _dims(9, 9));
      final container2 = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe2.call)],
      );
      addTearDown(container2.dispose);
      final store2 = container2.read(conversationTimelineCacheProvider);
      await store2.reloadConversationFromRawStore('conv-t1-ok');
      await _drainMaintenance(store2, 'conv-t1-ok');

      expect(probe2.callCount, 0, reason: '重启后从 DB 直接取到宽高，不再探测');
      final restoredBlock =
          (await store2.loadCachedMessages('conv-t1-ok')).single.blocks!.single
              as ImageBlock;
      expect(restoredBlock.width, 1);
      expect(restoredBlock.height, 1);
    });

    test('部分成功：好块补齐坏块收敛，单次通知', () async {
      tempDir = await Directory.systemTemp.createTemp('timeline_probe_');
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 9, 20, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t1-partial', baseTime);

      final pngFile = await _writeTestPng(
        '${tempDir!.path}/good.png',
        width: 1,
        height: 1,
      );

      final container = _createTimelineContainer(database);
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t1-partial',
        Message.fromBlocks(
          id: 'img_good',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'img_good', localPath: pngFile.path),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );
      await _persistMessage(
        container,
        'conv-t1-partial',
        Message.fromBlocks(
          id: 'img_lost',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(
              messageId: 'img_lost',
              localPath: '${tempDir!.path}/lost.png',
            ),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      final recorder = _WindowRecorder(
        store.watchWindow(conversationId: 'conv-t1-partial', limit: 20),
      );
      addTearDown(recorder.close);

      await recorder.waitForEventCount(2);
      await _drainMaintenance(store, 'conv-t1-partial');

      expect(store.debugProbeCount, 2);
      expect(recorder.events.length, 2, reason: '部分成功的维护轮只通知一次');
      final messages = await store.loadCachedMessages('conv-t1-partial');
      final goodBlock =
          messages
                  .firstWhere((message) => message.id == 'img_good')
                  .blocks!
                  .single
              as ImageBlock;
      final lostBlock =
          messages
                  .firstWhere((message) => message.id == 'img_lost')
                  .blocks!
                  .single
              as ImageBlock;
      expect(goodBlock.width, 1);
      expect(goodBlock.height, 1);
      expect(lostBlock.width, isNull);
    });

    test('多来源回退：失效 localPath＋有效 base64 命中 base64（真实探测）', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 9, 25, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t1-fallback', baseTime);

      final pngBase64 = base64Encode(
        img.encodePng(img.Image(width: 5, height: 9)),
      );

      final container = _createTimelineContainer(database);
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t1-fallback',
        Message.fromBlocks(
          id: 'img_fallback',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(
              messageId: 'img_fallback',
              localPath: '/definitely/not/exists.png',
              base64: pngBase64,
            ),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      final recorder = _WindowRecorder(
        store.watchWindow(conversationId: 'conv-t1-fallback', limit: 20),
      );
      addTearDown(recorder.close);

      await recorder.waitForEventCount(2);
      final block =
          recorder.events.last.messages.single.blocks!.single as ImageBlock;
      expect(block.width, 5);
      expect(block.height, 9);

      final rowData = await _readSingleImageRowData(container, 'img_fallback');
      expect(rowData['width'], 5);
      expect(rowData['height'], 9);
    });

    test('重投影（块 UUID 变化）不绕过 attempted', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 9, 30, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t1-reproject', baseTime);

      final probe = _nullProbe();
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t1-reproject',
        Message(
          id: 'raw_reproject',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t1-reproject');
      await store.upsertMessage(
        conversationId: 'conv-t1-reproject',
        message: _projectedImageMessage(
          id: 'proj_a',
          sourceMessageId: 'raw_reproject',
          localPath: '/gone/reproject.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );
      await _drainMaintenance(store, 'conv-t1-reproject');
      expect(store.debugProbeCount, 1);

      // 重投影：新块 UUID、同 raw 消息、同来源。
      await store.upsertMessage(
        conversationId: 'conv-t1-reproject',
        message: _projectedImageMessage(
          id: 'proj_b',
          sourceMessageId: 'raw_reproject',
          localPath: '/gone/reproject.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
        ),
      );
      await _drainMaintenance(store, 'conv-t1-reproject');

      expect(store.debugProbeCount, 1, reason: 'attempted 身份不受块 UUID 影响');
    });

    test('Web 桩注入下一次 attempted 后静默收敛（Web 行为存储层等价验证）', () async {
      tempDir = await Directory.systemTemp.createTemp('timeline_probe_');
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 9, 35, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t1-webstub', baseTime);

      // 真实可解码 PNG——桩仍应返回 null，且缓存静默收敛。
      final pngFile = await _writeTestPng(
        '${tempDir!.path}/web.png',
        width: 2,
        height: 2,
      );

      final spyBlocks = _SpyMessageBlockRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(
            probe_stub.probeImageDimensions,
          ),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t1-webstub',
        Message.fromBlocks(
          id: 'img_web',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'img_web', localPath: pngFile.path),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      final recorder = _WindowRecorder(
        store.watchWindow(conversationId: 'conv-t1-webstub', limit: 20),
      );
      addTearDown(recorder.close);
      await recorder.waitForEventCount(1);
      await _drainMaintenance(store, 'conv-t1-webstub');

      expect(store.debugProbeCount, 1, reason: '桩被调用恰一次后 attempted 收敛');
      expect(spyBlocks.casCallCount, 0);
      expect(recorder.events.length, 1, reason: '桩失败轮不发通知');

      await store.loadCachedMessages('conv-t1-webstub');
      await _drainMaintenance(store, 'conv-t1-webstub');
      expect(store.debugProbeCount, 1);
    });
  });

  group('T2 peekWindow 纯读', () {
    test('调用前后维护入队与探测计数均不变', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 10, 0, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t2-peek', baseTime);

      final probe = _FakeProbe((_) async => _dims(9, 9));
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      final store = container.read(conversationTimelineCacheProvider);
      // 经 transient 路径安装含候选的快照（该路径不调度维护）。
      await store.replaceMessagesTransient(
        conversationId: 'conv-t2-peek',
        messages: <Message>[
          Message.fromBlocks(
            id: 'transient_img',
            role: 'assistant',
            blocks: <MessageBlock>[
              ImageBlock(
                messageId: 'transient_img',
                localPath: '/gone/transient.png',
              ),
            ],
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
          ),
        ],
      );
      expect(store.debugMaintenanceEnqueueCount, 0);

      for (var i = 0; i < 5; i += 1) {
        final window = store.peekWindow(
          conversationId: 'conv-t2-peek',
          limit: 20,
        );
        expect(window, isNotNull);
        expect(window!.messages, isNotEmpty);
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(store.debugMaintenanceEnqueueCount, 0, reason: 'peekWindow 纯读');
      expect(store.debugProbeCount, 0);
      expect(probe.callCount, 0);
    });
  });

  group('T3 热首值旁路与无丢通知', () {
    test('队列被占时首值仍及时产出；缓冲期变更（含 visibility）不丢失', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 10, 10, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t3-hot', baseTime);

      final gatedRepo = _GatedMessageRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          messageRepositoryProvider.overrideWithValue(gatedRepo),
          imageDimensionProbeProvider.overrideWithValue(_nullProbe().call),
        ],
      );
      addTearDown(container.dispose);

      for (var i = 1; i <= 25; i += 1) {
        await _persistMessage(
          container,
          'conv-t3-hot',
          Message(
            id: 'm$i',
            role: i.isOdd ? 'user' : 'assistant',
            content: 'message-$i',
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
          ),
        );
      }

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore(
        'conv-t3-hot',
        targetMessageCount: 20,
      );

      // 用真实内容任务占住会话串行队列。
      gatedRepo.gate = Completer<void>();
      gatedRepo.entered = Completer<void>();
      final olderFuture = store.loadOlderMessages(
        conversationId: 'conv-t3-hot',
        pageSize: 5,
      );
      await gatedRepo.entered!.future.timeout(const Duration(seconds: 10));

      final events = <ConversationTimelineWindowState>[];
      final firstEvent = Completer<void>();
      final secondEvent = Completer<void>();
      late final StreamSubscription<ConversationTimelineWindowState>
      subscription;
      subscription = store
          .watchWindow(conversationId: 'conv-t3-hot', limit: 50)
          .listen((window) {
            events.add(window);
            if (events.length == 1) {
              // 暂停消费：把生成器钉在首个 yield 上，制造
              // 「变更发生在首值与监听建立之间」的窗口。
              subscription.pause();
              firstEvent.complete();
            } else if (events.length == 2 && !secondEvent.isCompleted) {
              secondEvent.complete();
            }
          });
      addTearDown(subscription.cancel);

      await firstEvent.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('队列被占时热首值未旁路产出'),
      );
      expect(events.single.messages.length, 20);

      // 挂起期间发生 visibility 变更（排队在被占任务之后）。
      final hideFuture = store.hideMessages(
        conversationId: 'conv-t3-hot',
        rawMessageIds: const <String>['m25'],
      );

      gatedRepo.gate!.complete();
      expect(await olderFuture.timeout(const Duration(seconds: 10)), 5);
      await hideFuture.timeout(const Duration(seconds: 10));

      subscription.resume();
      await secondEvent.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('缓冲期完成的变更通知丢失'),
      );

      final updatedWindow = events[1];
      expect(
        updatedWindow.messages.map((message) => message.id),
        isNot(contains('m25')),
        reason: '挂起期间的 hideMessages 必须体现在恢复后的窗口里',
      );
      expect(updatedWindow.messages.length, 24, reason: '25 条减去 1 条隐藏');
    });
  });

  group('T4 来源身份与持久化矩阵', () {
    test('普通 DB 行：写回仅覆盖宽高、其余键原样；新实例装载后不再探测', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 10, 20, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t4-row', baseTime);

      final probe = _FakeProbe((_) async => _dims(7, 9));
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await container
          .read(messageRepositoryProvider)
          .upsert(
            MessageConverter.toCompanion(
              Message(
                id: 'row_raw',
                role: 'assistant',
                content: '',
                createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
              ),
              'conv-t4-row',
            ),
          );
      await database
          .into(database.messageBlocks)
          .insert(
            db.MessageBlocksCompanion.insert(
              id: 'row_custom',
              messageId: 'row_raw',
              type: 'image',
              data: jsonEncode(<String, dynamic>{
                'id': 'row_custom',
                'messageId': 'row_raw',
                'type': 'image',
                'status': 'success',
                'localPath': '/data/user/images/photo.png',
                'prompt': 'keep prompt',
                'customExtra': 'keep-me',
                'createdAt': '2026-07-01T00:00:00.000',
              }),
              createdAt: baseTime + 1,
            ),
          );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t4-row');
      await _drainMaintenance(store, 'conv-t4-row');

      expect(store.debugProbeCount, 1);
      final rowData = await _readSingleImageRowData(container, 'row_raw');
      expect(rowData['width'], 7);
      expect(rowData['height'], 9);
      expect(rowData['id'], 'row_custom');
      expect(rowData['localPath'], '/data/user/images/photo.png');
      expect(rowData['prompt'], 'keep prompt');
      expect(rowData['customExtra'], 'keep-me', reason: '未知键原样保留');
      expect(rowData['status'], 'success');
      expect(rowData['createdAt'], '2026-07-01T00:00:00.000');

      // 模拟重启：新缓存实例装载后不再探测。
      final probe2 = _FakeProbe((_) async => _dims(1, 1));
      final container2 = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe2.call)],
      );
      addTearDown(container2.dispose);
      final store2 = container2.read(conversationTimelineCacheProvider);
      await store2.reloadConversationFromRawStore('conv-t4-row');
      await _drainMaintenance(store2, 'conv-t4-row');
      expect(probe2.callCount, 0);
      final block =
          (await store2.loadCachedMessages('conv-t4-row')).single.blocks!.single
              as ImageBlock;
      expect(block.width, 7);
      expect(block.height, 9);
    });

    test('导入场景（行 id ≠ data.id）按来源指纹命中真相源行并写回', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 10, 25, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t4-import', baseTime);

      final probe = _FakeProbe((_) async => _dims(11, 13));
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await container
          .read(messageRepositoryProvider)
          .upsert(
            MessageConverter.toCompanion(
              Message(
                id: 'import_raw',
                role: 'assistant',
                content: '',
                createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
              ),
              'conv-t4-import',
            ),
          );
      await database
          .into(database.messageBlocks)
          .insert(
            db.MessageBlocksCompanion.insert(
              id: 'row_import_1',
              messageId: 'import_raw',
              type: 'image',
              data: jsonEncode(<String, dynamic>{
                'id': 'blk_orig_9',
                'messageId': 'import_raw',
                'type': 'image',
                'status': 'success',
                'localPath': '/imported/pic.png',
              }),
              createdAt: baseTime + 1,
            ),
          );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t4-import');
      await _drainMaintenance(store, 'conv-t4-import');

      final rowData = await _readSingleImageRowData(
        container,
        'import_raw',
        rowId: 'row_import_1',
      );
      expect(rowData['width'], 11, reason: '按来源匹配写回行 id 而非 data.id');
      expect(rowData['height'], 13);
      expect(rowData['id'], 'blk_orig_9');
    });

    test('投影合成块（无 DB 行）：跳过写回、内存生效、attempted 收敛', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 10, 30, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t4-synth', baseTime);

      final probe = _FakeProbe((_) async => _dims(5, 6));
      final spyBlocks = _SpyMessageBlockRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t4-synth',
        Message(
          id: 'synth_raw',
          role: 'assistant',
          content: 'text only raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t4-synth');
      await store.upsertMessage(
        conversationId: 'conv-t4-synth',
        message: _projectedImageMessage(
          id: 'proj_synth',
          sourceMessageId: 'synth_raw',
          localPath: '/payload/only.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );
      await _drainMaintenance(store, 'conv-t4-synth');

      expect(store.debugProbeCount, 1);
      expect(spyBlocks.casCallCount, 0, reason: '无真相源行时不做 DB 写回');
      final messages = await store.loadCachedMessages('conv-t4-synth');
      final block =
          messages
                  .firstWhere((message) => message.id == 'proj_synth')
                  .blocks!
                  .single
              as ImageBlock;
      expect(block.width, 5);
      expect(block.height, 6);

      await store.loadCachedMessages('conv-t4-synth');
      await _drainMaintenance(store, 'conv-t4-synth');
      expect(store.debugProbeCount, 1, reason: '内存生效后不再重复探测');
    });

    test('同 raw 消息、同长度、不同内容的 base64 互不污染（精确校验门）', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 10, 35, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t4-b64', baseTime);

      // 两个 payload 同长度，仅在采样窗口（前后 4096）之外的中段不同：
      // 采样指纹相同（sourceKey 碰撞），精确校验必须挡住污染。
      final payloadA = '${'A' * 4096}${'C' * 1000}${'B' * 4096}';
      final payloadB = '${'A' * 4096}${'D' * 1000}${'B' * 4096}';
      expect(payloadA.length, payloadB.length);

      final probe = _FakeProbe((_) async => _dims(3, 4));
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await container
          .read(messageRepositoryProvider)
          .upsert(
            MessageConverter.toCompanion(
              Message(
                id: 'b64_raw',
                role: 'assistant',
                content: '',
                createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
              ),
              'conv-t4-b64',
            ),
          );
      await database
          .into(database.messageBlocks)
          .insert(
            db.MessageBlocksCompanion.insert(
              id: 'row_b64_a',
              messageId: 'b64_raw',
              type: 'image',
              data: jsonEncode(<String, dynamic>{
                'id': 'row_b64_a',
                'messageId': 'b64_raw',
                'type': 'image',
                'status': 'success',
                'base64': payloadA,
              }),
              createdAt: baseTime + 1,
            ),
          );
      await database
          .into(database.messageBlocks)
          .insert(
            db.MessageBlocksCompanion.insert(
              id: 'row_b64_b',
              messageId: 'b64_raw',
              type: 'image',
              data: jsonEncode(<String, dynamic>{
                'id': 'row_b64_b',
                'messageId': 'b64_raw',
                'type': 'image',
                'status': 'success',
                'base64': payloadB,
              }),
              sortOrder: const Value(1),
              createdAt: baseTime + 1,
            ),
          );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t4-b64');
      await _drainMaintenance(store, 'conv-t4-b64');

      expect(store.debugProbeCount, 1, reason: '指纹碰撞按同一来源去重，只探测一次');
      expect(probe.inputs.single.base64, payloadA);

      final rowA = await _readSingleImageRowData(
        container,
        'b64_raw',
        rowId: 'row_b64_a',
      );
      final rowB = await _readSingleImageRowData(
        container,
        'b64_raw',
        rowId: 'row_b64_b',
      );
      expect(rowA['width'], 3);
      expect(rowA['height'], 4);
      expect(rowB.containsKey('width'), isFalse, reason: 'B 行不得被 A 尺寸污染');

      final blocks = (await store.loadCachedMessages(
        'conv-t4-b64',
      )).single.blocks!.whereType<ImageBlock>().toList();
      final blockA = blocks.firstWhere((block) => block.base64 == payloadA);
      final blockB = blocks.firstWhere((block) => block.base64 == payloadB);
      expect(blockA.width, 3);
      expect(blockB.width, isNull, reason: 'B 块不得被 A 尺寸污染');
    });

    test('localPath 与等价 file:// URI 同指纹：成功结果直接回放不再探测', () async {
      tempDir = await Directory.systemTemp.createTemp('timeline_probe_');
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 10, 40, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t4-fileurl', baseTime);

      final imagePath = '${tempDir!.path}/same source dir/pic.png';
      await Directory('${tempDir!.path}/same source dir').create();

      final probe = _FakeProbe((_) async => _dims(2, 3));
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t4-fileurl',
        Message(
          id: 'fileurl_raw',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t4-fileurl');
      await store.upsertMessage(
        conversationId: 'conv-t4-fileurl',
        message: _projectedImageMessage(
          id: 'proj_lp',
          sourceMessageId: 'fileurl_raw',
          localPath: imagePath,
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );
      await _drainMaintenance(store, 'conv-t4-fileurl');
      expect(store.debugProbeCount, 1);

      await store.upsertMessage(
        conversationId: 'conv-t4-fileurl',
        message: _projectedImageMessage(
          id: 'proj_fileurl',
          sourceMessageId: 'fileurl_raw',
          url: Uri.file(imagePath).toString(),
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
        ),
      );
      await _drainMaintenance(store, 'conv-t4-fileurl');

      expect(store.debugProbeCount, 1, reason: 'file:// 与 localPath 同指纹，回放即可');
      final messages = await store.loadCachedMessages('conv-t4-fileurl');
      final block =
          messages
                  .firstWhere((message) => message.id == 'proj_fileurl')
                  .blocks!
                  .single
              as ImageBlock;
      expect(block.width, 2);
      expect(block.height, 3);
    });

    test('同一 payload 换包装（data URL／裸 base64／空白差异）回放成功不丢宽高', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 10, 45, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t4-wrap', baseTime);

      final payload = base64Encode(
        img.encodePng(img.Image(width: 4, height: 6)),
      );
      final wrapped = 'data:image/png;base64,$payload';
      final buffer = StringBuffer();
      for (var i = 0; i < payload.length; i += 40) {
        buffer
          ..write(
            payload.substring(
              i,
              i + 40 > payload.length ? payload.length : i + 40,
            ),
          )
          ..write('\n');
      }
      final whitespaced = buffer.toString();

      final probe = _FakeProbe((_) async => _dims(4, 6));
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t4-wrap',
        Message(
          id: 'wrap_raw',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t4-wrap');
      await store.upsertMessage(
        conversationId: 'conv-t4-wrap',
        message: _projectedImageMessage(
          id: 'proj_wrap_raw64',
          sourceMessageId: 'wrap_raw',
          base64: payload,
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );
      await _drainMaintenance(store, 'conv-t4-wrap');
      expect(store.debugProbeCount, 1);

      await store.upsertMessages(
        conversationId: 'conv-t4-wrap',
        messages: <Message>[
          _projectedImageMessage(
            id: 'proj_wrap_dataurl',
            sourceMessageId: 'wrap_raw',
            base64: wrapped,
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
          ),
          _projectedImageMessage(
            id: 'proj_wrap_ws',
            sourceMessageId: 'wrap_raw',
            base64: whitespaced,
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 4),
          ),
        ],
      );
      await _drainMaintenance(store, 'conv-t4-wrap');

      expect(store.debugProbeCount, 1, reason: '包装差异不影响 sourceKey 与精确门');
      final messages = await store.loadCachedMessages('conv-t4-wrap');
      final dataUrlBlock =
          messages
                  .firstWhere((message) => message.id == 'proj_wrap_dataurl')
                  .blocks!
                  .single
              as ImageBlock;
      final whitespacedBlock =
          messages
                  .firstWhere((message) => message.id == 'proj_wrap_ws')
                  .blocks!
                  .single
              as ImageBlock;
      expect(dataUrlBlock.width, 4);
      expect(dataUrlBlock.height, 6);
      expect(whitespacedBlock.width, 4);
      expect(whitespacedBlock.height, 6);
    });
  });

  group('T5 内容路径调度', () {
    test('upsert/replace/loadOlder/reload 各实际入队一次，transient 不入队', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 11, 0, 0).millisecondsSinceEpoch;
      for (final conversationId in <String>[
        'conv-t5-upsert',
        'conv-t5-replace',
        'conv-t5-older',
        'conv-t5-reload',
        'conv-t5-transient',
      ]) {
        await _insertConversation(database, conversationId, baseTime);
      }

      final probe = _nullProbe();
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);
      final store = container.read(conversationTimelineCacheProvider);

      // upsertMessages
      await _persistMessage(
        container,
        'conv-t5-upsert',
        Message(
          id: 'up_raw',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );
      await store.reloadConversationFromRawStore('conv-t5-upsert');
      expect(store.debugMaintenanceEnqueueCount, 0);
      await store.upsertMessages(
        conversationId: 'conv-t5-upsert',
        messages: <Message>[
          _projectedImageMessage(
            id: 'up_proj',
            sourceMessageId: 'up_raw',
            localPath: '/gone/up.png',
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
          ),
        ],
      );
      expect(store.debugMaintenanceEnqueueCount, 1);
      await _drainMaintenance(store, 'conv-t5-upsert');

      // replaceMessages（持久路径）
      await _persistMessage(
        container,
        'conv-t5-replace',
        Message(
          id: 'rep_raw',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );
      await store.reloadConversationFromRawStore('conv-t5-replace');
      final enqueueBeforeReplace = store.debugMaintenanceEnqueueCount;
      await store.replaceMessages(
        conversationId: 'conv-t5-replace',
        messages: <Message>[
          _projectedImageMessage(
            id: 'rep_proj',
            sourceMessageId: 'rep_raw',
            localPath: '/gone/rep.png',
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
          ),
        ],
      );
      expect(store.debugMaintenanceEnqueueCount, enqueueBeforeReplace + 1);
      await _drainMaintenance(store, 'conv-t5-replace');

      // loadOlderMessages：候选只存在于更早分页里
      await _persistMessage(
        container,
        'conv-t5-older',
        Message.fromBlocks(
          id: 'old_img',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'old_img', localPath: '/gone/old.png'),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime),
        ),
      );
      for (var i = 1; i <= 20; i += 1) {
        await _persistMessage(
          container,
          'conv-t5-older',
          Message(
            id: 'older_seed_$i',
            role: i.isOdd ? 'user' : 'assistant',
            content: 'seed-$i',
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
          ),
        );
      }
      await store.reloadConversationFromRawStore(
        'conv-t5-older',
        targetMessageCount: 20,
      );
      final enqueueBeforeOlder = store.debugMaintenanceEnqueueCount;
      await store.loadOlderMessages(
        conversationId: 'conv-t5-older',
        pageSize: 5,
      );
      expect(store.debugMaintenanceEnqueueCount, enqueueBeforeOlder + 1);
      await _drainMaintenance(store, 'conv-t5-older');

      // reloadConversationFromRawStore
      await _persistMessage(
        container,
        'conv-t5-reload',
        Message.fromBlocks(
          id: 'reload_img',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'reload_img', localPath: '/gone/reload.png'),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );
      final enqueueBeforeReload = store.debugMaintenanceEnqueueCount;
      await store.reloadConversationFromRawStore('conv-t5-reload');
      expect(store.debugMaintenanceEnqueueCount, enqueueBeforeReload + 1);
      await _drainMaintenance(store, 'conv-t5-reload');

      // transient 不入队
      final enqueueBeforeTransient = store.debugMaintenanceEnqueueCount;
      await store.replaceMessagesTransient(
        conversationId: 'conv-t5-transient',
        messages: <Message>[
          Message.fromBlocks(
            id: 'transient_img_t5',
            role: 'assistant',
            blocks: <MessageBlock>[
              ImageBlock(
                messageId: 'transient_img_t5',
                localPath: '/gone/transient.png',
              ),
            ],
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
          ),
        ],
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(store.debugMaintenanceEnqueueCount, enqueueBeforeTransient);
    });

    test('内容 API 不 await 探测：探测挂起时内容调用照常完成', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 11, 5, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t5-hang', baseTime);

      final probeGate = Completer<ImageDimensions?>();
      final probe = _FakeProbe((_) => probeGate.future);
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t5-hang',
        Message(
          id: 'hang_raw',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t5-hang');

      final upsertFuture = store.upsertMessages(
        conversationId: 'conv-t5-hang',
        messages: <Message>[
          _projectedImageMessage(
            id: 'hang_proj',
            sourceMessageId: 'hang_raw',
            localPath: '/gone/hang.png',
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
          ),
        ],
      );
      await upsertFuture.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('内容 API 不得 await 探测'),
      );
      await probe.signalAtCall(1).future.timeout(const Duration(seconds: 5));

      probeGate.complete(null);
      await _drainMaintenance(store, 'conv-t5-hang');
    });
  });

  group('T6 CAS 竞态', () {
    test('探测期间行被外部替换（A→B）：stale 丢弃、不污染新快照、无多余通知', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 11, 10, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t6-cas', baseTime);

      final probeGate = Completer<ImageDimensions?>();
      final probe = _FakeProbe((_) async => null);
      probe.handler = (_) {
        probe.handler = (_) async => null;
        return probeGate.future;
      };
      final spyBlocks = _SpyMessageBlockRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t6-cas',
        Message.fromBlocks(
          id: 'cas_raw',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'cas_raw', localPath: '/source/a.png'),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t6-cas');

      final recorder = _WindowRecorder(
        store.watchWindow(conversationId: 'conv-t6-cas', limit: 20),
      );
      addTearDown(recorder.close);
      await recorder.waitForEventCount(1);

      // 维护轮进入探测挂起。
      await probe.signalAtCall(1).future.timeout(const Duration(seconds: 10));

      // 外部写路径：同 id 换图（A→B），并排队 cache 层 reload。
      final rowId = (await spyBlocks.getByMessage('cas_raw')).single.id;
      await spyBlocks.update(
        rowId,
        db.MessageBlocksCompanion(
          data: Value(
            jsonEncode(<String, dynamic>{
              'id': rowId,
              'messageId': 'cas_raw',
              'type': 'image',
              'status': 'success',
              'localPath': '/source/b.png',
            }),
          ),
        ),
      );
      final reloadFuture = store.reloadConversationFromRawStore('conv-t6-cas');

      probeGate.complete(_dims(10, 20));
      await reloadFuture.timeout(const Duration(seconds: 10));
      await _drainMaintenance(store, 'conv-t6-cas');

      expect(store.debugStaleWriteBackSkipCount, 1);
      final rowData = await _readSingleImageRowData(container, 'cas_raw');
      expect(rowData['localPath'], '/source/b.png');
      expect(rowData.containsKey('width'), isFalse, reason: '旧尺寸不得写入新图');

      final cachedBlock =
          (await store.loadCachedMessages('conv-t6-cas')).single.blocks!.single
              as ImageBlock;
      expect(cachedBlock.localPath, '/source/b.png');
      expect(cachedBlock.width, isNull, reason: 'reload 安装的新快照未被旧结果覆盖');

      expect(recorder.events.length, 2, reason: '仅 reload 通知一次；stale 维护轮不通知');

      // 终审 N3：全部 stale 后状态表不得留有该来源尺寸——
      // 重新引入 A 来源块：attempted 命中不重探测，且不回放出宽高。
      final probeCountBefore = store.debugProbeCount;
      await store.upsertMessage(
        conversationId: 'conv-t6-cas',
        message: _projectedImageMessage(
          id: 'proj_a_again',
          sourceMessageId: 'cas_raw',
          localPath: '/source/a.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 5),
        ),
      );
      await _drainMaintenance(store, 'conv-t6-cas');
      expect(store.debugProbeCount, probeCountBefore);
      final reintroducedBlock =
          (await store.loadCachedMessages('conv-t6-cas'))
                  .firstWhere((message) => message.id == 'proj_a_again')
                  .blocks!
                  .single
              as ImageBlock;
      expect(reintroducedBlock.width, isNull, reason: '状态表无该来源尺寸');
    });

    test('软删除行不写回', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 11, 15, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t6-softdel', baseTime);

      final probeGate = Completer<ImageDimensions?>();
      final probe = _FakeProbe((_) async => null);
      probe.handler = (_) {
        probe.handler = (_) async => null;
        return probeGate.future;
      };
      final spyBlocks = _SpyMessageBlockRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t6-softdel',
        Message.fromBlocks(
          id: 'softdel_raw',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'softdel_raw', localPath: '/source/s.png'),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t6-softdel');
      await probe.signalAtCall(1).future.timeout(const Duration(seconds: 10));

      // 探测期间行被软删除。
      final rows = await database.select(database.messageBlocks).get();
      final rowId = rows.firstWhere((row) => row.messageId == 'softdel_raw').id;
      await spyBlocks.softDelete(rowId, baseTime + 100);

      final originalData = rows
          .firstWhere((row) => row.messageId == 'softdel_raw')
          .data;

      probeGate.complete(_dims(6, 6));
      await _drainMaintenance(store, 'conv-t6-softdel');

      expect(store.debugStaleWriteBackSkipCount, 1, reason: '软删除行 CAS 受 0 行影响');
      final deletedRow = (await database.select(database.messageBlocks).get())
          .firstWhere((row) => row.id == rowId);
      expect(deletedRow.data, originalData, reason: '软删除行内容不被写回');
      expect(deletedRow.deletedAt, baseTime + 100);
    });

    test('两行同来源、第二行 CAS 抛错：第一行保留、任务无未处理异常', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 11, 20, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t6-tworows', baseTime);

      final probe = _FakeProbe((_) async => _dims(8, 9));
      final spyBlocks = _SpyMessageBlockRepository(database)
        ..throwOnCas = (rowId) =>
            rowId == 'dup_row_2' ? StateError('cas boom') : null;
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(messageRepositoryProvider)
          .upsert(
            MessageConverter.toCompanion(
              Message(
                id: 'dup_raw',
                role: 'assistant',
                content: '',
                createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
              ),
              'conv-t6-tworows',
            ),
          );
      for (final (index, rowId) in <String>['dup_row_1', 'dup_row_2'].indexed) {
        await database
            .into(database.messageBlocks)
            .insert(
              db.MessageBlocksCompanion.insert(
                id: rowId,
                messageId: 'dup_raw',
                type: 'image',
                data: jsonEncode(<String, dynamic>{
                  'id': rowId,
                  'messageId': 'dup_raw',
                  'type': 'image',
                  'status': 'success',
                  'localPath': '/source/dup.png',
                }),
                sortOrder: Value(index),
                createdAt: baseTime + 1,
              ),
            );
      }

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t6-tworows');
      await _drainMaintenance(store, 'conv-t6-tworows');

      expect(
        spyBlocks.casRowIds,
        containsAll(<String>['dup_row_1', 'dup_row_2']),
      );
      final row1 = await _readSingleImageRowData(
        container,
        'dup_raw',
        rowId: 'dup_row_1',
      );
      final row2 = await _readSingleImageRowData(
        container,
        'dup_raw',
        rowId: 'dup_row_2',
      );
      expect(row1['width'], 8, reason: '单块写回失败不影响其余块');
      expect(row2.containsKey('width'), isFalse);

      final blocks = (await store.loadCachedMessages(
        'conv-t6-tworows',
      )).single.blocks!.whereType<ImageBlock>().toList();
      for (final block in blocks) {
        expect(block.width, 8, reason: '≥1 行成功即内存提交');
        expect(block.height, 9);
      }
    });
  });

  group('T7 映射语义', () {
    test('几何维护轮前后投影映射仓储零调用', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 11, 30, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t7-map', baseTime);

      var probeCallIndex = 0;
      final probe = _FakeProbe((_) async {
        probeCallIndex += 1;
        return probeCallIndex == 1 ? _dims(2, 2) : null;
      });
      final spyMapping = _SpyMappingRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageProjectionMappingRepositoryProvider.overrideWithValue(
            spyMapping,
          ),
        ],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t7-map',
        Message(
          id: 'map_raw',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t7-map');
      // reload 全量同步：map_raw 一次。
      final writesAfterReload = spyMapping.writeCallCount;
      expect(writesAfterReload, 1);

      // 成功维护轮：不得新增映射写。
      await store.upsertMessage(
        conversationId: 'conv-t7-map',
        message: _projectedImageMessage(
          id: 'map_proj_ok',
          sourceMessageId: 'map_raw',
          localPath: '/gone/map-ok.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );
      final writesAfterUpsert1 = spyMapping.writeCallCount;
      expect(
        writesAfterUpsert1,
        writesAfterReload + 1,
        reason: 'upsert 自身同步一次',
      );
      await _drainMaintenance(store, 'conv-t7-map');
      expect(store.debugProbeCount, 1);
      expect(
        spyMapping.writeCallCount,
        writesAfterUpsert1,
        reason: '成功维护轮零映射调用',
      );

      // 失败维护轮：同样零调用。
      await store.upsertMessage(
        conversationId: 'conv-t7-map',
        message: _projectedImageMessage(
          id: 'map_proj_fail',
          sourceMessageId: 'map_raw',
          localPath: '/gone/map-fail.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
        ),
      );
      final writesAfterUpsert2 = spyMapping.writeCallCount;
      expect(writesAfterUpsert2, writesAfterUpsert1 + 1);
      await _drainMaintenance(store, 'conv-t7-map');
      expect(store.debugProbeCount, 2);
      expect(
        spyMapping.writeCallCount,
        writesAfterUpsert2,
        reason: '失败维护轮零映射调用',
      );
    });
  });

  group('T8 批次接力', () {
    test('超过单轮上限（4）的候选经尾处理接力，内容任务先于下一维护批次', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 11, 40, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t8-relay', baseTime);

      final gate1 = Completer<ImageDimensions?>();
      final gate5 = Completer<ImageDimensions?>();
      final probe = _FakeProbe((_) async => null);
      probe.handler = (input) {
        final callNumber = probe.callCount;
        if (callNumber == 1) {
          return gate1.future;
        }
        if (callNumber == 5) {
          return gate5.future;
        }
        return Future<ImageDimensions?>.value(null);
      };
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      for (var i = 1; i <= 5; i += 1) {
        await _persistMessage(
          container,
          'conv-t8-relay',
          Message.fromBlocks(
            id: 'relay_$i',
            role: 'assistant',
            blocks: <MessageBlock>[
              ImageBlock(
                messageId: 'relay_$i',
                localPath: '/gone/relay_$i.png',
              ),
            ],
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
          ),
        );
      }

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t8-relay');
      await probe.signalAtCall(1).future.timeout(const Duration(seconds: 10));

      // 第一批仍在执行时排入内容任务。
      final contentFuture = store.upsertMessages(
        conversationId: 'conv-t8-relay',
        messages: <Message>[
          Message.text(
            id: 'content_marker',
            role: 'user',
            content: 'queued during round 1',
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 100),
          ),
        ],
      );

      gate1.complete(null);
      // 内容任务必须先于下一维护批次执行：若第 5 个探测先启动，
      // 内容任务会被 gate5 卡死导致超时失败。
      await contentFuture.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('接力批次先于内容任务执行了'),
      );
      await probe.signalAtCall(5).future.timeout(const Duration(seconds: 10));
      gate5.complete(null);
      await _drainMaintenance(store, 'conv-t8-relay');

      expect(store.debugProbeCount, 5, reason: '第 5 个候选经接力最终被探测');
      expect(probe.inputs.map((input) => input.localPath).toSet(), <String>{
        for (var i = 1; i <= 5; i += 1) '/gone/relay_$i.png',
      });
      expect(
        store.debugMaintenanceEnqueueCount,
        greaterThanOrEqualTo(2),
        reason: '接力通过重新入队实现',
      );
    });

    test('部分成功批次同样接力处理剩余候选', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 11, 45, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t8-partial', baseTime);

      final probe = _FakeProbe((input) async {
        return input.localPath == '/gone/pr_1.png' ? _dims(1, 2) : null;
      });
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      for (var i = 1; i <= 5; i += 1) {
        await _persistMessage(
          container,
          'conv-t8-partial',
          Message.fromBlocks(
            id: 'pr_$i',
            role: 'assistant',
            blocks: <MessageBlock>[
              ImageBlock(messageId: 'pr_$i', localPath: '/gone/pr_$i.png'),
            ],
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
          ),
        );
      }

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t8-partial');
      await _drainMaintenance(store, 'conv-t8-partial');

      expect(store.debugProbeCount, 5);
      final messages = await store.loadCachedMessages('conv-t8-partial');
      final okBlock =
          messages.firstWhere((message) => message.id == 'pr_1').blocks!.single
              as ImageBlock;
      expect(okBlock.width, 1);
      expect(okBlock.height, 2);
    });
  });

  group('T9 状态表回放', () {
    test('无 DB 行来源探测成功后，同生命周期重投影直接带宽高不再探测', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 12, 0, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t9-replay', baseTime);

      final probe = _FakeProbe((_) async => _dims(9, 9));
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t9-replay',
        Message(
          id: 'r9',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t9-replay');
      await store.upsertMessage(
        conversationId: 'conv-t9-replay',
        message: _projectedImageMessage(
          id: 'proj_r9_a',
          sourceMessageId: 'r9',
          localPath: '/gone/nine.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );
      await _drainMaintenance(store, 'conv-t9-replay');
      expect(store.debugProbeCount, 1);

      await store.upsertMessage(
        conversationId: 'conv-t9-replay',
        message: _projectedImageMessage(
          id: 'proj_r9_b',
          sourceMessageId: 'r9',
          localPath: '/gone/nine.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
        ),
      );
      await _drainMaintenance(store, 'conv-t9-replay');

      expect(store.debugProbeCount, 1, reason: '回放命中，无需再探测');
      final block =
          (await store.loadCachedMessages('conv-t9-replay'))
                  .firstWhere((message) => message.id == 'proj_r9_b')
                  .blocks!
                  .single
              as ImageBlock;
      expect(block.width, 9);
      expect(block.height, 9);
    });

    test('DB 写回抛异常（内存降级）后 reload 重投影同样回放不丢宽高', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 12, 5, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t9-dbfail', baseTime);

      final probe = _FakeProbe((_) async => _dims(4, 4));
      final spyBlocks = _SpyMessageBlockRepository(database)
        ..throwOnCas = (_) => StateError('db write boom');
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t9-dbfail',
        Message.fromBlocks(
          id: 'r9db',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'r9db', localPath: '/source/nine-db.png'),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t9-dbfail');
      await _drainMaintenance(store, 'conv-t9-dbfail');

      expect(store.debugProbeCount, 1);
      final rowData = await _readSingleImageRowData(container, 'r9db');
      expect(rowData['width'], isNull, reason: 'DB 写回失败');
      var block =
          (await store.loadCachedMessages(
                'conv-t9-dbfail',
              )).single.blocks!.single
              as ImageBlock;
      expect(block.width, 4, reason: '内存降级生效');

      // reload 重投影：DB 行仍无尺寸，但状态表回放补齐，不再探测。
      await store.reloadConversationFromRawStore('conv-t9-dbfail');
      await _drainMaintenance(store, 'conv-t9-dbfail');
      expect(store.debugProbeCount, 1);
      block =
          (await store.loadCachedMessages(
                'conv-t9-dbfail',
              )).single.blocks!.single
              as ImageBlock;
      expect(block.width, 4, reason: '不出现「不再探测且宽高丢失」');
      expect(block.height, 4);
    });

    test('超容量逐出：attempted 与尺寸同进同出，被逐出来源允许重新探测', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 12, 10, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t9-evict', baseTime);

      final probe = _FakeProbe((input) async {
        if (input.localPath == '/gone/a9.png') return _dims(1, 1);
        if (input.localPath == '/gone/b9.png') return _dims(2, 2);
        return null;
      });
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t9-evict',
        Message(
          id: 'r9c',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider)
        ..sourceProbeStateCapacityPerConversation = 1;
      await store.reloadConversationFromRawStore('conv-t9-evict');

      await store.upsertMessage(
        conversationId: 'conv-t9-evict',
        message: _projectedImageMessage(
          id: 'proj_a9',
          sourceMessageId: 'r9c',
          localPath: '/gone/a9.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );
      await _drainMaintenance(store, 'conv-t9-evict');
      expect(store.debugProbeCount, 1);

      // B 入表 → A（attempted＋尺寸）整体被逐出。
      await store.upsertMessage(
        conversationId: 'conv-t9-evict',
        message: _projectedImageMessage(
          id: 'proj_b9',
          sourceMessageId: 'r9c',
          localPath: '/gone/b9.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
        ),
      );
      await _drainMaintenance(store, 'conv-t9-evict');
      expect(store.debugProbeCount, 2);

      // A 来源重新出现：允许重新探测一次，最终仍拿到宽高。
      await store.upsertMessage(
        conversationId: 'conv-t9-evict',
        message: _projectedImageMessage(
          id: 'proj_a9_again',
          sourceMessageId: 'r9c',
          localPath: '/gone/a9.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 4),
        ),
      );
      await _drainMaintenance(store, 'conv-t9-evict');

      expect(store.debugProbeCount, 3, reason: '被逐出来源重新成为候选');
      expect(probe.inputs.map((input) => input.localPath).toList(), <String>[
        '/gone/a9.png',
        '/gone/b9.png',
        '/gone/a9.png',
      ]);
      final messages = await store.loadCachedMessages('conv-t9-evict');
      final blockA =
          messages
                  .firstWhere((message) => message.id == 'proj_a9_again')
                  .blocks!
                  .single
              as ImageBlock;
      final blockB =
          messages
                  .firstWhere((message) => message.id == 'proj_b9')
                  .blocks!
                  .single
              as ImageBlock;
      expect(blockA.width, 1, reason: '重新探测后不丢宽高');
      expect(blockB.width, 2, reason: '已应用到快照的尺寸不受逐出影响');
    });
  });

  group('T10 在途失效', () {
    test('探测在途时 clearConversation：不写 DB、不安装、不通知、不重排队，attempted 一并清理', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 12, 20, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t10-clear', baseTime);

      final probeGate = Completer<ImageDimensions?>();
      final probe = _FakeProbe((_) async => null);
      probe.handler = (_) {
        probe.handler = (_) async => null;
        return probeGate.future;
      };
      final spyBlocks = _SpyMessageBlockRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t10-clear',
        Message.fromBlocks(
          id: 'inv_raw',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'inv_raw', localPath: '/source/inv.png'),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t10-clear');
      final recorder = _WindowRecorder(
        store.watchWindow(conversationId: 'conv-t10-clear', limit: 20),
      );
      addTearDown(recorder.close);
      await recorder.waitForEventCount(1);
      await probe.signalAtCall(1).future.timeout(const Duration(seconds: 10));
      expect(store.debugMaintenanceEnqueueCount, 1);

      final clearFuture = store.clearConversation('conv-t10-clear');
      probeGate.complete(_dims(6, 6));
      await clearFuture.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(spyBlocks.casCallCount, 0, reason: '失效任务不写 DB');
      final rowData = await _readSingleImageRowData(container, 'inv_raw');
      expect(rowData['width'], isNull);
      expect(await store.loadCachedMessages('conv-t10-clear'), isEmpty);
      expect(recorder.events.length, 2, reason: '仅 clear 自身通知一次，失效维护轮静默');
      expect(store.debugMaintenanceEnqueueCount, 1, reason: '失效后不重排队');

      // clear 清理了状态表：同来源重新引入允许再次探测。
      await store.upsertMessage(
        conversationId: 'conv-t10-clear',
        message: _projectedImageMessage(
          id: 'proj_after_clear',
          sourceMessageId: 'inv_raw',
          localPath: '/source/inv.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 5),
        ),
      );
      await _drainMaintenance(store, 'conv-t10-clear');
      expect(store.debugProbeCount, 2, reason: 'attempted 已随 clear 清理');
    });

    test('探测在途时 dispose：释放后不写 DB、无未处理异常', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 12, 25, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-t10-dispose', baseTime);

      final probeGate = Completer<ImageDimensions?>();
      final probe = _FakeProbe((_) => probeGate.future);
      final spyBlocks = _SpyMessageBlockRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-t10-dispose',
        Message.fromBlocks(
          id: 'disp_raw',
          role: 'assistant',
          blocks: <MessageBlock>[
            ImageBlock(messageId: 'disp_raw', localPath: '/source/disp.png'),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-t10-dispose');
      await probe.signalAtCall(1).future.timeout(const Duration(seconds: 10));
      expect(store.debugMaintenanceEnqueueCount, 1);

      store.dispose();
      probeGate.complete(_dims(7, 7));
      for (var i = 0; i < 5; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(spyBlocks.casCallCount, 0);
      final rowData = await _readSingleImageRowData(container, 'disp_raw');
      expect(rowData['width'], isNull);
      expect(store.debugMaintenanceEnqueueCount, 1, reason: 'dispose 后不重排队');
    });
  });

  group('代码终审修复回归', () {
    test('B1: 维护任务已入队未启动时 clearConversation 使其整体失效'
        '（零探测/零写/零安装/零通知/零重排队）', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 13, 0, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-b1-queued', baseTime);

      final gate1 = Completer<ImageDimensions?>();
      late final _FakeProbe probe;
      probe = _FakeProbe((input) {
        final callNumber = probe.callCount;
        if (callNumber == 1) {
          return gate1.future;
        }
        if (callNumber <= 4) {
          return Future<ImageDimensions?>.value(null);
        }
        // 第 5 次探测不应发生：返回可见尺寸让违规立即暴露。
        return Future<ImageDimensions?>.value(_dims(99, 99));
      });
      final gatedRepo = _GatedMessageRepository(database);
      final spyBlocks = _SpyMessageBlockRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageRepositoryProvider.overrideWithValue(gatedRepo),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      for (var i = 1; i <= 20; i += 1) {
        await _persistMessage(
          container,
          'conv-b1-queued',
          Message(
            id: 'm$i',
            role: i.isOdd ? 'user' : 'assistant',
            content: 'message-$i',
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
          ),
        );
      }
      for (var i = 1; i <= 5; i += 1) {
        await _persistMessage(
          container,
          'conv-b1-queued',
          Message.fromBlocks(
            id: 'b$i',
            role: 'assistant',
            blocks: <MessageBlock>[
              ImageBlock(messageId: 'b$i', localPath: '/gone/b1_$i.png'),
            ],
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 20 + i),
          ),
        );
      }

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore(
        'conv-b1-queued',
        targetMessageCount: 20,
      );
      final recorder = _WindowRecorder(
        store.watchWindow(conversationId: 'conv-b1-queued', limit: 50),
      );
      addTearDown(recorder.close);
      await recorder.waitForEventCount(1);

      // 第一批维护挂在探测 1 上。
      await probe.signalAtCall(1).future.timeout(const Duration(seconds: 10));

      // 用真实内容任务占住队列：尾处理接力的第二批维护将排在它之后。
      gatedRepo.gate = Completer<void>();
      gatedRepo.entered = Completer<void>();
      final olderFuture = store.loadOlderMessages(
        conversationId: 'conv-b1-queued',
        pageSize: 5,
      );

      // 放行探测 1 → 第一批（1-4 全 null）结束 → 尾处理把第二批入队到
      // 被占内容任务之后：此刻第二批「已入队、未启动」。
      gate1.complete(null);
      await gatedRepo.entered!.future.timeout(const Duration(seconds: 10));
      for (
        var i = 0;
        i < 50 && store.debugMaintenanceEnqueueCount < 2;
        i += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(store.debugMaintenanceEnqueueCount, 2, reason: '第二批已入队');
      expect(store.debugProbeCount, 4);

      // 入队之后、启动之前 clear（epoch 递增）。
      final clearFuture = store.clearConversation('conv-b1-queued');
      gatedRepo.gate!.complete();
      expect(await olderFuture.timeout(const Duration(seconds: 10)), 5);
      await clearFuture.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(store.debugProbeCount, 4, reason: 'B1：epoch 固定于入队时刻，已失效批次零探测');
      expect(spyBlocks.casCallCount, 0, reason: '零 DB 写');
      expect(store.debugMaintenanceEnqueueCount, 2, reason: '零重排队');
      expect(
        await store.loadCachedMessages('conv-b1-queued'),
        isEmpty,
        reason: '零安装：clear 结果未被失效批次覆盖',
      );
      expect(
        recorder.events.length,
        3,
        reason: '首值＋loadOlder＋clear 各一次；失效批次零通知',
      );
      final rowData = await _readSingleImageRowData(container, 'b5');
      expect(rowData['width'], isNull);
    });

    test('B2: 活跃失败来源超过状态表容量仍有界收敛（软上限不逐出活跃源）', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 13, 10, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-b2-active', baseTime);

      final probe = _nullProbe();
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      for (var i = 1; i <= 5; i += 1) {
        await _persistMessage(
          container,
          'conv-b2-active',
          Message.fromBlocks(
            id: 'act_$i',
            role: 'assistant',
            blocks: <MessageBlock>[
              ImageBlock(messageId: 'act_$i', localPath: '/gone/act_$i.png'),
            ],
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
          ),
        );
      }

      final store = container.read(conversationTimelineCacheProvider)
        ..sourceProbeStateCapacityPerConversation = 2;
      await store.reloadConversationFromRawStore('conv-b2-active');
      // 旧实现会因「逐出活跃失败源 → 重新成为候选 → 永久接力」在此不收敛。
      await _drainMaintenance(store, 'conv-b2-active');

      expect(store.debugProbeCount, 5, reason: '每个失败来源恰好探测一次：软上限保护活跃源不被逐出');
      expect(
        store.debugMaintenanceEnqueueCount,
        2,
        reason: '第一批 4＋接力批 1，之后维护入队稳定',
      );

      await store.loadCachedMessages('conv-b2-active');
      await _drainMaintenance(store, 'conv-b2-active');
      expect(store.debugProbeCount, 5);
      expect(store.debugMaintenanceEnqueueCount, 2);
    });

    test('B3: 探测期间仅变更非来源字段（prompt/customExtra）——'
        '来源不变则以新原文重试 CAS 并最终写回', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 13, 20, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-b3-meta', baseTime);

      final probeGate = Completer<ImageDimensions?>();
      final probe = _FakeProbe((_) async => null);
      probe.handler = (_) {
        probe.handler = (_) async => null;
        return probeGate.future;
      };
      final spyBlocks = _SpyMessageBlockRepository(database);
      final container = _createTimelineContainer(
        database,
        overrides: [
          imageDimensionProbeProvider.overrideWithValue(probe.call),
          messageBlockRepositoryProvider.overrideWithValue(spyBlocks),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(messageRepositoryProvider)
          .upsert(
            MessageConverter.toCompanion(
              Message(
                id: 'meta_raw',
                role: 'assistant',
                content: '',
                createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
              ),
              'conv-b3-meta',
            ),
          );
      await database
          .into(database.messageBlocks)
          .insert(
            db.MessageBlocksCompanion.insert(
              id: 'meta_row',
              messageId: 'meta_raw',
              type: 'image',
              data: jsonEncode(<String, dynamic>{
                'id': 'meta_row',
                'messageId': 'meta_raw',
                'type': 'image',
                'status': 'success',
                'localPath': '/source/meta.png',
                'prompt': 'old prompt',
              }),
              createdAt: baseTime + 1,
            ),
          );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-b3-meta');
      final recorder = _WindowRecorder(
        store.watchWindow(conversationId: 'conv-b3-meta', limit: 20),
      );
      addTearDown(recorder.close);
      await recorder.waitForEventCount(1);
      await probe.signalAtCall(1).future.timeout(const Duration(seconds: 10));

      // 外部路径只改非来源字段：prompt 更新＋新增 customExtra，localPath 不变。
      await spyBlocks.update(
        'meta_row',
        db.MessageBlocksCompanion(
          data: Value(
            jsonEncode(<String, dynamic>{
              'id': 'meta_row',
              'messageId': 'meta_raw',
              'type': 'image',
              'status': 'success',
              'localPath': '/source/meta.png',
              'prompt': 'new prompt',
              'customExtra': 'added-later',
            }),
          ),
        ),
      );

      probeGate.complete(_dims(12, 34));
      await _drainMaintenance(store, 'conv-b3-meta');

      expect(store.debugStaleWriteBackSkipCount, 1, reason: '首次 CAS stale');
      expect(spyBlocks.casCallCount, 2, reason: '来源未变：本轮内以新原文恰好重试一次');
      final rowData = await _readSingleImageRowData(container, 'meta_raw');
      expect(rowData['width'], 12, reason: 'B3：metadata-only stale 最终写回宽高');
      expect(rowData['height'], 34);
      expect(rowData['prompt'], 'new prompt', reason: '并发写入的新字段原样保留');
      expect(rowData['customExtra'], 'added-later');
      final block =
          (await store.loadCachedMessages('conv-b3-meta')).single.blocks!.single
              as ImageBlock;
      expect(block.width, 12);
      expect(block.height, 34);
      expect(recorder.events.length, 2, reason: '成功维护轮恰一次通知');
      expect(store.debugProbeCount, 1);

      await store.loadCachedMessages('conv-b3-meta');
      await _drainMaintenance(store, 'conv-b3-meta');
      expect(store.debugProbeCount, 1, reason: '写回成功后保持收敛');
    });

    test('B4: 大 base64 身份走流式路径——零全量规范化拷贝、'
        '包装等价回放、采样窗外差异不污染', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 13, 30, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-b4-stream', baseTime);

      // 长度 20000 > 采样窗 8192；Q 仅在采样窗之外的中段（下标 10000）不同。
      final payloadUnits = List<int>.generate(20000, (i) => 65 + (i % 26));
      final payloadP = String.fromCharCodes(payloadUnits);
      final changedUnits = List<int>.of(payloadUnits)..[10000] = 0x30;
      final payloadQ = String.fromCharCodes(changedUnits);
      expect(payloadP.length, payloadQ.length);
      expect(payloadP == payloadQ, isFalse);
      final dataUrlP = 'data:image/png;base64,$payloadP';
      final whitespaceBuffer = StringBuffer();
      for (var i = 0; i < payloadP.length; i += 76) {
        whitespaceBuffer
          ..write(
            payloadP.substring(
              i,
              i + 76 > payloadP.length ? payloadP.length : i + 76,
            ),
          )
          ..write('\n');
      }
      final whitespacedP = whitespaceBuffer.toString();

      final probe = _FakeProbe((_) async => _dims(5, 5));
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-b4-stream',
        Message(
          id: 'b4_raw',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-b4-stream');

      await store.upsertMessage(
        conversationId: 'conv-b4-stream',
        message: _projectedImageMessage(
          id: 'b4_p',
          sourceMessageId: 'b4_raw',
          base64: payloadP,
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );
      await _drainMaintenance(store, 'conv-b4-stream');
      expect(store.debugProbeCount, 1);

      await store.upsertMessages(
        conversationId: 'conv-b4-stream',
        messages: <Message>[
          _projectedImageMessage(
            id: 'b4_data',
            sourceMessageId: 'b4_raw',
            base64: dataUrlP,
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
          ),
          _projectedImageMessage(
            id: 'b4_ws',
            sourceMessageId: 'b4_raw',
            base64: whitespacedP,
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 4),
          ),
        ],
      );
      await _drainMaintenance(store, 'conv-b4-stream');
      expect(store.debugProbeCount, 1, reason: '包装差异同 sourceKey，直接回放');
      var messages = await store.loadCachedMessages('conv-b4-stream');
      final dataUrlBlock =
          messages
                  .firstWhere((message) => message.id == 'b4_data')
                  .blocks!
                  .single
              as ImageBlock;
      final whitespacedBlock =
          messages.firstWhere((message) => message.id == 'b4_ws').blocks!.single
              as ImageBlock;
      expect(dataUrlBlock.width, 5);
      expect(whitespacedBlock.width, 5);

      // 采样窗外中段差异 → sourceKey 碰撞：漏一次探测为既定取舍，
      // 但流式精确门必须拒绝回放污染。
      await store.upsertMessage(
        conversationId: 'conv-b4-stream',
        message: _projectedImageMessage(
          id: 'b4_q',
          sourceMessageId: 'b4_raw',
          base64: payloadQ,
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 5),
        ),
      );
      await _drainMaintenance(store, 'conv-b4-stream');
      expect(store.debugProbeCount, 1);
      messages = await store.loadCachedMessages('conv-b4-stream');
      final collidedBlock =
          messages.firstWhere((message) => message.id == 'b4_q').blocks!.single
              as ImageBlock;
      expect(collidedBlock.width, isNull, reason: '精确门拒绝碰撞来源的尺寸回放');

      expect(
        store.debugFullBase64NormalizationCount,
        0,
        reason: 'B4：候选扫描/状态表/回放路径零全量规范化拷贝',
      );
    });

    test('S1: 维护尾处理抛错被密封——无未处理异常且后续维护正常', () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final baseTime = DateTime(2026, 7, 19, 13, 40, 0).millisecondsSinceEpoch;
      await _insertConversation(database, 'conv-s1-tail', baseTime);

      final probe = _nullProbe();
      final container = _createTimelineContainer(
        database,
        overrides: [imageDimensionProbeProvider.overrideWithValue(probe.call)],
      );
      addTearDown(container.dispose);

      await _persistMessage(
        container,
        'conv-s1-tail',
        Message(
          id: 's1_raw',
          role: 'assistant',
          content: 'raw',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
      );

      final store = container.read(conversationTimelineCacheProvider);
      await store.reloadConversationFromRawStore('conv-s1-tail');

      store.debugMaintenanceTailHook = (_) => throw StateError('tail boom');
      await store.upsertMessage(
        conversationId: 'conv-s1-tail',
        message: _projectedImageMessage(
          id: 's1_a',
          sourceMessageId: 's1_raw',
          localPath: '/gone/s1_a.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      );
      await _drainMaintenance(store, 'conv-s1-tail');
      expect(store.debugProbeCount, 1);

      // 钩子解除后维护恢复正常；未处理异常会让 flutter_test 的 zone
      // 直接判本测试失败——测试通过即证明尾处理异常被就地密封。
      store.debugMaintenanceTailHook = null;
      await store.upsertMessage(
        conversationId: 'conv-s1-tail',
        message: _projectedImageMessage(
          id: 's1_b',
          sourceMessageId: 's1_raw',
          localPath: '/gone/s1_b.png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
        ),
      );
      await _drainMaintenance(store, 'conv-s1-tail');
      expect(store.debugProbeCount, 2, reason: '后续维护不受尾处理故障影响');
    });
  });
}
