/// 鑱婂ぉ鍙戦€佹湇鍔?
///
/// 灏佽娑堟伅鍙戦€佺殑鏍稿績娴佺▼锛屽寘鎷厤缃噯澶囥€丄PI璋冪敤銆佹秷鎭氦浠樼瓑銆?
/// 浠?chat_actions.dart 鎻愬彇锛岄伒寰崟涓€鑱岃矗鍘熷垯銆?
///
/// 鏇存柊璁板綍锛?
/// - 2025-12-31: 浠?chat_actions.dart 鎻愬彇
/// - 2026-01-27: 鍗囩骇 executeApiCall 鏀寔涓ゅ洖鍚?閫掑綊宸ュ叿璋冪敤
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

/// 鍙戦€佽姹傜殑杈撳叆鍙傛暟
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
  String get displayText => text ?? (imagePath != null ? '[鍥剧墖]' : '');
}

/// API 璋冪敤缁撴灉
class ApiCallResult {
  final String replyText;
  final String processedText;
  final List<PluginEvent> pluginEvents;
  final List<PluginContent> pluginContents;
  final List<Map<String, dynamic>> toolResults;

  /// 宸ュ叿璋冪敤浜х敓鐨勯煶棰戝垪琛紙speak 宸ュ叿锛?
  final List<ToolAudioResult> toolAudioResults;

  const ApiCallResult({
    required this.replyText,
    required this.processedText,
    required this.pluginEvents,
    this.pluginContents = const [],
    required this.toolResults,
    this.toolAudioResults = const [],
  });

  /// 鏄惁鏈夊伐鍏疯皟鐢ㄤ骇鐢熺殑闊抽
  bool get hasToolAudio => toolAudioResults.isNotEmpty;
}

/// 宸ュ叿璋冪敤浜х敓鐨勯煶棰戠粨鏋?
class ToolAudioResult {
  final String audioUrl;
  final String text;

  const ToolAudioResult({required this.audioUrl, required this.text});
}

/// 鑱婂ぉ鍙戦€佹湇鍔?
///
/// 鎻愪緵娑堟伅鍙戦€佺殑鏍稿績鍔熻兘锛屽皢澶嶆潅娴佺▼鎷嗗垎涓哄彲鐙珛娴嬭瘯鐨勬楠ゃ€?
class ChatSendService {
  final Ref _ref;
  final McpApi _mcpApi = McpApi();
  McpConfigDto? _cachedMcpConfig;
  DateTime? _cachedMcpFetchedAt;

  ChatSendService(this._ref);

  /// 鍒涘缓鐢ㄦ埛娑堟伅
  Message createUserMessage({
    required String? text,
    required String? imagePath,
  }) {
    final now = DateTime.now();

    if (imagePath != null && imagePath.isNotEmpty) {
      // 鍥剧墖娑堟伅
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

    // 鏂囨湰娑堟伅
    return Message(
      id: genId('msg'),
      role: 'user',
      content: text ?? '',
      createdAt: now,
      status: 'sending',
    );
  }

  /// 鍒涘缓鐢ㄦ埛鏂囦欢娑堟伅锛堟寜鈥滄枃鏈檮浠垛€濆彂閫侊紝渚?AI 闃呰锛?
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

  /// 娣诲姞鐢ㄦ埛娑堟伅鍒板璇?
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

  /// 鍑嗗 API 璋冪敤閰嶇疆
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
  }) async {
    final configTrace = trace?.startChild('鍔犺浇閰嶇疆');

    final settings = await _ref.read(appSettingsProvider.future);
    final mcpConfig = await _getMcpConfig();
    final toolPrefs = _buildToolPrefs(settings, mcpConfig);

    configTrace?.note('閰嶇疆', metadata: {
      'ttsEnabled': settings.ttsEnabled,
      'autoTools': toolPrefs['auto_tools_enabled'] == true,
      'enabledToolsCount':
          (toolPrefs['mcp_enabled_tools'] as List?)?.length ?? 0,
    });
    configTrace?.end();

    // 鍑嗗妯″瀷鍜屾笭閬撲俊鎭?
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

    // 鐩磋繛閰嶇疆瑕嗙洊
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

    // 鏋勫缓娑堟伅鍒楄〃锛堟敮鎸佸浘鐗?鏂囦欢绛夊妯℃€侊級
    final reqMessages =
        await _buildRequestMessages(history, settings: settings);

    // 鏋勫缓绯荤粺鎻愮ず璇?
    final systemParts = <String>[];
    if (conv.personaPrompt.isNotEmpty) {
      systemParts.add(conv.personaPrompt);
    }
    if (conv.addressUser != null && conv.addressUser!.isNotEmpty) {
      systemParts.add('你应该称呼用户为"${conv.addressUser}"。');
    }

    // 鎻掍欢鎻愮ず璇?
    // 榛樿鏀寔宸ュ叿璋冪敤锛岄櫎闈炵敤鎴峰湪妯″瀷璁剧疆涓槑纭鐢?
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

    // 鏀堕泦鎻掍欢宸ュ叿瀹氫箟锛堜粎褰撴ā鍨嬫敮鎸?Tool Calling 鏃讹級
    List<Map<String, dynamic>>? tools;
    if (supportsToolCalling) {
      final aiTools = _collectPluginTools(effectivePlugins);
      if (aiTools.isNotEmpty) {
        tools = aiTools.map((t) => t.toOpenAISchema()).toList();
        AppLogger.debug('ChatSendService', '鏀堕泦鎻掍欢宸ュ叿', metadata: {
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

    // Token 鎴柇锛氱‘淇濇秷鎭€婚暱搴︿笉瓒呰繃妯″瀷涓婁笅鏂囬檺鍒?
    // 瑙ｆ瀽妯″瀷鍚嶇О锛堢Щ闄?provider 鍓嶇紑锛屽 "openai:gpt-4o" -> "gpt-4o"锛?
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
        AppLogger.warning('ChatSendService', '鎻掍欢宸ュ叿鏀堕泦澶辫触', metadata: {
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
        AppLogger.warning('ChatSendService', '鎻掍欢宸ュ叿鏌ユ壘澶辫触', metadata: {
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
        AppLogger.warning('ChatSendService', '鎻掍欢鍝嶅簲澶勭悊澶辫触', metadata: {
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
            parts.add({'type': 'text', 'text': '[鍥剧墖璇诲彇澶辫触]'});
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

    // 鍙湁 1 娈垫枃鏈椂锛岄€€鍖栦负绾枃鏈紝鍏煎鏇村 OpenAI 鍏煎瀹炵幇
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
      return '鐢ㄦ埛涓婁紶浜嗘枃浠讹細${block.fileName}锛?{block.fileSize}B锛夈€俓n\n```$lang\n$safeContent\n```';
    } catch (_) {
      try {
        // 鍏滃簳锛氬厑璁镐笉瀹屽叏 UTF-8锛屼絾鑻ュ寘鍚ぇ閲?NUL 瀛楃鍒欒涓轰簩杩涘埗
        final bytes = await File(path).readAsBytes();
        final content = utf8.decode(bytes, allowMalformed: true);
        if (content.contains('\u0000')) {
          return '用户上传了文件：${block.fileName}（${block.mimeType}），但内容疑似二进制，无法读取。';
        }
        final safeContent = _truncateForPrompt(content);
        final lang = ext.isEmpty ? 'text' : ext;
        return '鐢ㄦ埛涓婁紶浜嗘枃浠讹細${block.fileName}锛?{block.fileSize}B锛夈€俓n\n```$lang\n$safeContent\n```';
      } catch (e) {
        return '鐢ㄦ埛涓婁紶浜嗘枃浠讹細${block.fileName}锛屼絾璇诲彇澶辫触锛?e';
      }
    }
  }

  String _truncateForPrompt(String content) {
    const maxChars = 40000;
    if (content.length <= maxChars) return content;
    return '${content.substring(0, maxChars)}\n鈥?鍐呭杩囬暱锛屽凡鎴柇锛屼粎鍙戦€佸墠 $maxChars 瀛楃)';
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

  /// 鏆撮湶 prepareApiConfig 鐨勮繑鍥炵被鍨?
  Future<ApiConfig> getApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
  }) =>
      prepareApiConfig(
          conv: conv, history: history, userText: userText, trace: trace);

  /// 鎵ц API 璋冪敤锛堟敮鎸佷袱鍥炲悎/閫掑綊宸ュ叿璋冪敤锛?
  ///
  /// 娴佺▼锛?
  /// 1. 璋冪敤 AI API
  /// 2. 濡傛灉 AI 杩斿洖 tool_calls锛屾墽琛屽伐鍏峰苟鏀堕泦缁撴灉
  /// 3. 灏嗗伐鍏风粨鏋滆拷鍔犲埌娑堟伅鍒楄〃锛屽啀娆¤皟鐢?API
  /// 4. 閲嶅鐩村埌 AI 杩斿洖绾枃鏈垨杈惧埌鏈€澶у洖鍚堟暟
  ///
  /// [maxRounds] 鏈€澶у洖鍚堟暟锛岄槻姝㈡棤闄愬惊鐜紙榛樿 5锛?
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    TraceLogger? trace,
    int maxRounds = 5,
  }) async {
    final apiCallTrace = trace?.startChild('璋冪敤AI API');
    apiCallTrace?.note('杩炴帴', metadata: {
      'endpoint':
          config.providerApiBase.isNotEmpty ? config.providerApiBase : '鍚庣缃戝叧',
      'model': config.modelFullId,
      'history': config.messages.length,
      'maxRounds': maxRounds,
    });

    final agent = AgentApiClient();
    final pluginManager = _ref.read(pluginManagerProvider);
    final effectivePlugins =
        _getEffectivePlugins(pluginManager, config.enabledPluginIds);
    final allToolEvents = <PluginEvent>[];
    final allToolAudioResults = <ToolAudioResult>[]; // 鏀堕泦 speak 宸ュ叿浜х敓鐨勯煶棰?
    final allToolContents = <PluginContent>[]; // draw_image 工具生成的图片内容

    // 瑙ｆ瀽 provider 鐢ㄤ簬鑾峰彇閫傞厤鍣?
    String provider = 'openai';
    final idx = config.modelFullId.indexOf(':');
    if (idx > 0) {
      provider = config.modelFullId.substring(0, idx);
    }
    final adapter = ProviderAdapterFactory.getAdapter(provider);

    // 鍙彉鐨勬秷鎭垪琛紙姣忚疆鍙兘杩藉姞宸ュ叿缁撴灉锛?
    var currentMessages = List<Map<String, dynamic>>.from(config.messages);
    SendMessageRichResult? lastRich;

    for (var round = 1; round <= maxRounds; round++) {
      final roundTrace = apiCallTrace?.startChild('绗?round杞瓵PI璋冪敤');
      roundTrace?.note('璇锋眰', metadata: {
        'round': round,
        'messagesCount': currentMessages.length,
      });

      lastRich = await agent.sendMessageRich(
        agentId: 'default',
        sessionId: sessionId,
        modelFullId: config.modelFullId,
        messages: currentMessages,
        userText: round == 1 ? (userText ?? '') : '', // 鍙湪绗竴杞紶 userText
        temperature: config.effectiveTemperature,
        topP: config.modelTopP, // 妯″瀷绾у埆 Top P锛坣ull 鏃剁敱鏈嶅姟鍟嗛粯璁わ級
        token: config.settings.backendApiKey,
        toolPrefs: config.toolPrefs,
        providerApiBase: config.providerApiBase,
        providerApiKey: config.providerApiKey,
        customConfig: config.customConfig,
        tools: config.tools,
        trace: roundTrace,
      );

      roundTrace?.note('鍝嶅簲', metadata: {
        'textLength': lastRich.text.length,
        'toolCalls': lastRich.toolCalls.length,
      });

      // 濡傛灉娌℃湁宸ュ叿璋冪敤锛岀粨鏉熷惊鐜?
      if (!lastRich.hasToolCalls) {
        roundTrace?.end(additionalMessage: '鏃犲伐鍏疯皟鐢紝缁撴潫');
        break;
      }

      // 鎵ц宸ュ叿璋冪敤
      final toolTrace = roundTrace?.startChild('鎵ц宸ュ叿璋冪敤');
      toolTrace?.note('宸ュ叿', metadata: {
        'count': lastRich.toolCalls.length,
        'names': lastRich.toolCalls.map((t) => t.name).toList(),
      });

      final toolResults = <ToolResult>[];
      for (final tc in lastRich.toolCalls) {
        try {
          final tool = _findToolByName(effectivePlugins, tc.name);
          if (tool != null) {
            AppLogger.info('ChatSendService', '鎵ц宸ュ叿璋冪敤', metadata: {
              'round': round,
              'name': tc.name,
              'args': tc.arguments,
            });
            final result = await tool.handler(tc.arguments);
            final resultStr = result ?? '';
            AppLogger.info('ChatSendService', '宸ュ叿璋冪敤瀹屾垚', metadata: {
              'name': tc.name,
              'result': resultStr,
            });

            // 濡傛灉鏄?speak 宸ュ叿锛岃В鏋愯繑鍥炵殑 JSON 鏀堕泦闊抽
            if (tc.name == 'speak') {
              try {
                final parsed = jsonDecode(resultStr) as Map<String, dynamic>;
                final success = parsed['success'] == true;
                final audioUrl = parsed['audioUrl'] as String?;
                final text = parsed['text'] as String? ?? '';
                if (success && audioUrl != null && audioUrl.isNotEmpty) {
                  allToolAudioResults
                      .add(ToolAudioResult(audioUrl: audioUrl, text: text));
                  AppLogger.info('ChatSendService', '鏀堕泦鍒?speak 宸ュ叿闊抽',
                      metadata: {
                        'audioUrlLength': audioUrl.length,
                        'text': text,
                      });
                }
              } catch (e) {
                AppLogger.warning('ChatSendService', '瑙ｆ瀽 speak 缁撴灉澶辫触',
                    metadata: {'error': e.toString()});
              }

              // 銆愰噸瑕併€憇peak 宸ュ叿鏄?鍓綔鐢ㄥ伐鍏?锛孉I 涓嶉渶瑕佺湅鍒伴煶棰戞暟鎹?
              // 鍙繑鍥炴墽琛岀粨鏋滄憳瑕侊紝閬垮厤 base64 闊抽鏁版嵁姹℃煋涓婁笅鏂?
              // 鍙傝€冿細https://github.com/openai/codex/issues/6426 (tool output truncation)
              toolResults.add(ToolResult(
                toolCallId: tc.id,
                name: tc.name,
                result: '{"success": true, "message": "璇煶宸叉挱鏀剧粰鐢ㄦ埛"}',
              ));
            } else if (tc.name == 'draw_image') {
              final imageContents = _extractToolImageContents(resultStr);
              if (imageContents.isNotEmpty) {
                allToolContents.addAll(imageContents);
                AppLogger.info('ChatSendService', 'Collected draw_image tool images', metadata: {
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
          AppLogger.error('ChatSendService', '宸ュ叿璋冪敤澶辫触', metadata: {
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

      // 濡傛灉鏄渶鍚庝竴杞紝涓嶅啀杩藉姞娑堟伅
      if (round == maxRounds) {
        AppLogger.warning('ChatSendService', '杈惧埌鏈€澶у洖鍚堟暟',
            metadata: {'maxRounds': maxRounds});
        roundTrace?.end(additionalMessage: '杈惧埌鏈€澶у洖鍚堟暟');
        break;
      }

      // 鏋勫缓宸ュ叿缁撴灉娑堟伅锛岃拷鍔犲埌 currentMessages
      // 浠?rawResponse 鏋勫缓 assistant 娑堟伅
      final assistantMessage =
          _buildAssistantMessageFromRich(lastRich, provider);
      final toolResultMessages = adapter.buildToolResultMessages(
        assistantMessage: assistantMessage,
        toolResults: toolResults,
      );
      currentMessages = [...currentMessages, ...toolResultMessages];

      roundTrace?.note('杩藉姞宸ュ叿缁撴灉', metadata: {
        'newMessagesCount': toolResultMessages.length,
        'totalMessages': currentMessages.length,
      });
      roundTrace?.end(additionalMessage: '继续下一轮');
    }

    apiCallTrace?.note('瀹屾垚', metadata: {
      'textLength': lastRich?.text.length ?? 0,
      'toolResults': lastRich?.toolResults.length ?? 0,
    });
    apiCallTrace?.end(additionalMessage: 'API璋冪敤鎴愬姛');

    // 鎻掍欢澶勭悊锛堝鐞嗛檷绾фā寮忕殑鏍囩瑙ｆ瀽锛?
    final pluginTrace = trace?.startChild('杩愯鎻掍欢');
    final pluginResult = await _processResponseWithPlugins(
        effectivePlugins, lastRich?.text ?? '');

    pluginTrace?.note('鎻掍欢澶勭悊', metadata: {
      'original': lastRich?.text.length ?? 0,
      'processed': pluginResult.processedText.length,
      'events': pluginResult.events.length,
    });
    pluginTrace?.end();

    // 鍚堝苟宸ュ叿璋冪敤浜嬩欢鍜屾彃浠朵簨浠?
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

  /// 浠?API 鍝嶅簲鏋勫缓 assistant 娑堟伅锛堢敤浜庡伐鍏疯皟鐢ㄧ殑娑堟伅杩藉姞锛?
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
    // 鏍规嵁 provider 绫诲瀷鏋勫缓涓嶅悓鏍煎紡
    switch (provider) {
      case 'claude':
      case 'anthropic':
        // Anthropic 鏍煎紡锛氳繑鍥炲師濮?content 鏁扮粍
        return rich.rawResponse ?? {'content': []};
      case 'gemini':
      case 'google':
        // Gemini 鏍煎紡锛氳繑鍥?candidates[0].content
        final candidates = (rich.rawResponse?['candidates'] as List?) ?? [];
        if (candidates.isNotEmpty) {
          final first = candidates.first as Map<String, dynamic>;
          return {'content': first['content']};
        }
        return {
          'content': {'parts': []}
        };
      default:
        // OpenAI 鏍煎紡锛氳繑鍥?choices[0].message
        final choices = (rich.rawResponse?['choices'] as List?) ?? [];
        if (choices.isNotEmpty) {
          final first = choices.first as Map<String, dynamic>;
          return first['message'] as Map<String, dynamic>? ?? {};
        }
        return {};
    }
  }

  /// 鏋勫缓鍔╂墜娑堟伅
  ///
  /// 杩斿洖 AssistantMessageBuildResult锛屽寘鍚秷鎭垪琛ㄥ拰 TTS 鍗犱綅娑堟伅 ID
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    // 璺緞A锛氬鏋滄湁宸ュ叿璋冪敤浜х敓鐨勯煶棰戯紙speak 宸ュ叿锛夛紝鐩存帴杩斿洖闊抽娑堟伅
    // 涓嶅啀璧拌矾寰凚锛?tts>鏍囩瑙ｆ瀽锛?
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
      // 濡傛灉 AI 杩樻湁鏂囨湰鍥炲锛屼篃涓€骞惰繑鍥烇紙涓嶅垎娈碉紝淇濇寔瀹屾暣瀛樺偍锛?
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

    // 璺緞B锛氭病鏈夊伐鍏烽煶棰戯紝璧版甯哥殑娑堟伅澶勭悊娴佺▼锛堝彲鑳藉惈 <tts> 鏍囩锛?
    // 娉ㄦ剰锛氬垎娈甸€昏緫宸茬Щ鑷?UI 灞傦紝杩欓噷淇濇寔娑堟伅瀹屾暣瀛樺偍
    return chatMessageProcessor.buildAssistantMessages(
      replyText: apiResult.replyText,
      processedText: apiResult.processedText,
      pluginEvents: apiResult.pluginEvents,
      contents: apiResult.pluginContents,
    );
  }

  /// 浜や粯鍔╂墜娑堟伅鍒板璇?
  Future<void> deliverAssistantMessages({
    required String convId,
    required String userMsgId,
    required List<Message> messages,
    required String lastMessagePreview,
    TraceLogger? trace,
  }) async {
    final forwardTrace = trace?.startChild('向用户转发消息');
    forwardTrace?.info('娑堟伅鍒嗘瀹屾垚', metadata: {
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

    forwardTrace?.info('娑堟伅宸茶浆鍙戝埌鐢ㄦ埛', metadata: {
      'messagesCount': messages.length,
      'hasAudio':
          messages.any((m) => m.blocks?.any((b) => b is AudioBlock) ?? false),
    });
    forwardTrace?.end(additionalMessage: '杞彂鎴愬姛');
  }

  /// 鏍囪鐢ㄦ埛娑堟伅鍙戦€佸け璐?
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

  /// 璇诲彇鍥剧墖涓?Base64
  Future<String?> readImageAsBase64(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      AppLogger.error('ChatSendService', '璇诲彇鍥剧墖澶辫触: $e');
      return null;
    }
  }

  /// 鍑嗗鍘嗗彶娑堟伅
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

  /// 鏋勫缓宸ュ叿鍋忓ソ閰嶇疆
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

  /// 鑾峰彇 MCP 閰嶇疆
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

/// API 閰嶇疆绫?
class ApiConfig {
  final AppSettings settings;
  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic> customConfig;
  final Map<String, dynamic> toolPrefs;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>>? tools; // 鍘熺敓 Tool Calling 宸ュ叿瀹氫箟
  final Set<String>? enabledPluginIds; // 瑙掕壊绾ф彃浠剁櫧鍚嶅崟锛坣ull=鍏ㄩ儴锛?
  /// 妯″瀷绾у埆娓╁害鍙傛暟锛堜紭鍏堜簬鍏ㄥ眬璁剧疆锛?
  final double? modelTemperature;

  /// 妯″瀷绾у埆 Top P 鍙傛暟
  final double? modelTopP;

  /// 妯″瀷绾у埆涓婁笅鏂囨秷鎭暟闄愬埗
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

  /// 鑾峰彇瀹為檯浣跨敤鐨勬俯搴﹀弬鏁?
  /// 浼樺厛绾э細妯″瀷璁剧疆 > 鍏ㄥ眬璁剧疆
  double get effectiveTemperature => modelTemperature ?? settings.temperature;
}

/// Provider
final chatSendServiceProvider = Provider((ref) => ChatSendService(ref));

