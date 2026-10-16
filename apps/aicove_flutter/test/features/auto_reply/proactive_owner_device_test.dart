// With one account on several devices, triggers sync to every device, so
// each one could analyse and send on its own. Only the device the user last
// spoke from answers proactively for that conversation.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/analyzer_scheduler.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_claim_store.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/background_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
const _ownersKey = 'aicove.plugins.trigger.owner_devices.v1';
const _deviceKey = 'aicove.cloud.device_id';
const _localDevice = 'device_local';
const _otherDevice = 'device_other';
const _conv = 'conv_owner';
const _trigger = 't_owner';

Map<String, Object?> _triggerJson() => {
      'id': _trigger,
      'title': '早安',
      'type': 'custom',
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
      'next_fire_at':
          DateTime.now().subtract(const Duration(minutes: 1)).toIso8601String(),
      'allow_night': true,
      'prompt': '问候一下',
      'cached_content': '早上好呀',
      'prepared_at': DateTime.now().toIso8601String(),
      'source': 'ai_scheduler',
      'conversation_id': _conv,
    };

void _prefs({String? owner}) => SharedPreferences.setMockInitialValues({
      _deviceKey: _localDevice,
      _triggerKey: jsonEncode([_triggerJson()]),
      if (owner != null)
        _ownersKey: jsonEncode({
          _conv: {'device_id': owner, 'at_ms': 1},
        }),
    });

/// The task closes its connection a moment before; drift's background isolate
/// may still hold the file, so retry an open that hits the lock.
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

Future<String?> _status() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final list = jsonDecode(prefs.getString(_triggerKey)!) as List;
  return (list.single as Map)['status'] as String?;
}

Future<Map<String, dynamic>> _owners() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return Map<String, dynamic>.from(
    jsonDecode(prefs.getString(_ownersKey) ?? '{}') as Map,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('background task', () {
    late Directory root;
    late PathProviderPlatform oldPaths;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('proactive_owner_');
      oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
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

    Future<List<Message>> messages() => _withDb(
          (db) => (db.select(db.messages)
                ..where((m) => m.conversationId.equals(_conv)))
              .get(),
        );

    Map<String, dynamic> task() => {
          'triggerId': _trigger,
          'convId': _conv,
          'prompt': '问候一下',
          'characterName': '理',
        };

    test('a device that does not own the conversation sends nothing',
        () async {
      _prefs(owner: _otherDevice);

      await runActiveReplyTaskForTest(task());

      expect(await messages(), isEmpty);
      expect(await _status(), 'pending');
    });

    test('the owning device still sends', () async {
      _prefs(owner: _localDevice);

      await runActiveReplyTaskForTest(task());

      expect((await messages()).single.content, '早上好呀');
      expect(await _status(), 'fired');
    });
  });

  group('foreground', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<void> start() async {
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      await container.read(autoReplyTriggersProvider.future);
    }

    test('a synced trigger owned by another device is left alone', () async {
      _prefs(owner: _otherDevice);
      await start();

      await container
          .read(autoReplyTriggersProvider.notifier)
          .pollDueTriggersForTest();

      // Neither claimed, fired nor expired here: the owner finishes it.
      expect(await _status(), 'pending');
      expect(
        await AutoReplyClaimStore(db).stateOf(_trigger),
        isA<AutoReplyClaimFree>(),
      );
    });

    test('a user message makes this device the owner', () async {
      _prefs(owner: _otherDevice);
      await start();

      await container
          .read(analyzerSchedulerProvider)
          .handleUserMessageActivity(
            conversationId: _conv,
            messageId: 'm1',
            occurredAt: DateTime.now(),
          );

      expect((await _owners())[_conv]['device_id'], _localDevice);
    });

    test('speaking again on the owning device renews the claim time',
        () async {
      // Otherwise an earlier claim from another device, still on its way,
      // would win the field merge over this later message.
      _prefs(owner: _localDevice);
      await start();
      final scheduler = container.read(analyzerSchedulerProvider);

      await scheduler.handleUserMessageActivity(
        conversationId: _conv,
        messageId: 'm1',
        occurredAt: DateTime.now(),
      );
      final first = (await _owners())[_conv]['at_ms'] as int;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await scheduler.handleUserMessageActivity(
        conversationId: _conv,
        messageId: 'm2',
        occurredAt: DateTime.now(),
      );

      expect((await _owners())[_conv]['at_ms'], greaterThan(first));
      expect(first, greaterThan(1));
    });

    test('a write starts from the synced list, not the in-memory copy',
        () async {
      _prefs(owner: _localDevice);
      await start();
      // Sync applies a list with another trigger behind the controller.
      final prefs = await SharedPreferences.getInstance();
      final synced = {..._triggerJson(), 'id': 't_synced'};
      await prefs.setString(
        _triggerKey,
        jsonEncode([_triggerJson(), synced]),
      );

      await container.read(autoReplyTriggersProvider.notifier).createTrigger(
            title: '晚安',
            type: AutoReplyTriggerType.delay,
            nextFireAt: DateTime.now().add(const Duration(hours: 1)),
            allowNight: true,
            requireExact: false,
            delayMinutes: 60,
            conversationId: _conv,
          );

      final ids = [
        for (final t in await AutoReplyTriggerStorage().loadTriggers()) t.id,
      ];
      expect(ids, containsAll([_trigger, 't_synced']));
      expect(ids, hasLength(3));
    });

    // A pause written behind the in-memory copy (by sync or by a write that
    // finished first) must survive a decision made from that stale copy.
    Future<void> pauseBehindController() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _triggerKey,
        jsonEncode([
          {..._triggerJson(), 'status': 'paused'},
        ]),
      );
    }

    test('expiring from a stale copy keeps a pause from storage', () async {
      _prefs(owner: _localDevice);
      await start();
      await pauseBehindController();

      await container
          .read(autoReplyTriggersProvider.notifier)
          .expireTrigger(_trigger, 'stale');

      expect(await _status(), 'paused');
    });

    test('a retry from a stale copy keeps a pause from storage', () async {
      _prefs(owner: _localDevice);
      await start();
      final token = await AutoReplyClaimStore(db).tryClaim(
        triggerId: _trigger,
        claimedBy: AutoReplyClaimOwner.foreground,
      );
      await pauseBehindController();

      await container
          .read(autoReplyTriggersProvider.notifier)
          .completeTriggeredSend(
            triggerId: _trigger,
            firedAt: DateTime.now(),
            success: false,
            retryable: true,
            reason: 'empty_reply',
            claimToken: token,
          );

      expect(await _status(), 'paused');
      expect(
        await AutoReplyClaimStore(db).stateOf(_trigger),
        isA<AutoReplyClaimFree>(),
      );
    });

    test('analysis is skipped on a device that does not own the conversation',
        () async {
      _prefs(owner: _otherDevice);
      await start();

      container
          .read(analyzerSchedulerProvider)
          .scheduleAnalysis(conversationId: _conv, delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final events = [
        for (final log in await AutoReplyTriggerStorage().loadLogs()) log.event,
      ];
      expect(events, contains('analysis_skipped_other_device'));
    });
  });
}
