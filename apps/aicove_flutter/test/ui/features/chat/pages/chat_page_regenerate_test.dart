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
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

class _RecordingChatActions extends ChatActions {
  _RecordingChatActions(super.ref);

  final List<String> regenerateIds = <String>[];
  int peekTextRegenerateCalls = 0;
  int prepareTextRegenerateCalls = 0;
  final List<String> sentTexts = <String>[];

  Future<String?> peekTextRegenerate(String aiMessageId) async {
    peekTextRegenerateCalls += 1;
    return '这句原话会被错误地重发';
  }

  Future<String?> prepareTextRegenerate(String aiMessageId) async {
    prepareTextRegenerateCalls += 1;
    return '这句原话会被错误地重发';
  }

  Future<void> regenerate(String aiMessageId) async {
    regenerateIds.add(aiMessageId);
  }

  @override
  Future<void> send(String text) async {
    sentTexts.add(text);
  }
}

class _AlwaysAllowChatPageSendSupport extends ChatPageSendSupport {
  _AlwaysAllowChatPageSendSupport(super.ref);

  @override
  Future<ChatPageVisionCompatibilityDecision> resolveVisionCompatibility({
    required Conversation conversation,
    bool currentMessageHasImage = false,
  }) async {
    return const ChatPageVisionCompatibilityDecision.allow();
  }
}

AppSettings _buildTestSettings() {
  const defaultModelRef = 'openai:gpt-4o-mini';
  return const AppSettings(
    ttsEnabled: true,
    defaultModelName: defaultModelRef,
    defaultPersonaPrompt: '',
    modelList: const <String>[defaultModelRef],
    allKnownModels: const <String>[defaultModelRef],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: const <CustomModel>[],
    providers: const <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
      ),
    ],
    modelProviderMap: const <String, String>{
      defaultModelRef: 'openai',
      'gpt-4o-mini': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: true,
    messageFormatConfig: const MessageFormatConfig(
      enableChunking: true,
      chunkPunctuations: <String>['。'],
      minSegmentLength: 1,
    ),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: const <String>[defaultModelRef],
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
        extensions: <ThemeExtension<dynamic>>[
          MoeColors.light(),
        ],
      ),
      home: ChatPage(
        conversationId: conversation.id,
        initialConversation: conversation,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('纯文本重新生成应直接走 regenerate，而不是 send 重放链', (tester) async {
    final now = DateTime(2026, 3, 27, 21, 0);
    final userMessage = Message(
      id: 'msg_page_regen_user',
      role: 'user',
      content: '请重新组织一下这句话',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final assistantMessage = Message(
      id: 'msg_page_regen_ai',
      role: 'assistant',
      content: '旧回复',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conversation = Conversation(
      id: 'conv_page_regen',
      title: 'PageRegen',
      displayName: 'PageRegen',
      createdAt: now,
      updatedAt: now,
      messages: [userMessage, assistantMessage],
      lastMessage: assistantMessage.displayText,
      lastMessageTime: assistantMessage.createdAt,
    );

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    late _RecordingChatActions actions;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(_buildTestSettings()),
        ),
        chatActionsProvider.overrideWith((ref) {
          actions = _RecordingChatActions(ref);
          return actions;
        }),
        chatPageSendSupportProvider.overrideWith(
          (ref) => _AlwaysAllowChatPageSendSupport(ref),
        ),
        activeConversationProvider.overrideWith((ref) => conversation),
        resolvedConversationByIdProvider(conversation.id)
            .overrideWith((ref) => conversation),
        conversationMessagesProvider(conversation.id).overrideWith(
          (ref) => AsyncValue.data(<Message>[userMessage, assistantMessage]),
        ),
        conversationHasMoreProvider(conversation.id)
            .overrideWith((ref) => false),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _buildHost(
        container: container,
        conversation: conversation,
      ),
    );
    await tester.pump();

    final chatMessageList =
        tester.widget<ChatMessageList>(find.byType(ChatMessageList));
    expect(chatMessageList.onRegenerateMessage, isNotNull);

    await actions.regenerate(assistantMessage.id);
    await tester.pump();

    expect(actions.regenerateIds, [assistantMessage.id]);
    expect(actions.peekTextRegenerateCalls, 0);
    expect(actions.prepareTextRegenerateCalls, 0);
    expect(actions.sentTexts, isEmpty);
  });

  testWidgets('同会话消息 provider 短暂回到 loading 时，聊天页仍应保留用户消息并移除发送中的 assistant 占位',
      (tester) async {
    final now = DateTime(2026, 4, 4, 10, 0, 0);
    final userMessage = Message(
      id: 'msg_interrupt_gap_user',
      role: 'user',
      content: '这条用户消息在中断后不该消失',
      createdAt: now,
      status: 'sending',
    );
    final assistantPlaceholder = Message(
      id: 'msg_interrupt_gap_ai',
      role: 'assistant',
      content: '生成中...',
      createdAt: now.add(const Duration(milliseconds: 1)),
      status: 'sending',
    );
    final conversation = Conversation(
      id: 'conv_interrupt_gap',
      title: 'InterruptGap',
      displayName: 'InterruptGap',
      createdAt: now,
      updatedAt: now,
      messages: [userMessage, assistantPlaceholder],
      lastMessage: assistantPlaceholder.displayText,
      lastMessageTime: assistantPlaceholder.createdAt,
    );
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final messagesStateProvider = StateProvider<AsyncValue<List<Message>>>(
      (ref) => AsyncValue.data(<Message>[userMessage, assistantPlaceholder]),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(_buildTestSettings()),
        ),
        activeConversationProvider.overrideWith((ref) => conversation),
        resolvedConversationByIdProvider(conversation.id)
            .overrideWith((ref) => conversation),
        conversationMessagesProvider(conversation.id).overrideWith(
          (ref) => ref.watch(messagesStateProvider),
        ),
        conversationHasMoreProvider(conversation.id)
            .overrideWith((ref) => false),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _buildHost(
        container: container,
        conversation: conversation,
      ),
    );
    await tester.pump();

    expect(find.text('这条用户消息在中断后不该消失'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('message_bubble_msg_interrupt_gap_ai')),
      findsOneWidget,
    );

    container.read(messagesStateProvider.notifier).state =
        const AsyncValue<List<Message>>.loading();
    await tester.pump();

    expect(
      find.text('这条用户消息在中断后不该消失'),
      findsOneWidget,
      reason: '同会话时间线短暂回到 loading 时，上一帧的用户消息仍应继续显示。',
    );
    expect(
      find.byKey(const ValueKey<String>('message_bubble_msg_interrupt_gap_ai')),
      findsNothing,
      reason: '停止生成后的 loading 空窗里，不应继续保留发送中的 assistant 占位。',
    );

    container.read(messagesStateProvider.notifier).state =
        AsyncValue.data(<Message>[userMessage]);
    await tester.pump();

    expect(find.text('这条用户消息在中断后不该消失'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('message_bubble_msg_interrupt_gap_ai')),
      findsNothing,
    );
  });
}
