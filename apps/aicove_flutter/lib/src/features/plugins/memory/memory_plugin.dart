import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../background_agent/background_agent_service.dart';
import '../../chat/domain/message.dart' as chat;
import '../../chat/providers2.dart';
import '../../chat/services/chat_history_store.dart';
import '../../memory/services/memory_service.dart';
import '../../memory/utils/lexical_tokenizer_zh.dart';
import '../../settings/app_settings.dart';
import '../domain/index.dart';
import 'memory_config.dart';

String buildMemorySearchQuery(
  List<chat.Message> messages, {
  required String currentUserMessage,
  int historyLimit = 2,
  int maxChars = 200,
}) {
  final normalizedCurrent = currentUserMessage.trim();
  final recent = messages
      .map((m) => m.displayText.trim())
      .where((c) => c.isNotEmpty)
      .toList();
  final historyWindow = recent.length > historyLimit
      ? recent.sublist(recent.length - historyLimit)
      : List<String>.from(recent);

  if (normalizedCurrent.isNotEmpty) {
    final alreadyIncluded =
        historyWindow.isNotEmpty && historyWindow.last == normalizedCurrent;
    if (!alreadyIncluded) {
      historyWindow.add(normalizedCurrent);
    }
  }

  final joined = historyWindow.join('\n').trim();
  if (joined.isEmpty) return normalizedCurrent;
  return joined.length > maxChars
      ? joined.substring(joined.length - maxChars)
      : joined;
}

class MemoryPlugin extends BasePlugin {
  static const _metadata = PluginMetadata(
    id: 'memory',
    name: '长期记忆',
    description: '允许AI记住用户的长期喜好和重要信息',
    version: '2.0.0',
    author: 'AIcove Team',
    icon: Icons.memory,
    configSchema: {
      'enabled': ConfigField(
        type: ConfigFieldType.boolean,
        label: '启用插件',
        defaultValue: false,
      ),
      'roundSplitThreshold': ConfigField(
        type: ConfigFieldType.integer,
        label: '分轮阈值',
        description: '当日用户消息超过该数值时按 1 小时间隔拆分轮次',
        defaultValue: 20,
      ),
      'summarizeProviderId': ConfigField(
        type: ConfigFieldType.string,
        label: '总结模型提供商',
      ),
      'summarizeModelName': ConfigField(
        type: ConfigFieldType.string,
        label: '总结模型名称',
      ),
      'embeddingProviderId': ConfigField(
        type: ConfigFieldType.string,
        label: 'Embedding 提供商',
      ),
      'embeddingModelName': ConfigField(
        type: ConfigFieldType.string,
        label: 'Embedding 模型',
      ),
    },
  );

  MemoryConfig _memoryConfig;
  MemoryService? _service;
  final Ref _ref;
  final Map<String, List<String>> _lastRetrievedByConversation = {};

  MemoryPlugin(this._memoryConfig, this._ref) : super(metadata: _metadata) {
    _initService();
  }

  void _initService() {
    final appSettings = _ref.read(appSettingsProvider).valueOrNull;
    if (appSettings == null) {
      _service = null;
      return;
    }
    final memoryRepository = _ref.read(memoryRepositoryProvider);
    final messageRepository = _ref.read(messageRepositoryProvider);
    final serviceConfig = _resolveConfig(appSettings);
    _service = MemoryService(
      serviceConfig,
      memoryRepository,
      messageRepository,
      backgroundAgentService: _ref.read(backgroundAgentServiceProvider),
      conversationRepository: _ref.read(conversationRepositoryProvider),
      diaryRepository: _ref.read(diaryRepositoryProvider),
    );
  }

  MemoryServiceConfig _resolveConfig(AppSettings settings) {
    return MemoryServiceConfig(
      enabled: _memoryConfig.enabled,
      summarizePrompt: _memoryConfig.summarizePrompt,
      summarizeModelRef: _buildModelRef(
        _memoryConfig.summarizeProviderId,
        _memoryConfig.summarizeModelName,
      ),
      summarizeModel: _resolveModel(settings, _memoryConfig.summarizeProviderId,
          _memoryConfig.summarizeModelName),
      embeddingModel: _resolveModel(settings, _memoryConfig.embeddingProviderId,
          _memoryConfig.embeddingModelName),
      fallbackEmbeddingModel: _resolveModel(
        settings,
        _memoryConfig.fallbackEmbeddingProviderId,
        _memoryConfig.fallbackEmbeddingModelName,
      ),
      fallbackEnabled: _memoryConfig.fallbackEmbeddingEnabled,
      roundSplitThreshold: _memoryConfig.roundSplitThreshold,
      enableCategoryClassification: _memoryConfig.enableCategoryClassification,
      enableHybridSearch: _memoryConfig.enableHybridSearch,
      enableProfileLayer: _memoryConfig.enableProfileLayer,
      enableNextDayTrigger: _memoryConfig.enableNextDayTrigger,
      enableMemoryMerge: _memoryConfig.enableMemoryMerge,
      enableCapacityCompress: _memoryConfig.enableCapacityCompress,
      enablePreFlush: _memoryConfig.enablePreFlush,
      localMaxMemories: _memoryConfig.localMaxMemories,
    );
  }

  ResolvedModelConfig? _resolveModel(
      AppSettings settings, String? providerId, String? modelName) {
    if (providerId == null ||
        providerId.isEmpty ||
        modelName == null ||
        modelName.isEmpty) {
      return null;
    }
    final provider = settings.providers.firstWhere(
      (p) => p.id == providerId && p.enabled,
      orElse: () => const ProviderAuth(id: '', apiKeys: [], apiBaseUrl: ''),
    );
    if (provider.id.isEmpty || provider.apiKeys.isEmpty) return null;
    return ResolvedModelConfig(
      apiKey: provider.apiKeys.first,
      baseUrl: provider.apiBaseUrl,
      model: modelName,
    );
  }

  String? _buildModelRef(String? providerId, String? modelName) {
    final normalizedProviderId = providerId?.trim() ?? '';
    final normalizedModelName = modelName?.trim() ?? '';
    if (normalizedProviderId.isEmpty || normalizedModelName.isEmpty) {
      return null;
    }
    return '$normalizedProviderId:$normalizedModelName';
  }

  @override
  bool get enabled => _memoryConfig.enabled;

  @override
  Future<void> onConfigChanged(Map<String, dynamic> newConfig) async {
    _memoryConfig = MemoryConfig.fromJson(newConfig);
    _initService();
  }

  @override
  Map<String, dynamic> getConfig() => _memoryConfig.toJson();

  @override
  void updateConfig(Map<String, dynamic> config) {
    _memoryConfig = MemoryConfig.fromJson(config);
    _initService();
  }

  @override
  Future<String?> getSystemPrompt(
      {String? userMessage,
      bool supportsToolCalling = false,
      String? conversationId}) async {
    final service = _service;
    if (!enabled ||
        service == null ||
        userMessage == null ||
        userMessage.trim().isEmpty) {
      return null;
    }

    final resolvedConversationId = _resolveConversationId(conversationId);
    if (resolvedConversationId == null) return null;

    // next-day summary trigger on user message (fire-and-forget)
    if (_memoryConfig.enableNextDayTrigger) {
      Future(() async {
        try {
          await service.checkAndTriggerDailySummarization(
            conversationId: resolvedConversationId,
          );
        } catch (e) {
          AppLogger.warning(
              'MemoryPlugin', 'Daily summarization trigger failed',
              metadata: {
                'conversationId': resolvedConversationId,
                'error': e.toString(),
              });
        }
      });
    }

    final recentMessages =
        await _ref.read(chatHistoryStoreProvider).loadRecentMessages(
              resolvedConversationId,
              limit: 3,
            );
    final query = buildMemorySearchQuery(
      recentMessages,
      currentUserMessage: userMessage,
    );
    final isFiller = LexicalTokenizerZh.looksLikeFillerUtterance(userMessage);

    List<String> related = [];
    if (isFiller) {
      related =
          _lastRetrievedByConversation[resolvedConversationId] ?? const [];
    }

    if (!isFiller || related.isEmpty) {
      try {
        related = await service.searchFormatted(
          conversationId: resolvedConversationId,
          query: query,
        );
        _lastRetrievedByConversation[resolvedConversationId] = related;
      } catch (e) {
        AppLogger.warning('MemoryPlugin', 'Memory retrieval failed', metadata: {
          'conversationId': resolvedConversationId,
          'error': e.toString(),
        });
      }
    }

    final profilePrompt = _memoryConfig.enableProfileLayer
        ? await service.getProfilePrompt(resolvedConversationId)
        : '';
    if (profilePrompt.trim().isEmpty && related.isEmpty) return null;

    final parts = <String>[];
    if (profilePrompt.trim().isNotEmpty) {
      parts.add(profilePrompt.trim());
    }
    if (related.isNotEmpty) {
      final buffer = StringBuffer()
        ..writeln('## 相关记忆')
        ..writeln('以下是与当前对话相关的历史记忆：');
      for (final m in related) {
        buffer.writeln('- $m');
      }
      parts.add(buffer.toString().trim());
    }
    return parts.join('\n\n');
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    return PluginProcessResult(processedText: text, events: const []);
  }

  void triggerPreFlush({
    String? conversationId,
    required List<chat.Message> droppedMessages,
  }) {
    final service = _service;
    if (!enabled ||
        service == null ||
        !_memoryConfig.enablePreFlush ||
        droppedMessages.isEmpty) {
      return;
    }
    final resolvedConversationId = _resolveConversationId(conversationId);
    if (resolvedConversationId == null) return;
    Future(() async {
      try {
        await service.runPreFlush(
          conversationId: resolvedConversationId,
          messagesLikelyToLose: droppedMessages,
        );
      } catch (e) {
        AppLogger.warning('MemoryPlugin', 'Pre-flush failed', metadata: {
          'conversationId': resolvedConversationId,
          'error': e.toString(),
        });
      }
    });
  }

  String? _resolveConversationId(String? conversationId) {
    final explicitConversationId = conversationId?.trim();
    if (explicitConversationId != null && explicitConversationId.isNotEmpty) {
      return explicitConversationId;
    }
    return _ref.read(activeConversationProvider)?.id;
  }

  /// kept for backward compatibility with existing caller
  Future<void> onSessionEnd() async {}

  MemoryService? get service => _service;
}
