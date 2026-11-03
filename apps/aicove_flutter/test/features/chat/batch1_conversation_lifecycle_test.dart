import 'dart:async';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state_storage.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _id = 'batch1_conversation';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

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

class _Tasks implements TaskAgentService {
  final aborted = Completer<String>();
  @override
  Future<void> abortForDeletedConversation(String conversationId) async {
    aborted.complete(conversationId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previousPaths;
  late db.AppDatabase database;
  late ProviderContainer container;
  late _Tasks tasks;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('aicove_batch1_conversation_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.now();
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: _id,
            title: 'Role',
            displayName: 'Role',
            createdAt: now.millisecondsSinceEpoch,
            updatedAt: now.millisecondsSinceEpoch,
          ),
        );
    await database
        .into(database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: 'user',
            conversationId: _id,
            role: 'user',
            content: 'hello',
            createdAt: now.millisecondsSinceEpoch,
          ),
        );
    await ConversationProactiveStateStorage().saveStates({
      _id: ConversationProactiveState(
        conversationId: _id,
        pendingAutoTriggerId: 'auto',
        lastUserMessageId: 'user',
        lastUserAt: now,
      ),
    });
    await AutoReplyTriggerStorage().saveTriggers([
      for (final source in [
        TriggerSource.aiScheduler,
        TriggerSource.userManual,
      ])
        AutoReplyTrigger(
          id: source == TriggerSource.aiScheduler ? 'auto' : 'manual',
          title: 'reminder',
          type: AutoReplyTriggerType.delay,
          status: AutoReplyTriggerStatus.pending,
          createdAt: now,
          nextFireAt: now.add(const Duration(hours: 1)),
          allowNight: true,
          requireExact: false,
          delayMinutes: 60,
          manual: source == TriggerSource.userManual,
          source: source,
          conversationId: _id,
          contextLastUserMessageId: 'user',
        ),
    ]);
    tasks = _Tasks();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        conversationsProvider.overrideWith(_Conversations.new),
        taskAgentServiceProvider.overrideWith((_) async => tasks),
      ],
    );
    await container.read(conversationsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  test(
    'clear entry point resets proactive lifecycle but retains manual reminders',
    () async {
      await container.read(conversationsProvider.notifier).clearMessages(_id);
      final state = (await ConversationProactiveStateStorage()
          .loadStates())[_id]!;
      expect(state.lastUserAt, isNull);
      expect(state.pendingAutoTriggerId, isNull);
      expect(
        (await AutoReplyTriggerStorage().loadTriggers()).single.id,
        'manual',
      );
      expect(
        (await database.select(database.messages).get()).single.deletedAt,
        isNotNull,
      );
      expect(tasks.aborted.isCompleted, isFalse);
    },
  );

  test(
    'delete entry point removes all reminders and aborts task work',
    () async {
      await container
          .read(conversationsProvider.notifier)
          .deleteConversation(_id);
      expect(
        await tasks.aborted.future.timeout(const Duration(seconds: 5)),
        _id,
      );
      expect(
        (await ConversationProactiveStateStorage().loadStates()).containsKey(
          _id,
        ),
        isFalse,
      );
      expect(await AutoReplyTriggerStorage().loadTriggers(), isEmpty);
      expect(
        (await database.select(database.conversations).get()).single.deletedAt,
        isNotNull,
      );
      expect(
        (await database.select(database.messages).get()).single.deletedAt,
        isNotNull,
      );
    },
  );
}
