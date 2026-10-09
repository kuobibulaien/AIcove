import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/conversation_state/data/sqlite_conversation_state_store.dart';
import 'package:aicove_flutter/src/features/conversation_state/domain/conversation_state_port.dart';
import 'package:aicove_flutter/src/features/conversation_state/domain/mvu_engine.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const conv = 'c1';
String greetingId(String id) => 'msg_greeting_$id';

MvuSourceSnapshot sources([
  String content = '{"hp": [10, "生命"], "items": []}',
]) => MvuSourceSnapshot(
  sources: [MvuInitSource(name: '[InitVar]', content: content)],
);

void main() {
  late db.AppDatabase database;
  late SqliteConversationStateStore store;
  var clock = 0;

  Future<void> addMessage(
    String id,
    String text, {
    String role = 'assistant',
    String status = 'sent',
  }) async {
    clock++;
    await database.customStatement(
      'INSERT INTO messages (id, conversation_id, role, content, status, raw_payload, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        conv,
        role,
        text,
        status,
        jsonEncode({'rawReplyText': text}),
        clock,
      ],
    );
  }

  Future<int> stateRows() async =>
      (await database
              .customSelect('SELECT COUNT(*) AS n FROM message_states')
              .getSingle())
          .read<int>('n');

  Future<Object?> hp([MvuSourceSnapshot? snapshot]) async => (await store.read(
    conv,
    sources: snapshot ?? sources(),
  )).mvu?.statData['hp'];

  setUp(() async {
    clock = 0;
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.customStatement(
      "INSERT INTO conversations (id, title, display_name, created_at, updated_at) "
      "VALUES ('$conv', 't', 'd', 1, 1)",
    );
    store = SqliteConversationStateStore(
      database,
      resolveSources: (_) async => sources(),
      greetingMessageId: greetingId,
    );
  });

  tearDown(() => database.close());

  test('从基线沿链重放；开场白里的更新只执行一次', () async {
    await addMessage(
      greetingId(conv),
      "你好<UpdateVariable>_.add('hp', 5);</UpdateVariable>",
    );
    await addMessage('u1', '嗨', role: 'user');
    await addMessage('a1', "<UpdateVariable>_.add('hp', 1);</UpdateVariable>");
    expect(await hp(), [16, '生命']);
    expect(await hp(), [16, '生命'], reason: '重复读取不重复累加');
  });

  test('删除中间消息、恢复、重新生成后等于从头重放', () async {
    await addMessage('a1', "_.add('hp', 1);");
    await addMessage('a2', "_.add('hp', 2);");
    await addMessage('a3', "_.add('hp', 4);");
    expect(await hp(), [17, '生命']);

    await database.customStatement(
      "UPDATE messages SET deleted_at = 1 WHERE id = 'a2'",
    );
    expect(await hp(), [15, '生命']);

    await database.customStatement(
      "UPDATE messages SET deleted_at = NULL WHERE id = 'a2'",
    );
    expect(await hp(), [17, '生命']);

    // 重新生成：旧回复被替换，新回复不同。
    await database.customStatement(
      "UPDATE messages SET replaced_by = 'a3b' WHERE id = 'a3'",
    );
    await addMessage('a3b', "_.add('hp', 100);");
    expect(await hp(), [113, '生命']);
  });

  test('编辑原文后从该条起重算；failed / sending 消息不计入', () async {
    await addMessage('a1', "_.add('hp', 1);");
    await addMessage('a2', "_.add('hp', 2);");
    expect(await hp(), [13, '生命']);
    await database.customStatement(
      "UPDATE messages SET raw_payload = ? WHERE id = 'a1'",
      [
        jsonEncode({'rawReplyText': "_.add('hp', 5);"}),
      ],
    );
    expect(await hp(), [17, '生命']);
    await addMessage('a3', "_.add('hp', 50);", status: 'failed');
    await addMessage('a4', "_.add('hp', 50);", status: 'sending');
    expect(await hp(), [17, '生命']);
  });

  test('漏写的缓存与执行器版本变化都能自愈', () async {
    await addMessage('a1', "_.add('hp', 1);");
    await addMessage('a2', "_.add('hp', 2);");
    expect(await hp(), [13, '生命']);
    await database.customStatement(
      "DELETE FROM message_states WHERE anchor_id = 'a2'",
    );
    expect(await hp(), [13, '生命']);
    await database.customStatement(
      "UPDATE message_states SET engine_version = 0 WHERE anchor_id = 'a1'",
    );
    expect(await hp(), [13, '生命']);
    final versions = await database
        .customSelect('SELECT DISTINCT engine_version AS v FROM message_states')
        .get();
    expect(versions.map((r) => r.read<int>('v')), [MvuEngine.version]);
  });

  test('没有变化的消息不重复存状态，读取时向前找最近一份', () async {
    await addMessage('a1', "_.add('hp', 1);");
    await addMessage('a2', '普通回复');
    await addMessage('a3', '普通回复');
    expect(await hp(), [11, '生命']);
    final empty = await database
        .customSelect(
          'SELECT COUNT(*) AS n FROM message_states WHERE data_json IS NULL',
        )
        .getSingle();
    expect(empty.read<int>('n'), 2);
    // 再读一次走全命中路径。
    expect(await hp(), [11, '生命']);
  });

  test('卡片没用 MVU 时不建基线也不写行', () async {
    await addMessage('a1', '普通回复');
    final view = await store.read(
      conv,
      sources: const MvuSourceSnapshot(sources: []),
    );
    expect(view.active, isFalse);
    expect(await stateRows(), 0);
  });

  test('初始化失败不生效；修正来源后数据库里的基线被更新', () async {
    await addMessage('a1', "_.add('hp', 1);");
    final bad = sources('{"hp": <%= 1 %>}');
    final failed = await store.read(conv, sources: bad);
    expect(failed.active, isFalse);
    expect(failed.diagnostics.single, contains('EJS'));
    expect(await hp(), [11, '生命']);
    final base = await database
        .customSelect(
          "SELECT status FROM message_states WHERE anchor_id = '__init__'",
        )
        .getSingle();
    expect(base.read<String>('status'), 'ready');
  });

  test('基线冻结：世界书改动不影响已初始化的会话', () async {
    await addMessage('a1', "_.add('hp', 1);");
    expect(await hp(), [11, '生命']);
    expect(await hp(sources('{"hp": [99, "生命"]}')), [11, '生命']);
  });

  test('换开场白后替换基线并整链重算', () async {
    await addMessage(greetingId(conv), '<initvar>{"hp": [1, "生命"]}</initvar>');
    await addMessage('a1', "_.add('hp', 1);");
    expect(await hp(), [2, '生命']);
    await database.customStatement(
      "UPDATE messages SET raw_payload = ? WHERE id = ?",
      [
        jsonEncode({'rawReplyText': '<initvar>{"hp": [50, "生命"]}</initvar>'}),
        greetingId(conv),
      ],
    );
    final view = await store.read(conv, sources: sources());
    expect(view.mvu!.statData['hp'], [51, '生命']);
    expect(view.diagnostics, contains('开场白已变化，已按当前来源重新初始化'));
  });

  test('同一会话的并发读取串行执行，结果一致', () async {
    for (var i = 0; i < 20; i++) {
      await addMessage('a$i', "_.add('hp', 1);");
    }
    final results = await Future.wait([for (var i = 0; i < 5; i++) hp()]);
    expect(results.map(jsonEncode).toSet(), hasLength(1));
    expect(results.first, [30, '生命']);
  });

  test('重算过程中提交的编辑在下一次读取时生效，不被旧结果覆盖', () async {
    await addMessage('a1', "_.add('hp', 1);");
    final pending = hp();
    await database.customStatement(
      "UPDATE messages SET raw_payload = ? WHERE id = 'a1'",
      [
        jsonEncode({'rawReplyText': "_.add('hp', 3);"}),
      ],
    );
    await pending;
    expect(await hp(), [13, '生命']);
  });

  test('purgeExpired 只删被清除消息的缓存并保留基线；deleteByConversation 全清', () async {
    await addMessage('a1', "_.add('hp', 1);");
    await addMessage('a2', "_.add('hp', 2);");
    await hp();
    await database.customStatement(
      "UPDATE messages SET deleted_at = 1, purge_at = 1 WHERE id = 'a2'",
    );
    final repo = MessageRepository(database);
    await repo.purgeExpired();
    final anchors =
        (await database
                .customSelect(
                  'SELECT anchor_id FROM message_states ORDER BY anchor_id',
                )
                .get())
            .map((r) => r.read<String>('anchor_id'));
    expect(anchors, ['__init__', 'a1']);
    await repo.deleteByConversation(conv);
    expect(await stateRows(), 0);
  });

  test('会话物理删除时级联清除状态', () async {
    // 生产连接在 _openConnection 里开启外键，测试库需手动开启。
    await database.customStatement('PRAGMA foreign_keys = ON');
    await addMessage('a1', "_.add('hp', 1);");
    await hp();
    await database.customStatement('DELETE FROM messages');
    await database.customStatement(
      "DELETE FROM conversations WHERE id = '$conv'",
    );
    expect(await stateRows(), 0);
  });

  test('refresh 失败只记日志不抛出', () async {
    final broken = SqliteConversationStateStore(
      database,
      resolveSources: (_) async => throw StateError('boom'),
      greetingMessageId: greetingId,
    );
    await expectLater(broken.refresh(conv), completes);
  });

  test('旧库 v20 升级到 v21 建表', () async {
    await database.customStatement('DROP TABLE message_states');
    await database.migration.onUpgrade(Migrator(database), 20, 21);
    await addMessage('a1', "_.add('hp', 1);");
    expect(await hp(), [11, '生命']);
  });
}
