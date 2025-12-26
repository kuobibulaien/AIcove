import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/conversation.dart';
import 'domain/message.dart';
import 'id_gen.dart';
import 'data/context_analyzer.dart';
import 'data/auto_reply_trigger.dart';
import '../settings/direct_mode.dart' as direct;
import '../tts/data/tts_api.dart';
import '../tts/tts_player.dart';
import '../settings/app_settings.dart';
import '../settings/mcp_api.dart';
import '../plugins/plugin_providers.dart';
import '../plugins/domain/plugin.dart';
import '../plugins/tts/tts_player_manager.dart';
import '../../core/api/agent_api.dart';
import '../../core/models/message_block.dart';
import '../../core/models/block_status.dart';
import '../../core/app_logger.dart';
import '../../core/utils/message_formatter.dart';
import '../../core/database/database_provider.dart';
import '../../core/database/converters/database_converters.dart';
import 'presentation/widgets/momotalk_sort_dialog.dart' show SortMode;
import 'conversation_providers.dart';

final sendingProvider = StateProvider<bool>((ref) => false);
final errorProvider = StateProvider<String?>((ref) => null);

class ChatActions {
  ChatActions(this._ref)
      : _ttsManager = _ref.read(ttsPlayerManagerProvider) {
    _setupTtsProcessedListener();
  }
  final Ref _ref;
  // 固定使用同一个 TTS 管理器实例，避免 provider 重建导致监听与投递使用不同实例
  final TtsPlayerManager _ttsManager;
  final McpApi _mcpApi = McpApi();
  McpConfigDto? _cachedMcpConfig;
  DateTime? _cachedMcpFetchedAt;
  static const Duration _ttsTimeout = Duration(seconds: 30);
  final Map<String, _PendingTtsAudio> _pendingTtsEvents = {};
  StreamSubscription<TtsPlayItem>? _ttsProcessedSubscription;
  
  // 触发器分析延迟定时器（5分钟无消息后触发）
  Timer? _analyzerDelayTimer;
  
  // 后台切换防抖相关
  Timer? _bgAnalyzerTimer;
  int _bgSwitchCount = 0;
  DateTime? _bgSwitchWindowStart;
  DateTime? _bgProcessingPausedUntil;

  // 统一的事件日志，使用 AppLogger
  void _evt(String name, Map<String, Object?> data, {String level = 'INFO'}) {
    final source = 'ChatActions';
    final message = name;
    final metadata = <String, dynamic>{};

    // 将数据添加到元数据中
    data.forEach((k, v) {
      if (v != null) {
        if (v is String && v.length > 200) {
          metadata[k] = '${v.substring(0, 200)}…';
        } else {
          metadata[k] = v;
        }
      }
    });

    // 根据级别记录日志
    switch (level.toUpperCase()) {
      case 'DBUG':
      case 'DEBUG':
        AppLogger.debug(source, message, metadata: metadata);
        break;
      case 'INFO':
        AppLogger.info(source, message, metadata: metadata);
        break;
      case 'WARN':
      case 'WARNING':
        AppLogger.warning(source, message, metadata: metadata);
        break;
      case 'ERRO':
      case 'ERROR':
        AppLogger.error(source, message, metadata: metadata);
        break;
      case 'CRIT':
      case 'CRITICAL':
        AppLogger.critical(source, message, metadata: metadata);
        break;
      default:
        AppLogger.info(source, message, metadata: metadata);
    }
  }

  /// 启动/重置触发器分析延迟定时器
  /// 每次用户发消息时调用，5分钟无新消息后才触发分析
  void _scheduleAnalyzer() {
    // 取消之前的定时器
    _analyzerDelayTimer?.cancel();
    _bgAnalyzerTimer?.cancel(); // 用户活跃时取消后台快速触发
    
    // 创建新的5分钟延迟定时器
    _analyzerDelayTimer = Timer(const Duration(minutes: 5), () {
      try {
        final conv = _ref.read(activeConversationProvider);
        if (conv != null && conv.messages.isNotEmpty) {
          _evt('analyzer:triggered', {
            'reason': '5分钟无新消息',
            'messagesCount': conv.messages.length,
          }, level: 'INFO');
          _ref.read(contextAnalyzerProvider).analyzeAndSchedule(conv);
        }
      } catch (e) {
        _evt('analyzer:error', {'error': e.toString()}, level: 'ERRO');
      }
    });
    
    _evt('analyzer:scheduled', {'delayMinutes': 5}, level: 'DBUG');
  }

  /// 应用切后台时调用，确保分析器定时器正在运行
  void onAppBackground() {
    final now = DateTime.now();

    // 1. 检查是否处于冷却期
    if (_bgProcessingPausedUntil != null) {
      if (now.isBefore(_bgProcessingPausedUntil!)) {
        _evt('analyzer:background_skipped', {
          'reason': 'cooldown_active', 
          'until': _bgProcessingPausedUntil.toString()
        }, level: 'WARN');
        return;
      } else {
        _bgProcessingPausedUntil = null;
        _bgSwitchCount = 0;
        _bgSwitchWindowStart = null;
      }
    }

    // 2. 更新计数窗口 (5分钟窗口)
    if (_bgSwitchWindowStart == null || now.difference(_bgSwitchWindowStart!).inMinutes >= 5) {
      _bgSwitchWindowStart = now;
      _bgSwitchCount = 1;
    } else {
      _bgSwitchCount++;
    }

    // 3. 检查是否触发冷却 (5分钟内超过3次)
    if (_bgSwitchCount > 3) {
      _bgProcessingPausedUntil = now.add(const Duration(minutes: 10));
      _evt('analyzer:background_cooldown', {
        'reason': 'too_frequent', 
        'count': _bgSwitchCount, 
        'pauseMinutes': 10
      }, level: 'WARN');
      return;
    }

    // 4. 调度快速分析 (10秒后，给用户一点撤回机会)
    // 取消常规的5分钟定时器，改用快速定时器
    _analyzerDelayTimer?.cancel();
    _bgAnalyzerTimer?.cancel();

    _bgAnalyzerTimer = Timer(const Duration(seconds: 10), () {
      try {
        final conv = _ref.read(activeConversationProvider);
        if (conv != null && conv.messages.isNotEmpty) {
           _evt('analyzer:triggered', {
            'reason': 'app_background',
            'messagesCount': conv.messages.length,
          }, level: 'INFO');
          _ref.read(contextAnalyzerProvider).analyzeAndSchedule(conv);
        }
      } catch (e) {
        _evt('analyzer:error', {'error': e.toString()}, level: 'ERRO');
      }
    });
    
    _evt('analyzer:scheduled_fast', {'delaySeconds': 10}, level: 'DBUG');

    // 5. 同步云端心跳 (Fire and forget)
    // 即使分析失败，也应该告诉云端我们下线了
    Future(() async {
      try {
        final settings = await _ref.read(appSettingsProvider.future);
        if (settings.backendApiKey.isNotEmpty) {
           final agent = AgentApiClient(); // 使用默认 client
           await agent.syncTriggerHeartbeat(now, token: settings.backendApiKey);
           _evt('cloud:heartbeat_sent', {'timestamp': now.toIso8601String()}, level: 'DBUG');
        }
      } catch (e) {
         _evt('cloud:heartbeat_failed', {'error': e.toString()}, level: 'WARN');
      }
    });
  }

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

  Future<void> send(String text) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || text.trim().isEmpty) return;
    final convId = conv.id;

    // ?? 创建主追踪：完整的消息发送流程
    final trace = AppLogger.startTrace('AI消息发送', source: 'ChatActions');
    trace.note('用户输入', metadata: {
      'conversationId': convId,
      'messageLength': text.length,
    });

    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    final now = DateTime.now();
    final userMsg = Message(
      id: genId('msg'),
      role: 'user',
      content: text,
      createdAt: now,
      status: 'sending', // 标记为发送中
    );
    await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
            messages: [...c.messages, userMsg],
            updatedAt: now,
            lastMessage: text,
            lastMessageTime: now,
          ),
        );

    // 用于在 TTS 完成前暂存“语音生成中”占位消息的 ID
    String? ttsPlaceholderId;

    try {
      // 子追踪1: 准备配置
      final configTrace = trace.startChild('加载配置');
      final settings = await _ref.read(appSettingsProvider.future);
      final mcpConfig = await _getMcpConfig();
      final toolPrefs = _buildToolPrefs(settings, mcpConfig);
      configTrace.note('配置', metadata: {
        'ttsEnabled': settings.ttsEnabled,
        'autoTools': toolPrefs['auto_tools_enabled'] == true,
        'enabledToolsCount': (toolPrefs['mcp_enabled_tools'] as List?)?.length ?? 0,
      });
      configTrace.end();

      // 子追踪2: 准备历史消息
      final historyTrace = trace.startChild('准备历史消息');
      // 仅保留最近N 条历史
      final all = [...conv.messages, userMsg];
      final lim = settings.historyMessageLimit;
      final history = (lim <= 0 || all.length <= lim)
          ? all
          : all.sublist(all.length - lim);
      historyTrace.note('历史消息', metadata: {
        'total': all.length,
        'limit': lim,
        'used': history.length,
      });
      historyTrace.end();

      // 子追踪3: 准备API调用
      final apiPrepareTrace = trace.startChild('准备API调用');
      final model = settings.defaultModelName;
      final provider = settings.modelProviderMap[model] ?? 'openai';
      apiPrepareTrace.note('API参数', metadata: {
        'provider': provider,
        'model': model,
      });

      // 统一网关调用
      final agent = AgentApiClient();
      var modelFull = '$provider:$model';
      apiPrepareTrace.end();

      // 从后端同步的渠道列表里找出当前渠道的配置，用于传递给后台（KISS：只取必需字段）
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
      // 从直连配置覆盖（若启用）
      try {
        final cfg = await direct.loadDirectConfig();
        if (cfg.enabled) {
          // 只有当当前没有有效配置时才用直连配置进行兜底（避免覆盖你已导入的提供商配置）
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

      final reqMessages = history.map((m) => m.toHistoryJson()).toList();

      // 构建系统提示词（包含插件提示词）
      final systemParts = <String>[];

      // 1. 对话角色提示词
      if (conv.personaPrompt.isNotEmpty) {
        systemParts.add(conv.personaPrompt);
      }

      // 2. 用户称呼
      if (conv.addressUser != null && conv.addressUser!.isNotEmpty) {
        systemParts.add('你应该称呼用户为"${conv.addressUser}"。');
      }

      // 3. 插件提示词（如 TTS）
      final pluginManager = _ref.read(pluginManagerProvider);
      final pluginPrompts = await pluginManager.getSystemPrompts(userMessage: text);
      if (pluginPrompts.isNotEmpty) {
        systemParts.add(pluginPrompts);
        AppLogger.debug('ChatActions', '添加插件提示词', metadata: {
          'pluginCount': pluginManager.getEnabledPlugins().length,
          'promptsLength': pluginPrompts.length,
        });
      }

      // 4. 插入系统消息
      if (systemParts.isNotEmpty) {
        reqMessages.insert(0, {
          'role': 'system',
          'content': systemParts.join('\n\n'),
        });
      }

      // 子追踪4: API调用
      final apiCallTrace = trace.startChild('调用AI API');
      apiCallTrace.note('连接', metadata: {
        'endpoint': providerApiBase.isNotEmpty ? providerApiBase : '后端网关',
        'model': modelFull,
        'history': reqMessages.length,
      });
      
      final rich = await agent.sendMessageRich(
        agentId: 'default',
        sessionId: convId,
        modelFullId: modelFull,
        messages: reqMessages,
        userText: text,
        temperature: settings.temperature,
        token: settings.backendApiKey,
        toolPrefs: toolPrefs,
        providerApiBase: providerApiBase,
        providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
        customConfig: providerAuth.customConfig,
        trace: apiCallTrace, // 传递追踪日志器，共享 traceId
      );
      final replyText = rich.text;
      final toolResults = rich.toolResults;
      
      apiCallTrace.note('响应', metadata: {
        'textLength': replyText.length,
        'toolResults': toolResults.length,
      });
      apiCallTrace.end(additionalMessage: 'API调用成功');

      // 子追踪5: 插件处理
      final pluginTrace = trace.startChild('运行插件');
      // 步骤 5.1: 通过插件管理器处理响应文本
      final pluginResult = await pluginManager.processResponse(replyText);
      final processedText = pluginResult.processedText;
      final pluginEvents = pluginResult.events;
      
      pluginTrace.note('插件处理', metadata: {
        'original': replyText.length,
        'processed': processedText.length,
        'events': pluginEvents.length,
      });

      pluginTrace.end();

      // 处理后端TTS结果（兼容性）
      Message? audioMsg;
      if (settings.ttsEnabled && toolResults.isNotEmpty) {
        try {
          final first = toolResults.firstWhere(
            (e) => (e['name'] ?? '') == 'tts' && ((e['payload'] as Map<String, dynamic>?)?['audio_url']?.toString().isNotEmpty ?? false),
            orElse: () => const {'name': '', 'payload': <String, dynamic>{}},
          );
          if ((first['name'] ?? '') == 'tts') {
            final url = ((first['payload'] as Map<String, dynamic>)['audio_url'] as String?)?.trim();
            if (url != null && url.isNotEmpty) {
              final audioId = genId('msg');
              audioMsg = Message.fromBlocks(
                id: audioId,
                role: 'assistant',
                blocks: [AudioBlock(messageId: audioId, url: url, text: replyText)],
                createdAt: DateTime.now(),
                status: 'sent',
              );
            }
          }
        } catch (_) {}
      }

      // 构建文本消息（用于回退）
      final messageConfig = settings.messageFormatConfig;
      final assistantMessages = _buildAssistantMessages(
        replyText: replyText,
        processedText: processedText,
        pluginEvents: pluginEvents,
        messageConfig: messageConfig,
      );
      final fallbackMessages = [
        ...assistantMessages.messages,
        if (audioMsg != null) audioMsg,
      ];
      final delivery = await _prepareAssistantDelivery(
        convId: convId,
        fallbackMessages: fallbackMessages,
        replyText: replyText,
        pluginEvents: pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      ttsPlaceholderId = delivery.placeholderId;

      final aiMsgTime = DateTime.now();

      // 子追踪6: 转发消息
      final forwardTrace = trace.startChild('向用户转发消息');
      forwardTrace.info('消息分段完成', metadata: {
        'chunksCount': delivery.messages.length,
        'firstChunk': delivery.messages.isNotEmpty
            ? delivery.messages.first.displayText
            : '',
      });

      await _ref.read(conversationsProvider.notifier).updateOne(
            convId,
            (c) {
              final updatedMessages = c.messages.map((m) {
                if (m.id == userMsg.id) {
                  return m.copyWith(status: 'sent');
                }
                return m;
              }).toList();
              return c.copyWith(
                messages: [
                  ...updatedMessages,
                  ...delivery.messages,
                ],
                updatedAt: aiMsgTime,
                lastMessage: delivery.lastMessagePreview,
                lastMessageTime: aiMsgTime,
              );
            },
          );
      
       forwardTrace.info('消息已转发到用户', metadata: {
        'messagesCount': delivery.messages.length,
        'hasAudio': delivery.messages.any((m) => m.blocks?.any((b) => b is AudioBlock) ?? false),
      });
      forwardTrace.end(additionalMessage: '转发成功');
      
      trace.end(additionalMessage: '所有步骤完成');
      ttsPlaceholderId = null;
    } catch (e) {
      if (ttsPlaceholderId != null) {
        await _removePlaceholderMessage(convId, ttsPlaceholderId);
      }
      trace.error('消息发送失败', metadata: {
        'convId': convId,
        'error': e.toString(),
      });
      trace.end(additionalMessage: '发送失败');

      await _ref.read(conversationsProvider.notifier).updateOne(
            convId,
            (c) {
              final updatedMessages = c.messages.map((m) {
                if (m.id == userMsg.id) {
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
      _ref.read(errorProvider.notifier).state =
          e is Exception ? e.toString() : '发送失败';
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
      // 触发上下文分析（延迟执行，避免阻塞 UI）
      Future.delayed(const Duration(seconds: 2), () {
        try {
          final conv = _ref.read(activeConversationProvider);
          if (conv != null && conv.messages.isNotEmpty) {
            _ref.read(contextAnalyzerProvider).analyzeAndSchedule(conv);
          }
        } catch (_) {}
      });
    }
  }

  /// 发送一条仅包含图片的消息（从相册选择）
  /// KISS/YAGNI：最小实现，复用现有 send 流程的核心步骤，避免重复造轮子
  Future<void> sendWithImage(String imagePath) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || imagePath.trim().isEmpty) return;
    final convId = conv.id;

    _evt('send:image:start', {
      'convId': convId,
      'pathLen': imagePath.length,
    }, level: 'INFO');

    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    final now = DateTime.now();

    // 将本地图片转为 base64，便于通过 toHistoryJson 注入到后端
    String? base64Image;
    try {
      final bytes = await File(imagePath).readAsBytes();
      base64Image = base64Encode(bytes);
      _evt('send:image:encoded', {
        'pathLen': imagePath.length,
        'sizeBytes': bytes.length,
        'base64Len': base64Image.length,
      }, level: 'DBUG');
    } catch (e) {
      _evt('send:image:encode_failed', {
        'path': imagePath,
        'error': e.toString(),
      }, level: 'WARN');
      // 编码失败时仍然以本地预览方式展示，但可能后端无法访问
      base64Image = null;
    }

    final msgId = genId('msg');
    final userMsg = Message.fromBlocks(
      id: msgId,
      role: 'user',
      blocks: [
        if (base64Image != null)
          ImageBlock(messageId: msgId, base64: base64Image)
        else
          ImageBlock(messageId: msgId, localPath: imagePath),
      ],
      createdAt: now,
      status: 'sending',
    );

    // 先将图片消息加入会话（本地可见）
    await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
            messages: [...c.messages, userMsg],
            updatedAt: now,
            lastMessage: '[图片]',
            lastMessageTime: now,
          ),
        );

    // TTS 占位消息 ID（如有）
    String? placeholderId;

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final mcpConfig = await _getMcpConfig();
      final toolPrefs = _buildToolPrefs(settings, mcpConfig);

      // 构建历史（包含当前图片消息）
      final all = [...conv.messages, userMsg];
      final lim = settings.historyMessageLimit;
      final history = (lim <= 0 || all.length <= lim) ? all : all.sublist(all.length - lim);
      var reqMessages = history.map((m) => m.toHistoryJson()).toList();

      // 拼接系统提示词
      final systemParts = <String>[];
      if (conv.personaPrompt.isNotEmpty) systemParts.add(conv.personaPrompt);
      if (conv.addressUser != null && conv.addressUser!.isNotEmpty) {
        systemParts.add('你应该称呼用户为"${conv.addressUser}"。');
      }
      final pluginManager = _ref.read(pluginManagerProvider);
      final pluginPrompts = await pluginManager.getSystemPrompts();
      if (pluginPrompts.isNotEmpty) systemParts.add(pluginPrompts);
      if (systemParts.isNotEmpty) {
        reqMessages.insert(0, {
          'role': 'system',
          'content': systemParts.join('\n\n'),
        });
      }

      // 后端准备参数（与 send 保持一致）
      final agent = AgentApiClient();
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

      // 直连兜底
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

      _evt('backend:request', {
        'endpoint': '/v1/messages | /api/chat',
        'sessionId': convId,
        'modelFull': modelFull,
      }, level: 'INFO');

      final rich = await agent.sendMessageRich(
        agentId: 'default',
        sessionId: convId,
        modelFullId: modelFull,
        messages: reqMessages,
        userText: '[image]',
        temperature: settings.temperature,
        token: settings.backendApiKey,
        toolPrefs: toolPrefs,
        providerApiBase: providerApiBase,
        providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      );

      final replyText = rich.text;
      final toolResults = rich.toolResults;

      // 插件处理 + TTS 事件
      final pluginResult = await pluginManager.processResponse(replyText);
      final processedText = pluginResult.processedText;
      final pluginEvents = pluginResult.events;
      // 兼容：后端返回的 TTS 结果（audio_url）
      Message? audioMsg;
      if (settings.ttsEnabled && toolResults.isNotEmpty) {
        try {
          final first = toolResults.firstWhere(
            (e) => (e['name'] ?? '') == 'tts' && ((e['payload'] as Map<String, dynamic>?)?['audio_url']?.toString().isNotEmpty ?? false),
            orElse: () => const {'name': '', 'payload': <String, dynamic>{}},
          );
          if ((first['name'] ?? '') == 'tts') {
            final url = ((first['payload'] as Map<String, dynamic>)['audio_url'] as String?)?.trim();
            if (url != null && url.isNotEmpty) {
              final audioId = genId('msg');
              audioMsg = Message.fromBlocks(
                id: audioId,
                role: 'assistant',
                blocks: [AudioBlock(messageId: audioId, url: url, text: replyText)],
                createdAt: DateTime.now(),
                status: 'sent',
              );
            }
          }
        } catch (_) {}
      }

      // 文本分段（用于回退）
      final messageConfig = settings.messageFormatConfig;
      final assistantMessages = _buildAssistantMessages(
        replyText: replyText,
        processedText: processedText,
        pluginEvents: pluginEvents,
        messageConfig: messageConfig,
      );
      final fallbackMessages = [
        ...assistantMessages.messages,
        if (audioMsg != null) audioMsg,
      ];

      final delivery = await _prepareAssistantDelivery(
        convId: convId,
        fallbackMessages: fallbackMessages,
        replyText: replyText,
        pluginEvents: pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      placeholderId = delivery.placeholderId;

      final aiMsgTime = DateTime.now();

      await _ref.read(conversationsProvider.notifier).updateOne(
            convId,
            (c) {
              var updated = c.messages.map((m) {
                if (m.id == userMsg.id) return m.copyWith(status: 'sent');
                return m;
              }).toList();
              if (placeholderId != null) {
                updated =
                    updated.where((m) => m.id != placeholderId).toList();
              }
              return c.copyWith(
                messages: [
                  ...updated,
                  ...delivery.messages,
                ],
                updatedAt: aiMsgTime,
                lastMessage: delivery.lastMessagePreview,
                lastMessageTime: aiMsgTime,
              );
            },
          );
      placeholderId = null;
    } catch (e) {
      if (placeholderId != null) {
        await _removePlaceholderMessage(convId, placeholderId);
      }
      _evt('send:image:error', {'convId': convId, 'error': e.toString()}, level: 'ERRO');
      await _ref.read(conversationsProvider.notifier).updateOne(
            convId,
            (c) {
              final updated = c.messages.map((m) {
                if (m.id == userMsg.id) return m.copyWith(status: 'failed');
                return m;
              }).toList();
              return c.copyWith(messages: updated, updatedAt: DateTime.now());
            },
          );
      _ref.read(errorProvider.notifier).state =
          e is Exception ? e.toString() : '发送失败';
    } finally {
      _evt('send:image:finish', {'convId': convId}, level: 'INFO');
      _ref.read(sendingProvider.notifier).state = false;
      // 启动/重置5分钟延迟定时器
      _scheduleAnalyzer();
    }
  }


  Future<void> sendProactiveTrigger(AutoReplyTrigger trigger) async {
    Conversation? conv;
    if (trigger.contactId != null) {
      final conversations = _ref.read(conversationsProvider).valueOrNull ?? [];
      try {
        conv = conversations.firstWhere((c) => c.id == trigger.contactId);
      } catch (_) {}
    }
    if (conv == null) {
      conv = _ref.read(activeConversationProvider);
    }
    
    if (conv == null) return;
    final convId = conv.id;
    _evt('trigger:start', {'trigger': trigger.title, 'contactId': convId}, level: 'INFO');

    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    String? placeholderId;

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final mcpConfig = await _getMcpConfig();
      final toolPrefs = _buildToolPrefs(settings, mcpConfig);

      final history = conv.messages;
      final lim = settings.historyMessageLimit;
      final effectiveHistory = (lim <= 0 || history.length <= lim)
          ? history
          : history.sublist(history.length - lim);
      
      final reqMessages = effectiveHistory.map((m) => m.toHistoryJson()).toList();

      final systemParts = <String>[];
      
      // 触发器指令（关键）
      final triggerPrompt = trigger.prompt?.isNotEmpty == true
          ? trigger.prompt!
          : 'A scheduled trigger "${trigger.title}" has fired. You must now initiate a conversation with the user based on this context. Do not mention that this is a trigger. Be natural.';
          
      systemParts.add('SYSTEM EVENT: $triggerPrompt');

      if (conv.personaPrompt.isNotEmpty) systemParts.add(conv.personaPrompt);
      if (conv.addressUser != null && conv.addressUser!.isNotEmpty) {
        systemParts.add('You should address the user as "${conv.addressUser}".');
      }
      final pluginManager = _ref.read(pluginManagerProvider);
      final pluginPrompts = await pluginManager.getSystemPrompts();
      if (pluginPrompts.isNotEmpty) systemParts.add(pluginPrompts);

      if (systemParts.isNotEmpty) {
        reqMessages.insert(0, {
          'role': 'system',
          'content': systemParts.join('\n\n'),
        });
      }

      final agent = AgentApiClient();
      final model = settings.defaultModelName;
      final provider = settings.modelProviderMap[model] ?? 'openai';
      var modelFull = '$provider:$model';

      final providerAuth = settings.providers.firstWhere(
        (p) => p.id == provider,
        orElse: () => ProviderAuth(
            id: provider, apiKeys: [], apiBaseUrl: settings.apiBaseUrl),
      );
      var providerApiBase = providerAuth.apiBaseUrl.trim().isEmpty ? settings.apiBaseUrl : providerAuth.apiBaseUrl.trim();
      var providerApiKey = providerAuth.apiKeys.isNotEmpty ? providerAuth.apiKeys.first.trim() : null;

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

      // 发送请求（userText为空，完全依赖System Prompt和历史）
      final rich = await agent.sendMessageRich(
        agentId: 'default',
        sessionId: convId,
        modelFullId: modelFull,
        messages: reqMessages,
        userText: '', 
        temperature: settings.temperature,
        token: settings.backendApiKey,
        toolPrefs: toolPrefs,
        providerApiBase: providerApiBase,
        providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      );
      
      final replyText = rich.text;
      final toolResults = rich.toolResults;

      final pluginResult = await pluginManager.processResponse(replyText);
      final processedText = pluginResult.processedText;
      final pluginEvents = pluginResult.events;

      Message? audioMsg;
      if (settings.ttsEnabled && toolResults.isNotEmpty) {
         try {
          final first = toolResults.firstWhere(
            (e) => (e['name'] ?? '') == 'tts' && ((e['payload'] as Map<String, dynamic>?)?['audio_url']?.toString().isNotEmpty ?? false),
            orElse: () => const {'name': '', 'payload': <String, dynamic>{}},
          );
          if ((first['name'] ?? '') == 'tts') {
            final url = ((first['payload'] as Map<String, dynamic>)['audio_url'] as String?)?.trim();
            if (url != null && url.isNotEmpty) {
              final audioId = genId('msg');
              audioMsg = Message.fromBlocks(
                id: audioId,
                role: 'assistant',
                blocks: [AudioBlock(messageId: audioId, url: url, text: replyText)],
                createdAt: DateTime.now(),
                status: 'sent',
              );
            }
          }
        } catch (_) {}
      }

      final messageConfig = settings.messageFormatConfig;
      final assistantMessages = _buildAssistantMessages(
        replyText: replyText,
        processedText: processedText,
        pluginEvents: pluginEvents,
        messageConfig: messageConfig,
      );
       final fallbackMessages = [
        ...assistantMessages.messages,
        if (audioMsg != null) audioMsg,
      ];

      final delivery = await _prepareAssistantDelivery(
        convId: convId,
        fallbackMessages: fallbackMessages,
        replyText: replyText,
        pluginEvents: pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      placeholderId = delivery.placeholderId;

       final aiMsgTime = DateTime.now();
      
       await _ref.read(conversationsProvider.notifier).updateOne(
            convId,
            (c) {
              return c.copyWith(
                messages: [
                  ...c.messages,
                  ...delivery.messages,
                ],
                updatedAt: aiMsgTime,
                lastMessage: delivery.lastMessagePreview,
                lastMessageTime: aiMsgTime,
              );
            },
          );
       placeholderId = null;

    } catch (e) {
        if (placeholderId != null) {
        await _removePlaceholderMessage(convId, placeholderId);
      }
      _evt('trigger:error', {'error': e.toString()}, level: 'ERRO');
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
    }
  }

  /// 重新发送失败的消息
  Future<void> retry(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;
    _evt('retry:start', {'convId': convId, 'messageId': messageId}, level: 'INFO');

    // 找到失败的消息
    final failedMsg = conv.messages.firstWhere(
      (m) => m.id == messageId && m.status == 'failed',
      orElse: () => throw Exception('消息不存在或未失败'),
    );
    
    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;
    
    // 更新消息状态为sending
    await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) {
            final updatedMessages = c.messages.map((m) {
              if (m.id == messageId) {
                return m.copyWith(status: 'sending');
              }
              return m;
            }).toList();
            return c.copyWith(
              messages: updatedMessages,
              updatedAt: DateTime.now(),
            );
          },
        );

    // 重发时可能创建的 TTS 占位消息 ID
    String? placeholderId;
    
    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final mcpConfig = await _getMcpConfig();
      final toolPrefs = _buildToolPrefs(settings, mcpConfig);
      _evt('retry:toolPrefs', {
        'ttsEnabled': settings.ttsEnabled,
        'autoTools': toolPrefs['auto_tools_enabled'] == true,
      }, level: 'DBUG');

      // 构建历史消息（排除当前重发的消息）
      final historyMsgs = conv.messages.where((m) => m.id != messageId).toList();
      final lim = settings.historyMessageLimit;
      final history = (lim <= 0 || historyMsgs.length <= lim)
          ? historyMsgs
          : historyMsgs.sublist(historyMsgs.length - lim);
      _evt('retry:historyPrepared', {
        'total': historyMsgs.length,
        'limit': lim,
        'used': history.length,
      }, level: 'DBUG');

      final agent = AgentApiClient();
      final model = settings.defaultModelName;
      final provider = settings.modelProviderMap[model] ?? 'openai';
      var modelFull = '$provider:$model';
      _evt('backend:prepare', {
        'provider': provider,
        'model': model,
        'modelFull': modelFull,
      }, level: 'DBUG');

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

      final reqMessages = history.map((m) => m.toHistoryJson()).toList();

      // 构建系统提示词（包含插件提示词）
      final systemParts = <String>[];

      // 1. 对话角色提示词
      if (conv.personaPrompt.isNotEmpty) {
        systemParts.add(conv.personaPrompt);
      }

      // 2. 用户称呼
      if (conv.addressUser != null && conv.addressUser!.isNotEmpty) {
        systemParts.add('你应该称呼用户为"${conv.addressUser}"。');
      }

      // 3. 插件提示词（如 TTS）
      final pluginManager = _ref.read(pluginManagerProvider);
      final pluginPrompts = await pluginManager.getSystemPrompts();
      if (pluginPrompts.isNotEmpty) {
        systemParts.add(pluginPrompts);
        AppLogger.debug('ChatActions', '添加插件提示词', metadata: {
          'pluginCount': pluginManager.getEnabledPlugins().length,
          'promptsLength': pluginPrompts.length,
        });
      }

      // 4. 插入系统消息
      if (systemParts.isNotEmpty) {
        reqMessages.insert(0, {
          'role': 'system',
          'content': systemParts.join('\n\n'),
        });
      }

      _evt('backend:request', {
        'endpoint': '/v1/messages | /api/chat',
        'sessionId': convId,
        'modelFull': modelFull,
      }, level: 'INFO');
      final rich = await agent.sendMessageRich(
        agentId: 'default',
        sessionId: convId,
        modelFullId: modelFull,
        messages: reqMessages,
        userText: failedMsg.content,
        temperature: settings.temperature,
        token: settings.backendApiKey,
        toolPrefs: toolPrefs,
        providerApiBase: providerApiBase,
        providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      );
      final replyText = rich.text;
      final toolResults = rich.toolResults;
      _evt('backend:response', {
        'textLen': replyText.length,
        'textHead': replyText.substring(0, replyText.length > 60 ? 60 : replyText.length),
        'toolResults': toolResults.length,
      }, level: 'INFO');

      // 通过插件管理器处理响应文本
      final pluginResult = await pluginManager.processResponse(replyText);
      final processedText = pluginResult.processedText;
      final pluginEvents = pluginResult.events;

      // 不自动播放：如有 TTS 结果，构造语音气泡消息（兼容性）
      Message? audioMsg;
      if (settings.ttsEnabled && toolResults.isNotEmpty) {
        try {
          final first = toolResults.firstWhere(
            (e) => (e['name'] ?? '') == 'tts' && ((e['payload'] as Map<String, dynamic>?)?['audio_url']?.toString().isNotEmpty ?? false),
            orElse: () => const {'name': '', 'payload': <String, dynamic>{}},
          );

          if ((first['name'] ?? '') == 'tts') {
            final url = ((first['payload'] as Map<String, dynamic>)['audio_url'] as String?)?.trim();

            if (url != null && url.isNotEmpty) {
              final audioId = genId('msg');
              audioMsg = Message.fromBlocks(
                id: audioId,
                role: 'assistant',
                blocks: [AudioBlock(messageId: audioId, url: url, text: replyText)],
                createdAt: DateTime.now(),
                status: 'sent',
              );
              _evt('tools:tts', {'audioUrl': url, 'audioMsgId': audioId}, level: 'INFO');
            }
          }
        } catch (e) {
          print('Error creating audio message: $e');
        }
      }

      // 应用消息格式化（用于回退）
      final messageConfig = settings.messageFormatConfig;
      final assistantMessages = _buildAssistantMessages(
        replyText: replyText,
        processedText: processedText,
        pluginEvents: pluginEvents,
        messageConfig: messageConfig,
      );
      final fallbackMessages = [
        ...assistantMessages.messages,
        if (audioMsg != null) audioMsg,
      ];

      String? placeholderId;
      final delivery = await _prepareAssistantDelivery(
        convId: convId,
        fallbackMessages: fallbackMessages,
        replyText: replyText,
        pluginEvents: pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      placeholderId = delivery.placeholderId;

      final aiMsgTime = DateTime.now();
      _evt('messages:update', {
        'convId': convId,
        'chunksCount': delivery.messages.length,
        'hasAudioMsg': delivery.messages.any((m) => m.blocks?.any((b) => b is AudioBlock) ?? false),
      }, level: 'INFO');

      // 更新用户消息为sent，并添加AI回复
      await _ref.read(conversationsProvider.notifier).updateOne(
            convId,
            (c) {
              var updatedMessages = c.messages.map((m) {
                if (m.id == messageId) {
                  return m.copyWith(status: 'sent');
                }
                return m;
              }).toList();
              if (placeholderId != null) {
                updatedMessages =
                    updatedMessages.where((m) => m.id != placeholderId).toList();
              }
              return c.copyWith(
                messages: [
                  ...updatedMessages,
                  ...delivery.messages,
                ],
                updatedAt: aiMsgTime,
                lastMessage: delivery.lastMessagePreview,
                lastMessageTime: aiMsgTime,
              );
            },
          );
      placeholderId = null;
    } catch (e) {
      if (placeholderId != null) {
        await _removePlaceholderMessage(convId, placeholderId);
      }
      _evt('retry:error', {'convId': convId, 'messageId': messageId, 'error': e.toString()}, level: 'ERRO');
      // 重发失败，恢复为failed状态
      await _ref.read(conversationsProvider.notifier).updateOne(
            convId,
            (c) {
              final updatedMessages = c.messages.map((m) {
                if (m.id == messageId) {
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
      _ref.read(errorProvider.notifier).state =
          e is Exception ? e.toString() : '重发失败';
  } finally {
      _evt('retry:finish', {'convId': convId, 'messageId': messageId}, level: 'INFO');
      _ref.read(sendingProvider.notifier).state = false;
    }
  }

  void _setupTtsProcessedListener() {
    _ttsProcessedSubscription = _ttsManager.processedStream.listen((item) {
      unawaited(_handleTtsProcessed(item));
    });
    _ref.onDispose(() {
      _ttsProcessedSubscription?.cancel();
    });
  }

  Future<void> _handleTtsProcessed(TtsPlayItem item) async {
    _evt('tts:processed', {
      'eventId': item.id,
      'hasUrl': (item.audioUrl?.isNotEmpty ?? false),
      'status': item.status.toString(),
      'error': item.error,
    }, level: 'INFO');

    final pending = _pendingTtsEvents.remove(item.event.id);
    if (pending == null) return;

    if (pending.completer.isCompleted) {
      return;
    }

    final audioUrl = item.audioUrl;
    if (audioUrl == null || audioUrl.isEmpty) {
      pending.completer.complete(const _TtsAudioResult.failure('empty_url'));
      return;
    }

    final text = pending.originalText?.isNotEmpty == true
        ? pending.originalText!
        : ((item.event.data['originalText'] as String?)?.trim() ??
            (item.event.data['text'] as String?)?.trim() ??
            '');

    // 就地替换占位语音条：把占位消息中的 AudioBlock 填入 url，状态置为 success
    try {
      await _ref.read(conversationsProvider.notifier).updateOne(
        pending.convId,
        (c) {
          final updated = c.messages.map((m) {
            if (m.id != pending.placeholderId) return m;
            // 用新的 AudioBlock 覆盖
            final audioBlock = AudioBlock(
              messageId: m.id,
              url: audioUrl,
              text: text.isNotEmpty ? text : null,
              status: BlockStatus.success,
            );
            return Message.fromBlocks(
              id: m.id,
              role: m.role,
              blocks: [audioBlock],
              createdAt: m.createdAt,
              status: 'sent',
            );
          }).toList();
          return c.copyWith(
            messages: updated,
            updatedAt: DateTime.now(),
            lastMessage: '[语音]',
            lastMessageTime: DateTime.now(),
          );
        },
      );
    } catch (_) {}

    pending.completer.complete(const _TtsAudioResult.success(null));
  }

  Future<List<_TtsAudioResult>> _registerAndWaitForTtsEvents(
    String convId,
    List<PluginEvent> events,
    {
      required String placeholderId,
    }
  ) {
    final futures = <Future<_TtsAudioResult>>[];
    for (final event in events) {
      final original = (event.data['originalText'] as String?)?.trim();
      final fallback = (event.data['text'] as String?)?.trim();
      final completer = Completer<_TtsAudioResult>();
      _pendingTtsEvents[event.id] = _PendingTtsAudio(
        convId: convId,
        placeholderId: placeholderId,
        originalText: original?.isNotEmpty == true ? original : fallback,
        completer: completer,
      );

      // 超时保护：若 _ttsTimeout 内仍未完成，自动失败，移除占位
      Future.delayed(_ttsTimeout, () async {
        final p = _pendingTtsEvents.remove(event.id);
        if (p != null && !p.completer.isCompleted) {
          _evt('tts:timeout', {
            'eventId': event.id,
            'convId': convId,
          }, level: 'WARN');
          p.completer.complete(const _TtsAudioResult.failure('timeout'));
          try {
            await _removePlaceholderMessage(convId, placeholderId);
          } catch (_) {}
        }
      });

      futures.add(completer.future);
    }
    if (futures.isEmpty) {
      return Future.value(const []);
    }
    return Future.wait(futures);
  }

  Future<void> _cancelPendingTtsEvents(
    Iterable<PluginEvent> events, {
    bool stopPlayer = false,
  }) async {
    for (final event in events) {
      final pending = _pendingTtsEvents.remove(event.id);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer
            .complete(const _TtsAudioResult.failure('cancelled'));
      }
    }
    if (stopPlayer) {
      final manager = _ref.read(ttsPlayerManagerProvider);
      await manager.stop();
      manager.clearQueue();
    }
  }

  Future<_AssistantDeliveryResult> _prepareAssistantDelivery({
    required String convId,
    required List<Message> fallbackMessages,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool ttsEnabled,
  }) async {
    final fallbackPreview =
        fallbackMessages.isNotEmpty ? fallbackMessages.last.displayText : replyText;

    if (!ttsEnabled) {
      return _AssistantDeliveryResult(
        messages: fallbackMessages,
        lastMessagePreview: fallbackPreview,
      );
    }

    final hasAudioInFallback = fallbackMessages.any(
      (m) => m.blocks?.any((b) => b is AudioBlock) ?? false,
    );
    if (hasAudioInFallback) {
      return _AssistantDeliveryResult(
        messages: fallbackMessages,
        lastMessagePreview: fallbackPreview,
      );
    }

    // 关闭直连兜底：任何时候都不调用 /api/tts，统一走插件事件占位与就地替换流程
    return _prepareAssistantDeliveryWithPending(
      convId: convId,
      fallbackMessages: fallbackMessages,
      replyText: replyText,
      pluginEvents: pluginEvents,
      fallbackPreview: fallbackPreview,
    );

    return _prepareAssistantDeliveryWithPending(
      convId: convId,
      fallbackMessages: fallbackMessages,
      replyText: replyText,
      pluginEvents: pluginEvents,
      fallbackPreview: fallbackPreview,
    );
  }

  Future<_AssistantDeliveryResult> _prepareAssistantDeliveryWithPending({
    required String convId,
    required List<Message> fallbackMessages,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required String fallbackPreview,
  }) async {
    final ttsEvents =
        pluginEvents.where((e) => e.type == 'tts_convert').toList();
    if (ttsEvents.isEmpty) {
      return _AssistantDeliveryResult(
        messages: fallbackMessages,
        lastMessagePreview: fallbackPreview,
      );
    }

    // 使用语音条占位：先插入一个待加载的音频Block，等待后台TTS完成后替换为可播放语音
    final placeholderId = genId('msg');
    final placeholder = Message.fromBlocks(
      id: placeholderId,
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: placeholderId,
          url: '', // 占位：未就绪，UI 显示加载态
          text: _collectTtsTexts(replyText, pluginEvents).join('\n\n').trim().isNotEmpty
              ? _collectTtsTexts(replyText, pluginEvents).join('\n\n').trim()
              : null,
          status: BlockStatus.pending,
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sending',
    );

    await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
            messages: [...c.messages, placeholder],
            updatedAt: DateTime.now(),
            lastMessage: '[语音]',
            lastMessageTime: DateTime.now(),
          ),
        );

    // 绑定占位ID并开始后台处理；完成后在 _handleTtsProcessed 中“就地替换”占位条
    unawaited(_registerAndWaitForTtsEvents(
      convId,
      ttsEvents,
      placeholderId: placeholder.id,
    ));
    await _ttsManager.addEvents(ttsEvents);

    // 立即返回：不追加文本消息，占位语音条已经插入

    return _AssistantDeliveryResult(
      messages: fallbackMessages,
      lastMessagePreview: fallbackPreview,
      placeholderId: placeholder.id,
    );
  }

  Future<void> _removePlaceholderMessage(String convId, String placeholderId) async {
    await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
            messages: [
              for (final m in c.messages)
                if (m.id != placeholderId) m,
            ],
          ),
        );
  }

  _AssistantMessageBuildResult _buildAssistantMessages({
    required String replyText,
    required String processedText,
    required List<PluginEvent> pluginEvents,
    required MessageFormatConfig messageConfig,
  }) {
    var sourceText = _selectAssistantText(processedText, pluginEvents, replyText);
    
    // 如果文本为空但有 trigger 事件，生成确认消息
    if (sourceText.isEmpty) {
      final triggerEvents = pluginEvents.where((e) => e.type == 'trigger_created').toList();
      if (triggerEvents.isNotEmpty) {
        // 从 trigger 事件中提取信息生成确认消息
        final titles = triggerEvents.map((e) => e.data['title'] as String?).where((t) => t != null).toList();
        if (titles.isNotEmpty) {
          sourceText = '好的，已设置提醒：${titles.join("、")} ✓';
        }
      }
    }
    
    if (sourceText.isEmpty) {
      return const _AssistantMessageBuildResult(messages: [], lastMessageText: '');
    }

    final chunks = MessageFormatter.formatAndChunkText(sourceText, messageConfig);
    final texts = chunks.isEmpty ? [sourceText] : chunks;
    final aiMessages = texts
        .map((chunk) => Message(
              id: genId('msg'),
              role: 'assistant',
              content: chunk,
              createdAt: DateTime.now(),
              status: 'sent',
            ))
        .toList();

    // 处理表情包事件（来自 StickerPlugin 解析的 [标签]）
    final stickerEvents = pluginEvents.where((e) => e.type == 'sticker_convert').toList();
    for (final event in stickerEvents) {
      final stickerId = event.data['stickerId'] as String?;
      final assetPath = event.data['assetPath'] as String?;
      final tag = event.data['tag'] as String?;
      
      if (assetPath != null && assetPath.isNotEmpty) {
        final stickerMsg = Message.fromBlocks(
          id: genId('sticker'),
          role: 'assistant',
          blocks: [
            EmojiBlock(
              messageId: genId('emoji'),
              emojiId: stickerId ?? tag ?? 'unknown',
              path: assetPath,
              matchedTag: tag,
            ),
          ],
          createdAt: DateTime.now(),
          status: 'sent',
        );
        aiMessages.add(stickerMsg);
      }
    }

    return _AssistantMessageBuildResult(
      messages: aiMessages,
      lastMessageText: texts.last,
    );
  }

  String _selectAssistantText(
    String processedText,
    List<PluginEvent> pluginEvents,
    String replyText,
  ) {
    final trimmedProcessed = processedText.trim();
    if (trimmedProcessed.isNotEmpty) {
      return trimmedProcessed;
    }

    // 如果检测到 TTS 事件，说明这轮回复应以语音为主，避免渲染文本气泡
    final hasTts = pluginEvents.any((e) => e.type == 'tts_convert');
    if (hasTts) {
      return '';
    }

    // 使用更完整的标签移除函数，确保所有插件标签都被移除
    final stripped = _stripPluginTags(replyText);
    return stripped;
  }

  /// 移除所有插件标签（TTS、Trigger 等）
  String _stripPluginTags(String text) {
    if (text.isEmpty) return text;
    var result = text;
    
    // 移除 <tts>...</tts> 标签
    final ttsRegex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
    final ttsMatches = ttsRegex.allMatches(result).map((m) => m.group(1)?.trim()).where((v) => v != null && v.isNotEmpty).toList();
    result = result.replaceAll(ttsRegex, '');
    
    // 移除 <create_trigger ... /> 标签
    result = result.replaceAll(RegExp(r'<create_trigger\s[^>]*?/?>', caseSensitive: false), '');
    
    // 移除 <delete_trigger ... /> 标签
    result = result.replaceAll(RegExp(r'<delete_trigger\s[^>]*?/?>', caseSensitive: false), '');
    
    result = result.trim();
    
    // 如果移除标签后为空，但有 TTS 内容，返回 TTS 内容
    if (result.isEmpty && ttsMatches.isNotEmpty) {
      return ttsMatches.cast<String>().join('\n\n');
    }
    
    return result;
  }

  String _stripTtsTags(String text) {
    if (text.isEmpty) return text;
    final regex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
    final matches = regex
        .allMatches(text)
        .map((m) => m.group(1)?.trim())
        .where((value) => value != null && value!.isNotEmpty)
        .toList();
    final withoutTags = text.replaceAll(regex, '').trim();
    if (withoutTags.isNotEmpty) {
      return withoutTags;
    }
    if (matches.isNotEmpty) {
      return matches.join('\n\n');
    }
    return '';
  }

  List<String> _collectTtsTexts(String replyText, List<PluginEvent> pluginEvents) {
    final segments = <String>[];
    for (final event in pluginEvents) {
      if (event.type != 'tts_convert') continue;
      final original = (event.data['originalText'] as String?)?.trim();
      final fallback = (event.data['text'] as String?)?.trim();
      final text = original?.isNotEmpty == true ? original : fallback;
      if (text != null && text.isNotEmpty) {
        segments.add(text);
      }
    }

    if (segments.isEmpty) {
      final regex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
      for (final match in regex.allMatches(replyText)) {
        final value = match.group(1)?.trim();
        if (value != null && value.isNotEmpty) {
          segments.add(value);
        }
      }
    }

    return segments;
  }

  Future<Message?> _synthesizeTtsDirect(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final api = _ref.read(ttsApiProvider);
    final resp = await api.synthesize(text: trimmed);
    final url = resp.audioUrl.trim();
    if (url.isEmpty) {
      return null;
    }

    final audioId = genId('msg');
    return Message.fromBlocks(
      id: audioId,
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: audioId,
          url: url,
          text: trimmed,
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sent',
    );
  }
}

final chatActionsProvider = Provider((ref) => ChatActions(ref));

final sidebarVisibleProvider = StateProvider<bool>((ref) => true);

class _PendingTtsAudio {
  final String convId;
  final String placeholderId;
  final String? originalText;
  final Completer<_TtsAudioResult> completer;

  _PendingTtsAudio({
    required this.convId,
    required this.placeholderId,
    this.originalText,
    required this.completer,
  });
}

class _TtsAudioResult {
  final Message? message;
  final bool success;
  final String? error;

  const _TtsAudioResult.success(this.message)
      : success = true,
        error = null;

  const _TtsAudioResult.failure([this.error])
      : success = false,
        message = null;
}

class _AssistantDeliveryResult {
  final List<Message> messages;
  final String lastMessagePreview;
  final String? placeholderId;

  const _AssistantDeliveryResult({
    required this.messages,
    required this.lastMessagePreview,
    this.placeholderId,
  });
}

class _AssistantMessageBuildResult {
  final List<Message> messages;
  final String lastMessageText;

  const _AssistantMessageBuildResult({
    required this.messages,
    required this.lastMessageText,
  });
}

// ===== 联系人列表排序状态 =====
// 遵循 DRY 原则：将排序状态提升到 Provider，供 ContactsPage 和 SplitChatPage 共享
// 更新记录：
// - 2025-12-06: 从 ContactsPage/SplitChatPage 提取，消除状态重复

/// 排序模式 Provider
final sortModeProvider = StateProvider<SortMode>((ref) => SortMode.latest);

/// 升序/降序 Provider
final sortAscendingProvider = StateProvider<bool>((ref) => false);
