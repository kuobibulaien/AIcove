/// 聊天发送服务
///
/// 封装消息发送的核心流程，包括配置准备、API调用、消息交付等。
/// 从 chat_actions.dart 提取，遵循单一职责原则。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
/// - 2026-01-27: 升级 executeApiCall 支持两回合/递归工具调用
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../id_gen.dart';
import '../conversation_providers.dart';
import '../../settings/direct_mode.dart' as direct;
import '../../settings/app_settings.dart';
import '../../settings/mcp_api.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../../core/api/agent_api.dart';
import '../../../core/api/providers/provider_adapter.dart' show ToolResult;
import '../../../core/api/providers/provider_adapter_factory.dart';
import '../../../core/models/message_block.dart';
import '../../../core/app_logger.dart';
import '../../../core/utils/token_estimator.dart';
import 'chat_message_processor.dart';
import 'chat_types.dart';

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
  final List<PluginContent> pluginContents;
  final List<Map<String, dynamic>> toolResults;
  /// 工具调用产生的音频列表（speak 工具）
  final List<ToolAudioResult> toolAudioResults;

  const ApiCallResult({
    required this.replyText,
    required this.processedText,
    required this.pluginEvents,
    this.pluginContents = const [],
    required this.toolResults,
    this.toolAudioResults = const [],
  });

  /// 是否有工具调用产生的音频
  bool get hasToolAudio => toolAudioResults.isNotEmpty;
}

/// 工具调用产生的音频结果
class ToolAudioResult {
  final String audioUrl;
  final String text;

  const ToolAudioResult({required this.audioUrl, required this.text});
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

  /// 创建用户文件消息（按“文本附件”发送，供 AI 阅读）
  Future<Message> createUserFileMessage({required String filePath}) async {
    final trimmed = filePath.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('filePath is empty');
    }

    final file = File(trimmed);
    if (!await file.exists()) {
      throw StateError('File not found: $trimmed');
    }

    final msgId = genId('msg');
    final size = await file.length();
    final name = p.basename(trimmed);

    return Message.fromBlocks(
      id: msgId,
      role: 'user',
      blocks: [
        FileBlock(
          messageId: msgId,
          fileName: name,
          fileSize: size,
          mimeType: _guessMimeType(trimmed),
          filePath: trimmed,
        ),
      ],
      createdAt: DateTime.now(),
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

    // 构建消息列表（支持图片/文件等多模态）
    final reqMessages = await _buildRequestMessages(history, settings: settings);
    
    // 构建系统提示词
    final systemParts = <String>[];
    if (conv.personaPrompt.isNotEmpty) {
      systemParts.add(conv.personaPrompt);
    }
    if (conv.addressUser != null && conv.addressUser!.isNotEmpty) {
      systemParts.add('你应该称呼用户为"${conv.addressUser}"。');
    }

    // 插件提示词
    // 默认支持工具调用，除非用户在模型设置中明确禁用
    final supportsToolCalling = !settings.isModelToolCallingDisabled(model);
    final pluginManager = _ref.read(pluginManagerProvider);
    final pluginPrompts = await pluginManager.getSystemPrompts(
      userMessage: userText ?? '',
      supportsToolCalling: supportsToolCalling,
    );
    if (pluginPrompts.isNotEmpty) {
      systemParts.add(pluginPrompts);
    }

    // 收集插件工具定义（仅当模型支持 Tool Calling 时）
    List<Map<String, dynamic>>? tools;
    if (supportsToolCalling) {
      final aiTools = pluginManager.getAllTools();
      if (aiTools.isNotEmpty) {
        tools = aiTools.map((t) => t.toOpenAISchema()).toList();
        AppLogger.debug('ChatSendService', '收集插件工具', metadata: {
          'toolCount': tools.length,
          'toolNames': aiTools.map((t) => t.name).toList(),
        });
      }
    }

    if (systemParts.isNotEmpty) {
      reqMessages.insert(0, {
        'role': 'system',
        'content': systemParts.join('\n\n'),
      });
    }

    // Token 截断：确保消息总长度不超过模型上下文限制
    // 解析模型名称（移除 provider 前缀，如 "openai:gpt-4o" -> "gpt-4o"）
    final modelName = modelFull.contains(':')
        ? modelFull.split(':').last
        : modelFull;
    final maxContextTokens = getModelContextLimit(modelName);
    final truncatedMessages = truncateMessagesToFit(
      messages: reqMessages,
      maxContextTokens: maxContextTokens,
      reserveTokens: 2048, // 为模型回复预留 2K token
    );

    return ApiConfig(
      settings: settings,
      modelFullId: modelFull,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      customConfig: providerAuth.customConfig,
      toolPrefs: toolPrefs,
      messages: truncatedMessages,
      tools: tools,
      modelTemperature: settings.getModelConfig(model).temperature,
      modelTopP: settings.getModelConfig(model).topP,
      modelContextMessageLimit: settings.getModelConfig(model).contextMessageLimit,
    );
  }

  Future<List<Map<String, dynamic>>> _buildRequestMessages(
    List<Message> history, {
    required AppSettings settings,
  }) async {
    final reqMessages = <Map<String, dynamic>>[];
    for (final m in history) {
      final converted = await _toRequestMessage(m, settings: settings);
      if (converted == null) continue;
      reqMessages.add(converted);
    }
    return reqMessages;
  }

  Future<Map<String, dynamic>?> _toRequestMessage(
    Message message, {
    required AppSettings settings,
  }) async {
    final blocks = message.blocks;
    if (blocks == null || blocks.isEmpty) {
      final content = message.content;
      if (content.trim().isEmpty) return null;
      return {'role': message.role, 'content': content};
    }

    final parts = <Map<String, dynamic>>[];

    for (final block in blocks) {
      if (block is TextBlock) {
        if (block.content.trim().isEmpty) continue;
        parts.add({'type': 'text', 'text': block.content});
        continue;
      }

      if (block is ImageBlock) {
        final url = block.url?.trim();
        if (url != null && url.isNotEmpty) {
          parts.add({'type': 'image_url', 'image_url': {'url': url}});
          continue;
        }

        final base64 = block.base64?.trim();
        if (base64 != null && base64.isNotEmpty) {
          parts.add({
            'type': 'image_url',
            'image_url': {'url': 'data:image/jpeg;base64,$base64'},
          });
          continue;
        }

        final localPath = block.localPath?.trim();
        if (localPath != null && localPath.isNotEmpty) {
          final encoded = await readImageAsBase64(localPath);
          if (encoded != null && encoded.isNotEmpty) {
            final mime = _guessImageMimeType(localPath);
            parts.add({
              'type': 'image_url',
              'image_url': {'url': 'data:$mime;base64,$encoded'},
            });
          } else {
            parts.add({'type': 'text', 'text': '[图片读取失败]'});
          }
        }
        continue;
      }

      if (block is FileBlock) {
        final fileText = await _readTextFileForAi(block, settings: settings);
        if (fileText.trim().isEmpty) continue;
        parts.add({'type': 'text', 'text': fileText});
        continue;
      }
    }

    if (parts.isEmpty) {
      final content = message.content;
      if (content.trim().isEmpty) return null;
      return {'role': message.role, 'content': content};
    }

    // 只有 1 段文本时，退化为纯文本，兼容更多 OpenAI 兼容实现
    if (parts.length == 1 && parts.first['type'] == 'text') {
      return {'role': message.role, 'content': parts.first['text']};
    }

    return {'role': message.role, 'content': parts};
  }

  static const _supportedTextFileExts = <String>{
    'txt',
    'md',
    'markdown',
    'json',
    'yaml',
    'yml',
    'csv',
    'log',
    'xml',
    'ini',
    'conf',
    'toml',
    'dart',
    'py',
    'js',
    'ts',
    'java',
    'kt',
    'swift',
    'go',
    'rs',
    'c',
    'cpp',
    'h',
    'hpp',
    'html',
    'css',
    'sh',
  };

  Future<String> _readTextFileForAi(FileBlock block, {required AppSettings settings}) async {
    final path = block.filePath.trim();
    if (path.isEmpty) return '';

    final maxBytes = settings.maxFileUploadMB * 1024 * 1024;
    if (maxBytes > 0 && block.fileSize > maxBytes) {
      return '用户上传了文件：${block.fileName}（${block.fileSize}B），但文件超过大小限制，已拦截读取。';
    }

    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    if (ext.isNotEmpty && !_supportedTextFileExts.contains(ext)) {
      return '用户上传了文件：${block.fileName}（${block.mimeType}），但该格式暂不支持读取。';
    }

    try {
      final bytes = await File(path).readAsBytes();
      final content = utf8.decode(bytes, allowMalformed: false);
      final safeContent = _truncateForPrompt(content);
      final lang = ext.isEmpty ? 'text' : ext;
      return '用户上传了文件：${block.fileName}（${block.fileSize}B）。\n\n```$lang\n$safeContent\n```';
    } catch (_) {
      try {
        // 兜底：允许不完全 UTF-8，但若包含大量 NUL 字符则视为二进制
        final bytes = await File(path).readAsBytes();
        final content = utf8.decode(bytes, allowMalformed: true);
        if (content.contains('\u0000')) {
          return '用户上传了文件：${block.fileName}（${block.mimeType}），但文件似乎是二进制内容，无法读取。';
        }
        final safeContent = _truncateForPrompt(content);
        final lang = ext.isEmpty ? 'text' : ext;
        return '用户上传了文件：${block.fileName}（${block.fileSize}B）。\n\n```$lang\n$safeContent\n```';
      } catch (e) {
        return '用户上传了文件：${block.fileName}，但读取失败：$e';
      }
    }
  }

  String _truncateForPrompt(String content) {
    const maxChars = 40000;
    if (content.length <= maxChars) return content;
    return '${content.substring(0, maxChars)}\n…(内容过长，已截断，仅发送前 $maxChars 字符)';
  }

  String _guessMimeType(String filePath) {
    final ext = p.extension(filePath).replaceFirst('.', '').toLowerCase();
    switch (ext) {
      case 'txt':
      case 'log':
      case 'md':
      case 'markdown':
        return 'text/plain';
      case 'json':
        return 'application/json';
      case 'yaml':
      case 'yml':
        return 'application/x-yaml';
      case 'csv':
        return 'text/csv';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }

  String _guessImageMimeType(String imagePath) {
    final ext = p.extension(imagePath).replaceFirst('.', '').toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'jpg':
      case 'jpeg':
      default:
        return 'image/jpeg';
    }
  }

  /// 暴露 prepareApiConfig 的返回类型
  Future<ApiConfig> getApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
  }) => prepareApiConfig(conv: conv, history: history, userText: userText, trace: trace);

  /// 执行 API 调用（支持两回合/递归工具调用）
  ///
  /// 流程：
  /// 1. 调用 AI API
  /// 2. 如果 AI 返回 tool_calls，执行工具并收集结果
  /// 3. 将工具结果追加到消息列表，再次调用 API
  /// 4. 重复直到 AI 返回纯文本或达到最大回合数
  ///
  /// [maxRounds] 最大回合数，防止无限循环（默认 5）
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    TraceLogger? trace,
    int maxRounds = 5,
  }) async {
    final apiCallTrace = trace?.startChild('调用AI API');
    apiCallTrace?.note('连接', metadata: {
      'endpoint': config.providerApiBase.isNotEmpty ? config.providerApiBase : '后端网关',
      'model': config.modelFullId,
      'history': config.messages.length,
      'maxRounds': maxRounds,
    });

    final agent = AgentApiClient();
    final pluginManager = _ref.read(pluginManagerProvider);
    final allToolEvents = <PluginEvent>[];
    final allToolAudioResults = <ToolAudioResult>[]; // 收集 speak 工具产生的音频

    // 解析 provider 用于获取适配器
    String provider = 'openai';
    final idx = config.modelFullId.indexOf(':');
    if (idx > 0) {
      provider = config.modelFullId.substring(0, idx);
    }
    final adapter = ProviderAdapterFactory.getAdapter(provider);

    // 可变的消息列表（每轮可能追加工具结果）
    var currentMessages = List<Map<String, dynamic>>.from(config.messages);
    SendMessageRichResult? lastRich;

    for (var round = 1; round <= maxRounds; round++) {
      final roundTrace = apiCallTrace?.startChild('第${round}轮API调用');
      roundTrace?.note('请求', metadata: {
        'round': round,
        'messagesCount': currentMessages.length,
      });

      lastRich = await agent.sendMessageRich(
        agentId: 'default',
        sessionId: sessionId,
        modelFullId: config.modelFullId,
        messages: currentMessages,
        userText: round == 1 ? (userText ?? '') : '', // 只在第一轮传 userText
        temperature: config.effectiveTemperature,
        topP: config.modelTopP, // 模型级别 Top P（null 时由服务商默认）
        token: config.settings.backendApiKey,
        toolPrefs: config.toolPrefs,
        providerApiBase: config.providerApiBase,
        providerApiKey: config.providerApiKey,
        customConfig: config.customConfig,
        tools: config.tools,
        trace: roundTrace,
      );

      roundTrace?.note('响应', metadata: {
        'textLength': lastRich.text.length,
        'toolCalls': lastRich.toolCalls.length,
      });

      // 如果没有工具调用，结束循环
      if (!lastRich.hasToolCalls) {
        roundTrace?.end(additionalMessage: '无工具调用，结束');
        break;
      }

      // 执行工具调用
      final toolTrace = roundTrace?.startChild('执行工具调用');
      toolTrace?.note('工具', metadata: {
        'count': lastRich.toolCalls.length,
        'names': lastRich.toolCalls.map((t) => t.name).toList(),
      });

      final toolResults = <ToolResult>[];
      for (final tc in lastRich.toolCalls) {
        try {
          final tool = pluginManager.findToolByName(tc.name);
          if (tool != null) {
            AppLogger.info('ChatSendService', '执行工具调用', metadata: {
              'round': round,
              'name': tc.name,
              'args': tc.arguments,
            });
            final result = await tool.handler(tc.arguments);
            final resultStr = result ?? '';
            AppLogger.info('ChatSendService', '工具调用完成', metadata: {
              'name': tc.name,
              'result': resultStr,
            });

            // 如果是 speak 工具，解析返回的 JSON 收集音频
            if (tc.name == 'speak') {
              try {
                final parsed = jsonDecode(resultStr) as Map<String, dynamic>;
                final success = parsed['success'] == true;
                final audioUrl = parsed['audioUrl'] as String?;
                final text = parsed['text'] as String? ?? '';
                if (success && audioUrl != null && audioUrl.isNotEmpty) {
                  allToolAudioResults.add(ToolAudioResult(audioUrl: audioUrl, text: text));
                  AppLogger.info('ChatSendService', '收集到 speak 工具音频', metadata: {
                    'audioUrlLength': audioUrl.length,
                    'text': text,
                  });
                }
              } catch (e) {
                AppLogger.warning('ChatSendService', '解析 speak 结果失败', metadata: {'error': e.toString()});
              }

              // 【重要】speak 工具是"副作用工具"，AI 不需要看到音频数据
              // 只返回执行结果摘要，避免 base64 音频数据污染上下文
              // 参考：https://github.com/openai/codex/issues/6426 (tool output truncation)
              toolResults.add(ToolResult(
                toolCallId: tc.id,
                name: tc.name,
                result: '{"success": true, "message": "语音已播放给用户"}',
              ));
            } else {
              toolResults.add(ToolResult(
                toolCallId: tc.id,
                name: tc.name,
                result: resultStr,
              ));
            }
          } else {
            AppLogger.warning('ChatSendService', '未找到工具', metadata: {'name': tc.name});
            toolResults.add(ToolResult(
              toolCallId: tc.id,
              name: tc.name,
              result: '{"error": "Tool not found: ${tc.name}"}',
            ));
          }
        } catch (e) {
          AppLogger.error('ChatSendService', '工具调用失败', metadata: {
            'name': tc.name,
            'error': e.toString(),
          });
          toolResults.add(ToolResult(
            toolCallId: tc.id,
            name: tc.name,
            result: '{"error": "${e.toString()}"}',
          ));
        }
      }
      toolTrace?.end();

      // 如果是最后一轮，不再追加消息
      if (round == maxRounds) {
        AppLogger.warning('ChatSendService', '达到最大回合数', metadata: {'maxRounds': maxRounds});
        roundTrace?.end(additionalMessage: '达到最大回合数');
        break;
      }

      // 构建工具结果消息，追加到 currentMessages
      // 从 rawResponse 构建 assistant 消息
      final assistantMessage = _buildAssistantMessageFromRich(lastRich, provider);
      final toolResultMessages = adapter.buildToolResultMessages(
        assistantMessage: assistantMessage,
        toolResults: toolResults,
      );
      currentMessages = [...currentMessages, ...toolResultMessages];

      roundTrace?.note('追加工具结果', metadata: {
        'newMessagesCount': toolResultMessages.length,
        'totalMessages': currentMessages.length,
      });
      roundTrace?.end(additionalMessage: '继续下一轮');
    }

    apiCallTrace?.note('完成', metadata: {
      'textLength': lastRich?.text.length ?? 0,
      'toolResults': lastRich?.toolResults.length ?? 0,
    });
    apiCallTrace?.end(additionalMessage: 'API调用成功');

    // 插件处理（处理降级模式的标签解析）
    final pluginTrace = trace?.startChild('运行插件');
    final pluginResult = await pluginManager.processResponse(lastRich?.text ?? '');

    pluginTrace?.note('插件处理', metadata: {
      'original': lastRich?.text.length ?? 0,
      'processed': pluginResult.processedText.length,
      'events': pluginResult.events.length,
    });
    pluginTrace?.end();

    // 合并工具调用事件和插件事件
    final allEvents = [...allToolEvents, ...pluginResult.events];

    return ApiCallResult(
      replyText: lastRich?.text ?? '',
      processedText: pluginResult.processedText,
      pluginEvents: allEvents,
      pluginContents: pluginResult.contents,
      toolResults: lastRich?.toolResults ?? [],
      toolAudioResults: allToolAudioResults,
    );
  }

  /// 从 API 响应构建 assistant 消息（用于工具调用的消息追加）
  Map<String, dynamic> _buildAssistantMessageFromRich(SendMessageRichResult rich, String provider) {
    // 根据 provider 类型构建不同格式
    switch (provider) {
      case 'claude':
      case 'anthropic':
        // Anthropic 格式：返回原始 content 数组
        return rich.rawResponse ?? {'content': []};
      case 'gemini':
      case 'google':
        // Gemini 格式：返回 candidates[0].content
        final candidates = (rich.rawResponse?['candidates'] as List?) ?? [];
        if (candidates.isNotEmpty) {
          final first = candidates.first as Map<String, dynamic>;
          return {'content': first['content']};
        }
        return {'content': {'parts': []}};
      default:
        // OpenAI 格式：返回 choices[0].message
        final choices = (rich.rawResponse?['choices'] as List?) ?? [];
        if (choices.isNotEmpty) {
          final first = choices.first as Map<String, dynamic>;
          return first['message'] as Map<String, dynamic>? ?? {};
        }
        return {};
    }
  }

  /// 构建助手消息
  ///
  /// 返回 AssistantMessageBuildResult，包含消息列表和 TTS 占位消息 ID
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    // 路径A：如果有工具调用产生的音频（speak 工具），直接返回音频消息
    // 不再走路径B（<tts>标签解析）
    if (apiResult.hasToolAudio) {
      AppLogger.info('ChatSendService', '使用工具调用音频（路径A）', metadata: {
        'audioCount': apiResult.toolAudioResults.length,
      });
      final audioMessages = <Message>[];
      for (final audio in apiResult.toolAudioResults) {
        final audioId = genId('msg');
        audioMessages.add(Message.fromBlocks(
          id: audioId,
          role: 'assistant',
          blocks: [AudioBlock(messageId: audioId, url: audio.audioUrl, text: audio.text)],
          createdAt: DateTime.now(),
          status: 'sent',
        ));
      }
      // 如果 AI 还有文本回复，也一并返回（不分段，保持完整存储）
      final textContent = apiResult.processedText.trim();
      if (textContent.isNotEmpty) {
        audioMessages.add(Message(
          id: genId('msg'),
          role: 'assistant',
          content: textContent,
          createdAt: DateTime.now(),
          status: 'sent',
        ));
      }
      return AssistantMessageBuildResult(
        messages: audioMessages,
        lastMessageText: audioMessages.isNotEmpty ? audioMessages.last.displayText : '',
      );
    }

    // 路径B：没有工具音频，走正常的消息处理流程（可能含 <tts> 标签）
    // 注意：分段逻辑已移至 UI 层，这里保持消息完整存储
    return chatMessageProcessor.buildAssistantMessages(
      replyText: apiResult.replyText,
      processedText: apiResult.processedText,
      pluginEvents: apiResult.pluginEvents,
      contents: apiResult.pluginContents,
    );
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
  final List<Map<String, dynamic>>? tools; // 原生 Tool Calling 工具定义
  /// 模型级别温度参数（优先于全局设置）
  final double? modelTemperature;
  /// 模型级别 Top P 参数
  final double? modelTopP;
  /// 模型级别上下文消息数限制
  final int? modelContextMessageLimit;

  const ApiConfig({
    required this.settings,
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    required this.customConfig,
    required this.toolPrefs,
    required this.messages,
    this.tools,
    this.modelTemperature,
    this.modelTopP,
    this.modelContextMessageLimit,
  });

  /// 获取实际使用的温度参数
  /// 优先级：模型设置 > 全局设置
  double get effectiveTemperature => modelTemperature ?? settings.temperature;
}

/// Provider
final chatSendServiceProvider = Provider((ref) => ChatSendService(ref));
