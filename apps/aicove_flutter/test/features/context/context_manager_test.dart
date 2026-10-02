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

class _Summary implements ContextSummarizerPort {
  String text = '- 周五一起去看海，用户怕冷。';
  bool fail = false;
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
    seen = snapshot;
    this.kind = kind;
    if (gate != null) await gate!.future;
    if (fail) throw StateError('fake network unavailable');
    onProgress(1, 1);
    return text;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  ContextManager createService() => ContextManager(
    store: store,
    loadMessages: (owner) =>
        container.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    readBoundary: boundary,
    summarizerFactory: () async => summary,
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

  test('边界存在但没有摘要：发送前补整理边界前的原文并保存；失败则阻止发送', () async {
    await owner('a', start: 'm2');
    await message('m1');
    await message('m2', role: 'assistant', at: 2);
    await message('m3', at: 3);
    summary.fail = true;
    await expectLater(
      service.manualSummary('a', 'm2', []),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(compacted, isEmpty);
    summary.fail = false;
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

  test('来源编辑后旧摘要不再注入，必须先撤销再整理', () async {
    await owner('a');
    await message('m1');
    final draft = await prepare();
    await service.commit(draft, draft.summary);
    await (database.update(database.messages)..where((m) => m.id.equals('m1')))
        .write(const db.MessagesCompanion(content: Value('纠正旧事实')));
    expect(await service.current('a'), isNull);
    await message('m2', at: 2);
    await expectLater(prepare(), throwsA(isA<ContextCompactionException>()));
    await service.undo('a');
    expect(await boundary('a'), isNull);
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
    await expectLater(
      service.commit(draft, draft.summary),
      throwsA(anything),
    );
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
    expect(
      await store.loadAuto('a', null, history.take(3).toList()),
      isNull,
    );
    await (database.update(database.messages)
          ..where((m) => m.id.equals('long_0')))
        .write(const db.MessagesCompanion(content: Value('修改了原始内容')));
    final edited = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages('a');
    expect(await store.loadAuto('a', null, edited), isNull);
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
    final check = expectLater(future, throwsA(isA<ContextCompactionException>()));
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
    expect((await store.manualFor('a', result.boundaryId))?.summary, '- 保留原始事实');
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
