library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../id_gen.dart';
import '../../settings/app_settings.dart';
import '../../observability/trace_models.dart';
import '../../../core/app_logger.dart';
import '../../../core/models/message_block.dart';
import '../../../core/utils/mime_utils.dart';
import 'chat_history_store.dart';
import 'chat_message_processor.dart';
import 'chat_request_message_builder.dart';
import 'chat_send_backend_service.dart';
import 'chat_types.dart';

export 'chat_types.dart'
    show SendRequest, ApiCallResult, ApiConfig, ToolAudioResult;

/// 发送门面：对上层保持稳定接口，把重型请求装配/执行委托给后台发送服务。
class ChatSendService {
  ChatSendService(this._ref);

  final Ref _ref;
  late final ChatSendBackendService _backendService = ChatSendBackendService(
    _ref,
    readImageAsBase64: readImageAsBase64,
    shouldUseNonVisionImageFlow: shouldUseNonVisionImageFlow,
    resolveTimeAwarenessPreviousUserMessageTime:
        ChatSendService.resolveTimeAwarenessPreviousUserMessageTime,
  );

  static const String _logTag = 'ChatSendService';
  static const String visionDescriptionSystemPrompt =
      ChatRequestMessageBuilder.visionDescriptionSystemPrompt;

  static bool isVisionModel(String modelId) {
    return inferChatModelCapabilities(modelId)
        .contains(ChatModelCapability.vision);
  }

  /// 构建图片消息发送时的模型调用链。
  ///
  /// 图片消息始终由聊天模型链负责主回复；
  /// 视觉辅助模型只参与图片预处理，不作为前台回复模型。
  List<String> buildImageSendModelRefs(AppSettings settings) {
    final chatModels = settings.defaultChatModels.isNotEmpty
        ? settings.defaultChatModels
        : [settings.defaultModelName];
    final normalizedChatModels = <String>[];
    for (final model in chatModels) {
      final ref = model.trim();
      if (ref.isEmpty || normalizedChatModels.contains(ref)) continue;
      normalizedChatModels.add(ref);
    }
    if (normalizedChatModels.isEmpty) {
      final fallback = settings.defaultModelName.trim();
      if (fallback.isNotEmpty) normalizedChatModels.add(fallback);
    }
    if (settings.preferVisionAssistant &&
        !hasVisionAssistant(settings.defaultVisionModel)) {
      AppLogger.warning(
        _logTag,
        'prefer_vision_assistant 已开启，但 defaultVisionModel 未配置，图片将仅复用已有提示词',
      );
    }
    return normalizedChatModels;
  }

  bool shouldUseNonVisionImageFlow({
    required AppSettings settings,
    required String modelRef,
  }) {
    if (settings.preferVisionAssistant &&
        hasVisionAssistant(settings.defaultVisionModel)) {
      return true;
    }
    return !settings.hasChatModelCapability(
      modelRef,
      ChatModelCapability.vision,
    );
  }

  static bool hasVisionAssistant(String? modelRef) {
    final normalized = modelRef?.trim();
    return normalized != null && normalized.isNotEmpty;
  }

  /// 在聊天模型不支持视觉时，为图片解析可发送给模型的文字描述。
  ///
  /// 优先复用图片块里已有的生图提示词；
  /// 若不存在，再调用视觉辅助模型回退。
  static Future<String?> resolveImageDescriptionForNonVision({
    required ImageBlock imageBlock,
    required Future<String?> Function() translateWithVision,
    String? cachedDescription,
    void Function(String description)? onDescriptionResolved,
  }) =>
      ChatRequestMessageBuilder.resolveImageDescriptionForNonVision(
        imageBlock: imageBlock,
        translateWithVision: translateWithVision,
        cachedDescription: cachedDescription,
        onDescriptionResolved: onDescriptionResolved,
      );

  static List<Map<String, dynamic>> buildVisionTranslationMessages({
    required Map<String, dynamic> imagePart,
  }) =>
      ChatRequestMessageBuilder.buildVisionTranslationMessages(
        imagePart: imagePart,
      );

  /// 构造非视觉模型下的图片上下文文本。
  static String? buildNonVisionImageMessageText({
    required String role,
    required String? description,
  }) =>
      ChatRequestMessageBuilder.buildNonVisionImageMessageText(
        role: role,
        description: description,
      );

  /// 创建用户消息。
  Message createUserMessage({
    required String? text,
    required String? imagePath,
  }) {
    final now = DateTime.now();

    if (imagePath != null && imagePath.isNotEmpty) {
      final msgId = genId('msg');
      final blocks = <MessageBlock>[
        ImageBlock(
          messageId: msgId,
          localPath: imagePath,
        ),
      ];
      final normalizedText = text?.trim();
      if (normalizedText != null && normalizedText.isNotEmpty) {
        blocks.add(
          TextBlock(
            messageId: msgId,
            content: normalizedText,
          ),
        );
      }
      return Message.fromBlocks(
        id: msgId,
        role: 'user',
        blocks: blocks,
        createdAt: now,
        status: 'sending',
      );
    }

    return Message(
      id: genId('msg'),
      role: 'user',
      content: text ?? '',
      createdAt: now,
      status: 'sending',
    );
  }

  Future<Message> createUserFileMessage({required String filePath}) async {
    final trimmed = filePath.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('filePath is empty');
    }

    final file = File(trimmed);
    if (!await file.exists()) {
      throw StateError('File not found: $trimmed');
    }

    final msgId = genId('msg');
    final size = await file.length();
    final name = p.basename(trimmed);

    return Message.fromBlocks(
      id: msgId,
      role: 'user',
      blocks: [
        FileBlock(
          messageId: msgId,
          fileName: name,
          fileSize: size,
          mimeType: MimeUtils.guessGenericMimeType(trimmed),
          filePath: trimmed,
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sending',
    );
  }

  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) async {
    await _ref.read(chatHistoryStoreProvider).appendUserMessage(
          conversationId: convId,
          message: userMsg,
          displayText: displayText,
        );
  }

  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) =>
      _backendService.prepareApiConfig(
        conv: conv,
        history: history,
        userText: userText,
        trace: trace,
        overrideModel: overrideModel,
        conversationId: conversationId,
        traceContext: traceContext,
      );

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
  }) =>
      _backendService.executeApiCall(
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

  /// 构建助手消息。
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    if (apiResult.hasToolAudio) {
      AppLogger.info(_logTag, 'Use tool audio output', metadata: {
        'audioCount': apiResult.toolAudioResults.length,
      });
      final audioMessages = <Message>[];
      for (final audio in apiResult.toolAudioResults) {
        final audioId = genId('msg');
        audioMessages.add(
          Message.fromBlocks(
            id: audioId,
            role: 'assistant',
            blocks: [
              AudioBlock(
                messageId: audioId,
                url: audio.audioUrl,
                text: audio.text,
              ),
            ],
            createdAt: DateTime.now(),
            status: 'sent',
          ),
        );
      }
      final textContent = apiResult.processedText.trim();
      if (textContent.isNotEmpty) {
        audioMessages.add(
          Message(
            id: genId('msg'),
            role: 'assistant',
            content: textContent,
            createdAt: DateTime.now(),
            status: 'sent',
          ),
        );
      }
      return AssistantMessageBuildResult(
        messages: audioMessages,
        lastMessageText:
            audioMessages.isNotEmpty ? audioMessages.last.displayText : '',
      );
    }

    return chatMessageProcessor.buildAssistantMessages(
      replyText: apiResult.replyText,
      processedText: apiResult.processedText,
      pluginEvents: apiResult.pluginEvents,
      contents: apiResult.pluginContents,
      toolCalls: apiResult.toolCalls,
      rawToolResults: apiResult.rawToolResults,
    );
  }

  Future<void> deliverAssistantMessages({
    required String convId,
    required String userMsgId,
    required List<Message> messages,
    required String lastMessagePreview,
    TraceLogger? trace,
  }) async {
    final forwardTrace = trace?.startChild('deliver message to user');
    forwardTrace?.info('消息分段完成', metadata: {
      'chunksCount': messages.length,
      'firstChunk': messages.isNotEmpty ? messages.first.displayText : '',
    });

    await _ref.read(chatHistoryStoreProvider).appendAssistantMessages(
          conversationId: convId,
          userMessageId: userMsgId,
          messages: messages,
          lastMessagePreview: lastMessagePreview,
        );

    forwardTrace?.info('消息已转发到用户', metadata: {
      'messagesCount': messages.length,
      'hasAudio':
          messages.any((m) => m.blocks?.any((b) => b is AudioBlock) ?? false),
    });
    forwardTrace?.end(additionalMessage: '转发成功');
  }

  Future<void> markUserMessageFailed({
    required String convId,
    required String userMsgId,
  }) async {
    await _ref.read(chatHistoryStoreProvider).markMessageStatus(
          conversationId: convId,
          messageId: userMsgId,
          status: 'failed',
        );
  }

  Future<String?> readImageAsBase64(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      AppLogger.error(_logTag, '读取图片失败: $e');
      return null;
    }
  }

  /// 计算时间感知插件的“上一条用户消息时间”。
  ///
  /// 当 history 末尾已经包含当前轮 user 消息时，会跳过这条当前消息，
  /// 返回它之前最近的一条 user 消息时间；否则返回 history 中最后一条 user 消息时间。
  static DateTime? resolveTimeAwarenessPreviousUserMessageTime(
    List<Message> history,
  ) {
    if (history.isEmpty) return null;

    final shouldSkipLatestUser = history.last.role == 'user';
    var skippedLatestUser = false;
    for (var i = history.length - 1; i >= 0; i--) {
      final message = history[i];
      if (message.role != 'user') continue;
      if (shouldSkipLatestUser && !skippedLatestUser) {
        skippedLatestUser = true;
        continue;
      }
      return message.createdAt;
    }
    return null;
  }

  /// 准备历史消息。
  List<Message> prepareHistory({
    required Conversation conv,
    required Message userMsg,
    required int limit,
  }) {
    final all = [...conv.messages, userMsg];
    return _sliceContextWindow(
      allMessages: all,
      contextStartId: conv.contextStartMessageId,
      limit: limit,
    );
  }

  /// 从数据库加载会话有效消息（排除 deleted/replaced），并按需补上当前用户消息。
  Future<List<Message>> loadConversationMessagesFromStore({
    required Conversation conv,
    Message? ensureTailMessage,
  }) async {
    final all =
        await _ref.read(chatHistoryStoreProvider).loadAllMessages(conv.id);

    if (ensureTailMessage != null &&
        all.every((m) => m.id != ensureTailMessage.id)) {
      all.add(ensureTailMessage);
    }
    return all;
  }

  /// 从数据库准备发送上下文。
  Future<List<Message>> prepareHistoryFromStore({
    required Conversation conv,
    required Message userMsg,
    required int limit,
  }) async {
    final all = await loadConversationMessagesFromStore(
      conv: conv,
      ensureTailMessage: userMsg,
    );
    return _sliceContextWindow(
      allMessages: all,
      contextStartId: conv.contextStartMessageId,
      limit: limit,
    );
  }

  List<Message> _sliceContextWindow({
    required List<Message> allMessages,
    required String? contextStartId,
    required int limit,
  }) {
    var contextWindow = allMessages;
    if (contextStartId != null && contextStartId.isNotEmpty) {
      final markerIndex =
          allMessages.lastIndexWhere((m) => m.id == contextStartId);
      if (markerIndex >= 0 && markerIndex + 1 < allMessages.length) {
        contextWindow = allMessages.sublist(markerIndex + 1);
      }
    }

    if (limit <= 0 || contextWindow.length <= limit) {
      return contextWindow;
    }
    return contextWindow.sublist(contextWindow.length - limit);
  }
}

final chatSendServiceProvider = Provider((ref) => ChatSendService(ref));
