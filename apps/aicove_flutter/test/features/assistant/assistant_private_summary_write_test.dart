import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateOutcome, ToolCallScope;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_private_read_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/assistant_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/context/data/sqlite_context_summary_store.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/context/providers/context_providers.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late db.AppDatabase database;
  late ProviderContainer container;
  late SqliteContextSummaryStore store;
  late AssistantPrivateDataChanges changes;
  late AssistantPrivateReadTools tools;
  late FileChangeJournal journal;
  late Directory root;
  late List<Message> messages;
  final now = DateTime.fromMillisecondsSinceEpoch(1);

  Future<Map<String, dynamic>> call(
    Map<String, dynamic> args, {
    bool approved = true,
    bool aggregate = false,
  }) async {
    final scope = ToolCallScope()
      ..outcome = approved ? GateOutcome.approved : GateOutcome.allowed;
    final result = await scope.run(
      () => tools
          .tools()
          .singleWhere(
            (tool) =>
                tool.name ==
                (aggregate
                    ? AssistantPrivateReadTools.roleContext
                    : AssistantPrivateReadTools.editSummary),
          )
          .handler(
            aggregate
                ? {'target': 'summary', 'action': 'update', ...args}
                : args,
          ),
    );
    return jsonDecode(result!) as Map<String, dynamic>;
  }

  Map<String, dynamic> args([String text = '修订']) => {
    'role_id': 'a',
    'mode': 'update_current',
    'kind': 'manual',
    'summary': text,
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory(
      'test/features/assistant',
    ).createTemp('.summary_write_');
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'a',
            title: 'a',
            displayName: 'a',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    messages = [Message(id: 'm1', role: 'user', content: '原文', createdAt: now)];
    store = SqliteContextSummaryStore(database, (_) async => List.of(messages));
    await store.commitManual(await store.manualSnapshot('a'), '旧摘要');
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        contextSummaryStoreProvider.overrideWithValue(store),
      ],
    );
    changes = container.read(assistantPrivateDataChangesProvider);
    journal = FileChangeJournal(
      file: () async => File('${root.path}/journal.json'),
      appliers: {assistantPrivateDataChangeKind: changes},
    );
    tools = AssistantPrivateReadTools(
      roles: () async => [
        Conversation(
          id: 'a',
          title: 'a',
          displayName: 'a',
          createdAt: now,
          updatedAt: now,
        ),
      ],
      rolesNow: () => [],
      grants: AssistantReadGrants(),
      messages: (_, {required limit, before, keyword}) async => [],
      memories: (_) async => [],
      changes: changes,
      journal: journal,
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await root.delete(recursive: true);
  });

  test('聚合摘要入口保留正文更新、版本检查与撤销', () async {
    final before = await changes.summary('a', ContextSummaryKind.manual);
    final denied = await call(args(), approved: false, aggregate: true);
    expect(denied['error'], 'invalid');
    expect(await journal.recent(), isEmpty);
    final result = await call(args('聚合摘要'), aggregate: true);
    expect(result['ok'], true);
    expect((await store.manualFor('a', 'm1'))!.summary, '聚合摘要');
    await journal.undo(result['change_id'] as String);
    expect(await changes.summary('a', ContextSummaryKind.manual), before);
  });

  test('写摘要按既有工具协议审批，真实落库并可恢复正文与时间', () async {
    final before = await changes.summary('a', ContextSummaryKind.manual);
    expect(
      tools.riskOf(AssistantPrivateReadTools.editSummary, args()),
      AssistantRisk.review,
    );
    final result = await call(args());
    expect(result['ok'], isTrue);
    final saved = (await store.manualFor('a', 'm1'))!;
    expect(saved.summary, '修订');
    expect(
      saved.createdAt.millisecondsSinceEpoch,
      result['after']['created_at'],
    );
    await journal.undo(result['change_id'] as String);
    expect(await changes.summary('a', ContextSummaryKind.manual), before);
  });

  test('读授权不等于写审批，拒绝后不生成日志或修改摘要', () async {
    await tools.grants.grant('a');
    final result = await call(args(), approved: false);
    expect(result['error'], 'invalid');
    expect(await journal.recent(), isEmpty);
    expect((await store.manualFor('a', 'm1'))!.summary, '旧摘要');
  });

  test('指定 kind 而省略 mode 时默认修改当前摘要', () async {
    final input = args()..remove('mode');
    expect((await call(input))['ok'], isTrue);
    expect((await store.manualFor('a', 'm1'))!.summary, '修订');
  });

  test('来源失效或读取的摘要已被改动时拒绝保存', () async {
    final stale = args()..['expected_summary'] = '更早的摘要';
    expect((await call(stale))['error'], 'invalid');
    messages = [
      Message(id: 'm1', role: 'user', content: '原文已改', createdAt: now),
    ];
    expect((await call(args()))['error'], 'invalid');
    expect(await journal.recent(), isEmpty);
  });

  test('后续改动不被撤销覆盖', () async {
    final result = await call(args());
    final record = (await store.manualFor('a', 'm1'))!;
    await store.updateCurrent(
      ownerId: 'a',
      kind: ContextSummaryKind.manual,
      expectedBoundaryId: 'm1',
      expectedSummary: record,
      summary: '后来修改',
    );
    await expectLater(
      journal.undo(result['change_id'] as String),
      throwsStateError,
    );
    expect((await store.manualFor('a', 'm1'))!.summary, '后来修改');
  });

  test('目标角色生成中不能写入或撤销，其他角色生成不阻止目标修改', () async {
    container.read(conversationSendingProvider('a').notifier).state = true;
    await expectLater(call(args()), throwsStateError);
    expect(await journal.recent(), isEmpty);
    expect((await store.manualFor('a', 'm1'))!.summary, '旧摘要');
    container.read(conversationSendingProvider('a').notifier).state = false;
    container.read(conversationSendingProvider('b').notifier).state = true;
    final result = await call(args());
    expect(result['ok'], isTrue);
    container.read(conversationSendingProvider('a').notifier).state = true;
    await expectLater(
      journal.undo(result['change_id'] as String),
      throwsStateError,
    );
    expect((await store.manualFor('a', 'm1'))!.summary, '修订');
    container.read(conversationSendingProvider('a').notifier).state = false;
    await journal.undo(result['change_id'] as String);
    expect((await store.manualFor('a', 'm1'))!.summary, '旧摘要');
  });

  test('即使角色列表尚未更新，数据库中的隐私状态也会阻止修改和撤销', () async {
    final result = await call(args());
    // The database adapter is the final authority, rather than cached roles.
    await (database.update(database.conversations)
          ..where((row) => row.id.equals('a')))
        .write(const db.ConversationsCompanion(isHidden: Value(true)));
    await expectLater(
      journal.undo(result['change_id'] as String),
      throwsStateError,
    );
    expect((await store.manualFor('a', 'm1'))!.summary, '修订');
  });
}
