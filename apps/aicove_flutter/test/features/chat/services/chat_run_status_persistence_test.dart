import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../task_agent/agent_execution_reliability_test.dart' as app;
import 'agent_execution_audit_test.dart' as audit;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('length text returns truncated status and machine reason', () async {
    final result = await audit.run(
      app.ScriptClient(
        (_, _) async => const SendMessageRichResult(
          text: 'partial',
          toolResults: [],
          rawFinishReason: 'length',
        ),
      ),
      [],
    );
    expect(result.status, ApiRunStatus.truncated);
    expect(result.stopReason, 'length');
  });
  test(
    'codemode ToolBlock contract B survives raw payload and DB reload',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      await database
          .into(database.conversations)
          .insert(
            db.ConversationsCompanion.insert(
              id: 'c',
              title: 'c',
              displayName: 'c',
              createdAt: 0,
              updatedAt: 0,
            ),
          );
      const code = 'text(await tools.read({path:"a"}));';
      final calls = [
        {
          'id': 'code/1',
          'name': 'read',
          'args': '{"path":"a"}',
          'status': 'ok',
          'durationMs': 2,
        },
      ];
      final built = container
          .read(chatSendServiceProvider)
          .buildAssistantMessages(
            apiResult: ApiCallResult(
              replyText: 'done',
              processedText: 'done',
              pluginEvents: const [],
              toolResults: const [],
              toolCalls: const [
                ToolCall(
                  id: 'code',
                  name: 'codemode',
                  arguments: {'code': code},
                ),
              ],
              rawToolResults: [
                ToolResult(
                  toolCallId: 'code',
                  name: 'codemode',
                  result: 'Script completed\nOutput:\na',
                  structured: {'codemodeCalls': calls},
                ),
              ],
            ),
            settings: mapUiModelsToAppSettings({}),
          );
      final history = container.read(chatHistoryStoreProvider);
      await history.appendAssistantRawMessage(
        conversationId: 'c',
        userMessageId: '',
        rawMessage: built.rawMessage!,
        projectedMessages: built.messages,
        lastMessagePreview: 'done',
      );
      final raw = (await history.loadAllRawMessages('c')).single;
      final reprojected = const ChatFrontendMessageProjectionService()
          .projectMessage(raw);
      final block = reprojected
          .expand((m) => m.blocks ?? <MessageBlock>[])
          .whereType<ToolBlock>()
          .single;
      expect(block.arguments, {'code': code});
      expect(block.result?['content'], startsWith('Script completed'));
      expect(block.result?['codemodeCalls'], calls);
    },
  );
  for (final status in ApiRunStatus.values) {
    test(
      '${status.name} survives DB reload and appears only on last projected assistant',
      () async {
        final database = db.AppDatabase.forTesting(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(database)],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });
        await database
            .into(database.conversations)
            .insert(
              db.ConversationsCompanion.insert(
                id: 'c',
                title: 'c',
                displayName: 'c',
                createdAt: 0,
                updatedAt: 0,
              ),
            );
        final service = container.read(chatSendServiceProvider);
        final built = service.buildAssistantMessages(
          apiResult: ApiCallResult(
            status: status,
            stopReason: status == ApiRunStatus.truncated ? 'length' : null,
            replyText: 'partial',
            processedText: 'partial',
            pluginEvents: const [],
            toolResults: const [],
          ),
          settings: mapUiModelsToAppSettings({}),
        );
        final store = container.read(chatHistoryStoreProvider);
        await store.appendAssistantRawMessage(
          conversationId: 'c',
          userMessageId: '',
          rawMessage: built.rawMessage!,
          projectedMessages: built.messages,
          lastMessagePreview: 'partial',
        );
        final reloaded = (await store.loadAllRawMessages('c')).single;
        final expected = status == ApiRunStatus.completed ? null : status.name;
        expect(reloaded.rawPayload?['runStatus'], expected);
        final projected = const ChatFrontendMessageProjectionService()
            .projectMessage(reloaded);
        expect(projected.last.rawPayload?['runStatus'], expected);
        expect(built.messages.last.rawPayload?['runStatus'], expected);
        if (status == ApiRunStatus.truncated)
          expect(reloaded.rawPayload?['stopReason'], 'length');
      },
    );
  }
}
