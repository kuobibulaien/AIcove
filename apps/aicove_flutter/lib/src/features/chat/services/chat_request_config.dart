library;

import '../../settings/app_settings.dart';
import '../../settings/direct_mode.dart' as direct;
import '../../settings/mcp_api.dart';

/// Request-level config for one chat model attempt.
class ChatRequestConfig {
  /// Raw model reference key used by AppSettings APIs.
  final String modelRef;

  /// Full model id in `provider:model` format.
  final String modelFullId;

  /// Provider API base URL.
  final String providerApiBase;

  /// Provider API key.
  final String? providerApiKey;

  /// Tool preference payload sent to backend.
  final Map<String, dynamic> toolPrefs;

  /// Provider custom config passed through to backend.
  final Map<String, dynamic> customConfig;

  /// Model-level temperature override.
  final double? modelTemperature;

  /// Model-level topP override.
  final double? modelTopP;

  /// Model-level context message limit override.
  final int? modelContextMessageLimit;

  const ChatRequestConfig({
    required this.modelRef,
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    required this.toolPrefs,
    this.customConfig = const <String, dynamic>{},
    this.modelTemperature,
    this.modelTopP,
    this.modelContextMessageLimit,
  });
}

/// Builds chat request config with MCP cache and direct-mode fallback.
class ChatRequestConfigBuilder {
  final McpApi _mcpApi = McpApi();
  McpConfigDto? _cachedMcpConfig;
  DateTime? _cachedMcpFetchedAt;

  Future<McpConfigDto?> getMcpConfig() async {
    final now = DateTime.now();
    if (_cachedMcpFetchedAt != null &&
        now.difference(_cachedMcpFetchedAt!) < McpApi.mobileConfigCacheTtl) {
      return _cachedMcpConfig;
    }
    try {
      final res = await _mcpApi.fetchConfig();
      _cachedMcpConfig = res.config;
      _cachedMcpFetchedAt = DateTime.now();
      return _cachedMcpConfig;
    } catch (_) {
      _cachedMcpConfig = null;
      _cachedMcpFetchedAt = DateTime.now();
      return null;
    }
  }

  Map<String, dynamic> buildToolPrefs(
      AppSettings settings, McpConfigDto? config) {
    final prefs = <String, dynamic>{
      'tts_enabled': settings.ttsEnabled,
    };
    if (config == null || !config.enabled || config.enabledTools.isEmpty) {
      prefs['auto_tools_enabled'] = false;
      return prefs;
    }
    prefs['auto_tools_enabled'] = true;
    prefs['mcp_enabled_tools'] = config.enabledTools;
    if (config.delegate.enabled) {
      final delegate = config.delegate;
      final delegateMap = <String, dynamic>{};
      if (delegate.provider != null && delegate.provider!.isNotEmpty) {
        delegateMap['provider'] = delegate.provider;
      }
      if (delegate.model != null && delegate.model!.isNotEmpty) {
        delegateMap['model'] = delegate.model;
      }
      if (delegate.apiBase != null && delegate.apiBase!.isNotEmpty) {
        delegateMap['api_base'] = delegate.apiBase;
      }
      if (delegate.prompt.isNotEmpty) {
        delegateMap['prompt'] = delegate.prompt;
      }
      if (delegateMap.isNotEmpty) {
        prefs['mcp_delegate'] = delegateMap;
      }
    }
    return prefs;
  }

  Future<ChatRequestConfig> buildRequestConfig(
    AppSettings settings, {
    String? modelRef,
  }) async {
    final mcpConfig = await getMcpConfig();
    final toolPrefs = buildToolPrefs(settings, mcpConfig);

    final resolvedModelRef = (modelRef != null && modelRef.trim().isNotEmpty)
        ? modelRef.trim()
        : settings.defaultModelName;

    final model = settings.getRawModelId(resolvedModelRef);
    final provider = settings.getModelProviderId(resolvedModelRef) ?? 'openai';
    var modelFull = '$provider:$model';

    final providerAuth = settings.providers.firstWhere(
      (p) => p.id == provider,
      orElse: () => ProviderAuth(
        id: provider,
        apiKeys: const <String>[],
        apiBaseUrl: settings.apiBaseUrl,
      ),
    );

    var providerApiBase = providerAuth.apiBaseUrl.trim().isEmpty
        ? settings.apiBaseUrl
        : providerAuth.apiBaseUrl.trim();
    var providerApiKey = providerAuth.apiKeys.isNotEmpty
        ? providerAuth.apiKeys.first.trim()
        : null;

    try {
      final cfg = await direct.loadDirectConfig();
      if (cfg.enabled) {
        if ((providerApiBase.isEmpty ||
                providerApiBase == settings.apiBaseUrl) &&
            cfg.apiBase.isNotEmpty) {
          providerApiBase = cfg.apiBase;
        }
        if ((providerApiKey == null || providerApiKey.isEmpty) &&
            cfg.apiKey.isNotEmpty) {
          providerApiKey = cfg.apiKey;
        }
        if (!modelFull.contains(':') && cfg.model.isNotEmpty) {
          modelFull = 'openai:${cfg.model}';
        }
      }
    } catch (_) {}

    final modelConfig = settings.getModelConfig(resolvedModelRef);

    return ChatRequestConfig(
      modelRef: resolvedModelRef,
      modelFullId: modelFull,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      toolPrefs: toolPrefs,
      customConfig: providerAuth.customConfig,
      modelTemperature: modelConfig.temperature,
      modelTopP: modelConfig.topP,
      modelContextMessageLimit: modelConfig.contextMessageLimit,
    );
  }
}
