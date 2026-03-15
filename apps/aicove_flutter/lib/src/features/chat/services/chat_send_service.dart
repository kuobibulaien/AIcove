/// (注释已丢失)
///
/// (注释已丢失)
/// (注释已丢失)
///
/// (注释已丢失)
/// (注释已丢失)
/// (注释已丢失)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../domain/persona_prompt_codec.dart';
import '../id_gen.dart';
import 'chat_history_store.dart';
import '../../settings/app_settings.dart';
import '../../plugins/image/image_config.dart';
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
import '../../observability/trace_models.dart';
import '../../observability/trace_store.dart';

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
  static const String _logTag = 'ChatSendService';
  static const String _internalImageContextRule =
      '__AICOVE_IMAGE_CONTEXT__{...} 是内部图片上下文记录，只供理解，不是发给用户的话，禁止原样输出这段标记。';

  ChatSendService(this._ref);

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
  ///
  /// 统一把图片转成文字上下文，供非视觉链路理解。
  static String? buildNonVisionImageMessageText({
    required String role,
    required String? description,
  }) =>
      ChatRequestMessageBuilder.buildNonVisionImageMessageText(
        role: role,
        description: description,
      );

  bool _containsInternalImageContext(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      if (_containsInternalImageContextNode(message)) {
        return true;
      }
    }
    return false;
  }

  bool _containsInternalImageContextNode(dynamic node) {
    final marker = ChatRequestMessageBuilder.nonVisionImageContextPrefix;
    if (node is String) {
      return node.contains(marker);
    }
    if (node is List) {
      for (final item in node) {
        if (_containsInternalImageContextNode(item)) {
          return true;
        }
      }
      return false;
    }
    if (node is Map) {
      for (final value in node.values) {
        if (_containsInternalImageContextNode(value)) {
          return true;
        }
      }
    }
    return false;
  }

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
    await _ref.read(chatHistoryStoreProvider).appendUserMessage(
          conversationId: convId,
          message: userMsg,
          displayText: displayText,
        );
  }

  /// 准备 API 调用配置
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    final resolvedConversationId = (conversationId?.trim().isNotEmpty ?? false)
        ? conversationId!.trim()
        : conv.id;
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
    if (traceContext != null) {
      unawaited(
        TraceStore.instance.record(
          traceId: traceContext.traceId,
          sessionId: traceContext.sessionId,
          turnId: traceContext.turnId,
          stage: TraceStage.historyPrepared,
          source: 'ChatSendService',
          meta: {
            'historyCount': history.length,
            'hasUserText': (userText?.trim().isNotEmpty ?? false),
          },
        ),
      );
    }

    final modelRef = requestConfig.modelRef;
    final modelFull = requestConfig.modelFullId;
    final supportsVision = !shouldUseNonVisionImageFlow(
      settings: settings,
      modelRef: modelRef,
    );
    final reqMessages = await _requestMessageBuilder.buildRequestMessages(
      history,
      settings: settings,
      supportsVision: supportsVision,
    );

    final personaParts = PersonaPromptCodec.parse(conv.personaPrompt);
    final imageConfig = _ref.read(imagePluginConfigProvider);
    final boundImageToolPresetName = _resolveBoundToolPresetName(
      imageConfig,
      personaParts.drawingToolPresetName,
    );
    final boundImageArtistPresetName = _resolveBoundArtistPresetName(
      imageConfig,
      personaParts.drawingArtistPresetName,
    );
    final systemParts = <String>[];
    if (personaParts.userPrompt.isNotEmpty) {
      systemParts.add(personaParts.userPrompt);
    }
    if (_containsInternalImageContext(reqMessages)) {
      systemParts.add(_internalImageContextRule);
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
    final pluginPromptBuild =
        await _pluginContextBuilder.buildPluginPromptEntriesWithFilter(
      effectivePlugins,
      userMessage: userText ?? '',
      supportsToolCalling: supportsToolCalling,
      conversationId: resolvedConversationId,
    );
    for (final promptEntry in pluginPromptBuild.entries) {
      if (!promptEntry.injected) continue;
      systemParts.add(promptEntry.content);
    }

    List<Map<String, dynamic>>? tools;
    if (supportsToolCalling) {
      final aiTools = await _pluginContextBuilder.collectPluginToolsWithRetry(
        effectivePlugins,
      );
      if (aiTools.isNotEmpty) {
        tools = aiTools.map((t) => t.toOpenAISchema()).toList();
        tools = _applyRoleBoundDrawImageToolPreset(
          tools: tools,
          imageConfig: imageConfig,
          toolPresetName: boundImageToolPresetName,
          customDrawingPrompt: personaParts.customDrawingPrompt,
        );
        AppLogger.debug('ChatSendService', '收集到工具定义', metadata: {
          'toolCount': tools.length,
          'toolNames': aiTools.map((t) => t.name).toList(),
        });
      }
    }

    final systemAssemblyEntries = _buildSystemAssemblyEntries(
      personaPrompt: personaParts.userPrompt,
      includeInternalImageRule: _containsInternalImageContext(reqMessages),
      pluginPromptBuild: pluginPromptBuild,
    );
    final messagesBeforeSystemCount = reqMessages.length;

    if (systemParts.isNotEmpty) {
      reqMessages.insert(0, {
        'role': 'system',
        'content': systemParts.join('\n\n'),
      });
    }

    final maxContextTokens = settings.getMaxContextTokens(modelRef);
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
            conversationId: resolvedConversationId,
            droppedMessages: history.take(droppedCount).toList(),
          );
        }
      }
    }

    if (traceContext != null) {
      final now = DateTime.now();
      final payloadRef = await TraceStore.instance.writePayload(
        traceId: traceContext.traceId,
        sessionId: traceContext.sessionId,
        turnId: traceContext.turnId,
        stage: TraceStage.apiConfigReady.value,
        source: 'ChatSendService',
        payload: {
          'runtimeContext': _buildRuntimeContextPayload(
            now: now,
            lastMessageTime: timeAwarenessAnchor,
            effectivePlugins: effectivePlugins,
            pluginPromptBuild: pluginPromptBuild,
            historyCount: history.length,
          ),
          'promptAssembly': _buildPromptAssemblyPayload(
            systemAssemblyEntries: systemAssemblyEntries,
            pluginPromptBuild: pluginPromptBuild,
            messagesBeforeSystemCount: messagesBeforeSystemCount,
            messagesAfterSystemCount: reqMessages.length,
            finalMessages: truncatedMessages,
            toolsCount: tools?.length ?? 0,
          ),
        },
        now: now,
      );
      await TraceStore.instance.record(
        traceId: traceContext.traceId,
        sessionId: traceContext.sessionId,
        turnId: traceContext.turnId,
        stage: TraceStage.apiConfigReady,
        source: 'ChatSendService',
        payloadRef: payloadRef,
        meta: {
          'modelFullId': modelFull,
          'messagesCount': truncatedMessages.length,
          'toolsCount': tools?.length ?? 0,
          'supportsToolCalling': supportsToolCalling,
          'supportsVision': supportsVision,
        },
      );
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
      traceContext: traceContext,
      boundImageToolPresetName: boundImageToolPresetName,
      boundImageArtistPresetName: boundImageArtistPresetName,
    );
  }

  String? _resolveBoundToolPresetName(
    ImageConfig imageConfig,
    String? candidate,
  ) {
    final name = candidate?.trim();
    if (name == null || name.isEmpty) return null;
    final exists =
        imageConfig.systemPromptPresets.any((preset) => preset.name == name);
    return exists ? name : null;
  }

  String? _resolveBoundArtistPresetName(
    ImageConfig imageConfig,
    String? candidate,
  ) {
    final name = candidate?.trim();
    if (name == null || name.isEmpty) return null;
    if (PersonaPromptCodec.isArtistPresetDisabledBinding(name)) {
      return PersonaPromptCodec.artistPresetDisabledBinding;
    }
    final exists =
        imageConfig.artistPresets.any((preset) => preset.name == name);
    return exists ? name : null;
  }

  List<Map<String, dynamic>> _applyRoleBoundDrawImageToolPreset({
    required List<Map<String, dynamic>> tools,
    required ImageConfig imageConfig,
    required String? toolPresetName,
    required String customDrawingPrompt,
  }) {
    final normalizedDrawingPrompt = customDrawingPrompt.trim();
    final hasToolPreset = toolPresetName != null && toolPresetName.isNotEmpty;
    if (!hasToolPreset && normalizedDrawingPrompt.isEmpty) {
      return tools;
    }

    var blocks = imageConfig.effectiveToolDescriptionBlocks;
    if (hasToolPreset) {
      final preset = imageConfig.systemPromptPresets
          .where((item) => item.name == toolPresetName)
          .firstOrNull;
      if (preset != null) {
        blocks = ImageConfig.decodeToolDescriptionBlocks(preset.content) ??
            ImageConfig.defaultToolDescriptionBlocks;
      }
    }
    if (normalizedDrawingPrompt.isNotEmpty) {
      final promptDescription = blocks.promptDescription.trim();
      blocks = blocks.copyWith(
        promptDescription:
            '$promptDescription\n\n【角色专属生图要求】\n$normalizedDrawingPrompt',
      );
    }

    return [
      for (final rawSchema in tools)
        () {
          final schema = Map<String, dynamic>.from(rawSchema);
          final rawFunction = schema['function'];
          if (rawFunction is! Map) return schema;

          final function = Map<String, dynamic>.from(rawFunction);
          final functionName = function['name']?.toString().trim();
          if (functionName != 'draw_image') return schema;

          function['description'] = blocks.toolDescription;

          final rawParameters = function['parameters'];
          if (rawParameters is Map) {
            final parameters = Map<String, dynamic>.from(rawParameters);
            final rawProperties = parameters['properties'];
            if (rawProperties is Map) {
              final properties = Map<String, dynamic>.from(rawProperties);

              void overrideDescription(String key, String description) {
                final rawProperty = properties[key];
                if (rawProperty is! Map) return;
                final property = Map<String, dynamic>.from(rawProperty);
                property['description'] = description;
                properties[key] = property;
              }

              overrideDescription('prompt', blocks.promptDescription);
              overrideDescription(
                'negative_prompt',
                blocks.negativePromptDescription,
              );
              overrideDescription('width', blocks.widthDescription);
              overrideDescription('height', blocks.heightDescription);

              parameters['properties'] = properties;
            }
            function['parameters'] = parameters;
          }

          schema['function'] = function;
          return schema;
        }(),
    ];
  }

  /// (注释已丢失)
  Future<ApiConfig> getApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? conversationId,
    TraceContext? traceContext,
  }) =>
      prepareApiConfig(
          conv: conv,
          history: history,
          userText: userText,
          trace: trace,
          conversationId: conversationId,
          traceContext: traceContext);

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
      traceContext: config.traceContext,
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

  /// (注释已丢失)
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

  List<Map<String, dynamic>> _buildSystemAssemblyEntries({
    required String personaPrompt,
    required bool includeInternalImageRule,
    required PluginPromptBuildResult pluginPromptBuild,
  }) {
    final entries = <Map<String, dynamic>>[];

    void addEntry({
      required String source,
      required String label,
      required String content,
      Map<String, dynamic>? extra,
    }) {
      final trimmed = content.trim();
      if (trimmed.isEmpty) return;
      entries.add(<String, dynamic>{
        'order': entries.length,
        'source': source,
        'label': label,
        'content': trimmed,
        if (extra != null && extra.isNotEmpty) ...extra,
      });
    }

    addEntry(
      source: 'persona.userPrompt',
      label: '角色人设',
      content: personaPrompt,
    );
    if (includeInternalImageRule) {
      addEntry(
        source: 'internal.imageContextRule',
        label: '内部图片上下文规则',
        content: _internalImageContextRule,
      );
    }
    for (final promptEntry in pluginPromptBuild.entries) {
      if (!promptEntry.injected) continue;
      addEntry(
        source: 'plugin.${promptEntry.pluginId}',
        label: '插件提示词',
        content: promptEntry.content,
        extra: <String, dynamic>{
          'pluginId': promptEntry.pluginId,
          'pluginName': promptEntry.pluginName,
        },
      );
    }
    return entries;
  }

  Map<String, dynamic> _buildRuntimeContextPayload({
    required DateTime now,
    required DateTime? lastMessageTime,
    required List<dynamic> effectivePlugins,
    required PluginPromptBuildResult pluginPromptBuild,
    required int historyCount,
  }) {
    Map<String, dynamic>? timeAwarenessConfig;
    String? timeAwarenessPluginName;
    var timeAwarenessPluginEnabled = false;
    for (final plugin in effectivePlugins) {
      if (plugin is! TimeAwarenessPlugin) continue;
      timeAwarenessPluginName = plugin.name;
      timeAwarenessPluginEnabled = plugin.enabled;
      timeAwarenessConfig = Map<String, dynamic>.from(plugin.getConfig());
      break;
    }

    PluginPromptEntry? timePromptEntry;
    for (final promptEntry in pluginPromptBuild.entries) {
      if (promptEntry.pluginId != 'time_awareness') continue;
      timePromptEntry = promptEntry;
      break;
    }

    final elapsed =
        lastMessageTime == null ? null : now.difference(lastMessageTime);

    return <String, dynamic>{
      'clockSource': 'device_local',
      'generatedAt': now.toIso8601String(),
      'timezoneName': now.timeZoneName,
      'timezoneOffset': _formatTimezoneOffset(now.timeZoneOffset),
      'timezoneOffsetMinutes': now.timeZoneOffset.inMinutes,
      'historyCount': historyCount,
      if (lastMessageTime != null)
        'lastMessageTime': lastMessageTime.toIso8601String(),
      if (elapsed != null)
        'elapsedSinceLastMessage': <String, dynamic>{
          'milliseconds': elapsed.inMilliseconds,
          'minutes': elapsed.inMinutes,
          'human': _formatElapsedForTrace(elapsed),
        },
      'timeAwareness': <String, dynamic>{
        'pluginEnabled': timeAwarenessPluginEnabled,
        if (timeAwarenessPluginName != null)
          'pluginName': timeAwarenessPluginName,
        'promptInjected': timePromptEntry?.injected ?? false,
        if (timePromptEntry != null) 'reason': timePromptEntry.reason,
        if (timeAwarenessConfig != null) 'config': timeAwarenessConfig,
        if (timePromptEntry != null && timePromptEntry.content.isNotEmpty)
          'promptContent': timePromptEntry.content,
      },
    };
  }

  Map<String, dynamic> _buildPromptAssemblyPayload({
    required List<Map<String, dynamic>> systemAssemblyEntries,
    required PluginPromptBuildResult pluginPromptBuild,
    required int messagesBeforeSystemCount,
    required int messagesAfterSystemCount,
    required List<Map<String, dynamic>> finalMessages,
    required int toolsCount,
  }) {
    final finalSystemPrompt = [
      for (final entry in systemAssemblyEntries)
        (entry['content'] ?? '').toString().trim(),
    ].where((content) => content.isNotEmpty).join('\n\n');

    return <String, dynamic>{
      'systemEntries': systemAssemblyEntries,
      'pluginPrompts': pluginPromptBuild.toJson(),
      'finalSystemPrompt': finalSystemPrompt,
      'insertedSystemMessage': finalSystemPrompt.isNotEmpty,
      'messagesCountBeforeSystem': messagesBeforeSystemCount,
      'messagesCountAfterSystem': messagesAfterSystemCount,
      'messagesCountAfterTruncate': finalMessages.length,
      'wasTruncated': finalMessages.length < messagesAfterSystemCount,
      'finalMessageRoles': <String>[
        for (final message in finalMessages) (message['role'] ?? '').toString(),
      ],
      'toolsCount': toolsCount,
    };
  }

  String _formatTimezoneOffset(Duration offset) {
    final totalMinutes = offset.inMinutes;
    final sign = totalMinutes >= 0 ? '+' : '-';
    final absoluteMinutes = totalMinutes.abs();
    final hours = (absoluteMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (absoluteMinutes % 60).toString().padLeft(2, '0');
    return '$sign$hours:$minutes';
  }

  String? _formatElapsedForTrace(Duration elapsed) {
    final totalMinutes = elapsed.inMinutes;
    if (totalMinutes < 1) return '不足1分钟';

    final days = elapsed.inDays;
    final hours = elapsed.inHours;

    if (days >= 1) {
      final remainHours = hours - days * 24;
      if (remainHours > 0) {
        return '$days天${remainHours}小时';
      }
      return '$days天';
    }

    if (hours >= 1) {
      final remainMinutes = totalMinutes - hours * 60;
      if (remainMinutes > 0) {
        return '$hours小时${remainMinutes}分钟';
      }
      return '$hours小时';
    }

    return '$totalMinutes分钟';
  }

  /// 准备历史消息
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
  ///
  /// 这个方法用于“发送上下文”构建，避免受 UI 分页加载数量影响。
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
  ///
  /// 与 [prepareHistory] 的切片规则保持一致，但数据源改为数据库，
  /// 确保手动删除消息不会进入上下文，且不受 UI 首屏分页数量影响。
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
    // Respect the "new topic" marker: only messages after the marker are
    // eligible for model context.
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

/// Provider
final chatSendServiceProvider = Provider((ref) => ChatSendService(ref));
