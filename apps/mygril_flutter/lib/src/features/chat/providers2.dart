import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain/conversation.dart';
import 'domain/message.dart';
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

String _genId(String prefix) => '${prefix}_${DateTime.now().millisecondsSinceEpoch}';

final ttsApiProvider = Provider((ref) => TtsApi());

final ttsPlayerUsecaseProvider = Provider((ref) {
  final player = ref.watch(ttsPlayerProvider);
  return (String url) => player.playUrl(url);
});

class ConversationsNotifier extends AsyncNotifier<List<Conversation>> {
  static const _storageKey = 'mygril.conversations';

  @override
  Future<List<Conversation>> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      final conv = _createConversation();
      await _save([conv]);
      return [conv];
    }
    try {
      final arr = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return arr.map(_fromJson).toList();
    } catch (_) {
      final conv = _createConversation();
      await _save([conv]);
      return [conv];
    }
  }

  Conversation _createConversation() {
    final now = DateTime.now();
    final examples = [
      {'name': 'Arona', 'org': '联邦学生会', 'char': 'assets/characters/Arona.webp'},
      {'name': 'Aru', 'org': '便利屋68', 'char': 'assets/characters/Aru.webp'},
      {'name': 'Hoshino', 'org': '对策委员会', 'char': 'assets/characters/Hoshino.webp'},
      {'name': 'Shiroko', 'org': '对策委员会', 'char': 'assets/characters/Shiroko.webp'},
      {'name': 'Hina', 'org': '风纪委员会', 'char': 'assets/characters/Hina.webp'},
    ];
    final random = (now.millisecondsSinceEpoch % examples.length);
    final example = examples[random];

    return Conversation(
      id: _genId('conv'),
      title: example['name']!,
      displayName: example['name']!,
      organization: example['org'],
      characterImage: example['char'],
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
  }

  Map<String, dynamic> _toJson(Conversation c) => {
        'id': c.id,
        'title': c.title,
        'displayName': c.displayName,
        'avatarUrl': c.avatarUrl,
        'characterImage': c.characterImage,
        'organization': c.organization,
        'addressUser': c.addressUser,
        'personaPrompt': c.personaPrompt,
        'createdAt': c.createdAt.toIso8601String(),
        'updatedAt': c.updatedAt.toIso8601String(),
        'defaultProvider': c.defaultProvider,
        'sessionProvider': c.sessionProvider,
        'isPinned': c.isPinned,
        'isMuted': c.isMuted,
        'notificationSound': c.notificationSound,
        'lastMessage': c.lastMessage,
        'lastMessageTime': c.lastMessageTime?.toIso8601String(),
        'unreadCount': c.unreadCount,
        'messages': c.messages
            .map((m) => {
                  'id': m.id,
                  'role': m.role,
                  'content': m.content,
                  'createdAt': m.createdAt.toIso8601String(),
                  'status': m.status, // 保存消息状态
                  'blocks': m.blocks?.map((b) => b.toJson()).toList(), // 保存多模态blocks
                })
            .toList(),
      };

  Conversation _fromJson(Map<String, dynamic> m) {
    List<Message> msgs = [];
    if (m['messages'] is List) {
      msgs = (m['messages'] as List)
          .cast<Map<String, dynamic>>()
          .map((x) {
                // 解析blocks（如果存在）
                List<MessageBlock>? blocks;
                if (x['blocks'] is List) {
                  try {
                    blocks = (x['blocks'] as List)
                        .cast<Map<String, dynamic>>()
                        .map((b) => MessageBlock.fromJson(b))
                        .toList();
                  } catch (e) {
                    // 解析失败时忽略，使用content字段作为fallback
                    blocks = null;
                  }
                }

                return Message(
                  id: x['id'] as String,
                  role: x['role'] as String,
                  content: x['content'] as String,
                  blocks: blocks, // 加载多模态blocks
                  createdAt:
                      DateTime.tryParse(x['createdAt'] as String? ?? '') ?? DateTime.now(),
                  status: x['status'] as String?, // 读取消息状态（向后兼容）
                );
              })
          .toList();
    }
    return Conversation(
      id: m['id'] as String,
      title: m['title'] as String,
      displayName: (m['displayName'] as String?) ?? (m['title'] as String),
      avatarUrl: m['avatarUrl'] as String?,
      characterImage: m['characterImage'] as String?,
      organization: m['organization'] as String?,
      addressUser: m['addressUser'] as String?,
      personaPrompt: (m['personaPrompt'] as String?) ?? '',
      messages: msgs,
      createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(m['updatedAt'] as String? ?? '') ?? DateTime.now(),
      defaultProvider: m['defaultProvider'] as String?,
      sessionProvider: m['sessionProvider'] as String?,
      isPinned: (m['isPinned'] as bool?) ?? false,
      isMuted: (m['isMuted'] as bool?) ?? false,
      notificationSound: (m['notificationSound'] as bool?) ?? true,
      lastMessage: m['lastMessage'] as String?,
      lastMessageTime: m['lastMessageTime'] != null
          ? DateTime.tryParse(m['lastMessageTime'] as String)
          : null,
      unreadCount: (m['unreadCount'] as int?) ?? 0,
    );
  }

  Future<void> _save(List<Conversation> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(list.map(_toJson).toList()),
    );
  }

  Future<void> setAll(List<Conversation> list) async {
    state = AsyncValue.data(list);
    await _save(list);
  }

  Future<void> updateOne(String id, Conversation Function(Conversation) fn) async {
    final current = state.value ?? <Conversation>[];
    final next = [for (final c in current) if (c.id == id) fn(c) else c];
    await setAll(next);
  }

  Future<String> createNew() async {
    final list = <Conversation>[...(state.value ?? <Conversation>[])];
    final c = _createConversation();
    list.insert(0, c);
    await setAll(list);
    return c.id;
  }

  // 应用联系人编辑
  Future<void> applyContactEdit(
    String id, {
    String? displayName,
    String? avatarUrl,
    String? characterImage,
    String? organization,
    String? addressUser,
    String? personaPrompt,
  }) async {
    await updateOne(id, (c) => c.copyWith(
      displayName: displayName ?? c.displayName,
      avatarUrl: avatarUrl ?? c.avatarUrl,
      characterImage: characterImage ?? c.characterImage,
      organization: organization ?? c.organization,
      addressUser: addressUser ?? c.addressUser,
      personaPrompt: personaPrompt ?? c.personaPrompt,
      updatedAt: DateTime.now(),
    ));
  }

  // 更新对话设置
  Future<void> updateConversationSettings(
    String id, {
    bool? isPinned,
    bool? isMuted,
    bool? notificationSound,
  }) async {
    await updateOne(id, (c) => c.copyWith(
      isPinned: isPinned ?? c.isPinned,
      isMuted: isMuted ?? c.isMuted,
      notificationSound: notificationSound ?? c.notificationSound,
      updatedAt: DateTime.now(),
    ));
  }

  // 清空消息
  Future<void> clearMessages(String id) async {
    await updateOne(id, (c) => Conversation(
      id: c.id,
      title: c.title,
      displayName: c.displayName,
      avatarUrl: c.avatarUrl,
      characterImage: c.characterImage,
      organization: c.organization,
      addressUser: c.addressUser,
      personaPrompt: c.personaPrompt,
      messages: const [],
      createdAt: c.createdAt,
      updatedAt: DateTime.now(),
      defaultProvider: c.defaultProvider,
      sessionProvider: c.sessionProvider,
      isPinned: c.isPinned,
      isMuted: c.isMuted,
      notificationSound: c.notificationSound,
      lastMessage: null,
      lastMessageTime: null,
      unreadCount: 0,
    ));
  }

  // 删除对话
  Future<void> deleteConversation(String id) async {
    final current = state.value ?? <Conversation>[];
    final next = current.where((c) => c.id != id).toList();
    await setAll(next);
  }
}

final conversationsProvider =
    AsyncNotifierProvider<ConversationsNotifier, List<Conversation>>(
  ConversationsNotifier.new,
);

final activeConversationIdProvider = StateProvider<String?>((ref) => null);

final activeConversationProvider = Provider<Conversation?>((ref) {
  final id = ref.watch(activeConversationIdProvider);
  final listAsync = ref.watch(conversationsProvider);
  return listAsync.maybeWhen(
    data: (list) {
      if (list.isEmpty) return null;
      if (id == null) return list.first;
      for (final c in list) {
        if (c.id == id) return c;
      }
      return list.first;
    },
    orElse: () => null,
  );
});

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
    _scheduleAnalyzer();
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
      id: _genId('msg'),
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
              final audioId = _genId('msg');
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

    final msgId = _genId('msg');
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
              final audioId = _genId('msg');
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
              final audioId = _genId('msg');
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
              final audioId = _genId('msg');
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
    final placeholderId = _genId('msg');
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
    final sourceText = _selectAssistantText(processedText, pluginEvents, replyText);
    if (sourceText.isEmpty) {
      return const _AssistantMessageBuildResult(messages: [], lastMessageText: '');
    }

    final chunks = MessageFormatter.formatAndChunkText(sourceText, messageConfig);
    final texts = chunks.isEmpty ? [sourceText] : chunks;
    final aiMessages = texts
        .map((chunk) => Message(
              id: _genId('msg'),
              role: 'assistant',
              content: chunk,
              createdAt: DateTime.now(),
              status: 'sent',
            ))
        .toList();

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

    final stripped = _stripTtsTags(replyText);
    if (stripped.isNotEmpty) {
      return stripped;
    }

    return replyText.trim();
  }

  String _stripTtsTags(String text) {
    if (text.isEmpty) return text;
    final regex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
    final matches = regex
        .allMatches(text)
        .map((m) => m.group(1)?.trim())
        .where((value) => value != null && value!.isNotEmpty)
        .cast<String>()
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

    final audioId = _genId('msg');
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