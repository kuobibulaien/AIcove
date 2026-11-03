import 'dart:async';
import 'dart:convert';

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
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _conversationId = 'batch1_scheduler';
const _triggerKey = 'aicove.auto_triggers.v1';

class _Conversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
    Conversation(
      id: _conversationId,
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
    started.complete();
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

AutoReplyTrigger _trigger(String id, TriggerSource source, {String? convId}) =>
    AutoReplyTrigger(
      id: id,
      title: id,
      type: AutoReplyTriggerType.delay,
      status: AutoReplyTriggerStatus.pending,
      createdAt: DateTime.now(),
      nextFireAt: DateTime.now().add(const Duration(hours: 12)),
      allowNight: true,
      requireExact: false,
      delayMinutes: 720,
      manual: source == TriggerSource.userManual,
      source: source,
      conversationId: convId ?? _conversationId,
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
            id: _conversationId,
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

  Future<void> seedTriggers() async {
    await AutoReplyTriggerStorage().saveTriggers([
      _trigger('auto', TriggerSource.aiScheduler),
      _trigger('manual', TriggerSource.userManual),
      _trigger('requested', TriggerSource.userRequest),
      _trigger('other', TriggerSource.aiScheduler, convId: 'other'),
    ]);
    await container
        .read(autoReplyTriggersProvider.notifier)
        .reloadFromStorage();
  }

  Future<void> startAnalysis() async {
    container
        .read(analyzerSchedulerProvider)
        .scheduleAnalysis(
          conversationId: _conversationId,
          delay: Duration.zero,
        );
    await analyzer.started.future.timeout(const Duration(seconds: 5));
  }

  Future<void> drain() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  const silent = ContextAnalysisDecision(
    contextMessages: [],
    sessionPatch: ContextAnalysisSessionPatch(
      mode: ConversationProactiveMode.dormant,
    ),
  );

  test(
    'clear resets state, cancels timers, and preserves manual reminders',
    () async {
      await seedTriggers();
      final scheduler = container.read(analyzerSchedulerProvider);
      await scheduler.handleUserMessageActivity(
        conversationId: _conversationId,
        messageId: 'old',
        occurredAt: DateTime.now(),
      );
      await seedTriggers();
      await scheduler.onConversationCleared(_conversationId);

      final state = (await ConversationProactiveStateStorage()
          .loadStates())[_conversationId]!;
      expect(state.lastUserAt, isNull);
      expect(state.lastUserMessageId, isNull);
      expect(state.pendingAutoTriggerId, isNull);
      expect(state.unrepliedCount, 0);
      expect(state.mode, ConversationProactiveMode.active);
      expect(
        (await AutoReplyTriggerStorage().loadTriggers()).map((t) => t.id),
        ['manual', 'requested', 'other'],
      );
      await scheduler.onAppResumed();
      await drain();
      expect(analyzer.started.isCompleted, isFalse);
    },
  );

  test(
    'delete removes state and every reminder for just that conversation',
    () async {
      await seedTriggers();
      final scheduler = container.read(analyzerSchedulerProvider);
      await scheduler.onConversationCleared(_conversationId);
      await seedTriggers();
      await scheduler.onConversationDeleted(_conversationId);
      expect(
        (await ConversationProactiveStateStorage().loadStates()).containsKey(
          _conversationId,
        ),
        isFalse,
      );
      expect(
        (await AutoReplyTriggerStorage().loadTriggers()).single.id,
        'other',
      );
    },
  );

  test(
    'batch removal reads storage, including triggers absent from memory',
    () async {
      await AutoReplyTriggerStorage().saveTriggers([
        _trigger('background', TriggerSource.aiScheduler),
        _trigger('manual', TriggerSource.userManual),
      ]);
      await container
          .read(autoReplyTriggersProvider.notifier)
          .removeTriggersForConversation(
            _conversationId,
            onlyAutoScheduled: true,
          );
      expect(
        container.read(autoReplyTriggersProvider).requireValue.single.id,
        'manual',
      );
    },
  );

  test(
    'resume reloads trigger states written by the background isolate',
    () async {
      await seedTriggers();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _triggerKey,
        jsonEncode([
          _trigger(
            'auto',
            TriggerSource.aiScheduler,
          ).copyWith(status: AutoReplyTriggerStatus.fired).toJson(),
        ]),
      );
      await container.read(analyzerSchedulerProvider).onAppResumed();
      expect(
        container.read(autoReplyTriggersProvider).requireValue.single.status,
        AutoReplyTriggerStatus.fired,
      );
    },
  );

  test('a current analysis still applies its decision', () async {
    await startAnalysis();
    analyzer.result.complete(silent);
    await drain();
    expect(
      (await ConversationProactiveStateStorage().loadStates())[_conversationId]!
          .mode,
      ConversationProactiveMode.dormant,
    );
  });

  for (final change in ['clear', 'delete', 'soft_delete', 'new_user']) {
    test(
      'an analysis finishing after $change cannot restore stale state',
      () async {
        await startAnalysis();
        final scheduler = container.read(analyzerSchedulerProvider);
        if (change == 'clear') {
          await scheduler.onConversationCleared(_conversationId);
        } else if (change == 'delete') {
          await scheduler.onConversationDeleted(_conversationId);
        } else if (change == 'soft_delete') {
          await (database.update(
            database.conversations,
          )..where((c) => c.id.equals(_conversationId))).write(
            db.ConversationsCompanion(
              deletedAt: Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
        } else {
          await database
              .into(database.messages)
              .insert(
                db.MessagesCompanion.insert(
                  id: 'new_user',
                  conversationId: _conversationId,
                  role: 'user',
                  content: 'new',
                  createdAt: DateTime.now().millisecondsSinceEpoch,
                ),
              );
        }
        analyzer.result.complete(silent);
        await drain();
        final state = (await ConversationProactiveStateStorage()
            .loadStates())[_conversationId];
        expect(state?.mode, isNot(ConversationProactiveMode.dormant));
      },
    );
  }

  for (final change in ['clear', 'delete']) {
    test('a draft finishing after $change cannot recreate a trigger', () async {
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
      await pregenerator.started.future.timeout(const Duration(seconds: 5));
      final scheduler = container.read(analyzerSchedulerProvider);
      if (change == 'clear') {
        await scheduler.onConversationCleared(_conversationId);
      } else {
        await scheduler.onConversationDeleted(_conversationId);
      }
      pregenerator.result.complete(null);
      await drain();
      expect(await AutoReplyTriggerStorage().loadTriggers(), isEmpty);
      final state = (await ConversationProactiveStateStorage()
          .loadStates())[_conversationId];
      expect(state?.hasPendingAutoTrigger ?? false, isFalse);
      if (change == 'delete') expect(state, isNull);
    });
  }
}
