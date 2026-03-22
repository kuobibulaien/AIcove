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

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../domain/persona_prompt_codec.dart';
import '../../settings/app_settings.dart';
import '../../settings/mcp_api.dart';
import '../../settings/direct_mode.dart' as direct;
import '../../plugins/image/image_plugin.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/time_awareness/time_awareness_plugin.dart';
import '../../plugins/tts/tts_plugin.dart';
import '../../../core/app_logger.dart';
import '../../../core/services/prompt_tag_semantics_service.dart';
import '../../../core/services/system_reminder_service.dart';
import '../../../core/utils/token_estimator.dart';
import '../services/chat_plugin_context_builder.dart';

/// 请求构建结果 - 包含发送 AI 请求所需的所有参数
class ChatRequestParams {
  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic>? customConfig;
  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> toolPrefs;
  final double? temperature;
  final String backendApiKey;

  const ChatRequestParams({
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    this.customConfig,
    required this.messages,
    required this.toolPrefs,
    this.temperature,
    required this.backendApiKey,
  });
}

class _ProviderApiKeyCandidate {
  const _ProviderApiKeyCandidate({
    required this.key,
    required this.enabled,
    required this.isError,
  });

  final String key;
  final bool enabled;
  final bool isError;
}

/// 聊天请求构建器
class ChatRequestBuilder {
  static const String _multiKeyEnabledField = 'multi_key_enabled';
  static const String _multiKeyStrategyField = 'multi_key_strategy';
  static const String _multiKeyItemsField = 'multi_key_items';
  static const String _multiKeyStrategyRoundRobin = 'round_robin';
  static const String _multiKeyStrategyRandom = 'random';
  static const Set<String> _managedTagSemanticsPluginIds = <String>{
    'tts',
    'image',
  };
  static final Map<String, int> _roundRobinIndexMap = <String, int>{};

  ChatRequestBuilder(this._ref);

  final Ref _ref;
  final McpApi _mcpApi = McpApi();
  final ChatPluginContextBuilder _pluginContextBuilder =
      const ChatPluginContextBuilder();
  final PromptTagSemanticsService _promptTagSemanticsService =
      const PromptTagSemanticsService();
  final SystemReminderService _systemReminderService =
      const SystemReminderService();

  // MCP 配置缓存（移动端优化 TTL）
  McpConfigDto? _cachedMcpConfig;
  DateTime? _cachedMcpFetchedAt;
  static const Duration _mcpCacheDuration = McpApi.mobileConfigCacheTtl;

  String? _selectProviderApiKey(ProviderAuth providerAuth) {
    final fallback = providerAuth.apiKeys.isNotEmpty
        ? providerAuth.apiKeys.first.trim()
        : null;
    final customConfig = providerAuth.customConfig;
    if (customConfig[_multiKeyEnabledField] != true) {
      return fallback?.isEmpty == true ? null : fallback;
    }

    final items = <_ProviderApiKeyCandidate>[];
    final rawItems = customConfig[_multiKeyItemsField];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is! Map) continue;
        final mapped = Map<String, dynamic>.from(item);
        final key = mapped['key']?.toString().trim() ?? '';
        if (key.isEmpty) continue;
        final enabled = mapped['enabled'] != false;
        final status =
            mapped['status']?.toString().trim().toLowerCase() ?? 'normal';
        items.add(_ProviderApiKeyCandidate(
          key: key,
          enabled: enabled,
          isError: status == 'error',
        ));
      }
    }
    if (items.isEmpty) {
      for (final raw in providerAuth.apiKeys) {
        final key = raw.trim();
        if (key.isEmpty) continue;
        items.add(_ProviderApiKeyCandidate(
          key: key,
          enabled: true,
          isError: false,
        ));
      }
    }
    if (items.isEmpty) {
      return fallback?.isEmpty == true ? null : fallback;
    }

    var available = items
        .where((item) => item.enabled && !item.isError && item.key.isNotEmpty)
        .toList();
    available = available.isEmpty
        ? items.where((item) => item.enabled && item.key.isNotEmpty).toList()
        : available;
    if (available.isEmpty) {
      return fallback?.isEmpty == true ? null : fallback;
    }

    final strategy =
        customConfig[_multiKeyStrategyField]?.toString().trim().toLowerCase() ??
            _multiKeyStrategyRoundRobin;
    if (strategy == _multiKeyStrategyRandom && available.length > 1) {
      return available[Random().nextInt(available.length)].key;
    }
    final providerId = providerAuth.id.trim();
    final index = (_roundRobinIndexMap[providerId] ?? 0) % available.length;
    _roundRobinIndexMap[providerId] = (index + 1) % available.length;
    return available[index].key;
  }

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
    final modelRef = settings.defaultModelName;
    final model = settings.getRawModelId(modelRef);
    final provider = settings.getModelProviderId(modelRef) ?? 'openai';
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
    var providerApiKey = _selectProviderApiKey(providerAuth);

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
  String buildSystemPrompt({
    required Conversation conversation,
    String? additionalPrompt,
    String? tagSemanticsPrompt,
    PluginPromptBuildResult pluginPromptBuild =
        const PluginPromptBuildResult(entries: <PluginPromptEntry>[]),
  }) {
    final systemParts = <String>[];

    // 1. 额外提示词（如触发器指令）
    if (additionalPrompt != null && additionalPrompt.isNotEmpty) {
      systemParts.add(additionalPrompt);
    }

    final personaParts = PersonaPromptCodec.parse(conversation.personaPrompt);

    // 2. 对话角色提示词
    if (personaParts.userPrompt.isNotEmpty) {
      systemParts.add(personaParts.userPrompt);
    }

    if (tagSemanticsPrompt != null && tagSemanticsPrompt.isNotEmpty) {
      systemParts.add(tagSemanticsPrompt);
    }

    // 3. 插件提示词（排除已由标签说明汇总接管的标签型插件）
    final pluginPrompts = pluginPromptBuild.mergedPrompt;
    if (pluginPrompts.isNotEmpty) {
      systemParts.add(pluginPrompts);
      AppLogger.debug('ChatRequestBuilder', '添加插件提示词', metadata: {
        'pluginCount': pluginPromptBuild.entries.length,
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
    final ttsPlugin = pluginManager.getPlugin('tts') as TtsPlugin?;
    final imagePlugin = pluginManager.getPlugin('image') as ImagePlugin?;
    final includeTimestamp =
        timeAwarenessPlugin?.shouldIncludeTimestamp ?? false;
    var reqMessages = history
        .expand((m) => m.toHistoryJsonList(includeTimestamp: includeTimestamp))
        .toList();

    String? systemReminderTagPrompt;
    if (timeAwarenessPlugin != null && timeAwarenessPlugin.enabled) {
      final reminderPayload = timeAwarenessPlugin.buildSystemReminderPayload(
        currentTime: DateTime.now(),
        previousUserMessageTime: _resolvePreviousUserMessageTime(history),
      );
      if (reminderPayload != null) {
        final reminderContent =
            _systemReminderService.buildReminderContent(reminderPayload);
        if (reminderContent.isNotEmpty) {
          reqMessages = _systemReminderService.insertReminderBeforeLastUser(
            messages: reqMessages,
            reminderContent: reminderContent,
          );
          systemReminderTagPrompt =
              _buildSystemReminderTagPrompt(timeAwarenessPlugin);
        }
      }
    }
    final pluginPromptBuild =
        await _pluginContextBuilder.buildPluginPromptEntriesWithFilter(
      pluginManager.getEnabledPlugins(),
      userMessage: userMessage ?? '',
      supportsToolCalling: false,
      excludedPluginIds: _managedTagSemanticsPluginIds,
    );
    final tagSemanticsPrompt = _promptTagSemanticsService.buildMergedPrompt(
      <PromptTagSemanticsEntry>[
        if (systemReminderTagPrompt != null &&
            systemReminderTagPrompt.isNotEmpty)
          PromptTagSemanticsEntry(
            id: 'system-reminder',
            tagName: '<system-reminder>',
            prompt: systemReminderTagPrompt,
          ),
        if ((ttsPlugin?.buildTagSemanticsPrompt()?.isNotEmpty ?? false))
          PromptTagSemanticsEntry(
            id: 'tts',
            tagName: '<tts>',
            prompt: ttsPlugin!.buildTagSemanticsPrompt()!,
          ),
        if ((imagePlugin?.buildTagSemanticsPrompt()?.isNotEmpty ?? false))
          PromptTagSemanticsEntry(
            id: 'image',
            tagName: '<image>',
            prompt: imagePlugin!.buildTagSemanticsPrompt()!,
          ),
      ],
    );

    final systemPrompt = buildSystemPrompt(
      conversation: conversation,
      additionalPrompt: additionalPrompt,
      tagSemanticsPrompt: tagSemanticsPrompt,
      pluginPromptBuild: pluginPromptBuild,
    );

    if (systemPrompt.isNotEmpty) {
      reqMessages.insert(0, {
        'role': 'system',
        'content': systemPrompt,
      });
    }

    return reqMessages;
  }

  DateTime? _resolvePreviousUserMessageTime(List<Message> history) {
    if (history.isEmpty) return null;
    final shouldSkipLatestUser = history.last.role == 'user';
    var skippedLatestUser = false;
    for (var i = history.length - 1; i >= 0; i--) {
      final message = history[i];
      if (message.role != 'user') continue;
      if (shouldSkipLatestUser && !skippedLatestUser) {
        skippedLatestUser = true;
        continue;
      }
      return message.createdAt;
    }
    return null;
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
    final maxContextTokens =
        settings.getMaxContextTokens(settings.defaultModelName);
    final truncatedMessages = truncateMessagesToFit(
      messages: messages,
      maxContextTokens: maxContextTokens,
      reserveTokens: 2048,
    );
    final finalMessages = _systemReminderService.normalizeReminderPlacement(
      messages: truncatedMessages,
    );

    return ChatRequestParams(
      modelFullId: providerConfig.modelFullId,
      providerApiBase: providerConfig.providerApiBase,
      providerApiKey: providerConfig.providerApiKey,
      customConfig: providerConfig.customConfig,
      messages: finalMessages,
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
