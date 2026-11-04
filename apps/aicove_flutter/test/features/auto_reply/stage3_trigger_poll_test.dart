import 'dart:async';
import 'dart:convert';

import 'package:aicove_flutter/src/features/auto_reply/data/analyzer_scheduler.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_owner_device.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_claim_store.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_call_ledger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state_storage.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Conversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
    Conversation(
      id: 'c',
      title: 'Role',
      displayName: 'Role',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  ];
}

class _FlakySettings extends AppSettingsNotifier {
  static int attempts = 0;
  @override
  Future<AppSettings> build() async {
    if (attempts++ == 0) throw StateError('settings temporarily unavailable');
    return mapUiModelsToAppSettings(const {}).copyWith(
      autoReplySettings: const AutoReplySettings(quietHoursEnabled: false),
    );
  }
}

class _Settings extends AppSettingsNotifier {
  _Settings(this.value);
  final AppSettings value;
  @override
  Future<AppSettings> build() async => value;
}

AutoReplyTrigger _trigger(String id, {bool exact = false, bool call = false}) =>
    AutoReplyTrigger(
      id: id,
      title: id,
      type: AutoReplyTriggerType.fixed,
      status: AutoReplyTriggerStatus.pending,
      createdAt: DateTime.now(),
      nextFireAt: DateTime.now().subtract(const Duration(minutes: 20)),
      allowNight: true,
      requireExact: exact,
      delayMinutes: 0,
      manual: true,
      conversationId: 'c',
      action: call ? ProactiveAction.callUser : ProactiveAction.sendMessage,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  late StreamSubscription<AutoReplyTriggerEvent> subscription;
  late List<AutoReplyTriggerEvent> events;

  Future<void> start(AutoReplySettings settings, {bool flaky = false}) async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.now().millisecondsSinceEpoch;
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'c',
            title: 'Role',
            displayName: 'Role',
            createdAt: now,
            updatedAt: now,
          ),
        );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        conversationsProvider.overrideWith(_Conversations.new),
        appSettingsProvider.overrideWith(() => flaky ? _FlakySettings() : _Settings(
          mapUiModelsToAppSettings(const {}).copyWith(autoReplySettings: settings),
        )),
      ],
    );
    await container.read(conversationsProvider.future);
    await container.read(autoReplyTriggersProvider.future);
    events = [];
    subscription = container
        .read(autoReplyTriggerEventBusProvider)
        .stream
        .listen(events.add);
  }

  tearDown(() async {
    await subscription.cancel();
    container.dispose();
    await database.close();
  });

  Future<void> poll(List<AutoReplyTrigger> triggers) async {
    await AutoReplyTriggerStorage().saveTriggers(triggers);
    final controller = container.read(autoReplyTriggersProvider.notifier);
    await controller.refresh();
    await controller.pollDueTriggersForTest();
    await Future<void>.delayed(Duration.zero);
  }

  test('poll retries after settings loading fails', () async {
    _FlakySettings.attempts = 0;
    await start(const AutoReplySettings(), flaky: true);
    await AutoReplyTriggerStorage().saveTriggers([_trigger('retry-settings')]);
    final controller = container.read(autoReplyTriggersProvider.notifier);
    await controller.refresh();
    await controller.pollDueTriggersForTest();
    container.invalidate(appSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(events.where((e) => e.type == AutoReplyTriggerEventType.fired), hasLength(1));
  });

  test('taking ownership on a user message wakes a skipped trigger', () async {
    await start(const AutoReplySettings(quietHoursEnabled: false));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('aicove.cloud.device_id', 'local');
    await prefs.setString(proactiveOwnerDevicesKey, jsonEncode({
      'c': {'device_id': 'other', 'at_ms': 1},
    }));
    await poll([_trigger('handoff')]);
    expect(events, isEmpty);

    await container.read(analyzerSchedulerProvider).handleUserMessageActivity(
      conversationId: 'c', messageId: 'm', occurredAt: DateTime.now(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(events.where((e) => e.type == AutoReplyTriggerEventType.fired),
        hasLength(1));
  });

  test('a future trigger wakes without periodic polling', () async {
    await start(const AutoReplySettings(quietHoursEnabled: false));
    await poll([_trigger('future').copyWith(
      nextFireAt: DateTime.now().add(const Duration(milliseconds: 200)),
    )]);
    expect(events, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(events.where((e) => e.type == AutoReplyTriggerEventType.fired),
        hasLength(1));
  });

  test(
    'multiple due triggers in one tick all dispatch when not in quiet hours',
    () async {
      await start(const AutoReplySettings(quietHoursEnabled: false));
      await poll([_trigger('a'), _trigger('b')]);
      expect(
        events.where((e) => e.type == AutoReplyTriggerEventType.fired),
        hasLength(2),
      );
    },
  );

  test(
    'contact-level quiet hours override global quiet hours per conversation',
    () async {
      await start(
        const AutoReplySettings(
          quietHoursEnabled: true,
          quietHoursStart: '00:00',
          quietHoursEnd: '23:59',
          contactSettings: {
            'c': ContactAutoReplySettings(quietHoursEnabled: false),
          },
        ),
      );
      await poll([_trigger('a').copyWith(allowNight: false)]);
      expect(
        events.where((e) => e.type == AutoReplyTriggerEventType.fired),
        hasLength(1),
      );
    },
  );

  test('an overdue exact reminder is delivered instead of expiring', () async {
    await start(
      const AutoReplySettings(allowExactAlarm: true, quietHoursEnabled: false),
    );
    await poll([_trigger('late', exact: true)]);
    expect(events.single.type, AutoReplyTriggerEventType.fired);
    expect(
      (await AutoReplyTriggerStorage().loadTriggers()).single.isActive,
      isTrue,
    );
  });

  test(
    'confirmed call recovery is delivered even without a message row',
    () async {
      await start(const AutoReplySettings(quietHoursEnabled: false));
      final at = DateTime.now().subtract(const Duration(minutes: 20));
      final claims = AutoReplyClaimStore(database);
      final token = await claims.tryClaim(
        triggerId: 'call',
        claimedBy: 'background',
        now: at,
      );
      await claims.beginDelivery('call', token!, now: at);
      final ledger = ProactiveCallLedger(database);
      await ledger.reserve(
        ProactiveCall(
          triggerId: 'call',
          conversationId: 'c',
          openingLine: 'hello',
          rangAt: at,
          answerUntil: at.add(const Duration(minutes: 1)),
        ),
        now: at,
      );
      await ledger.confirm('call');
      await poll([_trigger('call', call: true).copyWith(
        manual: false, source: TriggerSource.aiScheduler,
      )]);
      expect(
        (await AutoReplyTriggerStorage().loadTriggers()).single.status,
        AutoReplyTriggerStatus.fired,
      );
      expect((await ConversationProactiveStateStorage().loadStates())['c']!
          .unrepliedCount, 1);
    },
  );

  test('a recovered confirmed call settles without blocking the next due trigger', () async {
    await start(const AutoReplySettings(quietHoursEnabled: false));
    final at = DateTime.now().subtract(const Duration(minutes: 20));
    final claims = AutoReplyClaimStore(database);
    final token = await claims.tryClaim(triggerId: 'call', claimedBy: 'background', now: at);
    await claims.beginDelivery('call', token!, now: at);
    final ledger = ProactiveCallLedger(database);
    await ledger.reserve(ProactiveCall(
      triggerId: 'call', conversationId: 'c', openingLine: 'hello',
      rangAt: at, answerUntil: at.add(const Duration(minutes: 1)),
    ), now: at);
    await ledger.confirm('call');
    await poll([_trigger('call', call: true), _trigger('next')]);
    expect(events.where((e) => e.type == AutoReplyTriggerEventType.fired), hasLength(1));
    expect((await AutoReplyTriggerStorage().loadTriggers()).first.status,
        AutoReplyTriggerStatus.fired);
  });
}
