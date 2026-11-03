import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

import 'edit_regenerate_audit_test.dart' show AuditHistory, AuditSettings, auditSettings;

class _ControlledSend extends ChatSendService {
  _ControlledSend(super.ref, this.settings, {required this.emitDelta});

  final AppSettings settings;
  final bool emitDelta;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
    DateTime? requestTime,
    bool persistSideEffects = true,
    bool deferReminders = false,
    bool forceInlineImageRoute = false,
  }) async => ApiConfig(
        settings: settings,
        modelFullId: overrideModel ?? settings.defaultModelName,
        providerApiBase: settings.apiBaseUrl,
        providerApiKey: null,
        customConfig: const {},
        messages: const [],
        tools: null,
        enabledPluginIds: null,
        modelTemperature: null,
        modelTopP: null,
        modelContextMessageLimit: null,
      );

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    if (emitDelta) onStreamTextDelta!('还没结束');
    started.complete();
    await release.future;
    return ApiCallResult(
      replyText: '还没结束',
      processedText: '还没结束',
      pluginEvents: const [],
      toolResults: const [],
      reasoning: '',
    );
  }
}

class _FailingCommitHistory extends AuditHistory {
  _FailingCommitHistory(super.messages);

  final attempted = Completer<void>();

  @override
  Future<Future<void> Function()> prepareTruncateAfterMessage({
    required String conversationId,
    required String anchorMessageId,
  }) async => () async {
        if (!attempted.isCompleted) attempted.complete();
        throw StateError('truncate commit failed');
      };
}

bool _placeholder(Message m) =>
    m.role == 'assistant' &&
    m.status == 'sending' &&
    (m.blocks?.whereType<TextBlock>().any((b) =>
            b.status == BlockStatus.streaming && b.content.trim() == '生成中...') ??
        false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final activeChannel in [false, true]) {
    for (final scenario in ['no delta', 'unsealed delta', 'truncate failure']) {
      test('重生成 $scenario，活跃通道=$activeChannel', () async {
        SharedPreferences.setMockInitialValues({});
        final now = DateTime(2026, 1, 1);
        final user = Message(id: 'u', role: 'user', content: '你好', createdAt: now);
        final old = Message(
          id: 'old', role: 'assistant', content: '旧回复', status: 'sent',
          createdAt: now.add(const Duration(seconds: 1)),
        );
        final conv = Conversation(
          id: 'regenerate', title: 'test', displayName: 'test',
          createdAt: now, updatedAt: now, messages: [user, old],
        );
        final database = db.AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        await database.into(database.conversations).insert(
          db.ConversationsCompanion.insert(
            id: conv.id, title: conv.title, displayName: conv.displayName,
            createdAt: now.millisecondsSinceEpoch,
            updatedAt: now.millisecondsSinceEpoch,
          ),
        );
        for (final m in [user, old]) {
          await database.into(database.messages).insert(db.MessagesCompanion.insert(
            id: m.id, conversationId: conv.id, role: m.role, content: m.content,
            createdAt: m.createdAt.millisecondsSinceEpoch,
          ));
        }
        final settings = auditSettings.copyWith(
          defaultModelName: 'openai:gpt-4o-mini',
          defaultChatModels: const ['openai:gpt-4o-mini'],
          messageChunkingEnabled: true,
          messageFormatConfig: const MessageFormatConfig(
            enableChunking: true,
            chunkPunctuations: ['。', '！', '？'],
            minSegmentLength: 1,
          ),
        );
        final failure = scenario == 'truncate failure'
            ? _FailingCommitHistory([user, old]) : null;
        late _ControlledSend send;
        final container = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(database),
          activeConversationProvider.overrideWith((ref) => conv),
          appSettingsProvider.overrideWith(() => AuditSettings(Future.value(settings))),
          streamProjectionPolicyProvider.overrideWithValue(
            StreamProjectionPolicy(useActiveStreamChannel: activeChannel),
          ),
          if (failure != null) chatHistoryPortProvider.overrideWithValue(failure),
          chatSendServiceProvider.overrideWith((ref) => send = _ControlledSend(
            ref, settings, emitDelta: scenario != 'no delta',
          )),
        ]);
        addTearDown(container.dispose);
        container.read(chatSendServiceProvider);
        await container.read(appSettingsProvider.future);
        final store = container.read(chatHistoryStoreProvider);
        final initial = await store.loadCachedTimelineMessages(conv.id);
        expect(initial.any((m) => m.id == old.id), isTrue);
        final pending = container.read(chatActionsProvider).regenerate(old.id);
        addTearDown(() async {
          if (!send.release.isCompleted) send.release.complete();
          await pending;
        });
        await send.started.future.timeout(const Duration(seconds: 5));
        if (failure != null) {
          await failure.attempted.future.timeout(const Duration(seconds: 5));
          await Future<void>.delayed(const Duration(milliseconds: 550));
        } else {
          await Future<void>.delayed(Duration(milliseconds: scenario == 'no delta' ? 650 : 300));
        }
        final timeline = await store.loadCachedTimelineMessages(conv.id);
        final projection = container.read(activeStreamProjectionsProvider)[conv.id];
        final hasPlaceholder = timeline.any(_placeholder) ||
            projection?.phase == ActiveStreamPhase.thinking;
        if (scenario == 'no delta') {
          expect(timeline.any((m) => m.id == old.id && m.displayText == '旧回复'), isTrue);
          expect(hasPlaceholder, isFalse);
        } else if (failure != null) {
          expect(timeline.any((m) => m.id == old.id), isTrue);
          expect(hasPlaceholder, isFalse);
          send.release.complete();
          await pending;
          expect(container.read(conversationErrorProvider(conv.id)), contains('truncate commit failed'));
          expect((await store.loadCachedTimelineMessages(conv.id)).any(_placeholder), isFalse);
          expect(container.read(activeStreamProjectionsProvider)[conv.id], isNull);
        } else {
          expect(timeline.any((m) => m.id == old.id), isFalse);
          expect(hasPlaceholder, isTrue);
        }
      });
    }
  }
}
