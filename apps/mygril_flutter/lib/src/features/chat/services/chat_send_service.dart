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
    return inferChatModelCapabilities(modelId)
        .contains(ChatModelCapability.vision);
  }

  /// 在聊天模型不支持视觉时，为图片解析可发送给模型的文字描述。
  ///
  /// 优先复用图片块里已有的生图提示词；
  /// 若不存在，再调用视觉辅助模型回退。
  static Future<String?> resolveImageDescriptionForNonVision({
    required ImageBlock imageBlock,
    required Future<String?> Function() translateWithVision,
  }) async {
    final existingPrompt = imageBlock.prompt?.trim();
    if (existingPrompt != null && existingPrompt.isNotEmpty) {
      return existingPrompt;
    }

    final translated = (await translateWithVision())?.trim();
    if (translated == null || translated.isEmpty) return null;
    return translated;
  }

  /// 构造非视觉模型下的图片上下文文本。
  ///
  /// 设计约束：
  /// - assistant 图片不注入普通消息正文（避免模型模仿固定壳子文本）
  /// - user 图片转成中性说明，供模型理解用户刚发送了图片
  static String? buildNonVisionImageMessageText({
    required String role,
    required String? description,
  }) {
    if (role == 'assistant') return null;

    final normalized = description?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return '用户刚刚发送了一张图片，内容摘要：$normalized';
    }
    return '用户刚刚发送了一张图片（当前模型不支持视觉，无法解析细节）。';
  }

  /// 构建“assistant 最近发图”的内部媒体事件，注入 system prompt。
  ///
  /// 注意：这是内部状态提示，不应被模型原样回复给用户。
  static String buildAssistantImageEventPrompt(
    List<Message> history, {
    int maxEvents = 3,
  }) {
    if (maxEvents <= 0 || history.isEmpty) return '';

    final events = <String>[];
    for (final msg in history.reversed) {
      if (msg.role != 'assistant') continue;
      final blocks = msg.blocks;
      if (blocks == null || blocks.isEmpty) continue;

      final images = blocks.whereType<ImageBlock>().toList();
      if (images.isEmpty) continue;

      String? prompt;
      for (final image in images) {
        final currentPrompt = image.prompt?.trim();
        if (currentPrompt != null && currentPrompt.isNotEmpty) {
          prompt = currentPrompt;
          break;
        }
      }

      final countPart = 'count=${images.length}';
      final promptPart = (prompt == null || prompt.isEmpty)
          ? ''
          : ' prompt="${_sanitizePromptForEvent(prompt)}"';
      events.add('- assistant_image_sent $countPart$promptPart');
      if (events.length >= maxEvents) break;
    }

    if (events.isEmpty) return '';

    final ordered = events.reversed.toList();
    return [
      '以下是最近媒体状态（仅供内部上下文理解，禁止逐字输出给用户）：',
      '<internal_media_events>',
      ...ordered,
      '</internal_media_events>',
    ].join('\n');
  }

  static String _sanitizePromptForEvent(String prompt) {
    var normalized = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length > 160) {
      normalized = '${normalized.substring(0, 160)}...';
    }
    return normalized.replaceAll('"', "'");
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
    final modelFull = requestConfig.modelFullId;

    final supportsVision = settings.hasChatModelCapability(
      modelRef,
      ChatModelCapability.vision,
    );
    final reqMessages = await _buildRequestMessages(
      history,
      settings: settings,
      supportsVision: supportsVision,
    );

    final systemParts = <String>[];
    if (conv.personaPrompt.isNotEmpty) {
      systemParts.add(conv.personaPrompt);
    }
    final supportsToolCalling =
        settings.hasChatModelCapability(modelRef, ChatModelCapability.tools) &&
            !settings.isModelToolCallingDisabled(modelRef);
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

    if (!supportsVision) {
      final mediaContext = buildAssistantImageEventPrompt(history);
      if (mediaContext.isNotEmpty) {
        systemParts.add(mediaContext);
      }
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
      final convertedMessages = await _toRequestMessages(
        m,
        settings: settings,
        supportsVision: supportsVision,
      );
      reqMessages.addAll(convertedMessages);
    }
    return reqMessages;
  }

  Future<List<Map<String, dynamic>>> _toRequestMessages(
    Message message, {
    required AppSettings settings,
    bool supportsVision = true,
  }) async {
    final blocks = message.blocks;
    if (blocks == null || blocks.isEmpty) {
      final content = message.content;
      if (content.trim().isEmpty) return [];
      return [
        {'role': message.role, 'content': content}
      ];
    }

    final parts = <Map<String, dynamic>>[];
    final toolCalls = <Map<String, dynamic>>[];
    final toolResultMessages = <Map<String, dynamic>>[];

    for (final block in blocks) {
      if (block is TextBlock) {
        if (block.content.trim().isEmpty) continue;
        parts.add({'type': 'text', 'text': block.content});
        continue;
      }

      if (block is ImageBlock) {
        // 模型不支持视觉时，尝试使用视觉辅助模型进行翻译，填充为文本描述
        if (!supportsVision) {
          final description = await resolveImageDescriptionForNonVision(
            imageBlock: block,
            translateWithVision: () =>
                _translateImageWithVisionModel(block, settings),
          );
          final fallbackText = buildNonVisionImageMessageText(
            role: message.role,
            description: description,
          );
          if (fallbackText != null && fallbackText.isNotEmpty) {
            parts.add({'type': 'text', 'text': fallbackText});
          }
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

      if (block is ToolBlock) {
        if (block.toolCallId != null && block.toolCallId!.isNotEmpty) {
          toolCalls.add({
            'id': block.toolCallId,
            'type': 'function',
            'function': {
              'name': block.toolName,
              'arguments':
                  block.arguments != null ? jsonEncode(block.arguments) : '{}',
            }
          });
          toolResultMessages.add({
            'role': 'tool',
            'tool_call_id': block.toolCallId,
            'name': block.toolName,
            'content': block.result != null
                ? jsonEncode(block.result)
                : '{"success": true}',
          });
        }
      }
    }

    final assistantMessage = <String, dynamic>{
      'role': message.role,
    };

    if (parts.isNotEmpty) {
      if (parts.length == 1 && parts.first['type'] == 'text') {
        assistantMessage['content'] = parts.first['text'];
      } else {
        assistantMessage['content'] = parts;
      }
    } else {
      assistantMessage['content'] = '';
    }

    if (toolCalls.isNotEmpty) {
      assistantMessage['tool_calls'] = toolCalls;
    }

    return [
      if (parts.isNotEmpty || toolCalls.isNotEmpty) assistantMessage,
      ...toolResultMessages
    ];
  }

  Future<String?> _translateImageWithVisionModel(
      ImageBlock block, AppSettings settings) async {
    final visionModelRef = settings.defaultVisionModel;
    if (visionModelRef == null || visionModelRef.trim().isEmpty) return null;

    final providerId = settings.getModelProviderId(visionModelRef);
    final rawModelId = settings.getRawModelId(visionModelRef);
    if (providerId == null || rawModelId.isEmpty) return null;

    final provider = settings.providers.firstWhere(
      (p) => p.id == providerId,
      orElse: () =>
          const ProviderAuth(id: '', apiKeys: <String>[], apiBaseUrl: ''),
    );
    if (provider.id.isEmpty || provider.apiKeys.isEmpty) return null;

    final apiKey = provider.apiKeys.first.trim();
    if (apiKey.isEmpty) return null;

    final apiBaseUrl = provider.apiBaseUrl.trim();

    final imageParts = <Map<String, dynamic>>[];

    final url = block.url?.trim();
    if (url != null && url.isNotEmpty) {
      imageParts.add({
        'type': 'image_url',
        'image_url': {'url': url}
      });
    } else {
      final base64 = block.base64?.trim();
      if (base64 != null && base64.isNotEmpty) {
        imageParts.add({
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,$base64'},
        });
      } else {
        final localPath = block.localPath?.trim();
        if (localPath != null && localPath.isNotEmpty) {
          final encoded = await readImageAsBase64(localPath);
          if (encoded != null && encoded.isNotEmpty) {
            final mime = MimeUtils.guessImageMimeType(localPath);
            imageParts.add({
              'type': 'image_url',
              'image_url': {'url': 'data:$mime;base64,$encoded'},
            });
          }
        }
      }
    }

    if (imageParts.isEmpty) return null;

    final promptPart = {'type': 'text', 'text': '请详细描述这张图片的内容，不要遗漏任何重要细节'};

    final messages = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [promptPart, ...imageParts],
      }
    ];

    try {
      final agent = AgentApiClient(timeout: const Duration(seconds: 30));
      final result = await agent.sendMessageRich(
        agentId: 'system_vision',
        sessionId: 'vision_translate_${DateTime.now().millisecondsSinceEpoch}',
        modelFullId: visionModelRef,
        messages: messages,
        userText: '',
        providerApiBase: apiBaseUrl,
        providerApiKey: apiKey,
        customConfig: provider.customConfig,
      );
      final text = result.text.trim();
      if (text.isEmpty) return null;
      return text;
    } catch (e) {
      AppLogger.warning('ChatSendService', 'Vision translation failed',
          metadata: {'error': e.toString()});
      return null;
    }
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
    void Function(String toolName)? onToolExecuting,
  }) async {
    final flowSettings = config.settings.callFlowSettings;
    final isFastMode = flowSettings.mode == CallFlowMode.fast;
    final effectiveMaxRounds = isFastMode ? 1 : maxRounds;
    final modelTimeout = Duration(seconds: flowSettings.modelTimeoutSeconds);
    final toolTimeout = Duration(seconds: flowSettings.toolTimeoutSeconds);

    final apiCallTrace = trace?.startChild('调用AI API');
    apiCallTrace?.note('连接', metadata: {
      'endpoint':
          config.providerApiBase.isNotEmpty ? config.providerApiBase : '后端网关',
      'model': config.modelFullId,
      'history': config.messages.length,
      'mode': flowSettings.mode.value,
      'maxRounds': effectiveMaxRounds,
      'modelTimeoutSec': flowSettings.modelTimeoutSeconds,
      'toolTimeoutSec': flowSettings.toolTimeoutSeconds,
    });
    final effectiveTurnId = (turnId != null && turnId.trim().isNotEmpty)
        ? turnId.trim()
        : 'turn_${DateTime.now().microsecondsSinceEpoch}';

    final agent = AgentApiClient(
      timeout: modelTimeout,
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

    final allToolCalls = <ToolCall>[];
    final allRawToolResults = <ToolResult>[];

    Future<_ToolExecutionOutcome> executeToolCall(
      ToolCall tc, {
      required int round,
    }) async {
      try {
        final tool = _findToolByName(effectivePlugins, tc.name);
        if (tool == null) {
          AppLogger.warning('ChatSendService', 'Tool not found',
              metadata: {'name': tc.name});
          return _ToolExecutionOutcome(
            toolResult: ToolResult(
              toolCallId: tc.id,
              name: tc.name,
              result: jsonEncode({'error': 'Tool not found: ${tc.name}'}),
            ),
          );
        }

        // 通知调用方当前正在执行的工具名称（用于更新 UI 状态）
        onToolExecuting?.call(tc.name);
        AppLogger.info('ChatSendService', '执行工具调用', metadata: {
          'round': round,
          'name': tc.name,
          'args': tc.arguments,
        });

        final result = await tool.handler(tc.arguments).timeout(toolTimeout);
        final resultStr = result ?? '';
        AppLogger.info('ChatSendService', '工具调用完成', metadata: {
          'name': tc.name,
          'result': resultStr,
        });

        if (tc.name == 'speak') {
          ToolAudioResult? audioResult;
          try {
            final parsed = jsonDecode(resultStr) as Map<String, dynamic>;
            final success = parsed['success'] == true;
            final audioUrl = parsed['audioUrl'] as String?;
            final text = parsed['text'] as String? ?? '';
            if (success && audioUrl != null && audioUrl.isNotEmpty) {
              audioResult = ToolAudioResult(audioUrl: audioUrl, text: text);
              AppLogger.info('ChatSendService', '收集到 speak 工具音频', metadata: {
                'audioUrlLength': audioUrl.length,
                'text': text,
              });
            }
          } catch (e) {
            AppLogger.warning('ChatSendService', '解析 speak 结果失败',
                metadata: {'error': e.toString()});
          }

          return _ToolExecutionOutcome(
            toolResult: ToolResult(
              toolCallId: tc.id,
              name: tc.name,
              // 参考：https://github.com/openai/codex/issues/6426 (tool output truncation)
              result: '{"success": true, "message": "语音已播放给用户"}',
            ),
            audioResult: audioResult,
          );
        }

        if (tc.name == 'draw_image') {
          final imageContents = _extractToolImageContents(resultStr);
          if (imageContents.isNotEmpty) {
            AppLogger.info(
                'ChatSendService', 'Collected draw_image tool images',
                metadata: {
                  'count': imageContents.length,
                });
          }
          return _ToolExecutionOutcome(
            toolResult: ToolResult(
              toolCallId: tc.id,
              name: tc.name,
              result: _buildToolResultForModel(
                toolName: tc.name,
                rawResult: resultStr,
              ),
            ),
            imageContents: imageContents,
          );
        }

        return _ToolExecutionOutcome(
          toolResult: ToolResult(
            toolCallId: tc.id,
            name: tc.name,
            result: _buildToolResultForModel(
              toolName: tc.name,
              rawResult: resultStr,
            ),
          ),
        );
      } on TimeoutException {
        AppLogger.warning('ChatSendService', '工具调用超时', metadata: {
          'name': tc.name,
          'timeoutSec': flowSettings.toolTimeoutSeconds,
        });
        return _ToolExecutionOutcome(
          toolResult: ToolResult(
            toolCallId: tc.id,
            name: tc.name,
            result: jsonEncode(
              {
                'error':
                    'Tool timeout after ${flowSettings.toolTimeoutSeconds}s'
              },
            ),
          ),
        );
      } catch (e) {
        AppLogger.error('ChatSendService', '工具调用失败', metadata: {
          'name': tc.name,
          'error': e.toString(),
        });
        return _ToolExecutionOutcome(
          toolResult: ToolResult(
            toolCallId: tc.id,
            name: tc.name,
            result: jsonEncode({'error': e.toString()}),
          ),
        );
      }
    }

    void collectToolOutcome(
        _ToolExecutionOutcome outcome, List<ToolResult> to) {
      to.add(outcome.toolResult);
      if (outcome.audioResult != null) {
        allToolAudioResults.add(outcome.audioResult!);
      }
      if (outcome.imageContents.isNotEmpty) {
        allToolContents.addAll(outcome.imageContents);
      }
    }

    for (var round = 1; round <= effectiveMaxRounds; round++) {
      lastRoundIndex = round;
      final roundTrace = apiCallTrace?.startChild('第 $round 轮 API 调用');
      roundTrace?.note('请求', metadata: {
        'round': round,
        'mode': flowSettings.mode.value,
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
        'parallel': isFastMode,
      });

      final toolResults = <ToolResult>[];
      if (isFastMode) {
        final outcomes = await Future.wait([
          for (final tc in currentToolCalls) executeToolCall(tc, round: round),
        ]);
        for (final outcome in outcomes) {
          collectToolOutcome(outcome, toolResults);
        }
      } else {
        for (final tc in currentToolCalls) {
          final outcome = await executeToolCall(tc, round: round);
          collectToolOutcome(outcome, toolResults);
        }
      }
      toolTrace?.end();
      executedAnyTool = true;
      allToolCalls.addAll(currentToolCalls);
      allRawToolResults.addAll(toolResults);
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
      if (round == effectiveMaxRounds) {
        if (isFastMode) {
          AppLogger.info('ChatSendService', '快速模式停止后续模型轮次', metadata: {
            'round': round,
          });
          roundTrace?.end(additionalMessage: 'fast mode stop');
        } else {
          AppLogger.warning('ChatSendService', '达到最大回合数',
              metadata: {'maxRounds': effectiveMaxRounds});
          roundTrace?.end(additionalMessage: '达到最大回合数');
        }
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
      toolCalls: allToolCalls,
      rawToolResults: allRawToolResults,
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
      toolCalls: apiResult.toolCalls,
      rawToolResults: apiResult.rawToolResults,
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

class _ToolExecutionOutcome {
  final ToolResult toolResult;
  final ToolAudioResult? audioResult;
  final List<PluginImageContent> imageContents;

  const _ToolExecutionOutcome({
    required this.toolResult,
    this.audioResult,
    this.imageContents = const <PluginImageContent>[],
  });
}

/// Provider
final chatSendServiceProvider = Provider((ref) => ChatSendService(ref));
