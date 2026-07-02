library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../domain/persona_prompt_codec.dart';
import '../../settings/app_settings.dart';
import '../../settings/provider_detail/provider_detail_support.dart';
import '../../plugins/image/image_config.dart';
import '../../plugins/image/image_plugin.dart';
import '../../plugins/memory/memory_plugin.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/time_awareness/time_awareness_plugin.dart';
import '../../plugins/tts/tts_plugin.dart';
import '../../observability/trace_models.dart';
import '../../observability/trace_store.dart';
import '../../../core/app_logger.dart';
import '../../../core/models/message_block.dart';
import '../../../core/services/multimodal_assistant_service.dart';
import '../../../core/services/prompt_tag_semantics_service.dart';
import '../../../core/services/system_reminder_service.dart';
import '../../../core/utils/token_estimator.dart';
import 'chat_plugin_context_builder.dart';
import 'chat_request_config.dart';
import 'chat_request_message_builder.dart';
import 'chat_send_api_runner.dart';
import 'chat_send_trace_payload_builder.dart';
import 'chat_types.dart';

typedef ChatSupportsNonVisionImageFlow = bool Function({
  required AppSettings settings,
  required String modelRef,
});

typedef ChatPreviousUserMessageTimeResolver = DateTime? Function(
  List<Message> history,
);

/// 后台发送执行服务：聊天主链路唯一运行时请求装配入口。
///
/// 所有真实发送前的 prompt 组装、tool 收集、reminder 插入、token 截断、
/// trace 记录与模型调用，都应收口在这里完成。
class ChatSendBackendService {
  static const String _logTag = 'ChatSendBackendService';
  static const Set<String> _managedTagSemanticsPluginIds = <String>{
    'tts',
    'image',
  };
  static const Set<String> _chatRoleSeparatedPluginIds = <String>{};
  static const String _internalImageContextRule =
      '<image source="history" ...>...</image> 是内部图片上下文记录，只供理解，不是发给用户的话，'
      '也不是新的生图指令，禁止原样输出这段标记。只有你当前这轮主动输出的普通 '
      '<image>英文提示词</image> 或稳定模式发送占位 <image></image> 才表示真的要发图。';

  ChatSendBackendService(
    this._ref, {
    required Future<String?> Function(String imagePath) readImageAsBase64,
    required ChatSupportsNonVisionImageFlow shouldUseNonVisionImageFlow,
    required ChatPreviousUserMessageTimeResolver
        resolveTimeAwarenessPreviousUserMessageTime,
    ChatSendApiRunner apiRunner = const ChatSendApiRunner(),
    ChatPluginContextBuilder pluginContextBuilder =
        const ChatPluginContextBuilder(),
    ChatRequestConfigBuilder? requestConfigBuilder,
    ChatSendTracePayloadBuilder tracePayloadBuilder =
        const ChatSendTracePayloadBuilder(),
    SystemReminderService systemReminderService = const SystemReminderService(),
    PromptTagSemanticsService promptTagSemanticsService =
        const PromptTagSemanticsService(),
  })  : _readImageAsBase64 = readImageAsBase64,
        _shouldUseNonVisionImageFlow = shouldUseNonVisionImageFlow,
        _resolveTimeAwarenessPreviousUserMessageTime =
            resolveTimeAwarenessPreviousUserMessageTime,
        _apiRunner = apiRunner,
        _pluginContextBuilder = pluginContextBuilder,
        _requestConfigBuilder =
            requestConfigBuilder ?? ChatRequestConfigBuilder(),
        _tracePayloadBuilder = tracePayloadBuilder,
        _systemReminderService = systemReminderService,
        _promptTagSemanticsService = promptTagSemanticsService;

  final Ref _ref;
  final Future<String?> Function(String imagePath) _readImageAsBase64;
  final ChatSupportsNonVisionImageFlow _shouldUseNonVisionImageFlow;
  final ChatPreviousUserMessageTimeResolver
      _resolveTimeAwarenessPreviousUserMessageTime;
  final ChatSendApiRunner _apiRunner;
  final ChatPluginContextBuilder _pluginContextBuilder;
  final ChatRequestConfigBuilder _requestConfigBuilder;
  final ChatSendTracePayloadBuilder _tracePayloadBuilder;
  final SystemReminderService _systemReminderService;
  final PromptTagSemanticsService _promptTagSemanticsService;

  late final ChatRequestMessageBuilder _requestMessageBuilder =
      ChatRequestMessageBuilder(
    readImageAsBase64: _readImageAsBase64,
    multimodalAssistantService: _ref.read(multimodalAssistantServiceProvider),
  );

  /// 为聊天主链路准备最终 `ApiConfig`。
  ///
  /// 这是当前运行时唯一的请求装配真入口：
  /// - 统一收口 persona / tag semantics / plugin prompts / reminders
  /// - 统一收口 tools、provider config、token 裁剪与 trace
  /// - 不要再把新的主链路装配逻辑加回旧的 `ChatRequestBuilder`
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
          source: 'ChatSendBackendService',
          meta: {
            'historyCount': history.length,
            'hasUserText': (userText?.trim().isNotEmpty ?? false),
          },
        ),
      );
    }

    final modelRef = requestConfig.modelRef;
    final modelFull = requestConfig.modelFullId;
    final supportsVision = !_shouldUseNonVisionImageFlow(
      settings: settings,
      modelRef: modelRef,
    );
    final effectiveImageRoute =
        settings.resolveEffectiveImageGenerationRoute(modelRef);
    final shouldUseStableImageRoute =
        effectiveImageRoute == EffectiveImageGenerationRoute.stable;
    final shouldUseFastImageRoute =
        effectiveImageRoute == EffectiveImageGenerationRoute.fast;
    var reqMessages = await _requestMessageBuilder.buildRequestMessages(
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
    final includeInternalImageRule = _containsInternalImageContext(reqMessages);
    final systemParts = <String>[];
    if (personaParts.userPrompt.isNotEmpty) {
      systemParts.add(personaParts.userPrompt);
    }
    if (includeInternalImageRule) {
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
      excludedPluginIds: _chatRoleSeparatedPluginIds,
    );
    final imagePlugin = effectivePlugins.whereType<ImagePlugin>().firstOrNull;
    final ttsPlugin = effectivePlugins.whereType<TtsPlugin>().firstOrNull;
    final timeAwarenessPlugin =
        effectivePlugins.whereType<TimeAwarenessPlugin>().firstOrNull;
    final previousUserMessageTime =
        _resolveTimeAwarenessPreviousUserMessageTime(history);
    final requestTime = DateTime.now();
    var systemReminderContent = '';
    final reminderContents = <String>[];
    if (timeAwarenessPlugin != null && timeAwarenessPlugin.enabled) {
      final reminderPayload = timeAwarenessPlugin.buildSystemReminderPayload(
        currentTime: requestTime,
        previousUserMessageTime: previousUserMessageTime,
      );
      if (reminderPayload != null) {
        final content = _systemReminderService.buildReminderContent(
          reminderPayload,
        );
        if (content.isNotEmpty) {
          reminderContents.add(content);
        }
      }
    }
    final imageFailureReminderContent =
        _buildImageFailureReminderContent(history);
    if (imageFailureReminderContent != null &&
        imageFailureReminderContent.isNotEmpty) {
      reminderContents.add(imageFailureReminderContent);
    }
    systemReminderContent =
        _systemReminderService.mergeReminderContents(reminderContents);
    if (systemReminderContent.isNotEmpty) {
      reqMessages = _systemReminderService.insertReminderBeforeLastUser(
        messages: reqMessages,
        reminderContent: systemReminderContent,
      );
    }
    final pluginPromptBuild =
        await _pluginContextBuilder.buildPluginPromptEntriesWithFilter(
      effectivePlugins,
      userMessage: userText ?? '',
      supportsToolCalling: supportsToolCalling,
      conversationId: resolvedConversationId,
      excludedPluginIds: _managedTagSemanticsPluginIds,
    );
    final shouldInjectManagedFastImagePrompt =
        imagePlugin != null && imagePlugin.enabled && shouldUseFastImageRoute;
    final systemReminderTagPrompt = systemReminderContent.isEmpty
        ? null
        : _buildSystemReminderTagPrompt(timeAwarenessPlugin);
    final ttsTagPrompt = ttsPlugin?.buildTagSemanticsPrompt();
    final imageTagPrompt = shouldInjectManagedFastImagePrompt
        ? imagePlugin.buildTagSemanticsPrompt(
            customDrawingPrompt: personaParts.customDrawingPrompt,
          )
        : null;
    final tagSemanticsSnapshot = _promptTagSemanticsService.buildSnapshot(
      <PromptTagSemanticsEntry>[
        if (systemReminderTagPrompt != null &&
            systemReminderTagPrompt.isNotEmpty)
          PromptTagSemanticsEntry(
            id: 'system-reminder',
            tagName: '<system-reminder>',
            prompt: systemReminderTagPrompt,
          ),
        if (ttsTagPrompt != null && ttsTagPrompt.isNotEmpty)
          PromptTagSemanticsEntry(
            id: 'tts',
            tagName: '<tts>',
            prompt: ttsTagPrompt,
          ),
        if (imageTagPrompt != null && imageTagPrompt.isNotEmpty)
          PromptTagSemanticsEntry(
            id: 'image',
            tagName: '<image>',
            prompt: imageTagPrompt,
          ),
      ],
    );
    if (tagSemanticsSnapshot.mergedPrompt.isNotEmpty) {
      systemParts.add(tagSemanticsSnapshot.mergedPrompt);
    }
    if (shouldInjectManagedFastImagePrompt &&
        (imageTagPrompt == null || imageTagPrompt.isEmpty)) {
      final fallbackImagePrompt = imagePlugin.buildInlineImageSystemPrompt(
        customDrawingPrompt: personaParts.customDrawingPrompt,
      );
      if (fallbackImagePrompt.isNotEmpty) {
        systemParts.add(fallbackImagePrompt);
      }
    }
    for (final promptEntry in pluginPromptBuild.entries) {
      if (!promptEntry.injected) continue;
      systemParts.add(promptEntry.content);
    }

    List<Map<String, dynamic>>? tools;
    if (supportsToolCalling) {
      var aiTools = await _pluginContextBuilder.collectPluginToolsWithRetry(
        effectivePlugins,
      );
      if (shouldUseFastImageRoute) {
        aiTools = aiTools.where((tool) => tool.name != 'draw_image').toList();
      }
      if (aiTools.isNotEmpty) {
        tools = aiTools.map((t) => t.toOpenAISchema()).toList();
        if (shouldUseStableImageRoute) {
          tools = _applyRoleBoundDrawImageToolPreset(
            tools: tools,
            imageConfig: imageConfig,
            toolPresetName: boundImageToolPresetName,
            customDrawingPrompt: personaParts.customDrawingPrompt,
          );
        }
        AppLogger.debug(_logTag, '收集到工具定义', metadata: {
          'toolCount': tools.length,
          'toolNames': aiTools.map((t) => t.name).toList(),
        });
      }
    }

    final systemAssemblyEntries =
        _tracePayloadBuilder.buildSystemAssemblyEntries(
      personaPrompt: personaParts.userPrompt,
      includeInternalImageRule: includeInternalImageRule,
      internalImageContextRule: _internalImageContextRule,
      tagSemanticsPrompt: tagSemanticsSnapshot.mergedPrompt,
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
    final finalMessages = _systemReminderService.normalizeReminderPlacement(
      messages: truncatedMessages,
    );

    if (finalMessages.length < reqMessages.length) {
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
            (finalMessages.length - systemCount).clamp(0, history.length);
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
      final payloadRef = await TraceStore.instance.writePayload(
        traceId: traceContext.traceId,
        sessionId: traceContext.sessionId,
        turnId: traceContext.turnId,
        stage: TraceStage.apiConfigReady.value,
        source: 'ChatSendBackendService',
        payload: {
          'runtimeContext': _tracePayloadBuilder.buildRuntimeContextPayload(
            now: requestTime,
            previousUserMessageTime: previousUserMessageTime,
            effectivePlugins: effectivePlugins,
            historyCount: history.length,
            systemReminderInjected: systemReminderContent.isNotEmpty,
            systemReminderContent: systemReminderContent,
          ),
          'promptAssembly': _tracePayloadBuilder.buildPromptAssemblyPayload(
            systemAssemblyEntries: systemAssemblyEntries,
            pluginPromptBuild: pluginPromptBuild,
            messagesBeforeSystemCount: messagesBeforeSystemCount,
            messagesAfterSystemCount: reqMessages.length,
            finalMessages: finalMessages,
            toolsCount: tools?.length ?? 0,
            systemReminderInjected: systemReminderContent.isNotEmpty,
            systemReminderContent: systemReminderContent,
          ),
        },
        now: requestTime,
      );
      await TraceStore.instance.record(
        traceId: traceContext.traceId,
        sessionId: traceContext.sessionId,
        turnId: traceContext.turnId,
        stage: TraceStage.apiConfigReady,
        source: 'ChatSendBackendService',
        payloadRef: payloadRef,
        meta: {
          'modelFullId': modelFull,
          'messagesCount': finalMessages.length,
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
      providerId: requestConfig.providerId,
      providerApiKeyItemId: requestConfig.providerApiKeyItemId,
      providerApiKeyItemIndex: requestConfig.providerApiKeyItemIndex,
      providerApiKeyStrategy: requestConfig.providerApiKeyStrategy,
      customConfig: requestConfig.customConfig,
      toolPrefs: toolPrefs,
      messages: finalMessages,
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
      excludedPluginIds: _chatRoleSeparatedPluginIds,
    );
    try {
      return await _apiRunner.executeApiCall(
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
    } catch (e) {
      await _markExhaustedMultiKeyFailure(config, e);
      rethrow;
    }
  }

  Future<void> _markExhaustedMultiKeyFailure(
    ApiConfig config,
    Object error,
  ) async {
    final failedKey = config.providerApiKey?.trim();
    if (failedKey == null || failedKey.isEmpty) return;
    if (config.providerApiKeyStrategy != providerMultiKeyStrategyExhaust) {
      return;
    }

    final settings = _ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return;
    final provider = settings.getProvider(config.providerId);
    if (provider == null) return;

    final patch = buildProviderMultiKeyFailurePatch(
      provider: provider,
      failedKey: failedKey,
      failedItemId: config.providerApiKeyItemId,
      failedItemIndex: config.providerApiKeyItemIndex,
      error: error,
    );
    if (!patch.changed) return;

    await _ref.read(appSettingsProvider.notifier).editProvider(
          providerId: provider.id,
          apiKeys: patch.apiKeys,
          customConfig: patch.customConfig,
        );
  }

  bool _containsInternalImageContext(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      if (_containsInternalImageContextNode(message)) {
        return true;
      }
    }
    return false;
  }

  bool _containsInternalImageContextNode(dynamic node) {
    if (node is String) {
      return ChatRequestMessageBuilder.containsInternalImageContextText(node);
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

  String? _buildImageFailureReminderContent(List<Message> history) {
    Map<String, dynamic>? lastFailurePayload;
    for (final message in history) {
      final blocks = message.blocks;
      if (blocks == null || blocks.isEmpty) continue;
      for (final block in blocks) {
        if (block is! ToolBlock) continue;
        final payload = ChatRequestMessageBuilder
            .extractInternalImageContextPayloadFromToolBlock(
          block,
        );
        if (payload == null || !_isFailedImageContextPayload(payload)) {
          continue;
        }
        lastFailurePayload = payload;
      }
    }
    if (lastFailurePayload == null) {
      return null;
    }

    final fields = <SystemReminderField>[
      const SystemReminderField(
        name: 'image_generation_failed',
        value: 'true',
      ),
    ];

    void addField(String name, Object? rawValue) {
      final value = rawValue?.toString().trim() ?? '';
      if (value.isEmpty) return;
      fields.add(SystemReminderField(name: name, value: value));
    }

    addField(
      'image_generation_failure_reason',
      lastFailurePayload['reason'],
    );
    addField(
      'image_generation_failure_raw_prompt',
      lastFailurePayload['raw_prompt'],
    );
    addField(
      'image_generation_failure_prompt',
      lastFailurePayload['prompt'],
    );

    return _systemReminderService.buildReminderContent(
      SystemReminderPayload(fields: fields),
    );
  }

  String _buildSystemReminderTagPrompt(
    TimeAwarenessPlugin? timeAwarenessPlugin,
  ) {
    final parts = <String>[
      _systemReminderService.buildReminderSemanticsPrompt(),
      if (timeAwarenessPlugin != null &&
          timeAwarenessPlugin.enabled &&
          timeAwarenessPlugin.buildSystemReminderFieldGuide().trim().isNotEmpty)
        timeAwarenessPlugin.buildSystemReminderFieldGuide(),
    ];
    return parts
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join('\n');
  }

  bool _isFailedImageContextPayload(Map<String, dynamic> payload) {
    final status = payload['status']?.toString().trim().toLowerCase();
    return status == 'failed' || payload['generation_failed'] == true;
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
}
