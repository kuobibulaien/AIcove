import 'dart:async';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_dispatch_service.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _convId = 'batch1_dispatch';

class _Conversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
    Conversation(
      id: _convId,
      title: 'Role',
      displayName: 'Role',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  ];
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({});
}

class _Send implements ChatSendService {
  _Send(this.raw);
  final Message raw;

  @override
  Future<ApiCallResult> processAssistantReplyWithPlugins({
    required Conversation conv,
    required String rawReplyText,
  }) async => ApiCallResult(
    replyText: rawReplyText,
    processedText: rawReplyText,
    pluginEvents: const [],
    toolResults: const [],
  );

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
    String? rawMessageId,
    DateTime? createdAt,
  }) => AssistantMessageBuildResult(
    rawMessage: raw,
    messages: [raw],
    lastMessageText: 'reply',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Delivery implements ChatTtsHandler {
  _Delivery(this.run);
  final Future<void> Function(FutureOr<bool> Function() guard) run;

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
  }) => run(shouldCommit!);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final observeBeforeClear in [true, false]) {
    test('clearing a committed anchor stops subsequent segments '
        '(observed before clear: $observeBeforeClear)', () async {
      SharedPreferences.setMockInitialValues({});
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final now = DateTime.now();
      final raw = Message.text(
        id: 'raw_reply',
        role: 'assistant',
        content: 'reply',
        createdAt: now,
      );
      await database
          .into(database.conversations)
          .insert(
            db.ConversationsCompanion.insert(
              id: _convId,
              title: 'Role',
              displayName: 'Role',
              createdAt: now.millisecondsSinceEpoch,
              updatedAt: now.millisecondsSinceEpoch,
            ),
          );
      var guarded = false;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          conversationsProvider.overrideWith(_Conversations.new),
          appSettingsProvider.overrideWith(_Settings.new),
          chatSendServiceProvider.overrideWithValue(_Send(raw)),
          chatTtsHandlerProvider.overrideWithValue(
            _Delivery((guard) async {
              // Entry and pre-write checks may repeat before the raw row exists.
              expect(await guard(), isTrue);
              expect(await guard(), isTrue);
              await database
                  .into(database.messages)
                  .insert(
                    db.MessagesCompanion.insert(
                      id: raw.id,
                      conversationId: _convId,
                      role: 'assistant',
                      content: 'reply',
                      createdAt: now.millisecondsSinceEpoch,
                    ),
                  );
              if (observeBeforeClear) expect(await guard(), isTrue);
              await (database.update(
                database.messages,
              )..where((m) => m.id.equals(raw.id))).write(
                db.MessagesCompanion(
                  deletedAt: Value(now.millisecondsSinceEpoch),
                ),
              );
              expect(await guard(), isFalse);
              guarded = true;
            }),
          ),
        ],
      );
      try {
        await container.read(conversationsProvider.future);
        final result = await container
            .read(autoReplyDispatchServiceProvider)
            .dispatchTestTrigger(
              AutoReplyTrigger(
                id: 'trigger',
                title: 'check in',
                type: AutoReplyTriggerType.delay,
                status: AutoReplyTriggerStatus.prepared,
                createdAt: now,
                nextFireAt: now,
                allowNight: true,
                requireExact: false,
                delayMinutes: 1,
                manual: false,
                conversationId: _convId,
                cachedContent: 'reply',
                preparedAt: now,
              ),
            );
        expect(guarded, isTrue);
        expect(result.success, isFalse);
        expect(result.reason, 'delivery_anchor_no_longer_active');
      } finally {
        container.dispose();
        await database.close();
      }
    });
  }
}
