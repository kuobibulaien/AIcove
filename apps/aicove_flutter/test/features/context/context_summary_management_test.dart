import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/context/application/context_manager.dart';
import 'package:aicove_flutter/src/features/context/data/sqlite_context_summary_store.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late db.AppDatabase database;
  late SqliteContextSummaryStore store;
  late List<Message> messages;

  Message message(String id, [String text = '原文']) => Message(
    id: id,
    role: 'user',
    content: text,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1),
  );

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

  Future<String?> boundary() async => (await (database.select(
    database.conversations,
  )..where((t) => t.id.equals('a'))).getSingle()).contextStartMessageId;

  Future<ContextSummary> auto() async {
    final snapshot = ContextSnapshot(
      ownerId: 'a',
      previousBoundaryId: await boundary(),
      allMessages: List.of(messages),
      messages: List.of(messages),
      previous: null,
    );
    return store.saveAuto(snapshot, '自动摘要');
  }

  Future<ContextSummaryChange> update(
    ContextSummary record, {
    String text = '修订摘要',
    String? expectedBoundary,
    String ownerId = 'a',
  }) => store.updateCurrent(
    ownerId: ownerId,
    kind: record.kind,
    expectedBoundaryId: expectedBoundary,
    expectedSummary: record,
    summary: text,
  );

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    messages = [message('m1')];
    store = SqliteContextSummaryStore(database, (_) async => List.of(messages));
    await owner('a');
    await owner('b');
  });
  tearDown(() => database.close());

  test('历史保留失效记录并隔离角色，修改来源后拒绝保存', () async {
    final record = await auto();
    expect((await store.listHistory('a')).single.isValid, isTrue);
    expect(await store.listHistory('b'), isEmpty);
    messages = [message('m1', '已编辑')];
    final history = await store.listHistory('a');
    expect(history.single.record.id, record.id);
    expect(history.single.isCurrent, isTrue);
    expect(history.single.isValid, isFalse);
    await expectLater(
      update(record),
      throwsA(isA<ContextCompactionException>()),
    );
  });

  test('修改只换正文并返回前后值；旧版本、其他角色、无效正文均拒绝', () async {
    final record = await auto();
    final change = await update(record, text: '  修订摘要  ');
    expect(change.before.summary, '自动摘要');
    expect(change.after.summary, '修订摘要');
    expect(change.after.id, record.id);
    expect(change.after.sourceIds, record.sourceIds);
    expect(change.after.sourceDigest, record.sourceDigest);
    expect(
      change.after.createdAt.millisecondsSinceEpoch,
      greaterThanOrEqualTo(record.createdAt.millisecondsSinceEpoch),
    );
    expect(change.after.boundaryId, record.boundaryId);
    expect(change.after.topicBoundary, record.topicBoundary);
    await expectLater(
      update(record),
      throwsA(isA<ContextCompactionException>()),
    );
    await expectLater(
      update(change.after, ownerId: 'b'),
      throwsA(isA<ContextCompactionException>()),
    );
    await expectLater(
      update(change.after, text: ' '),
      throwsA(isA<ContextCompactionException>()),
    );
    await expectLater(
      update(change.after, text: 'a' * 32769),
      throwsA(isA<ContextCompactionException>()),
    );
    expect((await store.listHistory('a')).single.record.summary, '修订摘要');
  });

  test('手动摘要可改正文但不移动边界；切换话题后拒绝旧状态', () async {
    final first = await store.commitManual(
      await store.manualSnapshot('a'),
      '手动',
    );
    final change = await update(first, expectedBoundary: 'm1');
    expect(await boundary(), 'm1');
    expect((await store.manualFor('a', 'm1'))!.summary, change.after.summary);
    messages.add(message('m2'));
    await store.commitManual(await store.manualSnapshot('a'), '下一段');
    await expectLater(
      update(change.after, expectedBoundary: 'm1'),
      throwsA(isA<ContextCompactionException>()),
    );
    final old = (await store.listHistory(
      'a',
    )).firstWhere((entry) => entry.record.id == first.id);
    expect(old.isCurrent, isFalse);
    expect(old.isValid, isTrue);
  });

  test('删除自动摘要只影响当前话题，不删除手动和旧话题摘要', () async {
    final oldAuto = await auto();
    final manual = await store.commitManual(
      await store.manualSnapshot('a'),
      '手动',
    );
    messages.add(message('m2'));
    await store.saveAuto(
      ContextSnapshot(
        ownerId: 'a',
        previousBoundaryId: 'm1',
        allMessages: [messages.last],
        messages: [messages.last],
        previous: null,
      ),
      '新话题自动摘要',
    );
    await expectLater(
      store.deleteCurrentAuto(ownerId: 'a', expectedBoundaryId: null),
      throwsA(isA<ContextCompactionException>()),
    );
    await store.deleteCurrentAuto(ownerId: 'a', expectedBoundaryId: 'm1');
    expect((await store.listHistory('a')).map((e) => e.record.id).toSet(), {
      oldAuto.id,
      manual.id,
    });
    expect((await store.manualFor('a', 'm1'))!.summary, '手动');
    expect(await boundary(), 'm1');
    await store.deleteCurrentAuto(ownerId: 'a', expectedBoundaryId: 'm1');
  });

  test('边界消息删除后历史失效，不能用管理接口复活摘要', () async {
    final record = await auto();
    messages.clear();
    expect((await store.listHistory('a')).single.isValid, isFalse);
    await expectLater(
      update(record),
      throwsA(isA<ContextCompactionException>()),
    );
  });

  test('末尾失败消息可以是边界但不是摘要来源，沿用现有有效性定义', () async {
    messages.add(
      Message(
        id: 'failed',
        role: 'assistant',
        content: '',
        status: 'failed',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2),
      ),
    );
    final record = await store.commitManual(
      await store.manualSnapshot('a'),
      '手动',
    );
    expect(record.boundaryId, 'failed');
    expect(record.sourceIds, ['m1']);
    expect((await store.listHistory('a')).single.isValid, isTrue);
    final change = await update(record, expectedBoundary: 'failed');
    expect(
      (await store.manualFor('a', 'failed'))!.summary,
      change.after.summary,
    );
  });

  test('数据库更新失败回滚正文，原摘要和边界不变', () async {
    final record = await store.commitManual(
      await store.manualSnapshot('a'),
      '手动',
    );
    await database.customStatement('''
      CREATE TRIGGER reject_summary_update BEFORE UPDATE ON context_summaries
      BEGIN SELECT RAISE(ABORT, 'test rejection'); END
    ''');
    await expectLater(
      update(record, expectedBoundary: 'm1'),
      throwsA(anything),
    );
    expect((await store.manualFor('a', 'm1'))!.summary, '手动');
    expect(await boundary(), 'm1');
  });

  test('工具压缩复用提交入口并通知边界和记忆，拒绝旧来源与生成中操作', () async {
    final published = <String>[];
    final compacted = <String>[];
    var sending = false;
    final manager = ContextManager(
      store: store,
      loadMessages: (_) async => List.of(messages),
      readBoundary: (_) => boundary(),
      summarizerFactory: () => throw StateError('不应调用摘要模型'),
      publishBoundary: (id) async => published.add(id),
      ensureIdle: (_) {
        if (sending) throw const ContextCompactionException('生成中');
      },
      onCompacted: compacted.add,
    );
    final snapshot = await store.manualSnapshot('a');
    final draft = ManualCompactionDraft(snapshot: snapshot, summary: '新摘要');
    messages[0] = message('m1', '变更');
    await expectLater(
      manager.commit(draft, '新摘要'),
      throwsA(isA<ContextCompactionException>()),
    );
    expect(await boundary(), isNull);
    sending = true;
    await expectLater(
      manager.commit(draft, '新摘要'),
      throwsA(isA<ContextCompactionException>()),
    );
    sending = false;
    final result = await manager.commit(
      ManualCompactionDraft(
        snapshot: await store.manualSnapshot('a'),
        summary: '新摘要',
      ),
      '新摘要',
    );
    expect(result.summary, '新摘要');
    expect(await boundary(), 'm1');
    expect(published, ['a']);
    expect(compacted, ['a']);
    expect(messages.length, 1);
  });
}
