library;

import '../../agent_context/domain/preset_script_runtime.dart';
import '../../agent_context/domain/preset_tag_mapping.dart';
import 'dart:async';
import '../../context/application/runtime_context_service.dart';
import '../../context/domain/context_window_policy.dart';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../conversation_state/domain/conversation_state_port.dart';
import '../../conversation_state/domain/mvu_content.dart';
import '../../conversation_state/providers/conversation_state_providers.dart';
import '../../agent_context/data/silly_tavern_variable_store.dart';
import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../agent_context/domain/silly_tavern_preset_assembler.dart';
import '../../agent_context/domain/silly_tavern_regex_processor.dart';
import '../../agent_context/domain/silly_tavern_world_book.dart';
import '../../agent_context/providers/preset_recipe_provider.dart';
import '../domain/conversation.dart';
import '../domain/chat_context_preview.dart';
import '../../context/domain/context_summary.dart';
import '../../context/providers/context_providers.dart';
import '../domain/message.dart';
import '../domain/persona_prompt_codec.dart';
import '../../settings/app_settings.dart';
import '../../settings/provider_detail/provider_detail_support.dart';
import '../../plugins/image/image_config.dart';
import '../../plugins/image/drawing_preset_provider.dart';
import '../../plugins/image/image_plugin.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/prompts/plugin_prompts.dart';
import '../../plugins/sticker/sticker_config.dart';
import '../../plugins/sticker/sticker_plugin.dart';
import '../../plugins/time_awareness/time_awareness_config.dart';
import '../../plugins/time_awareness/time_awareness_plugin.dart';
import '../../plugins/web_search/web_search_plugin.dart';
import '../../plugins/tts/tts_plugin.dart';
import '../../plugins/tts/voice_preset_application.dart';
import 'tts_fallback_notification.dart';
import '../../observability/trace_models.dart';
import '../../observability/trace_store.dart';
import '../../../core/app_logger.dart';
import '../../../core/api/providers/provider_adapter.dart'
    show ProviderChatRequestOptions;
import '../../../core/api/providers/provider_adapter_factory.dart';
import '../../../core/api/thinking/thinking_level_resolver.dart';
import '../../../core/services/system_reminder_service.dart';
import 'chat_output_tag_reminder.dart';
import 'chat_plugin_context_builder.dart';
import 'chat_plugin_context_policy.dart';
import 'chat_request_config.dart';
import 'chat_request_message_builder.dart';
import 'api_runner.dart';
import 'chat_send_trace_payload_builder.dart';
import 'chat_types.dart';

typedef ChatSupportsNonVisionImageFlow =
    bool Function({required AppSettings settings, required String modelRef});

typedef ChatPreviousUserMessageTimeResolver =
    DateTime? Function(List<Message> history);

const _inlinePromptPresetName = '辅助提示词';

const _neutralUserNameHint =
    '提示词中的“$kNeutralUserName”只是对对话另一方的指代，不是对方的名字；'
    '称呼对方时以角色设定中的称呼为准。';

/// 后台发送执行服务：聊天主链路唯一运行时请求装配入口。
///
/// 所有真实发送前的 prompt 组装、tool 收集、reminder 插入、自动压缩、
/// trace 记录与模型调用，都应收口在这里完成。
class ChatSendBackendService {
  static const String _logTag = 'ChatSendBackendService';
  ChatSendBackendService(
    this._ref, {
    required Future<String?> Function(String imagePath) readImageAsBase64,
    required ChatSupportsNonVisionImageFlow shouldUseNonVisionImageFlow,
    required ChatPreviousUserMessageTimeResolver
    resolveTimeAwarenessPreviousUserMessageTime,
    ApiRunner? apiRunner,
    ChatPluginContextBuilder pluginContextBuilder =
        const ChatPluginContextBuilder(),
    ChatRequestConfigBuilder? requestConfigBuilder,
    ChatSendTracePayloadBuilder tracePayloadBuilder =
        const ChatSendTracePayloadBuilder(),
    SystemReminderService systemReminderService = const SystemReminderService(),
    SillyTavernPresetAssembler sillyTavernPresetAssembler =
        const SillyTavernPresetAssembler(),
    SillyTavernVariableStore? sillyTavernVariableStore,
    SillyTavernRegexProcessor sillyTavernRegexProcessor =
        const SillyTavernRegexProcessor(),
    TavernWorldScannerPort worldScanner = const TavernWorldScanner(),
  }) : _readImageAsBase64 = readImageAsBase64,
       _shouldUseNonVisionImageFlow = shouldUseNonVisionImageFlow,
       _resolveTimeAwarenessPreviousUserMessageTime =
           resolveTimeAwarenessPreviousUserMessageTime,
       _apiRunner =
           apiRunner ?? createApiRunner(useKernel: kAgentKernelChat),
       _pluginContextBuilder = pluginContextBuilder,
       _requestConfigBuilder =
           requestConfigBuilder ?? ChatRequestConfigBuilder(),
       _tracePayloadBuilder = tracePayloadBuilder,
       _systemReminderService = systemReminderService,
       _sillyTavernPresetAssembler = sillyTavernPresetAssembler,
       _sillyTavernVariableStore =
           sillyTavernVariableStore ?? SillyTavernVariableStore(),
       _sillyTavernRegexProcessor = sillyTavernRegexProcessor,
       _worldScanner = worldScanner;

  final Ref _ref;
  final Future<String?> Function(String imagePath) _readImageAsBase64;
  final ChatSupportsNonVisionImageFlow _shouldUseNonVisionImageFlow;
  final ChatPreviousUserMessageTimeResolver
  _resolveTimeAwarenessPreviousUserMessageTime;
  final ApiRunner _apiRunner;
  final ChatPluginContextBuilder _pluginContextBuilder;
  final ChatRequestConfigBuilder _requestConfigBuilder;
  final ChatSendTracePayloadBuilder _tracePayloadBuilder;
  final SystemReminderService _systemReminderService;
  final SillyTavernPresetAssembler _sillyTavernPresetAssembler;
  final SillyTavernVariableStore _sillyTavernVariableStore;
  final SillyTavernRegexProcessor _sillyTavernRegexProcessor;
  final TavernWorldScannerPort _worldScanner;

  late final ChatRequestMessageBuilder _requestMessageBuilder =
      ChatRequestMessageBuilder(readImageAsBase64: _readImageAsBase64);

  /// 为聊天主链路准备最终 `ApiConfig`。
  ///
  /// 这是当前运行时唯一的请求装配真入口：
  /// - 统一收口 persona / tag semantics / plugin prompts / reminders
  /// - 统一收口 tools、provider config、上下文预算与自动压缩、trace
  /// - 不要再把新的主链路装配逻辑加回旧的 `ChatRequestBuilder`
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
    int compactionPass = 0,
  }) => _prepareApiConfig(
    conv: conv,
    history: history,
    userText: userText,
    trace: trace,
    overrideModel: overrideModel,
    conversationId: conversationId,
    traceContext: traceContext,
    compactionPass: compactionPass,
  );

  /// 只读预览：走与真实发送相同的装配，返回模型将看到的完整上下文。
  ///
  /// 不补摘要、不自动压缩、不写回会话变量、不落追踪、不发送请求。
  Future<ChatContextPreview> previewContext({
    required Conversation conv,
    required List<Message> history,
  }) async {
    final collector = _ContextPreviewCollector();
    final config = await _prepareApiConfig(
      conv: conv,
      history: history,
      userText: null,
      preview: collector,
    );
    final tools = config.tools ?? const <Map<String, dynamic>>[];
    return ChatContextPreview(
      modelId: config.modelFullId,
      presetName: collector.presetName,
      messages: config.messages,
      messageTokens: [
        for (final message in config.messages)
          renderedContextTokens([message], null),
      ],
      tools: tools,
      sources: [
        for (final entry in collector.sources)
          ChatContextSource(
            label: (entry['pluginName'] ?? entry['label'] ?? entry['source'])
                .toString(),
            content: (entry['content'] ?? '').toString(),
          ),
      ],
      plugins: [
        for (final entry in collector.plugins)
          ChatContextPluginStatus(
            name: entry.pluginName,
            injected: entry.injected,
            reason: entry.error ?? entry.reason,
          ),
      ],
      inputTokens: renderedContextTokens(config.messages, config.tools),
      inputLimit: collector.inputLimit,
      notes: collector.notes,
    );
  }

  Future<ApiConfig> _prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
    int compactionPass = 0,
    _ContextPreviewCollector? preview,
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
    final resolvedProvider = ProviderAdapterFactory.resolveProvider(
      requestConfig.providerId,
      customConfig: requestConfig.customConfig,
      apiBaseUrl: requestConfig.providerApiBase,
    );
    final boundRecipeId = conv.recipeId?.trim();
    // 按请求 owner 的明确绑定／默认预设一次性读取。后续切角色或改开关不污染本轮。
    final boundPreset = await _ref
        .read(tavernCompatibilityPortProvider)
        .resolvePreset(boundRecipeId);

    // 思考档位：会话覆盖 > 模型默认 > 预设 > 软件默认（prd R1.3/R1.5）
    final effectiveThinking = resolveEffectiveThinkingLevel(
      providerType: resolvedProvider,
      modelId: _rawModelId(requestConfig.modelFullId),
      sessionLevel: conv.thinkingLevels[requestConfig.modelRef],
      modelDefaultLevel: requestConfig.modelThinkingLevel,
      presetReasoningEffort: boundPreset?.reasoningEffort,
    );
    final providerRequestOptions = ProviderChatRequestOptions(
      useSystemPrompt: boundPreset?.useSystemPrompt ?? true,
      temperature: boundPreset?.temperature,
      topP: boundPreset?.topP,
      topK: boundPreset?.topK,
      minP: boundPreset?.minP,
      topA: boundPreset?.topA,
      repetitionPenalty: boundPreset?.repetitionPenalty,
      frequencyPenalty: boundPreset?.frequencyPenalty,
      presencePenalty: boundPreset?.presencePenalty,
      seed: boundPreset?.seed,
      maxOutputTokens: boundPreset?.maxOutputTokens,
      reasoningEffort: boundPreset?.reasoningEffort,
      thinkingLevel: effectiveThinking.level,
      thinkingScheme: effectiveThinking.options.scheme,
    );

    configTrace?.note(
      '配置',
      metadata: {
        'thinkingLevel': effectiveThinking.level.name,
        'thinkingSource': effectiveThinking.source.name,
        'thinkingScheme': effectiveThinking.options.scheme.name,
        'ttsEnabled': settings.ttsEnabled,
        'autoTools': toolPrefs['auto_tools_enabled'] == true,
        'enabledToolsCount':
            (toolPrefs['mcp_enabled_tools'] as List?)?.length ?? 0,
      },
    );
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

    final originalHistory = history;
    final context = _ref.read(conversationContextProvider);
    final automaticHandoff = await context.loadAuto(
      resolvedConversationId,
      conv.contextStartMessageId,
      originalHistory,
    );
    if (automaticHandoff != null) {
      final covered = automaticHandoff.sourceIds.toSet();
      history = history.where((m) => !covered.contains(m.id)).toList();
    }
    final modelRef = requestConfig.modelRef;
    final modelFull = requestConfig.modelFullId;
    final supportsVision = !_shouldUseNonVisionImageFlow(
      settings: settings,
      modelRef: modelRef,
    );
    final effectiveImageRoute = settings.resolveEffectiveImageGenerationRoute(
      modelRef,
    );
    final shouldUseStableImageRoute =
        effectiveImageRoute == EffectiveImageGenerationRoute.stable;
    final shouldUseFastImageRoute =
        effectiveImageRoute == EffectiveImageGenerationRoute.fast;
    if (resolvedConversationId != conv.id) {
      throw StateError('请求联系人与角色上下文不一致');
    }
    // 边界缺摘要时会先补整理；重放旧轮次时不倒灌之后的摘要。
    final handoff = preview == null
        ? await context.manualSummary(
            resolvedConversationId,
            conv.contextStartMessageId,
            history,
          )
        : await _previewManualSummary(
            resolvedConversationId,
            conv.contextStartMessageId,
            history,
            preview,
          );
    final handoffPrompt = [
      handoff?.prompt ?? '',
      automaticHandoff?.prompt ?? '',
    ].where((part) => part.isNotEmpty).join('\n\n');
    final personaParts = PersonaPromptCodec.parse(conv.personaPrompt);
    final imageEnabled =
        settings.imageGenerationEnabled &&
        (conv.enabledPlugins == null || conv.enabledPlugins!.contains('image'));
    // 标签／工具说明全局一份，覆盖预设与插件配置里的旧副本。
    final pluginPrompts = await _ref.read(pluginPromptsProvider.future);
    final imageConfig =
        (imageEnabled
                ? (await _ref
                          .read(drawingPresetCatalogProvider.notifier)
                          .resolveForPersona(conv.personaPrompt))
                      .config
                : _ref.read(imagePluginConfigProvider))
            .copyWith(
              fastPromptPresets: [
                DrawingPromptPreset(
                  name: _inlinePromptPresetName,
                  content: pluginPrompts.of(PluginPromptSlot.image),
                ),
              ],
              selectedFastPromptPresetName: _inlinePromptPresetName,
            );
    // 旧选择已经在预设迁移中收成值，不能在执行时再覆盖快照。
    const String? boundImageToolPresetName = null;
    const String? boundImageArtistPresetName = null;
    final modelSupportsTools =
        settings.hasChatModelCapability(modelRef, ChatModelCapability.tools) &&
        !settings.isModelToolCallingDisabled(modelRef);
    final supportsToolCalling =
        boundPreset?.functionCalling != false && modelSupportsTools;
    final enabledPluginIds = conv.enabledPlugins?.toSet();
    final voiceRequest = await _ref
        .read(voicePresetApplicationProvider)
        .forRole(conv);
    if (preview == null &&
        voiceRequest.error != null &&
        _ref.read(ttsPluginConfigProvider).enabled &&
        (enabledPluginIds == null || enabledPluginIds.contains('tts'))) {
      _ref
          .read(ttsFallbackNotificationServiceProvider)
          .notify(voiceRequest.error!);
    }
    final pluginManager = _ref.read(pluginManagerProvider);
    final effectivePlugins = _pluginContextBuilder
        .getEffectivePlugins(
          pluginManager: pluginManager,
          enabledPluginIds: enabledPluginIds,
        )
        .map(
          (plugin) => plugin is ImagePlugin
              ? ImagePlugin(
                  imageConfig,
                  _ref,
                  requestSettings: settings,
                  isRequestSnapshot: true,
                )
              : plugin is TtsPlugin
              ? TtsPlugin.forRequest(
                  voiceRequest,
                  systemPromptTemplate: pluginPrompts.of(PluginPromptSlot.tts),
                )
              : plugin is StickerPlugin
              ? StickerPlugin(
                  StickerConfig.fromJson(plugin.getConfig()).copyWith(
                    systemPromptTemplate: pluginPrompts.of(
                      PluginPromptSlot.sticker,
                    ),
                  ),
                )
              : plugin is TimeAwarenessPlugin
              ? TimeAwarenessPlugin(
                  TimeAwarenessConfig.fromJson(plugin.getConfig()).copyWith(
                    currentTimePromptTemplate: pluginPrompts.of(
                      PluginPromptSlot.currentTime,
                    ),
                  ),
                )
              : plugin,
        )
        .toList(growable: false);
    final imagePlugin = effectivePlugins.whereType<ImagePlugin>().firstOrNull;
    final contextPolicy = ChatPluginContextPolicy.firstParty(
      activeProviderIds: {
        for (final plugin in effectivePlugins)
          if (plugin.enabled) plugin.id,
      },
    );
    var reqMessages = await _requestMessageBuilder.buildRequestMessages(
      history,
      settings: settings,
      supportsVision: supportsVision,
      pluginPolicy: contextPolicy,
      inlineImagePrompts: !shouldUseStableImageRoute,
    );

    reqMessages = contextPolicy.filterMessages(reqMessages);
    // 历史回复里的 MVU 更新块只在请求副本中去掉，状态改由宏注入（ADR0071）。
    reqMessages = stripMvuUpdatesFromHistory(reqMessages);
    final includeInternalImageRule = _containsInternalImageContext(reqMessages);
    final systemParts = <String>[];
    if (boundPreset == null && personaParts.userPrompt.isNotEmpty) {
      systemParts.add(contextPolicy.filterText(personaParts.userPrompt));
    }
    if (handoffPrompt.isNotEmpty) {
      systemParts.add(contextPolicy.filterText(handoffPrompt));
    }
    final timeAwarenessPlugin = effectivePlugins
        .whereType<TimeAwarenessPlugin>()
        .firstOrNull;
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
    final imageFailureReminderContent = imagePlugin
        ?.buildImageFailureReminderContent(history);
    if (imageFailureReminderContent != null &&
        imageFailureReminderContent.isNotEmpty) {
      reminderContents.add(imageFailureReminderContent);
    }
    final imageActive = imagePlugin?.enabled ?? false;
    final outputTagReminder = buildOutputTagReminder(
      imageInline: imageActive && shouldUseFastImageRoute,
      imageTool:
          imageActive && shouldUseStableImageRoute && supportsToolCalling,
      tts: effectivePlugins.whereType<TtsPlugin>().any((p) => p.enabled),
      presetTags: boundPreset == null
          ? const <String>[]
          : inferPresetTagMapping(boundPreset).rules.map((rule) => rule.name),
    );
    if (outputTagReminder.isNotEmpty) {
      reminderContents.add(outputTagReminder);
    }
    systemReminderContent = _systemReminderService.mergeReminderContents(
      reminderContents,
    );
    if (boundPreset == null && systemReminderContent.isNotEmpty) {
      reqMessages = _systemReminderService.insertReminderBeforeLastUser(
        messages: reqMessages,
        reminderContent: systemReminderContent,
      );
    }
    final rawPluginPromptBuild = await _pluginContextBuilder
        .buildPluginPromptEntriesWithFilter(
          effectivePlugins,
          userMessage: userText ?? '',
          supportsToolCalling: supportsToolCalling,
          conversationId: resolvedConversationId,
          useFastImageRoute: shouldUseFastImageRoute,
          customDrawingPrompt: personaParts.customDrawingPrompt,
          hasInternalImageContext: includeInternalImageRule,
          hasImageFailureReminder:
              imageFailureReminderContent?.isNotEmpty ?? false,
        );
    final pluginPromptBuild = PluginPromptBuildResult(
      entries: [
        for (final entry in rawPluginPromptBuild.entries)
          PluginPromptEntry(
            order: entry.order,
            pluginId: entry.pluginId,
            pluginName: entry.pluginName,
            injected:
                entry.injected &&
                contextPolicy.filterText(entry.content).trim().isNotEmpty,
            content: contextPolicy.filterText(entry.content),
            reason: entry.reason,
            error: entry.error,
          ),
      ],
    );
    for (final promptEntry in pluginPromptBuild.entries) {
      if (!promptEntry.injected) continue;
      systemParts.add(contextPolicy.filterText(promptEntry.content));
    }

    List<Map<String, dynamic>>? tools;
    List<AITool> boundTools = const [];
    if (supportsToolCalling) {
      var aiTools = await _pluginContextBuilder.collectPluginToolsWithRetry(
        effectivePlugins,
        conversationId: resolvedConversationId,
      );
      if (shouldUseFastImageRoute) {
        aiTools = aiTools.where((tool) => tool.name != 'draw_image').toList();
      }
      boundTools = List.unmodifiable(aiTools);
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
        AppLogger.debug(
          _logTag,
          '收集到工具定义',
          metadata: {
            'toolCount': tools.length,
            'toolNames': aiTools.map((t) => t.name).toList(),
          },
        );
      }
    }

    final systemAssemblyEntries = _tracePayloadBuilder
        .buildSystemAssemblyEntries(
          personaPrompt: boundPreset == null
              ? contextPolicy.filterText(personaParts.userPrompt)
              : '',
          handoffPrompt: contextPolicy.filterText(handoffPrompt),
          pluginPromptBuild: pluginPromptBuild,
        );
    // 关闭 {{user}} 名称时预设只拿到中性指代，提示模型称呼仍以角色设定为准。
    if (boundPreset != null && !boundPreset.userNameMacroEnabled) {
      systemParts.add(_neutralUserNameHint);
    }
    systemParts.removeWhere((part) => part.trim().isEmpty);
    final userName = settings.userName?.trim() ?? '';
    final promptUserName =
        boundPreset?.userNameMacroEnabled != false && userName.isNotEmpty
        ? userName
        : kNeutralUserName;
    final messagesBeforeSystemCount = reqMessages.length;
    final maxContextTokens = math.min(
      boundPreset?.maxContextTokens ?? settings.getMaxContextTokens(modelRef),
      settings.getMaxContextTokens(modelRef),
    );
    SillyTavernAssemblyResult? presetAssembly;
    SillyTavernRegexMessagesResult? presetRegexPromptResult;
    SillyTavernVariableSnapshot? presetVariableSnapshot;
    var presetVariablesPersisted = false;
    final presetRuntimeWarnings = <String>[];
    TavernWorldScanResult? worldScan;
    List<Map<String, dynamic>> truncatedMessages;
    if (boundPreset != null) {
      final mvuView = await _readMvuState(
        conv: conv,
        conversationId: resolvedConversationId,
        preset: boundPreset,
        userName: promptUserName,
      );
      final mvuState = mvuView.active ? mvuView.mvu : null;
      presetRegexPromptResult = await _sillyTavernRegexProcessor
          .applyToPromptMessages(
            messages: reqMessages,
            scripts: boundPreset.regexScripts,
            authorized: boundPreset.regexAuthorized,
          );
      reqMessages = contextPolicy.filterMessages(
        presetRegexPromptResult.messages,
      );
      worldScan = await _worldScanner.scan(
        books: boundPreset.worldBooks,
        messages: reqMessages,
        tokenBudget:
            ((maxContextTokens - (boundPreset.maxOutputTokens ?? 2048)) ~/ 4)
                .clamp(0, 65536),
        macroValues: {
          'char': conv.displayName.trim().isEmpty
              ? conv.title
              : conv.displayName,
          'user': promptUserName,
          'description': contextPolicy.filterText(personaParts.userPrompt),
          'scenario': conv.description?.trim() ?? '',
        },
        entrySkips: mvuWorldEntrySkips(
          boundPreset.worldBooks,
          mvuActive: mvuState != null,
        ),
      );
      worldScan = await _sillyTavernRegexProcessor.applyToWorldInfo(
        scan: worldScan,
        scripts: boundPreset.regexScripts,
        authorized: boundPreset.regexAuthorized,
      );
      presetVariableSnapshot = await _sillyTavernVariableStore.load(
        presetId: boundPreset.id,
        conversationId: resolvedConversationId,
      );
      final reminderMessage = systemReminderContent.isEmpty
          ? null
          : _systemReminderService.buildReminderMessage(
              reminderContent: systemReminderContent,
            );
      presetAssembly = _sillyTavernPresetAssembler.assemble(
        preset: boundPreset,
        historyMessages: reqMessages,
        context: SillyTavernAssemblyContext(
          characterName: conv.displayName.trim().isEmpty
              ? conv.title
              : conv.displayName,
          userName: promptUserName,
          characterDescription: contextPolicy.filterText(
            personaParts.userPrompt,
          ),
          scenario: conv.description?.trim() ?? '',
          // 酒馆仅在主提示词/越狱提示词被外部 override 时为
          // {{original}} 提供被覆盖前文本；AIcove 当前没有该 override 层。
          original: '',
          runtimeSystemContent: systemParts.join('\n\n'),
          protectedRuntimeMessages: <Map<String, dynamic>>[
            if (reminderMessage != null) reminderMessage,
          ],
          initialVariables: presetVariableSnapshot.values,
          initialWarnings: [
            ...presetVariableSnapshot.warnings,
            ...worldScan.warnings,
            ...mvuView.diagnostics,
          ],
          worldInjections: worldScan.injections,
          messageVariables: mvuState == null
              ? null
              : <String, Object?>{'stat_data': mvuState.statData},
        ),
        maxContextTokens: maxContextTokens,
        reserveTokens: boundPreset.maxOutputTokens ?? 2048,
        truncateHistory: false,
      );
      reqMessages = contextPolicy.filterMessages(presetAssembly.messages);
      truncatedMessages = reqMessages;
      systemAssemblyEntries
        ..clear()
        ..addAll(
          presetAssembly.traceEntries
              .where((entry) => entry['role'] == 'system')
              .map(
                (entry) => <String, dynamic>{
                  'order': entry['order'],
                  'source': entry['source'],
                  'label': entry['label'],
                  'content': contextPolicy.filterText(
                    (entry['content'] ?? '').toString(),
                  ),
                },
              ),
        );
    } else {
      if (systemParts.isNotEmpty) {
        reqMessages.insert(0, {
          'role': 'system',
          'content': systemParts.join('\n\n'),
        });
      }
      reqMessages = contextPolicy.filterMessages(reqMessages);
      truncatedMessages = reqMessages;
    }
    systemAssemblyEntries.removeWhere(
      (entry) => (entry['content'] ?? '').toString().trim().isEmpty,
    );
    var finalMessages = _systemReminderService.normalizeReminderPlacement(
      messages: contextPolicy.filterMessages(truncatedMessages),
    );

    final policy = ContextWindowPolicy(
      configured: settings.contextWindowTokens,
      modelWindow: maxContextTokens,
      outputReserve: boundPreset?.maxOutputTokens ?? 2048,
    );
    var inputTokens = renderedContextTokens(finalMessages, tools);
    final inputLimit = policy.trigger;
    final runtimeContext = RuntimeContextService(
      owner: resolvedConversationId,
      policy: policy,
      summarizerFactory: () => _ref.read(contextSummarizerProvider.future),
      tools: tools,
    );
    if (preview != null) {
      preview.inputLimit = inputLimit;
      if (inputTokens >= inputLimit) {
        preview.notes.add('已达到自动压缩阈值，真实发送前会先压缩，实际内容会比这里短');
      }
    } else if (inputTokens >= inputLimit) {
      finalMessages = await runtimeContext.pruneToolResults(finalMessages);
      inputTokens = renderedContextTokens(finalMessages, tools);
    }
    final uncoveredUsers = originalHistory
        .where(
          (m) =>
              m.role == 'user' &&
              !(automaticHandoff?.sourceIds.contains(m.id) ?? false),
        )
        .length;
    if (preview != null) {
      // 预览只读，不压缩。
    } else if (inputTokens >= inputLimit && uncoveredUsers < 2) {
      finalMessages = await runtimeContext.prepare(finalMessages);
    } else if (inputTokens >= inputLimit) {
      AppLogger.info(
        'AutomaticContext',
        '达到上下文窗口，先压缩再发送',
        metadata: {
          'conversationId': resolvedConversationId,
          'inputTokens': inputTokens,
          'inputLimit': inputLimit,
          'pass': compactionPass,
        },
      );
      if (compactionPass >= 2) {
        throw const ContextCompactionException(
          '自动压缩后仍超过上下文窗口，本轮未发送；请缩短当前消息或角色设置。',
        );
      }
      await context.compactAuto(
        ownerId: resolvedConversationId,
        topicBoundary: conv.contextStartMessageId,
        history: originalHistory,
        previous: automaticHandoff,
        keepOnlyLatestTurn: compactionPass > 0,
        retainTokens: policy.retain,
      );
      return prepareApiConfig(
        conv: conv,
        history: originalHistory,
        userText: userText,
        trace: trace,
        overrideModel: overrideModel,
        conversationId: conversationId,
        traceContext: traceContext,
        compactionPass: compactionPass + 1,
      );
    }
    if (preview == null &&
        boundPreset != null &&
        presetAssembly != null &&
        presetVariableSnapshot != null) {
      try {
        presetVariablesPersisted = await _sillyTavernVariableStore
            .saveIfChanged(
              presetId: boundPreset.id,
              conversationId: resolvedConversationId,
              previousValues: presetVariableSnapshot.values,
              values: presetAssembly.variables,
            );
      } catch (error) {
        presetRuntimeWarnings.add('会话变量写入失败，本轮求值已生效但下轮不会继承');
        AppLogger.warning(
          _logTag,
          '酒馆预设变量写入失败',
          metadata: <String, dynamic>{
            'recipeId': boundPreset.id,
            'errorType': error.runtimeType.toString(),
          },
        );
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
            presetAssembly: <String, dynamic>{
              if (boundRecipeId != null && boundRecipeId.isNotEmpty)
                'recipeId': boundRecipeId,
              if (boundPreset != null) ...<String, dynamic>{
                'effectivePresetId': boundPreset.id,
                'presetName': boundPreset.name,
                'worldInfo': worldScan?.traces,
                'sourceFormat': boundPreset.sourceFormat,
                'selectedOrderIndex': boundPreset.selectedOrder.sourceIndex,
                if (boundPreset.selectedOrder.characterId != null)
                  'selectedOrderCharacterId':
                      boundPreset.selectedOrder.characterId,
                'historyIncluded': presetAssembly?.historyIncluded,
                'maxContextTokens': maxContextTokens,
                'maxOutputTokens': boundPreset.maxOutputTokens,
                'functionCalling': boundPreset.functionCalling,
                'toolsEffectiveCount': tools?.length ?? 0,
                'useSystemPrompt': boundPreset.useSystemPrompt,
                'squashSystemMessages': boundPreset.squashSystemMessages,
                'attachmentCount': boundPreset.attachmentCount,
                'assistantPrefillDeclared': boundPreset.assistantPrefill
                    .trim()
                    .isNotEmpty,
                'assistantPrefillApplied':
                    presetAssembly?.traceEntries.any(
                      (entry) => entry['source'].toString().contains(
                        'preset.assistantPrefill',
                      ),
                    ) ??
                    false,
                'warnings': <String>[
                  ...?presetAssembly?.warnings,
                  ...?presetRegexPromptResult?.warnings,
                  ...presetRuntimeWarnings,
                ],
                'appliedMacros':
                    presetAssembly?.appliedMacros.toList() ?? const <String>[],
                'unknownMacros':
                    presetAssembly?.unknownMacros.toList() ?? const <String>[],
                'variableCount': presetAssembly?.variables.length ?? 0,
                'variablesPersisted': presetVariablesPersisted,
                'regex': <String, dynamic>{
                  'declared': boundPreset.regexScriptCount,
                  'authorized': boundPreset.regexAuthorized,
                  'promptTrace':
                      presetRegexPromptResult?.traces ?? const <dynamic>[],
                },
                'parameterCompatibility': boundPreset.parameterCompatibility
                    .map((entry) => entry.toTraceJson())
                    .toList(growable: false),
                'providerRequestOptions': providerRequestOptions.toTraceJson(),
                'providerParameterMapping': providerRequestOptions
                    .parameterTraceForProvider(resolvedProvider),
                'provider': resolvedProvider,
                'entries': presetAssembly?.traceEntries ?? const [],
              },
            },
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

    if (preview != null) {
      preview
        ..presetName = boundPreset?.name
        ..sources = systemAssemblyEntries
        ..plugins = pluginPromptBuild.entries;
      preview.notes.addAll([
        ...?presetAssembly?.warnings,
        ...?presetRegexPromptResult?.warnings,
      ]);
    }

    return ApiConfig(
      requestInputTokenLimit: inputLimit,
      presetScript: PresetScriptSnapshot.fromPreset(
        boundPreset,
        toolsAllowed: supportsToolCalling,
        modelSupportsTools: modelSupportsTools,
        macros: {
          'char': conv.displayName.trim().isEmpty
              ? conv.title
              : conv.displayName,
          'user': promptUserName,
          'description': contextPolicy.filterText(personaParts.userPrompt),
          'scenario': conv.description?.trim() ?? '',
        },
      ),
      runtimeContext: runtimeContext,
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
      boundTools: boundTools,
      enabledPluginIds: enabledPluginIds,
      modelTemperature:
          boundPreset?.temperature ?? requestConfig.modelTemperature,
      modelTopP: boundPreset?.topP ?? requestConfig.modelTopP,
      modelContextMessageLimit: requestConfig.modelContextMessageLimit,
      // 联网搜索插件接管时，本轮去掉模型内置搜索，只走插件工具。
      providerRequestOptions:
          supportsToolCalling &&
              effectivePlugins.whereType<WebSearchPlugin>().any(
                (plugin) => plugin.replacesModelBuiltinSearch,
              )
          ? providerRequestOptions.copyWith(disableBuiltinWebSearch: true)
          : providerRequestOptions,
      // 显示美化正则输出的 HTML 界面无法渲染，已由语义标签组件接管的不再执行，
      // 保留原标签交给聊天列表投影为折叠／正文／选项（ADR0046）。
      presetRegexScripts: boundPreset == null
          ? const <SillyTavernRegexScript>[]
          : inferPresetTagMapping(boundPreset)
              .displayScripts(boundPreset.regexScripts),
      presetRegexAuthorized: boundPreset?.regexAuthorized ?? false,
      presetStreamResponse: boundPreset?.streamResponse,
      traceContext: traceContext,
      boundImageToolPresetName: boundImageToolPresetName,
      boundImageArtistPresetName: boundImageArtistPresetName,
      drawingConfig: imageConfig,
      voiceRequest: voiceRequest,
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
    if (config.voiceRequest != null &&
        config.voiceRequest!.ownerId != sessionId) {
      throw StateError('语音请求与当前发送角色不一致');
    }
    final pluginManager = _ref.read(pluginManagerProvider);
    final effectivePlugins = _pluginContextBuilder
        .getEffectivePlugins(
          pluginManager: pluginManager,
          enabledPluginIds: config.enabledPluginIds,
        )
        .map(
          (plugin) => plugin is ImagePlugin && config.drawingConfig != null
              ? ImagePlugin(
                  config.drawingConfig!,
                  _ref,
                  requestSettings: config.settings,
                  isRequestSnapshot: true,
                )
              : plugin,
        )
        .toList();
    // A toggle/default change after prepare must not replace this turn's TTS
    // snapshot. Other plugins keep their existing lifecycle rules.
    effectivePlugins.removeWhere((plugin) => plugin is TtsPlugin);
    if (config.voiceRequest != null) {
      effectivePlugins.add(TtsPlugin.forRequest(config.voiceRequest!));
    }
    try {
      return await _apiRunner.executeApiCall(
        config: config,
        sessionId: sessionId,
        userText: userText,
        effectivePlugins: effectivePlugins,
        availableTools: config.boundTools,
        turnId: turnId,
        trace: trace,
        maxRounds: maxRounds,
        onToolExecuting: onToolExecuting,
        enableStreaming: enableStreaming,
        onStreamTextDelta: onStreamTextDelta == null
            ? null
            : (delta) {
                final request = config.voiceRequest;
                if (request == null) {
                  onStreamTextDelta(delta);
                } else {
                  request.run(() => onStreamTextDelta(delta));
                }
              },
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

    await _ref
        .read(appSettingsProvider.notifier)
        .editProvider(
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
        blocks =
            ImageConfig.decodeToolDescriptionBlocks(preset.content) ??
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
              // 尺寸描述由请求插件生成，保留其中的预设参考值。

              parameters['properties'] = properties;
            }
            function['parameters'] = parameters;
          }

          schema['function'] = function;
          return schema;
        }(),
    ];
  }

  /// 本轮 MVU 状态（ADR0071）：按请求 owner 的预设与名字固定来源；读取失败不阻塞发送。
  Future<ConversationStateView> _readMvuState({
    required Conversation conv,
    required String conversationId,
    required SillyTavernPreset preset,
    required String userName,
  }) async {
    if (!mvuAllowedFor(conv, preset)) {
      return const ConversationStateView.inactive();
    }
    try {
      return await _ref
          .read(conversationStatePortProvider)
          .read(
            conversationId,
            sources: buildMvuSourceSnapshot(
              preset: preset,
              characterName: conv.displayName.trim().isEmpty
                  ? conv.title
                  : conv.displayName,
              userName: userName,
            ),
          );
    } catch (error) {
      AppLogger.warning(
        _logTag,
        '读取 MVU 状态失败，本轮按未启用处理',
        metadata: {'errorType': error.runtimeType.toString()},
      );
      return const ConversationStateView.inactive(
        diagnostics: ['MVU 状态读取失败，本轮未注入变量'],
      );
    }
  }

  /// 预览只读已保存的话题摘要；缺摘要时真实发送会先整理，这里只提示。
  Future<ContextSummary?> _previewManualSummary(
    String ownerId,
    String? boundaryId,
    List<Message> history,
    _ContextPreviewCollector preview,
  ) async {
    if (boundaryId == null) return null;
    final summary = await _ref
        .read(contextSummaryStoreProvider)
        .manualFor(ownerId, boundaryId);
    if (summary == null) {
      preview.notes.add('话题边界还没有摘要，真实发送前会先自动整理一次');
      return null;
    }
    if (history.any((m) => summary.sourceIds.contains(m.id))) return null;
    return summary;
  }

  static String _rawModelId(String modelFullId) {
    final idx = modelFullId.indexOf(':');
    return idx < 0 ? modelFullId : modelFullId.substring(idx + 1);
  }
}

class _ContextPreviewCollector {
  String? presetName;
  List<Map<String, dynamic>> sources = const [];
  List<PluginPromptEntry> plugins = const [];
  int inputLimit = 0;
  final notes = <String>[];
}
