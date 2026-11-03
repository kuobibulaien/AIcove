import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/background_service.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

const _triggerKey = 'aicove.auto_triggers.v1';
const _conv = 'conv_bg';
const _trigger = 't_bg';

Map<String, Object?> _triggerJson() => {
      'id': _trigger,
      'title': '早安',
      'type': 'custom',
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
      'next_fire_at': DateTime.now().toIso8601String(),
      'allow_night': true,
      'prompt': '问候一下',
      'cached_content': '早上好呀',
      'prepared_at': DateTime.now().toIso8601String(),
      'conversation_id': _conv,
    };

/// A connection closed a moment ago may still hold the file in drift's
/// background isolate; retry the helper's own open on a lock.
Future<T> _withDb<T>(Future<T> Function(AppDatabase db) body) async {
  for (var attempt = 0;; attempt++) {
    final db = AppDatabase();
    try {
      return await body(db);
    } catch (e) {
      final locked = '$e'.contains('(code 5)') || '$e'.contains('(code 6)');
      if (!locked || attempt >= 6) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 50 * (1 << attempt)));
    } finally {
      await db.close();
    }
  }
}

Future<List<Message>> _messages() => _withDb(
      (db) => (db.select(db.messages)
            ..where((m) => m.conversationId.equals(_conv)))
          .get(),
    );

Future<int> _unread() => _withDb((db) async =>
    (await (db.select(db.conversations)..where((c) => c.id.equals(_conv)))
            .getSingle())
        .unreadCount);

Future<String?> _status() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final list = jsonDecode(prefs.getString(_triggerKey)!) as List;
  return (list.single as Map)['status'] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late PathProviderPlatform oldPaths;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bg_delivery_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({
      _triggerKey: jsonEncode([_triggerJson()]),
    });
    final now = DateTime.now().millisecondsSinceEpoch;
    await _withDb(
      (db) => db.into(db.conversations).insert(ConversationsCompanion.insert(
            id: _conv,
            title: '理',
            displayName: '理',
            createdAt: now,
            updatedAt: now,
          )),
    );
  });

  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  Map<String, dynamic> task() => {
        'triggerId': _trigger,
        'convId': _conv,
        'prompt': '问候一下',
        'characterName': '理',
      };

  test('soft-deleted conversation receives neither message nor notification', () async {
    await _withDb((db) => db.customStatement(
      "UPDATE conversations SET deleted_at = 1 WHERE id = '$_conv'",
    ));
    await runActiveReplyTaskForTest(task());
    expect(await _messages(), isEmpty);
    expect(await _unread(), 0);
    expect(await _status(), isNot('fired'));
    final prefs = await SharedPreferences.getInstance();
    final logs = jsonDecode(prefs.getString('aicove.auto_trigger_logs.v1')!) as List;
    expect(logs.where((log) => log['event'] == 'task_notification_failed'), isEmpty);
  });

  test('new user raw message expires automatic cached delivery', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_triggerKey, jsonEncode([
      {..._triggerJson(), 'manual': false, 'priority': 'medium'},
    ]));
    await _withDb((db) => db.into(db.messages).insert(MessagesCompanion.insert(
      id: 'new-user', conversationId: _conv, role: 'user', content: '继续聊',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    )));
    await runActiveReplyTaskForTest(task());
    expect((await _messages()).map((m) => m.id), ['new-user']);
    expect(await _unread(), 0);
    expect(await _status(), isNot('fired'));
  });

  for (final change in ['new-user', 'soft-delete']) {
    test('live generation cancels when $change happens during request', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_triggerKey, jsonEncode([
        {..._triggerJson(), 'manual': false},
      ]));
      var generated = false;
      final reply = await _withDb((db) => generateBackgroundLiveReplyForTest(
        database: db, conversationId: _conv, triggerId: _trigger,
        generate: () async {
          generated = true;
          if (change == 'soft-delete') {
            await db.customStatement("UPDATE conversations SET deleted_at = 1 WHERE id = '$_conv'");
          } else {
            await db.into(db.messages).insert(MessagesCompanion.insert(
              id: 'during-user', conversationId: _conv, role: 'user',
              content: '继续聊', createdAt: DateTime.now().millisecondsSinceEpoch,
            ));
          }
          return '过期生成';
        },
      ));
      expect(generated, isTrue);
      expect(reply, isNull);
    });
  }

  test('live generation checks latest user raw, not a newer assistant raw', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_triggerKey, jsonEncode([
      {..._triggerJson(), 'manual': false},
    ]));
    var generated = false;
    final reply = await _withDb((db) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final role in ['user', 'assistant']) {
        await db.into(db.messages).insert(MessagesCompanion.insert(
          id: role, conversationId: _conv, role: role,
          content: role, createdAt: now + (role == 'assistant' ? 1 : 0),
        ));
      }
      return generateBackgroundLiveReplyForTest(
        database: db, conversationId: _conv, triggerId: _trigger,
        generate: () async { generated = true; return '不得生成'; },
      );
    });
    expect(generated, isFalse);
    expect(reply, isNull);
  });

  test('assistant-only change does not expire live generation', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_triggerKey, jsonEncode([
      {..._triggerJson(), 'manual': false},
    ]));
    final reply = await _withDb((db) => generateBackgroundLiveReplyForTest(
      database: db, conversationId: _conv, triggerId: _trigger,
      generate: () async {
        await db.into(db.messages).insert(MessagesCompanion.insert(
          id: 'assistant', conversationId: _conv, role: 'assistant',
          content: '并发回复', createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
        return '仍有效';
      },
    ));
    expect(reply, '仍有效');
  });


  for (final deletion in ['conversation', 'message']) {
    test('final storage rejects $deletion deleted after delivery gates', () async {
      var reachedStorage = false;
      await runActiveReplyTaskForTest(task(), beforePersist: () async {
        reachedStorage = true;
        await _withDb((db) async {
          if (deletion == 'conversation') {
            await db.customStatement("UPDATE conversations SET deleted_at = 1 WHERE id = '$_conv'");
          } else {
            await db.customStatement(
              'INSERT INTO messages (id, conversation_id, role, content, created_at, deleted_at) VALUES (?, ?, ?, ?, ?, ?)',
              [backgroundTriggerMessageId(_trigger), _conv, 'assistant', '已删除', 1, 2],
            );
          }
        });
      });
      expect(reachedStorage, isTrue);
      final messages = await _messages();
      if (deletion == 'conversation') {
        expect(messages, isEmpty);
      } else {
        expect(messages.single.deletedAt, 2);
        expect(messages.single.content, '已删除');
      }
      expect(await _unread(), 0);
      expect(await _status(), isNot('fired'));
      final prefs = await SharedPreferences.getInstance();
      final logs = jsonDecode(prefs.getString('aicove.auto_trigger_logs.v1')!) as List;
      expect(logs.any((log) => log['event'] == 'task_failed_persist_message'), isTrue);
      expect(logs.where((log) => log['event'] == 'task_notification_failed'), isEmpty);
    });
  }


  for (final change in ['clear', 'new-user']) {
    test('final storage rejects $change after the last context gate', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_triggerKey, jsonEncode([
        {..._triggerJson(), 'manual': false, 'context_last_user_message_id': 'old-user'},
      ]));
      await _withDb((db) => db.into(db.messages).insert(MessagesCompanion.insert(
        id: 'old-user', conversationId: _conv, role: 'user', content: '先前消息', createdAt: 1,
      )));
      var reachedStorage = false;
      await runActiveReplyTaskForTest(task(), beforePersist: () async {
        reachedStorage = true;
        await _withDb((db) async {
          if (change == 'clear') {
            await db.customStatement('UPDATE messages SET deleted_at=2 WHERE conversation_id=?', [_conv]);
          } else {
            await db.into(db.messages).insert(MessagesCompanion.insert(
              id: 'new-user', conversationId: _conv, role: 'user',
              content: '刚发消息', createdAt: DateTime.now().millisecondsSinceEpoch,
            ));
          }
        });
      });
      expect(reachedStorage, isTrue);
      expect((await _messages()).any((message) => message.id.startsWith('bg_')), isFalse);
      expect(await _unread(), 0);
      expect(await _status(), isNot('fired'));
      await prefs.reload();
      final logs = jsonDecode(prefs.getString('aicove.auto_trigger_logs.v1')!) as List;
      expect(logs.any((log) => log['event'] == 'task_failed_persist_message'), isTrue);
      expect(logs.where((log) => log['event'] == 'task_notification_failed'), isEmpty);
    });
  }

}
