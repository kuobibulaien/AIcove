import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/token_estimator.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/context/application/context_manager.dart';
import 'package:aicove_flutter/src/features/context/data/background_context_summarizer.dart';
import 'package:aicove_flutter/src/features/context/data/sqlite_context_summary_store.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/context/providers/context_providers.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_config.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_plugin.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Settings extends AppSettingsNotifier {
  static int? maxTokens;
  static int window = 272000;
  static String? extraModel;
  @override
  Future<AppSettings> build() async {
    var settings = mapUiModelsToAppSettings({'context_window_tokens': window});
    final extra = extraModel;
    if (extra != null) {
      settings = settings.copyWith(
        modelList: [...settings.modelList, extra],
        allKnownModels: [...settings.allKnownModels, extra],
      );
    }
    return maxTokens == null
        ? settings
        : settings.copyWith(
            modelConfigs: {
              settings.defaultModelName: ModelConfig(
                maxContextTokens: maxTokens,
              ),
            },
          );
  }
}

class _Summary implements ContextSummarizerPort {
  String text = '- 周五一起去看海，用户怕冷。';
  bool fail = false;
  int calls = 0;
  Object? error;
  Completer<void>? gate;
  ContextSnapshot? seen;
  ContextSummaryKind? kind;
  @override
  Future<String> summarize(
    ContextSnapshot snapshot, {
    required ContextSummaryKind kind,
    required void Function(int, int) onProgress,
    required bool Function() isCancelled,
  }) async {
    calls++;
    seen = snapshot;
    this.kind = kind;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    if (fail) throw StateError('fake network unavailable');
    onProgress(1, 1);
    return text;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  manualCompactionSessionTests();
  late Directory root;
  late db.AppDatabase database;
  late ProviderContainer container;
  late PathProviderPlatform oldPaths;
  late SqliteContextSummaryStore store;
  late _Summary summary;
  late ContextManager service;
  var compacted = <String>[];
  bool sending = false;

  Future<void> open() async {
    database = db.AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/test.sqlite')),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(_Settings.new),
        pluginManagerProvider.overrideWithValue(PluginManager()),
        contextSummarizerProvider.overrideWith((ref) async => summary),
        // 长期记忆整理另有测试；这里关闭，避免后台任务跨越测试生命周期。
        memoryKeeperProvider.overrideWith(
          (ref) => MemoryKeeperService(
            store: ref.read(memoryStoreProvider),
            loadMessages: (_) async => const [],
            compactedBoundaries: (_) async => const {},
            agentFactory: () => throw StateError('memory agent disabled'),
            allowed: (_) async => false,
          ),
        ),
        sillyTavernPresetStoreProvider.overrideWithValue(
          SillyTavernPresetStore(documentsDirectoryResolver: () async => root),
        ),
      ],
    );
    await database.customStatement('PRAGMA foreign_keys = ON');
    store = SqliteContextSummaryStore(
      database,
      (owner) =>
          container.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    );
  }

  Future<String?> boundary(String owner) async =>
      (await container.read(conversationRepositoryProvider).getById(owner))
          ?.contextStartMessageId;
  ContextManager createService({
    DateTime Function()? now,
    Future<ContextSummarizerPort> Function()? factory,
  }) => ContextManager(
    now: now,
    store: store,
    loadMessages: (owner) =>
        container.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    readBoundary: boundary,
    summarizerFactory: factory ?? () async => summary,
    publishBoundary: (_) async {},
    ensureIdle: (_) {
      if (sending) throw const ContextCompactionException('生成中');
    },
    onCompacted: compacted.add,
  );
  Future<void> owner(String id, {String? start}) async {
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: id,
            title: '同名角色',
            displayName: '同名角色',
            createdAt: 1,
            updatedAt: 1,
            personaPrompt: const Value('最新角色卡：只用简短聊天，不用旁白。'),
            contextStartMessageId: Value(start),
          ),
        );
  }

  Future<void> message(
    String id, {
    String owner = 'a',
    String role = 'user',
    String? text,
    int at = 1,
    String status = 'sent',
  }) async {
    await database
        .into(database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: id,
            conversationId: owner,
            role: role,
            content: text ?? '$id：旧格式旁白示例',
            createdAt: at,
            status: Value(status),
          ),
        );
  }

  Future<ManualCompactionDraft> prepare([String id = 'a']) =>
      service.prepare(id, onProgress: (_, __) {}, isCancelled: () => false);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _Settings.maxTokens = null;
    _Settings.extraModel = null;
    _Settings.window = 272000;
    root = await Directory.systemTemp.createTemp('topic_compaction_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TraceStore.instance.debugResetForTest();
    await open();
    summary = _Summary();
    compacted = <String>[];
    sending = false;
    service = createService();
  });
  tearDown(() async {
    await TraceStore.instance.waitForPendingWrites();
    TraceStore.instance.debugResetForTest();
    container.dispose();
    await database.close();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  for (final oldAge in [const Duration(hours: 1), const Duration(minutes: 1)]) {
    test('旧话题 sending 不阻塞当前话题整理：$oldAge', () async {
      final now = DateTime.now();
      final at = now.subtract(oldAge).millisecondsSinceEpoch;
      await owner('a', start: 'boundary');
      await message(
        'old-placeholder',
        role: 'assistant',
        status: 'sending',
        at: at,
      );
      await message('boundary', at: at + 1);
      await message('current', at: at + 2);
      final snapshot = await store.manualSnapshot('a');
      expect(snapshot.messages.map((m) => m.id), ['current']);
      await store.commitManual(snapshot, '- 当前话题事实');
    });
  }

  test('手动 prepare 先清理旧占位再整理并提交', () async {
    await owner('a', start: 'boundary');
    await message('old-placeholder', role: 'assistant', status: 'sending');
    await message('boundary', at: 2);
    await message('current', at: 3);
    final manager = container.read(contextManagerProvider);
    final draft = await manager.prepare(
      'a',
      onProgress: (_, __) {},
      isCancelled: () => false,
    );
    expect(draft.snapshot.messages.map((m) => m.id), ['current']);
    final orphan = await container
        .read(messageRepositoryProvider)
        .getById('old-placeholder');
    expect(orphan?.status, 'failed');
    expect(orphan?.deletedAt, isNotNull);
    await manager.commit(draft, draft.summary);
    expect(await boundary('a'), 'current');
  });

  test('当前话题新 sending 仍阻塞手动整理', () async {
    await owner('a');
    await message('normal');
    await message(
      'active',
      role: 'assistant',
      status: 'sending',
      at: DateTime.now().millisecondsSinceEpoch,
    );
    await expectLater(
      store.manualSnapshot('a'),
      throwsA(
        isA<ContextCompactionException>().having(
          (e) => e.message,
          'message',
          '请等本轮回复结束后再压缩。',
        ),
      ),
    );
  });

  test('当前话题超时 sending 不阻塞也不进入待整理原文', () async {
    await owner('a');
    await message('normal');
    await message('dead', role: 'assistant', status: 'sending', at: 2);
    final snapshot = await store.manualSnapshot('a');
    expect(snapshot.messages.map((m) => m.id), ['normal']);
    await store.commitManual(snapshot, '- 正常消息事实');
  });

  for (final role in ['user', 'assistant']) {
    for (final offset in [-1, 0, 1]) {
      test('当前话题 $role sending 阈值边界 ${offset}ms', () async {
        final now = DateTime.utc(2030);
        final timedStore = SqliteContextSummaryStore(
          database,
          container.read(chatHistoryStoreProvider).loadAllRawMessages,
          now: () => now,
        );
        await owner('a');
        await message('normal');
        await message(
          'in-flight',
          role: role,
          status: 'sending',
          at:
              now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch +
              offset,
        );
        if (offset >= 0) {
          await expectLater(
            timedStore.manualSnapshot('a'),
            throwsA(
              isA<ContextCompactionException>().having(
                (e) => e.message,
                'message',
                '请等本轮回复结束后再压缩。',
              ),
            ),
          );
        } else {
          expect(
            (await timedStore.manualSnapshot('a')).messages.map((m) => m.id),
            ['normal'],
          );
        }
      });
    }
  }

  test('新话题边界恰是最后一条 raw 时，不回流整个旧话题', () async {
    await owner('a', start: 'm1');
    await message('m1');
    expect(
      await container
          .read(chatHistoryStoreProvider)
          .loadCanonicalContextMessages('a'),
      isEmpty,
    );
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    expect(
      await container
          .read(chatSendServiceProvider)
          .prepareHistoryFromStore(
            conv: conv,
            userMsg: Message(
              id: 'm1',
              role: 'user',
              content: 'old',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1),
            ),
          ),
      isEmpty,
    );
  });

  test('先预览不改边界；确认后原始消息全保留且角色各自隔离', () async {
    await owner('a');
    await owner('b');
    await message('a1');
    await message('a2', role: 'assistant', at: 2);
    await message('b1', owner: 'b', text: 'B秘密');
    final draft = await prepare();
    expect(await boundary('a'), isNull);
    expect(summary.seen!.messages.map((m) => m.id), ['a1', 'a2']);
    await service.commit(draft, draft.summary);
    expect(compacted, ['a']);
    expect(await boundary('a'), 'a2');
    expect(await boundary('b'), isNull);
    expect(
      (await container.read(chatHistoryStoreProvider).loadAllRawMessages('a'))
          .length,
      2,
    );
    expect(await store.manualFor('b', 'a2'), isNull);
    expect(await store.compactedBoundaries('a'), {'a2'});
    expect(await store.compactedBoundaries('b'), isEmpty);
    expect((await store.manualFor('a', 'a2'))!.sourceIds, ['a1', 'a2']);
  });

  test('总结失败或取消不改变话题，也不触发记忆整理', () async {
    await owner('a');
    await message('m1');
    summary.fail = true;
    await expectLater(prepare(), throwsStateError);
    summary.fail = false;
    await expectLater(
      service.prepare('a', onProgress: (_, __) {}, isCancelled: () => true),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(await boundary('a'), isNull);
    expect(compacted, isEmpty);
  });

  test('预览期间新增消息或编辑源消息，提交必须失败且保留旧边界', () async {
    await owner('a');
    await message('m1');
    var draft = await prepare();
    await message('m2', at: 2);
    await expectLater(
      service.commit(draft, draft.summary),
      throwsA(isA<ContextCompactionException>()),
    );
    draft = await prepare();
    await (database.update(database.messages)..where((m) => m.id.equals('m1')))
        .write(const db.MessagesCompanion(content: Value('已更正')));
    await expectLater(
      service.commit(draft, draft.summary),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(await boundary('a'), isNull);
  });

  test('角色卡可在预览期间更新，保存只改边界不会覆盖最新角色卡', () async {
    await owner('a');
    await message('m1');
    final draft = await prepare();
    await (database.update(database.conversations)
          ..where((c) => c.id.equals('a')))
        .write(const db.ConversationsCompanion(personaPrompt: Value('新卡短句')));
    await service.commit(draft, draft.summary);
    expect(
      (await container.read(conversationRepositoryProvider).getById('a'))!
          .personaPrompt,
      '新卡短句',
    );
  });

  test('连续压缩输入包含上一内容摘要；撤销恢复旧边界并缩小记忆整理范围', () async {
    await owner('a');
    await message('m1');
    var draft = await prepare();
    await service.commit(draft, draft.summary);
    await message('m2', at: 2);
    summary.text = '- 周五一起去看海，用户怕冷。\n- 已约好带外套。';
    draft = await prepare();
    expect(draft.snapshot.previous!.summary, contains('怕冷'));
    expect(draft.snapshot.messages.map((m) => m.id), ['m2']);
    await service.commit(draft, draft.summary);
    expect((await service.current('a'))!.sourceIds, ['m1', 'm2']);
    await service.undo('a');
    expect(await boundary('a'), 'm1');
    expect(await store.compactedBoundaries('a'), {'m1'});
    expect(
      (await container
              .read(chatHistoryStoreProvider)
              .loadCanonicalContextMessages('a'))
          .single
          .id,
      'm2',
    );
    await service.undo('a');
    expect(await boundary('a'), isNull);
  });

  test('边界存在但没有摘要：补整理失败放行，成功后保存复用', () async {
    await owner('a', start: 'm2');
    await message('m1');
    await message('m2', role: 'assistant', at: 2);
    await message('m3', at: 3);
    summary.fail = true;
    expect(await service.manualSummary('a', 'm2', []), isNull);
    expect(compacted, isEmpty);
    summary.fail = false;
    service = createService();
    final recovered = (await service.manualSummary('a', 'm2', []))!;
    expect(summary.kind, ContextSummaryKind.manual);
    expect(summary.seen!.messages.map((m) => m.id), ['m1', 'm2']);
    expect(recovered.boundaryId, 'm2');
    expect(compacted, ['a']);
    // 已补过的摘要直接复用，不再调用模型。
    summary.seen = null;
    expect((await service.manualSummary('a', 'm2', []))!.id, recovered.id);
    expect(summary.seen, isNull);
    // 重放边界之前的旧轮次时不倒灌。
    expect(
      await service.manualSummary('a', 'm2', [
        Message(
          id: 'm1',
          role: 'user',
          content: '',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      ]),
      isNull,
    );
  });

  test('补整理失败冷却十分钟，期满重试成功，已有摘要直接复用', () async {
    await owner('a', start: 'm1');
    await message('m1');
    var now = DateTime(2030);
    var requests = 0;
    service = createService(
      now: () => now,
      factory: () async {
        requests++;
        return summary;
      },
    );
    summary.fail = true;
    expect(await service.manualSummary('a', 'm1', []), isNull);
    now = now.add(const Duration(minutes: 9, seconds: 59));
    expect(await service.manualSummary('a', 'm1', []), isNull);
    expect(requests, 1);
    now = now.add(const Duration(seconds: 1));
    summary.fail = false;
    final record = await service.manualSummary('a', 'm1', []);
    expect(record, isNotNull);
    expect(requests, 2);
    expect(compacted, ['a']);
    expect((await service.manualSummary('a', 'm1', []))?.id, record!.id);
    expect(requests, 2);
  });

  test('冷却中同步来的手动摘要直接生效，损坏边界仍拒绝发送', () async {
    await owner('a', start: 'm1');
    await message('m1');
    summary.fail = true;
    expect(await service.manualSummary('a', 'm1', []), isNull);
    final all = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    final record = await store.saveRecoveredManual(
      ContextSnapshot(
        ownerId: 'a',
        previousBoundaryId: null,
        allMessages: all,
        messages: all,
        previous: null,
      ),
      '- 对端摘要',
    );
    expect((await service.manualSummary('a', 'm1', []))?.id, record.id);
    expect(summary.calls, 1);
    await database.customStatement('DELETE FROM context_summaries');
    summary.fail = false;
    expect(await service.manualSummary('a', 'm1', []), isNotNull);
    expect(summary.calls, 2);
    await (database.delete(database.messages)).go();
    await expectLater(
      service.manualSummary('a', 'm1', []),
      throwsA(
        isA<ContextCompactionException>().having(
          (e) => e.message,
          'message',
          '话题边界已失效，请先恢复或撤销上次压缩，本轮未发送。',
        ),
      ),
    );
  });

  test('整理中再次发送跳过补整理，不抛忙异常或重复请求', () async {
    await owner('a', start: 'm1');
    await message('m1');
    final started = Completer<void>();
    service = createService(
      factory: () async {
        started.complete();
        return summary;
      },
    );
    summary.gate = Completer<void>();
    final running = service.manualSummary('a', 'm1', []);
    await started.future;
    expect(await service.manualSummary('a', 'm1', []), isNull);
    expect(summary.calls, 1);
    summary.gate!.complete();
    expect(await running, isNotNull);
  });

  for (final failure in ['factory', 'summary', 'save']) {
    test('补整理 $failure 抛异常也放行并进入冷却', () async {
      await owner('a', start: 'm1');
      await message('m1');
      var requests = 0;
      service = createService(
        factory: () async {
          requests++;
          if (failure == 'factory') throw StateError('HTTP 403 forbidden');
          return summary;
        },
      );
      if (failure == 'summary') {
        summary.error = const ContextCompactionException('摘要模型超时');
      }
      if (failure == 'save') {
        await database.customStatement(
          "CREATE TRIGGER fail_recovery BEFORE INSERT ON context_summaries BEGIN SELECT RAISE(ABORT, 'save failed'); END",
        );
      }
      expect(await service.manualSummary('a', 'm1', []), isNull);
      expect(await service.manualSummary('a', 'm1', []), isNull);
      expect(requests, 1);
      expect(compacted, isEmpty);
    });
  }

  test('边界原文缺失时阻止发送，不请求摘要模型', () async {
    await owner('a', start: 'missing');
    await message('m1');
    await expectLater(
      service.manualSummary('a', 'missing', []),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(summary.seen, isNull);
    expect(compacted, isEmpty);
  });

  test('已提交手动摘要绑定边界，旧消息删改及历史指纹不影响连续压缩', () async {
    await owner('a');
    await message('m0');
    await message('m1', at: 2);
    final draft = await prepare();
    final record = await service.commit(draft, draft.summary);
    await database.customStatement(
      "UPDATE context_summaries SET source_digest = 'legacy-device-digest'",
    );
    await (database.delete(
      database.messages,
    )..where((m) => m.id.equals('m0'))).go();
    await (database.update(database.messages)..where((m) => m.id.equals('m1')))
        .write(const db.MessagesCompanion(content: Value('纠正旧事实')));
    expect((await service.current('a'))?.id, record.id);
    await message('m2', at: 3);
    final next = await prepare();
    expect(next.snapshot.previous?.id, record.id);
    await service.commit(next, next.summary);
    await service.undo('a');
    await (database.delete(
      database.messages,
    )..where((m) => m.id.equals('m1'))).go();
    expect(await service.current('a'), isNull);
  });

  test('补整理失败不阻塞 prepareApiConfig 正常发送', () async {
    await owner('a', start: 'm1');
    await message('m1');
    await message('m2', text: '继续聊天', at: 2);
    summary.fail = true;
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final history = await container
        .read(chatHistoryStoreProvider)
        .loadCanonicalContextMessages('a');
    final config = await container
        .read(chatSendServiceProvider)
        .prepareApiConfig(conv: conv, history: history, userText: '继续聊天');
    expect(jsonEncode(config.messages), contains('继续聊天'));
    expect(summary.calls, 1);
    expect(compacted, isEmpty);
  });

  test('媒体路径与播放状态及内部生图块不使自动摘要失效，正文编辑仍失效', () async {
    await owner('a');
    await message('m1');
    Future<void> blocks({required bool changed, String text = '事实'}) async {
      final values = <MessageBlock>[
        TextBlock(id: 'text', messageId: 'm1', content: text),
        EmojiBlock(
          id: 'emoji',
          messageId: 'm1',
          emojiId: 'e',
          path: changed ? '/device-b/emoji.gif' : '/device-a/emoji.gif',
          matchedTag: '开心',
          originalText: '笑',
        ),
        AudioBlock(
          id: 'audio',
          messageId: 'm1',
          text: '你好',
          url: changed ? 'aicove-media://audio' : '/device-a/audio.wav',
          unread: !changed,
        ),
        ImageBlock(
          id: 'image',
          messageId: 'm1',
          prompt: '海边',
          localPath: changed ? '/device-b/image.png' : '/device-a/image.png',
          url: changed ? 'aicove-media://image' : 'https://example.com/image',
          base64: changed ? null : 'old-base64',
          versions: changed
              ? [
                  ImageVersionEntry(localPath: '/device-b/v1.png'),
                  ImageVersionEntry(localPath: '/device-b/v2.png'),
                ]
              : const [],
          activeVersionIndex: changed ? 1 : 0,
        ),
        if (changed)
          ToolBlock(
            id: 'hidden',
            messageId: 'm1',
            toolName: 'image_context',
            result: {'error': 'failed'},
          ),
      ];
      await (database.delete(database.messageBlocks)).go();
      for (var i = 0; i < values.length; i++) {
        await database
            .into(database.messageBlocks)
            .insert(MessageBlockConverter.toCompanion(values[i], 'm1', i));
      }
    }

    await blocks(changed: false);
    final snapshot = await store.manualSnapshot('a');
    final auto = await store.saveAuto(snapshot, '- 自动事实');
    final manual = await store.commitManual(snapshot, '- 手动事实');
    await blocks(changed: true);
    final raw = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    expect(contextSourceDigest(raw), snapshot.sourceDigest);
    expect((await store.loadAuto('a', null, raw))?.id, auto.id);
    expect((await service.current('a'))?.id, manual.id);
    await message('m2', at: 2);
    expect((await prepare()).snapshot.previous?.id, manual.id);
    await blocks(changed: true, text: '修改事实');
    final edited = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    expect(await store.loadAuto('a', null, edited), isNull);
    expect((await service.current('a'))?.id, manual.id);
  });

  test('重复提交、生成中、空新话题、超限摘要、删除角色均拒绝', () async {
    await owner('a');
    await message('m1');
    final draft = await prepare();
    await expectLater(
      service.commit(draft, '很长' * 10000),
      throwsA(isA<ContextCompactionException>()),
    );
    sending = true;
    await expectLater(prepare(), throwsA(isA<ContextCompactionException>()));
    sending = false;
    await service.commit(draft, draft.summary);
    await expectLater(
      service.commit(draft, draft.summary),
      throwsA(isA<ContextCompactionException>()),
    );
    await expectLater(prepare(), throwsA(isA<ContextCompactionException>()));
    await (database.update(database.conversations)
          ..where((c) => c.id.equals('a')))
        .write(const db.ConversationsCompanion(deletedAt: Value(5)));
    await expectLater(
      service.current('a'),
      throwsA(isA<ContextCompactionException>()),
    );
  });

  test('同一角色整理互斥，角色 B 不会改写 A 的输入', () async {
    await owner('a');
    await owner('b');
    await message('m1');
    await message('b1', owner: 'b');
    summary.gate = Completer<void>();
    final running = prepare();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await expectLater(prepare(), throwsA(isA<ContextCompactionException>()));
    summary.gate!.complete();
    final a = await running;
    final b = await prepare('b');
    expect(a.snapshot.ownerId, 'a');
    expect(b.snapshot.ownerId, 'b');
  });

  test('真实应用入口按目标角色检查生成状态，不按当前活动页面判断', () async {
    await owner('a');
    await message('m1');
    container.read(conversationSendingProvider('a').notifier).state = true;
    final port = container.read(manualCompactionProvider);
    await expectLater(
      port.prepare('a', onProgress: (_, __) {}, isCancelled: () => false),
      throwsA(
        isA<ContextCompactionException>().having(
          (e) => e.message,
          'message',
          contains('回复结束'),
        ),
      ),
    );
  });

  test('数据库提交故障：摘要与边界必须一起回滚', () async {
    await owner('a');
    await message('m1');
    final draft = await prepare();
    await database.customStatement(
      "CREATE TRIGGER fail_boundary BEFORE UPDATE OF context_start_message_id ON conversations BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END",
    );
    await expectLater(service.commit(draft, draft.summary), throwsA(anything));
    expect(await boundary('a'), isNull);
    expect(
      await database.customSelect('SELECT * FROM context_summaries').get(),
      isEmpty,
    );
  });

  test('自动压缩：默认272k触发，保留近期轮次并持久恢复，不开启新话题', () async {
    _Settings.maxTokens = 1000000;
    await owner('a');
    for (var i = 0; i < 120; i++) {
      await message(
        'long_$i',
        text: 'a' * 9200,
        at: i + 1,
        role: i.isEven ? 'user' : 'assistant',
      );
    }
    await message('latest', text: '继续当前任务', at: 121);
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final sender = container.read(chatSendServiceProvider);
    final history = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    expect(history, hasLength(121));
    final config = await sender.prepareApiConfig(
      conv: conv,
      history: history,
      userText: '继续当前任务',
    );
    expect(summary.seen, isNotNull);
    expect(jsonEncode(config.messages), contains('用户怕冷'));
    expect(jsonEncode(config.messages), contains('继续当前任务'));
    expect(await boundary('a'), isNull);
    expect(
      await container.read(chatHistoryStoreProvider).loadAllRawMessages('a'),
      hasLength(121),
    );
    final restored = await store.loadAuto('a', null, history);
    expect(restored, isNotNull);
    expect(restored!.sourceIds, isNot(contains('latest')));
    container.dispose();
    await database.close();
    await open();
    summary.seen = null;
    final again = await container
        .read(chatSendServiceProvider)
        .prepareApiConfig(conv: conv, history: history, userText: '继续当前任务');
    expect(summary.seen, isNull);
    expect(jsonEncode(again.messages), contains('用户怕冷'));
    expect(await store.loadAuto('a', null, history.take(3).toList()), isNull);
    await (database.update(database.messages)
          ..where((m) => m.id.equals('long_0')))
        .write(const db.MessagesCompanion(content: Value('修改了原始内容')));
    final edited = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    expect(await store.loadAuto('a', null, edited), isNull);
  });

  test('自动压缩后重新装配仍使用调用方指定的请求时间', () async {
    _Settings.maxTokens = 1000000;
    await owner('a');
    for (var i = 0; i < 120; i++) {
      await message(
        'long_$i',
        text: 'a' * 9200,
        at: i + 1,
        role: i.isEven ? 'user' : 'assistant',
      );
    }
    await message('latest', text: '继续当前任务', at: 121);
    container
        .read(pluginManagerProvider)
        .updatePlugin(TimeAwarenessPlugin(TimeAwarenessConfig()));
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final history = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');

    final config = await container
        .read(chatSendServiceProvider)
        .prepareApiConfig(
          conv: conv,
          history: history,
          userText: '继续当前任务',
          requestTime: DateTime(2031, 1, 2, 3, 4),
        );

    expect(summary.seen, isNotNull);
    expect(jsonEncode(config.messages), contains('2031-01-02 03:04:00'));
  });

  test('自动压缩保留量不计助手正文和文本块中的草稿', () async {
    await owner('a');
    await message('u1');
    await message('u2', at: 2);
    await message(
      'a2',
      role: 'assistant',
      text: '<thinking>${'x' * 10000}</thinking>答复',
      at: 3,
    );
    await message('u3', text: '继续', at: 4);
    final history = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    final i = history.indexWhere((m) => m.id == 'a2');
    history[i] = history[i].copyWith(
      blocks: [
        TextBlock(
          messageId: 'a2',
          content: '<comic_plan>${'x' * 10000}</comic_plan>答复',
        ),
      ],
    );
    await service.compactAuto(
      ownerId: 'a',
      topicBoundary: null,
      history: history,
      previous: null,
      keepOnlyLatestTurn: false,
      retainTokens: 1000,
    );
    expect(summary.seen!.messages.map((m) => m.id), ['u1']);
  });

  test('刚好到阈值必定压缩，低于阈值不压缩', () async {
    _Settings.maxTokens = 1000000;
    await owner('a');
    await message('old', text: 'a' * 40000);
    await message('reply', role: 'assistant', text: '收到', at: 2);
    await message('latest', text: '继续', at: 3);
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final history = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    final sender = container.read(chatSendServiceProvider);
    final before = await sender.prepareApiConfig(
      conv: conv,
      history: history,
      userText: '继续',
    );
    expect(summary.seen, isNull);
    final tokens =
        before.messages.fold<int>(
          0,
          (sum, m) =>
              sum +
              estimateMessageTokens(m) +
              estimateTokenCount(
                jsonEncode(
                  Map<String, dynamic>.of(m)
                    ..remove('content')
                    ..remove('role'),
                ),
              ),
        ) +
        estimateTokenCount(jsonEncode(before.tools ?? []));
    _Settings.window = ((tokens + 1) / .8).ceil();
    container.invalidate(appSettingsProvider);
    await sender.prepareApiConfig(conv: conv, history: history, userText: '继续');
    expect(summary.seen, isNull);
    _Settings.window = (tokens / .8).ceil();
    container.invalidate(appSettingsProvider);
    await sender.prepareApiConfig(conv: conv, history: history, userText: '继续');
    expect(summary.seen, isNotNull);
  });

  test('预设窗口只截断发送内容，自动压缩仍按本地模型窗口判断', () async {
    _Settings.maxTokens = 100000;
    _Settings.window = 50000;
    await owner('a');
    await message('old', text: '旧内容' * 1200);
    await message('reply', role: 'assistant', text: '收到', at: 2);
    await message('latest', text: '继续', at: 3);
    final preset = await container
        .read(sillyTavernPresetStoreProvider)
        .importSource(
          jsonEncode({
            'openai_max_context': 8000,
            'openai_max_tokens': 60000,
            'prompts': [
              {'identifier': 'worldInfoBefore', 'marker': true},
              {'identifier': 'chatHistory', 'marker': true},
            ],
            'prompt_order': [
              {
                'order': [
                  {'identifier': 'worldInfoBefore', 'enabled': true},
                  {'identifier': 'chatHistory', 'enabled': true},
                ],
              },
            ],
          }),
          sourceFileName: 'window.json',
        );
    await container
        .read(sillyTavernPresetStoreProvider)
        .importWorldBook(
          preset.id,
          '{"entries":{"0":{"constant":true,"content":"世界书内容保留","position":0}}}',
          'world.json',
        );
    await (database.update(database.conversations)
          ..where((c) => c.id.equals('a')))
        .write(db.ConversationsCompanion(recipeId: Value(preset.id)));
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final sender = container.read(chatSendServiceProvider);
    final preview = await sender.previewContext(conv);
    expect(preview.inputLimit, 40000);
    expect(preview.notes, contains(contains('最大输出超过')));
    expect(preview.notes, contains(contains('聊天记录中仍保留')));
    expect(jsonEncode(preview.messages), isNot(contains('旧内容')));
    expect(jsonEncode(preview.messages), contains('继续'));
    expect(jsonEncode(preview.messages), contains('世界书内容保留'));
    final history = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    final config = await sender.prepareApiConfig(
      conv: conv,
      history: history,
      userText: '继续',
    );
    expect(summary.seen, isNull);
    expect(jsonEncode(config.messages), isNot(contains('旧内容')));
    expect(history, hasLength(3));
  });

  test('完整历史达到本地阈值时先压缩，即使预设滑窗很小', () async {
    _Settings.maxTokens = 100000;
    _Settings.window = 10000;
    await owner('a');
    await message('old', text: 'a' * 40000);
    await message('reply', role: 'assistant', text: '收到', at: 2);
    await message('latest', text: '继续', at: 3);
    final preset = await container
        .read(sillyTavernPresetStoreProvider)
        .importSource(
          jsonEncode({
            'openai_max_context': 3000,
            'openai_max_tokens': 500,
            'prompts': [
              {'identifier': 'chatHistory', 'marker': true},
            ],
            'prompt_order': [
              {
                'order': [
                  {'identifier': 'chatHistory', 'enabled': true},
                ],
              },
            ],
          }),
          sourceFileName: 'compact-window.json',
        );
    await (database.update(database.conversations)
          ..where((c) => c.id.equals('a')))
        .write(db.ConversationsCompanion(recipeId: Value(preset.id)));
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final sender = container.read(chatSendServiceProvider);
    final preview = await sender.previewContext(conv);
    expect(preview.inputLimit, 7952);
    expect(preview.notes, contains(contains('自动压缩')));
    final history = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    await sender.prepareApiConfig(conv: conv, history: history, userText: '继续');
    expect(summary.seen, isNotNull);
    expect(summary.seen!.messages.map((m) => m.id), contains('old'));
  });

  test('联系人上下文预览只读：超阈值不压缩，边界缺摘要只提示不补整理', () async {
    _Settings.maxTokens = 1000000;
    _Settings.window = 1000;
    await owner('a', start: 'm2');
    await message('m1');
    await message('m2', role: 'assistant', at: 2);
    await message('m3', text: 'a' * 40000, at: 3);
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final preview = await container
        .read(chatSendServiceProvider)
        .previewContext(conv);

    expect(summary.seen, isNull);
    expect(
      await container.read(contextSummaryStoreProvider).manualFor('a', 'm2'),
      isNull,
    );
    expect(preview.notes, contains(contains('还没有摘要')));
    expect(preview.notes, contains(contains('自动压缩')));
    expect(preview.inputTokens, greaterThanOrEqualTo(preview.inputLimit));
    expect(preview.messageTokens, hasLength(preview.messages.length));
    expect(preview.messages.first['role'], 'system');
    expect(preview.sources.first.label, '角色人设');
    expect(
      preview.messages.map((m) => '${m['content']}'),
      isNot(contains(contains('m1：'))),
    );
    expect('${preview.messages.last['content']}', contains('a' * 100));
  });

  test('没指定模型时（如上下文预览）按会话自己选的模型装配', () async {
    await owner('a');
    const other = 'openai:session-only-model';
    _Settings.extraModel = other;
    container.invalidate(appSettingsProvider);
    final settings = await container.read(appSettingsProvider.future);
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    ).copyWith(sessionProvider: other);

    final config = await container
        .read(chatSendServiceProvider)
        .prepareApiConfig(conv: conv, history: const [], userText: null);

    expect(config.modelFullId, settings.toModelFullId(other));
  });

  test('请求使用全局插件提示词，而不是插件配置里的旧副本', () async {
    await owner('a');
    await message('m1', text: '在吗');
    // 插件配置里的旧模板不能再生效。
    container
        .read(pluginManagerProvider)
        .updatePlugin(
          TimeAwarenessPlugin(
            TimeAwarenessConfig(currentTimePromptTemplate: '旧配置时间 {datetime}'),
          ),
        );
    await container
        .read(pluginPromptsProvider.notifier)
        .setText(PluginPromptSlot.currentTime, '全局时间说明 {datetime}');
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final preview = await container
        .read(chatSendServiceProvider)
        .previewContext(conv);
    expect(
      preview.messages.map((m) => '${m['content']}').join('\n'),
      allOf(contains('全局时间说明 '), isNot(contains('旧配置时间'))),
    );
  });

  test('自动压缩失败阻止请求，不丢弃原文或切换话题', () async {
    _Settings.maxTokens = 5000;
    await owner('a');
    await message('old', text: 'a' * 20000);
    await message('answer', role: 'assistant', text: '好的', at: 2);
    await message('latest', text: '继续', at: 3);
    summary.fail = true;
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final history = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    await expectLater(
      container
          .read(chatSendServiceProvider)
          .prepareApiConfig(conv: conv, history: history, userText: '继续'),
      throwsStateError,
    );
    expect(summary.seen, isNotNull);
    expect(await store.loadAuto('a', null, history), isNull);
    expect(await boundary('a'), isNull);
    expect(
      await container.read(chatHistoryStoreProvider).loadAllRawMessages('a'),
      hasLength(3),
    );
  });

  for (final preset in [false, true]) {
    test('真实请求装配 ${preset ? "酒馆" : "普通"}：最新角色卡和内容摘要存在，旧原文不在', () async {
      await owner('a');
      await message('m1');
      final draft = await prepare();
      await service.commit(draft, draft.summary);
      if (preset) {
        final p = await container
            .read(sillyTavernPresetStoreProvider)
            .importSource(
              jsonEncode({
                'name': '新格式预设',
                'prompts': [
                  {
                    'identifier': 'main',
                    'role': 'system',
                    'content': '最新预设：只用简短聊天',
                  },
                  {'identifier': 'charDescription', 'marker': true},
                  {'identifier': 'chatHistory', 'marker': true},
                ],
                'prompt_order': [
                  {
                    'order': [
                      {'identifier': 'main', 'enabled': true},
                      {'identifier': 'charDescription', 'enabled': true},
                      {'identifier': 'chatHistory', 'enabled': true},
                    ],
                  },
                ],
              }),
              sourceFileName: 'test.json',
            );
        await (database.update(database.conversations)
              ..where((c) => c.id.equals('a')))
            .write(db.ConversationsCompanion(recipeId: Value(p.id)));
      }
      final conv = ConversationConverter.fromDb(
        (await container.read(conversationRepositoryProvider).getById('a'))!,
      );
      final user = Message(
        id: 'm2',
        role: 'user',
        content: '还记得我们约好的事吗',
        createdAt: DateTime.now(),
      );
      final sender = container.read(chatSendServiceProvider);
      final history = await sender.prepareHistoryFromStore(
        conv: conv,
        userMsg: user,
      );
      final config = await sender.prepareApiConfig(
        conv: conv,
        history: history,
        userText: user.content,
      );
      final text = jsonEncode(config.messages);
      expect(text, contains('用户怕冷'));
      expect(text, contains('最新角色卡：只用简短聊天，不用旁白。'));
      expect(text, isNot(contains('m1：旧格式旁白示例')));
      expect(history.map((m) => m.id), ['m2']);
      if (preset) expect(text, contains('最新预设'));
    });
  }

  test('重放压缩范围内的旧消息，不把之后才总结的内容带回旧轮次', () async {
    await owner('a');
    await message('m1');
    await message('m2', at: 2);
    final draft = await prepare();
    await service.commit(draft, '之后才知道的出行约定');
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final config = await container
        .read(chatSendServiceProvider)
        .prepareApiConfig(
          conv: conv,
          history: [
            Message(
              id: 'm1',
              role: 'user',
              content: '重放旧问题',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1),
            ),
          ],
          userText: '重放旧问题',
        );
    expect(jsonEncode(config.messages), isNot(contains('之后才知道的出行约定')));
  });

  test('摘要与角色卡挤满预算时，不能静默丢掉当前用户消息后发送', () async {
    await owner('a');
    await message('m1');
    final draft = await prepare();
    await service.commit(draft, draft.summary);
    _Settings.maxTokens = 2200;
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final user = Message(
      id: 'm2',
      role: 'user',
      content: '当前问题必须保留',
      createdAt: DateTime.now(),
    );
    final sender = container.read(chatSendServiceProvider);
    final history = await sender.prepareHistoryFromStore(
      conv: conv,
      userMsg: user,
    );
    await expectLater(
      sender.prepareApiConfig(
        conv: conv,
        history: history,
        userText: user.content,
      ),
      throwsA(isA<ContextCompactionException>()),
    );
  });

  test('真实后台运行壳：无角色卡/工具，长单条分块完整，JSON 输出校验', () async {
    await owner('a');
    final text = '原始正文😀' * 1500;
    await message('m1', text: text);
    final requests = <ApiConfig>[];
    final agent = BackgroundAgentService(
      loadRecentMessages: (_, __) async => throw StateError('不得回退缓存'),
      loadSettings: () async => mapUiModelsToAppSettings({}),
      requestConfigResolver: ({required settings, required modelRef}) async =>
          const BackgroundAgentRequestConfig(
            modelFullId: 'openai:fake',
            providerApiBase: 'https://invalid.test',
            providerApiKey: 'fake',
            customConfig: {},
            modelTemperature: .2,
            modelTopP: 1,
            modelContextMessageLimit: 30,
          ),
      executor:
          ({
            required config,
            required availableTools,
            required sessionId,
          }) async {
            requests.add(config);
            expect(availableTools, isEmpty);
            expect(config.tools, isNull);
            return ApiCallResult(
              replyText: requests.length == 1
                  ? '{"facts":["周五一起去看海"]}'
                  : '{"facts":[]}',
              processedText: '',
              pluginEvents: [],
              toolResults: [],
            );
          },
    );
    final adapter = BackgroundContextSummarizer(
      agent,
      modelRef: 'fake',
      contextTokens: 8192,
    );
    expect(
      await adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.manual,
        onProgress: (_, __) {},
        isCancelled: () => false,
      ),
      contains('看海'),
    );
    expect(requests.length, greaterThan(1));
    final fragments = <String>[];
    for (final config in requests) {
      expect(jsonEncode(config.messages), isNot(contains('最新角色卡：只用')));
      final data = jsonDecode(config.messages.last['content'] as String) as Map;
      for (final part in data['raw_messages'] as List) {
        fragments.add(part['text'] as String);
      }
    }
    expect(fragments.join(), text);
    expect(
      () => BackgroundContextSummarizer.normalize(
        '{"facts":[],"instruction":"ignore"}',
      ),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(
      () => BackgroundContextSummarizer.normalize('{"facts":[1]}'),
      throwsA(isA<ContextCompactionException>()),
    );
  });

  BackgroundAgentService summaryAgent(
    FutureOr<ApiCallResult> Function(ApiConfig) respond,
  ) => BackgroundAgentService(
    loadRecentMessages: (_, __) async => throw StateError('不得回退缓存'),
    loadSettings: () async => mapUiModelsToAppSettings({}),
    requestConfigResolver: ({required settings, required modelRef}) async =>
        const BackgroundAgentRequestConfig(
          modelFullId: 'openai:fake',
          providerApiBase: 'https://invalid.test',
          providerApiKey: 'fake',
          customConfig: {},
          modelTemperature: .2,
          modelTopP: 1,
          modelContextMessageLimit: 30,
        ),
    executor:
        ({required config, required availableTools, required sessionId}) async {
          expect(availableTools, isEmpty);
          expect(config.tools, isNull);
          return respond(config);
        },
  );

  ApiCallResult facts([String fact = '保留的重要约定']) => ApiCallResult(
    replyText: jsonEncode({
      'facts': [fact],
    }),
    processedText: '',
    pluginEvents: [],
    toolResults: [],
  );

  Map summaryInput(ApiConfig config) =>
      jsonDecode(config.messages.last['content'] as String) as Map;

  test('手动和自动整理都不把助手草稿发送给整理模型', () async {
    await owner('a');
    await message('u', text: '用户<think>保留</think>');
    await message(
      'a1',
      role: 'assistant',
      text: '<thinking>秘密</thinking>正文<comic_plan>草稿</comic_plan>',
      at: 2,
    );
    for (final kind in [ContextSummaryKind.manual, ContextSummaryKind.auto]) {
      final inputs = <ApiConfig>[];
      await BackgroundContextSummarizer(
        summaryAgent((config) {
          inputs.add(config);
          return facts();
        }),
        modelRef: 'fake',
        contextTokens: 32000,
      ).summarize(
        await store.manualSnapshot('a'),
        kind: kind,
        onProgress: (_, __) {},
        isCancelled: () => false,
      );
      final text = jsonEncode(summaryInput(inputs.first)['raw_messages']);
      expect(text, contains('正文'));
      expect(text, contains('用户<think>保留</think>'));
      expect(text, isNot(contains('秘密')));
      expect(text, isNot(contains('草稿')));
    }
  });

  for (final window in [200000, 1000000]) {
    test('模型预算 $window：超过旧32块的历史一次压缩，完整且预留输出', () async {
      final text = '历史事实😀\n' * (window == 200000 ? 10000 : 50000);
      await owner('a');
      await message('long', text: text);
      final requests = <ApiConfig>[];
      final adapter = BackgroundContextSummarizer(
        summaryAgent((config) {
          requests.add(config);
          return facts();
        }),
        modelRef: 'fake',
        contextTokens: window,
      );
      await adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.manual,
        onProgress: (_, __) {},
        isCancelled: () => false,
      );
      expect(requests, hasLength(1));
      final config = requests.single;
      expect(
        (summaryInput(config)['raw_messages'] as List)
            .map((part) => part['text'])
            .join(),
        text,
      );
      final output = config.providerRequestOptions?.maxOutputTokens;
      expect(output, isNotNull);
      expect(
        config.messages.fold<int>(0, (n, m) => n + estimateMessageTokens(m)) +
            output!,
        lessThanOrEqualTo(window),
      );
    });
  }

  test('小窗口历史超过32批仍完整整理，前批摘要进入下一批', () async {
    await owner('a');
    final text = '长历史😀\u0001"\\\n' * 20000;
    await message('long', text: text);
    var calls = 0;
    final received = StringBuffer();
    final progress = <(int, int)>[];
    final adapter = BackgroundContextSummarizer(
      summaryAgent((config) {
        final data = summaryInput(config);
        expect(data['previous_facts'], calls == 0 ? '' : '- 第$calls批的重要约定');
        for (final part in data['raw_messages'] as List) {
          expect(part['id'], 'long');
          expect(part['role'], 'user');
          final value = part['text'] as String;
          expect(utf8.decode(utf8.encode(value)), value);
          received.write(value);
        }
        final output = config.providerRequestOptions?.maxOutputTokens;
        expect(output, isNotNull);
        expect(
          config.messages.fold<int>(0, (n, m) => n + estimateMessageTokens(m)) +
              output!,
          lessThanOrEqualTo(8192),
        );
        return facts('第${++calls}批的重要约定');
      }),
      modelRef: 'fake',
      contextTokens: 8192,
    );
    await adapter.summarize(
      await store.manualSnapshot('a'),
      kind: ContextSummaryKind.manual,
      onProgress: (a, b) => progress.add((a, b)),
      isCancelled: () => false,
    );
    expect(calls, greaterThan(32));
    expect(received.toString(), text);
    expect(progress.last, (calls, calls));
  });

  test('服务端明确上下文超限才缩小重试，成功材料不丢失', () async {
    await owner('a');
    final text = '完整的历史内容😀' * 10000;
    await message('long', text: text);
    var attempts = 0;
    final received = StringBuffer();
    final adapter = BackgroundContextSummarizer(
      summaryAgent((config) {
        attempts++;
        if ((config.messages.last['content'] as String).length > 40000) {
          throw Exception('HTTP 400 context_length_exceeded');
        }
        for (final part in summaryInput(config)['raw_messages'] as List) {
          received.write(part['text']);
        }
        return facts();
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    await adapter.summarize(
      await store.manualSnapshot('a'),
      kind: ContextSummaryKind.manual,
      onProgress: (_, __) {},
      isCancelled: () => false,
    );
    expect(attempts, greaterThan(1));
    expect(received.toString(), text);
  });

  test('自动压缩按角色模式选模板：聊天模式记关系与场景，工具模式记任务进度', () async {
    await owner('a');
    await message('m');
    ApiCallResult reply(Map<String, List<String>> sections) => ApiCallResult(
      replyText: jsonEncode({'summary': sections}),
      processedText: '',
      pluginEvents: [],
      toolResults: [],
    );
    Future<(String, String)> run({
      required bool companion,
      required Map<String, List<String>> sections,
    }) async {
      late String prompt;
      final adapter = BackgroundContextSummarizer(
        summaryAgent((config) {
          prompt = jsonEncode(config.messages);
          return reply(sections);
        }),
        modelRef: 'fake',
        contextTokens: 200000,
        isCompanion: (ownerId) async {
          expect(ownerId, 'a');
          return companion;
        },
      );
      final summary = await adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.auto,
        onProgress: (_, __) {},
        isCancelled: () => false,
      );
      return (prompt, summary);
    }

    final (companionPrompt, companionSummary) = await run(
      companion: true,
      sections: {
        'relationship': ['刚和好，她还有点别扭'],
        'scene': ['在海边散步，天快黑了'],
        'promises': ['答应周五一起看日落'],
        'background': [],
        'details': [],
      },
    );
    expect(companionPrompt, contains('陪伴聊天的上下文压缩器'));
    expect(companionPrompt, isNot(contains('未完成事项')));
    expect(companionSummary, contains('## 关系与情绪\n- 刚和好，她还有点别扭'));
    expect(companionSummary, contains('## 当前场景\n- 在海边散步，天快黑了'));
    expect(companionSummary, contains('## 约定与称呼\n- 答应周五一起看日落'));

    final (taskPrompt, taskSummary) = await run(
      companion: false,
      sections: {
        'background': [],
        'preferences': [],
        'progress': ['角色卡改完了开场白'],
        'pending': ['还要调语音'],
        'details': [],
      },
    );
    expect(taskPrompt, contains('聊天上下文压缩器'));
    expect(taskPrompt, isNot(contains('陪伴聊天')));
    expect(taskSummary, contains('## 未完成事项\n- 还要调语音'));

    // 两种结构互不放行：陪伴模板下交回任务结构算格式错误。
    expect(
      () => run(
        companion: true,
        sections: {
          'background': [],
          'preferences': [],
          'progress': ['x'],
          'pending': [],
          'details': [],
        },
      ),
      throwsA(isA<ContextCompactionException>()),
    );
  });

  test('压缩给思考留足输出额度；只有思考没有正文时明确报错', () async {
    await owner('a');
    await message('m');
    Future<int?> outputFor(int contextTokens) async {
      int? max;
      await BackgroundContextSummarizer(
        summaryAgent((config) {
          max = config.providerRequestOptions?.maxOutputTokens;
          return facts();
        }),
        modelRef: 'fake',
        contextTokens: contextTokens,
      ).summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.auto,
        onProgress: (_, __) {},
        isCancelled: () => false,
      );
      return max;
    }

    expect(await outputFor(8192), 2048);
    expect(await outputFor(32000), 8000);
    expect(await outputFor(128000), 32000);
    expect(await outputFor(1000000), 128000);

    final thinkingOnly = BackgroundContextSummarizer(
      summaryAgent(
        (_) => const ApiCallResult(
          replyText: '',
          processedText: '',
          pluginEvents: [],
          toolResults: [],
        ),
      ),
      modelRef: 'fake',
      contextTokens: 32000,
    );
    await expectLater(
      thinkingOnly.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.auto,
        onProgress: (_, __) {},
        isCancelled: () => false,
      ),
      throwsA(
        isA<ContextCompactionException>().having(
          (e) => e.message,
          'message',
          contains('没有写出摘要'),
        ),
      ),
    );
  });

  test('服务商拒绝过大的输出额度时逐次减半重试，不低于 8192', () async {
    await owner('a');
    await message('m');
    final maxes = <int?>[];
    final adapter = BackgroundContextSummarizer(
      summaryAgent((config) {
        maxes.add(config.providerRequestOptions?.maxOutputTokens);
        if (maxes.length < 3) {
          throw StateError(
            'HTTP 400: max_tokens: ${maxes.last} > 8192, which is the maximum allowed',
          );
        }
        return facts();
      }),
      modelRef: 'fake',
      contextTokens: 128000,
    );
    expect(
      await adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.auto,
        onProgress: (_, __) {},
        isCancelled: () => false,
      ),
      contains('保留的重要约定'),
    );
    expect(maxes, [32000, 16000, 8192]);
  });

  test('格式修复器带回 invalid_summary 外壳时剥掉外壳', () async {
    await owner('a');
    await message('m');
    final contents = <String>[];
    final adapter = BackgroundContextSummarizer(
      summaryAgent((config) {
        contents.add(config.messages.last['content'] as String);
        return ApiCallResult(
          replyText: contents.length == 1
              ? '{"facts":["周五看海",]}'
              : jsonEncode({'invalid_summary': '{"facts":["周五看海"]}'}),
          processedText: '',
          pluginEvents: [],
          toolResults: [],
        );
      }),
      modelRef: 'fake',
      contextTokens: 32000,
    );
    expect(
      await adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.manual,
        onProgress: (_, __) {},
        isCancelled: () => false,
      ),
      '- 周五看海',
    );
    expect(contents, hasLength(2));
  });

  test('进度回调中取消时不再发模型请求', () async {
    await owner('a');
    await message('m');
    var cancelled = false;
    var calls = 0;
    final adapter = BackgroundContextSummarizer(
      summaryAgent((_) {
        calls++;
        return facts();
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    await expectLater(
      adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.manual,
        onProgress: (_, __) => cancelled = true,
        isCancelled: () => cancelled,
      ),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(calls, 0);
  });

  test('鉴权失败不通过拆分重复请求，原话题不变', () async {
    await owner('a');
    await message('m');
    var calls = 0;
    final adapter = BackgroundContextSummarizer(
      summaryAgent((_) {
        calls++;
        throw StateError('HTTP 401 unauthorized');
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    await expectLater(
      adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.manual,
        onProgress: (_, __) {},
        isCancelled: () => false,
      ),
      throwsA(isA<StateError>()),
    );
    expect(calls, 1);
    expect(
      (await database.select(database.conversations).getSingle())
          .contextStartMessageId,
      isNull,
    );
  });

  test('超限缩小重试有上限，不能无限请求', () async {
    await owner('a');
    await message('m', text: '历史' * 10000);
    var calls = 0;
    final adapter = BackgroundContextSummarizer(
      summaryAgent((_) {
        calls++;
        throw StateError('HTTP 400 prompt is too long');
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    await expectLater(
      adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.manual,
        onProgress: (_, __) {},
        isCancelled: () => false,
      ),
      throwsA(isA<StateError>()),
    );
    expect(calls, 5);
  });

  test('摘要含大量转义时重新预算，不丢失未整理尾部', () async {
    await owner('a');
    final text = '完整消息' * 4000;
    await message('m', text: text);
    var calls = 0;
    final received = StringBuffer();
    // 仍符合摘要限制，但 JSON 编码显著增长。
    final summary = '\u0001' * 800;
    final adapter = BackgroundContextSummarizer(
      summaryAgent((config) {
        final data = summaryInput(config);
        if (calls > 0) expect(data['previous_facts'], '- $summary');
        expect(
          config.messages.fold<int>(0, (n, m) => n + estimateMessageTokens(m)) +
              config.providerRequestOptions!.maxOutputTokens!,
          lessThanOrEqualTo(8192),
        );
        for (final part in data['raw_messages'] as List) {
          received.write(part['text']);
        }
        calls++;
        return facts(summary);
      }),
      modelRef: 'fake',
      contextTokens: 8192,
    );
    await adapter.summarize(
      await store.manualSnapshot('a'),
      kind: ContextSummaryKind.manual,
      onProgress: (_, __) {},
      isCancelled: () => false,
    );
    expect(calls, greaterThan(1));
    expect(received.toString(), text);
  });

  test('请求期间取消，丢弃迟到结果且不整理下一批', () async {
    await owner('a');
    await message('m', text: '长历史' * 10000);
    var calls = 0;
    var cancelled = false;
    final started = Completer<void>();
    final response = Completer<ApiCallResult>();
    final adapter = BackgroundContextSummarizer(
      summaryAgent((_) {
        calls++;
        started.complete();
        return response.future;
      }),
      modelRef: 'fake',
      contextTokens: 8192,
    );
    final future = adapter.summarize(
      await store.manualSnapshot('a'),
      kind: ContextSummaryKind.manual,
      onProgress: (_, __) {},
      isCancelled: () => cancelled,
    );
    final check = expectLater(
      future,
      throwsA(isA<ContextCompactionException>()),
    );
    await started.future;
    cancelled = true;
    response.complete(facts());
    await check;
    expect(calls, 1);
  });

  test('无效摘要里的超限字样不触发供应商重试', () async {
    await owner('a');
    await message('m');
    var calls = 0;
    final adapter = BackgroundContextSummarizer(
      summaryAgent((_) {
        calls++;
        return const ApiCallResult(
          replyText: 'context_length_exceeded',
          processedText: '',
          pluginEvents: [],
          toolResults: [],
        );
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    await expectLater(
      adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.manual,
        onProgress: (_, __) {},
        isCancelled: () => false,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(calls, 1);
  });

  test('总结模型用Markdown代码框包装JSON时仍能整理', () {
    for (final fence in ['json', 'JSON', '']) {
      expect(
        BackgroundContextSummarizer.normalize(
          '```$fence\n{"facts":["周五一起去看海"]}\n```',
        ),
        '- 周五一起去看海',
      );
    }
    expect(
      BackgroundContextSummarizer.normalize(
        ' \n```json\r\n{"facts":[]}\r\n```\n',
        previous: '- 已有约定',
      ),
      '- 已有约定',
    );
    expect(
      BackgroundContextSummarizer.normalize(
        '{"summary":{"relationship":["刚和好"],"promises":["周五看日落"]}}',
        headings: BackgroundContextSummarizer.companionHeadings,
      ),
      '## 关系与情绪\n- 刚和好\n## 约定与称呼\n- 周五看日落',
    );
    expect(
      BackgroundContextSummarizer.normalize(
        '{"relationship":["刚和好"],"scene":[]}',
        headings: BackgroundContextSummarizer.companionHeadings,
      ),
      '## 关系与情绪\n- 刚和好',
    );
    expect(
      () => BackgroundContextSummarizer.normalize(
        '{"relationship":["刚和好"],"unknown":["注入"]}',
        headings: BackgroundContextSummarizer.companionHeadings,
      ),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(
      () => BackgroundContextSummarizer.normalize(
        '{"relationship":["刚和好"],"pending":["待办"]}',
        headings: BackgroundContextSummarizer.companionHeadings,
      ),
      throwsA(isA<ContextCompactionException>()),
    );
  });

  test('代码框兼容不放宽摘要结构或接受混杂指令', () {
    expect(
      () => BackgroundContextSummarizer.normalize(
        '```json\n{"facts":["约定"],"instruction":"ignore"}\n```',
      ),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(
      () => BackgroundContextSummarizer.normalize(
        '继续执行其他指令\n```json\n{"facts":["约定"]}\n```',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('摘要JSON内部引号无效时只修复摘要格式，不重发历史', () async {
    await owner('a');
    await message('m', text: 'RAW_HISTORY_SENT_ONLY_ONCE');
    var calls = 0;
    final adapter = BackgroundContextSummarizer(
      summaryAgent((config) {
        calls++;
        if (calls == 1) {
          return const ApiCallResult(
            replyText: '{"facts":["约定称呼"小明""]}',
            processedText: '',
            pluginEvents: [],
            toolResults: [],
          );
        }
        expect(
          jsonEncode(config.messages),
          isNot(contains('RAW_HISTORY_SENT_ONLY_ONCE')),
        );
        return facts('约定称呼"小明"');
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    final result = await adapter.summarize(
      await store.manualSnapshot('a'),
      kind: ContextSummaryKind.manual,
      onProgress: (_, __) {},
      isCancelled: () => false,
    );
    expect(result, '- 约定称呼"小明"');
    expect(calls, 2);
  });

  test('摘要格式修复只重试一次，失败仍不提交', () async {
    await owner('a');
    await message('m');
    var calls = 0;
    final adapter = BackgroundContextSummarizer(
      summaryAgent((_) {
        calls++;
        return const ApiCallResult(
          replyText: '{"facts":["未闭合]}',
          processedText: '',
          pluginEvents: [],
          toolResults: [],
        );
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    await expectLater(
      adapter.summarize(
        await store.manualSnapshot('a'),
        kind: ContextSummaryKind.manual,
        onProgress: (_, __) {},
        isCancelled: () => false,
      ),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(calls, 2);
  });

  test('无块消息单独补挂内部生图隐藏块后摘要指纹不变', () async {
    await owner('a');
    await message('m', text: '原始正文');
    final before = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    expect(before.single.blocks, isNull);
    final digest = contextSourceDigest(before);
    await database
        .into(database.messageBlocks)
        .insert(
          MessageBlockConverter.toCompanion(
            ToolBlock(
              id: 'hidden',
              messageId: 'm',
              toolName: 'image_context',
              result: {'error': 'failed'},
            ),
            'm',
            0,
          ),
        );
    final after = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    expect(after.single.blocks, hasLength(1));
    expect(contextSourceDigest(after), digest);
    expect(
      contextSourceDigest([
        before.single.copyWith(blocks: const <MessageBlock>[]),
      ]),
      digest,
    );
  });

  test('真实数据库内容块重复读取不应使摘要来源变化，实际块编辑仍拒绝', () async {
    await owner('a');
    await message('m', text: '原始正文');
    final block = <String, dynamic>{
      'id': 'b',
      'messageId': 'm',
      'type': 'mainText',
      'status': 'success',
      'content': '原始正文',
      'createdAt': '2000-01-01T00:00:00.000',
    };
    await database.customStatement(
      '''
      INSERT INTO message_blocks
      (id,message_id,type,status,data,sort_order,created_at)
      VALUES (?,?,?,?,?,?,?)
    ''',
      ['b', 'm', 'mainText', 'success', jsonEncode(block), 0, 1],
    );
    final first = await store.manualSnapshot('a');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = await store.manualSnapshot('a');
    expect(second.revision, first.revision);
    final result = await store.commitManual(first, '- 保留原始事实');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(
      (await store.manualFor('a', result.boundaryId))?.summary,
      '- 保留原始事实',
    );
    await store.undoManual('a');
    final stale = await store.manualSnapshot('a');
    block['content'] = '实际修改后的正文';
    await database.customStatement(
      'UPDATE message_blocks SET data=? WHERE id=?',
      [jsonEncode(block), 'b'],
    );
    await expectLater(
      store.commitManual(stale, '- 过期摘要'),
      throwsA(isA<ContextCompactionException>()),
    );
  });
}

class _ManualSessionPort implements ManualCompactionPort {
  final pending = <String, Completer<ManualCompactionDraft>>{};
  final cancelled = <String, bool Function()>{};
  final progress = <String, void Function(int, int)>{};
  int prepareCalls = 0;
  Future<ContextSummary?> Function(String)? onCurrent;
  Future<ContextSummary> Function(ManualCompactionDraft, String)? onCommit;
  Future<void> Function(String)? onUndo;

  @override
  Future<ManualCompactionDraft> prepare(
    String ownerId, {
    required void Function(int, int) onProgress,
    required bool Function() isCancelled,
  }) {
    prepareCalls++;
    cancelled[ownerId] = isCancelled;
    progress[ownerId] = onProgress;
    return (pending[ownerId] = Completer<ManualCompactionDraft>()).future;
  }

  @override
  Future<ContextSummary?> current(String ownerId) async =>
      onCurrent == null ? null : await onCurrent!(ownerId);

  @override
  Future<ContextSummary> commit(ManualCompactionDraft draft, String summary) =>
      onCommit!(draft, summary);

  @override
  Future<void> undo(String ownerId) async => onUndo?.call(ownerId);
}

ManualCompactionDraft _sessionDraft([String ownerId = 'a']) =>
    ManualCompactionDraft(
      snapshot: ContextSnapshot(
        ownerId: ownerId,
        previousBoundaryId: null,
        allMessages: const [],
        messages: const [],
        previous: null,
      ),
      summary: '- $ownerId 的摘要',
    );

ContextSummary _sessionSummary([String ownerId = 'a', String text = '- 已保存']) =>
    ContextSummary(
      id: 'saved-$ownerId',
      ownerId: ownerId,
      kind: ContextSummaryKind.manual,
      boundaryId: 'boundary-$ownerId',
      topicBoundary: null,
      summary: text,
      sourceIds: const [],
      sourceDigest: '',
      createdAt: DateTime(2026),
    );

void manualCompactionSessionTests() {
  group('手动压缩应用层会话', () {
    late _ManualSessionPort port;
    late ManualCompactionSessionStore sessions;
    late List<String> changes;

    setUp(() {
      port = _ManualSessionPort();
      sessions = ManualCompactionSessionStore.fromPort(port);
      changes = [];
      sessions.addListener(changes.add);
    });
    tearDown(() => sessions.dispose());

    test('构造与同步读取状态不解析端口，空值可显式清除', () async {
      var resolved = 0;
      final lazy = ManualCompactionSessionStore(() {
        resolved++;
        return port;
      });
      addTearDown(lazy.dispose);
      expect(lazy.stateOf('a').draft, isNull);
      expect(lazy.stateOf('b').preparing, isFalse);
      expect(resolved, 0);
      await lazy.loadCurrent('a');
      expect(resolved, 1);

      final state = ManualCompactionSessionState(
        currentSummary: _sessionSummary(),
        draft: _sessionDraft(),
        error: '错误',
        notice: const ManualCompactionNotice(
          id: 1,
          message: '完成',
          isError: false,
        ),
      );
      expect(state.copyWith().currentSummary, same(state.currentSummary));
      final cleared = state.copyWith(
        currentSummary: null,
        draft: null,
        error: null,
        notice: null,
      );
      expect(cleared.currentSummary, isNull);
      expect(cleared.draft, isNull);
      expect(cleared.error, isNull);
      expect(cleared.notice, isNull);
    });

    test('后台继续整理与更新进度，成功通知只消费一次', () async {
      final work = sessions.prepare('a');
      expect(sessions.stateOf('a').progress, '正在读取原始聊天…');
      await sessions.prepare('a');
      expect(port.prepareCalls, 1);
      sessions.enterBackground('a');
      expect(sessions.stateOf('a').backgrounded, isTrue);
      expect(port.cancelled['a']!(), isFalse);
      port.progress['a']!(2, 3);
      expect(sessions.stateOf('a').progress, '整理内容 2 / 3');
      expect(changes, ['a', 'a', 'a']);
      final draft = _sessionDraft();
      port.pending['a']!.complete(draft);
      await work;
      final state = sessions.stateOf('a');
      expect(state.draft, same(draft));
      expect(state.draftText, draft.summary);
      expect(state.preparing, isFalse);
      expect(state.backgrounded, isFalse);
      expect(state.progress, '');
      expect(state.error, isNull);
      final notice = state.notice!;
      expect(notice.message, '摘要已整理好，打开「更多 → 压缩上下文」即可确认开启。');
      expect(notice.isError, isFalse);
      sessions.clearNotice('a', notice.id + 1);
      expect(sessions.stateOf('a').notice, same(notice));
      sessions.clearNotice('a', notice.id);
      final count = changes.length;
      sessions.clearNotice('a', notice.id);
      expect(sessions.stateOf('a').notice, isNull);
      expect(changes, hasLength(count));
    });

    test('前台完成与后台返回前台后完成都不发通知', () async {
      for (final backgroundFirst in [false, true]) {
        final work = sessions.prepare('a');
        if (backgroundFirst) {
          sessions.enterBackground('a');
          sessions.markForeground('a');
          expect(port.cancelled['a']!(), isFalse);
        }
        port.pending['a']!.complete(_sessionDraft());
        await work;
        expect(sessions.stateOf('a').notice, isNull);
        expect(sessions.stateOf('a').draft, isNotNull);
      }
    });

    test('仅后台失败发错误通知，通知编号递增，回前台清除通知', () async {
      var lastId = 0;
      for (final failure in [
        const ContextCompactionException('原始聊天发生变化，请重新整理。'),
        StateError('network unavailable'),
      ]) {
        for (final backgrounded in [false, true]) {
          final work = sessions.prepare('a');
          if (backgrounded) sessions.enterBackground('a');
          port.pending['a']!.completeError(failure);
          await work;
          final state = sessions.stateOf('a');
          final message = failure is ContextCompactionException
              ? failure.message
              : '整理或保存失败，请检查模型/网络后重试。确认前原话题不会改变。';
          expect(state.error, message);
          expect(state.preparing, isFalse);
          expect(state.backgrounded, isFalse);
          expect(state.progress, '');
          if (backgrounded) {
            expect(state.notice!.message, message);
            expect(state.notice!.isError, isTrue);
            expect(state.notice!.id, greaterThan(lastId));
            lastId = state.notice!.id;
            sessions.markForeground('a');
            expect(sessions.stateOf('a').notice, isNull);
          } else {
            expect(state.notice, isNull);
          }
        }
      }
    });

    test('取消立即生效，迟到进度、成功及异常都不覆盖新一轮', () async {
      for (final failLate in [false, true]) {
        final oldWork = sessions.prepare('a');
        final oldResult = port.pending['a']!;
        final oldProgress = port.progress['a']!;
        final oldCancelled = port.cancelled['a']!;
        sessions.enterBackground('a');
        sessions.cancelPrepare('a');
        expect(oldCancelled(), isTrue);
        expect(sessions.stateOf('a').preparing, isFalse);
        expect(sessions.stateOf('a').backgrounded, isFalse);
        expect(sessions.stateOf('a').progress, '');
        expect(sessions.stateOf('a').error, isNull);
        expect(sessions.stateOf('a').notice, isNull);
        final newWork = sessions.prepare('a');
        final current = sessions.stateOf('a');
        oldProgress(9, 10);
        if (failLate) {
          oldResult.completeError(StateError('late failure'));
        } else {
          oldResult.complete(_sessionDraft());
        }
        await oldWork;
        expect(sessions.stateOf('a'), same(current));
        expect(port.cancelled['a']!(), isFalse);
        port.pending['a']!.complete(_sessionDraft());
        await newWork;
      }
    });

    test('提交冲突保留草稿和编辑内容，重试成功刷新摘要并清空会话', () async {
      expect(await sessions.commit('a', '无草稿'), isFalse);
      final draft = _sessionDraft();
      final work = sessions.prepare('a');
      port.pending['a']!.complete(draft);
      await work;
      final beforeEdit = changes.length;
      sessions.updateDraftText('a', '- 用户编辑');
      sessions.updateDraftText('a', '- 用户编辑');
      expect(sessions.stateOf('a').draftText, '- 用户编辑');
      expect(changes, hasLength(beforeEdit));
      port.onCommit = (received, text) async {
        expect(received, same(draft));
        expect(text, '- 用户编辑');
        throw const ContextCompactionException('聊天已变化，请重新整理。');
      };
      expect(await sessions.commit('a', '- 用户编辑'), isFalse);
      expect(sessions.stateOf('a').draft, same(draft));
      expect(sessions.stateOf('a').draftText, '- 用户编辑');
      expect(sessions.stateOf('a').error, '聊天已变化，请重新整理。');
      expect(sessions.stateOf('a').committing, isFalse);
      expect(sessions.stateOf('a').progress, '');

      final result = Completer<ContextSummary>();
      port.onCommit = (_, __) => result.future;
      final save = sessions.commit('a', '- 最终编辑');
      expect(sessions.stateOf('a').committing, isTrue);
      expect(sessions.stateOf('a').draftText, '- 最终编辑');
      expect(sessions.stateOf('a').progress, '正在保存内容交接…');
      expect(sessions.stateOf('a').error, isNull);
      expect(await sessions.commit('a', '重复'), isFalse);
      expect(await sessions.undo('a'), isFalse);
      final calls = port.prepareCalls;
      await sessions.prepare('a');
      expect(port.prepareCalls, calls);
      final saved = _sessionSummary('a', '- 最终编辑');
      result.complete(saved);
      expect(await save, isTrue);
      final state = sessions.stateOf('a');
      expect(state.currentSummary, same(saved));
      expect(state.draft, isNull);
      expect(state.draftText, '');
      expect(state.committing, isFalse);
      expect(state.preparing, isFalse);
      expect(state.backgrounded, isFalse);
      expect(state.progress, '');
      expect(state.error, isNull);
      expect(state.notice, isNull);
    });

    test('不同角色的整理、进度、取消、草稿、通知与提交互不影响', () async {
      final a = sessions.prepare('a');
      final b = sessions.prepare('b');
      sessions.enterBackground('b');
      port.progress['a']!(1, 2);
      port.progress['b']!(3, 4);
      expect(sessions.stateOf('a').progress, '整理内容 1 / 2');
      expect(sessions.stateOf('b').progress, '整理内容 3 / 4');
      sessions.cancelPrepare('a');
      expect(port.cancelled['a']!(), isTrue);
      expect(port.cancelled['b']!(), isFalse);
      port.pending['a']!.complete(_sessionDraft('a'));
      final bDraft = _sessionDraft('b');
      port.pending['b']!.complete(bDraft);
      await Future.wait([a, b]);
      expect(sessions.stateOf('a').draft, isNull);
      expect(sessions.stateOf('a').notice, isNull);
      expect(sessions.stateOf('b').draft, same(bDraft));
      expect(sessions.stateOf('b').notice, isNotNull);
      sessions.updateDraftText('a', '独立编辑');
      sessions.discardDraft('a');
      expect(sessions.stateOf('b').draftText, bDraft.summary);
      final saved = _sessionSummary('b');
      port.onCommit = (draft, _) async {
        expect(draft.snapshot.ownerId, 'b');
        return saved;
      };
      expect(await sessions.commit('b', 'b编辑'), isTrue);
      expect(sessions.stateOf('b').currentSummary, same(saved));
      expect(sessions.stateOf('a').currentSummary, isNull);
    });

    test('加载只接纳同角色最新代数，失败静默清除当前摘要', () async {
      final first = Completer<ContextSummary?>();
      final second = Completer<ContextSummary?>();
      final other = _sessionSummary('b');
      var calls = 0;
      port.onCurrent = (ownerId) => ownerId == 'b'
          ? Future.value(other)
          : (++calls == 1 ? first.future : second.future);
      final oldLoad = sessions.loadCurrent('a');
      final newLoad = sessions.loadCurrent('a');
      await sessions.loadCurrent('b');
      final latest = _sessionSummary();
      second.complete(latest);
      await newLoad;
      first.completeError(StateError('stale load failed'));
      await oldLoad;
      expect(sessions.stateOf('a').currentSummary, same(latest));
      expect(sessions.stateOf('b').currentSummary, same(other));
      port.onCurrent = (_) async => throw StateError('unavailable');
      await sessions.loadCurrent('a');
      expect(sessions.stateOf('a').currentSummary, isNull);
      expect(sessions.stateOf('a').error, isNull);
    });

    test('丢弃草稿清除编辑、错误和通知，保留当前摘要', () async {
      final current = _sessionSummary();
      port.onCurrent = (_) async => current;
      await sessions.loadCurrent('a');
      final work = sessions.prepare('a');
      sessions.enterBackground('a');
      port.pending['a']!.complete(_sessionDraft());
      await work;
      port.onCommit = (_, __) async => throw StateError('save failed');
      await sessions.commit('a', '编辑');
      expect(sessions.stateOf('a').error, isNotNull);
      sessions.discardDraft('a');
      final state = sessions.stateOf('a');
      expect(state.currentSummary, same(current));
      expect(state.draft, isNull);
      expect(state.draftText, '');
      expect(state.error, isNull);
      expect(state.notice, isNull);
    });

    test('撤销失败保留草稿，成功重新加载摘要，重读失败仍完成撤销', () async {
      final work = sessions.prepare('a');
      sessions.enterBackground('a');
      final draft = _sessionDraft();
      port.pending['a']!.complete(draft);
      await work;
      sessions.updateDraftText('a', '编辑');
      port.onUndo = (_) async => throw const ContextCompactionException('忙碌中');
      expect(await sessions.undo('a'), isFalse);
      expect(sessions.stateOf('a').error, '忙碌中');
      expect(sessions.stateOf('a').draft, same(draft));
      expect(sessions.stateOf('a').draftText, '编辑');
      expect(sessions.stateOf('a').committing, isFalse);
      expect(sessions.stateOf('a').progress, '');
      final gate = Completer<void>();
      port.onUndo = (ownerId) {
        expect(ownerId, 'a');
        return gate.future;
      };
      final previous = _sessionSummary();
      port.onCurrent = (_) async => previous;
      final undo = sessions.undo('a');
      expect(sessions.stateOf('a').committing, isTrue);
      expect(sessions.stateOf('a').progress, '正在恢复…');
      gate.complete();
      expect(await undo, isTrue);
      final state = sessions.stateOf('a');
      expect(state.currentSummary, same(previous));
      expect(state.draft, isNull);
      expect(state.draftText, '');
      expect(state.error, isNull);
      expect(state.notice, isNull);
      expect(state.committing, isFalse);
      expect(state.progress, '');
      port.onCurrent = (_) async => throw StateError('reload failed');
      expect(await sessions.undo('a'), isTrue);
      expect(sessions.stateOf('a').currentSummary, isNull);
      expect(sessions.stateOf('a').error, isNull);
    });

    test('移除监听者和销毁后不通知，销毁取消在途整理与加载', () async {
      var removedCalls = 0;
      void removed(String _) => removedCalls++;
      sessions.addListener(removed);
      sessions.removeListener(removed);
      final loadResult = Completer<ContextSummary?>();
      port.onCurrent = (_) => loadResult.future;
      final load = sessions.loadCurrent('a');
      final work = sessions.prepare('a');
      final state = sessions.stateOf('a');
      final count = changes.length;
      sessions.dispose();
      expect(port.cancelled['a']!(), isTrue);
      port.progress['a']!(1, 1);
      port.pending['a']!.complete(_sessionDraft());
      loadResult.complete(_sessionSummary());
      await Future.wait([load, work]);
      expect(sessions.stateOf('a'), same(state));
      expect(changes, hasLength(count));
      expect(removedCalls, 0);
    });

    test('销毁后丢弃提交与撤销的迟到状态', () async {
      final work = sessions.prepare('a');
      port.pending['a']!.complete(_sessionDraft());
      await work;
      final result = Completer<ContextSummary>();
      port.onCommit = (_, __) => result.future;
      final save = sessions.commit('a', '编辑');
      final state = sessions.stateOf('a');
      sessions.dispose();
      result.complete(_sessionSummary());
      expect(await save, isFalse);
      expect(sessions.stateOf('a'), same(state));

      final undoSessions = ManualCompactionSessionStore.fromPort(port);
      addTearDown(undoSessions.dispose);
      final gate = Completer<void>();
      port.onUndo = (_) => gate.future;
      var reads = 0;
      port.onCurrent = (_) async {
        reads++;
        return _sessionSummary();
      };
      final undo = undoSessions.undo('a');
      final undoState = undoSessions.stateOf('a');
      undoSessions.dispose();
      gate.complete();
      expect(await undo, isFalse);
      expect(reads, 0);
      expect(undoSessions.stateOf('a'), same(undoState));
    });

    test('首次订阅状态不构造压缩端口或数据库，变更仅刷新对应角色', () async {
      var portBuilds = 0;
      var databaseBuilds = 0;
      final providers = ProviderContainer(
        overrides: [
          manualCompactionProvider.overrideWith((ref) {
            portBuilds++;
            return port;
          }),
          databaseProvider.overrideWith((ref) {
            databaseBuilds++;
            throw StateError('state reads must not initialize the database');
          }),
        ],
      );
      addTearDown(providers.dispose);
      var aChanges = 0;
      var bChanges = 0;
      final a = providers.listen(manualCompactionStateProvider('a'), (_, __) {
        aChanges++;
      });
      final b = providers.listen(manualCompactionStateProvider('b'), (_, __) {
        bChanges++;
      });
      expect(a.read().preparing, isFalse);
      expect(b.read().draft, isNull);
      expect(portBuilds, 0);
      expect(databaseBuilds, 0);
      final store = providers.read(manualCompactionSessionProvider);
      final work = store.prepare('a');
      expect(portBuilds, 1);
      expect(a.read().preparing, isTrue);
      expect(aChanges, 1);
      expect(bChanges, 0);
      store.enterBackground('a');
      expect(a.read().backgrounded, isTrue);
      port.pending['a']!.complete(_sessionDraft());
      await work;
      expect(a.read().draft, isNotNull);
      expect(a.read().notice, isNotNull);
      expect(b.read().draft, isNull);
      expect(bChanges, 0);
      expect(databaseBuilds, 0);
      a.close();
      b.close();

      final pending = store.prepare('b');
      providers.dispose();
      expect(port.cancelled['b']!(), isTrue);
      port.pending['b']!.complete(_sessionDraft('b'));
      await pending;
    });
  });
}
