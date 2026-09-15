import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_ports.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_send_use_case.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_turn_command.dart';
import 'package:aicove_flutter/src/features/chat/application/standard_chat_agent.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

class _FakeChatSendPort implements ChatSendPort {
  _FakeChatSendPort(this.settings);

  final AppSettings settings;

  int prepareHistoryFromStoreCalls = 0;
  Conversation? lastPrepareHistoryConversation;
  Message? lastPrepareHistoryUserMessage;
  List<Message> historyFromStore = const <Message>[];

  final List<String?> prepareApiConfigOverrideModels = <String?>[];
  final List<List<Message>> prepareApiConfigHistories = <List<Message>>[];
  final List<String> callOrder = <String>[];

  ApiCallResult executeApiCallResult = const ApiCallResult(
    replyText: 'reply',
    processedText: 'processed',
    pluginEvents: <PluginEvent>[],
    toolResults: <Map<String, dynamic>>[],
  );

  AssistantMessageBuildResult buildAssistantMessagesResult =
      const AssistantMessageBuildResult(
    messages: <Message>[],
    lastMessageText: 'assistant',
  );

  @override
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) {
    throw UnimplementedError();
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return buildAssistantMessagesResult;
  }

  @override
  List<String> buildImageSendModelRefs(AppSettings settings) {
    throw UnimplementedError();
  }

  @override
  Message createUserMessage({
    required String? text,
    required String? imagePath,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Message> createUserFileMessage({
    required String filePath,
    String? text,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    callOrder.add('executeApiCall');
    return executeApiCallResult;
  }

  @override
  Future<List<Message>> loadConversationMessagesFromStore({
    required Conversation conv,
    Message? ensureTailMessage,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> markUserMessageFailed({
    required String convId,
    required String userMsgId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    trace,
    String? overrideModel,
    String? conversationId,
    traceContext,
  }) async {
    prepareApiConfigOverrideModels.add(overrideModel);
    prepareApiConfigHistories.add(List<Message>.from(history));
    return ApiConfig(
      settings: settings,
      modelFullId: overrideModel ?? settings.defaultModelName,
      providerApiBase: 'https://example.com',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: <Map<String, dynamic>>[
        for (final message in history) <String, dynamic>{'id': message.id}
      ],
    );
  }

  @override
  Future<List<Message>> prepareHistoryFromStore({
    required Conversation conv,
    required Message userMsg,
  }) async {
    prepareHistoryFromStoreCalls += 1;
    lastPrepareHistoryConversation = conv;
    lastPrepareHistoryUserMessage = userMsg;
    return historyFromStore;
  }
}

AppSettings _fakeSettings({
  String defaultModelName = 'openai:gpt-4o-mini',
  List<String>? defaultChatModels,
}) {
  return AppSettings(
    ttsEnabled: true,
    defaultModelName: defaultModelName,
    defaultPersonaPrompt: '',
    modelList: <String>[defaultModelName],
    allKnownModels: <String>[defaultModelName],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: const <CustomModel>[],
    providers: const <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
      ),
    ],
    modelProviderMap: <String, String>{
      defaultModelName: 'openai',
      'gpt-4o-mini': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: const MessageFormatConfig(),
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
    defaultChatModels: defaultChatModels ?? <String>[defaultModelName],
  );
}

Conversation _conversation({String id = 'conv_1'}) {
  final now = DateTime(2026, 3, 22, 12);
  return Conversation(
    id: id,
    title: 'Chat',
    displayName: 'Chat',
    createdAt: now,
    updatedAt: now,
  );
}

Message _message(String id, String text) {
  return Message(
    id: id,
    role: 'user',
    content: text,
    createdAt: DateTime(2026, 3, 22, 12),
  );
}

void main() {
  group('ChatSendUseCase', () {
    test('prepareTurn 提供 modelsToTry 时优先使用它而不是 resolveModelsToTry', () async {
      final settings = _fakeSettings(
        defaultChatModels: <String>['fallback-a', 'fallback-b'],
      );
      final port = _FakeChatSendPort(settings);
      final useCase = ChatSendUseCase(port);
      final conversation = _conversation();
      final userMessage = _message('user_1', 'hello');
      final history = <Message>[_message('history_1', 'history')];
      var resolveCalled = false;
      List<String>? executedModels;

      final result = await useCase.executeNonStreamingTurn(
        conversation: conversation,
        userMessage: userMessage,
        sessionId: conversation.id,
        apiText: 'hello',
        traceContext: null,
        loadSettings: () async => settings,
        prepareTurn: (_) async => ChatPreparedTurn(
          requestConversation: conversation,
          history: history,
          sessionId: conversation.id,
          modelsToTry: const <String>[
            ' prepared-a ',
            'prepared-b',
            'prepared-a'
          ],
        ),
        resolveModelsToTry: (_) {
          resolveCalled = true;
          return <String>['fallback-x'];
        },
        executeWithFailover: ({
          required modelsToTry,
          required buildConfig,
          required execute,
          required settings,
        }) async {
          executedModels = modelsToTry;
          final config = await buildConfig(modelsToTry.first);
          final apiResult = await execute(config);
          return (apiResult, settings);
        },
        onToolExecuting: (_) {},
        deliverResult: ({
          required settings,
          required apiResult,
          required buildResult,
        }) async {},
        isCurrent: () => true,
      );

      expect(result, isNotNull);
      expect(resolveCalled, isFalse);
      expect(executedModels, <String>['prepared-a', 'prepared-b']);
      expect(port.prepareHistoryFromStoreCalls, 0);
      expect(port.prepareApiConfigOverrideModels, <String?>['prepared-a']);
    });

    test('未提供 prepareTurn 时会从 port 加载 history', () async {
      final settings = _fakeSettings();
      final port = _FakeChatSendPort(settings)
        ..historyFromStore = <Message>[
          _message('history_1', 'persisted'),
        ];
      final useCase = ChatSendUseCase(port);
      final conversation = _conversation();
      final userMessage = _message('user_1', 'hello');

      await useCase.executeNonStreamingTurn(
        conversation: conversation,
        userMessage: userMessage,
        sessionId: conversation.id,
        apiText: 'hello',
        traceContext: null,
        loadSettings: () async => settings,
        resolveModelsToTry: (_) => <String>['model-a'],
        executeWithFailover: ({
          required modelsToTry,
          required buildConfig,
          required execute,
          required settings,
        }) async {
          final config = await buildConfig(modelsToTry.first);
          final apiResult = await execute(config);
          return (apiResult, settings);
        },
        onToolExecuting: (_) {},
        deliverResult: ({
          required settings,
          required apiResult,
          required buildResult,
        }) async {},
        isCurrent: () => true,
      );

      expect(port.prepareHistoryFromStoreCalls, 1);
      expect(port.lastPrepareHistoryConversation, same(conversation));
      expect(port.lastPrepareHistoryUserMessage, same(userMessage));
      expect(port.prepareApiConfigHistories.single.map((m) => m.id).toList(),
          <String>['history_1']);
    });

    test('streaming 路径会先调用 prepareStreaming 再执行 API', () async {
      final settings = _fakeSettings();
      final port = _FakeChatSendPort(settings)
        ..historyFromStore = <Message>[
          _message('history_1', 'persisted'),
        ];
      final useCase = ChatSendUseCase(port);
      final conversation = _conversation();
      final userMessage = _message('user_1', 'hello');

      await useCase.executeStreamingTurn(
        conversation: conversation,
        userMessage: userMessage,
        sessionId: conversation.id,
        apiText: 'hello',
        traceContext: null,
        loadSettings: () async => settings,
        resolveModelsToTry: (_) => <String>['model-a'],
        executeWithFailover: ({
          required modelsToTry,
          required buildConfig,
          required execute,
          required settings,
        }) async {
          final config = await buildConfig(modelsToTry.first);
          final apiResult = await execute(config);
          return (apiResult, settings);
        },
        prepareStreaming: (_) async {
          port.callOrder.add('prepareStreaming');
        },
        onToolExecuting: (_) {},
        deliverResult: ({
          required settings,
          required apiResult,
          required buildResult,
        }) async {},
        isCurrent: () => true,
      );

      expect(port.callOrder, <String>['prepareStreaming', 'executeApiCall']);
    });

    test('deliverResult 使用 buildAssistantMessages 产出的结果', () async {
      final settings = _fakeSettings();
      final buildResult = AssistantMessageBuildResult(
        messages: <Message>[
          Message(
            id: 'assistant_1',
            role: 'assistant',
            content: 'done',
            createdAt: DateTime(2026, 3, 22, 12, 1),
            status: 'sent',
          ),
        ],
        lastMessageText: 'done',
      );
      final port = _FakeChatSendPort(settings)
        ..historyFromStore = <Message>[
          _message('history_1', 'persisted'),
        ]
        ..buildAssistantMessagesResult = buildResult;
      final useCase = ChatSendUseCase(port);
      final conversation = _conversation();
      final userMessage = _message('user_1', 'hello');

      AssistantMessageBuildResult? deliveredBuildResult;
      ApiCallResult? deliveredApiResult;

      final result = await useCase.executeNonStreamingTurn(
        conversation: conversation,
        userMessage: userMessage,
        sessionId: conversation.id,
        apiText: 'hello',
        traceContext: null,
        loadSettings: () async => settings,
        resolveModelsToTry: (_) => <String>['model-a'],
        executeWithFailover: ({
          required modelsToTry,
          required buildConfig,
          required execute,
          required settings,
        }) async {
          final config = await buildConfig(modelsToTry.first);
          final apiResult = await execute(config);
          return (apiResult, settings);
        },
        onToolExecuting: (_) {},
        deliverResult: ({
          required settings,
          required apiResult,
          required buildResult,
        }) async {
          deliveredBuildResult = buildResult;
          deliveredApiResult = apiResult;
        },
        isCurrent: () => true,
      );

      expect(result, isNotNull);
      expect(identical(deliveredBuildResult, buildResult), isTrue);
      expect(identical(result!.buildResult, buildResult), isTrue);
      expect(deliveredApiResult, same(port.executeApiCallResult));
      expect(result.settings, same(settings));
    });

    test('StandardChatAgent 通过 AgentScheduler 委托现有 ChatSendUseCase', () async {
      final settings = _fakeSettings();
      final port = _FakeChatSendPort(settings)
        ..historyFromStore = <Message>[
          _message('history_1', 'persisted'),
        ];
      final useCase = ChatSendUseCase(port);
      final runtime = StandardChatAgentRuntime(useCase);
      final scheduler = DirectAgentScheduler<StandardChatAgentRunRequest,
          StandardChatAgentRunResult>(runtime);
      final agent = StandardChatAgent(scheduler);
      final conversation = _conversation();
      final userMessage = _message('user_1', 'hello');
      final command = ChatTurnCommand.nonStreaming(
        conversation: conversation,
        userMessage: userMessage,
        sessionId: conversation.id,
        apiText: 'hello',
        traceContext: null,
      );

      final result = await agent.executeTurn(
        command: command,
        options: ChatTurnExecutionOptions(
          loadSettings: () async => settings,
          resolveModelsToTry: (_) => <String>['model-a'],
          executeWithFailover: ({
            required modelsToTry,
            required buildConfig,
            required execute,
            required settings,
          }) async {
            final config = await buildConfig(modelsToTry.first);
            final apiResult = await execute(config);
            return (apiResult, settings);
          },
          onToolExecuting: (_) {},
          deliverResult: ({
            required settings,
            required apiResult,
            required buildResult,
          }) async {},
          isCurrent: () => true,
        ),
      );

      expect(result, isNotNull);
      expect(port.prepareHistoryFromStoreCalls, 1);
      expect(port.prepareApiConfigOverrideModels, <String?>['model-a']);

      final request = StandardChatAgentRunRequest(
        command: command,
        options: ChatTurnExecutionOptions(
          loadSettings: () async => settings,
          resolveModelsToTry: (_) => <String>['model-a'],
          executeWithFailover: ({
            required modelsToTry,
            required buildConfig,
            required execute,
            required settings,
          }) async {
            throw UnimplementedError();
          },
          onToolExecuting: (_) {},
          deliverResult: ({
            required settings,
            required apiResult,
            required buildResult,
          }) async {},
          isCurrent: () => true,
        ),
      );
      expect(
        request.agentId,
        StandardChatAgentIds.agentIdForContact(conversation.id),
      );
      expect(request.contactId, conversation.id);
      expect(
        request.contextOverrides['contextRecipeId'],
        StandardChatAgentIds.contextRecipeIdForContact(conversation.id),
      );
      expect(request.metadata['contactDisplayName'], conversation.displayName);
      expect(request.metadata['contextAssemblyScope'], 'full_chat');
      expect(
        request.metadata['assemblyPermissions'],
        contains(AgentContextAssemblyPermission.sillyTavernPreset.id),
      );
      expect(request.agentKind, AgentKind.chat);
      expect(request.deliveryChannel,
          AgentDeliveryChannelKind.foregroundConversation);
      expect(request.traceKind, AgentTraceKind.foreground);
      expect(request.triggerKind, AgentTriggerKind.userMessage);

      final definition =
          StandardChatAgentIds.definitionForConversation(conversation);
      expect(definition.id, request.agentId);
      expect(definition.contextRecipeId,
          StandardChatAgentIds.contextRecipeIdForContact(conversation.id));
      expect(definition.agentKind, AgentKind.chat);
      expect(
        definition.contextProfile
            .canAssemble(AgentContextAssemblyPermission.sillyTavernPreset),
        isTrue,
      );
      expect(
        definition.contextProfile
            .canAssemble(AgentContextAssemblyPermission.lorebook),
        isTrue,
      );
      expect(
        ContextProfile.backgroundAnalyzer
            .canAssemble(AgentContextAssemblyPermission.sillyTavernPreset),
        isFalse,
      );
    });

    test('bound preset id becomes the ChatAgent context recipe id', () {
      final now = DateTime(2026, 8, 27);
      final conversation = Conversation(
        id: 'conv_bound_recipe',
        title: 'Chat',
        displayName: 'Chat',
        recipeId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
        createdAt: now,
        updatedAt: now,
      );

      expect(
        StandardChatAgentIds.contextRecipeIdForConversation(conversation),
        conversation.recipeId,
      );
      expect(
        StandardChatAgentIds.definitionForConversation(conversation)
            .contextRecipeId,
        conversation.recipeId,
      );
    });
  });
}
