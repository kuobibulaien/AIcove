// F group (batch 2 plan §5): the WorkManager task delivers a proactive
// message exactly once, also when a previous run was killed after writing
// the message but before marking the trigger fired.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_claim_store.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/background_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

  test('delivers once under a stable id, then marks fired and completes',
      () async {
    await runActiveReplyTaskForTest(task());

    final messages = await _messages();
    expect(messages.single.id, backgroundTriggerMessageId(_trigger));
    expect(messages.single.content, '早上好呀');
    expect(jsonDecode(messages.single.rawPayload!)['bg_origin_device_id'],
        await MediaStore.localDeviceId);
    expect(await _unread(), 1);
    expect(await _status(), 'fired');
    final logs = await Directory(
      '${root.path}/logs',
    ).list().where((f) => f is File).toList();
    final diagnosticText = await (logs.single as File).readAsString();
    final records = diagnosticText
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map);
    final completed =
        records.singleWhere(
              (r) => r['metadata']?['event'] == 'task_completed',
            )['metadata']
            as Map;
    expect(completed['category'], 'backgroundDelivery');
    expect(completed['entityId'], backgroundTriggerMessageId(_trigger));
    expect(completed['elapsedMs'], isNonNegative);
    expect(diagnosticText, isNot(contains('早上好呀')));
    // The completed claim keeps a late foreground attempt out for good.
    expect(
      await _withDb((db) => AutoReplyClaimStore(db).tryClaim(
            triggerId: _trigger,
            claimedBy: AutoReplyClaimOwner.foreground,
            now: DateTime.now().add(const Duration(hours: 2)),
          )),
      isNull,
    );
  });

  test('a database locked while the task opens it is reopened, not reused',
      () async {
    // Another connection holds the file exclusively, so the task's first
    // open fails reading the schema version. Drift keeps that failure on the
    // connection for good: the retry has to open a new one.
    late AppDatabase holder;
    for (var attempt = 0;; attempt++) {
      holder = AppDatabase.forTesting(NativeDatabase(
        File(p.join(root.path, 'aicove.db')),
        setup: (db) => db.execute('PRAGMA locking_mode = EXCLUSIVE'),
      ));
      try {
        await holder.customStatement('BEGIN EXCLUSIVE');
        break;
      } catch (e) {
        await holder.close();
        if (!'$e'.contains('(code 5)') || attempt >= 6) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 50 * (1 << attempt)));
      }
    }
    final released = Future<void>.delayed(
      const Duration(milliseconds: 300),
      () async {
        await holder.customStatement('COMMIT');
        await holder.close();
      },
    );

    await runActiveReplyTaskForTest(task());
    await released;

    expect((await _messages()).single.content, '早上好呀');
    expect(await _status(), 'fired');
  });

  test('a run killed after writing is finished without a second message',
      () async {
    // Previous run: claimed, began delivery, wrote the message (with its
    // summary and unread count, in one transaction), died before marking
    // fired.
    final killedAt = DateTime.now().subtract(const Duration(minutes: 30));
    await _withDb((db) async {
      final store = AutoReplyClaimStore(db);
      final token = await store.tryClaim(
        triggerId: _trigger,
        claimedBy: AutoReplyClaimOwner.background,
        now: killedAt,
      );
      await store.beginDelivery(_trigger, token!, now: killedAt);
      await db.into(db.messages).insert(MessagesCompanion.insert(
            id: backgroundTriggerMessageId(_trigger),
            conversationId: _conv,
            role: 'assistant',
            content: '早上好呀',
            createdAt: killedAt.millisecondsSinceEpoch,
          ));
      await db.customStatement(
        "UPDATE conversations SET unread_count = 1 WHERE id = '$_conv'",
      );
    });

    await runActiveReplyTaskForTest(task());

    expect(await _messages(), hasLength(1));
    expect(await _unread(), 1);
    expect(await _status(), 'fired');
    expect(
      await _withDb((db) => AutoReplyClaimStore(db).stateOf(_trigger)),
      isA<AutoReplyClaimDelivered>(),
    );
  });

  test('a run killed after beginning delivery but before writing is not '
      'retried and ends as interrupted', () async {
    final killedAt = DateTime.now().subtract(const Duration(minutes: 30));
    await _withDb((db) async {
      final store = AutoReplyClaimStore(db);
      final token = await store.tryClaim(
        triggerId: _trigger,
        claimedBy: AutoReplyClaimOwner.background,
        now: killedAt,
      );
      await store.beginDelivery(_trigger, token!, now: killedAt);
    });

    await runActiveReplyTaskForTest(task());

    expect(await _messages(), isEmpty);
    expect(await _status(), 'expired');
  });

  test('an interrupted foreground delivery is recognised by the message id '
      'it recorded', () async {
    final killedAt = DateTime.now().subtract(const Duration(minutes: 30));
    await _withDb((db) async {
      final store = AutoReplyClaimStore(db);
      final token = await store.tryClaim(
        triggerId: _trigger,
        claimedBy: AutoReplyClaimOwner.foreground,
        now: killedAt,
      );
      await store.beginDelivery(_trigger, token!,
          messageId: 'msg_fg', now: killedAt);
      await db.into(db.messages).insert(MessagesCompanion.insert(
            id: 'msg_fg',
            conversationId: _conv,
            role: 'assistant',
            content: '早上好呀',
            createdAt: killedAt.millisecondsSinceEpoch,
          ));
    });

    await runActiveReplyTaskForTest(task());

    expect(await _messages(), hasLength(1));
    expect(await _status(), 'fired');
  });

  test('a delivery still inside its lease is left to its holder', () async {
    await _withDb((db) async {
      final store = AutoReplyClaimStore(db);
      final token = await store.tryClaim(
        triggerId: _trigger,
        claimedBy: AutoReplyClaimOwner.foreground,
      );
      await store.beginDelivery(_trigger, token!, messageId: 'msg_fg');
    });

    // The holder may still be writing: nothing is written or finalised here.
    // The task reschedules a check past the delivery lease; without
    // WorkManager in tests that fails and propagates, so the run is not
    // counted as done.
    await expectLater(runActiveReplyTaskForTest(task()), throwsA(anything));
    expect(await _messages(), isEmpty);
    expect(await _status(), 'pending');
  });

  test('a claim inside its lease is left alone and the task does not end '
      'as done', () async {
    await _withDb((db) => AutoReplyClaimStore(db).tryClaim(
          triggerId: _trigger,
          claimedBy: AutoReplyClaimOwner.foreground,
        ));

    // The task reschedules past the lease; without WorkManager in tests
    // that fails, and the failure propagates so WorkManager would retry
    // instead of counting the run as done.
    await expectLater(runActiveReplyTaskForTest(task()), throwsA(anything));

    expect(await _messages(), isEmpty);
    expect(await _status(), 'pending');
  });

  test('the other side having begun delivery means nothing is written here',
      () async {
    // A taken-over holder is refused at beginDelivery (lease test); here the
    // other side's delivery has started before this task claims.
    await _withDb((db) async {
      final store = AutoReplyClaimStore(db);
      final token = await store.tryClaim(
        triggerId: _trigger,
        claimedBy: AutoReplyClaimOwner.foreground,
      );
      await store.beginDelivery(_trigger, token!);
    });

    await expectLater(runActiveReplyTaskForTest(task()), throwsA(anything));

    expect(await _messages(), isEmpty);
  });
}
