import 'package:aicove_flutter/src/features/chat/application/chat_page_conversation_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 离线审计：失败断言表示尚未修复的安全/持久化契约，不改为迁就现状的断言。
import 'dart:io';

import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_media_codec.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_repository.dart';
import '../sync/lan_repository_test.dart'
    show LanMemoryPreferences, lanTestDevice, seedLan, copyLan;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_regex_processor.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  final time = DateTime(2026, 9, 6);
  final conversation = Conversation(
    id: 'a',
    title: '审计',
    displayName: '审计',
    createdAt: time,
    updatedAt: time,
  );
  ProviderContainer newContainer() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      activeConversationProvider.overrideWith((ref) => conversation),
    ],
  );
  ChatHistoryStore store() => container.read(chatHistoryStoreProvider);
  Future<void> seed(String id, String role, String text, int offset) async {
    await database
        .into(database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: id,
            conversationId: 'a',
            role: role,
            content: text,
            createdAt: time.millisecondsSinceEpoch + offset,
          ),
        );
  }

  Future<void> boundary(String id) async {
    await (database.update(database.conversations)
          ..where((t) => t.id.equals('a')))
        .write(db.ConversationsCompanion(contextStartMessageId: Value(id)));
  }

  Future<void> seedTopic() async {
    await seed('u0', 'user', '旧话题用户', 0);
    await seed('a0', 'assistant', '旧话题回复', 1);
    await seed('u1', 'user', '新话题用户', 2);
    await seed('a1', 'assistant', '新话题回复', 3);
    await boundary('a0');
  }

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.customStatement('PRAGMA foreign_keys = ON');
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'a',
            title: '审计',
            displayName: '审计',
            createdAt: time.millisecondsSinceEpoch,
            updatedAt: time.millisecondsSinceEpoch,
          ),
        );
    container = newContainer();
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('A01 UI显示替换不污染DB原文和canonical', () async {
    final raw = Message(
      id: 'raw',
      role: 'assistant',
      content: '原始秘密',
      createdAt: time,
      rawPayload: const {'rawReplyText': '原始秘密', 'processedText': '显示替换'},
    );
    final projection = const ChatFrontendMessageProjectionService()
        .projectMessage(raw);
    await store().appendAssistantRawMessage(
      conversationId: 'a',
      userMessageId: '',
      rawMessage: raw,
      projectedMessages: projection,
      lastMessagePreview: '显示替换',
    );
    expect(projection.single.content, '显示替换');
    final canonical = await store().loadCanonicalContextMessages('a');
    expect(canonical.single.content, '原始秘密');
    expect(canonical.single.toHistoryJsonList().single['content'], '原始秘密');
  });

  test('A02 正常话题边界只读取新话题', () async {
    await seedTopic();
    expect((await store().loadCanonicalContextMessages('a')).map((m) => m.id), [
      'u1',
      'a1',
    ]);
  });

  test('A03 编辑入口尚未提交新消息不得先删旧历史', () async {
    await seed('u0', 'user', '尚未确认的编辑', 0);
    await seed('a0', 'assistant', '应保留的回复', 1);
    expect(
      await container.read(chatActionsProvider).editMessage('u0'),
      '尚未确认的编辑',
    );
    // 不调用send，模拟取消或离开编辑器；目前此时已经写入deleted_at。
    expect((await store().loadAllRawMessages('a')).map((m) => m.id), [
      'u0',
      'a0',
    ]);
  });

  test('A04 截断删除话题边界后不得静默回流旧话题', () async {
    await seedTopic();
    // 等价于编辑边界之前的旧用户消息：旧marker随其后缀一起软删。
    await store().truncateAfterMessage(
      conversationId: 'a',
      anchorMessageId: 'u0',
    );
    final persisted = await container
        .read(conversationRepositoryProvider)
        .getById('a');
    expect(persisted!.contextStartMessageId, 'a0');
    await expectLater(
      store().loadCanonicalContextMessages('a'),
      throwsStateError,
      reason: '有显式边界但marker失效时应拒绝，不得当无边界发送',
    );
  });

  test('A05 前端删除应跨容器重建保留且不改canonical', () async {
    await seed('u0', 'user', '隐藏后不应复活', 0);
    await seed('a0', 'assistant', '同批隐藏', 1);
    await container.read(chatPageConversationActionsProvider).hideMessages(
      'a',
      ['u0', 'a0'],
    );
    final cache = container.read(conversationTimelineCacheProvider);
    expect(
      (await cache.watchWindow(conversationId: 'a', limit: 20).first).messages,
      isEmpty,
    );
    expect(await store().loadCanonicalContextMessages('a'), hasLength(2));
    container.dispose();
    container = newContainer();
    final restored = await container
        .read(conversationTimelineCacheProvider)
        .watchWindow(conversationId: 'a', limit: 20)
        .first;
    expect(restored.messages, isEmpty, reason: '同一DB，新容器模拟进程重启后的时间线重建');
  });

  Future<Message> regexRaw(String text, {bool multimedia = false}) async {
    final filtered = await const SillyTavernRegexProcessor().applyToDisplayText(
      text: text,
      authorized: true,
      scripts: const [
        SillyTavernRegexScript(
          id: 'hide-secret',
          name: 'hide-secret',
          source: 'audit',
          disabled: false,
          runOnEdit: false,
          findRegex: '/SECRET/g',
          replaceString: '',
          trimStrings: [],
          placements: [2],
          substituteRegex: 0,
          minDepth: null,
          maxDepth: null,
          markdownOnly: true,
          promptOnly: false,
        ),
      ],
    );
    expect(filtered.text, isNot(contains('SECRET')));
    final result = ApiCallResult(
      rawReplyText: text,
      replyText: filtered.text,
      processedText: filtered.text,
      pluginEvents: [
        if (multimedia)
          PluginEvent(
            pluginId: 'tts',
            type: 'tts_convert',
            data: {'text': '你好'},
          ),
      ],
      toolResults: const [],
    );
    return Message(
      id: 'raw',
      role: 'assistant',
      content: text,
      createdAt: time,
      rawPayload: ChatMessageProjectionCodec.buildRawAssistantPayload(
        apiResult: result,
      ),
    );
  }

  test('A06 显示正则清空文本后不得回退显示原文', () async {
    final raw = await regexRaw('SECRET');
    final bubbles = const ChatFrontendMessageProjectionService().projectMessage(
      raw,
    );
    expect(bubbles.map((m) => m.displayText).join(), isNot(contains('SECRET')));
  });

  test('A07 多模态分段不得绕过显示正则', () async {
    final raw = await regexRaw('SECRET正文<tts>你好</tts>', multimedia: true);
    final bubbles = const ChatFrontendMessageProjectionService().projectMessage(
      raw,
    );
    expect(bubbles.map((m) => m.displayText).join(), isNot(contains('SECRET')));
  });

  test('A08 当前LAN拉取不得忽略raw_payload', () async {
    final root = await Directory.systemTemp.createTemp('chat-sync-raw-audit-');
    final source = await lanTestDevice(root, 'source');
    final target = await lanTestDevice(root, 'target');
    addTearDown(() async {
      for (final device in [source, target]) {
        await device.media.close();
        await device.local.db.close();
      }
      await root.delete(recursive: true);
    });
    await seedLan(source);
    const payload = '{"rawReplyText":"原文","processedText":"显示"}';
    await source.local.execute('UPDATE messages SET raw_payload=? WHERE id=?', [
      payload,
      'message',
    ]);
    await copyLan(source, target);
    final row =
        (await target.local.read('messages', 'message'))!.payload['row'] as Map;
    expect(row['raw_payload'], payload);
    expect(row['content'], '原文');
    expect(
      (await source.local.read(
        'messages',
        'message',
      ))!.payload['row']['raw_payload'],
      payload,
    );
  });

  for (final stage in ['first_insert', 'tool_insert', 'delete']) {
    test('A10 投影补写失败不得删除raw消息的原始blocks: $stage', () async {
      final raw =
          Message.fromBlocks(
            id: 'raw',
            role: 'assistant',
            createdAt: time,
            blocks: [
              TextBlock(messageId: 'raw', content: '正文'),
              ToolBlock(
                messageId: 'raw',
                toolName: 'audit_tool',
                toolCallId: 'call1',
                arguments: const {},
                result: const {'ok': true},
              ),
            ],
          ).copyWith(
            rawPayload: const {'rawReplyText': '正文', 'processedText': '正文'},
          );
      final projection = const ChatFrontendMessageProjectionService()
          .projectMessage(raw);
      await store().appendAssistantRawMessage(
        conversationId: 'a',
        userMessageId: '',
        rawMessage: raw,
        projectedMessages: projection,
        lastMessagePreview: '正文',
      );
      final before = await container
          .read(messageBlockRepositoryProvider)
          .getByMessage('raw');
      expect(before, hasLength(2));
      final beforeRaw = await container
          .read(messageRepositoryProvider)
          .getById('raw');
      final beforeHistory = (await store().loadAllRawMessages(
        'a',
      )).single.toHistoryJsonList();
      // 后续块失败时正文已经插入；DELETE失败时message已经更新，均应回滚。
      final triggerEvent = stage == 'delete' ? 'DELETE' : 'INSERT';
      final condition = stage == 'tool_insert' ? "WHEN NEW.type = 'tool'" : '';
      await database.customStatement(
        "CREATE TRIGGER audit_block_failure BEFORE $triggerEvent ON message_blocks $condition BEGIN SELECT RAISE(ABORT, 'audit-write-failure'); END",
      );
      await expectLater(
        store().updateMessage(
          conversationId: 'a',
          message: projection.first.copyWith(content: '更新气泡'),
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains('audit-write-failure'),
          ),
        ),
      );
      final after = await container
          .read(messageBlockRepositoryProvider)
          .getByMessage('raw');
      expect(
        after.map((b) => b.data).toList(),
        before.map((b) => b.data).toList(),
        reason: '补写必须回滚到原blocks，不能先提交DELETE再让INSERT单独失败',
      );
      expect(
        await container.read(messageRepositoryProvider).getById('raw'),
        beforeRaw,
      );
      expect(
        (await store().loadAllRawMessages('a')).single.toHistoryJsonList(),
        beforeHistory,
      );
      await database.customStatement('DROP TRIGGER audit_block_failure');
      await store().updateMessage(
        conversationId: 'a',
        message: projection.first.copyWith(content: '更新气泡'),
      );
      expect(
        (await store().loadAllRawMessages('a')).single.toHistoryJsonList(),
        beforeHistory,
      );
      expect(
        (await container.read(messageRepositoryProvider).getById('raw'))!
            .rawPayload,
        isNot(beforeRaw!.rawPayload),
        reason: '正常重试应持久化补写结果，而不是直接跳过操作',
      );
      expect(
        await database.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
    });
  }

  test('A11 消息写入子事务成功后外层失败仍须全部回滚', () async {
    final before = await container
        .read(conversationRepositoryProvider)
        .getById('a');
    await database.customStatement(
      "CREATE TRIGGER audit_summary_failure BEFORE UPDATE ON conversations BEGIN SELECT RAISE(ABORT, 'audit-summary-failure'); END",
    );
    final message = Message.fromBlocks(
      id: 'nested',
      role: 'user',
      createdAt: time,
      blocks: [TextBlock(messageId: 'nested', content: '外层失败')],
    );
    await expectLater(
      store().appendUserMessage(
        conversationId: 'a',
        message: message,
        displayText: '外层失败',
      ),
      throwsA(
        predicate(
          (error) => error.toString().contains('audit-summary-failure'),
        ),
      ),
    );
    expect(
      await container.read(messageRepositoryProvider).getById('nested'),
      isNull,
    );
    expect(
      await container
          .read(messageBlockRepositoryProvider)
          .getByMessage('nested'),
      isEmpty,
    );
    expect(
      await container.read(conversationRepositoryProvider).getById('a'),
      before,
    );
    await database.customStatement('DROP TRIGGER audit_summary_failure');
    await store().appendUserMessage(
      conversationId: 'a',
      message: message,
      displayText: '外层失败',
    );
    expect(
      await container.read(messageRepositoryProvider).getById('nested'),
      isNotNull,
    );
    expect(
      await container
          .read(messageBlockRepositoryProvider)
          .getByMessage('nested'),
      hasLength(1),
    );
  });

  test('A09 普通聊天落库应进入当前LAN同步待办', () async {
    await store().appendUserMessage(
      conversationId: 'a',
      message: Message(
        id: 'u0',
        role: 'user',
        content: '需要同步的消息',
        createdAt: time,
      ),
      displayText: '需要同步的消息',
    );
    expect(await store().loadAllRawMessages('a'), hasLength(1));
    final dirty = await database
        .customSelect(
          "SELECT * FROM lan_dirty WHERE kind='messages' AND entity_id='u0'",
        )
        .get();
    expect(dirty, isNotEmpty, reason: '当前LAN同步必须捕获新落库的聊天');
    final root = await Directory.systemTemp.createTemp(
      'chat-sync-write-audit-',
    );
    final media = MediaStore(Directory('${root.path}/media'), 'chat-audit');
    addTearDown(() async {
      await media.close();
      await root.delete(recursive: true);
    });
    final local = CloudLocalStore(
      database,
      LanMemoryPreferences(),
      Directory('${root.path}/docs')..createSync(),
      Directory('${root.path}/support')..createSync(),
    );
    final repo = LanRepository(
      local,
      CloudMediaCodec(media, allowNetworkDownload: false),
      'chat-audit',
    );
    await repo.capture();
    final manifest = await repo.manifest();
    final item = (manifest['items'] as List).cast<Map>().singleWhere(
      (item) => item['kind'] == 'messages' && item['entity_id'] == 'u0',
    );
    final revision = await repo.revision(
      (item['hashes'] as List).single as String,
    );
    expect((revision.payload['row'] as Map)['content'], '需要同步的消息');
  });
}
