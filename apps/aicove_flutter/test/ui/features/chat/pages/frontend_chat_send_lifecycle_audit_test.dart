import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_send_support.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

class _RecordingChatActions extends ChatActions {
  _RecordingChatActions(this.auditRef) : super(auditRef);
  final Ref auditRef;
  final List<String?> sentOwners = [];
  final List<String> sentTexts = [];
  @override
  Future<void> sendWithImage(String path, {String? text}) async {
    sentOwners.add(auditRef.read(activeConversationProvider)?.id);
    sentTexts.add(text ?? path);
  }

  @override
  Future<void> send(String text) async {
    sentOwners.add(auditRef.read(activeConversationProvider)?.id);
    sentTexts.add(text);
  }
}

class _AlwaysAllowChatPageSendSupport extends ChatPageSendSupport {
  _AlwaysAllowChatPageSendSupport(super.ref, this.pending);
  final Completer<ChatPageVisionCompatibilityDecision> pending;
  int calls = 0;

  @override
  Future<ChatPageVisionCompatibilityDecision> resolveVisionCompatibility({
    required Conversation conversation,
    bool currentMessageHasImage = false,
  }) async {
    calls++;
    return pending.future;
  }
}

AppSettings _buildTestSettings() {
  const defaultModelRef = 'openai:gpt-4o-mini';
  return const AppSettings(
    ttsEnabled: true,
    defaultModelName: defaultModelRef,
    defaultPersonaPrompt: '',
    modelList: <String>[defaultModelRef],
    allKnownModels: <String>[defaultModelRef],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{},
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
      ),
    ],
    modelProviderMap: <String, String>{
      defaultModelRef: 'openai',
      'gpt-4o-mini': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: true,
    messageFormatConfig: MessageFormatConfig(
      enableChunking: true,
      chunkPunctuations: <String>['。'],
      minSegmentLength: 1,
    ),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: <String>[defaultModelRef],
    streamSegmentDelaySeconds: 0,
  );
}

Widget _buildHost({
  required ProviderContainer container,
  required Conversation conversation,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData(
        extensions: <ThemeExtension<dynamic>>[MoeColors.light()],
      ),
      home: ChatPage(
        conversationId: conversation.id,
        initialConversation: conversation,
      ),
    ),
  );
}

void main() {
  for (final image in [false, true]) {
    testWidgets(
      'chat send compatibility result after page disposal is ignored image=$image',
      (tester) async {
        final now = DateTime(2026, 9, 6);
        final conversation = Conversation(
          id: 'audit-send',
          title: 'Synthetic',
          displayName: 'Synthetic',
          createdAt: now,
          updatedAt: now,
        );
        final database = db.AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final pending = Completer<ChatPageVisionCompatibilityDecision>();
        late _AlwaysAllowChatPageSendSupport support;
        late _RecordingChatActions actions;
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            appSettingsProvider.overrideWith(
              () => _FakeAppSettingsNotifier(_buildTestSettings()),
            ),
            chatActionsProvider.overrideWith(
              (ref) => actions = _RecordingChatActions(ref),
            ),
            chatPageSendSupportProvider.overrideWith(
              (ref) => support = _AlwaysAllowChatPageSendSupport(ref, pending),
            ),
            activeConversationProvider.overrideWith((ref) => conversation),
            resolvedConversationByIdProvider(
              conversation.id,
            ).overrideWith((ref) => conversation),
            conversationMessagesProvider(
              conversation.id,
            ).overrideWith((ref) => const AsyncValue.data(<Message>[])),
            conversationHasMoreProvider(
              conversation.id,
            ).overrideWith((ref) => false),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _buildHost(container: container, conversation: conversation),
        );
        await tester.pump();
        final composer = tester.widget<Composer>(find.byType(Composer));
        Object? failure;
        final send =
            Future<void>.sync(
              () => image
                  ? composer.onImageSelected!(
                      '/tmp/synthetic.png',
                      text: 'Synthetic message',
                    )
                  : composer.onSend('Synthetic message'),
            ).catchError((Object error) {
              failure = error;
            });
        await tester.pump();
        expect(support.calls, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const MaterialApp(home: Scaffold()));
        pending.complete(const ChatPageVisionCompatibilityDecision.allow());
        await send;
        await tester.pump();
        expect(
          failure,
          isNull,
          reason:
              'late compatibility approval must not access disposed chat UI',
        );
        expect(actions.sentTexts, isEmpty);
      },
    );
    testWidgets(
      'chat send remains bound to originating conversation during compatibility check image=$image',
      (tester) async {
        final now = DateTime(2026, 9, 6);
        final conversation = Conversation(
          id: 'audit-send',
          title: 'Synthetic',
          displayName: 'Synthetic',
          createdAt: now,
          updatedAt: now,
        );
        final other = conversation.copyWith(
          id: 'audit-other',
          displayName: 'Other',
        );
        final current = StateProvider<Conversation>((ref) => conversation);
        final database = db.AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final pending = Completer<ChatPageVisionCompatibilityDecision>();
        late _AlwaysAllowChatPageSendSupport support;
        late _RecordingChatActions actions;
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            appSettingsProvider.overrideWith(
              () => _FakeAppSettingsNotifier(_buildTestSettings()),
            ),
            chatActionsProvider.overrideWith(
              (ref) => actions = _RecordingChatActions(ref),
            ),
            chatPageSendSupportProvider.overrideWith(
              (ref) => support = _AlwaysAllowChatPageSendSupport(ref, pending),
            ),
            activeConversationProvider.overrideWith(
              (ref) => ref.watch(current),
            ),
            resolvedConversationByIdProvider(
              conversation.id,
            ).overrideWith((ref) => conversation),
            conversationMessagesProvider(
              conversation.id,
            ).overrideWith((ref) => const AsyncValue.data(<Message>[])),
            conversationHasMoreProvider(
              conversation.id,
            ).overrideWith((ref) => false),
            resolvedConversationByIdProvider(
              other.id,
            ).overrideWith((ref) => other),
            conversationMessagesProvider(
              other.id,
            ).overrideWith((ref) => const AsyncValue.data(<Message>[])),
            conversationHasMoreProvider(other.id).overrideWith((ref) => false),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _buildHost(container: container, conversation: conversation),
        );
        await tester.pump();
        final composer = tester.widget<Composer>(find.byType(Composer));
        Object? failure;
        final send =
            Future<void>.sync(
              () => image
                  ? composer.onImageSelected!(
                      '/tmp/synthetic.png',
                      text: 'Synthetic message',
                    )
                  : composer.onSend('Synthetic message'),
            ).catchError((Object error) {
              failure = error;
            });
        await tester.pump();
        expect(support.calls, 1);
        expect(tester.takeException(), isNull);
        container.read(current.notifier).state = other;
        await tester.pumpWidget(
          _buildHost(container: container, conversation: other),
        );
        await tester.pump();
        expect(container.read(activeConversationProvider)?.id, other.id);
        pending.complete(const ChatPageVisionCompatibilityDecision.allow());
        await send;
        await tester.pump();
        expect(
          failure,
          isNull,
          reason: 'switching conversation must not throw',
        );
        expect(
          actions.sentOwners,
          isNot(contains(other.id)),
          reason: 'an operation started for A must not dispatch to B',
        );
      },
    );
  }
}
