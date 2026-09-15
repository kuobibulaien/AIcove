library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/api/providers/provider_adapter.dart'
    show ProviderChatRequestOptions;
import '../chat/domain/message.dart';
import '../chat/services/chat_history_store.dart';
import '../chat/services/chat_send_api_runner.dart';
import '../chat/services/chat_types.dart';
import '../observability/trace_models.dart';
import '../observability/trace_store.dart';
import '../plugins/domain/handlers/ai_tool.dart';
import '../plugins/plugin_manager.dart';
import '../plugins/plugin_providers.dart';
import '../settings/app_settings.dart';
import '../settings/direct_mode.dart' as direct;
import 'domain/background_agent_definition.dart';
import 'domain/background_agent_run_result.dart';

typedef LoadBackgroundAgentMessages = Future<List<Message>> Function(
  String conversationId,
  int limit,
);
typedef LoadBackgroundAgentSettings = Future<AppSettings> Function();
typedef ReadBackgroundAgentPluginManager = PluginManager Function();
typedef BuildBackgroundAgentSessionId = String Function(String agentId);
typedef ResolveBackgroundAgentRequestConfig
    = Future<BackgroundAgentRequestConfig> Function({
  required AppSettings settings,
  required String? modelRef,
});
typedef BackgroundAgentExecutor = Future<ApiCallResult> Function({
  required ApiConfig config,
  required List<AITool> availableTools,
  required String sessionId,
  required int maxRounds,
});

final backgroundAgentServiceProvider = Provider<BackgroundAgentService>((ref) {
  const runner = ChatSendApiRunner();
  return BackgroundAgentService(
    loadRecentMessages: (conversationId, limit) =>
        ref.read(chatHistoryStoreProvider).loadCanonicalContextMessages(
              conversationId,
              limit: limit,
            ),
    loadSettings: () => ref.read(appSettingsProvider.future),
    readPluginManager: () => ref.read(pluginManagerProvider),
    executor: ({
      required ApiConfig config,
      required List<AITool> availableTools,
      required String sessionId,
      required int maxRounds,
    }) {
      return runner.executeApiCall(
        config: config,
        sessionId: sessionId,
        userText: null,
        effectivePlugins: const [],
        availableTools: availableTools,
        maxRounds: maxRounds,
        traceContext: config.traceContext,
      );
    },
  );
});

class BackgroundAgentService {
  static const String _traceSource = 'BackgroundAgentService';

  BackgroundAgentService({
    required LoadBackgroundAgentMessages loadRecentMessages,
    required LoadBackgroundAgentSettings loadSettings,
    required ReadBackgroundAgentPluginManager readPluginManager,
    ResolveBackgroundAgentRequestConfig? requestConfigResolver,
    BackgroundAgentExecutor? executor,
    BuildBackgroundAgentSessionId? sessionIdFactory,
    TraceStore? traceStore,
  })  : _loadRecentMessages = loadRecentMessages,
        _loadSettings = loadSettings,
        _readPluginManager = readPluginManager,
        _requestConfigResolver =
            requestConfigResolver ?? _defaultRequestConfigResolver,
        _executor = executor ?? _defaultExecutor,
        _sessionIdFactory = sessionIdFactory ?? _defaultSessionIdFactory,
        _traceStore = traceStore ?? TraceStore.instance;

  final LoadBackgroundAgentMessages _loadRecentMessages;
  final LoadBackgroundAgentSettings _loadSettings;
  final ReadBackgroundAgentPluginManager _readPluginManager;
  final ResolveBackgroundAgentRequestConfig _requestConfigResolver;
  final BackgroundAgentExecutor _executor;
  final BuildBackgroundAgentSessionId _sessionIdFactory;
  final TraceStore _traceStore;

  static Future<ApiCallResult> _defaultExecutor({
    required ApiConfig config,
    required List<AITool> availableTools,
    required String sessionId,
    required int maxRounds,
  }) {
    return const ChatSendApiRunner().executeApiCall(
      config: config,
      sessionId: sessionId,
      userText: null,
      effectivePlugins: const [],
      availableTools: availableTools,
      maxRounds: maxRounds,
      traceContext: config.traceContext,
    );
  }

  static String _defaultSessionIdFactory(String agentId) =>
      'bg_agent_${agentId.trim()}_${DateTime.now().millisecondsSinceEpoch}';

  static Future<BackgroundAgentRequestConfig> _defaultRequestConfigResolver({
    required AppSettings settings,
    required String? modelRef,
  }) async {
    final resolvedModelRef = (modelRef != null && modelRef.trim().isNotEmpty)
        ? modelRef.trim()
        : settings.defaultModelName;
    var modelFullId = settings.toModelFullId(resolvedModelRef);
    final providerId =
        settings.getModelProviderId(resolvedModelRef) ?? 'openai';
    final providerAuth = settings.providers.firstWhere(
      (provider) => provider.id == providerId,
      orElse: () => ProviderAuth(
        id: providerId,
        apiKeys: const <String>[],
        apiBaseUrl: settings.apiBaseUrl,
      ),
    );
    var providerApiBase = providerAuth.apiBaseUrl.trim().isEmpty
        ? settings.apiBaseUrl
        : providerAuth.apiBaseUrl.trim();
    String? providerApiKey = providerAuth.apiKeys.isNotEmpty
        ? providerAuth.apiKeys.first.trim()
        : null;

    try {
      final directConfig = await direct.loadDirectConfig();
      if (directConfig.enabled) {
        if ((providerApiBase.isEmpty ||
                providerApiBase == settings.apiBaseUrl) &&
            directConfig.apiBase.trim().isNotEmpty) {
          providerApiBase = directConfig.apiBase.trim();
        }
        if ((providerApiKey == null || providerApiKey.isEmpty) &&
            directConfig.apiKey.trim().isNotEmpty) {
          providerApiKey = directConfig.apiKey.trim();
        }
        if (!modelFullId.contains(':') &&
            directConfig.model.trim().isNotEmpty) {
          modelFullId = 'openai:${directConfig.model.trim()}';
        }
      }
    } catch (_) {}

    final modelConfig = settings.getModelConfig(resolvedModelRef);
    return BackgroundAgentRequestConfig(
      modelFullId: modelFullId,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      customConfig: providerAuth.customConfig,
      modelTemperature: modelConfig.temperature,
      modelTopP: modelConfig.topP,
      modelContextMessageLimit: modelConfig.contextMessageLimit,
    );
  }

  Future<BackgroundAgentRunResult> run({
    required BackgroundAgentDefinition definition,
    required String conversationId,
    String? extraInstruction,
    List<Message>? contextMessages,
    List<AITool> additionalTools = const <AITool>[],
    int? maxOutputTokens,
  }) async {
    final sessionId = _sessionIdFactory(definition.id);
    final traceContext = await _startTurnTrace(
      definition: definition,
      conversationId: conversationId,
      turnId: sessionId,
      extraInstruction: extraInstruction,
    );

    try {
      final settings = await _loadSettings();
      final requestConfig = await _requestConfigResolver(
        settings: settings,
        modelRef: definition.modelRef,
      );
      final usedMessages = await _loadContextMessages(
        conversationId: conversationId,
        definition: definition,
        explicitMessages: contextMessages,
      );
      final allowedTools = _resolveAllowedTools(
        definition.allowedToolNames,
        additionalTools: additionalTools,
      );
      final systemPrompt = _buildSystemPrompt(
        definition.objectivePrompt,
        extraInstruction,
      );
      final requestMessages = _buildMessages(
        definition: definition,
        systemPrompt: systemPrompt,
        usedMessages: usedMessages,
      );
      final config = ApiConfig(
        settings: settings,
        modelFullId: requestConfig.modelFullId,
        providerApiBase: requestConfig.providerApiBase,
        providerApiKey: requestConfig.providerApiKey,
        customConfig: requestConfig.customConfig,
        toolPrefs: const <String, dynamic>{'auto_tools_enabled': false},
        messages: requestMessages,
        tools: allowedTools.isEmpty
            ? null
            : allowedTools.map((tool) => tool.toOpenAISchema()).toList(),
        modelTemperature:
            definition.temperature ?? requestConfig.modelTemperature,
        modelTopP: requestConfig.modelTopP,
        modelContextMessageLimit: requestConfig.modelContextMessageLimit,
        providerRequestOptions: maxOutputTokens == null
            ? null
            : ProviderChatRequestOptions(maxOutputTokens: maxOutputTokens),
        traceContext: traceContext,
      );
      await _recordPreparationTrace(
        traceContext: traceContext,
        definition: definition,
        conversationId: conversationId,
        extraInstruction: extraInstruction,
        requestConfig: requestConfig,
        usedMessages: usedMessages,
        requestMessages: requestMessages,
        allowedTools: allowedTools,
      );
      final result = await _executor(
        config: config,
        availableTools: allowedTools,
        sessionId: sessionId,
        maxRounds: definition.maxRounds,
      );
      final finalReply = result.processedText.trim().isNotEmpty
          ? result.processedText
          : result.replyText;
      await _recordTraceEvent(
        traceContext,
        TraceStage.turnCompleted,
        meta: <String, dynamic>{
          'traceKind': TraceKind.backgroundAgent.value,
          'agentId': definition.id,
          'agentName': definition.name,
          'conversationId': conversationId,
          'toolCalls': result.toolCalls.length,
          'toolResults': result.toolResults.length,
          'replyLength': finalReply.length,
        },
      );
      return BackgroundAgentRunResult(
        sessionId: sessionId,
        replyText: result.replyText,
        processedText: result.processedText,
        toolResults: result.toolResults,
        toolCalls: result.toolCalls,
        rawToolResults: result.rawToolResults,
        usedMessages: usedMessages,
      );
    } catch (error) {
      await _recordTraceEvent(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        meta: <String, dynamic>{
          'traceKind': TraceKind.backgroundAgent.value,
          'agentId': definition.id,
          'agentName': definition.name,
          'conversationId': conversationId,
          'error': error.toString(),
        },
      );
      rethrow;
    }
  }

  Future<List<Message>> _loadContextMessages({
    required String conversationId,
    required BackgroundAgentDefinition definition,
    List<Message>? explicitMessages,
  }) async {
    final messages = explicitMessages ??
        await _loadRecentMessages(
          conversationId,
          definition.contextSpec.normalizedLastMessages,
        );
    return messages
        .where((message) => definition.contextSpec.includesRole(message.role))
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _buildMessages({
    required BackgroundAgentDefinition definition,
    required String systemPrompt,
    required List<Message> usedMessages,
  }) {
    final messages = <Map<String, dynamic>>[];
    if (systemPrompt.isNotEmpty) {
      messages.add({
        'role': 'system',
        'content': systemPrompt,
      });
    }
    for (final message in usedMessages) {
      messages.addAll(
        message.toHistoryJsonList(
          includeTimestamp: definition.contextSpec.includeTimestamps,
        ),
      );
    }
    return messages;
  }

  String _buildSystemPrompt(String objectivePrompt, String? extraInstruction) {
    final base = objectivePrompt.trim();
    final extra = extraInstruction?.trim() ?? '';
    if (base.isEmpty) return extra;
    if (extra.isEmpty) return base;
    return '$base\n\n$extra';
  }

  Future<TraceContext?> _startTurnTrace({
    required BackgroundAgentDefinition definition,
    required String conversationId,
    required String turnId,
    required String? extraInstruction,
  }) async {
    try {
      return await _traceStore.startTurn(
        sessionId: conversationId,
        turnId: turnId,
        source: _traceSource,
        meta: <String, dynamic>{
          'entry': 'background_agent_run',
          'traceKind': TraceKind.backgroundAgent.value,
          'agentId': definition.id,
          'agentName': definition.name,
          'conversationId': conversationId,
          'hasExtraInstruction': extraInstruction?.trim().isNotEmpty == true,
        },
      );
    } catch (error) {
      AppLogger.warning(
        _traceSource,
        '启动后台 agent Trace 失败',
        metadata: <String, dynamic>{
          'conversationId': conversationId,
          'agentId': definition.id,
          'error': error.toString(),
        },
      );
      return null;
    }
  }

  Future<void> _recordPreparationTrace({
    required TraceContext? traceContext,
    required BackgroundAgentDefinition definition,
    required String conversationId,
    required String? extraInstruction,
    required BackgroundAgentRequestConfig requestConfig,
    required List<Message> usedMessages,
    required List<Map<String, dynamic>> requestMessages,
    required List<AITool> allowedTools,
  }) async {
    if (traceContext == null) return;
    final now = DateTime.now();
    await _recordTraceEvent(
      traceContext,
      TraceStage.historyPrepared,
      meta: <String, dynamic>{
        'traceKind': TraceKind.backgroundAgent.value,
        'agentId': definition.id,
        'agentName': definition.name,
        'conversationId': conversationId,
        'historyCount': usedMessages.length,
        'includeUser': definition.contextSpec.includeUser,
        'includeAssistant': definition.contextSpec.includeAssistant,
        'includeSystem': definition.contextSpec.includeSystem,
        'includeTimestamps': definition.contextSpec.includeTimestamps,
        'lastMessages': definition.contextSpec.normalizedLastMessages,
      },
    );

    final payloadRef = await _writeTracePayload(
      traceContext: traceContext,
      stage: TraceStage.apiConfigReady,
      payload: <String, dynamic>{
        'runtimeContext': <String, dynamic>{
          'requestSource': TraceKind.backgroundAgent.value,
          'conversationId': conversationId,
          'agentId': definition.id,
          'agentName': definition.name,
          'modelFullId': requestConfig.modelFullId,
          'requestedModelRef': definition.modelRef,
          'extraInstruction': extraInstruction?.trim(),
          'contextMessagesCount': usedMessages.length,
          'allowedToolNames':
              allowedTools.map((tool) => tool.name).toList(growable: false),
          'contextSpec': <String, dynamic>{
            'lastMessages': definition.contextSpec.normalizedLastMessages,
            'includeUser': definition.contextSpec.includeUser,
            'includeAssistant': definition.contextSpec.includeAssistant,
            'includeSystem': definition.contextSpec.includeSystem,
            'includeTimestamps': definition.contextSpec.includeTimestamps,
          },
        },
        'promptAssembly': <String, dynamic>{
          'source': TraceKind.backgroundAgent.value,
          'systemPrompt': _buildSystemPrompt(
            definition.objectivePrompt,
            extraInstruction,
          ),
          'entries': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'background-agent-objective',
              'label': '后台 Agent 目标提示词',
              'content': definition.objectivePrompt.trim(),
            },
            if (extraInstruction?.trim().isNotEmpty == true)
              <String, dynamic>{
                'id': 'background-agent-extra-instruction',
                'label': '后台 Agent 额外指令',
                'content': extraInstruction!.trim(),
              },
          ],
          'messagesBeforeSystemCount': usedMessages.length,
          'messagesAfterSystemCount': requestMessages.length,
          'toolsCount': allowedTools.length,
          'toolNames':
              allowedTools.map((tool) => tool.name).toList(growable: false),
        },
        'rawContext': jsonEncode(requestMessages),
      },
      now: now,
    );
    await _recordTraceEvent(
      traceContext,
      TraceStage.apiConfigReady,
      payloadRef: payloadRef,
      meta: <String, dynamic>{
        'traceKind': TraceKind.backgroundAgent.value,
        'agentId': definition.id,
        'agentName': definition.name,
        'conversationId': conversationId,
        'modelFullId': requestConfig.modelFullId,
        'messagesCount': requestMessages.length,
        'toolsCount': allowedTools.length,
      },
    );
  }

  Future<void> _recordTraceEvent(
    TraceContext? traceContext,
    TraceStage stage, {
    TraceEventStatus status = TraceEventStatus.success,
    int roundIndex = 0,
    Map<String, dynamic>? payloadRef,
    Map<String, dynamic>? meta,
  }) async {
    if (traceContext == null) return;
    try {
      await _traceStore.record(
        traceId: traceContext.traceId,
        sessionId: traceContext.sessionId,
        turnId: traceContext.turnId,
        stage: stage,
        status: status,
        source: _traceSource,
        roundIndex: roundIndex,
        payloadRef: payloadRef,
        meta: meta,
      );
    } catch (error) {
      AppLogger.warning(
        _traceSource,
        '记录后台 agent Trace 失败',
        metadata: <String, dynamic>{
          'traceId': traceContext.traceId,
          'stage': stage.value,
          'error': error.toString(),
        },
      );
    }
  }

  Future<Map<String, dynamic>?> _writeTracePayload({
    required TraceContext? traceContext,
    required TraceStage stage,
    required Map<String, dynamic> payload,
    DateTime? now,
  }) async {
    if (traceContext == null) return null;
    try {
      return await _traceStore.writePayload(
        traceId: traceContext.traceId,
        sessionId: traceContext.sessionId,
        turnId: traceContext.turnId,
        stage: stage.value,
        source: _traceSource,
        payload: payload,
        now: now,
      );
    } catch (error) {
      AppLogger.warning(
        _traceSource,
        '写入后台 agent Trace payload 失败',
        metadata: <String, dynamic>{
          'traceId': traceContext.traceId,
          'stage': stage.value,
          'error': error.toString(),
        },
      );
      return null;
    }
  }

  List<AITool> _resolveAllowedTools(
    List<String> allowedToolNames, {
    List<AITool> additionalTools = const <AITool>[],
  }) {
    if (allowedToolNames.isEmpty && additionalTools.isEmpty) {
      return const <AITool>[];
    }

    final whitelist = <String>{
      for (final name in allowedToolNames)
        if (name.trim().isNotEmpty) name.trim(),
    };

    final seen = <String>{};
    final tools = <AITool>[];
    for (final tool in additionalTools) {
      if (!seen.add(tool.name)) {
        continue;
      }
      tools.add(tool);
    }

    if (whitelist.isEmpty) {
      return tools;
    }

    for (final tool in _readPluginManager().getAllTools()) {
      if (!whitelist.contains(tool.name) || !seen.add(tool.name)) {
        continue;
      }
      tools.add(tool);
    }
    return tools;
  }
}

class BackgroundAgentRequestConfig {
  const BackgroundAgentRequestConfig({
    required this.modelFullId,
    required this.providerApiBase,
    required this.providerApiKey,
    required this.customConfig,
    required this.modelTemperature,
    required this.modelTopP,
    required this.modelContextMessageLimit,
  });

  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic> customConfig;
  final double? modelTemperature;
  final double? modelTopP;
  final int? modelContextMessageLimit;
}
