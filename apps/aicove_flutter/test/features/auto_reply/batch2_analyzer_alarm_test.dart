import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/analyzer_scheduler.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_service.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/context_analyzer.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_message_pregenerator.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_owner_device.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_action.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/auto_reply/data/proactive_planner.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_decision.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'batch2_analyzer';
const _second = 'batch2_second';
const _disabled = 'batch2_disabled';
const _channel = MethodChannel('com.example.aicove_flutter/keep_alive');

class _Conversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
    for (final id in [_id, _second, _disabled])
      Conversation(
        id: id,
        title: id,
        displayName: id,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        enabledPlugins: id == _disabled ? const [] : const ['trigger'],
      ),
  ];
}

class _Analyzer extends ContextAnalyzer {
  _Analyzer(super.ref);
  Future<ContextAnalysisDecision?> Function(Conversation)? run;
  final calls = <String>[];
  @override
  Future<ContextAnalysisDecision?> analyze(
    Conversation conversation, {
    required ConversationProactiveState proactiveState,
  }) async {
    calls.add(conversation.id);
    return run == null ? null : await run!(conversation);
  }
}

class _Pregenerator extends ProactiveMessagePregenerator {
  _Pregenerator(super.ref);
  Future<ProactiveDraft?> Function()? run;
  @override
  Future<ProactiveDraft?> generate({
    required Conversation conversation,
    required String systemReminder,
    required DateTime fireAt,
    bool allowCall = false,
  }) async => run == null ? null : await run!();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late db.AppDatabase database;
  late ProviderContainer container;
  late _Analyzer analyzer;
  late _Pregenerator pregenerator;
  late List<MethodCall> calls;
  Future<void> Function(MethodCall)? intercept;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'aicove.cloud.device_id': 'batch2_local',
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    intercept = null;
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      await intercept?.call(call);
      if (call.method == 'getStatus') {
        return <String, Object>{
          'generationActive': true,
          'serviceRunning': true,
          'generationWakeLockHeld': true,
          'guardEnabled': true,
        };
      }
      return null;
    });
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in [_id, _second, _disabled]) {
      await database
          .into(database.conversations)
          .insert(
            db.ConversationsCompanion.insert(
              id: id,
              title: id,
              displayName: id,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        conversationsProvider.overrideWith(_Conversations.new),
        contextAnalyzerProvider.overrideWith(
          (ref) => analyzer = _Analyzer(ref),
        ),
        proactiveMessagePregeneratorProvider.overrideWith(
          (ref) => pregenerator = _Pregenerator(ref),
        ),
      ],
    );
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    await container.read(autoReplyTriggersProvider.future);
    container.read(contextAnalyzerProvider);
    container.read(proactiveMessagePregeneratorProvider);
  });
  tearDown(() async {
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await database.close();
    messenger.setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  Future<void> drain() =>
      Future<void>.delayed(const Duration(milliseconds: 80));
  Future<void> seed(List<ConversationProactiveState> states) =>
      ConversationProactiveStateStorage().saveStates({
        for (final s in states) s.conversationId: s,
      });
  List<MethodCall> alarms() => calls
      .where(
        (c) =>
            (c.method == 'scheduleProactiveAlarm' ||
                c.method == 'cancelProactiveAlarm') &&
            (c.arguments as Map)['slot'] == 'analyzer',
      )
      .toList();
  DateTime at(MethodCall call) => DateTime.fromMillisecondsSinceEpoch(
    (call.arguments as Map)['fireAtMillis'] as int,
  );

  test(
    'restores observation and reschedules new observation on background',
    () async {
      final due = DateTime.now().add(const Duration(minutes: 20));
      await seed([
        ConversationProactiveState(conversationId: _id, observingUntil: due),
      ]);
      final scheduler = container.read(analyzerSchedulerProvider);
      await scheduler.onAppResumed();
      expect(
        at(alarms().last).millisecondsSinceEpoch,
        due.millisecondsSinceEpoch,
      );
      scheduler.scheduleAnalysis(
        conversationId: _id,
        delay: const Duration(minutes: 5),
      );
      await drain();
      scheduler.onAppBackground();
      await drain();
      final state = (await ConversationProactiveStateStorage()
          .loadStates())[_id]!;
      expect(
        at(
          alarms().last,
        ).difference(state.observingUntil!).inMilliseconds.abs(),
        lessThan(2),
      );
      expect(state.observingUntil!.isBefore(due), isTrue);
    },
  );
  test('selects earliest silent wake and falls back after deletion', () async {
    final due = DateTime.now().add(const Duration(minutes: 10));
    await seed([
      ConversationProactiveState(
        conversationId: _id,
        observingUntil: due.add(const Duration(hours: 1)),
      ),
      ConversationProactiveState(
        conversationId: _second,
        mode: ConversationProactiveMode.silent,
        silenceUntil: due,
      ),
    ]);
    final scheduler = container.read(analyzerSchedulerProvider);
    await scheduler.onAppResumed();
    expect(
      at(alarms().last).millisecondsSinceEpoch,
      due.millisecondsSinceEpoch,
    );
    await scheduler.onConversationDeleted(_second);
    expect(
      at(alarms().last).millisecondsSinceEpoch,
      due.add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
  });
  test('quiet hours defer analyzer and forward exact preference', () async {
    await container
        .read(appSettingsProvider.notifier)
        .updateAutoReplySettings(
          const AutoReplySettings(
            quietHoursEnabled: true,
            quietHoursStart: '22:00',
            quietHoursEnd: '08:00',
            allowExactAlarm: true,
          ),
        );
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final due = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 23);
    await seed([
      ConversationProactiveState(conversationId: _id, observingUntil: due),
    ]);
    await container.read(analyzerSchedulerProvider).onAppResumed();
    expect(at(alarms().last), DateTime(due.year, due.month, due.day + 1, 8));
    expect((alarms().last.arguments as Map)['exact'], isTrue);
  });
  test('dormant disabled and other-device states cancel analyzer', () async {
    await (await SharedPreferences.getInstance()).setString(
      proactiveOwnerDevicesKey,
      jsonEncode({
        _second: {'device_id': 'other', 'at_ms': 1},
      }),
    );
    final due = DateTime.now().add(const Duration(minutes: 10));
    await seed([
      const ConversationProactiveState(
        conversationId: _id,
        mode: ConversationProactiveMode.dormant,
      ),
      ConversationProactiveState(conversationId: _second, observingUntil: due),
      ConversationProactiveState(
        conversationId: _disabled,
        observingUntil: due,
      ),
    ]);
    await container.read(analyzerSchedulerProvider).onAppResumed();
    expect(alarms().last.method, 'cancelProactiveAlarm');
    expect(
      alarms().where((c) => c.method == 'scheduleProactiveAlarm'),
      isEmpty,
    );
  });
  test('pending trigger and clear remove observation alarm', () async {
    final scheduler = container.read(analyzerSchedulerProvider);
    await scheduler.handleUserMessageActivity(
      conversationId: _id,
      messageId: 'user',
      occurredAt: DateTime.now(),
    );
    await scheduler.onAutoTriggerCreated(
      AutoReplyTrigger(
        id: 'pending',
        title: 'pending',
        type: AutoReplyTriggerType.delay,
        status: AutoReplyTriggerStatus.pending,
        createdAt: DateTime.now(),
        nextFireAt: DateTime.now().add(const Duration(hours: 1)),
        allowNight: true,
        requireExact: false,
        delayMinutes: 60,
        manual: false,
        source: TriggerSource.aiScheduler,
        conversationId: _id,
      ),
    );
    expect(alarms().last.method, 'cancelProactiveAlarm');
    await scheduler.onConversationCleared(_id);
    expect(alarms().last.method, 'cancelProactiveAlarm');
  });
  test('explicit cancel follows a slow older native schedule', () async {
    final entered = Completer<void>();
    final finish = Completer<void>();
    intercept = (call) async {
      if (call.method == 'scheduleProactiveAlarm' && !entered.isCompleted) {
        entered.complete();
        await finish.future;
      }
    };
    final scheduler = container.read(analyzerSchedulerProvider);
    await scheduler.onAppResumed();
    scheduler.scheduleAnalysis(
      conversationId: _id,
      delay: const Duration(minutes: 10),
    );
    await entered.future;
    scheduler.cancel();
    finish.complete();
    await drain();
    expect(alarms().last.method, 'cancelProactiveAlarm');
  });
  test('dispose preserves the future native alarm', () async {
    await seed([
      ConversationProactiveState(
        conversationId: _id,
        observingUntil: DateTime.now().add(const Duration(minutes: 10)),
      ),
    ]);
    final scheduler = container.read(analyzerSchedulerProvider);
    scheduler.useNativeAlarmsOnly();
    await scheduler.flushAlarmSchedule();
    final count = alarms().length;
    container.dispose();
    await drain();
    expect(alarms(), hasLength(count));
    expect(alarms().last.method, 'scheduleProactiveAlarm');
  });
  test(
    'disposing during initialization does not access a disposed ref',
    () async {
      container.read(analyzerSchedulerProvider).useNativeAlarmsOnly();
      container.dispose();
      await drain();
      expect(analyzer.calls, isEmpty);
    },
  );
  test(
    'native-only engine persists deadlines without starting Dart timers',
    () async {
      final scheduler = container.read(analyzerSchedulerProvider);
      scheduler.useNativeAlarmsOnly();
      await scheduler.onAppResumed();
      scheduler.scheduleAnalysis(conversationId: _id, delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(analyzer.calls, isEmpty);
      expect(
        (await ConversationProactiveStateStorage().loadStates())[_id]!
            .observingUntil,
        isNotNull,
      );
      expect(alarms().last.method, 'scheduleProactiveAlarm');
      await scheduler.onNativeAlarmFired();
      expect(analyzer.calls, [_id]);
    },
  );
  test('sending preserves due observation until idle', () async {
    final scheduler = container.read(analyzerSchedulerProvider);
    await scheduler.onAppResumed();
    container.read(conversationSendingProvider(_id).notifier).state = true;
    final due = DateTime.now().add(const Duration(milliseconds: 500));
    await seed([
      ConversationProactiveState(conversationId: _id, observingUntil: due),
    ]);
    await scheduler.onNativeAlarmFired().timeout(const Duration(seconds: 5));
    expect(analyzer.calls, isEmpty);
    expect(
      (await ConversationProactiveStateStorage().loadStates())[_id]!
          .observingUntil,
      due,
    );
    container.read(conversationSendingProvider(_id).notifier).state = false;
    container.read(conversationIdleEventsProvider).add(_id);
    await drain();
    expect(
      at(alarms().last).difference(DateTime.now()).inSeconds,
      inInclusiveRange(298, 301),
    );
  });
  test(
    'platform callback reloads and awaits sequential analysis plus pregeneration',
    () async {
      container.read(autoReplyServiceProvider);
      final scheduler = container.read(analyzerSchedulerProvider);
      await scheduler.onAppResumed();
      final started = Completer<void>();
      final result = Completer<ContextAnalysisDecision?>();
      final draftStarted = Completer<void>();
      final draft = Completer<ProactiveDraft?>();
      analyzer.run = (conversation) async {
        if (conversation.id == _id) {
          started.complete();
          return result.future;
        }
        return const ContextAnalysisDecision(
          contextMessages: [],
          sessionPatch: ContextAnalysisSessionPatch(
            mode: ConversationProactiveMode.dormant,
          ),
        );
      };
      pregenerator.run = () {
        draftStarted.complete();
        return draft.future;
      };
      final due = DateTime.now().add(const Duration(seconds: 1));
      await seed([
        ConversationProactiveState(conversationId: _id, observingUntil: due),
        ConversationProactiveState(
          conversationId: _second,
          mode: ConversationProactiveMode.silent,
          silenceUntil: due,
        ),
      ]);
      final acknowledged = Completer<void>();
      Object? nativeError;
      messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onProactiveAlarmFired', {'slot': 'analyzer'}),
        ),
        (response) {
          try {
            const StandardMethodCodec().decodeEnvelope(response!);
          } catch (error) {
            nativeError = error;
          }
          acknowledged.complete();
        },
      );
      await started.future.timeout(const Duration(seconds: 5));
      expect(acknowledged.isCompleted, isFalse);
      expect(analyzer.calls, [_id]);
      result.complete(
        ContextAnalysisDecision(
          contextMessages: [],
          triggerPlan: ContextAnalysisTriggerPlan(
            kind: ProactiveReachOutKind.checkIn,
            title: 'check in',
            fireAt: DateTime.now().add(const Duration(hours: 1)),
            allowNight: true,
            priority: AutoReplyTriggerPriority.medium,
            systemReminder: 'check in',
          ),
        ),
      );
      await draftStarted.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(acknowledged.isCompleted, isFalse);
      expect(analyzer.calls, [_id]);
      draft.complete(const ProactiveDraft(text: 'ready reply'));
      await acknowledged.future.timeout(const Duration(seconds: 5));
      expect(nativeError, isNull);
      expect(analyzer.calls, [_id, _second]);
      expect(
        (await AutoReplyTriggerStorage().loadTriggers()).single.cachedContent,
        'ready reply',
      );
      expect(alarms().last.method, 'cancelProactiveAlarm');
    },
  );

  for (final slot in [
    ProactiveTimeSlot.inHalfHour,
    ProactiveTimeSlot.inHours,
  ]) {
    test('new topic accepts near-term slot ${slot.name}', () {
      final now = DateTime(2026, 11, 13, 12);
      final plan = ProactivePlanner(random: Random(1)).plan(
        answers: {
          'kind': const ProactiveAnswer.choice('new_topic'),
          'timing': ProactiveAnswer.choice(slot.label),
        },
        now: now,
        quietHours: const QuietHours.disabled(),
      );
      expect(plan.slot, slot);
      expect(
        plan.fireAt.difference(now),
        lessThanOrEqualTo(const Duration(hours: 2)),
      );
      expect(
        ProactivePlanner.defaultSlot[ProactiveReachOutKind.newTopic],
        ProactiveTimeSlot.nextMorning,
      );
    });
  }
}
