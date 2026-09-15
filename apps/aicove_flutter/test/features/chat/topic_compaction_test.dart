import 'package:aicove_flutter/src/features/chat/application/automatic_context_service.dart';
import 'package:aicove_flutter/src/features/memory/domain/compaction_memory.dart';
import 'package:aicove_flutter/src/features/memory/application/compaction_memory_service.dart';
import 'package:aicove_flutter/src/features/memory/data/sqlite_compaction_memory_queue.dart';
import 'package:aicove_flutter/src/features/chat/data/sqlite_runtime_context_store.dart';
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
import 'package:aicove_flutter/src/core/utils/token_estimator.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/providers/topic_compaction_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/topic_compaction_port.dart';
import 'package:aicove_flutter/src/features/chat/data/sqlite_topic_handoff_store.dart';
import 'package:aicove_flutter/src/features/chat/data/background_topic_summary_adapter.dart';
import 'package:aicove_flutter/src/features/chat/application/topic_compaction_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/memory/data/markdown_contact_memory_store.dart';
import 'package:aicove_flutter/src/features/memory/domain/contact_memory_port.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
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
  @override
  Future<AppSettings> build() async {
    final settings = mapUiModelsToAppSettings({
      'context_window_tokens': window,
    });
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

class _Summary implements TopicSummaryPort {
  String text = '- 周五一起去看海，用户怕冷。';
  bool fail = false;
  Completer<void>? gate;
  TopicSnapshot? seen;
  @override
  Future<String> summarize(
    TopicSnapshot snapshot, {
    required void Function(int, int) onProgress,
    required bool Function() isCancelled,
  }) async {
    seen = snapshot;
    if (gate != null) await gate!.future;
    if (fail) throw StateError('fake network unavailable');
    onProgress(1, 1);
    return text;
  }
}

class _RichSummary extends _Summary implements ContextSummaryPort {
  @override
  Future<TopicSummaryOutput> summarizeWithMemory(
    TopicSnapshot snapshot, {
    ContactMemoryNotebook? memory,
    required void Function(int, int) onProgress,
    required bool Function() isCancelled,
  }) async {
    expect(memory?.enabled, isTrue);
    return TopicSummaryOutput(
      await summarize(
        snapshot,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
      memoryUpdates: [
        CompactionMemoryUpdate(
          key: 'cold',
          title: '怕冷',
          body: '用户怕冷',
          kind: 'core',
          sourceIds: [snapshot.messages.first.id],
        ),
      ],
    );
  }
}

class _MemoryFailure implements ContactMemoryPort {
  _MemoryFailure(this.delegate);
  final ContactMemoryPort delegate;
  bool fail = true;
  @override
  Future<ContactMemoryNotebook> load(String ownerId) => delegate.load(ownerId);
  @override
  Future<ContactMemoryNotebook> save(ContactMemoryNotebook notebook) {
    if (fail) throw const ContactMemoryConflict();
    return delegate.save(notebook);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late db.AppDatabase database;
  late ProviderContainer container;
  late PathProviderPlatform oldPaths;
  late SqliteTopicHandoffStore store;
  late MarkdownContactMemoryStore memory;
  late _Summary summary;
  late TopicCompactionService service;
  bool allowed = true;
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
        topicSummaryPortProvider.overrideWith((ref) async => summary),
        automaticSummaryPortProvider.overrideWith((ref) async => summary),
        sillyTavernPresetStoreProvider.overrideWithValue(
          SillyTavernPresetStore(documentsDirectoryResolver: () async => root),
        ),
      ],
    );
    await database.customStatement('PRAGMA foreign_keys = ON');
    store = SqliteTopicHandoffStore(
      database,
      (owner) =>
          container.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    );
  }

  Future<String?> boundary(String owner) async =>
      (await container.read(conversationRepositoryProvider).getById(owner))
          ?.contextStartMessageId;
  TopicCompactionService createService({ContactMemoryPort? memoryPort}) =>
      TopicCompactionService(
        store: store,
        summaryFactory: () async => summary,
        memory: memoryPort ?? memory,
        memoryAllowed: (_) async => allowed,
        readBoundary: boundary,
        publishBoundary: (_) async {},
        ensureIdle: (_) {
          if (sending) throw const TopicCompactionException('生成中');
        },
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

  Future<TopicCompactionDraft> prepare([String id = 'a']) =>
      service.prepare(id, onProgress: (_, __) {}, isCancelled: () => false);
  Future<void> enableMemory(String id) async => memory
      .save((await memory.load(id)).copyWith(enabled: true, core: '用户手写，不能覆盖'))
      .then((_) {});

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _Settings.maxTokens = null;
    _Settings.window = 272000;
    root = await Directory.systemTemp.createTemp('topic_compaction_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TraceStore.instance.debugResetForTest();
    await open();
    memory = MarkdownContactMemoryStore(
      () async => Directory('${root.path}/memories'),
    );
    summary = _Summary();
    allowed = true;
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
    await enableMemory('a');
    await enableMemory('b');
    final draft = await prepare();
    expect(await boundary('a'), isNull);
    expect(summary.seen!.messages.map((m) => m.id), ['a1', 'a2']);
    final result = await service.commit(draft, draft.summary, archive: true);
    expect(result.memoryPending, isFalse);
    expect(await boundary('a'), 'a2');
    expect(await boundary('b'), isNull);
    expect(
      (await container.read(chatHistoryStoreProvider).loadAllRawMessages('a'))
          .length,
      2,
    );
    expect((await memory.load('a')).core, '用户手写，不能覆盖');
    expect((await memory.load('a')).events.single.body, contains('用户怕冷'));
    expect((await memory.load('b')).events, isEmpty);
    expect(await store.active('b', 'a2'), isNull);
    expect((await store.active('a', 'a2'))!.sourceIds, ['a1', 'a2']);
  });

  test('总结失败或取消不改变话题，也不提前写记忆', () async {
    await owner('a');
    await message('m1');
    await enableMemory('a');
    summary.fail = true;
    await expectLater(prepare(), throwsStateError);
    summary.fail = false;
    await expectLater(
      service.prepare('a', onProgress: (_, __) {}, isCancelled: () => true),
      throwsA(isA<TopicCompactionException>()),
    );
    expect(await boundary('a'), isNull);
    expect((await memory.load('a')).events, isEmpty);
  });

  test('预览期间新增消息或编辑源消息，提交必须失败且保留旧边界', () async {
    await owner('a');
    await message('m1');
    var draft = await prepare();
    await message('m2', at: 2);
    await expectLater(
      service.commit(draft, draft.summary, archive: false),
      throwsA(isA<TopicCompactionException>()),
    );
    draft = await prepare();
    await (database.update(database.messages)..where((m) => m.id.equals('m1')))
        .write(const db.MessagesCompanion(content: Value('已更正')));
    await expectLater(
      service.commit(draft, draft.summary, archive: false),
      throwsA(isA<TopicCompactionException>()),
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
    await service.commit(draft, draft.summary, archive: false);
    expect(
      (await container.read(conversationRepositoryProvider).getById('a'))!
          .personaPrompt,
      '新卡短句',
    );
  });

  test('MD 写入失败仍有可靠交接；重启后补写，不重复归档', () async {
    await owner('a');
    await message('m1');
    await enableMemory('a');
    final failing = _MemoryFailure(memory);
    service = createService(memoryPort: failing);
    final draft = await prepare();
    expect(
      (await service.commit(draft, draft.summary, archive: true)).memoryPending,
      isTrue,
    );
    expect(await boundary('a'), 'm1');
    expect((await service.current('a'))!.memoryState, 'pending');
    container.dispose();
    await database.close();
    await open();
    service = createService();
    expect((await service.current('a'))!.summary, contains('用户怕冷'));
    expect(await service.retryArchive('a'), isTrue);
    expect(await service.retryArchive('a'), isTrue);
    expect((await memory.load('a')).events, hasLength(1));
    expect((await service.current('a'))!.memoryState, 'archived');
  });

  test('连续压缩输入包含上一内容摘要；撤销恢复旧边界但不撤回记忆', () async {
    await owner('a');
    await message('m1');
    await enableMemory('a');
    var draft = await prepare();
    await service.commit(draft, draft.summary, archive: true);
    await message('m2', at: 2);
    summary.text = '- 周五一起去看海，用户怕冷。\n- 已约好带外套。';
    draft = await prepare();
    expect(draft.snapshot.previous!.summary, contains('怕冷'));
    expect(draft.snapshot.messages.map((m) => m.id), ['m2']);
    await service.commit(draft, draft.summary, archive: true);
    expect((await service.current('a'))!.sourceIds, ['m1', 'm2']);
    await service.undo('a');
    expect(await boundary('a'), 'm1');
    expect((await memory.load('a')).events, hasLength(2));
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

  test('来源编辑后旧摘要不再注入或补写，必须先撤销再整理', () async {
    await owner('a');
    await message('m1');
    final draft = await prepare();
    await service.commit(draft, draft.summary, archive: true);
    await (database.update(database.messages)..where((m) => m.id.equals('m1')))
        .write(const db.MessagesCompanion(content: Value('纠正旧事实')));
    expect(await service.current('a'), isNull);
    await message('m2', at: 2);
    await expectLater(prepare(), throwsA(isA<TopicCompactionException>()));
    await expectLater(
      service.retryArchive('a'),
      throwsA(isA<TopicCompactionException>()),
    );
    expect((await memory.load('a')).events, isEmpty);
    await service.undo('a');
    expect(await boundary('a'), isNull);
  });

  test('重复提交、生成中、空新话题、超限摘要、删除角色均拒绝', () async {
    await owner('a');
    await message('m1');
    final draft = await prepare();
    await expectLater(
      service.commit(draft, '很长' * 10000, archive: false),
      throwsA(isA<TopicCompactionException>()),
    );
    sending = true;
    await expectLater(prepare(), throwsA(isA<TopicCompactionException>()));
    sending = false;
    await service.commit(draft, draft.summary, archive: false);
    await expectLater(
      service.commit(draft, draft.summary, archive: false),
      throwsA(isA<TopicCompactionException>()),
    );
    await expectLater(prepare(), throwsA(isA<TopicCompactionException>()));
    await (database.update(database.conversations)
          ..where((c) => c.id.equals('a')))
        .write(const db.ConversationsCompanion(deletedAt: Value(5)));
    await expectLater(
      service.current('a'),
      throwsA(isA<TopicCompactionException>()),
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
    await expectLater(prepare(), throwsA(isA<TopicCompactionException>()));
    summary.gate!.complete();
    final a = await running;
    final b = await prepare('b');
    expect(a.snapshot.ownerId, 'a');
    expect(b.snapshot.ownerId, 'b');
  });

  test('归档前关闭权限：保留待写状态，不触碰 MD', () async {
    await owner('a');
    await message('m1');
    await enableMemory('a');
    final draft = await prepare();
    allowed = false;
    expect(
      (await service.commit(draft, draft.summary, archive: true)).memoryPending,
      isTrue,
    );
    expect((await memory.load('a')).events, isEmpty);
    allowed = true;
    expect(await service.retryArchive('a'), isTrue);
  });

  test('v15 → v16 只新增压缩表，保留原消息与角色卡', () async {
    await owner('a');
    await message('m1');
    await database.customStatement('DROP TABLE topic_handoffs');
    await database.customStatement('PRAGMA user_version = 15');
    container.dispose();
    await database.close();
    await open();
    service = createService();
    expect(
      (await container.read(chatHistoryStoreProvider).loadAllRawMessages('a'))
          .single
          .id,
      'm1',
    );
    final draft = await prepare();
    await service.commit(draft, draft.summary, archive: false);
  });

  test('撤销待归档操作后不再补写；相同来源的新摘要保留独立版本', () async {
    await owner('a');
    await message('m1');
    var draft = await prepare();
    final first = await service.commit(draft, draft.summary, archive: true);
    expect(first.memoryPending, isTrue);
    await service.undo('a');
    await enableMemory('a');
    await service.retryArchive('a');
    expect((await memory.load('a')).events, isEmpty);
    draft = await prepare();
    final second = await service.commit(draft, '已经改成周六出行', archive: false);
    expect(second.handoff.id, isNot(first.handoff.id));
    expect(
      await database.customSelect('SELECT * FROM topic_handoffs').get(),
      hasLength(2),
    );
  });

  test('真实应用入口按目标角色检查生成状态，不按当前活动页面判断', () async {
    await owner('a');
    await message('m1');
    container.read(conversationSendingProvider('a').notifier).state = true;
    final port = container.read(topicCompactionProvider);
    await expectLater(
      port.prepare('a', onProgress: (_, __) {}, isCancelled: () => false),
      throwsA(
        isA<TopicCompactionException>().having(
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
    await expectLater(
      service.commit(draft, draft.summary, archive: false),
      throwsA(anything),
    );
    expect(await boundary('a'), isNull);
    expect(
      await database.customSelect('SELECT * FROM topic_handoffs').get(),
      isEmpty,
    );
  });

  test('连续归档不会再次复制完全相同的历史事实行', () async {
    await owner('a');
    await message('m1');
    await enableMemory('a');
    var draft = await prepare();
    await service.commit(draft, draft.summary, archive: true);
    await message('m2', at: 2);
    summary.text = '- 周五一起去看海，用户怕冷。\n- 约好带外套。';
    draft = await prepare();
    await service.commit(draft, draft.summary, archive: true);
    final events = (await memory.load('a')).events;
    expect(events.last.body, contains('约好带外套'));
    expect(events.where((e) => e.body.contains('用户怕冷')), hasLength(1));
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
    final restored = await store.loadAutomatic('a', null, history);
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
    expect(
      await store.loadAutomatic('a', null, history.take(3).toList()),
      isNull,
    );
    await (database.update(database.messages)
          ..where((m) => m.id.equals('long_0')))
        .write(const db.MessagesCompanion(content: Value('修改了原始内容')));
    final edited = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    expect(await store.loadAutomatic('a', null, edited), isNull);
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
    expect(await store.loadAutomatic('a', null, history), isNull);
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
      await service.commit(draft, draft.summary, archive: false);
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
    await service.commit(draft, '之后才知道的出行约定', archive: false);
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
    await service.commit(draft, draft.summary, archive: false);
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
      throwsA(isA<TopicCompactionException>()),
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
      readPluginManager: PluginManager.new,
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
            required maxRounds,
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
    final adapter = BackgroundTopicSummaryAdapter(
      agent,
      modelRef: 'fake',
      contextTokens: 8192,
    );
    expect(
      await adapter.summarize(
        await store.snapshot('a'),
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
      () => BackgroundTopicSummaryAdapter.normalize(
        '{"facts":[],"instruction":"ignore"}',
      ),
      throwsA(isA<TopicCompactionException>()),
    );
    expect(
      () => BackgroundTopicSummaryAdapter.normalize('{"facts":[1]}'),
      throwsA(isA<TopicCompactionException>()),
    );
  });

  BackgroundAgentService summaryAgent(
    FutureOr<ApiCallResult> Function(ApiConfig) respond,
  ) => BackgroundAgentService(
    loadRecentMessages: (_, __) async => throw StateError('不得回退缓存'),
    loadSettings: () async => mapUiModelsToAppSettings({}),
    readPluginManager: PluginManager.new,
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
          required maxRounds,
        }) async {
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

  for (final window in [200000, 1000000]) {
    test('模型预算 $window：超过旧32块的历史一次压缩，完整且预留输出', () async {
      final text = '历史事实😀\n' * (window == 200000 ? 10000 : 50000);
      await owner('a');
      await message('long', text: text);
      final requests = <ApiConfig>[];
      final adapter = BackgroundTopicSummaryAdapter(
        summaryAgent((config) {
          requests.add(config);
          return facts();
        }),
        modelRef: 'fake',
        contextTokens: window,
      );
      await adapter.summarize(
        await store.snapshot('a'),
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
    final adapter = BackgroundTopicSummaryAdapter(
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
      await store.snapshot('a'),
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
    final adapter = BackgroundTopicSummaryAdapter(
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
      await store.snapshot('a'),
      onProgress: (_, __) {},
      isCancelled: () => false,
    );
    expect(attempts, greaterThan(1));
    expect(received.toString(), text);
  });

  test('进度回调中取消时不再发模型请求', () async {
    await owner('a');
    await message('m');
    var cancelled = false;
    var calls = 0;
    final adapter = BackgroundTopicSummaryAdapter(
      summaryAgent((_) {
        calls++;
        return facts();
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    await expectLater(
      adapter.summarize(
        await store.snapshot('a'),
        onProgress: (_, __) => cancelled = true,
        isCancelled: () => cancelled,
      ),
      throwsA(isA<TopicCompactionException>()),
    );
    expect(calls, 0);
  });

  test('鉴权失败不通过拆分重复请求，原话题不变', () async {
    await owner('a');
    await message('m');
    var calls = 0;
    final adapter = BackgroundTopicSummaryAdapter(
      summaryAgent((_) {
        calls++;
        throw StateError('HTTP 401 unauthorized');
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    await expectLater(
      adapter.summarize(
        await store.snapshot('a'),
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
    final adapter = BackgroundTopicSummaryAdapter(
      summaryAgent((_) {
        calls++;
        throw StateError('HTTP 400 prompt is too long');
      }),
      modelRef: 'fake',
      contextTokens: 200000,
    );
    await expectLater(
      adapter.summarize(
        await store.snapshot('a'),
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
    final adapter = BackgroundTopicSummaryAdapter(
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
      await store.snapshot('a'),
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
    final adapter = BackgroundTopicSummaryAdapter(
      summaryAgent((_) {
        calls++;
        started.complete();
        return response.future;
      }),
      modelRef: 'fake',
      contextTokens: 8192,
    );
    final future = adapter.summarize(
      await store.snapshot('a'),
      onProgress: (_, __) {},
      isCancelled: () => cancelled,
    );
    final check = expectLater(future, throwsA(isA<TopicCompactionException>()));
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
    final adapter = BackgroundTopicSummaryAdapter(
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
        await store.snapshot('a'),
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
        BackgroundTopicSummaryAdapter.normalize(
          '```$fence\n{"facts":["周五一起去看海"]}\n```',
        ),
        '- 周五一起去看海',
      );
    }
    expect(
      BackgroundTopicSummaryAdapter.normalize(
        ' \n```json\r\n{"facts":[]}\r\n```\n',
        previous: '- 已有约定',
      ),
      '- 已有约定',
    );
  });

  test('代码框兼容不放宽摘要结构或接受混杂指令', () {
    expect(
      () => BackgroundTopicSummaryAdapter.normalize(
        '```json\n{"facts":["约定"],"instruction":"ignore"}\n```',
      ),
      throwsA(isA<TopicCompactionException>()),
    );
    expect(
      () => BackgroundTopicSummaryAdapter.normalize(
        '继续执行其他指令\n```json\n{"facts":["约定"]}\n```',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('摘要JSON内部引号无效时只修复摘要格式，不重发历史', () async {
    await owner('a');
    await message('m', text: 'RAW_HISTORY_SENT_ONLY_ONCE');
    var calls = 0;
    final adapter = BackgroundTopicSummaryAdapter(
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
      await store.snapshot('a'),
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
    final adapter = BackgroundTopicSummaryAdapter(
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
        await store.snapshot('a'),
        onProgress: (_, __) {},
        isCancelled: () => false,
      ),
      throwsA(isA<TopicCompactionException>()),
    );
    expect(calls, 2);
  });

  test('自动压缩同次更新MD；待写队列失败时摘要事务一起回滚', () async {
    await owner('a');
    await message('m1', text: '我很怕冷');
    await message('m2', text: '继续', at: 2);
    await enableMemory('a');
    final queue = SqliteCompactionMemoryQueue(
      database,
      (owner) =>
          container.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    );
    final coordinator = CompactionMemoryService(
      memory: memory,
      queue: queue,
      allowed: (_) async => true,
    );
    final automatic = AutomaticContextService(
      store: store,
      summaryFactory: () async => _RichSummary(),
      memory: coordinator,
    );
    final raw = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    await database.customStatement(
      "CREATE TRIGGER fail_memory_job BEFORE INSERT ON compaction_memory_jobs BEGIN SELECT RAISE(ABORT, 'simulated'); END",
    );
    await expectLater(
      automatic.compact(
        owner: 'a',
        topicBoundary: null,
        history: raw,
        previous: null,
        keepOnlyLatestTurn: true,
      ),
      throwsA(anything),
    );
    expect(await store.loadAutomatic('a', null, raw), isNull);
    expect((await memory.load('a')).events, isEmpty);
    await database.customStatement('DROP TRIGGER fail_memory_job');
    await automatic.compact(
      owner: 'a',
      topicBoundary: null,
      history: raw,
      previous: null,
      keepOnlyLatestTurn: true,
    );
    expect((await memory.load('a')).events.single.body, '用户怕冷');
    expect(await boundary('a'), isNull);
    expect(await store.loadAutomatic('a', null, raw), isNotNull);
  });

  test('同次整理输出结构化摘要和记忆增量；SQLite与MD重启后补写', () async {
    await owner('a');
    await message('m1', text: '请记住我不吃香菜');
    await enableMemory('a');
    final failing = _MemoryFailure(memory);
    final queue = SqliteCompactionMemoryQueue(
      database,
      (owner) =>
          container.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    );
    final coordinator = CompactionMemoryService(
      memory: failing,
      queue: queue,
      allowed: (_) async => true,
    );
    final adapter = BackgroundTopicSummaryAdapter(
      summaryAgent((config) {
        final data =
            jsonDecode(config.messages.last['content'] as String) as Map;
        expect(data['existing_memory'], isNotNull);
        return ApiCallResult(
          replyText: jsonEncode({
            'summary': {
              'background': ['用户不吃香菜'],
              'preferences': [],
              'progress': [],
              'pending': [],
              'details': [],
            },
            'memory_updates': [
              {
                'key': 'food.coriander',
                'kind': 'core',
                'title': '饮食偏好',
                'body': '用户不吃香菜',
                'sourceIds': ['m1'],
                'existingId': null,
              },
            ],
          }),
          processedText: '',
          pluginEvents: [],
          toolResults: [],
        );
      }),
      modelRef: 'fake',
      contextTokens: 32000,
    );
    final richService = TopicCompactionService(
      store: store,
      summaryFactory: () async => adapter,
      memory: memory,
      memoryAllowed: (_) async => true,
      readBoundary: boundary,
      publishBoundary: (_) async {},
      ensureIdle: (_) {},
      compactionMemory: coordinator,
    );
    final draft = await richService.prepare(
      'a',
      onProgress: (_, __) {},
      isCancelled: () => false,
    );
    expect((await memory.load('a')).events, isEmpty);
    final result = await richService.commit(
      draft,
      draft.summary,
      archive: true,
    );
    expect(result.memoryPending, isTrue);
    expect(await boundary('a'), 'm1');
    expect(await queue.pending('a'), hasLength(1));
    container.dispose();
    await database.close();
    await open();
    final restartedQueue = SqliteCompactionMemoryQueue(
      database,
      (owner) =>
          container.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    );
    final restarted = CompactionMemoryService(
      memory: memory,
      queue: restartedQueue,
      allowed: (_) async => true,
    );
    expect(await restarted.flush('a'), isTrue);
    expect((await memory.load('a')).events.single.body, '用户不吃香菜');
    expect((await memory.load('a')).core, '用户手写，不能覆盖');
    expect(await restartedQueue.pending('a'), isEmpty);
  });

  test('运行时原文分页可跨重启读取，禁止跨角色和来源编辑后的记忆补写', () async {
    await owner('a');
    await owner('b');
    await message('m1', text: '用户原始要求');
    final runtime = SqliteRuntimeContextStore(
      database,
      (owner) =>
          container.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    );
    final id = await runtime.save(
      owner: 'a',
      source: [
        {'role': 'tool', 'content': '前缀${'😀' * 3000}查找目标'},
      ],
      replacement: [],
    );
    expect(await runtime.read('b', id, 0), isNull);
    await (database.update(database.messages)..where((m) => m.id.equals('m1')))
        .write(const db.MessagesCompanion(content: Value('用户更正原始要求')));
    await expectLater(
      runtime.save(
        owner: 'a',
        source: [
          {'role': 'tool', 'content': '旧来源'},
        ],
        replacement: [
          {'role': 'assistant', 'content': '旧摘要'},
        ],
        expectedSourceId: id,
      ),
      throwsA(isA<TopicCompactionException>()),
    );

    final first = jsonDecode((await runtime.read('a', id, 0))!) as Map;
    expect(first['nextOffset'], 2048);
    container.dispose();
    await database.close();
    await open();
    final reopened = SqliteRuntimeContextStore(
      database,
      (owner) =>
          container.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    );
    expect(await reopened.read('a', id, 0, query: '查找目标'), contains('查找目标'));
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
    final first = await store.snapshot('a');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = await store.snapshot('a');
    expect(second.revision, first.revision);
    final result = await store.commit(first, '- 保留原始事实', archive: false);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect((await store.active('a', result.boundaryId))?.summary, '- 保留原始事实');
    await store.undo('a');
    final stale = await store.snapshot('a');
    block['content'] = '实际修改后的正文';
    await database.customStatement(
      'UPDATE message_blocks SET data=? WHERE id=?',
      [jsonEncode(block), 'b'],
    );
    await expectLater(
      store.commit(stale, '- 过期摘要', archive: false),
      throwsA(isA<TopicCompactionException>()),
    );
  });
}
