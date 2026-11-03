import 'dart:async';
import 'dart:io';

import 'package:aicove_flutter/src/core/app_logger.dart' show TraceLogger;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
}

class _OfflineRunner implements ApiRunner {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Provider lifecycle tests must not execute an API call');
}

class _History extends ChatHistoryStore {
  _History(super.ref);
  int appends = 0;
  bool persist = false;

  @override
  Future<void> appendUserMessage({
    required String conversationId,
    required Message message,
    required String displayText,
    bool updatePreview = true,
  }) async {
    appends++;
    if (persist) {
      await super.appendUserMessage(
        conversationId: conversationId,
        message: message,
        displayText: displayText,
        updatePreview: updatePreview,
      );
    }
  }
}

class _Generator extends ProactiveReplyGenerator {
  _Generator(super.ref);
  int generations = 0;
  Future<void> Function()? duringGeneration;

  @override
  Future<String> generate({
    required Conversation conversation,
    required String? reminder,
    required String turnId,
    DateTime? requestTime,
  }) async {
    generations++;
    await duringGeneration?.call();
    return '任务办好了';
  }
}

class _SettingsValue implements AppSettings {
  @override
  bool get ttsEnabled => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => _SettingsValue();
}

class _Send extends ChatSendService {
  _Send(super.ref);
  int processed = 0;

  @override
  Future<ApiCallResult> processAssistantReplyWithPlugins({
    required Conversation conv,
    required String rawReplyText,
  }) async {
    processed++;
    return ApiCallResult(
      replyText: rawReplyText,
      processedText: rawReplyText,
      pluginEvents: const [],
      toolResults: const [],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) => AssistantMessageBuildResult(
    rawMessage: Message.text(
      id: 'relay_raw',
      role: 'assistant',
      content: apiResult.rawReplyText,
      createdAt: DateTime(2026),
    ),
    messages: const [],
    lastMessageText: apiResult.rawReplyText,
  );
}

/// The delivery boundary evaluates the actual guard supplied by the provider.
/// Chat/TTS persistence and delayed supplements have their own service tests.
class _Delivery implements ChatTtsHandler {
  int attempts = 0;
  int committed = 0;
  bool? guardResult;
  Future<void> Function()? beforeCommit;

  @override
  Future<void> deliverSegmentedMessages({
    required String convId,
    required String userMsgId,
    required AssistantMessageBuildResult buildResult,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool ttsEnabled,
    bool appendAfterStreamText = false,
    List<String>? streamTextMessageIds,
    List<Message>? streamPendingTtsMessages,
    bool streamTtsResolutionManaged = false,
    TraceLogger? trace,
    FutureOr<bool> Function()? shouldCommit,
  }) async {
    attempts++;
    expect(shouldCommit, isNotNull);
    await beforeCommit?.call();
    guardResult = await shouldCommit!();
    if (guardResult!) committed++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late AgentTaskStore store;
  late ProviderContainer container;
  late Directory root;
  late PathProviderPlatform originalPaths;
  late _History history;
  late _Generator generator;
  late _Send send;
  late _Delivery delivery;
  late TaskAgentService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('batch1_task_provider_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({
      'aicove.cloud.device_id': 'batch1',
    });
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    store = AgentTaskStore(database);
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'c1',
            title: 'c1',
            displayName: 'c1',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
    delivery = _Delivery();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        backgroundApiRunnerProvider.overrideWithValue(_OfflineRunner()),
        chatHistoryStoreProvider.overrideWith((ref) => history = _History(ref)),
        proactiveReplyGeneratorProvider.overrideWith(
          (ref) => generator = _Generator(ref),
        ),
        chatSendServiceProvider.overrideWith((ref) => send = _Send(ref)),
        chatTtsHandlerProvider.overrideWithValue(delivery),
        appSettingsProvider.overrideWith(_Settings.new),
      ],
    );
    service = await container.read(taskAgentServiceProvider.future);
    history = container.read(chatHistoryStoreProvider) as _History;
    generator = container.read(proactiveReplyGeneratorProvider) as _Generator;
    send = container.read(chatSendServiceProvider) as _Send;
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  Future<RecordedReceipt> receipt({bool writeAnchor = true}) async {
    await store.create(
      id: 't',
      requestKey: null,
      conversationId: 'c1',
      instruction: 'work',
    );
    final recorded = (await store.finish(
      't',
      from: {AgentTaskStatus.queued},
      to: AgentTaskStatus.done,
      executorDevice: 'batch1',
      summary: 'done',
    ))!;
    if (writeAnchor) {
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: recorded.messageId,
              conversationId: 'c1',
              role: 'user',
              content: 'receipt',
              createdAt: 0,
            ),
          );
    }
    return recorded;
  }

  Future<void> clearRawHistory() => database.customStatement(
    "UPDATE messages SET deleted_at=1 WHERE conversation_id='c1'",
  );

  Future<void> expectSettled() async {
    expect(await store.pendingDeliveries(), isEmpty);
    final row = await database
        .customSelect(
          "SELECT state FROM agent_task_deliveries WHERE receipt_id='t_1'",
        )
        .getSingle();
    expect(row.read<String>('state'), 'done');
  }

  test(
    'deleted conversation skips append and recovery clears receipt outbox',
    () async {
      await receipt(writeAnchor: false);
      await database.customStatement(
        "UPDATE conversations SET deleted_at=1 WHERE id='c1'",
      );
      await service.recover();
      expect(history.appends, 0);
      expect(await store.unwrittenReceipts(), isEmpty);
      expect(await database.select(database.messages).get(), isEmpty);
      await expectSettled();
    },
  );

  test('active conversation still appends its receipt', () async {
    final recorded = await receipt(writeAnchor: false);
    await service.writeReceipt(recorded);
    expect(history.appends, 1);
  });

  test(
    'real history and timeline cache write receipt inside the outer transaction',
    () async {
      final recorded = await receipt(writeAnchor: false);
      history.persist = true;
      await service.writeReceipt(recorded).timeout(const Duration(seconds: 5));
      final message = await (database.select(
        database.messages,
      )..where((row) => row.id.equals(recorded.messageId))).getSingle();
      expect(message.deletedAt, isNull);
      expect(message.content, recorded.block.content);
      final blocks = await (database.select(
        database.messageBlocks,
      )..where((row) => row.messageId.equals(recorded.messageId))).get();
      expect(blocks, hasLength(1));
      expect(blocks.single.data, contains(recorded.block.receiptId));
    },
  );

  test('deleted anchor settles without invoking generation', () async {
    final recorded = await receipt();
    await clearRawHistory();
    await service.deliver(recorded.block.receiptId, recorded.block);
    expect(generator.generations, 0);
    expect(send.processed, 0);
    expect(delivery.attempts, 0);
    await expectSettled();
  });

  test(
    'clearing history during generation skips delivery and settles',
    () async {
      final recorded = await receipt();
      generator.duringGeneration = clearRawHistory;
      await service.deliver(recorded.block.receiptId, recorded.block);
      expect(generator.generations, 1);
      expect(send.processed, 0);
      expect(delivery.attempts, 0);
      await expectSettled();
    },
  );

  test(
    'commit guard rechecks anchor after generation and plugin processing',
    () async {
      final recorded = await receipt();
      delivery.beforeCommit = clearRawHistory;
      await service.deliver(recorded.block.receiptId, recorded.block);
      expect(generator.generations, 1);
      expect(send.processed, 1);
      expect(delivery.attempts, 1);
      expect(delivery.guardResult, isFalse);
      expect(delivery.committed, 0);
      await expectSettled();
    },
  );

  test('active anchor permits normal relay commit', () async {
    final recorded = await receipt();
    await service.deliver(recorded.block.receiptId, recorded.block);
    expect(generator.generations, 1);
    expect(send.processed, 1);
    expect(delivery.guardResult, isTrue);
    expect(delivery.committed, 1);
    await expectSettled();
  });
}
