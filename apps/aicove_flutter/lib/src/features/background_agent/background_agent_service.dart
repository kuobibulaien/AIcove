library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/domain/message.dart';
import '../chat/services/chat_history_store.dart';
import '../chat/services/chat_send_api_runner.dart';
import '../chat/services/chat_types.dart';
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
        ref.read(chatHistoryStoreProvider).loadRecentProjectedMessages(
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
      );
    },
  );
});

class BackgroundAgentService {
  BackgroundAgentService({
    required LoadBackgroundAgentMessages loadRecentMessages,
    required LoadBackgroundAgentSettings loadSettings,
    required ReadBackgroundAgentPluginManager readPluginManager,
    ResolveBackgroundAgentRequestConfig? requestConfigResolver,
    BackgroundAgentExecutor? executor,
    BuildBackgroundAgentSessionId? sessionIdFactory,
  })  : _loadRecentMessages = loadRecentMessages,
        _loadSettings = loadSettings,
        _readPluginManager = readPluginManager,
        _requestConfigResolver =
            requestConfigResolver ?? _defaultRequestConfigResolver,
        _executor = executor ?? _defaultExecutor,
        _sessionIdFactory = sessionIdFactory ?? _defaultSessionIdFactory;

  final LoadBackgroundAgentMessages _loadRecentMessages;
  final LoadBackgroundAgentSettings _loadSettings;
  final ReadBackgroundAgentPluginManager _readPluginManager;
  final ResolveBackgroundAgentRequestConfig _requestConfigResolver;
  final BackgroundAgentExecutor _executor;
  final BuildBackgroundAgentSessionId _sessionIdFactory;

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
  }) async {
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
    final allowedTools = _resolveAllowedTools(definition.allowedToolNames);
    final sessionId = _sessionIdFactory(definition.id);
    final config = ApiConfig(
      settings: settings,
      modelFullId: requestConfig.modelFullId,
      providerApiBase: requestConfig.providerApiBase,
      providerApiKey: requestConfig.providerApiKey,
      customConfig: requestConfig.customConfig,
      toolPrefs: const <String, dynamic>{'auto_tools_enabled': false},
      messages: _buildMessages(
        definition: definition,
        extraInstruction: extraInstruction,
        usedMessages: usedMessages,
      ),
      tools: allowedTools.isEmpty
          ? null
          : allowedTools.map((tool) => tool.toOpenAISchema()).toList(),
      modelTemperature:
          definition.temperature ?? requestConfig.modelTemperature,
      modelTopP: requestConfig.modelTopP,
      modelContextMessageLimit: requestConfig.modelContextMessageLimit,
    );
    final result = await _executor(
      config: config,
      availableTools: allowedTools,
      sessionId: sessionId,
      maxRounds: definition.maxRounds,
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
    required String? extraInstruction,
    required List<Message> usedMessages,
  }) {
    final messages = <Map<String, dynamic>>[];
    final systemPrompt = _buildSystemPrompt(
      definition.objectivePrompt,
      extraInstruction,
    );
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

  List<AITool> _resolveAllowedTools(List<String> allowedToolNames) {
    if (allowedToolNames.isEmpty) return const <AITool>[];

    final whitelist = <String>{
      for (final name in allowedToolNames)
        if (name.trim().isNotEmpty) name.trim(),
    };
    if (whitelist.isEmpty) return const <AITool>[];

    final seen = <String>{};
    final tools = <AITool>[];
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
