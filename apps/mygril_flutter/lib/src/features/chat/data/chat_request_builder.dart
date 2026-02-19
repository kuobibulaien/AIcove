/// 聊天请求构建器 - 负责组装 AI API 请求的公共逻辑
///
/// 职责：
/// - 加载和缓存 MCP 配置
/// - 构建工具偏好设置
/// - 解析 provider 和模型配置
/// - 组装系统提示词
/// - 准备历史消息
///
/// 遵循 DRY 原则：从 ChatActions 中提取的重复代码
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../../settings/app_settings.dart';
import '../../settings/mcp_api.dart';
import '../../settings/direct_mode.dart' as direct;
import '../../plugins/plugin_providers.dart';
import '../../plugins/time_awareness/time_awareness_plugin.dart';
import '../../../core/app_logger.dart';
import '../../../core/utils/token_estimator.dart';

/// 请求构建结果 - 包含发送 AI 请求所需的所有参数
class ChatRequestParams {
  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic>? customConfig;
  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> toolPrefs;
  final double temperature;
  final String backendApiKey;

  const ChatRequestParams({
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    this.customConfig,
    required this.messages,
    required this.toolPrefs,
    required this.temperature,
    required this.backendApiKey,
  });
}

/// 聊天请求构建器
class ChatRequestBuilder {
  ChatRequestBuilder(this._ref);

  final Ref _ref;
  final McpApi _mcpApi = McpApi();

  // MCP 配置缓存（移动端优化 TTL）
  McpConfigDto? _cachedMcpConfig;
  DateTime? _cachedMcpFetchedAt;
  static const Duration _mcpCacheDuration = McpApi.mobileConfigCacheTtl;

  /// 获取 MCP 配置（带缓存）
  Future<McpConfigDto?> getMcpConfig() async {
    final now = DateTime.now();
    if (_cachedMcpFetchedAt != null &&
        now.difference(_cachedMcpFetchedAt!) < _mcpCacheDuration) {
      return _cachedMcpConfig;
    }
    try {
      final res = await _mcpApi.fetchConfig();
      _cachedMcpConfig = res.config;
      _cachedMcpFetchedAt = DateTime.now();
      return _cachedMcpConfig;
    } catch (_) {
      _cachedMcpConfig = null;
      // Negative cache to avoid repeated retries in weak mobile networks.
      _cachedMcpFetchedAt = DateTime.now();
      return null;
    }
  }

  /// 构建工具偏好设置
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

  /// 解析 Provider 配置（包含直连兜底逻辑）
  Future<ProviderConfig> resolveProviderConfig(AppSettings settings) async {
    final model = settings.defaultModelName;
    final provider = settings.modelProviderMap[model] ?? 'openai';
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

    // 直连配置兜底
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

    return ProviderConfig(
      modelFullId: modelFull,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      customConfig: providerAuth.customConfig,
    );
  }

  /// 构建系统提示词
  Future<String> buildSystemPrompt({
    required Conversation conversation,
    String? userMessage,
    String? additionalPrompt,
  }) async {
    final systemParts = <String>[];

    // 1. 额外提示词（如触发器指令）
    if (additionalPrompt != null && additionalPrompt.isNotEmpty) {
      systemParts.add(additionalPrompt);
    }

    // 2. 对话角色提示词
    if (conversation.personaPrompt.isNotEmpty) {
      systemParts.add(conversation.personaPrompt);
    }

    // 3. 用户称呼
    if (conversation.addressUser != null &&
        conversation.addressUser!.isNotEmpty) {
      systemParts.add('你应该称呼用户为"${conversation.addressUser}"。');
    }

    // 4. 插件提示词（如 TTS）
    final pluginManager = _ref.read(pluginManagerProvider);
    final pluginPrompts =
        await pluginManager.getSystemPrompts(userMessage: userMessage);
    if (pluginPrompts.isNotEmpty) {
      systemParts.add(pluginPrompts);
      AppLogger.debug('ChatRequestBuilder', '添加插件提示词', metadata: {
        'pluginCount': pluginManager.getEnabledPlugins().length,
        'promptsLength': pluginPrompts.length,
      });
    }

    return systemParts.join('\n\n');
  }

  /// 准备历史消息（应用消息数量限制）
  List<Message> prepareHistory({
    required List<Message> allMessages,
    required int historyLimit,
  }) {
    if (historyLimit <= 0 || allMessages.length <= historyLimit) {
      return allMessages;
    }
    return allMessages.sublist(allMessages.length - historyLimit);
  }

  /// 构建完整的请求消息列表（包含系统提示词）
  Future<List<Map<String, dynamic>>> buildRequestMessages({
    required Conversation conversation,
    required List<Message> history,
    String? userMessage,
    String? additionalPrompt,
  }) async {
    // 根据时间增强插件配置决定是否添加时间戳
    final pluginManager = _ref.read(pluginManagerProvider);
    final timeAwarenessPlugin =
        pluginManager.getPlugin('time_awareness') as TimeAwarenessPlugin?;
    final includeTimestamp =
        timeAwarenessPlugin?.shouldIncludeTimestamp ?? false;
    final reqMessages = history
        .map((m) => m.toHistoryJson(includeTimestamp: includeTimestamp))
        .toList();

    // 将最后一条消息的时间传给时间感知插件，用于计算对话间隔
    if (timeAwarenessPlugin != null && history.isNotEmpty) {
      timeAwarenessPlugin.setLastMessageTime(history.last.createdAt);
    }

    final systemPrompt = await buildSystemPrompt(
      conversation: conversation,
      userMessage: userMessage,
      additionalPrompt: additionalPrompt,
    );

    if (systemPrompt.isNotEmpty) {
      reqMessages.insert(0, {
        'role': 'system',
        'content': systemPrompt,
      });
    }

    return reqMessages;
  }

  /// 一站式构建完整请求参数
  ///
  /// 这是最常用的方法，整合了所有配置加载和参数组装逻辑
  Future<ChatRequestParams> build({
    required Conversation conversation,
    required List<Message> allMessages,
    String? userMessage,
    String? additionalPrompt,
  }) async {
    final settings = await _ref.read(appSettingsProvider.future);
    final mcpConfig = await getMcpConfig();
    final toolPrefs = buildToolPrefs(settings, mcpConfig);

    final history = prepareHistory(
      allMessages: allMessages,
      historyLimit: settings.historyMessageLimit,
    );

    final messages = await buildRequestMessages(
      conversation: conversation,
      history: history,
      userMessage: userMessage,
      additionalPrompt: additionalPrompt,
    );

    final providerConfig = await resolveProviderConfig(settings);

    // Token 截断：确保消息总长度不超过模型上下文限制
    final modelName = providerConfig.modelFullId.contains(':')
        ? providerConfig.modelFullId.split(':').last
        : providerConfig.modelFullId;
    final maxContextTokens = getModelContextLimit(modelName);
    final truncatedMessages = truncateMessagesToFit(
      messages: messages,
      maxContextTokens: maxContextTokens,
      reserveTokens: 2048,
    );

    return ChatRequestParams(
      modelFullId: providerConfig.modelFullId,
      providerApiBase: providerConfig.providerApiBase,
      providerApiKey: providerConfig.providerApiKey,
      customConfig: providerConfig.customConfig,
      messages: truncatedMessages,
      toolPrefs: toolPrefs,
      temperature: settings.temperature,
      backendApiKey: settings.backendApiKey,
    );
  }
}

/// Provider 配置
class ProviderConfig {
  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic>? customConfig;

  const ProviderConfig({
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    this.customConfig,
  });
}

/// Provider 定义
final chatRequestBuilderProvider = Provider((ref) => ChatRequestBuilder(ref));
