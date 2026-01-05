/// 聊天请求配置准备器
/// 
/// 负责准备 API 调用所需的配置（模型、Provider、工具偏好等）。
/// 
/// 从 chat_actions.dart 提取，遵循单一职责原则。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import '../../settings/app_settings.dart';
import '../../settings/mcp_api.dart';
import '../../settings/direct_mode.dart' as direct;

/// 请求配置结果
class ChatRequestConfig {
  /// 完整模型 ID（provider:model）
  final String modelFullId;
  
  /// Provider API Base URL
  final String providerApiBase;
  
  /// Provider API Key
  final String? providerApiKey;
  
  /// 工具偏好设置
  final Map<String, dynamic> toolPrefs;
  
  /// 自定义配置
  final Map<String, dynamic>? customConfig;

  const ChatRequestConfig({
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    required this.toolPrefs,
    this.customConfig,
  });
}

/// 聊天请求配置准备器
class ChatRequestConfigBuilder {
  final McpApi _mcpApi = McpApi();
  McpConfigDto? _cachedMcpConfig;
  DateTime? _cachedMcpFetchedAt;

  /// 获取 MCP 配置（带缓存）
  Future<McpConfigDto?> getMcpConfig() async {
    final now = DateTime.now();
    if (_cachedMcpConfig != null && _cachedMcpFetchedAt != null) {
      if (now.difference(_cachedMcpFetchedAt!).inSeconds < 30) {
        return _cachedMcpConfig;
      }
    }
    try {
      final res = await _mcpApi.fetchConfig();
      _cachedMcpConfig = res.config;
      _cachedMcpFetchedAt = DateTime.now();
      return _cachedMcpConfig;
    } catch (_) {
      _cachedMcpConfig = null;
      _cachedMcpFetchedAt = null;
      return null;
    }
  }

  /// 构建工具偏好设置
  Map<String, dynamic> buildToolPrefs(AppSettings settings, McpConfigDto? config) {
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

  /// 构建完整的请求配置
  Future<ChatRequestConfig> buildRequestConfig(AppSettings settings) async {
    final mcpConfig = await getMcpConfig();
    final toolPrefs = buildToolPrefs(settings, mcpConfig);
    
    final model = settings.defaultModelName;
    final provider = settings.modelProviderMap[model] ?? 'openai';
    var modelFull = '$provider:$model';

    // 获取 Provider 认证信息
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
    var providerApiKey =
        providerAuth.apiKeys.isNotEmpty ? providerAuth.apiKeys.first.trim() : null;

    // 尝试直连配置兜底
    try {
      final cfg = await direct.loadDirectConfig();
      if (cfg.enabled) {
        if ((providerApiBase.isEmpty || providerApiBase == settings.apiBaseUrl) && cfg.apiBase.isNotEmpty) {
          providerApiBase = cfg.apiBase;
        }
        if ((providerApiKey == null || providerApiKey.isEmpty) && cfg.apiKey.isNotEmpty) {
          providerApiKey = cfg.apiKey;
        }
        if (!modelFull.contains(':') && cfg.model.isNotEmpty) {
          modelFull = 'openai:${cfg.model}';
        }
      }
    } catch (_) {}

    return ChatRequestConfig(
      modelFullId: modelFull,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      toolPrefs: toolPrefs,
      customConfig: providerAuth.customConfig,
    );
  }
}
