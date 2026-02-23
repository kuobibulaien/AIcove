/// (注释已丢失)
///
/// (注释已丢失)
/// (注释已丢失)
///
/// (注释已丢失)
/// (注释已丢失)
/// (注释已丢失)
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
import '../../settings/app_settings.dart';
import 'chat_request_config.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/plugin_manager.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/memory/memory_plugin.dart';
import '../../../core/api/agent_api.dart';
import '../../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import '../../../core/api/providers/provider_adapter_factory.dart';
import '../../../core/api_logger.dart';
import '../../../core/models/message_block.dart';
import '../../../core/app_logger.dart';
import '../../../core/utils/mime_utils.dart';
import '../../../core/utils/token_estimator.dart';
import 'chat_message_processor.dart';
import 'chat_tool_fallback_parser.dart';
import 'chat_types.dart';

export 'chat_types.dart'
    show SendRequest, ApiCallResult, ApiConfig, ToolAudioResult;

/// Chat sending service.
class ChatSendService {
  final Ref _ref;
  final ChatRequestConfigBuilder _requestConfigBuilder =
      ChatRequestConfigBuilder();
  final ChatToolFallbackParser _fallbackParser = const ChatToolFallbackParser();

  ChatSendService(this._ref);

  static bool isVisionModel(String modelId) {
    final m = modelId.toLowerCase();
    const keywords = <String>[
      'gpt-4o',
      'vision',
      'vl',
      'gemini',
      'claude-3',
      'claude-sonnet-4',
      'qwen-vl',
      'glm-4v',
      'doubao-vision',
      'yi-vision',
      'llava',
      'pixtral',
      'minicpm-v',
      'internvl',
    ];
    for (final k in keywords) {
      if (m.contains(k)) return true;
    }
    return false;
  }

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

  /// (注释已丢失)
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
          mimeType: MimeUtils.guessGenericMimeType(trimmed),
          filePath: trimmed,
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sending',
    );
  }

  /// (注释已丢失)
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
    String? overrideModel,
  }) async {
    final configTrace = trace?.startChild('读取配置');

    final settings = await _ref.read(appSettingsProvider.future);
    final requestConfig = await _requestConfigBuilder.buildRequestConfig(
      settings,
      modelRef: overrideModel,
    );
    final toolPrefs = requestConfig.toolPrefs;

    configTrace?.note('配置', metadata: {
      'ttsEnabled': settings.ttsEnabled,
      'autoTools': toolPrefs['auto_tools_enabled'] == true,
      'enabledToolsCount':
          (toolPrefs['mcp_enabled_tools'] as List?)?.length ?? 0,
    });
    configTrace?.end();

    final modelRef = requestConfig.modelRef;
    final model = settings.getRawModelId(modelRef);
    final modelFull = requestConfig.modelFullId;

    final supportsVision = isVisionModel(model);
    final reqMessages = await _buildRequestMessages(
      history,
      settings: settings,
      supportsVision: supportsVision,
    );

    final systemParts = <String>[];
    if (conv.personaPrompt.isNotEmpty) {
      systemParts.add(conv.personaPrompt);
    }
    final supportsToolCalling = !settings.isModelToolCallingDisabled(modelRef);
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

    List<Map<String, dynamic>>? tools;
    if (supportsToolCalling) {
      final aiTools = _collectPluginTools(effectivePlugins);
      if (aiTools.isNotEmpty) {
        tools = aiTools.map((t) => t.toOpenAISchema()).toList();
        AppLogger.debug('ChatSendService', '收集到工具定义', metadata: {
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

    final modelName =
        modelFull.contains(':') ? modelFull.split(':').last : modelFull;
    final maxContextTokens = getModelContextLimit(modelName);
    final truncatedMessages = truncateMessagesToFit(
      messages: reqMessages,
      maxContextTokens: maxContextTokens,
      reserveTokens: 2048,
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
      providerApiBase: requestConfig.providerApiBase,
      providerApiKey: requestConfig.providerApiKey,
      customConfig: requestConfig.customConfig,
      toolPrefs: toolPrefs,
      messages: truncatedMessages,
      tools: tools,
      enabledPluginIds: enabledPluginIds,
      modelTemperature: requestConfig.modelTemperature,
      modelTopP: requestConfig.modelTopP,
      modelContextMessageLimit: requestConfig.modelContextMessageLimit,
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
        AppLogger.warning('ChatSendService', 'Failed to build plugin prompt',
            metadata: {
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
    bool supportsVision = true,
  }) async {
    final reqMessages = <Map<String, dynamic>>[];
    for (final m in history) {
      final converted = await _toRequestMessage(
        m,
        settings: settings,
        supportsVision: supportsVision,
      );
      if (converted == null) continue;
      reqMessages.add(converted);
    }
    return reqMessages;
  }

  Future<Map<String, dynamic>?> _toRequestMessage(
    Message message, {
    required AppSettings settings,
    bool supportsVision = true,
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
        // 模型不支持视觉时，仅保留图片占位，避免把生图提示词注入后续上下文
        if (!supportsVision) {
          parts.add({'type': 'text', 'text': '[图片]'});
          continue;
        }

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
            final mime = MimeUtils.guessImageMimeType(localPath);
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
      return 'User uploaded file ${block.fileName} (${block.fileSize}B), but it exceeds size limit.';
    }

    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    if (ext.isNotEmpty && !_supportedTextFileExts.contains(ext)) {
      return 'User uploaded file ${block.fileName} (${block.mimeType}), but this format is not supported for reading.';
    }

    try {
      final bytes = await File(path).readAsBytes();
      final content = utf8.decode(bytes, allowMalformed: false);
      final safeContent = _truncateForPrompt(content);
      final lang = ext.isEmpty ? 'text' : ext;
      return '用户上传了文件：${block.fileName}（${block.fileSize}B）。\n\n```$lang\n$safeContent\n```';
    } catch (_) {
      try {
        // 首次解码失败，允许 malformed 再试一次
        final bytes = await File(path).readAsBytes();
        final content = utf8.decode(bytes, allowMalformed: true);
        if (content.contains('\u0000')) {
          return 'User uploaded file ${block.fileName} (${block.mimeType}), but it appears to be binary and cannot be read as text.';
        }
        final safeContent = _truncateForPrompt(content);
        final lang = ext.isEmpty ? 'text' : ext;
        return '用户上传了文件：${block.fileName}（${block.fileSize}B）。\n\n```$lang\n$safeContent\n```';
      } catch (e) {
        return 'User uploaded file ${block.fileName}, but reading failed: $e';
      }
    }
  }

  String _truncateForPrompt(String content) {
    const maxChars = 40000;
    if (content.length <= maxChars) return content;
    return '${content.substring(0, maxChars)}\n...(内容过长，已截断，仅发送前 $maxChars 字符)';
  }

  /// (注释已丢失)
  Future<ApiConfig> getApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
  }) =>
      prepareApiConfig(
          conv: conv, history: history, userText: userText, trace: trace);

  /// (注释已丢失)
  ///
  /// (注释已丢失)
  /// 1. 调用 AI API
  /// (注释已丢失)
  /// (注释已丢失)
  /// (注释已丢失)
  ///
  /// (注释已丢失)
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
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
    final effectiveTurnId = (turnId != null && turnId.trim().isNotEmpty)
        ? turnId.trim()
        : 'turn_${DateTime.now().microsecondsSinceEpoch}';

    // 有工具调用时加长超时至 120 秒（推理模型 + 工具执行可能较慢）
    final hasTools = config.tools != null && config.tools!.isNotEmpty;
    final agent = AgentApiClient(
      timeout:
          hasTools ? const Duration(seconds: 120) : const Duration(seconds: 30),
    );
    final pluginManager = _ref.read(pluginManagerProvider);
    final effectivePlugins =
        _getEffectivePlugins(pluginManager, config.enabledPluginIds);
    final allToolEvents = <PluginEvent>[];
    final allToolAudioResults = <ToolAudioResult>[]; // (注释已丢失)
    final allToolContents = <PluginContent>[]; // draw_image 工具生成的图片内容

    // (注释已丢失)
    String provider = 'openai';
    final idx = config.modelFullId.indexOf(':');
    if (idx > 0) {
      provider = config.modelFullId.substring(0, idx);
    }
    final adapter = ProviderAdapterFactory.getAdapter(provider);
    // 部分模型（尤其经由兼容层）不会返回标准 tool_calls，而是把工具调用写进文本。
    // 这里对所有 provider 开启文本 fallback 兜底，避免因 provider 类型差异漏掉工具执行。
    const supportsTextToolFallback = true;

    // (注释已丢失)
    var currentMessages = List<Map<String, dynamic>>.from(config.messages);
    SendMessageRichResult? lastRich;
    final executedFallbackCallSignatures = <String>{};
    var executedAnyTool = false;
    var lastRoundIndex = 1;

    for (var round = 1; round <= maxRounds; round++) {
      lastRoundIndex = round;
      final roundTrace = apiCallTrace?.startChild('第 $round 轮 API 调用');
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
        topP: config.modelTopP, // (注释已丢失)
        token: config.settings.backendApiKey,
        toolPrefs: config.toolPrefs,
        providerApiBase: config.providerApiBase,
        providerApiKey: config.providerApiKey,
        customConfig: config.customConfig,
        tools: config.tools,
        trace: roundTrace,
        turnId: effectiveTurnId,
        roundIndex: round,
      );

      roundTrace?.note('响应', metadata: {
        'textLength': lastRich.text.length,
        'toolCalls': lastRich.toolCalls.length,
      });

      // (注释已丢失)
      var currentToolCalls = List<ToolCall>.from(lastRich.toolCalls);
      var usesFallbackToolCalls = false;
      if (currentToolCalls.isEmpty && supportsTextToolFallback) {
        final fallbackToolCalls = _extractFallbackToolCalls(lastRich.text);
        if (fallbackToolCalls.isNotEmpty) {
          final deduped = <ToolCall>[];
          for (final call in fallbackToolCalls) {
            final signature = _buildToolCallSignature(call);
            if (executedFallbackCallSignatures.contains(signature)) {
              continue;
            }
            executedFallbackCallSignatures.add(signature);
            deduped.add(call);
          }
          if (deduped.isNotEmpty) {
            currentToolCalls = deduped;
            usesFallbackToolCalls = true;
            AppLogger.info('ChatSendService', 'Parsed text tool call fallback',
                metadata: {
                  'round': round,
                  'count': deduped.length,
                  'names': deduped.map((t) => t.name).toList(),
                });
          } else {
            AppLogger.warning(
              'ChatSendService',
              'Duplicate fallback tool call skipped',
              metadata: {'round': round},
            );
          }
        }
      }
      if (currentToolCalls.isEmpty) {
        roundTrace?.end(additionalMessage: 'no tool call, stop');
        break;
      }

      // 执行工具调用
      final toolTrace = roundTrace?.startChild('执行工具调用');
      toolTrace?.note('工具', metadata: {
        'count': currentToolCalls.length,
        'names': currentToolCalls.map((t) => t.name).toList(),
      });

      final toolResults = <ToolResult>[];
      for (final tc in currentToolCalls) {
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

            // (注释已丢失)
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

              // (注释已丢失)
              // (注释已丢失)
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
                result: _buildToolResultForModel(
                  toolName: tc.name,
                  rawResult: resultStr,
                ),
              ));
            } else {
              toolResults.add(ToolResult(
                toolCallId: tc.id,
                name: tc.name,
                result: _buildToolResultForModel(
                  toolName: tc.name,
                  rawResult: resultStr,
                ),
              ));
            }
          } else {
            AppLogger.warning('ChatSendService', 'Tool not found',
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
      executedAnyTool = true;
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'TOOL',
        url: 'local://chat/tools',
        status: 200,
        durationMs: 0,
        requestBody: '',
        responseBody: '',
        ok: true,
        sessionId: sessionId,
        turnId: effectiveTurnId,
        roundIndex: round,
        eventType: 'tool_execution',
        rawToolCalls: _encodeToolCallsForLog(currentToolCalls),
        rawToolResults: _encodeToolResultsForLog(toolResults),
      ));

      // 如果是最后一轮，不再追加消息
      if (round == maxRounds) {
        AppLogger.warning('ChatSendService', '达到最大回合数',
            metadata: {'maxRounds': maxRounds});
        roundTrace?.end(additionalMessage: '达到最大回合数');
        break;
      }

      // 构建工具结果消息，追加到 currentMessages
      // (注释已丢失)
      final assistantMessage = usesFallbackToolCalls
          ? _buildFallbackAssistantMessageForToolCalls(
              currentToolCalls,
              provider,
            )
          : _buildAssistantMessageFromRich(lastRich, provider);
      final toolResultMessages = adapter.buildToolResultMessages(
        assistantMessage: assistantMessage,
        toolResults: toolResults,
      );
      currentMessages = [...currentMessages, ...toolResultMessages];

      roundTrace?.note('追加工具结果', metadata: {
        'newMessagesCount': toolResultMessages.length,
        'totalMessages': currentMessages.length,
      });
      roundTrace?.end(additionalMessage: 'continue next round');
    }

    var finalAssistantText = lastRich?.text ?? '';
    final generatedImageCount =
        allToolContents.whereType<PluginImageContent>().length;
    if (executedAnyTool &&
        (finalAssistantText.trim().isEmpty ||
            _looksLikeToolInstructionText(finalAssistantText))) {
      finalAssistantText = _buildToolCompletionSummary(
        generatedImageCount: generatedImageCount,
        hasAudio: allToolAudioResults.isNotEmpty,
      );
    }
    finalAssistantText = _sanitizeAssistantText(finalAssistantText);
    if (generatedImageCount > 0) {
      finalAssistantText =
          _stripStandaloneImagePlaceholders(finalAssistantText);
    }
    if (executedAnyTool && finalAssistantText.trim().isEmpty) {
      finalAssistantText = _buildToolCompletionSummary(
        generatedImageCount: generatedImageCount,
        hasAudio: allToolAudioResults.isNotEmpty,
      );
    }

    apiCallTrace?.note('完成', metadata: {
      'textLength': finalAssistantText.length,
      'toolResults': lastRich?.toolResults.length ?? 0,
    });
    apiCallTrace?.end(additionalMessage: 'API调用成功');

    // (注释已丢失)
    final pluginTrace = trace?.startChild('运行插件');
    final pluginResult =
        await _processResponseWithPlugins(effectivePlugins, finalAssistantText);

    pluginTrace?.note('插件处理', metadata: {
      'original': finalAssistantText.length,
      'processed': pluginResult.processedText.length,
      'events': pluginResult.events.length,
    });
    pluginTrace?.end();
    ApiLogger.add(ApiLogEntry(
      time: DateTime.now(),
      method: 'DELIVER',
      url: 'local://chat/final_reply',
      status: 200,
      durationMs: 0,
      requestBody: '',
      responseBody: '',
      ok: true,
      sessionId: sessionId,
      turnId: effectiveTurnId,
      roundIndex: lastRoundIndex,
      eventType: 'final_response',
      rawAiResponse: finalAssistantText,
      finalReply: pluginResult.processedText,
    ));

    // (注释已丢失)
    final allEvents = [...allToolEvents, ...pluginResult.events];
    final allContents = [...allToolContents, ...pluginResult.contents];

    return ApiCallResult(
      replyText: finalAssistantText,
      processedText: pluginResult.processedText,
      pluginEvents: allEvents,
      pluginContents: allContents,
      toolResults: lastRich?.toolResults ?? [],
      toolAudioResults: allToolAudioResults,
    );
  }

  /// (注释已丢失)
  String? _encodeToolCallsForLog(List<ToolCall> calls) {
    if (calls.isEmpty) return null;
    return jsonEncode([
      for (final c in calls)
        {
          'id': c.id,
          'name': c.name,
          'arguments': c.arguments,
        }
    ]);
  }

  String? _encodeToolResultsForLog(List<ToolResult> results) {
    if (results.isEmpty) return null;
    return jsonEncode([
      for (final r in results)
        {
          'toolCallId': r.toolCallId,
          'name': r.name,
          'result': r.result,
        }
    ]);
  }

  List<PluginImageContent> _extractToolImageContents(String result) {
    final trimmed = result.trim();
    if (trimmed.isEmpty) return const <PluginImageContent>[];

    final payload = _tryParseJsonMap(trimmed);
    if (payload == null) return const <PluginImageContent>[];

    final contents = <PluginImageContent>[];
    final seenPaths = <String>{};

    void collect(dynamic value, {String? fallbackCaption}) {
      String localPath = '';
      String? caption;

      if (value is Map) {
        final map = _toStringDynamicMap(value);
        localPath = (map['localPath'] ??
                    map['image_path'] ??
                    map['imagePath'] ??
                    map['path'])
                ?.toString()
                .trim() ??
            '';
        caption = map['caption']?.toString().trim();
        caption ??= map['prompt']?.toString().trim();
      } else if (value is String) {
        localPath = value.trim();
      }

      if (localPath.isEmpty || !seenPaths.add(localPath)) {
        return;
      }

      final effectiveCaption = (caption == null || caption.isEmpty)
          ? (fallbackCaption == null || fallbackCaption.isEmpty
              ? null
              : fallbackCaption)
          : caption;
      contents.add(PluginImageContent(localPath, caption: effectiveCaption));
    }

    final promptCaption = payload['prompt']?.toString().trim();
    final images = payload['images'];
    if (images is List) {
      for (final image in images) {
        collect(image, fallbackCaption: promptCaption);
      }
    }

    collect(payload['image'], fallbackCaption: promptCaption);
    collect(payload['image_path'], fallbackCaption: promptCaption);
    collect(payload['imagePath'], fallbackCaption: promptCaption);
    collect(payload['localPath'], fallbackCaption: promptCaption);
    collect(payload['path'], fallbackCaption: promptCaption);

    final data = payload['data'];
    if (data is Map) {
      final dataMap = _toStringDynamicMap(data);
      collect(dataMap['image'], fallbackCaption: promptCaption);
      collect(dataMap['image_path'], fallbackCaption: promptCaption);
      collect(dataMap['imagePath'], fallbackCaption: promptCaption);
      collect(dataMap['localPath'], fallbackCaption: promptCaption);
      collect(dataMap['path'], fallbackCaption: promptCaption);
      final dataImages = dataMap['images'];
      if (dataImages is List) {
        for (final image in dataImages) {
          collect(image, fallbackCaption: promptCaption);
        }
      }
    }

    return contents;
  }

  List<ToolCall> _extractFallbackToolCalls(String text) =>
      _fallbackParser.extractFallbackToolCalls(text);

  Map<String, dynamic>? _tryParseJsonMap(String raw) =>
      _fallbackParser.tryParseJsonMap(raw);

  Map<String, dynamic> _toStringDynamicMap(Map raw) =>
      _fallbackParser.toStringDynamicMap(raw);

  String _buildToolCallSignature(ToolCall call) {
    final keys = call.arguments.keys.toList()..sort();
    final normalizedArgs = <String, dynamic>{};
    for (final key in keys) {
      normalizedArgs[key] = call.arguments[key];
    }
    return '${call.name}:${jsonEncode(normalizedArgs)}';
  }

  String _buildToolResultForModel({
    required String toolName,
    required String rawResult,
  }) {
    if (toolName != 'draw_image') {
      return rawResult;
    }

    final payload = _tryParseJsonMap(rawResult.trim());
    if (payload == null) {
      return rawResult;
    }

    final summary = <String, dynamic>{};
    final success = payload['success'];
    if (success is bool) {
      summary['success'] = success;
    }

    final provider = payload['provider']?.toString().trim();
    if (provider != null && provider.isNotEmpty) {
      summary['provider'] = provider;
    }

    final model = payload['model']?.toString().trim();
    if (model != null && model.isNotEmpty) {
      summary['model'] = model;
    }

    var imageCount = 0;
    final images = payload['images'];
    if (images is List) {
      imageCount = images.length;
    } else {
      final hasSingleImage = [
        payload['image'],
        payload['image_path'],
        payload['imagePath'],
        payload['localPath'],
        payload['path'],
      ].any((v) => v != null && v.toString().trim().isNotEmpty);
      if (hasSingleImage) {
        imageCount = 1;
      }
    }
    summary['image_count'] = imageCount;

    final message = payload['message']?.toString().trim();
    if (message != null && message.isNotEmpty) {
      summary['message'] = message;
    }

    final error = payload['error']?.toString().trim();
    if (error != null && error.isNotEmpty) {
      summary['error'] = error;
    }

    return jsonEncode(summary);
  }

  String _sanitizeAssistantText(String text) {
    var cleaned = text;
    if (cleaned.trim().isEmpty) return cleaned.trim();

    // 去除思维链标签，避免透传到用户端。
    cleaned = cleaned.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
      '',
    );
    cleaned =
        cleaned.replaceAll(RegExp(r'</?think>', caseSensitive: false), '');

    // 将伪造的图片占位（携带 prompt）收敛为标准占位符
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'\[(图片|image)\s*:\s*[^\]]*?\]', caseSensitive: false),
      (_) => '[图片]',
    );

    return cleaned.trim();
  }

  String _stripStandaloneImagePlaceholders(String text) {
    var cleaned = text;
    if (cleaned.trim().isEmpty) return cleaned.trim();

    // 仅删除独立占一行的图片占位符，避免与已投递的图片消息重复展示。
    cleaned = cleaned.replaceAll(
      RegExp(
        r'^[ \t]*\[(?:图片|image)(?:\s*:[^\]]*)?\][ \t]*(?:\r?\n)?',
        caseSensitive: false,
        multiLine: true,
      ),
      '',
    );

    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return cleaned.trim();
  }

  bool _looksLikeToolInstructionText(String text) {
    if (text.trim().isEmpty) return false;
    if (text.contains('<execute_tool>')) return true;
    if (RegExp(r'"action"\s*:\s*"[a-zA-Z_][a-zA-Z0-9_]*"').hasMatch(text)) {
      return true;
    }
    if (RegExp(r'"action_input"\s*:').hasMatch(text)) return true;
    if (RegExp(
      r'^\s*\[(prompt|negative_prompt|size)\]\s*$',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(text)) {
      return true;
    }
    if (RegExp(r'\bdraw_image\s*\(', caseSensitive: false).hasMatch(text)) {
      return true;
    }
    return false;
  }

  String _buildToolCompletionSummary({
    required int generatedImageCount,
    required bool hasAudio,
  }) {
    final chunks = <String>[];
    if (generatedImageCount > 0) {
      chunks.add(
        generatedImageCount == 1
            ? 'Image generated and sent.'
            : 'Images generated and sent ($generatedImageCount total).',
      );
    }
    if (hasAudio) {
      chunks.add('Audio output was also handled.');
    }
    if (chunks.isEmpty) {
      return 'Tool call executed.';
    }
    return chunks.join('\n');
  }

  Map<String, dynamic> _buildFallbackAssistantMessageForToolCalls(
    List<ToolCall> toolCalls,
    String provider,
  ) {
    if (!ProviderAdapterFactory.isOpenAICompatible(provider)) {
      return <String, dynamic>{'content': ''};
    }
    return <String, dynamic>{
      'content': null,
      'tool_calls': [
        for (var i = 0; i < toolCalls.length; i++)
          {
            'id': toolCalls[i].id.trim().isNotEmpty
                ? toolCalls[i].id
                : 'fallback_tool_call_${i + 1}',
            'type': 'function',
            'function': {
              'name': toolCalls[i].name,
              'arguments': jsonEncode(toolCalls[i].arguments),
            },
          }
      ],
    };
  }

  Map<String, dynamic> _buildAssistantMessageFromRich(
      SendMessageRichResult rich, String provider) {
    // 根据 provider 类型构建不同格式
    switch (provider) {
      case 'claude':
      case 'anthropic':
        // (注释已丢失)
        return rich.rawResponse ?? {'content': []};
      case 'gemini':
      case 'google':
        // (注释已丢失)
        final candidates = (rich.rawResponse?['candidates'] as List?) ?? [];
        if (candidates.isNotEmpty) {
          final first = candidates.first as Map<String, dynamic>;
          return {'content': first['content']};
        }
        return {
          'content': {'parts': []}
        };
      default:
        // (注释已丢失)
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
    // (注释已丢失)
    // (注释已丢失)
    if (apiResult.hasToolAudio) {
      AppLogger.info('ChatSendService', 'Use tool audio output', metadata: {
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
      // (注释已丢失)
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

    // (注释已丢失)
    // (注释已丢失)
    return chatMessageProcessor.buildAssistantMessages(
      replyText: apiResult.replyText,
      processedText: apiResult.processedText,
      pluginEvents: apiResult.pluginEvents,
      contents: apiResult.pluginContents,
    );
  }

  /// (注释已丢失)
  Future<void> deliverAssistantMessages({
    required String convId,
    required String userMsgId,
    required List<Message> messages,
    required String lastMessagePreview,
    TraceLogger? trace,
  }) async {
    final forwardTrace = trace?.startChild('deliver message to user');
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

  /// (注释已丢失)
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

  /// (注释已丢失)
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

    // Respect the "new topic" marker: only messages after the marker are
    // eligible for model context.
    var contextWindow = all;
    final contextStartId = conv.contextStartMessageId;
    if (contextStartId != null && contextStartId.isNotEmpty) {
      final markerIndex = all.lastIndexWhere((m) => m.id == contextStartId);
      if (markerIndex >= 0 && markerIndex + 1 < all.length) {
        contextWindow = all.sublist(markerIndex + 1);
      }
    }

    if (limit <= 0 || contextWindow.length <= limit) {
      return contextWindow;
    }
    return contextWindow.sublist(contextWindow.length - limit);
  }
}

/// Provider
final chatSendServiceProvider = Provider((ref) => ChatSendService(ref));
