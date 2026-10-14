// A send that returns after its claim was taken over must not change the
// trigger: only the current claim holder finishes it (batch 2 re-review).
import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_claim_store.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/settings/settings_models.dart';
import 'package:aicove_flutter/src/features/settings/ui_models_api.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _id = 't_fg';
final _fireAt = DateTime.now().add(const Duration(hours: 1));
// Inside the 24h cleanup window, outside any minimum send interval.
final _firedLongAgo = DateTime.now().subtract(const Duration(hours: 23));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;
  late AutoReplyClaimStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'aicove.auto_triggers.v1': jsonEncode([
        {
          'id': _id,
          'title': '早安',
          'type': 'custom',
          'status': 'pending',
          'created_at': DateTime.now().toIso8601String(),
          'next_fire_at': _fireAt.toIso8601String(),
          'allow_night': true,
          'conversation_id': 'conv_fg',
        },
      ]),
    });
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = AutoReplyClaimStore(db);
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    await container.read(autoReplyTriggersProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  AutoReplyTrigger trigger() => container
      .read(autoReplyTriggersProvider)
      .requireValue
      .singleWhere((t) => t.id == _id);

  Future<void> complete(String? token, {required bool retryable}) =>
      container.read(autoReplyTriggersProvider.notifier).completeTriggeredSend(
            triggerId: _id,
            firedAt: DateTime.now(),
            success: false,
            retryable: retryable,
            reason: 'empty_reply',
            claimToken: token,
          );

  for (final retryable in [true, false]) {
    test('a completion from a taken-over send leaves the trigger alone '
        '(retryable: $retryable)', () async {
      final old = (await store.tryClaim(
        triggerId: _id,
        claimedBy: AutoReplyClaimOwner.foreground,
        now: DateTime.now().subtract(const Duration(minutes: 20)),
      ))!;
      final current = await store.tryClaim(
        triggerId: _id,
        claimedBy: AutoReplyClaimOwner.background,
      );
      expect(current, isNotNull);

      await complete(old, retryable: retryable);

      expect(trigger().status, AutoReplyTriggerStatus.pending);
      expect(trigger().nextFireAt, _fireAt);
      expect(trigger().expireReason, isNull);
      expect(await store.stateOf(_id), isA<AutoReplyClaimHeld>());
    });
  }

  test('finishing a failure renews the claim before changing the trigger',
      () async {
    // The renewal keeps another side from taking over between the check and
    // the write; it shows as a lease restarted at completion time.
    final token = await store.tryClaim(
      triggerId: _id,
      claimedBy: AutoReplyClaimOwner.foreground,
      now: DateTime.now().subtract(const Duration(minutes: 9)),
    );

    await complete(token, retryable: false);

    expect(trigger().status, AutoReplyTriggerStatus.expired);
    expect(
      await store.stateOf(
        _id,
        now: DateTime.now().add(const Duration(minutes: 5)),
      ),
      isA<AutoReplyClaimHeld>(),
    );
  });

  test('a failure after delivery began is still finished by its holder',
      () async {
    final token = (await store.tryClaim(
      triggerId: _id,
      claimedBy: AutoReplyClaimOwner.foreground,
    ))!;
    await store.beginDelivery(_id, token, messageId: 'm');

    await complete(token, retryable: false);

    expect(trigger().status, AutoReplyTriggerStatus.expired);
    expect(trigger().expireReason, 'empty_reply');
  });

  test('the current holder schedules the retry and frees its claim', () async {
    final token = await store.tryClaim(
      triggerId: _id,
      claimedBy: AutoReplyClaimOwner.foreground,
    );

    await complete(token, retryable: true);

    expect(trigger().status, AutoReplyTriggerStatus.pending);
    expect(trigger().expireReason, 'empty_reply');
    expect(trigger().nextFireAt.isBefore(_fireAt), isTrue);
    expect(await store.stateOf(_id), isA<AutoReplyClaimFree>());
  });

  group('poll', () {
    // Points at a conversation that does not exist, so the poll would
    // expire it ('目标会话不存在') unless a delivery protects it.
    Future<void> seedDue({
      String status = 'pending',
      bool exact = false,
      Duration overdue = const Duration(minutes: 1),
    }) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'aicove.auto_triggers.v1',
        jsonEncode([
          {
            'id': _id,
            'title': '早安',
            'type': 'custom',
            'status': status,
            'created_at': DateTime.now().toIso8601String(),
            'next_fire_at': DateTime.now().subtract(overdue).toIso8601String(),
            'require_exact': exact,
            'allow_night': true,
            'conversation_id': 'conv_missing',
            if (status == 'fired')
              'last_fired_at': _firedLongAgo.toIso8601String(),
          },
        ]),
      );
      await container.read(autoReplyTriggersProvider.notifier).refresh();
    }

    Future<void> poll() => container
        .read(autoReplyTriggersProvider.notifier)
        .pollDueTriggersForTest();

    test('expiry is skipped while another side is delivering', () async {
      await seedDue();
      final token = await store.tryClaim(
        triggerId: _id,
        claimedBy: AutoReplyClaimOwner.background,
      );
      await store.beginDelivery(_id, token!, messageId: 'm');

      await poll();

      expect(trigger().status, AutoReplyTriggerStatus.pending);
    });

    test('expiry is skipped while another side holds the claim', () async {
      await seedDue();
      await store.tryClaim(
        triggerId: _id,
        claimedBy: AutoReplyClaimOwner.background,
      );

      await poll();

      expect(trigger().status, AutoReplyTriggerStatus.pending);
    });

    test('an unclaimed due trigger is expired and its claim kept', () async {
      await seedDue();

      await poll();

      expect(trigger().status, AutoReplyTriggerStatus.expired);
      // A background run that generated meanwhile cannot start delivering.
      expect(await store.stateOf(_id), isA<AutoReplyClaimHeld>());
    });

    test('an inactive exact trigger past its window leaves no claim behind',
        () async {
      await UiModelsApi().updatePartial({
        'auto_reply_settings':
            const AutoReplySettings(allowExactAlarm: true).toJson(),
      });
      await seedDue(
        status: 'expired',
        exact: true,
        overdue: const Duration(minutes: 5),
      );

      await poll();

      expect(await store.stateOf(_id), isA<AutoReplyClaimFree>());
    });

    test('a finished trigger is not finalised again', () async {
      await seedDue(status: 'fired');
      final startedAt = DateTime.now().subtract(const Duration(hours: 1));
      final token = await store.tryClaim(
        triggerId: _id,
        claimedBy: AutoReplyClaimOwner.background,
        now: startedAt,
      );
      await store.beginDelivery(_id, token!, messageId: 'm', now: startedAt);
      // The delivered message exists, so a repeated finalisation would mark
      // it fired again with a fresh time.
      final at = startedAt.millisecondsSinceEpoch;
      await db.into(db.conversations).insert(ConversationsCompanion.insert(
            id: 'conv_missing',
            title: '理',
            displayName: '理',
            createdAt: at,
            updatedAt: at,
          ));
      await db.into(db.messages).insert(MessagesCompanion.insert(
            id: 'm',
            conversationId: 'conv_missing',
            role: 'assistant',
            content: '早上好呀',
            createdAt: at,
          ));

      await poll();

      expect(trigger().status, AutoReplyTriggerStatus.fired);
      expect(trigger().lastFiredAt, _firedLongAgo);
    });
  });
}
