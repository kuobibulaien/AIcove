/// (注释已丢失)
///
/// (注释已丢失)
/// (注释已丢失)
///
/// (注释已丢失)
/// (注释已丢失)
/// (注释已丢失)
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../id_gen.dart';
import '../conversation_providers.dart';
import '../../settings/app_settings.dart';
import 'chat_request_config.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/memory/memory_plugin.dart';
import '../../plugins/time_awareness/time_awareness_plugin.dart';
import '../../../core/models/message_block.dart';
import '../../../core/app_logger.dart';
import '../../../core/utils/mime_utils.dart';
import '../../../core/utils/token_estimator.dart';
import 'chat_message_processor.dart';
import 'chat_send_api_runner.dart';
import 'chat_plugin_context_builder.dart';
import 'chat_request_message_builder.dart';
import 'chat_types.dart';

export 'chat_types.dart'
    show SendRequest, ApiCallResult, ApiConfig, ToolAudioResult;

/// Chat sending service.
class ChatSendService {
  final Ref _ref;
  final ChatSendApiRunner _apiRunner = const ChatSendApiRunner();
  final ChatPluginContextBuilder _pluginContextBuilder =
      const ChatPluginContextBuilder();
  late final ChatRequestMessageBuilder _requestMessageBuilder =
      ChatRequestMessageBuilder(
    readImageAsBase64: readImageAsBase64,
  );
  final ChatRequestConfigBuilder _requestConfigBuilder =
      ChatRequestConfigBuilder();
  static const String visionDescriptionSystemPrompt =
      ChatRequestMessageBuilder.visionDescriptionSystemPrompt;

  ChatSendService(this._ref);

  static bool isVisionModel(String modelId) {
    return inferChatModelCapabilities(modelId)
        .contains(ChatModelCapability.vision);
  }

  /// 构建图片消息发送时的模型调用链。
  ///
  /// 规则：
  /// - 只要聊天模型链中有视觉能力（自动识别或手动标签），就不插入视觉辅助模型
  /// - 仅在聊天模型链全部无视觉能力时，才把视觉辅助模型放在最前
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

    final hasVisionCapableChatModel = normalizedChatModels.any(
      (modelRef) => settings.hasChatModelCapability(
        modelRef,
        ChatModelCapability.vision,
      ),
    );
    if (hasVisionCapableChatModel) return normalizedChatModels;

    final modelsToTry = <String>[];
    final visionModelRef = settings.defaultVisionModel?.trim();
    if (visionModelRef != null && visionModelRef.isNotEmpty) {
      modelsToTry.add(visionModelRef);
    }
    for (final modelRef in normalizedChatModels) {
      if (!modelsToTry.contains(modelRef)) {
        modelsToTry.add(modelRef);
      }
    }
    if (modelsToTry.isEmpty) {
      final fallback = settings.defaultModelName.trim();
      if (fallback.isNotEmpty) modelsToTry.add(fallback);
    }
    return modelsToTry;
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
  ///
  /// 设计约束：
  /// - assistant 图片不注入普通消息正文（避免模型模仿固定壳子文本）
  /// - user 图片转成中性说明，供模型理解用户刚发送了图片
  static String? buildNonVisionImageMessageText({
    required String role,
    required String? description,
  }) =>
      ChatRequestMessageBuilder.buildNonVisionImageMessageText(
        role: role,
        description: description,
      );

  /// 构建“assistant 最近发图”的内部媒体事件，注入 system prompt。
  ///
  /// 注意：这是内部状态提示，不应被模型原样回复给用户。
  static String buildAssistantImageEventPrompt(
    List<Message> history, {
    int maxEvents = 3,
  }) =>
      ChatRequestMessageBuilder.buildAssistantImageEventPrompt(
        history,
        maxEvents: maxEvents,
      );

  /// 创建用户消息
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

    // 文本消息
    return Message(
      id: genId('msg'),
      role: 'user',
      content: text ?? '',
      createdAt: now,
      status: 'sending',
    );
  }

  /// (注释已丢失)
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

  /// (注释已丢失)
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) async {
    final now = DateTime.now();
    await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
            messages: [...c.messages, userMsg],
            updatedAt: now,
            lastMessage: displayText,
            lastMessageTime: now,
          ),
        );
  }

  /// 准备 API 调用配置
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
  }) async {
    final configTrace = trace?.startChild('读取配置');

    final settings = await _ref.read(appSettingsProvider.future);
    final requestConfig = await _requestConfigBuilder.buildRequestConfig(
      settings,
      modelRef: overrideModel,
    );
    final toolPrefs = requestConfig.toolPrefs;

    configTrace?.note('配置', metadata: {
      'ttsEnabled': settings.ttsEnabled,
      'autoTools': toolPrefs['auto_tools_enabled'] == true,
      'enabledToolsCount':
          (toolPrefs['mcp_enabled_tools'] as List?)?.length ?? 0,
    });
    configTrace?.end();

    final modelRef = requestConfig.modelRef;
    final modelFull = requestConfig.modelFullId;

    final supportsVision = settings.hasChatModelCapability(
      modelRef,
      ChatModelCapability.vision,
    );
    final reqMessages = await _requestMessageBuilder.buildRequestMessages(
      history,
      settings: settings,
      supportsVision: supportsVision,
    );

    final systemParts = <String>[];
    if (conv.personaPrompt.isNotEmpty) {
      systemParts.add(conv.personaPrompt);
    }
    final supportsToolCalling =
        settings.hasChatModelCapability(modelRef, ChatModelCapability.tools) &&
            !settings.isModelToolCallingDisabled(modelRef);
    final enabledPluginIds = conv.enabledPlugins?.toSet();
    final pluginManager = _ref.read(pluginManagerProvider);
    final effectivePlugins = _pluginContextBuilder.getEffectivePlugins(
      pluginManager: pluginManager,
      enabledPluginIds: enabledPluginIds,
    );
    final timeAwarenessAnchor = resolveTimeAwarenessLastMessageTime(history);
    for (final plugin in effectivePlugins) {
      if (plugin is TimeAwarenessPlugin) {
        plugin.setLastMessageTime(timeAwarenessAnchor);
        break;
      }
    }
    final pluginPrompts =
        await _pluginContextBuilder.buildPluginPromptsWithFilter(
      effectivePlugins,
      userMessage: userText ?? '',
      supportsToolCalling: supportsToolCalling,
    );
    if (pluginPrompts.isNotEmpty) {
      systemParts.add(pluginPrompts);
    }

    if (!supportsVision) {
      final mediaContext = buildAssistantImageEventPrompt(history);
      if (mediaContext.isNotEmpty) {
        systemParts.add(mediaContext);
      }
    }

    List<Map<String, dynamic>>? tools;
    if (supportsToolCalling) {
      final aiTools =
          _pluginContextBuilder.collectPluginTools(effectivePlugins);
      if (aiTools.isNotEmpty) {
        tools = aiTools.map((t) => t.toOpenAISchema()).toList();
        AppLogger.debug('ChatSendService', '收集到工具定义', metadata: {
          'toolCount': tools.length,
          'toolNames': aiTools.map((t) => t.name).toList(),
        });
      }
    }

    if (systemParts.isNotEmpty) {
      reqMessages.insert(0, {
        'role': 'system',
        'content': systemParts.join('\n\n'),
      });
    }

    final modelName =
        modelFull.contains(':') ? modelFull.split(':').last : modelFull;
    final maxContextTokens = getModelContextLimit(modelName);
    final truncatedMessages = truncateMessagesToFit(
      messages: reqMessages,
      maxContextTokens: maxContextTokens,
      reserveTokens: 2048,
    );

    if (truncatedMessages.length < reqMessages.length) {
      MemoryPlugin? memoryPlugin;
      for (final plugin in effectivePlugins) {
        if (plugin is MemoryPlugin && plugin.enabled) {
          memoryPlugin = plugin;
          break;
        }
      }
      if (memoryPlugin != null) {
        final systemCount = systemParts.isNotEmpty ? 1 : 0;
        final keptHistoryCount =
            (truncatedMessages.length - systemCount).clamp(0, history.length);
        final droppedCount = history.length - keptHistoryCount;
        if (droppedCount > 0) {
          memoryPlugin.triggerPreFlush(
            conversationId: conv.id,
            droppedMessages: history.take(droppedCount).toList(),
          );
        }
      }
    }

    return ApiConfig(
      settings: settings,
      modelFullId: modelFull,
      providerApiBase: requestConfig.providerApiBase,
      providerApiKey: requestConfig.providerApiKey,
      customConfig: requestConfig.customConfig,
      toolPrefs: toolPrefs,
      messages: truncatedMessages,
      tools: tools,
      enabledPluginIds: enabledPluginIds,
      modelTemperature: requestConfig.modelTemperature,
      modelTopP: requestConfig.modelTopP,
      modelContextMessageLimit: requestConfig.modelContextMessageLimit,
    );
  }

  /// (注释已丢失)
  Future<ApiConfig> getApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
  }) =>
      prepareApiConfig(
          conv: conv, history: history, userText: userText, trace: trace);

  /// (注释已丢失)
  ///
  /// (注释已丢失)
  /// 1. 调用 AI API
  /// (注释已丢失)
  /// (注释已丢失)
  /// (注释已丢失)
  ///
  /// (注释已丢失)
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
    final pluginManager = _ref.read(pluginManagerProvider);
    final effectivePlugins = _pluginContextBuilder.getEffectivePlugins(
      pluginManager: pluginManager,
      enabledPluginIds: config.enabledPluginIds,
    );
    return _apiRunner.executeApiCall(
      config: config,
      sessionId: sessionId,
      userText: userText,
      effectivePlugins: effectivePlugins,
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

  /// 构建助手消息
  ///
  /// 返回 AssistantMessageBuildResult，包含消息列表和 TTS 占位消息 ID
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    // (注释已丢失)
    // (注释已丢失)
    if (apiResult.hasToolAudio) {
      AppLogger.info('ChatSendService', 'Use tool audio output', metadata: {
        'audioCount': apiResult.toolAudioResults.length,
      });
      final audioMessages = <Message>[];
      for (final audio in apiResult.toolAudioResults) {
        final audioId = genId('msg');
        audioMessages.add(Message.fromBlocks(
          id: audioId,
          role: 'assistant',
          blocks: [
            AudioBlock(
                messageId: audioId, url: audio.audioUrl, text: audio.text)
          ],
          createdAt: DateTime.now(),
          status: 'sent',
        ));
      }
      // (注释已丢失)
      final textContent = apiResult.processedText.trim();
      if (textContent.isNotEmpty) {
        audioMessages.add(Message(
          id: genId('msg'),
          role: 'assistant',
          content: textContent,
          createdAt: DateTime.now(),
          status: 'sent',
        ));
      }
      return AssistantMessageBuildResult(
        messages: audioMessages,
        lastMessageText:
            audioMessages.isNotEmpty ? audioMessages.last.displayText : '',
      );
    }

    // (注释已丢失)
    // (注释已丢失)
    return chatMessageProcessor.buildAssistantMessages(
      replyText: apiResult.replyText,
      processedText: apiResult.processedText,
      pluginEvents: apiResult.pluginEvents,
      contents: apiResult.pluginContents,
      toolCalls: apiResult.toolCalls,
      rawToolResults: apiResult.rawToolResults,
    );
  }

  /// (注释已丢失)
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

    final now = DateTime.now();
    await _ref.read(conversationsProvider.notifier).updateOne(
      convId,
      (c) {
        final updatedMessages = c.messages.map((m) {
          if (m.id == userMsgId) {
            return m.copyWith(status: 'sent');
          }
          return m;
        }).toList();
        return c.copyWith(
          messages: [...updatedMessages, ...messages],
          updatedAt: now,
          lastMessage: lastMessagePreview,
          lastMessageTime: now,
        );
      },
    );

    forwardTrace?.info('消息已转发到用户', metadata: {
      'messagesCount': messages.length,
      'hasAudio':
          messages.any((m) => m.blocks?.any((b) => b is AudioBlock) ?? false),
    });
    forwardTrace?.end(additionalMessage: '转发成功');
  }

  /// (注释已丢失)
  Future<void> markUserMessageFailed({
    required String convId,
    required String userMsgId,
  }) async {
    await _ref.read(conversationsProvider.notifier).updateOne(
      convId,
      (c) {
        final updatedMessages = c.messages.map((m) {
          if (m.id == userMsgId) {
            return m.copyWith(status: 'failed');
          }
          return m;
        }).toList();
        return c.copyWith(
          messages: updatedMessages,
          updatedAt: DateTime.now(),
        );
      },
    );
  }

  /// (注释已丢失)
  Future<String?> readImageAsBase64(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      AppLogger.error('ChatSendService', '读取图片失败: $e');
      return null;
    }
  }

  /// 计算时间感知插件的“上一轮对话时间锚点”。
  ///
  /// 当 history 最后一条是当前用户刚发送的消息时，使用倒数第二条；
  /// 这样能反映“距离上一轮对话过去了多久”。
  static DateTime? resolveTimeAwarenessLastMessageTime(List<Message> history) {
    if (history.isEmpty) return null;
    if (history.length == 1) return history.first.createdAt;

    final last = history.last;
    if (last.role == 'user') {
      return history[history.length - 2].createdAt;
    }
    return last.createdAt;
  }

  /// 准备历史消息
  List<Message> prepareHistory({
    required Conversation conv,
    required Message userMsg,
    required int limit,
  }) {
    final all = [...conv.messages, userMsg];

    // Respect the "new topic" marker: only messages after the marker are
    // eligible for model context.
    var contextWindow = all;
    final contextStartId = conv.contextStartMessageId;
    if (contextStartId != null && contextStartId.isNotEmpty) {
      final markerIndex = all.lastIndexWhere((m) => m.id == contextStartId);
      if (markerIndex >= 0 && markerIndex + 1 < all.length) {
        contextWindow = all.sublist(markerIndex + 1);
      }
    }

    if (limit <= 0 || contextWindow.length <= limit) {
      return contextWindow;
    }
    return contextWindow.sublist(contextWindow.length - limit);
  }
}

/// Provider
final chatSendServiceProvider = Provider((ref) => ChatSendService(ref));
