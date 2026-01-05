/// 聊天请求执行器
/// 
/// 封装发送消息的通用流程，减少 ChatActions 中的重复代码。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../../settings/direct_mode.dart' as direct;
import '../../settings/app_settings.dart';
import '../../settings/mcp_api.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/domain/plugin.dart';
import '../../../core/api/agent_api.dart';
import '../../../core/app_logger.dart';

/// 请求上下文：封装一次请求所需的所有配置
class ChatRequestContext {
  final AppSettings settings;
  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic> customConfig;
  final Map<String, dynamic> toolPrefs;
  final List<Map<String, dynamic>> messages;
  final String? userText;
  
  const ChatRequestContext({
    required this.settings,
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    required this.customConfig,
    required this.toolPrefs,
    required this.messages,
    this.userText,
  });
}

/// 请求响应结果
class ChatRequestResult {
  final String replyText;
  final String processedText;
  final List<PluginEvent> pluginEvents;
  final List<Map<String, dynamic>> toolResults;
  
  const ChatRequestResult({
    required this.replyText,
    required this.processedText,
    required this.pluginEvents,
    required this.toolResults,
  });
}

/// 聊天请求执行器
/// 
/// 封装配置加载、API 调用、插件处理的通用流程
class ChatRequestExecutor {
  final Ref _ref;
  final McpApi _mcpApi = McpApi();
  McpConfigDto? _cachedMcpConfig;
  DateTime? _cachedMcpFetchedAt;

  ChatRequestExecutor(this._ref);

  /// 准备请求上下文
  Future<ChatRequestContext> prepareContext({
    required Conversation conv,
    required List<Message> history,
    String? userText,
    TraceLogger? trace,
  }) async {
    final configTrace = trace?.startChild('加载配置');

    // 1. 加载设置
    final settings = await _ref.read(appSettingsProvider.future);
    final mcpConfig = await _getMcpConfig();
    final toolPrefs = _buildToolPrefs(settings, mcpConfig);

    configTrace?.note('配置', metadata: {
      'ttsEnabled': settings.ttsEnabled,
      'autoTools': toolPrefs['auto_tools_enabled'] == true,
      'enabledToolsCount': (toolPrefs['mcp_enabled_tools'] as List?)?.length ?? 0,
    });
    configTrace?.end();

    // 2. 准备模型和渠道信息
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
    var providerApiKey =
        providerAuth.apiKeys.isNotEmpty ? providerAuth.apiKeys.first.trim() : null;

    // 3. 直连配置覆盖
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

    // 4. 构建消息列表
    final reqMessages = history.map((m) => m.toHistoryJson()).toList();
    
    // 5. 构建系统提示词
    final systemParts = <String>[];
    if (conv.personaPrompt.isNotEmpty) {
      systemParts.add(conv.personaPrompt);
    }
    if (conv.addressUser != null && conv.addressUser!.isNotEmpty) {
      systemParts.add('你应该称呼用户为"${conv.addressUser}"。');
    }

    // 6. 插件提示词
    final pluginManager = _ref.read(pluginManagerProvider);
    final pluginPrompts = await pluginManager.getSystemPrompts(userMessage: userText ?? '');
    if (pluginPrompts.isNotEmpty) {
      systemParts.add(pluginPrompts);
    }

    if (systemParts.isNotEmpty) {
      reqMessages.insert(0, {
        'role': 'system',
        'content': systemParts.join('\n\n'),
      });
    }

    return ChatRequestContext(
      settings: settings,
      modelFullId: modelFull,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      customConfig: providerAuth.customConfig,
      toolPrefs: toolPrefs,
      messages: reqMessages,
      userText: userText,
    );
  }

  /// 执行 API 调用
  Future<ChatRequestResult> executeRequest({
    required ChatRequestContext context,
    required String sessionId,
    TraceLogger? trace,
  }) async {
    final apiCallTrace = trace?.startChild('调用AI API');
    apiCallTrace?.note('连接', metadata: {
      'endpoint': context.providerApiBase.isNotEmpty ? context.providerApiBase : '后端网关',
      'model': context.modelFullId,
      'history': context.messages.length,
    });

    final agent = AgentApiClient();
    final rich = await agent.sendMessageRich(
      agentId: 'default',
      sessionId: sessionId,
      modelFullId: context.modelFullId,
      messages: context.messages,
      userText: context.userText ?? '',
      temperature: context.settings.temperature,
      token: context.settings.backendApiKey,
      toolPrefs: context.toolPrefs,
      providerApiBase: context.providerApiBase,
      providerApiKey: context.providerApiKey,
      customConfig: context.customConfig,
      trace: apiCallTrace,
    );

    apiCallTrace?.note('响应', metadata: {
      'textLength': rich.text.length,
      'toolResults': rich.toolResults.length,
    });
    apiCallTrace?.end(additionalMessage: 'API调用成功');

    // 插件处理
    final pluginTrace = trace?.startChild('运行插件');
    final pluginManager = _ref.read(pluginManagerProvider);
    final pluginResult = await pluginManager.processResponse(rich.text);

    pluginTrace?.note('插件处理', metadata: {
      'original': rich.text.length,
      'processed': pluginResult.processedText.length,
      'events': pluginResult.events.length,
    });
    pluginTrace?.end();

    return ChatRequestResult(
      replyText: rich.text,
      processedText: pluginResult.processedText,
      pluginEvents: pluginResult.events,
      toolResults: rich.toolResults,
    );
  }

  /// 构建工具偏好配置
  Map<String, dynamic> _buildToolPrefs(AppSettings settings, McpConfigDto? config) {
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

  /// 获取 MCP 配置（带缓存）
  Future<McpConfigDto?> _getMcpConfig() async {
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
    } catch (e) {
      _cachedMcpConfig = null;
      _cachedMcpFetchedAt = null;
      AppLogger.warning('ChatRequestExecutor', 'MCP 配置获取失败: $e');
      return null;
    }
  }
}

/// Provider
final chatRequestExecutorProvider = Provider((ref) => ChatRequestExecutor(ref));
