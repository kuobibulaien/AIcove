import 'dart:async';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/analyzer_scheduler.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/context_analyzer.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_message_pregenerator.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_action.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_decision.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:drift/native.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_claim_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _id = 'stage3_scheduler';

class _Conversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
    Conversation(
      id: _id,
      title: 'Role',
      displayName: 'Role',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      enabledPlugins: const ['trigger'],
    ),
  ];
}

class _Analyzer extends ContextAnalyzer {
  _Analyzer(super.ref);
  final started = Completer<void>();
  final result = Completer<ContextAnalysisDecision?>();

  @override
  Future<ContextAnalysisDecision?> analyze(
    Conversation conversation, {
    required ConversationProactiveState proactiveState,
  }) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}

class _Pregenerator extends ProactiveMessagePregenerator {
  _Pregenerator(super.ref);
  final started = Completer<void>();
  final result = Completer<ProactiveDraft?>();

  @override
  Future<ProactiveDraft?> generate({
    required Conversation conversation,
    required String systemReminder,
    required DateTime fireAt,
    bool allowCall = false,
  }) {
    started.complete();
    return result.future;
  }
}

AutoReplyTrigger _trigger(
  String id, {
  AutoReplyTriggerPriority priority = AutoReplyTriggerPriority.medium,
}) => AutoReplyTrigger(
  id: id,
  title: id,
  type: AutoReplyTriggerType.delay,
  status: AutoReplyTriggerStatus.pending,
  createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
  nextFireAt: DateTime.now().add(const Duration(hours: 1)),
  allowNight: true,
  requireExact: false,
  delayMinutes: 60,
  manual: false,
  source: TriggerSource.aiScheduler,
  priority: priority,
  conversationId: _id,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  late _Analyzer analyzer;
  late _Pregenerator pregenerator;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.now().millisecondsSinceEpoch;
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: _id,
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
        contextAnalyzerProvider.overrideWith(
          (ref) => analyzer = _Analyzer(ref),
        ),
        proactiveMessagePregeneratorProvider.overrideWith(
          (ref) => pregenerator = _Pregenerator(ref),
        ),
      ],
    );
    await container.read(conversationsProvider.future);
    await container.read(autoReplyTriggersProvider.future);
    container.read(contextAnalyzerProvider);
    container.read(proactiveMessagePregeneratorProvider);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  Future<void> drain() =>
      Future<void>.delayed(const Duration(milliseconds: 80));
  Future<void> startAnalysis() async {
    container
        .read(analyzerSchedulerProvider)
        .scheduleAnalysis(conversationId: _id, delay: Duration.zero);
    await analyzer.started.future.timeout(const Duration(seconds: 2));
  }

  test(
    'new user activity preserves explicit high priority AI reminders',
    () async {
      await AutoReplyTriggerStorage().saveTriggers([
        _trigger('high', priority: AutoReplyTriggerPriority.high),
        _trigger('ordinary'),
      ]);
      await container
          .read(autoReplyTriggersProvider.notifier)
          .reloadFromStorage();
      await container
          .read(analyzerSchedulerProvider)
          .handleUserMessageActivity(
            conversationId: _id,
            messageId: 'new',
            occurredAt: DateTime.now(),
          );
      expect(
        (await AutoReplyTriggerStorage().loadTriggers()).map((t) => t.id),
        ['high'],
      );
    },
  );

  test(
    'orphan pending pointer does not suppress analysis after resume',
    () async {
      await ConversationProactiveStateStorage().saveStates({
        _id: ConversationProactiveState(
          conversationId: _id,
          pendingAutoTriggerId: 'gone',
          lastUserAt: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      });
      await startAnalysis();
      analyzer.result.complete(
        const ContextAnalysisDecision(contextMessages: []),
      );
      await drain();
      expect(
        (await ConversationProactiveStateStorage().loadStates())[_id]!
            .pendingAutoTriggerId,
        isNull,
      );
    },
  );

  test(
    'failed pregeneration still creates a live-generation trigger',
    () async {
      await startAnalysis();
      analyzer.result.complete(
        ContextAnalysisDecision(
          contextMessages: const [],
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
      await pregenerator.started.future.timeout(const Duration(seconds: 2));
      pregenerator.result.completeError(StateError('network unavailable'));
      await drain();
      final triggers = await AutoReplyTriggerStorage().loadTriggers();
      expect(triggers, hasLength(1));
      expect(triggers.single.cachedContent, isNull);
      expect(triggers.single.status, AutoReplyTriggerStatus.pending);
    },
  );

  test(
    'analysis failure schedules a backoff rather than losing its wakeup',
    () async {
      await startAnalysis();
      analyzer.result.completeError(StateError('temporary network failure'));
      await drain();
      final logs = await AutoReplyTriggerStorage().loadLogs();
      expect(
        logs.any(
          (log) =>
              log.event == 'analysis_scheduled' &&
              log.metadata['reason'] == 'analysis_retry',
        ),
        isTrue,
      );
      expect(await AutoReplyTriggerStorage().loadTriggers(), isEmpty);
    },
  );

  test(
    'disabling care clears high and ordinary AI triggers but not manual reminders',
    () async {
      await AutoReplyTriggerStorage().saveTriggers([
        _trigger('high', priority: AutoReplyTriggerPriority.high),
        _trigger('ordinary'),
        _trigger(
          'manual',
        ).copyWith(source: TriggerSource.userManual, manual: true),
      ]);
      final role = container.read(conversationsProvider).requireValue.single;
      await container
          .read(analyzerSchedulerProvider)
          .syncConversationActivation(role.copyWith(enabledPlugins: const <String>[]));
      expect(
        (await AutoReplyTriggerStorage().loadTriggers()).map((t) => t.id),
        ['manual'],
      );
    },
  );

  test(
    'a reminder arriving during pregeneration is not deleted on draft failure',
    () async {
      await startAnalysis();
      analyzer.result.complete(
        ContextAnalysisDecision(
          contextMessages: const [],
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
      await pregenerator.started.future.timeout(const Duration(seconds: 2));
      await AutoReplyTriggerStorage().saveTriggers([_trigger('newer')]);
      pregenerator.result.completeError(
        StateError('temporary network failure'),
      );
      await drain();
      expect(
        (await AutoReplyTriggerStorage().loadTriggers()).map((t) => t.id),
        ['newer'],
      );
    },
  );

  test(
    'late delivery completion cannot put a replied conversation to sleep',
    () async {
      final trigger = _trigger('old');
      final at = DateTime.now();
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: 'new_user',
              conversationId: _id,
              role: 'user',
              content: 'I replied',
              createdAt: at.millisecondsSinceEpoch,
            ),
          );
      final scheduler = container.read(analyzerSchedulerProvider);
      await scheduler.handleUserMessageActivity(
        conversationId: _id,
        messageId: 'new_user',
        occurredAt: at,
      );
      await scheduler.onAutoTriggerSendCompleted(
        trigger: trigger,
        success: true,
        retryable: false,
        occurredAt: at,
      );
      final state = (await ConversationProactiveStateStorage()
          .loadStates())[_id]!;
      expect(state.mode, ConversationProactiveMode.active);
      expect(state.unrepliedCount, 0);
      expect(state.lastUserMessageId, 'new_user');
      expect(state.silenceUntil, isNull);
    },
  );
  test('observation deadline persists and survives resume unchanged', () async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    await ConversationProactiveStateStorage().saveStates({
      _id: ConversationProactiveState(
        conversationId: _id,
        lastUserAt: DateTime.now().subtract(const Duration(minutes: 20)),
        observingUntil: deadline,
      ),
    });
    final scheduler = container.read(analyzerSchedulerProvider);
    await scheduler.onAppResumed();
    await drain();
    expect(analyzer.started.isCompleted, isFalse);
    final state = (await ConversationProactiveStateStorage()
        .loadStates())[_id]!;
    expect(
      state.observingUntil!.difference(deadline).inMilliseconds.abs(),
      lessThan(100),
    );
  });

  test('AI idle refreshes a full five minute observation', () async {
    final scheduler = container.read(analyzerSchedulerProvider);
    await scheduler.handleUserMessageActivity(
      conversationId: _id,
      messageId: 'user',
      occurredAt: DateTime.now(),
    );
    scheduler.scheduleAnalysis(
      conversationId: _id,
      delay: const Duration(seconds: 20),
    );
    await drain();
    final before = DateTime.now();
    container.read(conversationIdleEventsProvider).add(_id);
    await drain();
    final state = (await ConversationProactiveStateStorage()
        .loadStates())[_id]!;
    expect(
      state.observingUntil!.difference(before).inSeconds,
      inInclusiveRange(299, 301),
    );
  });

  test('sending skips analysis until idle and resets observation', () async {
    final scheduler = container.read(analyzerSchedulerProvider);
    await scheduler.handleUserMessageActivity(
      conversationId: _id,
      messageId: 'user',
      occurredAt: DateTime.now(),
    );
    container.read(conversationSendingProvider(_id).notifier).state = true;
    scheduler.scheduleAnalysis(conversationId: _id, delay: Duration.zero);
    await drain();
    expect(analyzer.started.isCompleted, isFalse);
    container.read(conversationSendingProvider(_id).notifier).state = false;
    container.read(conversationIdleEventsProvider).add(_id);
    await drain();
    expect(
      (await ConversationProactiveStateStorage().loadStates())[_id]!
          .observingUntil,
      isNotNull,
    );
  });

  test(
    'another isolate claim blocks analysis, release allows next run',
    () async {
      final claims = AutoReplyClaimStore(database);
      final token = await claims.tryClaim(
        triggerId: 'analyzer:$_id',
        claimedBy: AutoReplyClaimOwner.background,
      );
      container
          .read(analyzerSchedulerProvider)
          .scheduleAnalysis(conversationId: _id, delay: Duration.zero);
      await drain();
      expect(analyzer.started.isCompleted, isFalse);
      await claims.release('analyzer:$_id', token!);
      await startAnalysis();
      analyzer.result.complete(
        const ContextAnalysisDecision(contextMessages: []),
      );
      await drain();
      expect(await claims.stateOf('analyzer:$_id'), isA<AutoReplyClaimFree>());
    },
  );

  test('expired persisted observation runs immediately', () async {
    await ConversationProactiveStateStorage().saveStates({
      _id: ConversationProactiveState(
        conversationId: _id,
        lastUserAt: DateTime.now(),
        observingUntil: DateTime.now().subtract(const Duration(seconds: 1)),
      ),
    });
    container.read(analyzerSchedulerProvider);
    await analyzer.started.future.timeout(const Duration(seconds: 3));
    expect(
      (await ConversationProactiveStateStorage().loadStates())[_id]!
          .observingUntil,
      isNull,
    );
    analyzer.result.complete(
      const ContextAnalysisDecision(contextMessages: []),
    );
    await drain();
  });

  test('observation JSON and transitions clear stale deadlines', () {
    final state = ConversationProactiveState(
      conversationId: _id,
      observingUntil: DateTime(2026, 11, 13),
    );
    expect(
      ConversationProactiveState.fromJson(state.toJson()).observingUntil,
      state.observingUntil,
    );
    expect(state.withObservingUntil(null).observingUntil, isNull);
    expect(state.withPendingAutoTrigger('pending').observingUntil, isNull);
    expect(
      state
          .applySessionPatch(mode: ConversationProactiveMode.silent)
          .observingUntil,
      isNull,
    );
    expect(
      state.copyWith(mode: ConversationProactiveMode.dormant).observingUntil,
      isNull,
    );
  });

  for (final failure in ['none', 'start', 'release']) {
    final failStart = failure == 'start';
    test(
      'analysis keeps generation lease through drafts (failure: $failure)',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        const channel = MethodChannel('com.example.aicove_flutter/keep_alive');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final transitions = <bool>[];
        var active = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'setGenerationActive') {
            active = (call.arguments as Map)['active'] == true;
            transitions.add(active);
            if ((active && failStart) || (!active && failure == 'release')) {
              throw PlatformException(code: 'denied');
            }
            return null;
          }
          return <String, Object>{
            'generationActive': active,
            'serviceRunning': active,
            'generationWakeLockHeld': active,
          };
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
          debugDefaultTargetPlatformOverride = null;
        });
        await startAnalysis();
        expect(transitions, failStart ? [true, false] : [true]);
        analyzer.result.complete(
          ContextAnalysisDecision(
            contextMessages: const [],
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
        await pregenerator.started.future.timeout(const Duration(seconds: 2));
        expect(transitions, failStart ? [true, false] : [true]);
        pregenerator.result.complete(null);
        await drain();
        expect(transitions, [true, false]);
      },
    );
  }
}
