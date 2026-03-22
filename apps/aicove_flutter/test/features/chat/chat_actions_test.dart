import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart'
    hide Conversation, Message;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/services/attachment_picker_service.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_player_manager.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';

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
    required int limit,
  }) async {
    return prepareHistory(
      conv: conv,
      userMsg: userMsg,
      limit: limit,
    );
  }
}

class _SpyStreamingSendService extends _InMemoryHistorySendService {
  _SpyStreamingSendService(super.ref, this._settings);

  final AppSettings _settings;

  bool lastEnableStreaming = false;
  bool sawDeltaCallback = false;
  bool sawResetCallback = false;
  bool sawToolObservedCallback = false;
  bool sawFallbackCallback = false;
  int executeCalls = 0;

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
    return AssistantMessageBuildResult(
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
    return AssistantMessageBuildResult(
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
    return AssistantMessageBuildResult(
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
    return AssistantMessageBuildResult(
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
    return AssistantMessageBuildResult(
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
    return AssistantMessageBuildResult(
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
    return AssistantMessageBuildResult(
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
    return AssistantMessageBuildResult(
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
    return AssistantMessageBuildResult(
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
    return AssistantMessageBuildResult(
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
    );
  }
}

class _RecordingStreamTtsHandler extends ChatTtsHandler {
  _RecordingStreamTtsHandler(super.ref);

  List<Message> lastPendingStreamTtsMessages = const <Message>[];
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
    TraceLogger? trace,
  }) async {
    lastAppendAfterStreamText = appendAfterStreamText;
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
  int executeCalls = 0;

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
    return AssistantMessageBuildResult(
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
    );
  }
}

class _TrackingDelayedTtsService extends TtsService {
  _TrackingDelayedTtsService({
    Duration defaultDelay = Duration.zero,
    Map<String, Duration>? delays,
  })  : _defaultDelay = defaultDelay,
        _delays = delays ?? const <String, Duration>{},
        super(
          config: TtsConfig(enabled: true),
          requestUrl: 'https://example.com/tts',
        );

  final Duration _defaultDelay;
  final Map<String, Duration> _delays;
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

class _DelayedWatchChatHistoryStore extends ChatHistoryStore {
  _DelayedWatchChatHistoryStore(
    super.ref, {
    required this.windowDelay,
  });

  final Duration windowDelay;

  @override
  Stream<ConversationMessageWindow> watchWindow({
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
    return AssistantMessageBuildResult(
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
    TraceLogger? trace,
  }) async {
    lastAppendAfterStreamText = appendAfterStreamText;
    if (buildResult.messages.isEmpty) {
      return;
    }
    await _ref.read(chatSendServiceProvider).deliverAssistantMessages(
          convId: convId,
          userMsgId: userMsgId,
          messages: buildResult.messages,
          lastMessagePreview: buildResult.lastMessageText,
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

    final remainingMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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

    final recalledAttachment = container.read(recalledAttachmentProvider);
    expect(recalledAttachment, isNotNull);
    expect(recalledAttachment!.type, AttachmentType.image);
    expect(recalledAttachment.path, imagePath);

    final remainingMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    expect(remainingMessages, isEmpty);

    final repo = container.read(messageRepositoryProvider);
    final deletedUser = await repo.getById(userMsg.id);
    final deletedAi = await repo.getById(aiMsg.id);
    expect(deletedUser, isNotNull);
    expect(deletedUser!.deletedAt, isNotNull);
    expect(deletedAi, isNotNull);
    expect(deletedAi!.deletedAt, isNotNull);
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

    final beforeMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    expect(beforeMessages.map((message) => message.id), [
      userMsg.id,
      aiMsg.id,
    ]);

    final preparedText = await actions.prepareTextRegenerate(aiMsg.id);
    expect(preparedText, '这句原话会被重新发送');

    final remainingMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    expect(remainingMessages, isEmpty);

    final repo = container.read(messageRepositoryProvider);
    final deletedUser = await repo.getById(userMsg.id);
    final deletedAi = await repo.getById(aiMsg.id);
    expect(deletedUser, isNotNull);
    expect(deletedUser!.deletedAt, isNotNull);
    expect(deletedAi, isNotNull);
    expect(deletedAi!.deletedAt, isNotNull);
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

    final remainingMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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

  test('deleteMessage 会删除单条消息并清理引用态', () async {
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

    final remainingMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    expect(remainingMessages.length, 1);
    expect(remainingMessages.first.id, userMsg.id);
    expect(container.read(quotedMessageProvider), isNull);

    final repo = container.read(messageRepositoryProvider);
    final blockRepo = container.read(messageBlockRepositoryProvider);
    final deleted = await repo.getById(aiMsg.id);
    final remained = await repo.getById(userMsg.id);
    final deletedBlocks = await blockRepo.getByMessage(aiMsg.id);
    final remainedBlocks = await blockRepo.getByMessage(userMsg.id);
    expect(deleted, isNotNull);
    expect(deleted!.deletedAt, isNotNull);
    expect(remained, isNotNull);
    expect(remained!.deletedAt, isNull);
    expect(deletedBlocks, isEmpty);
    expect(remainedBlocks.length, 1);

    final deletedBlockRaw = await blockRepo.getById('blk_ai_1');
    final remainedBlockRaw = await blockRepo.getById('blk_user_1');
    expect(deletedBlockRaw, isNotNull);
    expect(deletedBlockRaw!.deletedAt, isNotNull);
    expect(remainedBlockRaw, isNotNull);
    expect(remainedBlockRaw!.deletedAt, isNull);
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

    final storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    final assistantMessages = storedMessages
        .where((m) => m.role == 'assistant')
        .toList(growable: false);
    expect(
      assistantMessages.any((m) => m.id == 'assistant_result'),
      isTrue,
      reason: '有 delta 后回退到正式交付时，应保留 buildResult 里的原始正文消息',
    );
    expect(
      assistantMessages.any((m) => m.displayText.contains('前置流式文本')),
      isTrue,
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
    final transientSnapshots = <List<Message>>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      transientSnapshots.add(
        List<Message>.from(
          container.read(conversationTransientMessagesProvider(conv.id)),
        ),
      );
    }
    await sendFuture;

    var sawInProgressSuccessText = false;
    for (final snapshot in transientSnapshots) {
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

  test('send 在开启分段时，约 0.5 秒后应先出现 transient 生成中占位气泡', () async {
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
    final transientMessages =
        container.read(conversationTransientMessagesProvider(conv.id));

    final thinkingBubble = transientMessages.cast<Message?>().firstWhere(
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

  test('send 流式文本期间应只写入 transient timeline，正式时间线保持干净', () async {
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
    final stableMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    final transientMessages =
        container.read(conversationTransientMessagesProvider(conv.id));
    await sendFuture;

    expect(
      stableMessages.any(
        (message) => message.role == 'assistant' && message.status == 'sending',
      ),
      isFalse,
      reason: '流式阶段的 assistant 占位不应提前落进正式历史，否则会把分段策略写死到持久层',
    );
    expect(
      transientMessages.any(
        (message) => message.role == 'assistant' && message.status == 'sending',
      ),
      isTrue,
      reason: '流式阶段的 assistant 占位应只挂在 transient timeline，等待正式消息落库后再清掉',
    );
  });

  test('send 在打断生成后，应立即清掉临时占位气泡', () async {
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

    await Future<void>.delayed(const Duration(milliseconds: 560));
    final transientBeforeInterrupt =
        container.read(conversationTransientMessagesProvider(conv.id));
    expect(
      transientBeforeInterrupt.any(
        (message) => message.role == 'assistant' && message.status == 'sending',
      ),
      isTrue,
      reason: '停止前应先看到生成中占位，才能证明本用例覆盖到了用户反馈的场景',
    );

    final stopped =
        await container.read(chatActionsProvider).interruptCurrentGeneration();
    expect(stopped, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      sendFinished,
      isFalse,
      reason: '此时底层请求尚未自然返回，需要证明占位是在“中断瞬间”被清掉，而不是等请求结束后才消失',
    );
    expect(
      container.read(conversationTransientMessagesProvider(conv.id)),
      isEmpty,
      reason: '打断生成后，transient timeline 里的发送中占位也应立即清空',
    );
    expect(
      (await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id))
          .where((message) => message.role == 'assistant'),
      isEmpty,
      reason: '打断生成后，正式时间线里也不应残留 assistant 占位',
    );

    await sendFuture;

    final storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    expect(
      storedMessages.where((message) => message.role == 'assistant'),
      isEmpty,
      reason: '中断后的迟到结果不应再落成 assistant 消息',
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
    final transientSnapshots = <List<Message>>[];
    for (var i = 0; i < 9; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 90));
      transientSnapshots.add(
        List<Message>.from(
          container.read(conversationTransientMessagesProvider(conv.id)),
        ),
      );
    }
    await sendFuture;

    final leakedPartialText = transientSnapshots.any((snapshot) {
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
      reason: '分段模式下，未封口的半句正文应只留在 transient 后台缓冲，不能提前露到占位气泡里',
    );

    final sawFirstSentenceThenNextThinking = transientSnapshots.any((snapshot) {
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

    final finalMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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

  test('send 遇到 TTS 标签时，应先在 transient timeline 出现 pending 语音气泡', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_tts_pending',
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

    container.read(activeConversationIdProvider.notifier).state = conv.id;
    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);

    final sendFuture = container.read(chatActionsProvider).send('测试流式 TTS');
    final transientSnapshots = <List<Message>>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      transientSnapshots.add(
        List<Message>.from(
          container.read(conversationTransientMessagesProvider(conv.id)),
        ),
      );
    }
    await sendFuture;

    final sawPendingAudio = transientSnapshots.any((snapshot) {
      var hasLeadingText = false;
      var hasPendingAudio = false;
      for (final message in snapshot) {
        if (message.displayText == '第一句。') {
          hasLeadingText = true;
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
      return hasLeadingText && hasPendingAudio;
    });

    expect(
      sawPendingAudio,
      isTrue,
      reason: 'TTS 在流式中途闭合后，应先以 pending 音频气泡进入 transient timeline',
    );

    expect(ttsHandler.lastAppendAfterStreamText, isFalse);
    expect(ttsHandler.lastPendingStreamTtsMessages, isEmpty);
    expect(
      container.read(conversationTransientMessagesProvider(conv.id)),
      isEmpty,
      reason: '流式收尾后，transient timeline 不应再残留临时层数据',
    );
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

    await Future<void>.delayed(const Duration(milliseconds: 220));

    final storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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

    var storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    expect(
      storedMessages.any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
      isFalse,
      reason: '后补任务改成后台后，deliverSegmentedMessages 返回时慢图片不应已完成',
    );

    await Future<void>.delayed(const Duration(milliseconds: 120));

    storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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

    await Future<void>.delayed(const Duration(milliseconds: 220));

    storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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
    final transientSnapshots = <List<Message>>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      transientSnapshots.add(
        List<Message>.from(
          container.read(conversationTransientMessagesProvider(conv.id)),
        ),
      );
    }
    await sendFuture;

    final leakedInTransient = transientSnapshots.any((snapshot) {
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

    final storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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
    final transientSnapshots = <List<Message>>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      transientSnapshots.add(
        List<Message>.from(
          container.read(conversationTransientMessagesProvider(conv.id)),
        ),
      );
    }
    await sendFuture;

    final sawAttributeTagInTransient = transientSnapshots.any((snapshot) {
      return snapshot.any((message) => message.displayText.contains(
            '<image source="history">保留这段</image>',
          ));
    });
    expect(
      sawAttributeTagInTransient,
      isTrue,
      reason: '带属性的 image 标签不应再被宽匹配吞掉',
    );

    final storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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

    var storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    expect(
      _collectGeneratingPlaceholderMessages(storedMessages),
      hasLength(2),
      reason: '两个慢图都应先挂出独立占位，不阻塞正文',
    );

    await Future<void>.delayed(const Duration(milliseconds: 120));

    storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    final imageBlocks = storedMessages
        .where(
            (message) => message.blocks?.any((b) => b is ImageBlock) ?? false)
        .map((message) => message.blocks!.whereType<ImageBlock>().single)
        .toList(growable: false);
    expect(imageBlocks, hasLength(1));
    expect(imageBlocks.single.prompt, 'fast portrait');
    expect(
      _collectGeneratingPlaceholderMessages(storedMessages),
      hasLength(1),
      reason: '快图完成后应先单独发出，慢图继续保留占位等待',
    );

    await Future<void>.delayed(const Duration(milliseconds: 180));

    storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    final finalImagePrompts = storedMessages
        .where(
            (message) => message.blocks?.any((b) => b is ImageBlock) ?? false)
        .map((message) => message.blocks!.whereType<ImageBlock>().single.prompt)
        .toList(growable: false);
    expect(finalImagePrompts,
        containsAll(<String>['slow landscape', 'fast portrait']));
    expect(imagePlugin.prompts, <String>['slow landscape', 'fast portrait']);
    expect(
      _collectGeneratingPlaceholderMessages(storedMessages),
      isEmpty,
      reason: '所有图片完成后，尾部等待占位应全部清掉',
    );
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
        chatHistoryStoreProvider.overrideWith(
          (ref) => _DelayedWatchChatHistoryStore(
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

    var sawStablePlaceholder = false;
    var sawStableImage = false;
    var sawEmptyGap = false;
    for (var i = 0; i < 35; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final stableMessages =
          container.read(conversationMessagesProvider(conv.id)).valueOrNull ??
              const <Message>[];
      final hasStablePlaceholder =
          _collectGeneratingPlaceholderMessages(stableMessages).isNotEmpty;
      final hasStableImage = stableMessages.any(
        (message) =>
            message.blocks?.any((block) => block is ImageBlock) ?? false,
      );
      if (hasStablePlaceholder) {
        sawStablePlaceholder = true;
      }
      if (hasStableImage) {
        sawStableImage = true;
      }
      if (sawStablePlaceholder && !hasStableImage && !hasStablePlaceholder) {
        sawEmptyGap = true;
      }
    }

    expect(sawStablePlaceholder, isTrue);
    expect(sawStableImage, isTrue);
    expect(
      sawEmptyGap,
      isFalse,
      reason: '图片占位改为正式时间线同 ID 原地升级后，不应再出现“占位没了、图片还没到”的空窗',
    );

    await Future<void>.delayed(const Duration(milliseconds: 120));
    final finalStableMessages =
        container.read(conversationMessagesProvider(conv.id)).valueOrNull ??
            const <Message>[];
    expect(
      _collectGeneratingPlaceholderMessages(finalStableMessages),
      isEmpty,
      reason: '图片升级为最终态后，不应继续残留生成中占位',
    );
    expect(imagePlugin.prompts, <String>['handoff portrait']);
  });

  test('非流式混排遇到 TTS 和慢图时，应先发占位与后续文本，再等待补齐多模态', () async {
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

    var storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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
      storedMessages.any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
      isFalse,
      reason: '慢图完成前不应挡住后续文本，也不应提前落成最终图片',
    );
    expect(
      _collectGeneratingPlaceholderMessages(storedMessages),
      hasLength(1),
      reason: '慢图应先挂一个普通生成中气泡占位',
    );

    await Future<void>.delayed(const Duration(milliseconds: 120));

    storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    final updatedAudio =
        storedMessages[ttsIndex].blocks!.whereType<AudioBlock>().single;
    expect(updatedAudio.status, BlockStatus.success);
    expect(updatedAudio.url, isNotEmpty);
    expect(
      storedMessages.any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
      isFalse,
      reason: 'TTS 原位完成后，慢图仍应继续独立等待，不回头阻塞正文',
    );
    expect(
      _collectGeneratingPlaceholderMessages(storedMessages),
      hasLength(1),
    );

    await Future<void>.delayed(const Duration(milliseconds: 220));

    storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    final imageIndex = storedMessages.indexWhere(
      (message) => message.blocks?.any((block) => block is ImageBlock) ?? false,
    );
    expect(imageIndex, greaterThan(textCIndex));
    expect(imagePlugin.prompts, <String>['slow landscape']);
    expect(
      _collectGeneratingPlaceholderMessages(storedMessages),
      isEmpty,
      reason: '图片补齐后，生成中占位应及时清空',
    );
  });

  test('send 遇到 `<tts>...<image>...文本` 混排时，应先落完后续文本，再用尾部生成中气泡等待慢图', () async {
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

    await container.read(chatActionsProvider).send('测试混合尾部慢图');
    await Future<void>.delayed(const Duration(milliseconds: 40));

    var storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    final tailPlaceholders = _collectGeneratingPlaceholderMessages(
      storedMessages,
    );
    expect(tailPlaceholders, hasLength(1));
    final tailPlaceholder = tailPlaceholders.single;
    expect(tailPlaceholder.displayText.trim(), '生成中...');
    expect(tailPlaceholder.status, 'sending');
    final placeholderTextBlock =
        tailPlaceholder.blocks!.whereType<TextBlock>().single;
    expect(placeholderTextBlock.status, BlockStatus.streaming);

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

    storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
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
      storedMessages.any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
      isFalse,
      reason: '尾部慢图不应阻塞 TTS 原位完成，也不应在这之前抢先落库',
    );
    expect(
      _collectGeneratingPlaceholderMessages(storedMessages).single.id,
      tailPlaceholder.id,
      reason: '慢图仍未完成时，尾部生成中气泡应继续保留原位等待',
    );

    await Future<void>.delayed(const Duration(milliseconds: 220));

    storedMessages =
        await container.read(chatHistoryStoreProvider).loadAllMessages(conv.id);
    final finalAssistantMessages = storedMessages
        .where((message) => message.role == 'assistant')
        .toList(growable: false);
    final finalTextCIndex = finalAssistantMessages.indexWhere(
      (message) => message.displayText.trim() == '文本c。',
    );
    final imageIndex = finalAssistantMessages.indexWhere(
      (message) => message.blocks?.any((block) => block is ImageBlock) ?? false,
    );
    expect(imageIndex, greaterThan(finalTextCIndex));
    expect(imagePlugin.prompts, <String>['slow landscape']);
    expect(
      _collectGeneratingPlaceholderMessages(storedMessages),
      isEmpty,
      reason: '慢图完成后，尾部生成中占位应及时让位给最终图片',
    );
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
      defaultVisionModel: 'openai:gpt-4o-mini',
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
