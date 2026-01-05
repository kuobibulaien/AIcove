/// 聊天发送服务
/// 
/// 封装消息发送的核心流程，包括配置准备、API调用、消息交付等。
/// 从 chat_actions.dart 提取，遵循单一职责原则。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../id_gen.dart';
import '../conversation_providers.dart';
import '../../settings/direct_mode.dart' as direct;
import '../../settings/app_settings.dart';
import '../../settings/mcp_api.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/domain/plugin.dart';
import '../../../core/api/agent_api.dart';
import '../../../core/models/message_block.dart';
import '../../../core/app_logger.dart';
import 'chat_message_processor.dart';

/// 发送请求的输入参数
class SendRequest {
  final Conversation conversation;
  final String? text;
  final String? imagePath;
  final Message userMessage;
  
  const SendRequest({
    required this.conversation,
    this.text,
    this.imagePath,
    required this.userMessage,
  });
  
  String get convId => conversation.id;
  String get displayText => text ?? (imagePath != null ? '[图片]' : '');
}

/// API 调用结果
class ApiCallResult {
  final String replyText;
  final String processedText;
  final List<PluginEvent> pluginEvents;
  final List<Map<String, dynamic>> toolResults;
  
  const ApiCallResult({
    required this.replyText,
    required this.processedText,
    required this.pluginEvents,
    required this.toolResults,
  });
}

/// 聊天发送服务
/// 
/// 提供消息发送的核心功能，将复杂流程拆分为可独立测试的步骤。
class ChatSendService {
  final Ref _ref;
  final McpApi _mcpApi = McpApi();
  McpConfigDto? _cachedMcpConfig;
  DateTime? _cachedMcpFetchedAt;

  ChatSendService(this._ref);

  /// 创建用户消息
  Message createUserMessage({
    required String? text,
    required String? imagePath,
  }) {
    final now = DateTime.now();
    
    if (imagePath != null && imagePath.isNotEmpty) {
      // 图片消息
      final msgId = genId('msg');
      return Message.fromBlocks(
        id: msgId,
        role: 'user',
        blocks: [
          ImageBlock(
            messageId: msgId,
            localPath: imagePath,
          ),
        ],
        createdAt: now,
        status: 'sending',
      );
    }
    
    // 文本消息
    return Message(
      id: genId('msg'),
      role: 'user',
      content: text ?? '',
      createdAt: now,
      status: 'sending',
    );
  }

  /// 添加用户消息到对话
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) async {
    final now = DateTime.now();
    await _ref.read(conversationsProvider.notifier).updateOne(
      convId,
      (c) => c.copyWith(
        messages: [...c.messages, userMsg],
        updatedAt: now,
        lastMessage: displayText,
        lastMessageTime: now,
      ),
    );
  }

  /// 准备 API 调用配置
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
  }) async {
    final configTrace = trace?.startChild('加载配置');
    
    final settings = await _ref.read(appSettingsProvider.future);
    final mcpConfig = await _getMcpConfig();
    final toolPrefs = _buildToolPrefs(settings, mcpConfig);

    configTrace?.note('配置', metadata: {
      'ttsEnabled': settings.ttsEnabled,
      'autoTools': toolPrefs['auto_tools_enabled'] == true,
      'enabledToolsCount': (toolPrefs['mcp_enabled_tools'] as List?)?.length ?? 0,
    });
    configTrace?.end();

    // 准备模型和渠道信息
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

    // 直连配置覆盖
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

    // 构建消息列表
    final reqMessages = history.map((m) => m.toHistoryJson()).toList();
    
    // 构建系统提示词
    final systemParts = <String>[];
    if (conv.personaPrompt.isNotEmpty) {
      systemParts.add(conv.personaPrompt);
    }
    if (conv.addressUser != null && conv.addressUser!.isNotEmpty) {
      systemParts.add('你应该称呼用户为"${conv.addressUser}"。');
    }

    // 插件提示词
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

    return ApiConfig(
      settings: settings,
      modelFullId: modelFull,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      customConfig: providerAuth.customConfig,
      toolPrefs: toolPrefs,
      messages: reqMessages,
    );
  }

  /// 暴露 prepareApiConfig 的返回类型
  Future<ApiConfig> getApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
  }) => prepareApiConfig(conv: conv, history: history, userText: userText, trace: trace);

  /// 执行 API 调用
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    TraceLogger? trace,
  }) async {
    final apiCallTrace = trace?.startChild('调用AI API');
    apiCallTrace?.note('连接', metadata: {
      'endpoint': config.providerApiBase.isNotEmpty ? config.providerApiBase : '后端网关',
      'model': config.modelFullId,
      'history': config.messages.length,
    });

    final agent = AgentApiClient();
    final rich = await agent.sendMessageRich(
      agentId: 'default',
      sessionId: sessionId,
      modelFullId: config.modelFullId,
      messages: config.messages,
      userText: userText ?? '',
      temperature: config.settings.temperature,
      token: config.settings.backendApiKey,
      toolPrefs: config.toolPrefs,
      providerApiBase: config.providerApiBase,
      providerApiKey: config.providerApiKey,
      customConfig: config.customConfig,
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

    return ApiCallResult(
      replyText: rich.text,
      processedText: pluginResult.processedText,
      pluginEvents: pluginResult.events,
      toolResults: rich.toolResults,
    );
  }

  /// 构建助手消息
  List<Message> buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    final messageConfig = settings.messageFormatConfig;
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: apiResult.replyText,
      processedText: apiResult.processedText,
      pluginEvents: apiResult.pluginEvents,
      messageConfig: messageConfig,
    );
    
    // 处理后端TTS结果
    Message? audioMsg;
    if (settings.ttsEnabled && apiResult.toolResults.isNotEmpty) {
      try {
        final first = apiResult.toolResults.firstWhere(
          (e) => (e['name'] ?? '') == 'tts' && 
                 ((e['payload'] as Map<String, dynamic>?)?['audio_url']?.toString().isNotEmpty ?? false),
          orElse: () => const {'name': '', 'payload': <String, dynamic>{}},
        );
        if ((first['name'] ?? '') == 'tts') {
          final url = ((first['payload'] as Map<String, dynamic>)['audio_url'] as String?)?.trim();
          if (url != null && url.isNotEmpty) {
            final audioId = genId('msg');
            audioMsg = Message.fromBlocks(
              id: audioId,
              role: 'assistant',
              blocks: [AudioBlock(messageId: audioId, url: url, text: apiResult.replyText)],
              createdAt: DateTime.now(),
              status: 'sent',
            );
          }
        }
      } catch (_) {}
    }
    
    return [
      ...result.messages,
      if (audioMsg != null) audioMsg,
    ];
  }

  /// 交付助手消息到对话
  Future<void> deliverAssistantMessages({
    required String convId,
    required String userMsgId,
    required List<Message> messages,
    required String lastMessagePreview,
    TraceLogger? trace,
  }) async {
    final forwardTrace = trace?.startChild('向用户转发消息');
    forwardTrace?.info('消息分段完成', metadata: {
      'chunksCount': messages.length,
      'firstChunk': messages.isNotEmpty ? messages.first.displayText : '',
    });

    final now = DateTime.now();
    await _ref.read(conversationsProvider.notifier).updateOne(
      convId,
      (c) {
        final updatedMessages = c.messages.map((m) {
          if (m.id == userMsgId) {
            return m.copyWith(status: 'sent');
          }
          return m;
        }).toList();
        return c.copyWith(
          messages: [...updatedMessages, ...messages],
          updatedAt: now,
          lastMessage: lastMessagePreview,
          lastMessageTime: now,
        );
      },
    );

    forwardTrace?.info('消息已转发到用户', metadata: {
      'messagesCount': messages.length,
      'hasAudio': messages.any((m) => m.blocks?.any((b) => b is AudioBlock) ?? false),
    });
    forwardTrace?.end(additionalMessage: '转发成功');
  }

  /// 标记用户消息发送失败
  Future<void> markUserMessageFailed({
    required String convId,
    required String userMsgId,
  }) async {
    await _ref.read(conversationsProvider.notifier).updateOne(
      convId,
      (c) {
        final updatedMessages = c.messages.map((m) {
          if (m.id == userMsgId) {
            return m.copyWith(status: 'failed');
          }
          return m;
        }).toList();
        return c.copyWith(
          messages: updatedMessages,
          updatedAt: DateTime.now(),
        );
      },
    );
  }

  /// 读取图片为 Base64
  Future<String?> readImageAsBase64(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      AppLogger.error('ChatSendService', '读取图片失败: $e');
      return null;
    }
  }

  /// 准备历史消息
  List<Message> prepareHistory({
    required Conversation conv,
    required Message userMsg,
    required int limit,
  }) {
    final all = [...conv.messages, userMsg];
    if (limit <= 0 || all.length <= limit) {
      return all;
    }
    return all.sublist(all.length - limit);
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

  /// 获取 MCP 配置
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
    } catch (_) {
      _cachedMcpConfig = null;
      _cachedMcpFetchedAt = null;
      return null;
    }
  }
}

/// API 配置类
class ApiConfig {
  final AppSettings settings;
  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic> customConfig;
  final Map<String, dynamic> toolPrefs;
  final List<Map<String, dynamic>> messages;

  const ApiConfig({
    required this.settings,
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    required this.customConfig,
    required this.toolPrefs,
    required this.messages,
  });
}

/// Provider
final chatSendServiceProvider = Provider((ref) => ChatSendService(ref));
