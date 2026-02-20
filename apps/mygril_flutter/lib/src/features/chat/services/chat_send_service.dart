/// 注释已清理乱码
///
/// 注释已清理乱码
/// 注释已清理乱码
///
/// 注释已清理乱码
/// 注释已清理乱码
/// 注释已清理乱码
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
import '../../plugins/plugin_manager.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/memory/memory_plugin.dart';
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

  /// 注释已清理乱码
  final List<ToolAudioResult> toolAudioResults;

  const ApiCallResult({
    required this.replyText,
    required this.processedText,
    required this.pluginEvents,
    this.pluginContents = const [],
    required this.toolResults,
    this.toolAudioResults = const [],
  });

  /// 注释已清理乱码
  bool get hasToolAudio => toolAudioResults.isNotEmpty;
}

/// 注释已清理乱码
class ToolAudioResult {
  final String audioUrl;
  final String text;

  const ToolAudioResult({required this.audioUrl, required this.text});
}

/// 注释已清理乱码
///
/// 注释已清理乱码
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

  /// 注释已清理乱码
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

  /// 注释已清理乱码
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

  /// 准备 API 璋冪敤配置
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
      'enabledToolsCount':
          (toolPrefs['mcp_enabled_tools'] as List?)?.length ?? 0,
    });
    configTrace?.end();

    // 注释已清理乱码
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

    // 注释已清理乱码
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

    // 注释已清理乱码
    final reqMessages =
        await _buildRequestMessages(history, settings: settings);

    // 注释已清理乱码
    final systemParts = <String>[];
    if (conv.personaPrompt.isNotEmpty) {
      systemParts.add(conv.personaPrompt);
    }
    if (conv.addressUser != null && conv.addressUser!.isNotEmpty) {
      systemParts.add('你应该称呼用户为"${conv.addressUser}"。');
    }

    // 注释已清理乱码
    // 注释已清理乱码
    final supportsToolCalling = !settings.isModelToolCallingDisabled(model);
    final enabledPluginIds = conv.enabledPlugins?.toSet();
    final pluginManager = _ref.read(pluginManagerProvider);
    final effectivePlugins =
        _getEffectivePlugins(pluginManager, enabledPluginIds);
    final pluginPrompts = await _buildPluginPromptsWithFilter(
      effectivePlugins,
      userMessage: userText ?? '',
      supportsToolCalling: supportsToolCalling,
    );
    if (pluginPrompts.isNotEmpty) {
      systemParts.add(pluginPrompts);
    }

    // 注释已清理乱码
    List<Map<String, dynamic>>? tools;
    if (supportsToolCalling) {
      final aiTools = _collectPluginTools(effectivePlugins);
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

    // 注释已清理乱码
    // 注释已清理乱码
    final modelName =
        modelFull.contains(':') ? modelFull.split(':').last : modelFull;
    final maxContextTokens = getModelContextLimit(modelName);
    final truncatedMessages = truncateMessagesToFit(
      messages: reqMessages,
      maxContextTokens: maxContextTokens,
      reserveTokens: 2048, // reserve for completion
    );

    if (truncatedMessages.length < reqMessages.length) {
      MemoryPlugin? memoryPlugin;
      for (final plugin in effectivePlugins) {
        if (plugin is MemoryPlugin && plugin.enabled) {
          memoryPlugin = plugin;
          break;
        }
      }
      if (memoryPlugin != null) {
        final systemCount = systemParts.isNotEmpty ? 1 : 0;
        final keptHistoryCount =
            (truncatedMessages.length - systemCount).clamp(0, history.length);
        final droppedCount = history.length - keptHistoryCount;
        if (droppedCount > 0) {
          memoryPlugin.triggerPreFlush(
            conversationId: conv.id,
            droppedMessages: history.take(droppedCount).toList(),
          );
        }
      }
    }

    return ApiConfig(
      settings: settings,
      modelFullId: modelFull,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      customConfig: providerAuth.customConfig,
      toolPrefs: toolPrefs,
      messages: truncatedMessages,
      tools: tools,
      enabledPluginIds: enabledPluginIds,
      modelTemperature: settings.getModelConfig(model).temperature,
      modelTopP: settings.getModelConfig(model).topP,
      modelContextMessageLimit:
          settings.getModelConfig(model).contextMessageLimit,
    );
  }

  List<Plugin> _getEffectivePlugins(
    PluginManager pluginManager,
    Set<String>? enabledPluginIds,
  ) {
    final globallyEnabled = pluginManager.getEnabledPlugins();
    if (enabledPluginIds == null) {
      return globallyEnabled;
    }
    return [
      for (final plugin in globallyEnabled)
        if (enabledPluginIds.contains(plugin.id)) plugin,
    ];
  }

  Future<String> _buildPluginPromptsWithFilter(
    List<Plugin> plugins, {
    required String userMessage,
    required bool supportsToolCalling,
  }) async {
    if (plugins.isEmpty) return '';

    final prompts = <String>[];
    for (final plugin in plugins) {
      try {
        final prompt = await plugin.getSystemPrompt(
          userMessage: userMessage,
          supportsToolCalling: supportsToolCalling,
        );
        if (prompt != null && prompt.isNotEmpty) {
          prompts.add(prompt);
        }
      } catch (e) {
        AppLogger.warning('ChatSendService', '插件提示词构建失败', metadata: {
          'pluginId': plugin.id,
          'error': e.toString(),
        });
      }
    }
    return prompts.join('\n\n');
  }

  List<AITool> _collectPluginTools(List<Plugin> plugins) {
    final tools = <AITool>[];
    for (final plugin in plugins) {
      try {
        tools.addAll(plugin.getTools());
      } catch (e) {
        AppLogger.warning('ChatSendService', '插件工具收集失败', metadata: {
          'pluginId': plugin.id,
          'error': e.toString(),
        });
      }
    }
    return tools;
  }

  AITool? _findToolByName(List<Plugin> plugins, String name) {
    for (final plugin in plugins) {
      try {
        final tools = plugin.getTools();
        for (final tool in tools) {
          if (tool.name == name) return tool;
        }
      } catch (e) {
        AppLogger.warning('ChatSendService', '插件工具查找失败', metadata: {
          'pluginId': plugin.id,
          'toolName': name,
          'error': e.toString(),
        });
      }
    }
    return null;
  }

  Future<PluginProcessResult> _processResponseWithPlugins(
    List<Plugin> plugins,
    String text,
  ) async {
    if (plugins.isEmpty) {
      return PluginProcessResult(processedText: text, events: const []);
    }

    String currentText = text;
    final allEvents = <PluginEvent>[];
    final allContents = <PluginContent>[];

    for (final plugin in plugins) {
      try {
        final result = await plugin.processResponse(currentText);
        currentText = result.processedText;
        allEvents.addAll(result.events);
        allContents.addAll(result.contents);
      } catch (e) {
        AppLogger.warning('ChatSendService', '插件响应处理失败', metadata: {
          'pluginId': plugin.id,
          'error': e.toString(),
        });
      }
    }

    return PluginProcessResult(
      processedText: currentText,
      events: allEvents,
      contents: allContents,
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
          parts.add({
            'type': 'image_url',
            'image_url': {'url': url}
          });
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

  Future<String> _readTextFileForAi(FileBlock block,
      {required AppSettings settings}) async {
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
        // 注释已清理乱码
        final bytes = await File(path).readAsBytes();
        final content = utf8.decode(bytes, allowMalformed: true);
        if (content.contains('\u0000')) {
          return '用户上传了文件：${block.fileName}（${block.mimeType}），但内容疑似二进制，无法读取。';
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
    return '${content.substring(0, maxChars)}\n...(内容过长，已截断，仅发送前 $maxChars 字符)';
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

  /// 注释已清理乱码
  Future<ApiConfig> getApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
  }) =>
      prepareApiConfig(
          conv: conv, history: history, userText: userText, trace: trace);

  /// 注释已清理乱码
  ///
  /// 注释已清理乱码
  /// 1. 调用 AI API
  /// 注释已清理乱码
  /// 注释已清理乱码
  /// 注释已清理乱码
  ///
  /// 注释已清理乱码
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    TraceLogger? trace,
    int maxRounds = 5,
  }) async {
    final apiCallTrace = trace?.startChild('调用AI API');
    apiCallTrace?.note('连接', metadata: {
      'endpoint':
          config.providerApiBase.isNotEmpty ? config.providerApiBase : '后端网关',
      'model': config.modelFullId,
      'history': config.messages.length,
      'maxRounds': maxRounds,
    });

    final agent = AgentApiClient();
    final pluginManager = _ref.read(pluginManagerProvider);
    final effectivePlugins =
        _getEffectivePlugins(pluginManager, config.enabledPluginIds);
    final allToolEvents = <PluginEvent>[];
    final allToolAudioResults = <ToolAudioResult>[]; // 注释已清理乱码
    final allToolContents = <PluginContent>[]; // draw_image 工具生成的图片内容

    // 注释已清理乱码
    String provider = 'openai';
    final idx = config.modelFullId.indexOf(':');
    if (idx > 0) {
      provider = config.modelFullId.substring(0, idx);
    }
    final adapter = ProviderAdapterFactory.getAdapter(provider);

    // 注释已清理乱码
    var currentMessages = List<Map<String, dynamic>>.from(config.messages);
    SendMessageRichResult? lastRich;

    for (var round = 1; round <= maxRounds; round++) {
      final roundTrace = apiCallTrace?.startChild('第$round轮 API 调用');
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
        topP: config.modelTopP, // 注释已清理乱码
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

      // 注释已清理乱码
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
          final tool = _findToolByName(effectivePlugins, tc.name);
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

            // 注释已清理乱码
            if (tc.name == 'speak') {
              try {
                final parsed = jsonDecode(resultStr) as Map<String, dynamic>;
                final success = parsed['success'] == true;
                final audioUrl = parsed['audioUrl'] as String?;
                final text = parsed['text'] as String? ?? '';
                if (success && audioUrl != null && audioUrl.isNotEmpty) {
                  allToolAudioResults
                      .add(ToolAudioResult(audioUrl: audioUrl, text: text));
                  AppLogger.info('ChatSendService', '收集到 speak 工具音频',
                      metadata: {
                        'audioUrlLength': audioUrl.length,
                        'text': text,
                      });
                }
              } catch (e) {
                AppLogger.warning('ChatSendService', '解析 speak 结果失败',
                    metadata: {'error': e.toString()});
              }

              // 注释已清理乱码
              // 注释已清理乱码
              // 参考：https://github.com/openai/codex/issues/6426 (tool output truncation)
              toolResults.add(ToolResult(
                toolCallId: tc.id,
                name: tc.name,
                result: '{"success": true, "message": "语音已播放给用户"}',
              ));
            } else if (tc.name == 'draw_image') {
              final imageContents = _extractToolImageContents(resultStr);
              if (imageContents.isNotEmpty) {
                allToolContents.addAll(imageContents);
                AppLogger.info(
                    'ChatSendService', 'Collected draw_image tool images',
                    metadata: {
                      'count': imageContents.length,
                    });
              }
              toolResults.add(ToolResult(
                toolCallId: tc.id,
                name: tc.name,
                result: resultStr,
              ));
            } else {
              toolResults.add(ToolResult(
                toolCallId: tc.id,
                name: tc.name,
                result: resultStr,
              ));
            }
          } else {
            AppLogger.warning('ChatSendService', '未找到工具',
                metadata: {'name': tc.name});
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
        AppLogger.warning('ChatSendService', '达到最大回合数',
            metadata: {'maxRounds': maxRounds});
        roundTrace?.end(additionalMessage: '达到最大回合数');
        break;
      }

      // 构建工具结果消息，追加到 currentMessages
      // 注释已清理乱码
      final assistantMessage =
          _buildAssistantMessageFromRich(lastRich, provider);
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

    // 注释已清理乱码
    final pluginTrace = trace?.startChild('运行插件');
    final pluginResult = await _processResponseWithPlugins(
        effectivePlugins, lastRich?.text ?? '');

    pluginTrace?.note('插件处理', metadata: {
      'original': lastRich?.text.length ?? 0,
      'processed': pluginResult.processedText.length,
      'events': pluginResult.events.length,
    });
    pluginTrace?.end();

    // 注释已清理乱码
    final allEvents = [...allToolEvents, ...pluginResult.events];
    final allContents = [...allToolContents, ...pluginResult.contents];

    return ApiCallResult(
      replyText: lastRich?.text ?? '',
      processedText: pluginResult.processedText,
      pluginEvents: allEvents,
      pluginContents: allContents,
      toolResults: lastRich?.toolResults ?? [],
      toolAudioResults: allToolAudioResults,
    );
  }

  /// 注释已清理乱码
  List<PluginImageContent> _extractToolImageContents(String result) {
    final trimmed = result.trim();
    if (trimmed.isEmpty) return const <PluginImageContent>[];

    try {
      final payload = jsonDecode(trimmed);
      if (payload is! Map<String, dynamic>) return const <PluginImageContent>[];
      if (payload['success'] != true) return const <PluginImageContent>[];

      final images = payload['images'];
      if (images is! List) return const <PluginImageContent>[];

      final contents = <PluginImageContent>[];
      for (final image in images) {
        if (image is! Map) continue;
        final localPath = image['localPath']?.toString().trim() ?? '';
        if (localPath.isEmpty) continue;
        final captionRaw = image['caption']?.toString().trim();
        contents.add(
          PluginImageContent(
            localPath,
            caption:
                (captionRaw == null || captionRaw.isEmpty) ? null : captionRaw,
          ),
        );
      }
      return contents;
    } catch (_) {
      return const <PluginImageContent>[];
    }
  }

  Map<String, dynamic> _buildAssistantMessageFromRich(
      SendMessageRichResult rich, String provider) {
    // 根据 provider 类型构建不同格式
    switch (provider) {
      case 'claude':
      case 'anthropic':
        // 注释已清理乱码
        return rich.rawResponse ?? {'content': []};
      case 'gemini':
      case 'google':
        // 注释已清理乱码
        final candidates = (rich.rawResponse?['candidates'] as List?) ?? [];
        if (candidates.isNotEmpty) {
          final first = candidates.first as Map<String, dynamic>;
          return {'content': first['content']};
        }
        return {
          'content': {'parts': []}
        };
      default:
        // 注释已清理乱码
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
    // 注释已清理乱码
    // 注释已清理乱码
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
          blocks: [
            AudioBlock(
                messageId: audioId, url: audio.audioUrl, text: audio.text)
          ],
          createdAt: DateTime.now(),
          status: 'sent',
        ));
      }
      // 注释已清理乱码
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
        lastMessageText:
            audioMessages.isNotEmpty ? audioMessages.last.displayText : '',
      );
    }

    // 注释已清理乱码
    // 注释已清理乱码
    return chatMessageProcessor.buildAssistantMessages(
      replyText: apiResult.replyText,
      processedText: apiResult.processedText,
      pluginEvents: apiResult.pluginEvents,
      contents: apiResult.pluginContents,
    );
  }

  /// 注释已清理乱码
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
      'hasAudio':
          messages.any((m) => m.blocks?.any((b) => b is AudioBlock) ?? false),
    });
    forwardTrace?.end(additionalMessage: '转发成功');
  }

  /// 注释已清理乱码
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

  /// 注释已清理乱码
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

  /// 注释已清理乱码
  Map<String, dynamic> _buildToolPrefs(
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

  /// 获取 MCP 配置
  Future<McpConfigDto?> _getMcpConfig() async {
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
      // Negative cache to avoid repeated retries in weak mobile networks.
      _cachedMcpFetchedAt = DateTime.now();
      return null;
    }
  }
}

/// 注释已清理乱码
class ApiConfig {
  final AppSettings settings;
  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic> customConfig;
  final Map<String, dynamic> toolPrefs;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>>? tools; // 原生 Tool Calling 工具定义
  final Set<String>? enabledPluginIds; // 注释已清理乱码
  /// 注释已清理乱码
  final double? modelTemperature;

  /// 模型级别 Top P 参数
  final double? modelTopP;

  /// 注释已清理乱码
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
    this.enabledPluginIds,
    this.modelTemperature,
    this.modelTopP,
    this.modelContextMessageLimit,
  });

  /// 注释已清理乱码
  /// 优先级：模型设置 > 全局设置
  double get effectiveTemperature => modelTemperature ?? settings.temperature;
}

/// Provider
final chatSendServiceProvider = Provider((ref) => ChatSendService(ref));
