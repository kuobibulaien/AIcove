import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/features/conversation_state/data/sqlite_conversation_state_store.dart';
import 'package:aicove_flutter/src/features/conversation_state/domain/conversation_state_port.dart';
import 'package:aicove_flutter/src/features/conversation_state/domain/mvu_engine.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR0071 验收 8：只记录数值，不设阈值。`MVU_PERF=1` 时运行。
void main() {
  final enabled = Platform.environment['MVU_PERF'] == '1';

  for (final count in [500, 2000]) {
    test(
      '$count 条消息的状态读取耗时',
      () async {
        final root = await Directory.systemTemp.createTemp('mvu_perf_');
        final database = db.AppDatabase.forTesting(
          NativeDatabase.createInBackground(File('${root.path}/p.sqlite')),
        );
        await database.customStatement(
          "INSERT INTO conversations (id, title, display_name, created_at, updated_at) "
          "VALUES ('c', 't', 'd', 1, 1), ('other', 't', 'd', 1, 1)",
        );
        // 一张中等规模的状态：40 个角色字段。
        final init = {
          for (var i = 0; i < 40; i++)
            '角色$i': {
              '好感度': [0, '说明'],
              '地点': '教堂',
            },
        };
        final snapshot = MvuSourceSnapshot(
          sources: [
            MvuInitSource(name: '[InitVar]', content: jsonEncode(init)),
          ],
        );
        await database.batch((batch) {
          for (var i = 0; i < count; i++) {
            final text = i % 3 == 2
                ? '普通回复 $i'
                : "回复 $i<UpdateVariable>_.add('角色${i % 40}.好感度', 1);</UpdateVariable>";
            batch.customStatement(
              'INSERT INTO messages (id, conversation_id, role, content, status, raw_payload, created_at) '
              "VALUES (?, 'c', 'assistant', ?, 'sent', ?, ?)",
              [
                'm$i',
                text,
                jsonEncode({'rawReplyText': text}),
                i + 1,
              ],
            );
          }
        });
        final store = SqliteConversationStateStore(
          database,
          resolveSources: (_) async => snapshot,
          greetingMessageId: (id) => 'msg_greeting_$id',
        );

        Future<int> timed(Future<void> Function() body) async {
          final watch = Stopwatch()..start();
          await body();
          return watch.elapsedMilliseconds;
        }

        final first = await timed(() => store.read('c', sources: snapshot));
        final cached = await timed(() => store.read('c', sources: snapshot));
        await database.customStatement(
          "UPDATE messages SET raw_payload = ? WHERE id = 'm${count ~/ 2}'",
          [
            jsonEncode({'rawReplyText': '改过的回复'}),
          ],
        );
        var otherWait = 0;
        final middle = await timed(() async {
          final replay = store.read('c', sources: snapshot);
          otherWait = await timed(
            () => database
                .customSelect(
                  "SELECT COUNT(*) FROM messages WHERE conversation_id = 'other'",
                )
                .get(),
          );
          await replay;
        });
        // ignore: avoid_print
        print(
          'MVU_PERF count=$count first=${first}ms cached=${cached}ms '
          'middleInvalidated=${middle}ms otherQueryWait=${otherWait}ms',
        );
        await database.close();
        await root.delete(recursive: true);
      },
      skip: enabled ? false : '设置 MVU_PERF=1 时运行',
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
