import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aicove_flutter/src/core/database/database.dart'
    hide Conversation, Message;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/services/attachment_picker_service.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_ports.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_player_manager.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';

// Existing delivery tests inject their fake speech service through the new
// owner-bound port; their timing/persistence assertions remain unchanged.
class _TestVoiceApplication implements VoicePresetApplicationPort {
  _TestVoiceApplication(this.service);
  final TtsService service;
  @override
  Future<VoiceRequest> forOwnerId(String ownerId) async =>
      VoiceRequest(ownerId: ownerId, service: service);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(this._seed);

  final List<Conversation> _seed;

  @override
  Future<List<Conversation>> build() async => _seed;

  @override
  Future<void> setAll(
    List<Conversation> list, {
    bool persist = true,
  }) async {
    state = AsyncValue.data(list);
  }
}

class _SpyModelFailoverPromptController extends ModelFailoverPromptController {
  int requestCalls = 0;

  @override
  Future<ModelFailoverDecision> request({
    required String conversationId,
    required String failedModelName,
    required String nextModelName,
    required String errorMessage,
  }) async {
    requestCalls += 1;
    return ModelFailoverDecision.tryNext;
  }
}

class _BlockingModelFailoverPromptController
    extends ModelFailoverPromptController {
  int requestCalls = 0;

  @override
  Future<ModelFailoverDecision> request({
    required String conversationId,
    required String failedModelName,
    required String nextModelName,
    required String errorMessage,
  }) {
    requestCalls += 1;
    return super.request(
      conversationId: conversationId,
      failedModelName: failedModelName,
      nextModelName: nextModelName,
      errorMessage: errorMessage,
    );
  }
}

const MethodChannel _pathProviderChannel =
    MethodChannel('plugins.flutter.io/path_provider');
const MethodChannel _sharedPreferencesChannel =
    MethodChannel('plugins.flutter.io/shared_preferences');

void _installPlatformChannelMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_pathProviderChannel, (call) async {
    switch (call.method) {
      case 'getApplicationDocumentsDirectory':
      case 'getTemporaryDirectory':
      case 'getApplicationSupportDirectory':
      case 'getLibraryDirectory':
      case 'getExternalStorageDirectory':
        return Directory.systemTemp.path;
      case 'getExternalCacheDirectories':
      case 'getExternalStorageDirectories':
        return <String>[Directory.systemTemp.path];
    }
    return Directory.systemTemp.path;
  });
  messenger.setMockMethodCallHandler(_sharedPreferencesChannel, (call) async {
    switch (call.method) {
      case 'getAll':
        return <String, Object>{};
      case 'setBool':
      case 'setDouble':
      case 'setInt':
      case 'setString':
      case 'setStringList':
      case 'remove':
      case 'clear':
      case 'commit':
        return true;
    }
    return null;
  });
}

Future<void> _insertConversation(AppDatabase db, Conversation conv) async {
  await db.into(db.conversations).insert(
        ConversationsCompanion.insert(
          id: conv.id,
          title: conv.title,
          displayName: conv.displayName,
          personaPrompt: Value(conv.personaPrompt),
          createdAt: conv.createdAt.millisecondsSinceEpoch,
          updatedAt: conv.updatedAt.millisecondsSinceEpoch,
        ),
      );
}

Future<void> _insertMessage(AppDatabase db, String convId, Message msg) async {
  await db.into(db.messages).insert(
        MessagesCompanion.insert(
          id: msg.id,
          conversationId: convId,
          role: msg.role,
          content: msg.content,
          status: Value(msg.status ?? 'sent'),
          sourceMessageId: Value(msg.sourceMessageId),
          rawPayload:
              Value(msg.rawPayload != null ? jsonEncode(msg.rawPayload) : null),
          createdAt: msg.createdAt.millisecondsSinceEpoch,
        ),
      );
}

Future<void> _insertMessageWithBlocks(
  AppDatabase db,
  String convId,
  Message msg,
) async {
  await _insertMessage(db, convId, msg);
  final blocks = msg.blocks;
  if (blocks == null || blocks.isEmpty) {
    return;
  }

  for (var index = 0; index < blocks.length; index++) {
    await db.into(db.messageBlocks).insert(
          MessageBlockConverter.toCompanion(blocks[index], msg.id, index),
        );
  }
}

Future<void> _insertTextBlock(AppDatabase db, String messageId, String blockId,
    {int sortOrder = 0}) async {
  final block = TextBlock(
    id: blockId,
    messageId: messageId,
    content: 'block:$blockId',
  );
  await db.into(db.messageBlocks).insert(
        MessageBlocksCompanion.insert(
          id: block.id,
          messageId: block.messageId,
          type: 'mainText',
          data: jsonEncode(block.toJson()),
          sortOrder: Value(sortOrder),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
}

Future<List<Message>> _loadFrontendTimelineMessages(
  ProviderContainer container,
  String conversationId,
) {
  return container.read(chatHistoryStoreProvider).loadCachedTimelineMessages(
        conversationId,
      );
}

AudioBlock? _firstAudioBlock(Message message) {
  final audioBlocks =
      message.blocks?.whereType<AudioBlock>().toList() ?? const <AudioBlock>[];
  return audioBlocks.isEmpty ? null : audioBlocks.first;
}

AssistantMessageBuildResult _buildTestAssistantBuildResult({
  required List<Message> messages,
  required String lastMessageText,
  String? rawReplyText,
  Map<String, dynamic>? rawPayload,
}) {
  final rawMessageId =
      'raw_${messages.isNotEmpty ? messages.first.id : 'assistant'}';
  final normalizedMessages = <Message>[
    for (final message in messages)
      message.copyWith(sourceMessageId: rawMessageId),
  ];
  return AssistantMessageBuildResult(
    rawMessage: Message(
      id: rawMessageId,
      role: 'assistant',
      content: rawReplyText ?? lastMessageText,
      rawPayload: rawPayload,
      createdAt: normalizedMessages.isNotEmpty
          ? normalizedMessages.first.createdAt
          : DateTime.now(),
      status: 'sent',
    ),
    messages: normalizedMessages,
    lastMessageText: lastMessageText,
  );
}

AppSettings _buildTestSettings({double streamSegmentDelaySeconds = 0}) {
  const defaultModelRef = 'openai:gpt-4o-mini';
  return AppSettings(
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
    contextWindowTokens: 272000,
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
    streamSegmentDelaySeconds: streamSegmentDelaySeconds,
  );
}

bool _isGeneratingPlaceholderMessage(Message message) {
  return message.role == 'assistant' &&
      message.status == 'sending' &&
      (message.blocks?.whereType<TextBlock>().any(
                (block) =>
                    block.status == BlockStatus.streaming &&
                    block.content.trim() == '生成中...',
              ) ??
          false);
}

List<Message> _collectGeneratingPlaceholderMessages(
    Iterable<Message> messages) {
  return messages
      .where(_isGeneratingPlaceholderMessage)
      .toList(growable: false);
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

class _MemoryChatHistoryPort implements ChatHistoryPort {
  _MemoryChatHistoryPort(List<Message> messages)
      : _messages = List<Message>.from(messages);

  final List<Message> _messages;

  @override
  Future<List<Message>> loadRawMessages(String conversationId) async {
    return List<Message>.from(_messages);
  }

  @override
  Future<void> markMessageStatus({
    required String conversationId,
    required String messageId,
    required String status,
  }) async {
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    _messages[index] = _messages[index].copyWith(status: status);
  }

  @override
  Future<void> appendAssistantRawMessage({
    required String conversationId,
    required String userMessageId,
    required Message rawMessage,
    required List<Message> projectedMessages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
  }) async {}

  @override
  Future<void> softDeleteMessages(
    String conversationId,
    List<String> messageIds, {
    bool clearContextStartIfDeleted = false,
  }) async {
    _messages.removeWhere((message) => messageIds.contains(message.id));
  }

  @override
  Future<void> truncateFromMessage({
    required String conversationId,
    required String fromMessageId,
  }) async {
    final index =
        _messages.indexWhere((message) => message.id == fromMessageId);
    if (index < 0) return;
    _messages.removeRange(index, _messages.length);
  }

  @override
  Future<void> truncateAfterMessage({
    required String conversationId,
    required String anchorMessageId,
  }) async {
    final index =
        _messages.indexWhere((message) => message.id == anchorMessageId);
    if (index < 0 || index >= _messages.length - 1) return;
    _messages.removeRange(index + 1, _messages.length);
  }
}

class _EditMessageFastPathHistoryPort implements ChatHistoryPort {
  _EditMessageFastPathHistoryPort({
    this.onTruncateFromMessage,
  });

  int loadRawMessagesCallCount = 0;
  int truncateFromMessageCallCount = 0;
  Future<void> Function()? onTruncateFromMessage;

  @override
  Future<List<Message>> loadRawMessages(String conversationId) async {
    loadRawMessagesCallCount += 1;
    return const <Message>[];
  }

  @override
  Future<void> markMessageStatus({
    required String conversationId,
    required String messageId,
    required String status,
  }) async {}

  @override
  Future<void> appendAssistantRawMessage({
    required String conversationId,
    required String userMessageId,
    required Message rawMessage,
    required List<Message> projectedMessages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
  }) async {}

  @override
  Future<void> softDeleteMessages(
    String conversationId,
    List<String> messageIds, {
    bool clearContextStartIfDeleted = false,
  }) async {}

  @override
  Future<void> truncateFromMessage({
    required String conversationId,
    required String fromMessageId,
  }) async {
    truncateFromMessageCallCount += 1;
    await onTruncateFromMessage?.call();
  }

  @override
  Future<void> truncateAfterMessage({
    required String conversationId,
    required String anchorMessageId,
  }) async {}
}

abstract class _InMemoryHistorySendService extends ChatSendService {
  _InMemoryHistorySendService(super.ref);

  @override
  Future<List<Message>> loadConversationMessagesFromStore({
    required Conversation conv,
    Message? ensureTailMessage,
  }) async {
    final all = List<Message>.from(conv.messages);
    if (ensureTailMessage != null &&
        all.every((m) => m.id != ensureTailMessage.id)) {
      all.add(ensureTailMessage);
    }
    return all;
  }

  @override
  Future<List<Message>> prepareHistoryFromStore({
    required Conversation conv,
    required Message userMsg,
  }) async {
    return prepareHistory(
      conv: conv,
      userMsg: userMsg,
    );
  }
}

class _SpyStreamingSendService extends _InMemoryHistorySendService {
  _SpyStreamingSendService(super.ref, this._settings);

  final AppSettings _settings;

  int addUserMessageCalls = 0;
  bool lastEnableStreaming = false;
  bool sawDeltaCallback = false;
  bool sawResetCallback = false;
  bool sawToolObservedCallback = false;
  bool sawFallbackCallback = false;
  int executeCalls = 0;

  @override
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) async {
    addUserMessageCalls += 1;
    await super.addUserMessage(
      convId: convId,
      userMsg: userMsg,
      displayText: displayText,
    );
  }

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    executeCalls += 1;
    lastEnableStreaming = enableStreaming;
    sawDeltaCallback = onStreamTextDelta != null;
    sawResetCallback = onStreamTextReset != null;
    sawToolObservedCallback = onStreamToolCallObserved != null;
    sawFallbackCallback = onStreamingFallback != null;
    onStreamTextDelta?.call('先来一句。');
    return const ApiCallResult(
      replyText: '先来一句。',
      processedText: '先来一句。',
      pluginEvents: <PluginEvent>[],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _FallbackAfterDeltaSendService extends _InMemoryHistorySendService {
  _FallbackAfterDeltaSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('前置流式文本。');
    onStreamingFallback?.call();
    return const ApiCallResult(
      replyText: '前置流式文本。',
      processedText: '前置流式文本。',
      pluginEvents: <PluginEvent>[],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    final now = DateTime.now();
    const imageMsgId = 'assistant_image';
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: now,
          status: 'sent',
        ),
        Message.fromBlocks(
          id: imageMsgId,
          role: 'assistant',
          blocks: [
            ImageBlock(
              messageId: imageMsgId,
              localPath: r'C:\tmp\stream_image.png',
            ),
          ],
          createdAt: now.add(const Duration(milliseconds: 1)),
          status: 'sent',
        ),
      ],
      lastMessageText: '[图片]',
      rawReplyText: apiResult.replyText,
    );
  }
}

class _MultiDeltaStreamingSendService extends _InMemoryHistorySendService {
  _MultiDeltaStreamingSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('第一段。');
    await Future.delayed(const Duration(milliseconds: 45));
    onStreamTextDelta?.call('第二段。');
    await Future.delayed(const Duration(milliseconds: 45));
    onStreamTextDelta?.call('第三段。');
    await Future.delayed(const Duration(milliseconds: 45));
    return const ApiCallResult(
      replyText: '第一段。第二段。第三段。',
      processedText: '第一段。第二段。第三段。',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _SlowMultiDeltaStreamingSendService extends _InMemoryHistorySendService {
  _SlowMultiDeltaStreamingSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('第一段。');
    await Future<void>.delayed(const Duration(milliseconds: 220));
    onStreamTextDelta?.call('第二段。');
    await Future<void>.delayed(const Duration(milliseconds: 220));
    onStreamTextDelta?.call('第三段。');
    await Future<void>.delayed(const Duration(milliseconds: 260));
    return const ApiCallResult(
      replyText: '第一段。第二段。第三段。',
      processedText: '第一段。第二段。第三段。',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_result_slow',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _SingleDeltaSlowFinalizeSendService extends _InMemoryHistorySendService {
  _SingleDeltaSlowFinalizeSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('慢速流式片段');
    // 等待超过 flush 间隔，确保能观察到一次“流式中间态”快照。
    await Future<void>.delayed(const Duration(milliseconds: 260));
    return const ApiCallResult(
      replyText: '慢速流式片段',
      processedText: '慢速流式片段',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _DelayedFirstSentenceSendService extends _InMemoryHistorySendService {
  _DelayedFirstSentenceSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
    onStreamTextDelta?.call('第一句。');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return const ApiCallResult(
      replyText: '第一句。',
      processedText: '第一句。',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_delayed_first_sentence',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _ThrowAfterFirstSentenceSendService
    extends _DelayedFirstSentenceSendService {
  _ThrowAfterFirstSentenceSendService(super.ref, super._settings);

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
    onStreamTextDelta?.call('第一句。');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    throw Exception('模拟重新生成失败');
  }
}

class _DelayedMultiSentenceSendService extends _InMemoryHistorySendService {
  _DelayedMultiSentenceSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
    onStreamTextDelta?.call('第一句。');
    await Future<void>.delayed(const Duration(milliseconds: 220));
    onStreamTextDelta?.call('第二句。');
    await Future<void>.delayed(const Duration(milliseconds: 220));
    onStreamTextDelta?.call('第三句。');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return const ApiCallResult(
      replyText: '第一句。第二句。第三句。',
      processedText: '第一句。第二句。第三句。',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_delayed_multi_sentence',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _ChunkBoundarySentenceSendService extends _InMemoryHistorySendService {
  _ChunkBoundarySentenceSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('这是半句');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    onStreamTextDelta?.call('，还没结束');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    onStreamTextDelta?.call('。第二句');
    await Future<void>.delayed(const Duration(milliseconds: 260));
    onStreamTextDelta?.call('。');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return const ApiCallResult(
      replyText: '这是半句，还没结束。第二句。',
      processedText: '这是半句，还没结束。第二句。',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_chunk_boundary',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _NoBoundarySlowDeltaSendService extends _InMemoryHistorySendService {
  _NoBoundarySlowDeltaSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('这是一段没有结束标点');
    await Future<void>.delayed(const Duration(milliseconds: 240));
    onStreamTextDelta?.call('，继续补充但仍然没有结束');
    await Future<void>.delayed(const Duration(milliseconds: 240));
    onStreamTextDelta?.call('，再补充一点');
    await Future<void>.delayed(const Duration(milliseconds: 240));
    onStreamTextDelta?.call('。');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return const ApiCallResult(
      replyText: '这是一段没有结束标点，继续补充但仍然没有结束，再补充一点。',
      processedText: '这是一段没有结束标点，继续补充但仍然没有结束，再补充一点。',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_no_boundary_slow_delta',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _StreamingTtsSendService extends _InMemoryHistorySendService {
  _StreamingTtsSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('第一句。');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    onStreamTextDelta?.call('<tts>这是一段语音');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    onStreamTextDelta?.call('</tts>');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    onStreamTextDelta?.call('第二句。');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return ApiCallResult(
      replyText: '第一句。<tts>这是一段语音</tts>第二句。',
      processedText: '第一句。第二句。',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: <String, dynamic>{
            'text': '这是一段语音',
            'originalText': '这是一段语音',
          },
          id: 'evt_stream_tts',
        ),
      ],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_stream_tts_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _StreamingLeadingTtsSendService extends _InMemoryHistorySendService {
  _StreamingLeadingTtsSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('<tts>这是一段语音');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    onStreamTextDelta?.call('</tts>');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    onStreamTextDelta?.call('后续正文。');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return ApiCallResult(
      replyText: '<tts>这是一段语音</tts>后续正文。',
      processedText: '后续正文。',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: <String, dynamic>{
            'text': '这是一段语音',
            'originalText': '这是一段语音',
          },
          id: 'evt_stream_leading_tts',
        ),
      ],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_stream_leading_tts_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _SlowTailStreamingTtsSendService extends _InMemoryHistorySendService {
  _SlowTailStreamingTtsSendService(
    super.ref,
    this._settings, {
    this.ttsTagClosed,
    this.releaseTail,
    this.includeStickerAfterTts = false,
    this.longTailText = '',
  });

  final AppSettings _settings;
  final Completer<void>? ttsTagClosed;
  final Completer<void>? releaseTail;
  final bool includeStickerAfterTts;
  final String longTailText;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('第一句。');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    onStreamTextDelta?.call('<tts>流中语音');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    onStreamTextDelta?.call('</tts>');
    if (ttsTagClosed != null && !ttsTagClosed!.isCompleted) {
      ttsTagClosed!.complete();
    }
    if (longTailText.isNotEmpty) {
      onStreamTextDelta?.call(longTailText);
    }
    if (releaseTail != null) {
      await releaseTail!.future;
    } else {
      // 语音闭合后，留出足够时间让快速 TTS 返回
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // TTS 返回后，模型继续流式输出后续长尾文字
    onStreamTextDelta?.call('第二句很长很长的文本。');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    onStreamTextDelta?.call('第三句仍在流式生成的文本。');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return ApiCallResult(
      replyText: includeStickerAfterTts
          ? '第一句。<tts>流中语音</tts>[开心]$longTailText第二句很长很长的文本。第三句仍在流式生成的文本。'
          : '第一句。<tts>流中语音</tts>$longTailText第二句很长很长的文本。第三句仍在流式生成的文本。',
      processedText: '第一句。$longTailText第二句很长很长的文本。第三句仍在流式生成的文本。',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: <String, dynamic>{
            'text': '流中语音',
            'originalText': '流中语音',
          },
          id: 'evt_stream_fast_tts',
        ),
        if (includeStickerAfterTts)
          PluginEvent(
            pluginId: 'sticker',
            type: 'sticker_convert',
            data: const <String, dynamic>{
              'stickerId': 'happy',
              'tag': '开心',
              'assetPath': 'assets/stickers/happy.png',
            },
            id: 'evt_stream_sticker_after_tts',
          ),
      ],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_slow_tail_stream_tts_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _StreamingInlineImageSendService extends _InMemoryHistorySendService {
  _StreamingInlineImageSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('第一句。');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    onStreamTextDelta?.call('<image>1girl, cat ears, masterpiece');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    onStreamTextDelta?.call('</image>');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    onStreamTextDelta?.call('第二句。');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return ApiCallResult(
      replyText: '第一句。<image>1girl, cat ears, masterpiece</image>第二句。',
      processedText: '第一句。第二句。',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'image',
          type: 'image_generate',
          data: <String, dynamic>{
            'prompt': '1girl, cat ears, masterpiece',
          },
          id: 'evt_stream_inline_image',
        ),
      ],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_stream_inline_image_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _StreamingAttributeImageTagSendService
    extends _InMemoryHistorySendService {
  _StreamingAttributeImageTagSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('第一句。');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    onStreamTextDelta?.call('<image source="history">保留这段');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    onStreamTextDelta?.call('</image>');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    onStreamTextDelta?.call('第二句。');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return const ApiCallResult(
      replyText: '第一句。<image source="history">保留这段</image>第二句。',
      processedText: '第一句。<image source="history">保留这段</image>第二句。',
      pluginEvents: <PluginEvent>[],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_stream_attribute_image_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _StreamingMixedTtsImageTailSendService
    extends _InMemoryHistorySendService {
  _StreamingMixedTtsImageTailSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('文本a。');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    onStreamTextDelta?.call('<tts>语音段');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    onStreamTextDelta?.call('</tts>');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    onStreamTextDelta?.call('文本b');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    onStreamTextDelta?.call('<image>slow landscape</image>');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    onStreamTextDelta?.call('文本c。');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    return ApiCallResult(
      replyText: '文本a。<tts>语音段</tts>文本b<image>slow landscape</image>文本c。',
      processedText: '文本a。文本b文本c。',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: const <String, dynamic>{
            'text': '语音段',
            'originalText': '语音段',
          },
          id: 'evt_stream_mixed_tts',
        ),
        PluginEvent(
          pluginId: 'image',
          type: 'image_generate',
          data: const <String, dynamic>{
            'prompt': 'slow landscape',
          },
          id: 'evt_stream_mixed_image',
        ),
      ],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_stream_mixed_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
      rawPayload: ChatMessageProjectionCodec.buildRawAssistantPayload(
        apiResult: apiResult,
      ),
    );
  }
}

class _StreamingOnlyTtsSendService extends _InMemoryHistorySendService {
  _StreamingOnlyTtsSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('<tts>纯语音');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    onStreamTextDelta?.call('回复</tts>');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return ApiCallResult(
      replyText: '<tts>纯语音回复</tts>',
      processedText: '',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: const <String, dynamic>{
            'text': '纯语音回复',
            'originalText': '纯语音回复',
          },
          id: 'evt_stream_only_tts',
        ),
      ],
      toolResults: const <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: const <Message>[],
      lastMessageText: '',
      rawReplyText: apiResult.replyText,
    );
  }
}

class _StreamingOnlyTtsAndImageSendService extends _InMemoryHistorySendService {
  _StreamingOnlyTtsAndImageSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('<tts>语音段</tts>');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    onStreamTextDelta?.call('<image>sunset beach');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    onStreamTextDelta?.call('</image>');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    return ApiCallResult(
      replyText: '<tts>语音段</tts><image>sunset beach</image>',
      processedText: '',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: const <String, dynamic>{
            'text': '语音段',
            'originalText': '语音段',
          },
          id: 'evt_stream_only_multimodal_tts',
        ),
        PluginEvent(
          pluginId: 'image',
          type: 'image_generate',
          data: const <String, dynamic>{
            'prompt': 'sunset beach',
          },
          id: 'evt_stream_only_multimodal_image',
        ),
      ],
      toolResults: const <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: const <Message>[],
      lastMessageText: '',
      rawReplyText: apiResult.replyText,
    );
  }
}

class _RecordingStreamTtsHandler extends ChatTtsHandler {
  _RecordingStreamTtsHandler(super.ref);

  List<Message> lastPendingStreamTtsMessages = const <Message>[];
  List<String> lastStreamTextMessageIds = const <String>[];
  bool lastAppendAfterStreamText = false;
  List<Message> recordedStreamPendingMessages = <Message>[];

  @override
  Future<void> resolvePendingStreamMessage({
    required String convId,
    required Message message,
    void Function(String audioUrl, double? durationSeconds)? onAudioResolved,
    void Function(String text)? onTextFallback,
    bool persistResult = true,
    bool Function()? shouldApplyResult,
  }) async {
    recordedStreamPendingMessages.add(message);
  }

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
  }) async {
    lastAppendAfterStreamText = appendAfterStreamText;
    lastStreamTextMessageIds =
        List<String>.from(streamTextMessageIds ?? const <String>[]);
    lastPendingStreamTtsMessages =
        List<Message>.from(streamPendingTtsMessages ?? const <Message>[]);
  }
}

class _RecordingImageConfigSendService extends _InMemoryHistorySendService {
  _RecordingImageConfigSendService(super.ref, this._settings);

  final AppSettings _settings;
  ApiConfig? lastConfig;
  String? lastOverrideModel;
  String? lastConversationId;
  List<Message>? lastHistory;
  String? lastUserText;
  String? lastDisplayText;
  Message? lastAddedUserMessage;
  int executeCalls = 0;

  @override
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) async {
    lastDisplayText = displayText;
    lastAddedUserMessage = userMsg;
    await super.addUserMessage(
      convId: convId,
      userMsg: userMsg,
      displayText: displayText,
    );
  }

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    lastOverrideModel = overrideModel;
    lastConversationId = conversationId;
    lastHistory = List<Message>.from(history);
    lastUserText = userText;
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        {'role': 'user', 'content': 'stub'},
      ],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    executeCalls += 1;
    lastConfig = config;
    return const ApiCallResult(
      replyText: '图片内容',
      processedText: '图片内容',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_image_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _TrackingDelayedTtsService extends TtsService {
  _TrackingDelayedTtsService({
    Duration defaultDelay = Duration.zero,
    Map<String, Duration>? delays,
    Set<String> failingTexts = const <String>{},
    Map<String, Completer<void>> blockers = const <String, Completer<void>>{},
  })  : _defaultDelay = defaultDelay,
        _delays = delays ?? const <String, Duration>{},
        _failingTexts = failingTexts,
        _blockers = blockers,
        super(
          config: TtsConfig(enabled: true),
          requestUrl: 'https://example.com/tts',
        );

  final Duration _defaultDelay;
  final Map<String, Duration> _delays;
  final Set<String> _failingTexts;
  final Map<String, Completer<void>> _blockers;
  final List<String> startedTexts = <String>[];
  int activeCount = 0;
  int maxConcurrent = 0;

  @override
  Future<TtsConvertResult> convert(String text) async {
    startedTexts.add(text);
    activeCount += 1;
    if (activeCount > maxConcurrent) {
      maxConcurrent = activeCount;
    }
    try {
      await Future<void>.delayed(_delays[text] ?? _defaultDelay);
      final blocker = _blockers[text];
      if (blocker != null) {
        await blocker.future;
      }
      if (_failingTexts.contains(text)) {
        return TtsConvertResult(
          audioUrl: '',
          text: text,
          success: false,
          error: 'test_failure',
        );
      }
      return TtsConvertResult(
        audioUrl: r'C:\tmp\tts_${text.hashCode.abs()}.mp3',
        text: text,
        success: true,
      );
    } finally {
      activeCount -= 1;
    }
  }
}

class _DelayedInlineImagePlugin extends ImagePlugin {
  _DelayedInlineImagePlugin({
    required this.delay,
    required this.localPath,
    this.delaysByPrompt = const <String, Duration>{},
    this.localPathByPrompt = const <String, String>{},
    required Ref ref,
  }) : super(const ImageConfig(), ref);

  final Duration delay;
  final String localPath;
  final Map<String, Duration> delaysByPrompt;
  final Map<String, String> localPathByPrompt;
  final List<String> prompts = <String>[];

  @override
  bool get enabled => true;

  @override
  Future<InlineImageGenerationResult> generateInlineImage({
    required String prompt,
    String? roleArtistPresetName,
  }) async {
    prompts.add(prompt);
    await Future<void>.delayed(delaysByPrompt[prompt] ?? delay);
    return InlineImageGenerationResult.success(
      localPath: localPathByPrompt[prompt] ?? localPath,
      rawPrompt: prompt,
      prompt: prompt,
      negativePrompt: '',
      artistPresetName: roleArtistPresetName,
      artistPresetSource: 'test',
    );
  }
}

class _DelayedWatchConversationTimelineCache extends ConversationTimelineCache {
  _DelayedWatchConversationTimelineCache(
    super.ref, {
    required this.windowDelay,
  });

  final Duration windowDelay;

  @override
  Stream<ConversationTimelineWindowState> watchWindow({
    required String conversationId,
    required int limit,
  }) {
    return super
        .watchWindow(
      conversationId: conversationId,
      limit: limit,
    )
        .asyncMap((window) async {
      await Future<void>.delayed(windowDelay);
      return window;
    });
  }
}

class _DelayedReplaceConversationTimelineCache
    extends ConversationTimelineCache {
  _DelayedReplaceConversationTimelineCache(
    super.ref, {
    required this.replaceDelay,
  });

  final Duration replaceDelay;

  @override
  Future<void> replaceMessages({
    required String conversationId,
    List<String> removeMessageIds = const <String>[],
    List<Message> messages = const <Message>[],
  }) async {
    await Future<void>.delayed(replaceDelay);
    return super.replaceMessages(
      conversationId: conversationId,
      removeMessageIds: removeMessageIds,
      messages: messages,
    );
  }

  @override
  Future<void> replaceMessagesTransient({
    required String conversationId,
    List<String> removeMessageIds = const <String>[],
    List<Message> messages = const <Message>[],
  }) async {
    await Future<void>.delayed(replaceDelay);
    return super.replaceMessagesTransient(
      conversationId: conversationId,
      removeMessageIds: removeMessageIds,
      messages: messages,
    );
  }
}

class _CountingConversationTimelineCache extends ConversationTimelineCache {
  _CountingConversationTimelineCache(super.ref);

  int transientReplaceCalls = 0;

  @override
  Future<void> replaceMessagesTransient({
    required String conversationId,
    List<String> removeMessageIds = const <String>[],
    List<Message> messages = const <Message>[],
  }) async {
    transientReplaceCalls += 1;
    return super.replaceMessagesTransient(
      conversationId: conversationId,
      removeMessageIds: removeMessageIds,
      messages: messages,
    );
  }
}

class _RetryOnceProviderRefreshImageSendService
    extends _InMemoryHistorySendService {
  _RetryOnceProviderRefreshImageSendService(super.ref, this._settings);

  final AppSettings _settings;
  int executeCalls = 0;
  bool markUserMessageFailedCalled = false;

  @override
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) async {}

  @override
  Future<void> markUserMessageFailed({
    required String convId,
    required String userMsgId,
  }) async {
    markUserMessageFailedCalled = true;
  }

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    executeCalls += 1;
    if (executeCalls == 1) {
      throw StateError(
        "'package:riverpod/src/framework/element.dart': "
        "Failed assertion: line 675 pos 7: '!_didChangeDependency': "
        'Cannot use ref functions after the dependency of a provider '
        'changed but before the provider rebuilt',
      );
    }
    return const ApiCallResult(
      replyText: '重试成功',
      processedText: '重试成功',
      pluginEvents: <PluginEvent>[],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_retry_success',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
      rawReplyText: apiResult.replyText,
    );
  }
}

class _RetryOnceProviderRefreshStreamingSendService
    extends _SpyStreamingSendService {
  _RetryOnceProviderRefreshStreamingSendService(super.ref, super._settings);

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    if (executeCalls == 0) {
      executeCalls += 1;
      lastEnableStreaming = enableStreaming;
      sawDeltaCallback = onStreamTextDelta != null;
      sawResetCallback = onStreamTextReset != null;
      sawToolObservedCallback = onStreamToolCallObserved != null;
      sawFallbackCallback = onStreamingFallback != null;
      throw StateError(
        "'package:riverpod/src/framework/element.dart': "
        "Failed assertion: line 675 pos 7: '!_didChangeDependency': "
        'Cannot use ref functions after the dependency of a provider '
        'changed but before the provider rebuilt',
      );
    }
    return super.executeApiCall(
      config: config,
      sessionId: sessionId,
      userText: userText,
      turnId: turnId,
      trace: trace,
      maxRounds: maxRounds,
      onToolExecuting: onToolExecuting,
      enableStreaming: enableStreaming,
      onStreamTextDelta: onStreamTextDelta,
      onStreamTextReset: onStreamTextReset,
      onStreamToolCallObserved: onStreamToolCallObserved,
      onStreamingFallback: onStreamingFallback,
    );
  }
}

class _FailFirstModelStreamingSendService extends _SpyStreamingSendService {
  _FailFirstModelStreamingSendService(
    super.ref,
    super._settings, {
    required this.failingModel,
  });

  final String failingModel;

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    if (config.modelFullId == failingModel) {
      executeCalls += 1;
      lastEnableStreaming = enableStreaming;
      sawDeltaCallback = onStreamTextDelta != null;
      sawResetCallback = onStreamTextReset != null;
      sawToolObservedCallback = onStreamToolCallObserved != null;
      sawFallbackCallback = onStreamingFallback != null;
      throw Exception('模拟首个模型失败');
    }
    return super.executeApiCall(
      config: config,
      sessionId: sessionId,
      userText: userText,
      turnId: turnId,
      trace: trace,
      maxRounds: maxRounds,
      onToolExecuting: onToolExecuting,
      enableStreaming: enableStreaming,
      onStreamTextDelta: onStreamTextDelta,
      onStreamTextReset: onStreamTextReset,
      onStreamToolCallObserved: onStreamToolCallObserved,
      onStreamingFallback: onStreamingFallback,
    );
  }
}

class _NoopChatTtsHandler extends ChatTtsHandler {
  _NoopChatTtsHandler(super.ref);

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
  }) async {}
}

class _DeliverBuildResultOnlyChatTtsHandler extends ChatTtsHandler {
  _DeliverBuildResultOnlyChatTtsHandler(this._ref) : super(_ref);

  final Ref _ref;
  bool lastAppendAfterStreamText = false;

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
  }) async {
    lastAppendAfterStreamText = appendAfterStreamText;
    if (buildResult.messages.isEmpty) {
      return;
    }
    await _ref.read(chatSendServiceProvider).deliverAssistantMessages(
          convId: convId,
          userMsgId: userMsgId,
          buildResult: buildResult,
          trace: trace,
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _installPlatformChannelMocks();

  test('recallFailedMessage 会删除失败消息并软删除数据库记录', () async {
    final now = DateTime.now();
    final failed = Message(
      id: 'msg_failed',
      role: 'user',
      content: '发送失败内容',
      createdAt: now,
      status: 'failed',
    );
    final conv = Conversation(
      id: 'conv_1',
      title: 'C1',
      displayName: 'C1',
      createdAt: now,
      updatedAt: now,
      messages: [failed],
      lastMessage: failed.displayText,
      lastMessageTime: failed.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, failed);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.recallFailedMessage(failed.id);

    final remainingMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    expect(remainingMessages, isEmpty);
    expect(container.read(editingTextProvider), failed.displayText);

    final repo = container.read(messageRepositoryProvider);
    final dbMessage = await repo.getById(failed.id);
    expect(dbMessage, isNotNull);
    expect(dbMessage!.deletedAt, isNotNull);
  });

  test('recallFailedMessage 会回填失败图文消息的文字和图片附件', () async {
    final now = DateTime.now();
    const imagePath = r'C:\tmp\demo_recall.png';
    final failed = Message.fromBlocks(
      id: 'msg_failed_img',
      role: 'user',
      blocks: [
        ImageBlock(
          messageId: 'msg_failed_img',
          localPath: imagePath,
        ),
        TextBlock(
          messageId: 'msg_failed_img',
          content: '这是撤回后的说明文字',
        ),
      ],
      createdAt: now,
      status: 'failed',
    );
    final conv = Conversation(
      id: 'conv_img',
      title: 'C_IMG',
      displayName: 'C_IMG',
      createdAt: now,
      updatedAt: now,
      messages: [failed],
      lastMessage: failed.displayText,
      lastMessageTime: failed.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessageWithBlocks(db, conv.id, failed);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.recallFailedMessage(failed.id);

    expect(container.read(editingTextProvider), '这是撤回后的说明文字');

    final recalledAttachment = container.read(recalledAttachmentProvider);
    expect(recalledAttachment, isNotNull);
    expect(recalledAttachment!.type, AttachmentType.image);
    expect(recalledAttachment.path, imagePath);
  });

  test('editMessage 会回填图文消息的文字和图片附件', () async {
    final now = DateTime.now();
    const imagePath = r'C:\tmp\demo_edit.png';
    final userMsg = Message.fromBlocks(
      id: 'msg_edit_img',
      role: 'user',
      blocks: [
        ImageBlock(
          messageId: 'msg_edit_img',
          localPath: imagePath,
        ),
        TextBlock(
          messageId: 'msg_edit_img',
          content: '编辑时应回填这段文字',
        ),
      ],
      createdAt: now,
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_edit_ai',
      role: 'assistant',
      content: '后续回复',
      createdAt: now.add(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_edit',
      title: 'C_EDIT',
      displayName: 'C_EDIT',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessageWithBlocks(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    final text = await actions.editMessage(userMsg.id);

    expect(text, '编辑时应回填这段文字');

    final recalledAttachment = container.read(chatEditSeedProvider(conv.id))?.attachment;
    expect(recalledAttachment, isNotNull);
    expect(recalledAttachment!.type, AttachmentType.image);
    expect(recalledAttachment.path, imagePath);

    final remainingMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    expect(remainingMessages, isNotEmpty);

    final repo = container.read(messageRepositoryProvider);
    final deletedUser = await repo.getById(userMsg.id);
    final deletedAi = await repo.getById(aiMsg.id);
    expect(deletedUser, isNotNull);
    expect(deletedUser!.deletedAt, isNull);
    expect(deletedAi, isNotNull);
    expect(deletedAi!.deletedAt, isNull);
  });

  test('editMessage 只准备编辑草稿，不调用旧截断入口', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_edit_fast_path_user',
      role: 'user',
      content: '这条消息应该直接从前端缓存命中',
      createdAt: now,
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_edit_fast_path_ai',
      role: 'assistant',
      content: '后续回复',
      createdAt: now.add(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_edit_fast_path',
      title: 'C_EDIT_FAST',
      displayName: 'C_EDIT_FAST',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    final truncateCompleter = Completer<void>();
    final historyPort = _EditMessageFastPathHistoryPort(
      onTruncateFromMessage: () => truncateCompleter.future,
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        chatHistoryPortProvider.overrideWithValue(historyPort),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container
        .read(chatHistoryStoreProvider)
        .loadCachedTimelineMessages(conv.id);
    final actions = container.read(chatActionsProvider);

    final pending = actions.editMessage(userMsg.id);
    await Future<void>.delayed(Duration.zero);

    expect(historyPort.loadRawMessagesCallCount, 0);
    expect(historyPort.truncateFromMessageCallCount, 0);

    truncateCompleter.complete();

    final text = await pending;
    expect(text, '这条消息应该直接从前端缓存命中');
  });

  test('prepareTextRegenerate 会复用原用户文本并从用户消息开始截断', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_regen_text_user',
      role: 'user',
      content: '这句原话会被重新发送',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_regen_text_ai',
      role: 'assistant',
      content: '这句 AI 回复不应该被当作发送文本',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen_text_prepare',
      title: 'C_REGEN_TEXT',
      displayName: 'C_REGEN_TEXT',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    final previewText = await actions.peekTextRegenerate(aiMsg.id);
    expect(previewText, '这句原话会被重新发送');

    final beforeMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    expect(beforeMessages.map((message) => message.id), [
      userMsg.id,
      aiMsg.id,
    ]);

    final preparedText = await actions.prepareTextRegenerate(aiMsg.id);
    expect(preparedText, '这句原话会被重新发送');

    final remainingMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    expect(remainingMessages, isEmpty);

    final repo = container.read(messageRepositoryProvider);
    final deletedUser = await repo.getById(userMsg.id);
    final deletedAi = await repo.getById(aiMsg.id);
    expect(deletedUser, isNotNull);
    expect(deletedUser!.deletedAt, isNotNull);
    expect(deletedAi, isNotNull);
    expect(deletedAi!.deletedAt, isNotNull);
  });

  test('prepareTextRegenerate 支持使用历史投影 assistant id', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_regen_projected_user',
      role: 'user',
      content: '这句原话来自分页历史',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen_projected_assistant',
      title: 'C_REGEN_PROJECTED',
      displayName: 'C_REGEN_PROJECTED',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg],
      lastMessage: userMsg.displayText,
      lastMessageTime: userMsg.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final assistantBuild = _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_projected_history_item',
          role: 'assistant',
          content: '这是历史分页里的 assistant 投影消息',
          createdAt: now.subtract(const Duration(seconds: 1)),
          status: 'sent',
        ),
      ],
      lastMessageText: '这是历史分页里的 assistant 投影消息',
      rawReplyText: '这是历史分页里的 assistant 投影消息',
    );
    await container.read(chatHistoryStoreProvider).appendAssistantRawMessage(
          conversationId: conv.id,
          userMessageId: userMsg.id,
          rawMessage: assistantBuild.rawMessage!,
          projectedMessages: assistantBuild.messages,
          lastMessagePreview: assistantBuild.lastMessageText,
          updateShortWindow: false,
        );

    final actions = container.read(chatActionsProvider);
    final previewText =
        await actions.peekTextRegenerate('assistant_projected_history_item');
    expect(previewText, '这句原话来自分页历史');

    final preparedText =
        await actions.prepareTextRegenerate('assistant_projected_history_item');
    expect(preparedText, '这句原话来自分页历史');
  });

  test('regenerate 支持使用历史投影 assistant id', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_regen_projected_api_user',
      role: 'user',
      content: '请基于这句历史用户消息重新生成',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen_projected_api',
      title: 'C_REGEN_PROJECTED_API',
      displayName: 'C_REGEN_PROJECTED_API',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg],
      lastMessage: userMsg.displayText,
      lastMessageTime: userMsg.createdAt,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);

    late _SpyStreamingSendService spyService;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          spyService = _SpyStreamingSendService(ref, settings);
          return spyService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final assistantBuild = _buildTestAssistantBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_projected_history_regenerate',
          role: 'assistant',
          content: '这是历史分页里的投影 assistant',
          createdAt: now.subtract(const Duration(seconds: 1)),
          status: 'sent',
        ),
      ],
      lastMessageText: '这是历史分页里的投影 assistant',
      rawReplyText: '这是历史分页里的投影 assistant',
    );
    await container.read(chatHistoryStoreProvider).appendAssistantRawMessage(
          conversationId: conv.id,
          userMessageId: userMsg.id,
          rawMessage: assistantBuild.rawMessage!,
          projectedMessages: assistantBuild.messages,
          lastMessagePreview: assistantBuild.lastMessageText,
          updateShortWindow: false,
        );

    final actions = container.read(chatActionsProvider);
    await actions.regenerate('assistant_projected_history_regenerate');

    expect(spyService.executeCalls, 1);
    expect(spyService.lastEnableStreaming, isTrue);
  });

  test('prepareTextRegenerate 遇到图文轮次时会返回 null 且保留原消息', () async {
    final now = DateTime.now();
    const imagePath = r'C:\tmp\demo_regen_image.png';
    final userMsg = Message.fromBlocks(
      id: 'msg_regen_image_user',
      role: 'user',
      blocks: [
        ImageBlock(
          messageId: 'msg_regen_image_user',
          localPath: imagePath,
        ),
        TextBlock(
          messageId: 'msg_regen_image_user',
          content: '这是一条带图片的原始消息',
        ),
      ],
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_regen_image_ai',
      role: 'assistant',
      content: '图片回复',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen_image_prepare',
      title: 'C_REGEN_IMAGE',
      displayName: 'C_REGEN_IMAGE',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessageWithBlocks(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    final previewText = await actions.peekTextRegenerate(aiMsg.id);
    expect(previewText, isNull);

    final preparedText = await actions.prepareTextRegenerate(aiMsg.id);
    expect(preparedText, isNull);

    final remainingMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    expect(remainingMessages.map((message) => message.id), [
      userMsg.id,
      aiMsg.id,
    ]);

    final repo = container.read(messageRepositoryProvider);
    final persistedUser = await repo.getById(userMsg.id);
    final persistedAi = await repo.getById(aiMsg.id);
    expect(persistedUser, isNotNull);
    expect(persistedUser!.deletedAt, isNull);
    expect(persistedAi, isNotNull);
    expect(persistedAi!.deletedAt, isNull);
  });

  test('deleteMessage 仅隐藏前端消息并清理引用态', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_user',
      role: 'user',
      content: '第一条',
      createdAt: now.subtract(const Duration(minutes: 1)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_ai',
      role: 'assistant',
      content: '第二条',
      createdAt: now,
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_2',
      title: 'C2',
      displayName: 'C2',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);
    await _insertTextBlock(db, userMsg.id, 'blk_user_1');
    await _insertTextBlock(db, aiMsg.id, 'blk_ai_1');

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    container.read(quotedMessageProvider.notifier).state = const QuotedMessage(
      id: 'msg_ai',
      content: '第二条',
      isUser: false,
    );

    await actions.deleteMessage(aiMsg.id);

    final visibleWindow =
        await container.read(conversationMessageWindowProvider(conv.id).future);
    expect(visibleWindow.messages.map((message) => message.id), [userMsg.id]);
    expect(container.read(quotedMessageProvider), isNull);

    final canonicalMessages = await container
        .read(chatHistoryStoreProvider)
        .loadCanonicalContextMessages(conv.id);
    expect(
      canonicalMessages.map((message) => message.id),
      [userMsg.id, aiMsg.id],
    );

    await container
        .read(conversationTimelineCacheProvider)
        .reloadConversationFromRawStore(conv.id);
    final visibleAfterReload =
        await container.read(conversationMessageWindowProvider(conv.id).future);
    expect(
      visibleAfterReload.messages.map((message) => message.id),
      [userMsg.id],
    );

    final repo = container.read(messageRepositoryProvider);
    final blockRepo = container.read(messageBlockRepositoryProvider);
    final deleted = await repo.getById(aiMsg.id);
    final remained = await repo.getById(userMsg.id);
    final deletedBlocks = await blockRepo.getByMessage(aiMsg.id);
    final remainedBlocks = await blockRepo.getByMessage(userMsg.id);
    expect(deleted, isNotNull);
    expect(deleted!.deletedAt, isNull);
    expect(remained, isNotNull);
    expect(remained!.deletedAt, isNull);
    expect(deletedBlocks.length, 1);
    expect(remainedBlocks.length, 1);

    final deletedBlockRaw = await blockRepo.getById('blk_ai_1');
    final remainedBlockRaw = await blockRepo.getById('blk_user_1');
    expect(deletedBlockRaw, isNotNull);
    expect(deletedBlockRaw!.deletedAt, isNull);
    expect(remainedBlockRaw, isNotNull);
    expect(remainedBlockRaw!.deletedAt, isNull);
  });

  test('deleteMessage 删除 AI 单个气泡时只隐藏该气泡，不改同源 raw 语义', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_user_proj',
      role: 'user',
      content: '帮我拆成两句',
      createdAt: now.subtract(const Duration(minutes: 1)),
      status: 'sent',
    );
    final assistantBuild = _buildTestAssistantBuildResult(
      messages: [
        Message.text(
          id: 'msg_ai_seg_1',
          role: 'assistant',
          content: '第一句',
          createdAt: now,
          status: 'sent',
        ),
        Message.text(
          id: 'msg_ai_seg_2',
          role: 'assistant',
          content: '第二句',
          createdAt: now.add(const Duration(seconds: 1)),
          status: 'sent',
        ),
      ],
      lastMessageText: '第二句',
    );
    final baseRawAiMsg = assistantBuild.rawMessage!;
    final rawAiMsg = baseRawAiMsg.copyWith(
      rawPayload: ChatMessageProjectionCodec.copyWithProjectedMessages(
        baseRawAiMsg.rawPayload,
        assistantBuild.messages,
      ),
    );
    final conv = Conversation(
      id: 'conv_delete_projected',
      title: 'DeleteProjected',
      displayName: 'DeleteProjected',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, rawAiMsg],
      lastMessage: rawAiMsg.displayText,
      lastMessageTime: rawAiMsg.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, rawAiMsg);
    await _insertTextBlock(db, userMsg.id, 'blk_user_proj_1');

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    container.read(quotedMessageProvider.notifier).state = const QuotedMessage(
      id: 'msg_ai_seg_1',
      content: '第一句',
      isUser: false,
    );

    await actions.deleteMessage('msg_ai_seg_1');

    final visibleWindow =
        await container.read(conversationMessageWindowProvider(conv.id).future);
    expect(
      visibleWindow.messages.map((message) => message.id),
      [userMsg.id, 'msg_ai_seg_2'],
    );
    expect(container.read(quotedMessageProvider), isNull);

    final canonicalMessages = await container
        .read(chatHistoryStoreProvider)
        .loadCanonicalContextMessages(conv.id);
    expect(
      canonicalMessages.map((message) => message.id),
      [userMsg.id, rawAiMsg.id],
    );

    await container
        .read(conversationTimelineCacheProvider)
        .reloadConversationFromRawStore(conv.id);
    final visibleAfterReload =
        await container.read(conversationMessageWindowProvider(conv.id).future);
    expect(
      visibleAfterReload.messages.map((message) => message.id),
      [userMsg.id, 'msg_ai_seg_2'],
    );

    final repo = container.read(messageRepositoryProvider);
    final persistedRawAi = await repo.getById(rawAiMsg.id);
    expect(persistedRawAi, isNotNull);
    expect(persistedRawAi!.deletedAt, isNull);
    expect(persistedRawAi.rawPayload, isNotNull);

    final persistedPayload =
        jsonDecode(persistedRawAi.rawPayload!) as Map<String, dynamic>;
    final persistedProjected =
        ChatMessageProjectionCodec.projectedMessages(persistedPayload);
    expect(
      persistedProjected.map((message) => message.id),
      ['msg_ai_seg_1', 'msg_ai_seg_2'],
    );
  });

  test('retry 会使用流式参数调用 API', () async {
    final now = DateTime.now();
    final failedUser = Message(
      id: 'msg_user_retry',
      role: 'user',
      content: '重试一下',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'failed',
    );
    final conv = Conversation(
      id: 'conv_retry',
      title: 'Retry',
      displayName: 'Retry',
      createdAt: now,
      updatedAt: now,
      messages: [failedUser],
      lastMessage: failedUser.displayText,
      lastMessageTime: failedUser.createdAt,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, failedUser);

    late _SpyStreamingSendService spyService;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith((ref) {
          spyService = _SpyStreamingSendService(ref, settings);
          return spyService;
        }),
        activeConversationProvider.overrideWith((ref) {
          return conv;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.retry(failedUser.id);

    expect(spyService.executeCalls, 1);
    expect(spyService.lastEnableStreaming, isTrue);
    expect(spyService.sawDeltaCallback, isTrue);
    expect(spyService.sawResetCallback, isTrue);
    expect(spyService.sawToolObservedCallback, isTrue);
    expect(spyService.sawFallbackCallback, isTrue);
  });

  test('sendProactiveTrigger 会把 targetConvId 显式传给 prepareApiConfig', () async {
    final now = DateTime.now();
    final activeConv = Conversation(
      id: 'conv_active',
      title: 'Active',
      displayName: 'Active',
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
    final targetConv = Conversation(
      id: 'conv_target',
      title: 'Target',
      displayName: 'Target',
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
    final trigger = AutoReplyTrigger(
      id: 'trigger_1',
      title: '早安问候',
      type: AutoReplyTriggerType.fixed,
      status: AutoReplyTriggerStatus.pending,
      createdAt: now,
      nextFireAt: now,
      allowNight: true,
      requireExact: false,
      delayMinutes: 0,
      manual: false,
      conversationId: targetConv.id,
      contextSnapshot: '[{"role":"user","content":"昨晚聊过了"}]',
    );
    final settings = _buildTestSettings().copyWith(
      ttsEnabled: false,
      autoReplySettings: const AutoReplySettings(enabled: true),
    );

    late _RecordingImageConfigSendService sendService;
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService = _RecordingImageConfigSendService(ref, settings);
          return sendService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([activeConv, targetConv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.firstWhere((c) => c.id == activeConv.id);
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    final result = await actions.sendProactiveTrigger(trigger);

    expect(result.success, isTrue);
    expect(sendService.lastConversationId, targetConv.id);
  });

  test('sendProactiveTrigger 遇到 Provider 刷新窗口错误时会自动重试一次', () async {
    final now = DateTime.now();
    final targetConv = Conversation(
      id: 'conv_target_retry',
      title: 'TargetRetry',
      displayName: 'TargetRetry',
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
    final trigger = AutoReplyTrigger(
      id: 'trigger_retry',
      title: '中午提醒',
      type: AutoReplyTriggerType.fixed,
      status: AutoReplyTriggerStatus.pending,
      createdAt: now,
      nextFireAt: now,
      allowNight: true,
      requireExact: false,
      delayMinutes: 0,
      manual: false,
      conversationId: targetConv.id,
      contextSnapshot: '[{"role":"user","content":"上次提醒失败了"}]',
    );
    final settings = _buildTestSettings().copyWith(
      ttsEnabled: false,
      autoReplySettings: const AutoReplySettings(enabled: true),
    );

    late _RetryOnceProviderRefreshImageSendService sendService;
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService =
              _RetryOnceProviderRefreshImageSendService(ref, settings);
          return sendService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([targetConv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    final result = await actions.sendProactiveTrigger(trigger);

    expect(result.success, isTrue);
    expect(sendService.executeCalls, 2);
    expect(sendService.markUserMessageFailedCalled, isFalse);
  });

  test('sendComposerText 会拼接引用前缀并清空引用态', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_send_composer_quote',
      title: 'ComposerQuote',
      displayName: 'ComposerQuote',
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
    final settings = _buildTestSettings().copyWith(ttsEnabled: false);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    late _RecordingImageConfigSendService sendService;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith((ref) {
          sendService = _RecordingImageConfigSendService(ref, settings);
          return sendService;
        }),
        activeConversationProvider.overrideWith((ref) => conv),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);
    container.read(quotedMessageProvider.notifier).state = const QuotedMessage(
      id: 'quoted_1',
      content: '上一条引用消息',
      isUser: false,
    );

    await actions.sendComposerText('继续往下说');

    expect(
      sendService.lastUserText,
      '> Quote: 上一条引用消息\n\n继续往下说',
    );
    expect(container.read(quotedMessageProvider), isNull);
  });

  test('regenerate 会使用流式参数调用 API', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_user_regen',
      role: 'user',
      content: '你好呀',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_ai_regen',
      role: 'assistant',
      content: '旧回复',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen',
      title: 'Regen',
      displayName: 'Regen',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );
    final settings = _buildTestSettings();

    late _SpyStreamingSendService spyService;
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith((ref) {
          spyService = _SpyStreamingSendService(ref, settings);
          return spyService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.regenerate(aiMsg.id);

    expect(spyService.executeCalls, 1);
    expect(spyService.lastEnableStreaming, isTrue);
    expect(spyService.sawDeltaCallback, isTrue);
    expect(spyService.sawResetCallback, isTrue);
    expect(spyService.sawToolObservedCallback, isTrue);
    expect(spyService.sawFallbackCallback, isTrue);
  });

  test('regenerate 遇到 Provider 刷新窗口错误时会自动重试一次', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_user_regen_retry',
      role: 'user',
      content: '重新生成一下',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_ai_regen_retry',
      role: 'assistant',
      content: '旧回复',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen_retry',
      title: 'RegenRetry',
      displayName: 'RegenRetry',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    late _RetryOnceProviderRefreshStreamingSendService sendService;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService =
              _RetryOnceProviderRefreshStreamingSendService(ref, settings);
          return sendService;
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.regenerate(aiMsg.id);

    expect(sendService.executeCalls, 2);
    expect(sendService.lastEnableStreaming, isTrue);
    expect(container.read(errorProvider), isNull);
    expect(container.read(conversationSendingProvider(conv.id)), isFalse);
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });

  test('send 遇到 Provider 刷新窗口错误时会自动重试一次且不会重复追加用户消息', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_send_retry',
      title: 'SendRetry',
      displayName: 'SendRetry',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    late _RetryOnceProviderRefreshStreamingSendService sendService;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService =
              _RetryOnceProviderRefreshStreamingSendService(ref, settings);
          return sendService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.send('第一次先撞刷新窗口');

    expect(sendService.executeCalls, 2);
    expect(sendService.addUserMessageCalls, 1);
    expect(sendService.lastEnableStreaming, isTrue);
    expect(container.read(errorProvider), isNull);
    expect(container.read(conversationSendingProvider(conv.id)), isFalse);
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });

  test('send 在多模型场景遇到 Provider 刷新窗口错误时不应误触发模型切换提示', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_send_retry_multi_models',
      title: 'SendRetryMultiModels',
      displayName: 'SendRetryMultiModels',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings().copyWith(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      modelList: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      allKnownModels: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      modelProviderMap: const <String, String>{
        'openai:gpt-4o-mini': 'openai',
        'gpt-4o-mini': 'openai',
        'openai:gpt-3.5-turbo': 'openai',
        'gpt-3.5-turbo': 'openai',
      },
    );
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    late _RetryOnceProviderRefreshStreamingSendService sendService;
    _SpyModelFailoverPromptController? failoverController;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        modelFailoverPromptProvider.overrideWith(() {
          final controller = _SpyModelFailoverPromptController();
          failoverController = controller;
          return controller;
        }),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService =
              _RetryOnceProviderRefreshStreamingSendService(ref, settings);
          return sendService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.send('多模型下先撞刷新窗口');

    expect(sendService.executeCalls, 2);
    expect(sendService.addUserMessageCalls, 1);
    expect(failoverController?.requestCalls ?? 0, 0);
    expect(container.read(errorProvider), isNull);
    expect(container.read(conversationSendingProvider(conv.id)), isFalse);
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });

  test('send 在收到 delta 后发生流式回退时，仍保留流式文本并仅后补图片', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_fallback',
      title: 'StreamFallback',
      displayName: 'StreamFallback',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _FallbackAfterDeltaSendService(ref, settings),
        ),
        activeConversationProvider.overrideWith((ref) {
          return conv;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.send('测试回退后是否保留流式文本');

    final storedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final assistantMessages = storedMessages
        .where((m) => m.role == 'assistant')
        .toList(growable: false);
    expect(
      assistantMessages.any((m) => m.displayText.contains('前置流式文本')),
      isTrue,
      reason: '有 delta 后回退到正式交付时，应保留 buildResult 里的原始正文消息',
    );
    expect(
      assistantMessages
          .any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
      isTrue,
    );
  });

  test('send 在关闭分段时，流式中途文本块应为 success 以显示实时文本', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_no_chunk',
      title: 'StreamNoChunk',
      displayName: 'StreamNoChunk',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings().copyWith(
      messageFormatConfig: const MessageFormatConfig(enableChunking: false),
    );
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _SingleDeltaSlowFinalizeSendService(ref, settings),
        ),
        activeConversationProvider.overrideWith((ref) {
          return conv;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    final sendFuture = actions.send('测试关闭分段时也要看到流式文本');
    final frontendSnapshots = <List<Message>>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      frontendSnapshots.add(
        List<Message>.from(
          await _loadFrontendTimelineMessages(container, conv.id),
        ),
      );
    }
    await sendFuture;

    var sawInProgressSuccessText = false;
    for (final snapshot in frontendSnapshots) {
      final assistantSendingMessages = snapshot.where((m) {
        return m.role == 'assistant' && m.status == 'sending';
      });

      for (final message in assistantSendingMessages) {
        final blocks = message.blocks ?? const [];
        final textBlocks = blocks.whereType<TextBlock>().toList();
        if (textBlocks.isEmpty) continue;
        final text = textBlocks.first.content.trim();
        if (text.isEmpty || text == '生成中...') continue;
        if (textBlocks.first.status == BlockStatus.success) {
          sawInProgressSuccessText = true;
          break;
        }
      }
      if (sawInProgressSuccessText) break;
    }

    expect(
      sawInProgressSuccessText,
      isTrue,
      reason: '关闭分段后，流式中途应显示文本本身而不是始终保持 streaming 三点',
    );
  });

  test('send 在开启分段时，约 0.5 秒后应先出现在前端时间线缓存里的生成中占位气泡', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_thinking_delay',
      title: 'StreamThinkingDelay',
      displayName: 'StreamThinkingDelay',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _DelayedFirstSentenceSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final sendFuture =
        container.read(chatActionsProvider).send('测试 0.5 秒生成中占位');

    await Future<void>.delayed(const Duration(milliseconds: 560));
    final frontendMessages =
        await _loadFrontendTimelineMessages(container, conv.id);

    final thinkingBubble = frontendMessages.cast<Message?>().firstWhere(
          (message) =>
              message != null &&
              message.role == 'assistant' &&
              message.status == 'sending' &&
              (message.blocks?.whereType<TextBlock>().any(
                        (block) =>
                            block.status == BlockStatus.streaming &&
                            block.content.trim() == '生成中...',
                      ) ??
                  false),
          orElse: () => null,
        );

    expect(
      thinkingBubble,
      isNotNull,
      reason: '首句还没达到分段条件时，应先出现三点生成中占位，而不是一直没有气泡',
    );

    await sendFuture;
  });

  test('send 在开启分段时，无可见变化的流式增量不应重复刷新前端时间线', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_skip_invisible_delta',
      title: 'StreamSkipInvisibleDelta',
      displayName: 'StreamSkipInvisibleDelta',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    late _CountingConversationTimelineCache timelineCache;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _NoBoundarySlowDeltaSendService(ref, settings),
        ),
        conversationTimelineCacheProvider.overrideWith((ref) {
          timelineCache = _CountingConversationTimelineCache(ref);
          return timelineCache;
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    await container.read(chatActionsProvider).send('测试无可见变化增量');

    expect(
      timelineCache.transientReplaceCalls,
      lessThanOrEqualTo(2),
      reason: '没有达到分段边界的 token 增量不应反复通知聊天 UI 重建',
    );

    final frontendMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    expect(
      frontendMessages.any(
        (message) =>
            message.role == 'assistant' &&
            message.displayText.contains('再补充一点。'),
      ),
      isTrue,
    );
  });

  test('send 在开启分段时，生成中占位应稳定钉底不动，真实段以新 id 新建', () async {
    final now = DateTime.now();
    final convId =
        'conv_stream_placeholder_pinned_${now.microsecondsSinceEpoch}';
    final conv = Conversation(
      id: convId,
      title: 'StreamPlaceholderPinned',
      displayName: 'StreamPlaceholderPinned',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _DelayedMultiSentenceSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试占位钉底');
    String? firstPlaceholderId;
    var sawPlaceholderIdChange = false;
    var sawAssistantCountDrop = false;
    var sawRealSegmentWithNewId = false;
    var sawPlaceholderStayedAsPlaceholder = false;
    int? previousAssistantCount;

    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 90));
      final frontendMessages =
          await _loadFrontendTimelineMessages(container, conv.id);
      final assistantMessages = frontendMessages
          .where((message) => message.role == 'assistant')
          .toList(growable: false);
      final generatingMessages =
          _collectGeneratingPlaceholderMessages(assistantMessages);
      if (firstPlaceholderId == null && generatingMessages.isNotEmpty) {
        firstPlaceholderId = generatingMessages.last.id;
      }
      if (firstPlaceholderId == null) {
        continue;
      }
      if (previousAssistantCount != null &&
          assistantMessages.length < previousAssistantCount) {
        sawAssistantCountDrop = true;
      }
      previousAssistantCount = assistantMessages.length;

      // 占位 id 稳定钉底：整个流式期间占位始终是同一个 id（不被 promote 抢走换 id）。
      final currentPlaceholderIds = generatingMessages.map((m) => m.id).toSet();
      if (currentPlaceholderIds.length > 1 ||
          (currentPlaceholderIds.isNotEmpty &&
              !currentPlaceholderIds.contains(firstPlaceholderId))) {
        sawPlaceholderIdChange = true;
      }
      // 占位始终保持占位身份（不被原位升级成正文）。
      if (generatingMessages.any((m) => m.id == firstPlaceholderId)) {
        sawPlaceholderStayedAsPlaceholder = true;
      }
      // 真实段以新 id 出现（不沿用旧占位 id）。
      final realTextMessages = assistantMessages.where((message) =>
          message.id != firstPlaceholderId &&
          message.displayText.trim().isNotEmpty &&
          !_isGeneratingPlaceholderMessage(message));
      if (realTextMessages.any((message) => message.status == 'sent')) {
        sawRealSegmentWithNewId = true;
      }
    }

    await sendFuture;

    expect(
      firstPlaceholderId,
      isNotNull,
      reason: '前置条件：流式阶段应先出现一条生成中占位，才能验证它是否稳定钉底。',
    );
    expect(
      sawPlaceholderIdChange,
      isFalse,
      reason: '占位推进期间占位 id 不应变化（不再被 promote 抢走换 id）。',
    );
    expect(
      sawPlaceholderStayedAsPlaceholder,
      isTrue,
      reason: '占位应始终保持生成中占位身份，不被原位升级成正文。',
    );
    expect(
      sawRealSegmentWithNewId,
      isTrue,
      reason: '首句封口后真实段应以新 id 新建，而非沿用旧占位 id 原位升级。',
    );
    expect(
      sawAssistantCountDrop,
      isFalse,
      reason: '占位推进期间，前端时间线缓存消息数不应先减少再增加，否则列表会先缩再顶，产生抽搐。',
    );

    final finalizedMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    expect(
      finalizedMessages.any(
        (message) =>
            message.id == firstPlaceholderId &&
            message.displayText.trim() != '第一句。' &&
            _isGeneratingPlaceholderMessage(message) == false,
      ),
      isFalse,
      reason: '收尾后旧占位 id 不应变成真实正文（不再原位升级）。',
    );
    expect(
      finalizedMessages.any(
        (message) =>
            message.displayText.trim() == '第一句。' &&
            message.id != firstPlaceholderId,
      ),
      isTrue,
      reason: '收尾后第一句应以新 id 存在，而非沿用最初占位的 id。',
    );
    expect(
      _collectGeneratingPlaceholderMessages(finalizedMessages),
      isEmpty,
      reason: 'finalize 后不应残留生成中占位。',
    );
  });

  test('send 流式文本期间应只写入前端时间线缓存，数据库正式历史保持干净', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_stable_timeline_only',
      title: 'StableTimelineOnly',
      displayName: 'StableTimelineOnly',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _DelayedFirstSentenceSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试正式时间线直写');
    await Future<void>.delayed(const Duration(milliseconds: 560));
    final stableMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final frontendMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    await sendFuture;

    expect(
      stableMessages.any(
        (message) => message.role == 'assistant' && message.status == 'sending',
      ),
      isFalse,
      reason: '流式阶段的 assistant 占位不应提前落进正式历史，否则会把分段策略写死到持久层',
    );
    expect(
      frontendMessages.any(
        (message) => message.role == 'assistant' && message.status == 'sending',
      ),
      isTrue,
      reason: '流式阶段的 assistant 占位应只挂在前端时间线缓存，等待正式消息落库后再清掉',
    );
  });

  test('send 在打断生成后，应恢复前端用户消息并清掉临时态消息', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_interrupt_cleanup',
      title: 'StreamInterruptCleanup',
      displayName: 'StreamInterruptCleanup',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _DelayedFirstSentenceSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    var sendFinished = false;
    final sendFuture = container.read(chatActionsProvider).send('测试打断后立即清占位');
    sendFuture.whenComplete(() => sendFinished = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 560));
      final frontendBeforeInterrupt =
          await _loadFrontendTimelineMessages(container, conv.id);
      expect(
        sendFinished,
        isFalse,
        reason: '打断前底层请求仍应处于进行中，不能提前自然结束。',
      );
      expect(
        frontendBeforeInterrupt.any(
          (message) =>
              message.role == 'user' && message.displayText == '测试打断后立即清占位',
        ),
        isTrue,
        reason: '打断前，前端时间线缓存里至少应保留刚发出的用户消息，后续才能验证中断恢复是否正确。',
      );

      final stopped = await container
          .read(chatActionsProvider)
          .interruptCurrentGeneration();
      expect(stopped, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        sendFinished,
        isFalse,
        reason: '此时底层请求尚未自然返回，需要证明占位是在“中断瞬间”被清掉，而不是等请求结束后才消失。',
      );
      expect(
        (await _loadFrontendTimelineMessages(container, conv.id))
            .map((message) => message.displayText),
        ['测试打断后立即清占位'],
        reason: '打断生成后，前端应清掉 assistant 占位，但保留已落库的用户消息。',
      );
      expect(
        (await container
                .read(chatHistoryStoreProvider)
                .loadProjectedMessagesFromRawStore(conv.id))
            .where((message) => message.role == 'assistant'),
        isEmpty,
        reason: '打断生成后，正式时间线里也不应残留 assistant 占位。',
      );

      await sendFuture;

      final storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      expect(
        storedMessages.where((message) => message.role == 'assistant'),
        isEmpty,
        reason: '中断后的迟到结果不应再落成 assistant 消息。',
      );
      expect(
        (await _loadFrontendTimelineMessages(container, conv.id))
            .map((message) => message.displayText),
        ['测试打断后立即清占位'],
        reason: '底层请求自然返回后，前端仍应保持和持久历史一致的用户消息。',
      );
    } finally {
      await sendFuture;
    }
  });

  test('regenerate 截断到窗口外的原用户消息时，应立即把原用户消息补回前端时间线', () async {
    final baseTime = DateTime(2026, 4, 1, 12, 0, 0);
    final targetUser = Message(
      id: 'msg_regen_window_anchor_user',
      role: 'user',
      content: '这句原话在截断后必须立刻回到前端时间线',
      createdAt: baseTime,
      status: 'sent',
    );
    final targetAssistant = Message(
      id: 'msg_regen_window_anchor_ai',
      role: 'assistant',
      content: '这条回复会被重新生成',
      createdAt: baseTime.add(const Duration(seconds: 1)),
      status: 'sent',
    );
    final tailMessages = <Message>[
      for (var index = 0; index < 19; index++)
        Message(
          id: 'msg_regen_window_tail_$index',
          role: index.isEven ? 'user' : 'assistant',
          content: 'tail-$index',
          createdAt: baseTime.add(Duration(seconds: index + 2)),
          status: 'sent',
        ),
    ];
    final allMessages = <Message>[
      targetUser,
      targetAssistant,
      ...tailMessages,
    ];
    final conv = Conversation(
      id: 'conv_regen_window_anchor_restore',
      title: 'RegenWindowAnchorRestore',
      displayName: 'RegenWindowAnchorRestore',
      createdAt: baseTime,
      updatedAt: allMessages.last.createdAt,
      messages: allMessages,
      lastMessage: allMessages.last.displayText,
      lastMessageTime: allMessages.last.createdAt,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    for (final message in allMessages) {
      await _insertMessage(db, conv.id, message);
    }

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _DelayedFirstSentenceSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    await container
        .read(conversationTimelineCacheProvider)
        .reloadConversationFromRawStore(
          conv.id,
          targetMessageCount: 20,
        );

    final frontendBeforeRegenerate =
        await _loadFrontendTimelineMessages(container, conv.id);
    expect(
      frontendBeforeRegenerate.any((message) => message.id == targetUser.id),
      isFalse,
      reason: '前置用户消息要先落在窗口外，才能验证重生成截断时会不会补回。',
    );
    expect(
      frontendBeforeRegenerate.any(
        (message) => message.id == targetAssistant.id,
      ),
      isTrue,
      reason: '目标 assistant 需要位于当前前端窗口内，才能触发这条重生成链路。',
    );

    final regenerateFuture =
        container.read(chatActionsProvider).regenerate(targetAssistant.id);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final frontendDuringRegenerate =
          await _loadFrontendTimelineMessages(container, conv.id);
      final stableMessageIds = frontendDuringRegenerate
          .where((message) => message.status != 'sending')
          .map((message) => message.id)
          .toList(growable: false);
      expect(
        stableMessageIds,
        [targetUser.id],
        reason: '重生成开始后，即使原用户消息先前落在窗口外，前端也应立刻只保留这条原用户消息。',
      );

      final stopped = await container
          .read(chatActionsProvider)
          .interruptCurrentGeneration();
      expect(stopped, isTrue);
    } finally {
      await regenerateFuture;
    }
  });

  test('regenerate 在打断生成后，应恢复前端消息并保留原用户消息', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_regen_interrupt_user',
      role: 'user',
      content: '请基于这句话重新生成',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_regen_interrupt_ai',
      role: 'assistant',
      content: '这是一条会被替换掉的旧回复',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen_interrupt_cleanup',
      title: 'RegenInterruptCleanup',
      displayName: 'RegenInterruptCleanup',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _DelayedFirstSentenceSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    var regenerateFinished = false;
    final regenerateFuture =
        container.read(chatActionsProvider).regenerate(aiMsg.id);
    regenerateFuture.whenComplete(() => regenerateFinished = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 560));

      final stopped = await container
          .read(chatActionsProvider)
          .interruptCurrentGeneration();
      expect(stopped, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        regenerateFinished,
        isFalse,
        reason: '此时底层请求尚未自然返回，需要证明保留用户消息发生在“打断瞬间”',
      );

      final frontendAfterInterrupt =
          await _loadFrontendTimelineMessages(container, conv.id);
      final persistedMessagesAfterInterrupt = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      expect(
        frontendAfterInterrupt.map((message) => message.id),
        persistedMessagesAfterInterrupt.map((message) => message.id),
        reason: '重新生成被打断后，前端时间线应恢复到与持久历史一致。',
      );
      expect(
        frontendAfterInterrupt.any((message) => message.id == userMsg.id),
        isTrue,
        reason: '重新生成被打断后，前端时间线仍应保留原用户消息。',
      );
      expect(
        frontendAfterInterrupt.where(
          (message) =>
              message.role == 'assistant' && message.status == 'sending',
        ),
        isEmpty,
        reason: '重新生成被打断后，前端时间线不应残留 assistant 流式占位。',
      );
      expect(
        persistedMessagesAfterInterrupt
            .any((message) => message.id == userMsg.id),
        isTrue,
        reason: '重新生成被打断后，持久历史也应保留原用户消息。',
      );

      final rawMessagesAfterInterrupt = await container
          .read(chatHistoryStoreProvider)
          .loadAllRawMessages(conv.id);
      expect(
        rawMessagesAfterInterrupt.any((message) => message.id == userMsg.id),
        isTrue,
        reason: '重新生成被打断后，后端组装上下文用的原始历史也应保留原用户消息。',
      );

      await regenerateFuture;

      final frontendMessagesAfterLateReturn =
          await _loadFrontendTimelineMessages(container, conv.id);
      final storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      expect(
        frontendMessagesAfterLateReturn.map((message) => message.id),
        storedMessages.map((message) => message.id),
        reason: '迟到结果返回后，前端仍应和持久历史保持一致。',
      );
      expect(
        storedMessages.any((message) => message.id == userMsg.id),
        isTrue,
        reason: '中断后的迟到结果不应把原用户消息再清掉。',
      );
    } finally {
      await regenerateFuture;
    }
  });

  test('regenerate 失败后，应恢复前端消息并保留原用户消息', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_regen_failure_user',
      role: 'user',
      content: '这句原话在失败后也应该保留',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_regen_failure_ai',
      role: 'assistant',
      content: '这是一条将被替换的旧回复',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen_failure_restore',
      title: 'RegenFailureRestore',
      displayName: 'RegenFailureRestore',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _ThrowAfterFirstSentenceSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    await container.read(chatActionsProvider).regenerate(aiMsg.id);

    final frontendMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    final persistedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    expect(
      frontendMessages.map((message) => message.id),
      persistedMessages.map((message) => message.id),
      reason: '重新生成失败后，前端应恢复为与持久历史一致的时间线。',
    );
    expect(
      frontendMessages.any((message) => message.id == userMsg.id),
      isTrue,
      reason: '重新生成失败后，前端仍应保留原用户消息。',
    );
    expect(
      frontendMessages.where(
        (message) => message.role == 'assistant' && message.status == 'sending',
      ),
      isEmpty,
      reason: '重新生成失败后，前端不应残留旧 assistant 的流式占位。',
    );
    expect(
      persistedMessages.any((message) => message.id == userMsg.id),
      isTrue,
      reason: '重新生成失败后，持久历史也应保留原用户消息。',
    );

    final rawMessages = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages(conv.id);
    expect(
      rawMessages.any((message) => message.id == userMsg.id),
      isTrue,
      reason: '后端组装上下文读取的原始历史，也应保留原用户消息。',
    );
  });

  test('regenerate 在模型切换提示里取消后，应恢复前端消息并保留原用户消息', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_regen_failover_cancel_user',
      role: 'user',
      content: '这句原话在点取消后也不能丢',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_regen_failover_cancel_ai',
      role: 'assistant',
      content: '旧回复',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final settings = _buildTestSettings().copyWith(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      modelList: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      allKnownModels: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      modelProviderMap: const <String, String>{
        'openai:gpt-4o-mini': 'openai',
        'gpt-4o-mini': 'openai',
        'openai:gpt-3.5-turbo': 'openai',
        'gpt-3.5-turbo': 'openai',
      },
    );
    final conv = Conversation(
      id: 'conv_regen_failover_cancel',
      title: 'RegenFailoverCancel',
      displayName: 'RegenFailoverCancel',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    _BlockingModelFailoverPromptController? failoverController;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        modelFailoverPromptProvider.overrideWith(() {
          final controller = _BlockingModelFailoverPromptController();
          failoverController = controller;
          return controller;
        }),
        chatSendServiceProvider.overrideWith(
          (ref) => _FailFirstModelStreamingSendService(
            ref,
            settings,
            failingModel: 'openai:gpt-4o-mini',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final regenerateFuture =
        container.read(chatActionsProvider).regenerate(aiMsg.id);

    ModelFailoverPromptRequest? pendingRequest;
    for (var i = 0; i < 40; i++) {
      pendingRequest = container.read(modelFailoverPromptProvider);
      if ((failoverController?.requestCalls ?? 0) > 0 &&
          pendingRequest != null) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(failoverController?.requestCalls, 1);
    expect(pendingRequest, isNotNull);

    final stopped = await container
        .read(chatActionsProvider)
        .interruptCurrentGeneration(convId: conv.id);
    expect(stopped, isTrue);

    await regenerateFuture;

    final frontendMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    final persistedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    expect(
      frontendMessages.map((message) => message.id),
      persistedMessages.map((message) => message.id),
      reason: '模型切换提示里点取消后，前端仍应恢复到与持久历史一致的时间线。',
    );
    expect(
      frontendMessages.any((message) => message.id == userMsg.id),
      isTrue,
      reason: '模型切换提示里点取消后，前端仍应保留原用户消息。',
    );
    expect(
      frontendMessages.where(
        (message) => message.role == 'assistant' && message.status == 'sending',
      ),
      isEmpty,
      reason: '模型切换提示里点取消后，不应残留 assistant 流式占位。',
    );
    expect(
      persistedMessages.any((message) => message.id == userMsg.id),
      isTrue,
      reason: '模型切换提示里点取消后，持久历史也应保留原用户消息。',
    );
    final rawMessages = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages(conv.id);
    expect(
      rawMessages.any((message) => message.id == userMsg.id),
      isTrue,
      reason: '模型切换提示里点取消后，后端上下文原始历史也应保留原用户消息。',
    );
  });

  test('send 在开启分段时，首句落位前不应把半句正文装填到占位气泡', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_sentence_gate',
      title: 'StreamSentenceGate',
      displayName: 'StreamSentenceGate',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _ChunkBoundarySentenceSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试句级装填');
    final frontendSnapshots = <List<Message>>[];
    for (var i = 0; i < 9; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 90));
      frontendSnapshots.add(
        List<Message>.from(
          await _loadFrontendTimelineMessages(container, conv.id),
        ),
      );
    }
    await sendFuture;

    final leakedPartialText = frontendSnapshots.any((snapshot) {
      return snapshot.any((message) {
        if (message.role != 'assistant' || message.status != 'sending') {
          return false;
        }
        return message.displayText.contains('这是半句') ||
            message.displayText.contains('第二句');
      });
    });

    expect(
      leakedPartialText,
      isFalse,
      reason: '分段模式下，未封口的半句正文应只留在时间线缓存后台缓冲，不能提前露到占位气泡里',
    );

    final sawFirstSentenceThenNextThinking = frontendSnapshots.any((snapshot) {
      final hasCommittedFirstSentence = snapshot.any(
        (message) =>
            message.role == 'assistant' &&
            message.status == 'sent' &&
            message.displayText.trim() == '这是半句，还没结束。',
      );
      final hasTrailingThinkingBubble = snapshot.any((message) {
        if (message.role != 'assistant' || message.status != 'sending') {
          return false;
        }
        final textBlocks = message.blocks?.whereType<TextBlock>().toList() ??
            const <TextBlock>[];
        if (textBlocks.isEmpty) return false;
        return textBlocks.first.status == BlockStatus.streaming &&
            textBlocks.first.content.trim() == '生成中...';
      });
      return hasCommittedFirstSentence && hasTrailingThinkingBubble;
    });

    expect(
      sawFirstSentenceThenNextThinking,
      isTrue,
      reason: '第一句达到分段条件后，应先把整句装填进当前气泡，再补下一个生成中占位气泡',
    );
  });

  test('send 在开启分段时，最终应持久化原始 assistant 消息，由 UI 决定分段', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_finalize',
      title: 'StreamFinalize',
      displayName: 'StreamFinalize',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings(streamSegmentDelaySeconds: 0.02);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _MultiDeltaStreamingSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.send('测试流式收尾不回退');

    final finalMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final finalAssistantMessages = finalMessages
        .where((m) => m.role == 'assistant')
        .where((m) => m.displayText.trim().isNotEmpty)
        .where((m) => m.displayText.trim() != '生成中...')
        .toList(growable: false);
    expect(finalAssistantMessages.length, 1);
    expect(
      finalAssistantMessages.map((m) => m.displayText).toList(),
      <String>['第一段。第二段。第三段。'],
    );
  });

  test('send 流式收尾后不应在数据库残留占位消息和旧文本块', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_db_cleanup',
      title: 'StreamDbCleanup',
      displayName: 'StreamDbCleanup',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings(streamSegmentDelaySeconds: 0.02);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _MultiDeltaStreamingSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final actions = container.read(chatActionsProvider);
    await actions.send('测试流式数据库清理');

    final msgRepo = container.read(messageRepositoryProvider);
    final blockRepo = container.read(messageBlockRepositoryProvider);
    final storedMessages = await msgRepo.getAllByConversationOrdered(conv.id);

    expect(
      storedMessages.where((m) => m.role == 'assistant').length,
      1,
      reason: '流式结束后正式历史只应保留一条原始 assistant 消息，不混入占位记录',
    );
    expect(
      storedMessages.where((m) => m.status == 'sending'),
      isEmpty,
      reason: '流式结束后数据库里不应残留 sending 状态消息',
    );

    final assistantRows = storedMessages
        .where((m) => m.role == 'assistant')
        .toList(growable: false);
    final storedTexts = <String>[];
    for (final row in assistantRows) {
      final assistantBlocks = await blockRepo.getByMessage(row.id);
      final textBlocks = assistantBlocks
          .map(MessageBlockConverter.fromDb)
          .whereType<TextBlock>()
          .toList(growable: false);
      if (textBlocks.isEmpty) {
        storedTexts.add(row.content);
        continue;
      }
      expect(textBlocks.length, 1, reason: 'assistant 消息不应残留重复文本块');
      expect(textBlocks.single.status, BlockStatus.success);
      storedTexts.add(textBlocks.single.content);
    }
    expect(storedTexts, <String>['第一段。第二段。第三段。']);
  });

  test('send 流式收尾后应继续复用前端时间线缓存里的文本消息 id', () async {
    final now = DateTime.now();
    final convId = 'conv_stream_text_ids_reused_${now.microsecondsSinceEpoch}';
    final conv = Conversation(
      id: convId,
      title: 'StreamTextIdsReused',
      displayName: 'StreamTextIdsReused',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          return conv;
        }),
        chatSendServiceProvider.overrideWith(
          (ref) => _SlowMultiDeltaStreamingSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试流式文本原位升级');
    List<String>? streamingTextIds;
    String? streamingPendingSourceId;
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 90));
      final frontendMessages =
          await _loadFrontendTimelineMessages(container, conv.id);
      final streamingTextMessages = frontendMessages.where((message) {
        if (message.role != 'assistant') return false;
        final sourceMessageId = message.sourceMessageId?.trim();
        if (sourceMessageId == null || sourceMessageId.isEmpty) return false;
        if (!sourceMessageId.startsWith('raw_msg_')) return false;
        final textBlocks = message.blocks?.whereType<TextBlock>().toList() ??
            const <TextBlock>[];
        if (textBlocks.length != 1) return false;
        final text = textBlocks.single.content.trim();
        return text == '第一段。' || text == '第二段。' || text == '第三段。';
      }).toList(growable: false);
      if (streamingTextMessages.length == 3) {
        final sourceMessageIds = streamingTextMessages
            .map((message) => message.sourceMessageId!.trim())
            .toSet();
        expect(
          sourceMessageIds,
          hasLength(1),
          reason:
              '同一轮流式占位的多条前端气泡必须共享一个 pending raw source id，短窗才会把它们算作 1 个 raw 槽位。',
        );
        final pendingSourceId = sourceMessageIds.single;
        streamingPendingSourceId = pendingSourceId;
        streamingTextIds = streamingTextMessages
            .map((message) => message.id)
            .toList(growable: false);
        final mappingRepo =
            container.read(messageProjectionMappingRepositoryProvider);
        expect(
          await mappingRepo.getByRawMessage(pendingSourceId),
          isEmpty,
          reason:
              '流式进行中的 pending raw source id 只应存在于 transient timeline，不应写入 projection mapping。',
        );
        break;
      }
    }
    await sendFuture;

    expect(
      streamingTextIds,
      isNotNull,
      reason: '前置条件：流式阶段应先在时间线缓存里产出 3 条文本锚点，才能验证收尾时是否原位升级',
    );
    expect(
      streamingPendingSourceId,
      isNotNull,
      reason: '流式阶段文本占位应带有共享 pending raw source id。',
    );

    final frontendAfterSend =
        await _loadFrontendTimelineMessages(container, conv.id);
    final finalizedTextMessages = frontendAfterSend.where((message) {
      if (message.role != 'assistant') return false;
      if (!(message.sourceMessageId?.trim().isNotEmpty ?? false)) return false;
      final textBlocks = message.blocks?.whereType<TextBlock>().toList() ??
          const <TextBlock>[];
      if (textBlocks.length != 1) return false;
      final text = textBlocks.single.content.trim();
      return text == '第一段。' || text == '第二段。' || text == '第三段。';
    }).toList(growable: false);

    expect(
      finalizedTextMessages
          .map((message) => message.id)
          .toList(growable: false),
      streamingTextIds,
      reason: '流式收尾后，前端时间线缓存里的文本锚点应继续沿用原 id，而不是整组删掉再换成正式消息',
    );
    final finalizedSourceMessageIds = finalizedTextMessages
        .map((message) => message.sourceMessageId!.trim())
        .toSet();
    expect(finalizedSourceMessageIds, hasLength(1));
    final finalizedRawSourceId = finalizedSourceMessageIds.single;
    expect(
      finalizedRawSourceId,
      isNot(streamingPendingSourceId),
      reason: 'commit 后前端投影必须从 pending source id 切换到真实 raw message id。',
    );
    final finalizedMappings = await container
        .read(messageProjectionMappingRepositoryProvider)
        .getByRawMessage(finalizedRawSourceId);
    expect(
      finalizedMappings.map((mapping) => mapping.projectedMessageId).toSet(),
      finalizedTextMessages.map((message) => message.id).toSet(),
      reason: 'commit 后真实 raw message id 应恢复投影映射，后续查找/删除才能回到持久 raw 语义。',
    );
    expect(
      finalizedTextMessages.every((message) => message.status == 'sent'),
      isTrue,
      reason: '原位升级后，这批文本消息只应更新为 sent，不应继续残留 sending 状态',
    );
  });

  test('send 在分段延时模式下，即使时间线缓存写入变慢也不会一次冒出多条消息', () async {
    final now = DateTime.now();
    final convId =
        'conv_stream_delay_no_backlog_burst_${now.microsecondsSinceEpoch}';
    final conv = Conversation(
      id: convId,
      title: 'StreamDelayNoBacklogBurst',
      displayName: 'StreamDelayNoBacklogBurst',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings(streamSegmentDelaySeconds: 0.08);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationTimelineCacheProvider.overrideWith(
          (ref) => _DelayedReplaceConversationTimelineCache(
            ref,
            replaceDelay: const Duration(milliseconds: 220),
          ),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _SlowMultiDeltaStreamingSendService(ref, settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试逐条 reveal');
    final revealedCounts = <int>[];
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final frontendMessages =
          await _loadFrontendTimelineMessages(container, conv.id);
      final visibleTexts = frontendMessages.where((message) {
        if (message.role != 'assistant') return false;
        final textBlocks = message.blocks?.whereType<TextBlock>().toList() ??
            const <TextBlock>[];
        if (textBlocks.length != 1) return false;
        final text = textBlocks.single.content.trim();
        if (text == '生成中...' || text.isEmpty) return false;
        return text == '第一段。' || text == '第二段。' || text == '第三段。';
      }).length;
      revealedCounts.add(visibleTexts);
    }
    await sendFuture;

    final revealedProgress = <int>[];
    for (final count in revealedCounts) {
      if (revealedProgress.isEmpty || revealedProgress.last != count) {
        revealedProgress.add(count);
      }
    }

    expect(
      revealedProgress,
      contains(1),
      reason: '即使时间线缓存写入比设计延时更慢，第一条消息也必须单独露出一次，不能直接跳到 2 条以上。',
    );
    expect(
      revealedProgress,
      contains(2),
      reason: '第二条消息也应单独经历一次 reveal，不能和第一条或第三条一起追赶式冒出。',
    );
    for (var i = 1; i < revealedProgress.length; i++) {
      expect(
        revealedProgress[i] - revealedProgress[i - 1],
        lessThanOrEqualTo(1),
        reason: '时间线缓存写入变慢时，分段 reveal 也不应追赶式一次放出多条消息。',
      );
    }
  });

  test('send 遇到 TTS 标签时，应先按语序产出 pending 语音占位并在收尾后继续复用', () async {
    final now = DateTime.now();
    final convId = 'conv_stream_tts_pending_${now.microsecondsSinceEpoch}';
    final conv = Conversation(
      id: convId,
      title: 'StreamTtsPending',
      displayName: 'StreamTtsPending',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    late _RecordingStreamTtsHandler ttsHandler;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          return conv;
        }),
        chatSendServiceProvider.overrideWith(
          (ref) => _StreamingTtsSendService(ref, settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) {
          ttsHandler = _RecordingStreamTtsHandler(ref);
          return ttsHandler;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试流式 TTS');
    final frontendSnapshots = <List<Message>>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      frontendSnapshots.add(
        List<Message>.from(
          await _loadFrontendTimelineMessages(container, conv.id),
        ),
      );
    }
    await sendFuture;

    final sawPendingAudioDuringStream = frontendSnapshots.any((snapshot) {
      for (final message in snapshot) {
        final audioBlocks = message.blocks?.whereType<AudioBlock>().toList() ??
            const <AudioBlock>[];
        if (audioBlocks.isEmpty) {
          continue;
        }
        final block = audioBlocks.first;
        if ((block.text ?? '') == '这是一段语音' &&
            block.status == BlockStatus.pending &&
            block.url.isEmpty) {
          return true;
        }
      }
      return false;
    });

    expect(
      sawPendingAudioDuringStream,
      isTrue,
      reason: '原始设计要求是先落语音占位再回填，流式阶段不应把 TTS 全部拖到收尾后才补发。',
    );

    expect(ttsHandler.lastAppendAfterStreamText, isTrue);
    expect(
      ttsHandler.lastPendingStreamTtsMessages,
      hasLength(1),
      reason: '收尾阶段应继续复用流式阶段已经出现的语音占位，而不是重新晚创建一条。',
    );
    final frontendAfterSend =
        await _loadFrontendTimelineMessages(container, conv.id);
    final frontendTextIds = frontendAfterSend
        .where((message) {
          final textBlocks = message.blocks?.whereType<TextBlock>().toList() ??
              const <TextBlock>[];
          if (textBlocks.length != 1) return false;
          final text = textBlocks.single.content.trim();
          return text == '第一句。' || text == '第二句。';
        })
        .map((message) => message.id)
        .toList(growable: false);
    final pendingAudioMessages = frontendAfterSend.where((message) {
      final audioBlock = _firstAudioBlock(message);
      return audioBlock != null &&
          (audioBlock.text ?? '') == '这是一段语音' &&
          audioBlock.status == BlockStatus.pending &&
          audioBlock.url.isEmpty;
    }).toList(growable: false);
    expect(pendingAudioMessages, hasLength(1));
    expect(
      pendingAudioMessages.single.id,
      ttsHandler.lastPendingStreamTtsMessages.single.id,
      reason: '录制型 handler 不做真实回填时，前端时间线缓存里应继续保留同一条流式语音占位。',
    );
    expect(
      ttsHandler.lastStreamTextMessageIds,
      frontendTextIds,
      reason: '后补锚点必须使用最终时间线里真实存在的文本消息 id，不能再把 buildResult 的新 id 传下去。',
    );
  });

  test('send 遇到前置 TTS 标签时，应允许语音占位先于后续正文按语序出现', () async {
    final now = DateTime.now();
    final convId =
        'conv_stream_leading_tts_anchor_first_${now.microsecondsSinceEpoch}';
    final conv = Conversation(
      id: convId,
      title: 'StreamLeadingTtsAnchorFirst',
      displayName: 'StreamLeadingTtsAnchorFirst',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    late _RecordingStreamTtsHandler ttsHandler;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          return conv;
        }),
        chatSendServiceProvider.overrideWith(
          (ref) => _StreamingLeadingTtsSendService(ref, settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) {
          ttsHandler = _RecordingStreamTtsHandler(ref);
          return ttsHandler;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试前置流式 TTS');
    final frontendSnapshots = <List<Message>>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      frontendSnapshots.add(
        List<Message>.from(
          await _loadFrontendTimelineMessages(container, conv.id),
        ),
      );
    }
    await sendFuture;

    final sawPendingAudioBeforeText = frontendSnapshots.any((snapshot) {
      var hasAssistantText = false;
      var hasPendingAudio = false;
      for (final message in snapshot) {
        if (message.role == 'assistant' && message.displayText == '后续正文。') {
          hasAssistantText = true;
        }
        final audioBlocks = message.blocks?.whereType<AudioBlock>().toList() ??
            const <AudioBlock>[];
        if (audioBlocks.isNotEmpty) {
          final block = audioBlocks.first;
          if ((block.text ?? '') == '这是一段语音' &&
              block.status == BlockStatus.pending &&
              block.url.isEmpty) {
            hasPendingAudio = true;
          }
        }
      }
      return hasPendingAudio && !hasAssistantText;
    });

    expect(
      sawPendingAudioBeforeText,
      isTrue,
      reason: '当前轮如果本来就是 `<tts>` 在前，语音占位就应该先于后续正文出现，保持原始语序。',
    );

    final frontendAfterSend =
        await _loadFrontendTimelineMessages(container, conv.id);
    final pendingAudioMessages = frontendAfterSend.where((message) {
      final audioBlock = _firstAudioBlock(message);
      return audioBlock != null &&
          (audioBlock.text ?? '') == '这是一段语音' &&
          audioBlock.status == BlockStatus.pending &&
          audioBlock.url.isEmpty;
    }).toList(growable: false);
    final textIndex = frontendAfterSend.indexWhere(
      (message) =>
          message.role == 'assistant' && message.displayText == '后续正文。',
    );
    final pendingIndex = frontendAfterSend.indexWhere(
      (message) =>
          pendingAudioMessages.any((pending) => pending.id == message.id),
    );

    expect(textIndex, greaterThanOrEqualTo(0));
    expect(pendingAudioMessages, hasLength(1));
    expect(pendingIndex, greaterThanOrEqualTo(0));
    expect(pendingIndex, lessThan(textIndex));
    expect(ttsHandler.lastAppendAfterStreamText, isTrue);
    expect(
      ttsHandler.lastPendingStreamTtsMessages,
      hasLength(1),
      reason: '前置 TTS 场景也应沿用流式阶段已经创建好的 pending 占位。',
    );
    expect(
      pendingAudioMessages.single.id,
      ttsHandler.lastPendingStreamTtsMessages.single.id,
      reason: '录制型 handler 下，收尾后应保留同一条前置语音占位，而不是再新建一条。',
    );
  });

  test('send 收尾后应原位补齐已有流式语音占位，不再重插新消息', () async {
    final now = DateTime.now();
    final convId =
        'conv_stream_tts_in_place_fill_${now.microsecondsSinceEpoch}';
    final conv = Conversation(
      id: convId,
      title: 'StreamTtsInPlaceFill',
      displayName: 'StreamTtsInPlaceFill',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '这是一段语音': Duration(milliseconds: 120),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          return conv;
        }),
        chatSendServiceProvider.overrideWith(
          (ref) => _StreamingTtsSendService(ref, settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试语音原位补齐');
    String? placeholderId;
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final frontendMessages =
          await _loadFrontendTimelineMessages(container, conv.id);
      for (final message in frontendMessages) {
        final audioBlock = _firstAudioBlock(message);
        if (audioBlock == null) continue;
        if ((audioBlock.text ?? '') == '这是一段语音' &&
            audioBlock.status == BlockStatus.pending &&
            audioBlock.url.isEmpty) {
          placeholderId = message.id;
          break;
        }
      }
      if (placeholderId != null) {
        break;
      }
    }
    await sendFuture;

    expect(
      placeholderId,
      isNotNull,
      reason: '流式阶段应先在前端时间线缓存里产出一条 pending 语音占位，才能覆盖原位补齐场景',
    );

    var frontendMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    final audioMessagesAfterCommit = frontendMessages.where((message) {
      final audioBlock = _firstAudioBlock(message);
      return audioBlock != null &&
          (audioBlock.text ?? '') == '这是一段语音';
    }).toList();
    expect(
      audioMessagesAfterCommit.length,
      1,
      reason: '流式收尾后，应继续复用原来的语音占位，而不是立刻删掉再重插一条',
    );
    final retainedPendingId = audioMessagesAfterCommit.single.id;
    expect(retainedPendingId, placeholderId);
    final handler = container.read(chatTtsHandlerProvider);
    await handler.debugWaitForBackgroundTasks();

    frontendMessages = await _loadFrontendTimelineMessages(container, conv.id);
    final filledMessage = frontendMessages.firstWhere(
      (message) => message.id == retainedPendingId,
    );
    final filledAudio = filledMessage.blocks!.whereType<AudioBlock>().single;
    expect(filledAudio.status, BlockStatus.success);
    expect(filledAudio.url, isNotEmpty);
    expect(
      frontendMessages
          .where((message) {
            final audioBlock = _firstAudioBlock(message);
            return audioBlock != null && (audioBlock.text ?? '') == '这是一段语音';
          })
          .map((message) => message.id)
          .toList(growable: false),
      <String>[retainedPendingId],
      reason: 'TTS 完成后，应由同一条消息原位补齐，不应留下旧占位或新增副本',
    );
  });

  test('流式回复中语音若先返回，应在流中原位置为 success 可播放，且后续流式 delta 不被重置为 pending', () async {
    final now = DateTime.now();
    final convId =
        'conv_stream_tts_mid_resolve_${now.microsecondsSinceEpoch}';
    final conv = Conversation(
      id: convId,
      title: 'StreamTtsMidResolve',
      displayName: 'StreamTtsMidResolve',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    // 真机连接会开启外键；测试也必须拒绝引用尚未落库的 raw 消息。
    await db.customStatement('PRAGMA foreign_keys = ON');

    // 保留真实 TtsService 请求构造与响应解析，仅在 HTTP 边界拦截外网。
    final ttsService = TtsService(
      config: TtsConfig(enabled: true),
      requestUrl: 'https://example.com/v1/audio/speech',
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);
    final ttsTagClosed = Completer<void>();
    final releaseTail = Completer<void>();
    addTearDown(() {
      if (!releaseTail.isCompleted) releaseTail.complete();
    });

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) => conv),
        chatSendServiceProvider.overrideWith(
          (ref) => _SlowTailStreamingTtsSendService(
            ref,
            settings,
            ttsTagClosed: ttsTagClosed,
            releaseTail: releaseTail,
            longTailText: List.filled(800, '后续正文还在继续生成。').join(),
          ),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);

    final requestedTexts = <String>[];
    final client = MockClient((request) async {
      expect(releaseTail.isCompleted, isFalse,
          reason: 'TTS HTTP 请求必须在模型流结束前发出');
      expect(request.method, 'POST');
      requestedTexts.add(
        (jsonDecode(request.body) as Map<String, dynamic>)['input'] as String,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      return http.Response.bytes(
        <int>[0x49, 0x44, 0x33, 0],
        200,
        headers: const {'content-type': 'audio/mpeg'},
      );
    });
    addTearDown(client.close);
    final sendFuture = http.runWithClient(
      () => container.read(chatActionsProvider).send('测试流中语音提前就绪'),
      () => client,
    );
    addTearDown(() async {
      if (!releaseTail.isCompleted) releaseTail.complete();
      await sendFuture;
    });
    var sendCompleted = false;
    unawaited(sendFuture.then<void>(
      (_) => sendCompleted = true,
      onError: (Object _, StackTrace __) => sendCompleted = true,
    ));
    await ttsTagClosed.future.timeout(const Duration(seconds: 2));

    Message? playableDuringStream;
    for (var i = 0; i < 20 && playableDuringStream == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final messages = await _loadFrontendTimelineMessages(container, conv.id);
      for (final message in messages) {
        final audio = _firstAudioBlock(message);
        if (audio != null &&
            (audio.text ?? '') == '流中语音' &&
            audio.status == BlockStatus.success &&
            audio.url.isNotEmpty) {
          playableDuringStream = message;
          break;
        }
      }
    }
    expect(playableDuringStream, isNotNull);
    expect(requestedTexts, <String>['流中语音']);
    expect(
      await (db.select(db.messageProjectionMappings)
            ..where((row) => row.rawMessageId
                .equals(playableDuringStream!.sourceMessageId!)))
          .get(),
      isEmpty,
      reason: '流中只能更新瞬态缓存，不得提前为未落库 raw 写投影映射',
    );
    expect(
      sendCompleted,
      isFalse,
      reason: '模型尾部仍被闩锁时，语音必须已经可播放，不能等整段文字结束',
    );

    releaseTail.complete();
    await sendFuture;

    // 后续文字 delta 与最终收尾都不能把 success 冲回 pending，也不能重复合成。
    final finalMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    final finalAudios = finalMessages
        .where((m) => (_firstAudioBlock(m)?.text ?? '') == '流中语音')
        .toList();
    expect(finalAudios, hasLength(1));
    final finalAudioBlock = _firstAudioBlock(finalAudios.single)!;
    expect(finalAudioBlock.status, BlockStatus.success);
    expect(finalAudioBlock.url, startsWith('data:audio/mpeg;base64,'));
    expect(requestedTexts, <String>['流中语音']);
    final persistedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final persistedAudio = persistedMessages
        .expand((message) =>
            message.blocks?.whereType<AudioBlock>() ?? const <AudioBlock>[])
        .single;
    expect(persistedAudio.url, finalAudioBlock.url);
    expect(persistedAudio.status, BlockStatus.success);
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test('流中 TTS 若在文字收尾后才返回，应沿用同一次转换并持久化原占位', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_tts_late_handoff_${now.microsecondsSinceEpoch}',
      title: 'StreamTtsLateHandoff',
      displayName: 'StreamTtsLateHandoff',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '流中语音': Duration(milliseconds: 500),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) => conv),
        chatSendServiceProvider.overrideWith(
          (ref) => _SlowTailStreamingTtsSendService(ref, settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    await container.read(chatActionsProvider).send('测试流末 TTS 交接');

    Message? resolved;
    for (var i = 0; i < 20 && resolved == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final messages = await _loadFrontendTimelineMessages(container, conv.id);
      for (final message in messages) {
        final audio = _firstAudioBlock(message);
        if (audio != null &&
            (audio.text ?? '') == '流中语音' &&
            audio.status == BlockStatus.success &&
            audio.url.isNotEmpty) {
          resolved = message;
          break;
        }
      }
    }

    expect(resolved, isNotNull);
    expect(ttsService.startedTexts, <String>['流中语音']);
    final persisted = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final persistedAudio = persisted
        .where((message) => (_firstAudioBlock(message)?.text ?? '') == '流中语音')
        .toList(growable: false);
    expect(persistedAudio, hasLength(1));
    expect(_firstAudioBlock(persistedAudio.single)!.status, BlockStatus.success);
    expect(_firstAudioBlock(persistedAudio.single)!.url, isNotEmpty);
  });

  test('流式收尾后删除原回复，迟到的 TTS 结果不应复活已删语音', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_tts_deleted_after_commit_${now.microsecondsSinceEpoch}',
      title: 'StreamTtsDeletedAfterCommit',
      displayName: 'StreamTtsDeletedAfterCommit',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final releaseTts = Completer<void>();
    addTearDown(() {
      if (!releaseTts.isCompleted) releaseTts.complete();
    });
    final ttsService = _TrackingDelayedTtsService(
      blockers: <String, Completer<void>>{'流中语音': releaseTts},
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) => conv),
        chatSendServiceProvider.overrideWith(
          (ref) => _SlowTailStreamingTtsSendService(ref, settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    await container.read(chatActionsProvider).send('测试收尾后删除的迟到 TTS');
    expect(ttsService.startedTexts, <String>['流中语音']);

    final historyStore = container.read(chatHistoryStoreProvider);
    final rawAssistant = (await historyStore.loadAllRawMessages(conv.id))
        .lastWhere((message) => message.role == 'assistant');
    final pendingMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    final pendingAudio = pendingMessages.singleWhere(
      (message) => (_firstAudioBlock(message)?.text ?? '') == '流中语音',
    );

    await historyStore.softDeleteMessages(conv.id, <String>[rawAssistant.id]);
    releaseTts.complete();
    for (var i = 0; i < 20 && ttsService.activeCount > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final afterLateResult =
        await _loadFrontendTimelineMessages(container, conv.id);
    expect(
      afterLateResult.any(
        (message) =>
            message.id == pendingAudio.id ||
            message.sourceMessageId == rawAssistant.id,
      ),
      isFalse,
    );
    expect(ttsService.startedTexts, <String>['流中语音']);
  });

  test('中断流式回复后，迟到的 TTS 结果不应复活已清理的语音占位', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_tts_interrupt_${now.microsecondsSinceEpoch}',
      title: 'StreamTtsInterrupt',
      displayName: 'StreamTtsInterrupt',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '流中语音': Duration(milliseconds: 180),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);
    final ttsTagClosed = Completer<void>();
    final releaseTail = Completer<void>();
    addTearDown(() {
      if (!releaseTail.isCompleted) releaseTail.complete();
    });
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) => conv),
        chatSendServiceProvider.overrideWith(
          (ref) => _SlowTailStreamingTtsSendService(
            ref,
            settings,
            ttsTagClosed: ttsTagClosed,
            releaseTail: releaseTail,
          ),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final actions = container.read(chatActionsProvider);
    final sendFuture = actions.send('测试中断后迟到 TTS');
    await ttsTagClosed.future.timeout(const Duration(seconds: 2));
    for (var i = 0; i < 20 && ttsService.startedTexts.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ttsService.startedTexts, <String>['流中语音']);
    expect(await actions.interruptCurrentGeneration(convId: conv.id), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 260));

    final afterLateResult =
        await _loadFrontendTimelineMessages(container, conv.id);
    expect(
      afterLateResult
          .where((message) => (_firstAudioBlock(message)?.text ?? '') == '流中语音'),
      isEmpty,
    );
    releaseTail.complete();
    await sendFuture;
    expect(ttsService.startedTexts, <String>['流中语音']);
  });

  test('流中 TTS 失败回退文本后，后续 delta 不应重建占位或再次转换', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_tts_fallback_${now.microsecondsSinceEpoch}',
      title: 'StreamTtsFallback',
      displayName: 'StreamTtsFallback',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '流中语音': Duration(milliseconds: 30),
      },
      failingTexts: const <String>{'流中语音'},
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);
    final ttsTagClosed = Completer<void>();
    final releaseTail = Completer<void>();
    addTearDown(() {
      if (!releaseTail.isCompleted) releaseTail.complete();
    });
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) => conv),
        chatSendServiceProvider.overrideWith(
          (ref) => _SlowTailStreamingTtsSendService(
            ref,
            settings,
            ttsTagClosed: ttsTagClosed,
            releaseTail: releaseTail,
          ),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    await db.customStatement('PRAGMA foreign_keys = ON');
    final sendFuture = container.read(chatActionsProvider).send('测试流中 TTS 回退');
    await ttsTagClosed.future.timeout(const Duration(seconds: 2));
    var sawFallbackText = false;
    for (var i = 0; i < 20 && !sawFallbackText; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final messages = await _loadFrontendTimelineMessages(container, conv.id);
      sawFallbackText = messages.any(
        (message) =>
            message.displayText == '流中语音' &&
            _firstAudioBlock(message) == null,
      );
    }
    expect(sawFallbackText, isTrue);

    releaseTail.complete();
    await sendFuture;
    final finalMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    expect(
      finalMessages
          .where((message) => (_firstAudioBlock(message)?.text ?? '') == '流中语音'),
      isEmpty,
    );
    expect(
      finalMessages.where((message) => message.displayText == '流中语音'),
      hasLength(1),
    );
    expect(ttsService.startedTexts, <String>['流中语音']);
  });

  test('流中 TTS 失败后，表情应保持在回退文本与后续正文之间', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_tts_fallback_sticker_${now.microsecondsSinceEpoch}',
      title: 'StreamTtsFallbackSticker',
      displayName: 'StreamTtsFallbackSticker',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '流中语音': Duration(milliseconds: 30),
      },
      failingTexts: const <String>{'流中语音'},
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) => conv),
        chatSendServiceProvider.overrideWith(
          (ref) => _SlowTailStreamingTtsSendService(
            ref,
            settings,
            includeStickerAfterTts: true,
          ),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    await container.read(chatActionsProvider).send('测试 TTS 回退与表情顺序');
    final finalMessages =
        await _loadFrontendTimelineMessages(container, conv.id);
    final fallbackIndex = finalMessages.indexWhere(
      (message) =>
          message.displayText == '流中语音' &&
          _firstAudioBlock(message) == null,
    );
    final stickerIndex = finalMessages.indexWhere(
      (message) => message.blocks?.whereType<EmojiBlock>().isNotEmpty ?? false,
    );
    final tailTextIndex = finalMessages.indexWhere(
      (message) => message.displayText.contains('第二句很长很长的文本'),
    );

    expect(fallbackIndex, greaterThanOrEqualTo(0));
    expect(stickerIndex, greaterThan(fallbackIndex));
    expect(tailTextIndex, greaterThan(stickerIndex));
    expect(ttsService.startedTexts, <String>['流中语音']);
  });

  test('deliverSegmentedMessages 在流式后补时，多个 TTS 占位会并发启动转换', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_parallel_tts',
      title: 'ParallelTts',
      displayName: 'ParallelTts',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final anchor = Message(
      id: 'stream_text_anchor',
      role: 'assistant',
      content: '前置文本。',
      createdAt: now,
      status: 'sent',
    );
    final pendingOne = Message.fromBlocks(
      id: 'pending_tts_one',
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: 'pending_tts_one',
          url: '',
          text: '语音一',
          status: BlockStatus.pending,
        ),
      ],
      createdAt: now.add(const Duration(milliseconds: 1)),
      status: 'sending',
    );
    final pendingTwo = Message.fromBlocks(
      id: 'pending_tts_two',
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: 'pending_tts_two',
          url: '',
          text: '语音二',
          status: BlockStatus.pending,
        ),
      ],
      createdAt: now.add(const Duration(milliseconds: 2)),
      status: 'sending',
    );
    await _insertMessage(db, conv.id, anchor);
    await _insertMessageWithBlocks(db, conv.id, pendingOne);
    await _insertMessageWithBlocks(db, conv.id, pendingTwo);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '语音一': Duration(milliseconds: 180),
        '语音二': Duration(milliseconds: 180),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);

    final handler = container.read(chatTtsHandlerProvider);
    await handler.deliverSegmentedMessages(
      convId: conv.id,
      userMsgId: 'user_parallel_tts',
      buildResult: const AssistantMessageBuildResult(
        messages: <Message>[],
        lastMessageText: '',
      ),
      replyText: '前置文本。<tts>语音一</tts><tts>语音二</tts>',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: const <String, dynamic>{
            'text': '语音一',
            'originalText': '语音一',
          },
          id: 'evt_parallel_tts_1',
        ),
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: const <String, dynamic>{
            'text': '语音二',
            'originalText': '语音二',
          },
          id: 'evt_parallel_tts_2',
        ),
      ],
      ttsEnabled: true,
      appendAfterStreamText: true,
      streamTextMessageIds: const <String>['stream_text_anchor'],
      streamPendingTtsMessages: <Message>[pendingOne, pendingTwo],
    );

    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(
      ttsService.startedTexts,
      containsAll(<String>['语音一', '语音二']),
      reason: '后补阶段拿到多个独立 TTS 占位后，应立即并发提交转换',
    );
    expect(
      ttsService.maxConcurrent,
      greaterThanOrEqualTo(2),
      reason: '多个 TTS 占位不应被 ChatTtsHandler 顺序 await 卡成串行',
    );

    await handler.debugWaitForBackgroundTasks();

    final storedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final audioBlocks = storedMessages
        .where((m) => m.id == 'pending_tts_one' || m.id == 'pending_tts_two')
        .map((m) => m.blocks!.whereType<AudioBlock>().single)
        .toList(growable: false);
    expect(audioBlocks, hasLength(2));
    expect(audioBlocks.every((block) => block.status == BlockStatus.success),
        isTrue);
    expect(audioBlocks.every((block) => block.url.isNotEmpty), isTrue);
  });

  test('deliverSegmentedMessages 在流式后补时，图片生成不会阻塞 TTS 占位更新', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_tts_image_parallel',
      title: 'TtsImageParallel',
      displayName: 'TtsImageParallel',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings =
        _buildTestSettings().copyWith(imageGenerationEnabled: true);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final firstText = Message(
      id: 'stream_text_first',
      role: 'assistant',
      content: '第一句。',
      createdAt: now,
      status: 'sent',
    );
    final pendingTts = Message.fromBlocks(
      id: 'stream_pending_tts',
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: 'stream_pending_tts',
          url: '',
          text: '语音先更新',
          status: BlockStatus.pending,
        ),
      ],
      createdAt: now.add(const Duration(milliseconds: 1)),
      status: 'sending',
    );
    final secondText = Message(
      id: 'stream_text_second',
      role: 'assistant',
      content: '第二句。',
      createdAt: now.add(const Duration(milliseconds: 2)),
      status: 'sent',
    );
    await _insertMessage(db, conv.id, firstText);
    await _insertMessageWithBlocks(db, conv.id, pendingTts);
    await _insertMessage(db, conv.id, secondText);

    final tempDir =
        await Directory.systemTemp.createTemp('aicove_tts_image_parallel');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final imageFile = File('${tempDir.path}\\parallel.png');
    await imageFile.writeAsBytes(const <int>[1, 2, 3, 4]);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '语音先更新': Duration(milliseconds: 70),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);

    late _DelayedInlineImagePlugin imagePlugin;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
        pluginManagerProvider.overrideWith((ref) {
          final manager = PluginManager();
          imagePlugin = _DelayedInlineImagePlugin(
            delay: const Duration(milliseconds: 240),
            localPath: imageFile.path,
            ref: ref,
          );
          manager.register(imagePlugin);
          return manager;
        }),
      ],
    );
    addTearDown(container.dispose);

    final handler = container.read(chatTtsHandlerProvider);
    await handler.deliverSegmentedMessages(
      convId: conv.id,
      userMsgId: 'user_tts_image_parallel',
      buildResult: const AssistantMessageBuildResult(
        messages: <Message>[],
        lastMessageText: '',
      ),
      replyText: '第一句。<tts>语音先更新</tts><image>sunset beach</image>第二句。',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: const <String, dynamic>{
            'text': '语音先更新',
            'originalText': '语音先更新',
          },
          id: 'evt_parallel_tts_image_tts',
        ),
        PluginEvent(
          pluginId: 'image',
          type: 'image_generate',
          data: const <String, dynamic>{
            'prompt': 'sunset beach',
          },
          id: 'evt_parallel_tts_image_image',
        ),
      ],
      ttsEnabled: true,
      appendAfterStreamText: true,
      streamTextMessageIds: const <String>[
        'stream_text_first',
        'stream_text_second',
      ],
      streamPendingTtsMessages: <Message>[pendingTts],
    );

    var storedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    expect(
      storedMessages.any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
      isFalse,
      reason: '后补任务改成后台后，deliverSegmentedMessages 返回时慢图片不应已完成',
    );

    await handler.debugWaitForBackgroundTasks(
        labelPrefix: 'pending_stream_tts');

    storedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final updatedTts = storedMessages
        .firstWhere((message) => message.id == 'stream_pending_tts')
        .blocks!
        .whereType<AudioBlock>()
        .single;
    expect(updatedTts.status, BlockStatus.success);
    expect(updatedTts.url, isNotEmpty);
    expect(
      storedMessages.any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
      isFalse,
      reason: 'TTS 应该先独立完成，不该继续等待慢图片任务',
    );

    await handler.debugWaitForBackgroundTasks();

    storedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    expect(
      storedMessages.any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
      isTrue,
    );
    expect(imagePlugin.prompts, <String>['sunset beach']);
  });

  test('send 遇到快速生图标签时，不应把 <image> 提示词流式展示或落库给用户', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_inline_image_hidden',
      title: 'StreamInlineImageHidden',
      displayName: 'StreamInlineImageHidden',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _StreamingInlineImageSendService(ref, settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) {
          return _DeliverBuildResultOnlyChatTtsHandler(ref);
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试快速生图流式隐藏');
    final frontendSnapshots = <List<Message>>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      frontendSnapshots.add(
        List<Message>.from(
          await _loadFrontendTimelineMessages(container, conv.id),
        ),
      );
    }
    await sendFuture;

    final leakedInTransient = frontendSnapshots.any((snapshot) {
      return snapshot.any((message) {
        final text = message.displayText;
        return text.contains('<image>') || text.contains('cat ears');
      });
    });
    expect(
      leakedInTransient,
      isFalse,
      reason: '快速生图 prompt 只应留在后台处理链路里，不应出现在流式可见文本里',
    );

    final storedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final assistantMessages = storedMessages
        .where((message) => message.role == 'assistant')
        .toList(growable: false);
    final storedTexts = assistantMessages
        .map((message) => message.displayText.trim())
        .where((text) => text.isNotEmpty)
        .toList(growable: false);

    expect(storedTexts, <String>['第一句。第二句。']);
    expect(
      storedTexts.join('\n'),
      isNot(contains('masterpiece')),
      reason: '最终落库正文里不应残留 <image> 标签内的正向提示词',
    );
  });

  test('send 遇到带属性的 image 标签时，不应被当成 inline 生图标签吞掉', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_image_attr_visible',
      title: 'StreamImageAttrVisible',
      displayName: 'StreamImageAttrVisible',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _StreamingAttributeImageTagSendService(ref, settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) {
          return _DeliverBuildResultOnlyChatTtsHandler(ref);
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final sendFuture =
        container.read(chatActionsProvider).send('测试属性 image 标签');
    final frontendSnapshots = <List<Message>>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      frontendSnapshots.add(
        List<Message>.from(
          await _loadFrontendTimelineMessages(container, conv.id),
        ),
      );
    }
    await sendFuture;

    final sawAttributeTagInTransient = frontendSnapshots.any((snapshot) {
      return snapshot.any((message) => message.displayText.contains(
            '<image source="history">保留这段</image>',
          ));
    });
    expect(
      sawAttributeTagInTransient,
      isTrue,
      reason: '带属性的 image 标签不应再被宽匹配吞掉',
    );

    final storedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final storedTexts = storedMessages
        .where((message) => message.role == 'assistant')
        .map((message) => message.displayText.trim())
        .where((text) => text.isNotEmpty)
        .toList(growable: false);
    expect(
      storedTexts,
      <String>['第一句。<image source="history">保留这段</image>第二句。'],
    );
  });

  test('后补图片应谁先生成谁先发送，不必等待更慢的图片一起完成', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_post_stream_images_independent',
      title: 'PostStreamImagesIndependent',
      displayName: 'PostStreamImagesIndependent',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings =
        _buildTestSettings().copyWith(imageGenerationEnabled: true);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final firstText = Message(
      id: 'stream_text_first_independent',
      role: 'assistant',
      content: '第一句。',
      createdAt: now,
      status: 'sent',
    );
    final secondText = Message(
      id: 'stream_text_second_independent',
      role: 'assistant',
      content: '第二句。',
      createdAt: now.add(const Duration(milliseconds: 1)),
      status: 'sent',
    );
    final thirdText = Message(
      id: 'stream_text_third_independent',
      role: 'assistant',
      content: '第三句。',
      createdAt: now.add(const Duration(milliseconds: 2)),
      status: 'sent',
    );
    await _insertMessage(db, conv.id, firstText);
    await _insertMessage(db, conv.id, secondText);
    await _insertMessage(db, conv.id, thirdText);

    final tempDir = await Directory.systemTemp
        .createTemp('aicove_post_stream_images_independent');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final slowImageFile = File('${tempDir.path}\\slow.png');
    final fastImageFile = File('${tempDir.path}\\fast.png');
    await slowImageFile.writeAsBytes(const <int>[1, 2, 3, 4]);
    await fastImageFile.writeAsBytes(const <int>[5, 6, 7, 8]);

    late _DelayedInlineImagePlugin imagePlugin;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        pluginManagerProvider.overrideWith((ref) {
          final manager = PluginManager();
          imagePlugin = _DelayedInlineImagePlugin(
            delay: const Duration(milliseconds: 220),
            localPath: slowImageFile.path,
            delaysByPrompt: const <String, Duration>{
              'slow landscape': Duration(milliseconds: 220),
              'fast portrait': Duration(milliseconds: 70),
            },
            localPathByPrompt: <String, String>{
              'slow landscape': slowImageFile.path,
              'fast portrait': fastImageFile.path,
            },
            ref: ref,
          );
          manager.register(imagePlugin);
          return manager;
        }),
      ],
    );
    addTearDown(container.dispose);

    final handler = container.read(chatTtsHandlerProvider);
    try {
      await handler.deliverSegmentedMessages(
        convId: conv.id,
        userMsgId: 'user_post_stream_images_independent',
        buildResult: const AssistantMessageBuildResult(
          messages: <Message>[],
          lastMessageText: '',
        ),
        replyText:
            '第一句。<image>slow landscape</image>第二句。<image>fast portrait</image>第三句。',
        pluginEvents: <PluginEvent>[
          PluginEvent(
            pluginId: 'image',
            type: 'image_generate',
            data: const <String, dynamic>{
              'prompt': 'slow landscape',
            },
            id: 'evt_post_stream_image_slow',
          ),
          PluginEvent(
            pluginId: 'image',
            type: 'image_generate',
            data: const <String, dynamic>{
              'prompt': 'fast portrait',
            },
            id: 'evt_post_stream_image_fast',
          ),
        ],
        ttsEnabled: false,
        appendAfterStreamText: true,
        streamTextMessageIds: const <String>[
          'stream_text_first_independent',
          'stream_text_second_independent',
          'stream_text_third_independent',
        ],
      );

      await Future<void>.delayed(const Duration(milliseconds: 40));

      var storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      expect(
        _collectGeneratingPlaceholderMessages(storedMessages),
        isEmpty,
        reason: '图片后补不再创建占位消息，慢图阶段也不应额外占一个消息位',
      );
      expect(
        storedMessages.any(
          (message) => message.blocks?.any((b) => b is ImageBlock) ?? false,
        ),
        isFalse,
      );

      await Future<void>.delayed(const Duration(milliseconds: 120));

      storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      final imageBlocks = storedMessages
          .where(
              (message) => message.blocks?.any((b) => b is ImageBlock) ?? false)
          .map((message) => message.blocks!.whereType<ImageBlock>().single)
          .toList(growable: false);
      expect(imageBlocks, hasLength(1));
      expect(imageBlocks.single.prompt, 'fast portrait');
      expect(_collectGeneratingPlaceholderMessages(storedMessages), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 180));

      storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      final finalImagePrompts = storedMessages
          .where(
              (message) => message.blocks?.any((b) => b is ImageBlock) ?? false)
          .map((message) =>
              message.blocks!.whereType<ImageBlock>().single.prompt)
          .toList(growable: false);
      expect(finalImagePrompts,
          containsAll(<String>['slow landscape', 'fast portrait']));
      expect(imagePlugin.prompts, <String>['slow landscape', 'fast portrait']);
      expect(_collectGeneratingPlaceholderMessages(storedMessages), isEmpty);
    } finally {
      await handler.debugWaitForBackgroundTasks(labelPrefix: 'deferred_image_');
    }
  });

  test('后补图片接管占位时，不应先清空临时层再等待稳定时间线补位', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_post_stream_image_handoff',
      title: 'PostStreamImageHandoff',
      displayName: 'PostStreamImageHandoff',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings =
        _buildTestSettings().copyWith(imageGenerationEnabled: true);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final anchor = Message(
      id: 'stream_text_handoff_anchor',
      role: 'assistant',
      content: '前置正文。',
      createdAt: now,
      status: 'sent',
    );
    await _insertMessage(db, conv.id, anchor);

    final tempDir =
        await Directory.systemTemp.createTemp('aicove_post_stream_handoff');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final imageFile = File('${tempDir.path}\\handoff.png');
    await imageFile.writeAsBytes(const <int>[1, 2, 3, 4]);

    late _DelayedInlineImagePlugin imagePlugin;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        conversationTimelineCacheProvider.overrideWith(
          (ref) => _DelayedWatchConversationTimelineCache(
            ref,
            windowDelay: const Duration(milliseconds: 90),
          ),
        ),
        pluginManagerProvider.overrideWith((ref) {
          final manager = PluginManager();
          imagePlugin = _DelayedInlineImagePlugin(
            delay: const Duration(milliseconds: 70),
            localPath: imageFile.path,
            ref: ref,
          );
          manager.register(imagePlugin);
          return manager;
        }),
      ],
    );
    addTearDown(container.dispose);

    final stableMessagesSub = container.listen(
      conversationMessagesProvider(conv.id),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(stableMessagesSub.close);

    final handler = container.read(chatTtsHandlerProvider);
    try {
      await handler.deliverSegmentedMessages(
        convId: conv.id,
        userMsgId: 'user_post_stream_image_handoff',
        buildResult: const AssistantMessageBuildResult(
          messages: <Message>[],
          lastMessageText: '',
        ),
        replyText: '前置正文。<image>handoff portrait</image>',
        pluginEvents: <PluginEvent>[
          PluginEvent(
            pluginId: 'image',
            type: 'image_generate',
            data: const <String, dynamic>{
              'prompt': 'handoff portrait',
            },
            id: 'evt_post_stream_image_handoff',
          ),
        ],
        ttsEnabled: false,
        appendAfterStreamText: true,
        streamTextMessageIds: const <String>['stream_text_handoff_anchor'],
      );

      var sawStableImage = false;
      var sawStableAnchor = false;
      var sawEmptyGap = false;
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final stableMessages =
            container.read(conversationMessagesProvider(conv.id)).valueOrNull ??
                const <Message>[];
        final hasStableAnchor = stableMessages.any(
          (message) => message.id == 'stream_text_handoff_anchor',
        );
        final hasStableImage = stableMessages.any(
          (message) =>
              message.blocks?.any((block) => block is ImageBlock) ?? false,
        );
        if (hasStableAnchor) {
          sawStableAnchor = true;
        }
        if (hasStableImage) {
          sawStableImage = true;
        }
        if (sawStableAnchor && !sawStableImage && !hasStableAnchor) {
          sawEmptyGap = true;
        }
      }

      expect(
        sawEmptyGap,
        isFalse,
        reason: '图片后补改成直出最终图后，原文本锚点也不应先消失再等待最终图片补位',
      );

      await handler.debugWaitForBackgroundTasks(labelPrefix: 'deferred_image_');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final finalStableMessages =
          container.read(conversationMessagesProvider(conv.id)).valueOrNull ??
              const <Message>[];
      expect(
        _collectGeneratingPlaceholderMessages(finalStableMessages),
        isEmpty,
        reason: '图片升级为最终态后，不应继续残留生成中占位',
      );
      expect(imagePlugin.prompts, <String>['handoff portrait']);
    } finally {
      await handler.debugWaitForBackgroundTasks(labelPrefix: 'deferred_image_');
    }
  });

  test('非流式混排遇到 TTS 和慢图时，应先发语音占位与后续文本，图片完成后再直出最终图', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_non_stream_mixed_tts_image',
      title: 'NonStreamMixedTtsImage',
      displayName: 'NonStreamMixedTtsImage',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings =
        _buildTestSettings().copyWith(imageGenerationEnabled: true);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final tempDir =
        await Directory.systemTemp.createTemp('aicove_non_stream_mixed_tts');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final imageFile = File('${tempDir.path}\\mixed.png');
    await imageFile.writeAsBytes(const <int>[1, 2, 3, 4]);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '语音段': Duration(milliseconds: 70),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);

    late _DelayedInlineImagePlugin imagePlugin;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
        pluginManagerProvider.overrideWith((ref) {
          final manager = PluginManager();
          imagePlugin = _DelayedInlineImagePlugin(
            delay: const Duration(milliseconds: 260),
            localPath: imageFile.path,
            ref: ref,
          );
          manager.register(imagePlugin);
          return manager;
        }),
      ],
    );
    addTearDown(container.dispose);

    final handler = container.read(chatTtsHandlerProvider);
    try {
      await handler.deliverSegmentedMessages(
        convId: conv.id,
        userMsgId: 'user_non_stream_mixed_tts_image',
        buildResult: const AssistantMessageBuildResult(
          messages: <Message>[],
          lastMessageText: '',
        ),
        replyText: '文本a。<tts>语音段</tts>文本b。<image>slow landscape</image>文本c。',
        pluginEvents: <PluginEvent>[
          PluginEvent(
            pluginId: 'tts',
            type: 'tts_convert',
            data: const <String, dynamic>{
              'text': '语音段',
              'originalText': '语音段',
            },
            id: 'evt_non_stream_mixed_tts',
          ),
          PluginEvent(
            pluginId: 'image',
            type: 'image_generate',
            data: const <String, dynamic>{
              'prompt': 'slow landscape',
            },
            id: 'evt_non_stream_mixed_image',
          ),
        ],
        ttsEnabled: true,
      );

      var storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      final assistantMessages = storedMessages
          .where((message) => message.role == 'assistant')
          .toList(growable: false);
      final textAIndex = assistantMessages.indexWhere(
        (message) => message.displayText.trim() == '文本a。',
      );
      final ttsIndex = assistantMessages.indexWhere(
        (message) =>
            message.blocks?.whereType<AudioBlock>().any(
                  (block) => (block.text ?? '') == '语音段',
                ) ??
            false,
      );
      final textBIndex = assistantMessages.indexWhere(
        (message) => message.displayText.trim() == '文本b。',
      );
      final textCIndex = assistantMessages.indexWhere(
        (message) => message.displayText.trim() == '文本c。',
      );
      expect(textAIndex, greaterThanOrEqualTo(0));
      expect(ttsIndex, greaterThan(textAIndex));
      expect(textBIndex, greaterThan(ttsIndex));
      expect(textCIndex, greaterThan(textBIndex));
      final pendingAudio =
          assistantMessages[ttsIndex].blocks!.whereType<AudioBlock>().single;
      expect(pendingAudio.status, BlockStatus.pending);
      expect(
        storedMessages
            .any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
        isFalse,
        reason: '慢图完成前不应挡住后续文本，也不应提前落成最终图片',
      );
      expect(
        _collectGeneratingPlaceholderMessages(storedMessages),
        isEmpty,
        reason: '图片后补不再创建占位消息，慢图阶段不应额外占一个消息位',
      );

      await Future<void>.delayed(const Duration(milliseconds: 120));

      storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      final updatedAudio =
          storedMessages[ttsIndex].blocks!.whereType<AudioBlock>().single;
      expect(updatedAudio.status, BlockStatus.success);
      expect(updatedAudio.url, isNotEmpty);
      expect(
        storedMessages
            .any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
        isFalse,
        reason: 'TTS 原位完成后，慢图仍应继续独立等待，不回头阻塞正文',
      );
      expect(_collectGeneratingPlaceholderMessages(storedMessages), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 220));

      storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      final imageIndex = storedMessages.indexWhere(
        (message) =>
            message.blocks?.any((block) => block is ImageBlock) ?? false,
      );
      expect(imageIndex, greaterThan(textCIndex));
      expect(imagePlugin.prompts, <String>['slow landscape']);
      expect(_collectGeneratingPlaceholderMessages(storedMessages), isEmpty);
    } finally {
      await handler.debugWaitForBackgroundTasks();
    }
  });

  test('非流式文本和 TTS 混排时，也必须按分段延时逐条落消息', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_non_stream_tts_segment_delay',
      title: 'NonStreamTtsSegmentDelay',
      displayName: 'NonStreamTtsSegmentDelay',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings(streamSegmentDelaySeconds: 0.2);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '语音段': Duration(milliseconds: 360),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);

    final handler = container.read(chatTtsHandlerProvider);
    final deliveryFuture = handler.deliverSegmentedMessages(
      convId: conv.id,
      userMsgId: 'user_non_stream_tts_segment_delay',
      buildResult: const AssistantMessageBuildResult(
        messages: <Message>[],
        lastMessageText: '',
      ),
      replyText: '文本a。<tts>语音段</tts>文本b。',
      pluginEvents: <PluginEvent>[
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: const <String, dynamic>{
            'text': '语音段',
            'originalText': '语音段',
          },
          id: 'evt_non_stream_tts_segment_delay',
        ),
      ],
      ttsEnabled: true,
    );

    Future<List<Message>> loadAssistantMessages() async {
      final storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      return storedMessages
          .where((message) => message.role == 'assistant')
          .toList(growable: false);
    }

    final snapshots = <List<Message>>[];
    try {
      for (var i = 0; i < 24; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        snapshots.add(await loadAssistantMessages());
      }
      await deliveryFuture;
      await handler.debugWaitForBackgroundTasks(labelPrefix: 'pending_tts_');

      final sawNoAssistantYet = snapshots.any((snapshot) => snapshot.isEmpty);
      final sawFirstTextOnly = snapshots.any((snapshot) {
        return snapshot.length == 1 &&
            snapshot.single.displayText.trim() == '文本a。';
      });
      final sawTextThenPending = snapshots.any((snapshot) {
        if (snapshot.length != 2) return false;
        if (snapshot.first.displayText.trim() != '文本a。') return false;
        final audioBlock =
            snapshot[1].blocks?.whereType<AudioBlock>().singleOrNull;
        return audioBlock != null &&
            audioBlock.text == '语音段' &&
            audioBlock.status == BlockStatus.pending &&
            audioBlock.url.isEmpty;
      });
      final sawTextPendingThenTail = snapshots.any((snapshot) {
        return snapshot.length == 3 &&
            snapshot[0].displayText.trim() == '文本a。' &&
            snapshot[1].displayText.trim() == '[语音]' &&
            snapshot[2].displayText.trim() == '文本b。';
      });

      expect(
        sawNoAssistantYet,
        isTrue,
        reason: '三个点转首条正式消息前，非流式链路也要先走一段分段延时，不能瞬间把正文灌出来。',
      );
      expect(
        sawFirstTextOnly,
        isTrue,
        reason: '第一步只应该落第一条文本，语音占位不能和它一起出现。',
      );
      expect(
        sawTextThenPending,
        isTrue,
        reason: '第二步应只把语音占位落到原位，后续文本继续等待下一段延时。',
      );
      expect(
        sawTextPendingThenTail,
        isTrue,
        reason: '语音占位也应占住原位，等到下一段延时结束后，后续文本才能继续落下。',
      );

      final assistantMessages = await loadAssistantMessages();
      final finalAudio =
          assistantMessages[1].blocks!.whereType<AudioBlock>().single;
      expect(finalAudio.status, BlockStatus.success);
      expect(finalAudio.url, isNotEmpty);
      expect(
        assistantMessages.map((message) => message.displayText.trim()).toList(),
        <String>['文本a。', '[语音]', '文本b。'],
      );
    } finally {
      await deliveryFuture;
      await handler.debugWaitForBackgroundTasks(labelPrefix: 'pending_tts_');
    }
  });

  test('send 遇到 `<tts>...<image>...文本` 混排时，应先落完后续文本，再等待慢图直出最终图', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_mixed_tts_image_tail',
      title: 'StreamMixedTtsImageTail',
      displayName: 'StreamMixedTtsImageTail',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings =
        _buildTestSettings().copyWith(imageGenerationEnabled: true);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final tempDir =
        await Directory.systemTemp.createTemp('aicove_stream_mixed_tail');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final imageFile = File('${tempDir.path}\\tail.png');
    await imageFile.writeAsBytes(const <int>[1, 2, 3, 4]);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '语音段': Duration(milliseconds: 70),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);

    late _DelayedInlineImagePlugin imagePlugin;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _StreamingMixedTtsImageTailSendService(ref, settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
        pluginManagerProvider.overrideWith((ref) {
          final manager = PluginManager();
          imagePlugin = _DelayedInlineImagePlugin(
            delay: const Duration(milliseconds: 260),
            localPath: imageFile.path,
            ref: ref,
          );
          manager.register(imagePlugin);
          return manager;
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    try {
      await container.read(chatActionsProvider).send('测试混合尾部慢图');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      var storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      expect(_collectGeneratingPlaceholderMessages(storedMessages), isEmpty);

      final assistantMessages = storedMessages
          .where((message) => message.role == 'assistant')
          .toList(growable: false);
      expect(
        assistantMessages.any(
          (message) => message.displayText.trim() == '文本b文本c。',
        ),
        isFalse,
        reason: '<image> 应该像 `<tts>` 一样切开流式文本边界，避免把前后文本揉成同一个气泡',
      );
      final textBIndex = assistantMessages.indexWhere(
        (message) => message.displayText.trim() == '文本b',
      );
      final textCIndex = assistantMessages.indexWhere(
        (message) => message.displayText.trim() == '文本c。',
      );
      expect(textBIndex, greaterThanOrEqualTo(0));
      expect(textCIndex, greaterThan(textBIndex));
      expect(
        assistantMessages.any(
          (message) =>
              message.blocks?.any((block) => block is ImageBlock) ?? false,
        ),
        isFalse,
        reason: '慢图完成前，数据库里不应突然出现最终图片消息',
      );

      await Future<void>.delayed(const Duration(milliseconds: 120));

      storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      final updatedAudio = storedMessages
          .where((message) => message.role == 'assistant')
          .firstWhere((message) =>
              message.blocks?.whereType<AudioBlock>().any(
                    (block) => block.text == '语音段',
                  ) ??
              false)
          .blocks!
          .whereType<AudioBlock>()
          .single;
      expect(updatedAudio.status, BlockStatus.success);
      expect(updatedAudio.url, isNotEmpty);
      expect(
        storedMessages
            .any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
        isFalse,
        reason: '尾部慢图不应阻塞 TTS 原位完成，也不应在这之前抢先落库',
      );
      expect(_collectGeneratingPlaceholderMessages(storedMessages), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 220));

      storedMessages = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(conv.id);
      final finalAssistantMessages = storedMessages
          .where((message) => message.role == 'assistant')
          .toList(growable: false);
      final finalTextCIndex = finalAssistantMessages.indexWhere(
        (message) => message.displayText.trim() == '文本c。',
      );
      final imageIndex = finalAssistantMessages.indexWhere(
        (message) =>
            message.blocks?.any((block) => block is ImageBlock) ?? false,
      );
      expect(imageIndex, greaterThan(finalTextCIndex));
      expect(imagePlugin.prompts, <String>['slow landscape']);
      expect(_collectGeneratingPlaceholderMessages(storedMessages), isEmpty);
    } finally {
      await container
          .read(chatTtsHandlerProvider)
          .debugWaitForBackgroundTasks(labelPrefix: 'deferred_image_');
    }
  });

  test('send 处理多模态回复时，不应切到消息整理中状态', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_multimodal_no_processing_status',
      title: 'StreamMultimodalNoProcessingStatus',
      displayName: 'StreamMultimodalNoProcessingStatus',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _StreamingMixedTtsImageTailSendService(ref, settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final statuses = <ChatStatus>[];
    final statusSub = container.listen<ChatStatus>(
      chatStatusProvider,
      (_, next) => statuses.add(next),
      fireImmediately: true,
    );
    addTearDown(statusSub.close);

    await container.read(chatActionsProvider).send('测试多模态状态切换');

    expect(statuses, contains(ChatStatus.thinking));
    expect(
      statuses.where((status) => status == ChatStatus.processingResponse),
      isEmpty,
      reason: '多模态消息已按顺序正常交付，不应再额外进入“消息整理中”阶段。',
    );
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });

  test('send 遇到仅有 <tts> 的流式回复时，不应因缺少文本锚点而失败', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_only_tts',
      title: 'StreamOnlyTts',
      displayName: 'StreamOnlyTts',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '纯语音回复': Duration(milliseconds: 70),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _StreamingOnlyTtsSendService(ref, settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    await container.read(chatActionsProvider).send('测试仅有语音标签');
    await Future<void>.delayed(const Duration(milliseconds: 160));

    final storedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final assistantMessages = storedMessages
        .where((message) => message.role == 'assistant')
        .toList(growable: false);

    expect(ttsService.startedTexts, <String>['纯语音回复']);
    expect(
      assistantMessages.any(
        (message) =>
            message.blocks?.whereType<AudioBlock>().any(
                  (block) =>
                      block.text == '纯语音回复' &&
                      block.status == BlockStatus.success,
                ) ??
            false,
      ),
      isTrue,
      reason: '纯 TTS 回复应该正常生成语音消息，而不是因为没有文本锚点被整轮判失败。',
    );
    expect(
      assistantMessages.any((message) => message.status == 'failed'),
      isFalse,
    );
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });

  test('send 遇到仅有 <tts> + <image> 的流式回复时，不应因缺少文本锚点而失败', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_only_multimodal',
      title: 'StreamOnlyMultimodal',
      displayName: 'StreamOnlyMultimodal',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings =
        _buildTestSettings().copyWith(imageGenerationEnabled: true);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    final tempDir =
        await Directory.systemTemp.createTemp('aicove_stream_only_multimodal');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final imageFile = File('${tempDir.path}\\stream_only.png');
    await imageFile.writeAsBytes(const <int>[1, 2, 3, 4]);

    final ttsService = _TrackingDelayedTtsService(
      delays: const <String, Duration>{
        '语音段': Duration(milliseconds: 70),
      },
    );
    final ttsManager = TtsPlayerManager(() => ttsService);
    addTearDown(ttsManager.dispose);

    late _DelayedInlineImagePlugin imagePlugin;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _StreamingOnlyTtsAndImageSendService(ref, settings),
        ),
        ttsPlayerManagerProvider.overrideWithValue(ttsManager),
        voicePresetApplicationProvider.overrideWithValue(_TestVoiceApplication(ttsService)),
        pluginManagerProvider.overrideWith((ref) {
          final manager = PluginManager();
          imagePlugin = _DelayedInlineImagePlugin(
            delay: const Duration(milliseconds: 120),
            localPath: imageFile.path,
            ref: ref,
          );
          manager.register(imagePlugin);
          return manager;
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    await container.read(chatActionsProvider).send('测试仅有多模态标签');
    await Future<void>.delayed(const Duration(milliseconds: 260));

    final storedMessages = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(conv.id);
    final assistantMessages = storedMessages
        .where((message) => message.role == 'assistant')
        .toList(growable: false);

    expect(ttsService.startedTexts, <String>['语音段']);
    expect(imagePlugin.prompts, <String>['sunset beach']);
    expect(
      assistantMessages.any(
        (message) =>
            message.blocks?.whereType<AudioBlock>().any(
                  (block) =>
                      block.text == '语音段' &&
                      block.status == BlockStatus.success,
                ) ??
            false,
      ),
      isTrue,
      reason: '纯多模态回复里的 TTS 段应该正常落库。',
    );
    expect(
      assistantMessages.any(
        (message) =>
            message.blocks?.any((block) => block is ImageBlock) ?? false,
      ),
      isTrue,
      reason: '纯多模态回复里的图片段应该正常补发，而不是整轮失败。',
    );
    expect(
      assistantMessages.any((message) => message.status == 'failed'),
      isFalse,
    );
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });

  test('同一消息二次保存时应清掉旧文本块', () async {
    final now = DateTime.now();
    const convId = 'conv_stale_blocks';
    const msgId = 'msg_stale_blocks';
    const staleBlockId = 'blk_stale_streaming';
    const freshBlockId = 'blk_fresh_final';

    final conv = Conversation(
      id: convId,
      title: 'StaleBlocks',
      displayName: 'StaleBlocks',
      createdAt: now,
      updatedAt: now,
      messages: [
        Message.fromBlocks(
          id: msgId,
          role: 'assistant',
          blocks: [
            TextBlock(
              id: staleBlockId,
              messageId: msgId,
              content: '生成中...',
              status: BlockStatus.streaming,
            ),
          ],
          createdAt: now,
          status: 'sending',
        ),
      ],
      lastMessage: '生成中...',
      lastMessageTime: now,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, convId, conv.messages.single);
    await db.into(db.messageBlocks).insert(
          MessageBlocksCompanion.insert(
            id: staleBlockId,
            messageId: msgId,
            type: 'mainText',
            data: jsonEncode(
              TextBlock(
                id: staleBlockId,
                messageId: msgId,
                content: '生成中...',
                status: BlockStatus.streaming,
              ).toJson(),
            ),
            sortOrder: const Value(0),
            createdAt: now.millisecondsSinceEpoch,
          ),
        );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatHistoryStoreProvider).updateMessage(
          conversationId: convId,
          message: Message.fromBlocks(
            id: msgId,
            role: 'assistant',
            blocks: [
              TextBlock(
                id: freshBlockId,
                messageId: msgId,
                content: '最终回复',
                status: BlockStatus.success,
              ),
            ],
            createdAt: now,
            status: 'sent',
          ),
          lastMessagePreview: '最终回复',
        );

    final storedBlocks = await container
        .read(messageBlockRepositoryProvider)
        .getByMessage(msgId);
    final textBlocks = storedBlocks
        .map(MessageBlockConverter.fromDb)
        .whereType<TextBlock>()
        .toList(growable: false);

    expect(
      textBlocks.length,
      1,
      reason: '旧 streaming 文本块会让历史消息重复保存，并把生成中内容带回历史',
    );
    expect(textBlocks.single.id, freshBlockId);
    expect(textBlocks.single.content, '最终回复');
    expect(textBlocks.single.status, BlockStatus.success);
  });

  test('sendWithImage 发送图片时仍由聊天模型链负责主回复', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_image_vision_only',
      title: 'ImageVisionOnly',
      displayName: 'ImageVisionOnly',
      createdAt: now,
      updatedAt: now,
      messages: [
        Message(
          id: 'old_user',
          role: 'user',
          content: '上一轮文字',
          createdAt: now.subtract(const Duration(minutes: 2)),
          status: 'sent',
        ),
        Message(
          id: 'old_ai',
          role: 'assistant',
          content: '上一轮回复',
          createdAt: now.subtract(const Duration(minutes: 1)),
          status: 'sent',
        ),
      ],
      lastMessage: '上一轮回复',
      lastMessageTime: now.subtract(const Duration(minutes: 1)),
    );
    final settings = _buildTestSettings().copyWith(
      defaultModelName: 'openai:gpt-3.5-turbo',
      defaultChatModels: const <String>['openai:gpt-3.5-turbo'],
      modelList: const <String>['openai:gpt-3.5-turbo', 'openai:gpt-4o-mini'],
      allKnownModels: const <String>[
        'openai:gpt-3.5-turbo',
        'openai:gpt-4o-mini',
      ],
      modelProviderMap: const <String, String>{
        'openai:gpt-3.5-turbo': 'openai',
        'gpt-3.5-turbo': 'openai',
        'openai:gpt-4o-mini': 'openai',
        'gpt-4o-mini': 'openai',
      },
    );

    final tempDir = await Directory.systemTemp.createTemp('aicove_image_test');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final imageFile = File('${tempDir.path}\\demo.png');
    await imageFile.writeAsBytes(const <int>[1, 2, 3, 4]);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, conv.messages.first);
    await _insertMessage(db, conv.id, conv.messages.last);

    late _RecordingImageConfigSendService sendService;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith((ref) {
          sendService = _RecordingImageConfigSendService(ref, settings);
          return sendService;
        }),
        activeConversationProvider.overrideWith((ref) {
          return conv;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.sendWithImage(imageFile.path, text: '帮我看看这图');
    // 时间线缓存会异步补图片尺寸，稍等一拍避免 teardown 提前删除临时文件。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(sendService.executeCalls, 1);
    expect(sendService.lastOverrideModel, 'openai:gpt-3.5-turbo');
    expect(sendService.lastOverrideModel, isNot('openai:gpt-4o-mini'));
    expect(sendService.lastUserText, '帮我看看这图');
    expect(sendService.lastHistory, isNotNull);
    expect(sendService.lastHistory!.length, 3);
    expect(sendService.lastHistory!.first.content, '上一轮文字');
    expect(sendService.lastHistory![1].content, '上一轮回复');
    final config = sendService.lastConfig;
    expect(config, isNotNull);
    expect(config!.modelFullId, 'openai:gpt-3.5-turbo');
  });

  test('sendWithFile 发送音频时会保留文案展示并以 [audio] 驱动主聊天链路', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_audio_caption_flow',
      title: 'AudioCaptionFlow',
      displayName: 'AudioCaptionFlow',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();

    final tempDir = await Directory.systemTemp.createTemp('aicove_audio_test');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final audioFile = File('${tempDir.path}\\demo.mp3');
    await audioFile.writeAsBytes(const <int>[1, 2, 3, 4]);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    late _RecordingImageConfigSendService sendService;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService = _RecordingImageConfigSendService(ref, settings);
          return sendService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.sendWithFile(audioFile.path, text: '帮我听一下这段录音');

    expect(sendService.executeCalls, 1);
    expect(sendService.lastUserText, '[audio]');
    expect(sendService.lastDisplayText, '帮我听一下这段录音');
    final blocks = sendService.lastAddedUserMessage?.blocks;
    expect(blocks, isNotNull);
    final fileBlock = blocks!.whereType<FileBlock>().single;
    final textBlock = blocks.whereType<TextBlock>().single;
    expect(fileBlock.mimeType, 'audio/mpeg');
    expect(fileBlock.fileName, 'demo.mp3');
    expect(textBlock.content, '帮我听一下这段录音');
  });

  test('sendWithFile 发送视频且无文案时会使用 [视频] 占位展示', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_video_placeholder_flow',
      title: 'VideoPlaceholderFlow',
      displayName: 'VideoPlaceholderFlow',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();

    final tempDir = await Directory.systemTemp.createTemp('aicove_video_test');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final videoFile = File('${tempDir.path}\\demo.mp4');
    await videoFile.writeAsBytes(const <int>[1, 2, 3, 4]);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);

    late _RecordingImageConfigSendService sendService;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService = _RecordingImageConfigSendService(ref, settings);
          return sendService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.sendWithFile(videoFile.path);

    expect(sendService.executeCalls, 1);
    expect(sendService.lastUserText, '[video]');
    expect(sendService.lastDisplayText, '[视频]');
    final blocks = sendService.lastAddedUserMessage?.blocks;
    expect(blocks, isNotNull);
    expect(blocks!.whereType<TextBlock>(), isEmpty);
    final fileBlock = blocks.whereType<FileBlock>().single;
    expect(fileBlock.mimeType, 'video/mp4');
    expect(fileBlock.fileName, 'demo.mp4');
  });

  test('retry 会沿用默认聊天模型列表的首个模型', () async {
    final now = DateTime.now();
    final failedMsg = Message(
      id: 'msg_retry_model_choice',
      role: 'user',
      content: '帮我重试一下',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'failed',
    );
    final conv = Conversation(
      id: 'conv_retry_model_choice',
      title: 'RetryModelChoice',
      displayName: 'RetryModelChoice',
      createdAt: now,
      updatedAt: now,
      messages: [failedMsg],
      lastMessage: failedMsg.displayText,
      lastMessageTime: failedMsg.createdAt,
    );
    final settings = _buildTestSettings().copyWith(
      defaultModelName: 'openai:gpt-3.5-turbo',
      defaultChatModels: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      modelList: const <String>['openai:gpt-4o-mini', 'openai:gpt-3.5-turbo'],
      allKnownModels: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      modelProviderMap: const <String, String>{
        'openai:gpt-4o-mini': 'openai',
        'gpt-4o-mini': 'openai',
        'openai:gpt-3.5-turbo': 'openai',
        'gpt-3.5-turbo': 'openai',
      },
    );
    final historyPort = _MemoryChatHistoryPort([failedMsg]);
    late _RecordingImageConfigSendService sendService;
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatHistoryPortProvider.overrideWithValue(historyPort),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService = _RecordingImageConfigSendService(ref, settings);
          return sendService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.retry(failedMsg.id);

    expect(sendService.executeCalls, 1);
    expect(sendService.lastOverrideModel, 'openai:gpt-4o-mini');
  });

  test('regenerate 会沿用默认聊天模型列表的首个模型', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_regen_model_user',
      role: 'user',
      content: '重新组织一下回答',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_regen_model_ai',
      role: 'assistant',
      content: '旧回复',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen_model_choice',
      title: 'RegenModelChoice',
      displayName: 'RegenModelChoice',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );
    final settings = _buildTestSettings().copyWith(
      defaultModelName: 'openai:gpt-3.5-turbo',
      defaultChatModels: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      modelList: const <String>['openai:gpt-4o-mini', 'openai:gpt-3.5-turbo'],
      allKnownModels: const <String>[
        'openai:gpt-4o-mini',
        'openai:gpt-3.5-turbo',
      ],
      modelProviderMap: const <String, String>{
        'openai:gpt-4o-mini': 'openai',
        'gpt-4o-mini': 'openai',
        'openai:gpt-3.5-turbo': 'openai',
        'gpt-3.5-turbo': 'openai',
      },
    );
    final historyPort = _MemoryChatHistoryPort([userMsg, aiMsg]);
    late _RecordingImageConfigSendService sendService;
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatHistoryPortProvider.overrideWithValue(historyPort),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService = _RecordingImageConfigSendService(ref, settings);
          return sendService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.regenerate(aiMsg.id);

    expect(sendService.executeCalls, 1);
    expect(sendService.lastOverrideModel, 'openai:gpt-4o-mini');
  });

  test('sendWithImage 遇到 Provider 刷新窗口错误时会自动重试一次', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_image_retry_timing',
      title: 'ImageRetryTiming',
      displayName: 'ImageRetryTiming',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();

    final tempDir = await Directory.systemTemp.createTemp('aicove_image_retry');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final imageFile = File('${tempDir.path}\\retry.png');
    await imageFile.writeAsBytes(const <int>[1, 2, 3, 4]);

    late _RetryOnceProviderRefreshImageSendService sendService;
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatTtsHandlerProvider.overrideWith((ref) => _NoopChatTtsHandler(ref)),
        chatSendServiceProvider.overrideWith((ref) {
          sendService =
              _RetryOnceProviderRefreshImageSendService(ref, settings);
          return sendService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.sendWithImage(imageFile.path, text: '重新上传这张图');

    expect(sendService.executeCalls, 2);
    expect(sendService.markUserMessageFailedCalled, isFalse);
    expect(container.read(errorProvider), isNull);
    expect(container.read(conversationSendingProvider(conv.id)), isFalse);
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });

  test('ChatRequestMessageBuilder 会合并连续 assistant 文本段，避免分段污染上下文', () async {
    final builder = ChatRequestMessageBuilder(
      readImageAsBase64: (_) async => null,
    );
    final settings = _buildTestSettings();
    final now = DateTime(2026, 3, 3, 2, 0, 0);
    final history = <Message>[
      Message(
        id: 'a_1',
        role: 'assistant',
        content: '第一段。',
        createdAt: now,
        status: 'sent',
      ),
      Message(
        id: 'a_2',
        role: 'assistant',
        content: '第二段。',
        createdAt: now.add(const Duration(seconds: 1)),
        status: 'sent',
      ),
      Message(
        id: 'u_1',
        role: 'user',
        content: '继续',
        createdAt: now.add(const Duration(seconds: 2)),
        status: 'sent',
      ),
    ];

    final requestMessages = await builder.buildRequestMessages(
      history,
      settings: settings,
    );

    expect(requestMessages.length, 2);
    expect(requestMessages.first['role'], 'assistant');
    expect(requestMessages.first['content'], '第一段。\n第二段。');
    expect(requestMessages.last['role'], 'user');
    expect(requestMessages.last['content'], '继续');
  });
}
