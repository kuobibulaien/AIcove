import 'dart:async';
import 'dart:io';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/sync/cloud_local_write.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/infrastructure/chat_port_adapters.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/chat_segmented_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _PausedHistoryAdapter extends ChatHistoryStoreAdapter {
  _PausedHistoryAdapter(super.store, this.entered, this.release);
  final Completer<void> entered;
  final Completer<void> release;
  bool paused = false;
  @override
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
    if (!paused && shouldCommit != null) {
      paused = true;
      entered.complete();
      await release.future;
    }
    await super.appendAssistantRawMessage(
      conversationId: conversationId,
      userMessageId: userMessageId,
      rawMessage: rawMessage,
      projectedMessages: projectedMessages,
      lastMessagePreview: lastMessagePreview,
      updateShortWindow: updateShortWindow,
      updateSummary: updateSummary,
      shouldCommit: shouldCommit,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SegmentedChatFixture fixture;
  late Directory directory;
  final oldPaths = PathProviderPlatform.instance;
  setUpAll(() async {
    final output = await Directory(
      'build/chat_generation_integrity',
    ).create(recursive: true);
    directory = await output.createTemp();
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    fixture = await SegmentedChatFixture.create(historyCount: 0);
  });
  tearDown(() => fixture.dispose());

  for (final deleting in [false, true]) {
    test('${deleting ? "删除会话" : "清空消息"}先取消生成，迟到回复不再落库', () async {
      await fixture.start();
      final id = fixture.conversation.id;
      final notifier = fixture.container.read(conversationsProvider.notifier);
      if (deleting) {
        await notifier.deleteConversation(id);
      } else {
        await notifier.clearMessages(id);
      }
      expect(fixture.container.read(conversationSendingProvider(id)), isFalse);
      fixture.add('迟到的回答。');
      await fixture.finish();
      final active = await fixture.container
          .read(messageRepositoryProvider)
          .getAllByConversationOrderedStable(id);
      expect(active, isEmpty);
    });
  }

  test('补充投影等待云写锁，合并锁内最新原文，不覆盖新编辑', () async {
    final id = fixture.conversation.id;
    final store = fixture.container.read(chatHistoryStoreProvider);
    final raw = Message.text(
      id: 'raw',
      role: 'assistant',
      content: '旧原文',
      createdAt: DateTime.now(),
    );
    await store.appendAssistantRawMessage(
      conversationId: id,
      userMessageId: '',
      rawMessage: raw,
      projectedMessages: [raw.copyWith(sourceMessageId: raw.id)],
      lastMessagePreview: raw.content,
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final writer = cloudLocalWrite(() async {
      entered.complete();
      await release.future;
      await (fixture.database.update(fixture.database.messages)
            ..where((m) => m.id.equals(raw.id)))
          .write(const db.MessagesCompanion(content: Value('新原文')));
    });
    await entered.future;
    var completed = false;
    final sync = store
        .syncRawSupplementsFromTimeline(
          conversationId: id,
          rawMessageIds: {raw.id},
        )
        .then((_) => completed = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(completed, isFalse, reason: '原文读改写必须等待同步锁');
    } finally {
      release.complete();
      await writer;
      await sync;
    }
    final latest = await fixture.container
        .read(messageRepositoryProvider)
        .getById(raw.id);
    expect(latest!.content, '新原文');
  });

  test('补充投影不会从短窗复活已删除原文', () async {
    final id = fixture.conversation.id;
    final raw = Message.text(
      id: 'deleted_raw',
      role: 'assistant',
      content: '已删除',
      createdAt: DateTime.now(),
    );
    final store = fixture.container.read(chatHistoryStoreProvider);
    await store.appendAssistantRawMessage(
      conversationId: id,
      userMessageId: '',
      rawMessage: raw,
      projectedMessages: [raw.copyWith(sourceMessageId: raw.id)],
      lastMessagePreview: raw.content,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await fixture.container
        .read(messageRepositoryProvider)
        .softDeleteByConversation(id, now, now + 1000);
    expect(
      await fixture.container
          .read(conversationTimelineCacheProvider)
          .loadCachedMessages(id),
      isNotEmpty,
    );
    await store.syncRawSupplementsFromTimeline(
      conversationId: id,
      rawMessageIds: {raw.id},
    );
    expect(
      (await fixture.container.read(messageRepositoryProvider).getById(raw.id))!
          .deletedAt,
      isNotNull,
    );
  });
  test('排队等待数据库后重新确认生成资格，不写迟到的raw和映射', () async {
    final store = fixture.container.read(chatHistoryPortProvider);
    final entered = Completer<void>();
    final release = Completer<void>();
    var current = true;
    final blocker = fixture.database.transaction(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final raw = Message.text(
      id: 'waiting_raw',
      role: 'assistant',
      content: '已取消',
      createdAt: DateTime.now(),
    );
    final publication = store.appendAssistantRawMessage(
      conversationId: fixture.conversation.id,
      userMessageId: '',
      rawMessage: raw,
      projectedMessages: [raw.copyWith(sourceMessageId: raw.id)],
      lastMessagePreview: raw.content,
      shouldCommit: () => current,
    );
    current = false;
    release.complete();
    await blocker;
    await publication;
    expect(
      await fixture.container.read(messageRepositoryProvider).getById(raw.id),
      isNull,
    );
    final mappings = await fixture.database
        .select(fixture.database.messageProjectionMappings)
        .get();
    expect(mappings, isEmpty);
  });

  test('多模态分段等待期间清空消息，迟到分段不再写raw或时间线', () async {
    await fixture.dispose();
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      settings: segmentedProbeSettings.copyWith(streamSegmentDelaySeconds: 0.2),
    );
    final id = fixture.conversation.id;
    final raw = Message.text(
      id: 'delayed_segments',
      role: 'assistant',
      content: '稍后显示的文字',
      createdAt: DateTime.now(),
    );
    final handler = fixture.container.read(chatTtsHandlerProvider);
    final delivery = handler.deliverSegmentedMessages(
      convId: id,
      userMsgId: '',
      buildResult: AssistantMessageBuildResult(
        rawMessage: raw,
        messages: [raw],
        lastMessageText: raw.content,
      ),
      replyText: raw.content,
      pluginEvents: [
        PluginEvent(pluginId: 'image', type: 'image_generate', data: const {}),
      ],
      ttsEnabled: false,
      shouldCommit: () => true,
    );
    // The raw is committed before the segment delay; clear during that delay.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (await fixture.container
            .read(messageRepositoryProvider)
            .getById(raw.id) ==
        null) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('raw未提交');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await fixture.container
        .read(conversationsProvider.notifier)
        .clearMessages(id);
    await delivery;
    await handler.debugWaitForBackgroundTasks();
    expect(
      await fixture.container
          .read(messageRepositoryProvider)
          .getAllByConversationOrderedStable(id),
      isEmpty,
    );
    expect(
      await fixture.container
          .read(conversationTimelineCacheProvider)
          .loadCachedMessages(id),
      isEmpty,
    );
  });

  test('真实流式收尾在adapter等待期间清空，原文与映射都不会迟到落库', () async {
    await fixture.dispose();
    final entered = Completer<void>();
    final release = Completer<void>();
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      extraOverrides: [
        chatHistoryPortProvider.overrideWith(
          (ref) => _PausedHistoryAdapter(
            ref.read(chatHistoryStoreProvider),
            entered,
            release,
          ),
        ),
      ],
    );
    await fixture.start();
    fixture.add('这是一段足够完整的流式回答，已经生成完毕，但是原文正式提交还在等待。');
    final finishing = fixture.finish();
    try {
      await entered.future.timeout(const Duration(seconds: 10));
      await fixture.container
          .read(conversationsProvider.notifier)
          .clearMessages(fixture.conversation.id);
    } finally {
      release.complete();
      await finishing;
    }
    expect(
      await fixture.container
          .read(messageRepositoryProvider)
          .getAllByConversationOrderedStable(fixture.conversation.id),
      isEmpty,
    );
    final mappings = await fixture.database
        .select(fixture.database.messageProjectionMappings)
        .get();
    expect(mappings, isEmpty);
    expect(
      await fixture.container
          .read(conversationTimelineCacheProvider)
          .loadCachedMessages(fixture.conversation.id),
      isEmpty,
    );
  });
}
