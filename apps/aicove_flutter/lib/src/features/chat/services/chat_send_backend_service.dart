library;

import 'dart:io';
import '../../plugins/data/tool_result_store.dart';
import '../../workspace/application/workspace_shell.dart';
import '../../workspace/application/codemode_declarations.dart';

import '../../agent_context/domain/agent_runtime_contracts.dart'
    show AgentToolAuthorization;
import '../../agent_plugins/tool_policy.dart';
import '../../assistant/application/assistant_approvals.dart';
import '../../assistant/application/assistant_plugin.dart';
import '../../assistant/application/assistant_review.dart';
import '../../assistant/application/assistant_settings_tools.dart';
import '../../assistant/application/assistant_tool_group.dart';
import '../../assistant/assistant_providers.dart';
import '../../assistant/domain/assistant_onboarding.dart'
    show kAicoveAssistantId;
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
import '../domain/role_agent_mode.dart';
import '../domain/chat_context_preview.dart';
import '../../context/domain/context_summary.dart';
import '../../context/providers/context_providers.dart';
import '../domain/message.dart';
import '../domain/persona_prompt_codec.dart';
import '../../settings/app_settings.dart';
import '../../settings/provider_detail/provider_detail_support.dart';
import '../../plugins/image/image_config.dart';
import '../../plugins/image/drawing_preset_provider.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/packages/package_plugin.dart';
import '../../plugins/image/image_plugin.dart';
import '../../plugins/prompts/plugin_prompt_resolution.dart';
import '../../plugins/prompts/plugin_prompts.dart';
import '../../plugins/prompts/prompt_pack.dart';
import '../../plugins/tts/voice_request.dart';
import '../../plugins/prompts/prompt_pack_migration.dart';
import '../../plugins/prompts/prompt_pack_store.dart';
import '../../plugins/tts/voice_preset_application.dart';
import '../../plugins/tavern_compat/tavern_compat_agent_plugin.dart';
import '../../task_agent/application/delegate_task_plugin.dart';
import '../../task_agent/domain/task_relay.dart';
import '../../workspace/application/workspace_request_scope.dart';
import '../../workspace/application/workspace_toolset.dart';
import '../../workspace/domain/workspace_grants.dart';
import '../../workspace/domain/workspace_models.dart';
import '../../workspace/webapp/webapp_launcher.dart';
import '../../workspace/workspace_providers.dart';
import '../conversation_providers.dart';
import '../../task_agent/task_agent_providers.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../agent_plugins/plugin_response.dart';
import '../../agent_plugins/plugin_runtime.dart';
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

/// Wall clock for request assembly (time-awareness reminders). Overridden in
/// tests so request copies are reproducible.
final requestClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

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
       _apiRunner = apiRunner ?? createApiRunner(),
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
  ///
  /// [persistSideEffects] 为 false 时只组装不留痕：不写酒馆预设变量，超出窗口时只做
  /// 当次的运行时压缩、不写自动摘要。给历史里带占位、不属于聊天真相源的请求用（通话）。
  ///
  /// [deferReminders] 为 true 时插件提醒（时间感知等）不插进消息，改由
  /// [ApiConfig.reminders] 在每次发送时按当时时刻现算，由调用方放到位置上（通话）。
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
    int compactionPass = 0,
    DateTime? requestTime,
    bool persistSideEffects = true,
    bool deferReminders = false,
  }) => _prepareApiConfig(
    conv: conv,
    history: history,
    userText: userText,
    trace: trace,
    overrideModel: overrideModel,
    conversationId: conversationId,
    traceContext: traceContext,
    compactionPass: compactionPass,
    requestTime: requestTime,
    persistSideEffects: persistSideEffects,
    deferReminders: deferReminders,
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
      messageTokens: ChatContextUsage.measure(
        config.messages,
        tools,
      ).messageTokens,
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
            failed: entry.error != null,
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
    DateTime? requestTime,
    bool persistSideEffects = true,
    bool deferReminders = false,
  }) async {
    final resolvedConversationId = (conversationId?.trim().isNotEmpty ?? false)
        ? conversationId!.trim()
        : conv.id;
    final configTrace = trace?.startChild('读取配置');

    await ensurePluginConfigsLoaded(_ref);
    final settings = await _ref.read(appSettingsProvider.future);
    final requestConfig = await _requestConfigBuilder.buildRequestConfig(
      settings,
      modelRef: overrideModel,
    );
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
    final providerRequestOptions = effectiveThinking.applyTo(
      ProviderChatRequestOptions(
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
      ),
    );

    configTrace?.note(
      '配置',
      metadata: {
        'thinkingLevel': effectiveThinking.level.name,
        'thinkingSource': effectiveThinking.source.name,
        'thinkingScheme': effectiveThinking.options.scheme.name,
        'ttsEnabled': settings.ttsEnabled,
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

    // ADR0088 §7: one relay per receipt reaches the model.
    history = dropSupersededTaskRelays(history);
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
    // 表情包、时间感知的说明仍是全局一份（ADR0054）；语音、绘图改由预设绑定的提示词包提供（ADR0092）。
    final pluginPrompts = await _ref.read(pluginPromptsProvider.future);
    // 旧数据先收进提示词包；角色卡的「绘图提示」在启动时并进绘图预设，
    // 还没并的这里临时补上（见下方 unmovedDrawing）。
    await _ref.read(promptPackMigratorProvider).ensurePacks();
    final promptPacks = await _ref.read(promptPackProvider.notifier).library;
    final drawingPersona = conv.personaPrompt;
    final drawingPreset = imageEnabled
        ? await _ref
              .read(drawingPresetCatalogProvider.notifier)
              .resolveForPersona(drawingPersona)
        : null;
    final ImageConfig imageConfig =
        drawingPreset?.config ?? _ref.read(imagePluginConfigProvider);
    final imageTarget = drawingPreset == null
        ? null
        : ImagePlugin(
            imageConfig,
            _ref,
            requestSettings: settings,
            isRequestSnapshot: true,
          ).promptTarget(settings);
    // Without a usable target a bound pack still applies; 「自动」 then
    // falls back to the plugin's default pack.
    ResolvedPromptPack? imagePrompts;
    if (drawingPreset != null) {
      final format = imageTarget?.format ?? 'openai';
      final model = imageTarget?.model ?? '';
      try {
        imagePrompts = resolveDrawingPrompts(
          promptPacks,
          drawingPreset,
          format: format,
          model: model,
        );
      } on PromptPackMissingException {
        // A binding to a pack that is gone never breaks the turn: this one
        // matches automatically, and the preset editor shows the problem.
        AppLogger.warning(
          'PromptPacks',
          '绘图预设绑定的提示词包已不存在，本次按模型自动匹配',
          metadata: {'presetId': drawingPreset.id},
        );
        imagePrompts = resolveDrawingPrompts(
          promptPacks,
          drawingPreset.copyWith(prompts: drawingPreset.prompts.withPack(null)),
          format: format,
          model: model,
        );
      }
    }
    // A role not moved yet (unsaved, or the move failed) still gets its
    // drawing requirement, the same way the moved one would.
    final unmovedDrawing = PersonaPromptCodec.parse(
      drawingPersona,
    ).customDrawingPrompt.trim();
    if (imagePrompts != null && unmovedDrawing.isNotEmpty) {
      // By section id: a preset that already got the sections (the role
      // write failed after the preset was saved) keeps its own copy, which
      // the user may have edited since.
      final binding = PresetPromptBinding(
        ownSections: imagePrompts.ownSections,
      ).addMissing(roleDrawingSections(unmovedDrawing));
      imagePrompts = ResolvedPromptPack(
        pack: imagePrompts.pack,
        automatic: imagePrompts.automatic,
        ownSections: binding.ownSections,
      );
    }
    // 旧选择已经在预设迁移中收成值，不能在执行时再覆盖快照。
    const String? boundImageToolPresetName = null;
    const String? boundImageArtistPresetName = null;
    final modelSupportsTools =
        settings.hasChatModelCapability(modelRef, ChatModelCapability.tools) &&
        !settings.isModelToolCallingDisabled(modelRef);
    final supportsToolCalling =
        boundPreset?.functionCalling != false && modelSupportsTools;
    final enabledPluginIds = conv.enabledPlugins?.toSet();
    var voiceRequest = await _ref
        .read(voicePresetApplicationProvider)
        .forRole(conv);
    final ttsWanted =
        _ref.read(ttsPluginConfigProvider).enabled &&
        (enabledPluginIds == null || enabledPluginIds.contains('tts'));
    var voiceProblem = voiceRequest.error;
    ResolvedPromptPack? voicePrompts;
    final voiceService = voiceRequest.service;
    if (voiceService != null) {
      try {
        voicePrompts = resolveVoicePrompts(promptPacks, voiceService);
      } on PromptPackMissingException catch (e) {
        voiceProblem = e.toString();
        // Same as an unusable preset: no voice this turn, text goes on.
        voiceRequest = VoiceRequest(
          ownerId: voiceRequest.ownerId,
          error: voiceProblem,
        );
      }
    }
    if (preview == null && voiceProblem != null && ttsWanted) {
      _ref.read(ttsFallbackNotificationServiceProvider).notify(voiceProblem);
    }
    final previousUserMessageTime =
        _resolveTimeAwarenessPreviousUserMessageTime(history);
    // 插件按自身范围贡献提示词、提醒、工具与输出标签；核心不再识别具体插件类型。
    final pluginRuntime = PluginRuntime.fromPlugins(
      _ref.read(pluginManagerProvider).getAllPlugins(),
    )..install(tavernCompatAgentPlugin());
    // ADR0088/0097: 聊天模式下，联网搜索与 MCP 交给杂活 Agent，聊天模型只拿到
    // delegate_task；工具模式是完整 Agent，直接使用全部插件，不派活。
    final toolMode = conv.effectiveAgentMode == RoleAgentMode.tool;
    final officeToErrandAgent = delegateTaskEnabled && !toolMode;
    if (officeToErrandAgent) {
      pluginRuntime.install(
        delegateTaskAgentPlugin(_ref.read(delegateTaskPortProvider)),
      );
    }
    // ADR0073: the assistant's abilities belong to its conversation, not to
    // its editable role card.
    if (conv.id == kAicoveAssistantId) {
      pluginRuntime.install(
        assistantAgentPlugin(
          _ref.read(assistantToolsetProvider),
          // Writes need the review gate, which only the kernel runner has.
          writes: _ref.read(assistantWriteToolsProvider),
          settings: _ref.read(assistantSettingsToolsProvider),
          cards: _ref.read(assistantCardToolsProvider),
          checkup: _ref.read(assistantCheckupProvider),
          groups: _ref.read(assistantToolGroupsProvider),
        ),
      );
    }
    final selectedPluginIds = [
      for (final id in pluginRuntime.selectForRole(enabledPluginIds))
        if (!officeToErrandAgent || !isOfficePluginId(id)) id,
    ];
    final pluginScopes = [
      ...pluginRuntime.requestScopes(
        pluginRuntime.snapshot(),
        selectedPluginIds,
        PluginRequestInputs(
          ref: _ref,
          settings: settings,
          imageConfig: imageConfig,
          voiceRequest: voiceRequest,
          pluginPrompts: pluginPrompts,
          history: history,
          previousUserMessageTime: previousUserMessageTime,
          useFastImageRoute: shouldUseFastImageRoute,
          useStableImageRoute: shouldUseStableImageRoute,
          supportsToolCalling: supportsToolCalling,
          reminders: _systemReminderService,
          boundPreset: boundPreset,
          voicePrompts: voicePrompts,
          imagePrompts: imagePrompts,
          rolePluginIds: enabledPluginIds,
        ),
      ),
      // 工具模式的工作区直接给角色用，不经杂活 Agent（ADR0097）。
      if (toolMode)
        WorkspaceRequestScope(
          await _roleWorkspaceToolset(conv),
          supportsTools: supportsToolCalling,
        ),
    ];
    final contextPolicy = ChatPluginContextPolicy.firstParty(
      activeProviderIds: {
        for (final scope in pluginScopes)
          if (scope.active) scope.pluginId,
      },
      extraProviders: [
        for (final plugin in pluginRuntime.plugins)
          if (plugin.contentTags case final tags?) tags,
      ],
    );
    var reqMessages = await _requestMessageBuilder.buildRequestMessages(
      history,
      settings: settings,
      supportsVision: supportsVision,
      pluginPolicy: contextPolicy,
      inlineImagePrompts: !shouldUseStableImageRoute,
    );

    reqMessages = contextPolicy.filterMessages(reqMessages);
    for (final scope in pluginScopes) {
      reqMessages = scope.filterRequestMessages(reqMessages);
    }
    final includeInternalImageRule = _containsInternalImageContext(reqMessages);
    final systemParts = <String>[];
    if (boundPreset == null && personaParts.userPrompt.isNotEmpty) {
      systemParts.add(contextPolicy.filterText(personaParts.userPrompt));
    }
    if (handoffPrompt.isNotEmpty) {
      systemParts.add(contextPolicy.filterText(handoffPrompt));
    }
    // 插件提示词先于提醒构建：长期记忆在这里检索，本轮话题相关的往事随后进提醒。
    final pluginRequestContext = PluginRequestContext(
      userMessage: userText ?? '',
      supportsToolCalling: supportsToolCalling,
      conversationId: resolvedConversationId,
      hasInternalImageContext: includeInternalImageRule,
      readOnly: preview != null,
    );
    final rawPluginPromptBuild = await _pluginContextBuilder
        .buildPromptEntries([
          for (final scope in pluginScopes)
            PluginPromptSource(
              pluginId: scope.pluginId,
              pluginName: scope.pluginName,
              build: () => scope.prompt(pluginRequestContext),
            ),
        ]);
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
    // Proactive replies are written ahead of time and pass their fire time,
    // so time-aware plugins describe the moment the reply will be sent.
    final effectiveRequestTime =
        requestTime ?? _ref.read(requestClockProvider)();
    final outputTags = {for (final scope in pluginScopes) ...scope.outputTags};
    final outputTagReminder = buildOutputTagReminder(
      imageInline: outputTags.contains(OutputTagHint.imageInline),
      imageTool: outputTags.contains(OutputTagHint.imageTool),
      tts: outputTags.contains(OutputTagHint.tts),
      presetTags: [for (final scope in pluginScopes) ...scope.presetTagNames],
    );
    String remindersAt(DateTime time) =>
        _systemReminderService.mergeReminderContents([
          ...collectPluginReminders(
            pluginScopes,
            time,
          ).map(contextPolicy.filterText),
          outputTagReminder,
        ]);
    final systemReminderContent = remindersAt(effectiveRequestTime);
    // 延后的提醒只记进追踪，不进本次消息。
    final injectedReminder = deferReminders ? '' : systemReminderContent;
    if (boundPreset == null && injectedReminder.isNotEmpty) {
      reqMessages = _systemReminderService.insertReminderBeforeLastUser(
        messages: reqMessages,
        reminderContent: injectedReminder,
      );
    }

    List<Map<String, dynamic>>? tools;
    List<AITool> boundTools = const [];
    if (supportsToolCalling) {
      final aiTools = await _pluginContextBuilder.collectToolsWithRetry([
        for (final scope in pluginScopes)
          PluginToolSource(
            pluginId: scope.pluginId,
            tools: () => [
              for (final tool in scope.tools())
                if (!scope.pluginId.startsWith('pkg:') ||
                    !PackagePlugin.isExecutionTool(tool.name) ||
                    (toolMode))
                  tool,
            ],
          ),
      ]);
      if (toolMode) {
        aiTools.add(ToolResultStore.shared.reader(resolvedConversationId));
      }
      final exposedTools = toolMode ? assembleCodemodeTools(aiTools) : aiTools;
      boundTools = List.unmodifiable(exposedTools);
      if (aiTools.isNotEmpty) {
        var schemas = directToolSchemas(exposedTools);
        for (final scope in pluginScopes) {
          schemas = scope.rewriteToolSchemas(schemas);
        }
        tools = schemas;
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
      final reminderMessage = injectedReminder.isEmpty
          ? null
          : _systemReminderService.buildReminderMessage(
              reminderContent: injectedReminder,
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

    if (!toolMode &&
        ToolResultStore.wantsReader([
          for (final s in tools ?? const <Map<String, dynamic>>[])
            '${(s['function'] as Map?)?['name']}',
        ])) {
      tools = [
        ...tools!,
        ToolResultStore.shared.reader(resolvedConversationId).toOpenAISchema(),
      ];
    }
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
      summarizerFactory: () =>
          _ref.read(runtimeContextSummarizerProvider.future),
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
    } else if (inputTokens >= inputLimit &&
        (uncoveredUsers < 2 || !persistSideEffects)) {
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
        deferReminders: deferReminders,
      );
    }
    if (preview == null &&
        persistSideEffects &&
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
            now: effectiveRequestTime,
            previousUserMessageTime: previousUserMessageTime,
            pluginScopes: pluginScopes,
            historyCount: history.length,
            systemReminderInjected: injectedReminder.isNotEmpty,
            systemReminderContent: systemReminderContent,
          ),
          'promptAssembly': _tracePayloadBuilder.buildPromptAssemblyPayload(
            systemAssemblyEntries: systemAssemblyEntries,
            pluginPromptBuild: pluginPromptBuild,
            messagesBeforeSystemCount: messagesBeforeSystemCount,
            messagesAfterSystemCount: reqMessages.length,
            finalMessages: finalMessages,
            toolsCount: tools?.length ?? 0,
            systemReminderInjected: injectedReminder.isNotEmpty,
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
        now: effectiveRequestTime,
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

    final config = ApiConfig(
      requestInputTokenLimit: inputLimit,
      openPresetRuntime: pluginRuntime.scope.lookup(
        TavernCompatServices.presetRuntime,
      ),
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
      toolResultOwner: resolvedConversationId,
      currentWorkspaceId: () => pluginScopes
          .whereType<WorkspaceRequestScope>()
          .firstOrNull
          ?.toolset
          .currentWorkspaceId,
      settings: settings,
      modelFullId: modelFull,
      providerApiBase: requestConfig.providerApiBase,
      providerApiKey: requestConfig.providerApiKey,
      providerId: requestConfig.providerId,
      providerApiKeyItemId: requestConfig.providerApiKeyItemId,
      providerApiKeyItemIndex: requestConfig.providerApiKeyItemIndex,
      providerApiKeyStrategy: requestConfig.providerApiKeyStrategy,
      customConfig: requestConfig.customConfig,
      messages: finalMessages,
      tools: tools,
      boundTools: boundTools,
      enabledPluginIds: enabledPluginIds,
      modelTemperature:
          boundPreset?.temperature ?? requestConfig.modelTemperature,
      modelTopP: boundPreset?.topP ?? requestConfig.modelTopP,
      modelContextMessageLimit: requestConfig.modelContextMessageLimit,
      // 聊天模式办事交给杂活 Agent，一律去掉模型内置搜索（ADR0088）；
      // 其余情况沿用旧规则：联网搜索插件接管才去掉。
      providerRequestOptions:
          officeToErrandAgent ||
              supportsToolCalling &&
                  pluginScopes.any((scope) => scope.disablesBuiltinWebSearch)
          ? providerRequestOptions.copyWith(disableBuiltinWebSearch: true)
          : providerRequestOptions,
      // 显示美化正则输出的 HTML 界面无法渲染，已由语义标签组件接管的不再执行，
      // 保留原标签交给聊天列表投影为折叠／正文／选项（ADR0046）。
      presetRegexScripts: boundPreset == null
          ? const <SillyTavernRegexScript>[]
          : inferPresetTagMapping(
              boundPreset,
            ).displayScripts(boundPreset.regexScripts),
      presetRegexAuthorized: boundPreset?.regexAuthorized ?? false,
      presetStreamResponse: boundPreset?.streamResponse,
      traceContext: traceContext,
      boundImageToolPresetName: boundImageToolPresetName,
      boundImageArtistPresetName: boundImageArtistPresetName,
      drawingConfig: imageConfig,
      voiceRequest: voiceRequest,
      reminders: deferReminders ? remindersAt : null,
      responseProcessors: pluginRuntime.responseProcessors(
        pluginRuntime.snapshot(),
        selectedPluginIds,
        PluginResponseInputs(
          ref: _ref,
          voiceRequest: voiceRequest,
          drawingConfig: imageConfig,
          settings: settings,
          rolePluginIds: enabledPluginIds,
        ),
      ),
    );
    if (conv.id != kAicoveAssistantId || preview != null) {
      return config;
    }
    return config.copyWith(
      toolPolicy: await _assistantToolPolicy(
        alwaysAsk: await _ref.read(assistantAlwaysAskProvider.future),
        config: config,
        history: history,
        userText: userText,
        settings: settings,
      ),
    );
  }

  /// 工具模式的角色自己的工作区（ADR0097）：授权与杂活 Agent 看到的一样，
  /// 本次新建的工作区记到角色名下。
  Future<WorkspaceToolset> _roleWorkspaceToolset(Conversation conv) async {
    final store = await _ref.read(workspaceStoreProvider.future);
    final localIds = [for (final workspace in await store.list()) workspace.id];
    return WorkspaceToolset(
      store: store,
      enableScripts: true,
      enableShell: WorkspaceShell.available(platform: Platform.operatingSystem),
      workspaceIds: WorkspaceGrants.effective(
        roleGrants: WorkspaceGrants.forRole(conv.id, conv.enabledPlugins),
        presetAllows: null,
        pluginEnabled: true,
        localIds: localIds,
      ),
      runId: 'chat_${conv.id}_${DateTime.now().microsecondsSinceEpoch}',
      isCancelled: () => ToolCallContext.current?.isCancelled?.call() ?? false,
      onCreated: (workspace) => _grantWorkspaceToRole(conv.id, workspace),
      runWebApp: (ws, path) async => (await _ref.read(
        webAppLauncherProvider.future,
      )).openForAgent(ws, path),
      // Only AIcove酱 gets channel keys in its shell (ADR0109 补充二).
      shellEnvironment: conv.id == kAicoveAssistantId
          ? () {
              final settings = _ref.read(appSettingsProvider).valueOrNull;
              return settings == null
                  ? const <String, String>{}
                  : channelKeyEnvironment(settings);
            }
          : null,
    );
  }

  /// 「全部插件」不含空间授权，先把它展开成具体列表再追加这一项。
  Future<void> _grantWorkspaceToRole(
    String conversationId,
    WorkspaceInfo workspace,
  ) async {
    final latest = _ref
        .read(conversationsProvider)
        .valueOrNull
        ?.where((c) => c.id == conversationId)
        .firstOrNull;
    if (latest == null) return;
    final current =
        latest.enabledPlugins ??
        [
          for (final plugin in _ref.read(pluginManagerProvider).getAllPlugins())
            if (!isOfficePluginId(plugin.id) || plugin.id == 'web_search')
              plugin.id,
        ];
    final grant = WorkspaceGrants.pluginIdOf(workspace.id);
    if (current.contains(grant)) return;
    await _ref
        .read(conversationsProvider.notifier)
        .applyContactEdit(conversationId, enabledPlugins: [...current, grant]);
  }

  /// Assistant calls run without approval by default (ADR0107). The local
  /// opt-in switch restores per-call confirmation.
  Future<AgentToolPolicy> _assistantToolPolicy({
    required ApiConfig config,
    required List<Message> history,
    required String? userText,
    required AppSettings settings,
    required bool alwaysAsk,
  }) async {
    final store = await _ref.read(workspaceStoreProvider.future);
    final spaceNames = {
      for (final space in await store.list()) space.id: space.name,
    };
    bool alwaysAskNow() =>
        _ref.read(assistantAlwaysAskProvider).valueOrNull ?? alwaysAsk;
    final toolset = _ref.read(assistantToolsetProvider);
    final writes = _ref.read(assistantWriteToolsProvider);
    final settingsTools = _ref.read(assistantSettingsToolsProvider);
    final groups = _ref.read(assistantToolGroupsProvider);
    final riskOf = AssistantRequestScope.riskOf(
      toolset,
      writes,
      settings: settingsTools,
      groups: groups,
    );
    final descriptions = {
      for (final tool in [
        ...toolset.tools(),
        ...writes.tools(),
        ...settingsTools.tools(),
        for (final group in groups) ...group.tools(),
      ])
        tool.name: tool.description,
    };
    final userMessages = [
      for (final message in history)
        if (message.role == 'user' && message.content.trim().isNotEmpty)
          message.content.trim(),
    ];
    final current = userText?.trim() ?? '';
    if (current.isNotEmpty &&
        (userMessages.isEmpty || userMessages.last != current)) {
      userMessages.add(current);
    }
    final reviewer = AssistantReviewer(
      (messages) async => (await executeApiCall(
        config: _reviewConfig(config, messages),
        sessionId: '${kAicoveAssistantId}_review',
        userText: null,
      )).replyText,
    );
    return AgentToolPolicy(
      authorization: AgentToolAuthorization.allowAll,
      customGate: AssistantToolGate(riskOf, alwaysAsk: alwaysAskNow),
      redactor: redactorForCredentials(settings: settings),
      approvalTimeout: const Duration(minutes: 5),
      approvals: AssistantApprovalPort(
        riskOf: riskOf,
        describe: (name, args) => name == 'bash'
            ? ApprovalPrompt.workspaceShell(
                '${spaceNames[config.currentWorkspaceId?.call()] ?? config.currentWorkspaceId?.call() ?? '未选择'}',
                '${args['command']}',
              )
            : name == 'codemode'
            ? ApprovalPrompt.workspaceScript(
                '${spaceNames[config.currentWorkspaceId?.call()] ?? config.currentWorkspaceId?.call() ?? '未选择'}',
              )
            : groups.ownerOf(name)?.describe(name, args) ??
                  (AssistantSettingsTools.describes(name)
                      ? settingsTools.describe(name, args)
                      : writes.describe(name, args)),
        toolDescription: (name) => descriptions[name] ?? name,
        userMessages: userMessages.length <= 6
            ? userMessages
            : userMessages.sublist(userMessages.length - 6),
        review: reviewer.review,
        askUser: _ref.read(assistantApprovalsProvider.notifier).ask,
        alwaysAsk: alwaysAskNow,
      ),
    );
  }

  /// The reviewer's request: the assistant's model and channel, nothing of
  /// its assembly (no preset, tools or reply processors).
  static ApiConfig _reviewConfig(
    ApiConfig base,
    List<Map<String, dynamic>> messages,
  ) => ApiConfig(
    settings: base.settings,
    modelFullId: base.modelFullId,
    providerApiBase: base.providerApiBase,
    providerApiKey: base.providerApiKey,
    providerId: base.providerId,
    providerApiKeyItemId: base.providerApiKeyItemId,
    providerApiKeyItemIndex: base.providerApiKeyItemIndex,
    providerApiKeyStrategy: base.providerApiKeyStrategy,
    customConfig: base.customConfig,
    messages: messages,
    providerRequestOptions: base.providerRequestOptions,
  );

  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
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
    try {
      return await _apiRunner.executeApiCall(
        config: config,
        sessionId: sessionId,
        userText: userText,
        responseProcessors: config.responseProcessors,
        availableTools: config.boundTools,
        turnId: turnId,
        trace: trace,
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

  /// 本轮 MVU 状态（ADR0071）：按请求 owner 的预设与名字固定来源；读取失败不阻塞发送。
  Future<ConversationStateView> _readMvuState({
    required Conversation conv,
    required String conversationId,
    required SillyTavernPreset preset,
    required String userName,
  }) async {
    if (!mvuAllowedFor(preset)) {
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
