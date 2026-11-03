import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateOutcome, ToolCallScope;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_private_read_tools.dart';
import 'package:aicove_flutter/src/features/assistant/assistant_providers.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/context/application/context_manager.dart';
import 'package:aicove_flutter/src/features/context/data/sqlite_context_summary_store.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/context/providers/context_providers.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_item.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_ports.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _MemoryAgent implements MemoryAgentPort {
  final started = Completer<void>();
  final resume = Completer<void>();
  @override
  int get batchTokenBudget => 10000;
  @override
  Future<List<MemoryOp>> propose({
    required String ownerId,
    required List<MemoryItem> core,
    required List<MemoryItem> related,
    required List<Message> messages,
  }) async {
    started.complete();
    await resume.future;
    return [
      AddMemory(
        layer: MemoryLayer.archive,
        title: '回调整理',
        content: '已在提交后整理',
        sourceIds: messages.map((m) => m.id).toList(),
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  late AssistantPrivateReadTools tools;
  late SqliteContextSummaryStore summaries;
  late Directory root;
  late PathProviderPlatform oldPaths;
  late List<String> compacted;
  late List<String> published;
  Completer<void>? callbackGate;
  Future<void>? callbackWork;
  MemoryKeeperService? keeper;
  var clock = 0;

  Future<void> owner(String id) => database
      .into(database.conversations)
      .insert(
        db.ConversationsCompanion.insert(
          id: id,
          title: id,
          displayName: id,
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  ChatHistoryStore getHistory() => container.read(chatHistoryStoreProvider);
  Future<void> message(
    String id, {
    String owner = 'a',
    String text = '原文',
    List<MessageBlock>? blocks,
    Map<String, dynamic>? payload,
  }) => getHistory().appendMessage(
    conversationId: owner,
    message: Message(
      id: id,
      role: 'user',
      content: text,
      createdAt: DateTime.fromMillisecondsSinceEpoch(++clock),
      blocks: blocks,
      rawPayload: payload,
    ),
  );
  Future<db.Conversation> role() => (database.select(
    database.conversations,
  )..where((row) => row.id.equals('a'))).getSingle();
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> args, {
    bool approved = true,
  }) async {
    final scope = ToolCallScope()
      ..outcome = approved ? GateOutcome.approved : GateOutcome.allowed;
    final text = await scope.run(
      () => tools.tools().singleWhere((tool) => tool.name == name).handler({
        'role_id': 'a',
        ...args,
      }),
    );
    return jsonDecode(text!) as Map<String, dynamic>;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory(
      'test/features/assistant',
    ).createTemp('.private_crud_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    clock = 0;
    compacted = [];
    published = [];
    callbackGate = null;
    callbackWork = null;
    keeper = null;
    await owner('a');
    await owner('b');
    summaries = SqliteContextSummaryStore(
      database,
      (id) => container.read(chatHistoryStoreProvider).loadAllRawMessages(id),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        contextSummaryStoreProvider.overrideWithValue(summaries),
        manualCompactionProvider.overrideWith(
          (ref) => ContextManager(
            store: summaries,
            loadMessages: (id) => getHistory().loadAllRawMessages(id),
            readBoundary: (id) async =>
                (await ref.read(conversationRepositoryProvider).getById(id))
                    ?.contextStartMessageId,
            summarizerFactory: () => throw StateError('不应请求模型'),
            publishBoundary: (id) async => published.add(id),
            ensureIdle: (id) {
              if (ref.read(conversationSendingProvider(id))) {
                throw StateError('生成中');
              }
            },
            onCompacted: (id) {
              compacted.add(id);
              keeper?.schedule(id);
              if (callbackGate != null) {
                callbackWork = () async {
                  await callbackGate!.future;
                  await database
                      .customSelect('SELECT COUNT(*) FROM context_summaries')
                      .get();
                }();
              }
            },
          ),
        ),
      ],
    );
    tools = AssistantPrivateReadTools(
      roles: () async => [
        for (final row in await database.select(database.conversations).get())
          Conversation(
            id: row.id,
            title: row.title,
            displayName: row.displayName,
            isHidden: row.isHidden,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
      ],
      rolesNow: () => [],
      grants: AssistantReadGrants(),
      messages: (_, {required limit, before, keyword}) async => [],
      memories: (_) async => [],
      writePrivate: container.read(assistantPrivateWriteProvider),
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  test('聚合聊天入口沿用原文写改删与权限', () async {
    const name = AssistantPrivateReadTools.roleContext;
    Future<Map<String, dynamic>> context(
      String action,
      Map<String, dynamic> args,
    ) => call(name, {'target': 'chat', 'action': action, ...args});
    final invalid = await context('append', {});
    expect(invalid['error'], 'invalid');
    expect(await getHistory().loadAllRawMessages('a'), isEmpty);
    final appended = await context('append', {'content': '原始记录'});
    expect(appended['undoable'], false);
    final id = appended['message_id'];
    await context('write', {
      'message_id': id,
      'content_replace': {'old_text': '原始', 'new_text': '更新'},
    });
    expect((await getHistory().loadAllRawMessages('a')).single.content, '更新记录');
    await context('update', {'message_id': id, 'content': '再次修改'});
    expect((await getHistory().loadAllRawMessages('a')).single.content, '再次修改');
    await context('delete', {
      'message_ids': [id],
    });
    expect(await getHistory().loadAllRawMessages('a'), isEmpty);
    expect(await getHistory().loadAllRawMessages('b'), isEmpty);
  });

  test('追加实际原文、不触发回复、返回不可撤销且隔离角色', () async {
    final result = await call(AssistantPrivateReadTools.appendChat, {
      'sender_role': 'assistant',
      'content': '追加内容',
    });
    expect(result['undoable'], isFalse);
    final rows = await getHistory().loadAllRawMessages('a');
    expect(rows.single.id, result['message_id']);
    expect(rows.single.status, 'sent');
    expect(await getHistory().loadAllRawMessages('b'), isEmpty);
    expect((await role()).lastMessage, '追加内容');
  });

  test('追加协议默认 assistant，显式 user，并在保存前去掉首尾空白', () async {
    final schema = tools
        .tools()
        .singleWhere(
          (tool) => tool.name == AssistantPrivateReadTools.appendChat,
        )
        .inputSchema!;
    expect(schema['required'], ['role_id', 'content']);
    expect(
      (schema['properties'] as Map)['sender_role']['default'],
      'assistant',
    );
    await call(AssistantPrivateReadTools.appendChat, {
      'content': ' \n 默认回复 \t',
    });
    await call(AssistantPrivateReadTools.appendChat, {
      'sender_role': 'user',
      'content': '\n 用户补充  ',
    });
    final rows = await getHistory().loadAllRawMessages('a');
    expect(rows.map((message) => message.role), ['assistant', 'user']);
    expect(rows.map((message) => message.content), ['默认回复', '用户补充']);
    for (final args in [
      {'sender_role': null, 'content': '正文'},
      {'sender_role': 'system', 'content': '正文'},
      {'content': ' \n '},
      {'content': null},
    ]) {
      await expectLater(
        call(AssistantPrivateReadTools.appendChat, args),
        throwsArgumentError,
      );
    }
    expect(await getHistory().loadAllRawMessages('a'), hasLength(2));
  });

  test('content_replace 对象精确替换，并允许空 new_text 删除一处子串', () async {
    final schema = tools
        .tools()
        .singleWhere(
          (tool) => tool.name == AssistantPrivateReadTools.updateChat,
        )
        .inputSchema!;
    expect((schema['properties'] as Map)['content_replace']['required'], [
      'old_text',
      'new_text',
    ]);
    await message('m1', text: '你好，朋友');
    await call(AssistantPrivateReadTools.updateChat, {
      'message_id': 'm1',
      'content_replace': {'old_text': '朋友', 'new_text': '世界'},
    });
    expect(
      (await getHistory().loadAllRawMessages('a')).single.content,
      '你好，世界',
    );
    await call(AssistantPrivateReadTools.updateChat, {
      'message_id': 'm1',
      'content_replace': {'old_text': '，世界', 'new_text': ''},
    });
    expect((await getHistory().loadAllRawMessages('a')).single.content, '你好');
  });

  test('替换对象与整段/旧协议互斥，空值、缺字段、额外字段、重复及缺失原文均拒绝', () async {
    await message('m1', text: '重复重复');
    for (final input in <Map<String, dynamic>>[
      {
        'content': '新文',
        'content_replace': {'old_text': '重复', 'new_text': '新'},
      },
      {
        'old_text': '重复',
        'new_text': '新',
        'content_replace': {'old_text': '重复', 'new_text': '新'},
      },
      {'content_replace': null},
      {'content_replace': '错误'},
      {'content_replace': {}},
      {
        'content_replace': {'old_text': '', 'new_text': '新'},
      },
      {
        'content_replace': {'old_text': ' ', 'new_text': '新'},
      },
      {
        'content_replace': {'old_text': null, 'new_text': '新'},
      },
      {
        'content_replace': {'old_text': '重复', 'new_text': null},
      },
      {
        'content_replace': {'old_text': '重复'},
      },
      {
        'content_replace': {'old_text': '重复', 'new_text': '新', 'extra': true},
      },
      {'content': null},
      {},
    ]) {
      await expectLater(
        call(AssistantPrivateReadTools.updateChat, {
          'message_id': 'm1',
          ...input,
        }),
        throwsArgumentError,
      );
    }
    for (final old in ['重复', '不存在']) {
      await expectLater(
        call(AssistantPrivateReadTools.updateChat, {
          'message_id': 'm1',
          'content_replace': {'old_text': old, 'new_text': '新'},
        }),
        throwsStateError,
      );
    }
    expect((await getHistory().loadAllRawMessages('a')).single.content, '重复重复');
  });

  test('旧消息修改同步原文和缓存，不覆盖真实末尾预览', () async {
    await message('old', text: '旧文');
    await message('tail', text: '末尾');
    await call(AssistantPrivateReadTools.updateChat, {
      'message_id': 'old',
      'content': '修改后',
    });
    expect((await getHistory().loadAllRawMessages('a')).first.content, '修改后');
    final cache = await getHistory().loadCachedTimelineMessages('a');
    expect(cache.any((line) => line.displayText == '修改后'), isTrue);
    expect((await role()).lastMessage, '末尾');
    expect((await role()).lastMessageTime, 2);
  });

  test('单文本块修改保留块身份，与原文一致；精确替换拒绝重复及缺失', () async {
    await message(
      'text',
      text: '你好世界',
      blocks: [TextBlock(id: 'block', messageId: 'text', content: '你好世界')],
    );
    await call(AssistantPrivateReadTools.updateChat, {
      'message_id': 'text',
      'old_text': '世界',
      'new_text': '朋友',
    });
    final raw = (await getHistory().loadAllRawMessages('a')).single;
    expect(raw.content, '你好朋友');
    expect(raw.blocks!.single.id, 'block');
    expect((raw.blocks!.single as TextBlock).content, raw.content);
    await message('repeat', text: 'aaa');
    await expectLater(
      call(AssistantPrivateReadTools.updateChat, {
        'message_id': 'repeat',
        'old_text': 'aa',
        'new_text': 'b',
      }),
      throwsStateError,
    );
    await expectLater(
      call(AssistantPrivateReadTools.updateChat, {
        'message_id': 'repeat',
        'old_text': '不存在',
        'new_text': 'b',
      }),
      throwsStateError,
    );
  });

  test('正文修改只改文字，保留消息和文本块的其他存储信息', () async {
    await message(
      'text',
      text: '原文',
      blocks: [TextBlock(id: 'block', messageId: 'text', content: '原文')],
    );
    await (database.update(
      database.messages,
    )..where((m) => m.id.equals('text'))).write(
      const db.MessagesCompanion(
        summarized: Value(true),
        summarizedAt: Value(7),
        conflictOf: Value('origin'),
      ),
    );
    final block = await (database.select(
      database.messageBlocks,
    )..where((b) => b.id.equals('block'))).getSingle();
    final blockData = Map<String, dynamic>.from(jsonDecode(block.data) as Map)
      ..['extra'] = '保留';
    await (database.update(
      database.messageBlocks,
    )..where((b) => b.id.equals('block'))).write(
      db.MessageBlocksCompanion(
        data: Value(jsonEncode(blockData)),
        sourceBlockId: const Value('source'),
      ),
    );
    final beforeMessage =
        (await container.read(messageRepositoryProvider).getById('text'))!
            .toJson()
          ..remove('content');
    final beforeBlock =
        (await (database.select(
            database.messageBlocks,
          )..where((b) => b.id.equals('block'))).getSingle()).toJson()
          ..remove('data');
    await call(AssistantPrivateReadTools.updateChat, {
      'message_id': 'text',
      'content': '新正文',
    });
    final afterMessage =
        (await container.read(messageRepositoryProvider).getById('text'))!
            .toJson()
          ..remove('content');
    final afterBlock = await (database.select(
      database.messageBlocks,
    )..where((b) => b.id.equals('block'))).getSingle();
    expect(afterMessage, beforeMessage);
    expect(afterBlock.toJson()..remove('data'), beforeBlock);
    expect(jsonDecode(afterBlock.data), {...blockData, 'content': '新正文'});
  });

  test('复杂消息拒绝修改并保留原始数据', () async {
    await message('rich', text: '原文', payload: {'processedText': '显示内容'});
    await expectLater(
      call(AssistantPrivateReadTools.updateChat, {
        'message_id': 'rich',
        'content': '不能改',
      }),
      throwsStateError,
    );
    expect((await getHistory().loadAllRawMessages('a')).single.rawPayload, {
      'processedText': '显示内容',
    });
  });

  for (final withRound in [false, true]) {
    test('真实普通助手存储形态可修改（单轮结构 $withRound），原文、显示与缓存一致', () async {
      final payload = ChatMessageProjectionCodec.buildRawAssistantPayload(
        apiResult: ApiCallResult(
          replyText: '常见助手回复',
          processedText: '常见助手回复',
          pluginEvents: const [],
          toolResults: const [],
          reasoning: '保留原思考',
          replyRounds: withRound
              ? [
                  const ReplyRound(
                    replyText: '常见助手回复',
                    rawText: '常见助手回复',
                    processedText: '常见助手回复',
                    reasoning: '轮内思考',
                  ),
                ]
              : const [],
        ),
      );
      await getHistory().appendMessage(
        conversationId: 'a',
        message: Message(
          id: 'assistant',
          role: 'assistant',
          content: '常见助手回复',
          rawPayload: payload,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );
      await call(AssistantPrivateReadTools.updateChat, {
        'message_id': 'assistant',
        'old_text': '常见',
        'new_text': '已改',
      });
      final raw = (await getHistory().loadAllRawMessages('a')).single;
      expect(raw.content, '已改助手回复');
      for (final key in ['rawReplyText', 'displayReplyText', 'processedText']) {
        expect(raw.rawPayload![key], raw.content);
      }
      expect(raw.rawPayload!['reasoning'], '保留原思考');
      if (withRound) {
        final round = (raw.rawPayload!['replyRounds'] as List).single as Map;
        expect(round['replyText'], raw.content);
        expect(round['rawText'], raw.content);
        expect(round['processedText'], raw.content);
        expect(round['reasoning'], '轮内思考');
      }
      expect((await role()).lastMessage, '已改助手回复');
      final cache = await getHistory().loadCachedTimelineMessages('a');
      expect(cache.any((m) => m.displayText.contains('常见助手回复')), isFalse);
      expect(cache.any((m) => m.displayText.contains('已改助手回复')), isTrue);
    });
  }

  for (final condition in [
    'foreign',
    'deleted',
    'replaced',
    'sending',
    'missing',
  ]) {
    test('修改与批删拒绝 $condition，整批无部分删除', () async {
      await message('safe');
      if (condition != 'missing') {
        await message('bad', owner: condition == 'foreign' ? 'b' : 'a');
      }
      final state = switch (condition) {
        'deleted' => const db.MessagesCompanion(deletedAt: Value(5)),
        'replaced' => const db.MessagesCompanion(replacedBy: Value('next')),
        'sending' => const db.MessagesCompanion(status: Value('sending')),
        _ => null,
      };
      if (state != null) {
        await (database.update(
          database.messages,
        )..where((row) => row.id.equals('bad'))).write(state);
      }
      await expectLater(
        call(AssistantPrivateReadTools.updateChat, {
          'message_id': 'bad',
          'content': '无效修改',
        }),
        throwsStateError,
      );
      await expectLater(
        call(AssistantPrivateReadTools.deleteChat, {
          'message_ids': ['safe', 'bad'],
        }),
        throwsStateError,
      );
      expect(
        (await container.read(messageRepositoryProvider).getById('safe'))!
            .deletedAt,
        isNull,
      );
    });
  }

  test('批删去重并清理被删话题边界，保留其他角色', () async {
    await message('a1');
    await message('b1', owner: 'b');
    await summaries.commitManual(await summaries.manualSnapshot('a'), '摘要');
    final result = await call(AssistantPrivateReadTools.deleteChat, {
      'message_ids': ['a1', 'a1'],
    });
    expect(result['deleted'], 1);
    expect((await role()).contextStartMessageId, isNull);
    expect(await getHistory().loadAllRawMessages('a'), isEmpty);
    expect((await getHistory().loadAllRawMessages('b')).single.id, 'b1');
    await expectLater(
      call(AssistantPrivateReadTools.deleteChat, {
        'message_ids': [''],
      }),
      throwsArgumentError,
    );
  });

  test('批删数据库故障整批回滚，并发重复删除只有一批生效', () async {
    await message('one');
    await message('two');
    await database.customStatement("""
      CREATE TRIGGER reject_private_delete BEFORE UPDATE ON messages
      WHEN OLD.id = 'two' AND NEW.deleted_at IS NOT NULL
      BEGIN SELECT RAISE(ABORT, 'test failure'); END
    """);
    await expectLater(
      call(AssistantPrivateReadTools.deleteChat, {
        'message_ids': ['one', 'two'],
      }),
      throwsA(anything),
    );
    expect((await getHistory().loadAllRawMessages('a')).map((m) => m.id), [
      'one',
      'two',
    ]);
    await database.customStatement('DROP TRIGGER reject_private_delete');
    Future<bool> remove() async {
      try {
        await call(AssistantPrivateReadTools.deleteChat, {
          'message_ids': ['one', 'two'],
        });
        return true;
      } on StateError {
        return false;
      }
    }

    final results = await Future.wait([remove(), remove()]);
    expect(results.where((result) => result), hasLength(1));
    expect(await getHistory().loadAllRawMessages('a'), isEmpty);
  });

  test('原文修改提交前再次检查生成状态，失败不改原文', () async {
    await message('m1');
    var checks = 0;
    await expectLater(
      getHistory().updateRawMessageText(
        conversationId: 'a',
        messageId: 'm1',
        content: '不能保存',
        ensureWritable: () {
          if (++checks == 2) throw StateError('生成已开始');
        },
      ),
      throwsStateError,
    );
    expect((await getHistory().loadAllRawMessages('a')).single.content, '原文');
  });

  test('整理当前话题走真实提交并通知，手动删除恢复原边界', () async {
    await message('m1');
    callbackGate = Completer<void>();
    final revision = contextSourceDigest(
      await getHistory().loadAllRawMessages('a'),
    );
    final result = await call(AssistantPrivateReadTools.editSummary, {
      'mode': 'compact_current_topic',
      'summary': '归档摘要',
      'expected_revision': revision,
    });
    expect(result['undoable'], isFalse);
    expect((await role()).contextStartMessageId, 'm1');
    expect(compacted, ['a']);
    expect(published, ['a']);
    callbackGate!.complete();
    // The asynchronous memory notification must run outside a closed transaction.
    await callbackWork;
    await call(AssistantPrivateReadTools.deleteSummary, {'kind': 'manual'});
    expect((await role()).contextStartMessageId, isNull);
    expect(await getHistory().loadAllRawMessages('a'), hasLength(1));
  });

  test('整理拒绝过期来源，自动摘要删除只影响当前话题', () async {
    await message('m1');
    await expectLater(
      call(AssistantPrivateReadTools.editSummary, {
        'mode': 'compact_current_topic',
        'summary': '摘要',
        'expected_revision': 'stale',
      }),
      throwsStateError,
    );
    final snapshot = await summaries.manualSnapshot('a');
    final oldAuto = await summaries.saveAuto(snapshot, '旧自动');
    await summaries.commitManual(snapshot, '手动');
    await message('m2');
    final all = await getHistory().loadAllRawMessages('a');
    await summaries.saveAuto(
      ContextSnapshot(
        ownerId: 'a',
        previousBoundaryId: 'm1',
        allMessages: [all.last],
        messages: [all.last],
        previous: null,
      ),
      '新自动',
    );
    await call(AssistantPrivateReadTools.deleteSummary, {'kind': 'auto'});
    final history = await summaries.listHistory('a');
    expect(
      history
          .where((e) => e.record.kind == ContextSummaryKind.auto)
          .single
          .record
          .id,
      oldAuto.id,
    );
    expect(await summaries.manualFor('a', 'm1'), isNotNull);
  });

  test('真实记忆维护回调在压缩提交后可继续异步写入数据库', () async {
    await message('m1');
    final agent = _MemoryAgent();
    keeper = MemoryKeeperService(
      store: container.read(memoryStoreProvider),
      loadMessages: (id) => getHistory().loadAllRawMessages(id),
      compactedBoundaries: summaries.compactedBoundaries,
      agentFactory: () async => agent,
      allowed: (_) async => true,
    );
    await call(AssistantPrivateReadTools.editSummary, {
      'mode': 'compact_current_topic',
      'summary': '归档摘要',
    });
    await agent.started.future;
    agent.resume.complete();
    await keeper!.idle('a');
    final memories = await container.read(memoryStoreProvider).list('a');
    expect(memories.single.content, '已在提交后整理');
    expect(
      (await container.read(memoryStoreProvider).progress('a')).untilId,
      'm1',
    );
  });

  test('记忆新增默认锁定，修改可解锁，跨角色修改/删除拒绝', () async {
    final result = await call(AssistantPrivateReadTools.writeMemory, {
      'layer': 'archive',
      'title': '标题',
      'content': '内容',
    });
    final id = result['memory']['id'] as String;
    expect(result['memory']['locked'], isTrue);
    final updated = await call(AssistantPrivateReadTools.writeMemory, {
      'memory_id': id,
      'layer': 'core',
      'title': '新标题',
      'content': '新内容',
      'locked': false,
    });
    expect(updated['memory']['locked'], isFalse);
    expect(updated['memory']['layer'], 'core');
    await expectLater(
      call(AssistantPrivateReadTools.writeMemory, {
        'role_id': 'b',
        'memory_id': id,
        'layer': 'core',
        'title': '错',
        'content': '错',
      }),
      throwsStateError,
    );
    await expectLater(
      call(AssistantPrivateReadTools.deleteMemory, {
        'role_id': 'b',
        'memory_id': id,
      }),
      throwsStateError,
    );
    await call(AssistantPrivateReadTools.deleteMemory, {'memory_id': id});
    expect(await container.read(memoryStoreProvider).get('a', id), isNull);
  });

  test('记忆保存后锁定更新失败则内容一起回滚', () async {
    final result = await call(AssistantPrivateReadTools.writeMemory, {
      'layer': 'archive',
      'title': '标题',
      'content': '原内容',
    });
    final id = result['memory']['id'] as String;
    await database.customStatement("""
      CREATE TRIGGER reject_unlock BEFORE UPDATE OF locked ON memory_items
      WHEN NEW.locked = 0
      BEGIN SELECT RAISE(ABORT, 'test failure'); END
    """);
    await expectLater(
      call(AssistantPrivateReadTools.writeMemory, {
        'memory_id': id,
        'layer': 'archive',
        'title': '新标题',
        'content': '新内容',
        'locked': false,
      }),
      throwsA(anything),
    );
    final stored = (await container.read(memoryStoreProvider).get('a', id))!;
    expect(stored.content, '原内容');
    expect(stored.locked, isTrue);
  });

  test('角色生成中仍可写改删自身记忆，但读取授权不能代替写审批', () async {
    container.read(conversationSendingProvider('a').notifier).state = true;
    final created = await call(AssistantPrivateReadTools.writeMemory, {
      'layer': 'archive',
      'title': '生成中记录',
      'content': '初始内容',
    });
    final id = created['memory']['id'] as String;
    final updated = await call(AssistantPrivateReadTools.writeMemory, {
      'memory_id': id,
      'layer': 'archive',
      'title': '生成中修改',
      'content': '修改内容',
      'locked': false,
    });
    expect(updated['memory']['content'], '修改内容');
    expect(updated['memory']['locked'], isFalse);
    await tools.grants.grant('a');
    final refused = await call(AssistantPrivateReadTools.deleteMemory, {
      'memory_id': id,
    }, approved: false);
    expect(refused['error'], 'invalid');
    expect(await container.read(memoryStoreProvider).get('a', id), isNotNull);
    await call(AssistantPrivateReadTools.deleteMemory, {'memory_id': id});
    expect(await container.read(memoryStoreProvider).get('a', id), isNull);
    expect(container.read(conversationSendingProvider('a')), isTrue);
    await expectLater(
      call(AssistantPrivateReadTools.appendChat, {'content': '生成中不可追加'}),
      throwsStateError,
    );
    await expectLater(
      call(AssistantPrivateReadTools.deleteSummary, {'kind': 'auto'}),
      throwsStateError,
    );
  });

  test('私有写入有逐次审批和目标生成/隐私校验，输入类型错误不写入', () async {
    await tools.grants.grant('a');
    expect(
      (await call(AssistantPrivateReadTools.appendChat, {
        'sender_role': 'user',
        'content': '拒绝',
      }, approved: false))['error'],
      'invalid',
    );
    container.read(conversationSendingProvider('a').notifier).state = true;
    await expectLater(
      call(AssistantPrivateReadTools.appendChat, {
        'sender_role': 'user',
        'content': '拒绝',
      }),
      throwsStateError,
    );
    container.read(conversationSendingProvider('a').notifier).state = false;
    await expectLater(
      call(AssistantPrivateReadTools.writeMemory, {
        'layer': 'wrong',
        'title': '标题',
        'content': '内容',
      }),
      throwsArgumentError,
    );
    await expectLater(
      call(AssistantPrivateReadTools.writeMemory, {
        'layer': 'archive',
        'title': '标题',
        'content': '内容',
        'locked': 'false',
      }),
      throwsArgumentError,
    );
    await (database.update(database.conversations)
          ..where((row) => row.id.equals('a')))
        .write(const db.ConversationsCompanion(isHidden: Value(true)));
    // Bypass the cached role list to exercise the final database boundary.
    await expectLater(
      container.read(assistantPrivateWriteProvider)(
        AssistantPrivateReadTools.appendChat,
        {'role_id': 'a', 'sender_role': 'user', 'content': '拒绝'},
      ),
      throwsStateError,
    );
    expect(await getHistory().loadAllRawMessages('a'), isEmpty);
  });
}
