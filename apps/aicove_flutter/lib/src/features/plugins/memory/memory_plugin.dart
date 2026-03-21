import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../background_agent/background_agent_service.dart';
import '../../chat/domain/message.dart' as chat;
import '../../chat/providers2.dart';
import '../../memory/models/memory_entity.dart';
import '../../chat/services/chat_history_store.dart';
import '../../memory/services/memory_service.dart';
import '../../memory/utils/lexical_tokenizer_zh.dart';
import '../../memory/utils/memory_time_formatter.dart';
import '../../settings/app_settings.dart';
import '../domain/index.dart';
import 'memory_config.dart';

String buildRoleScopedMemoryPrompt({
  required String roleLabel,
  required String profilePrompt,
  List<String> relatedMemories = const [],
  List<String> l2SkillIndex = const [],
  List<String> l2SkillDetails = const [],
  List<String> l3Memories = const [],
}) {
  final normalizedRoleLabel =
      roleLabel.trim().isEmpty ? '当前角色' : roleLabel.trim();
  final profileLines = _normalizeProfilePromptLines(profilePrompt);
  final recallLines = <String>[
    ...relatedMemories.where((line) => line.trim().isNotEmpty),
    ...l3Memories.where((line) => line.trim().isNotEmpty),
  ];
  final sections = <String>[
    [
      '## 当前角色专属记忆库',
      '- 当前角色：$normalizedRoleLabel',
      '- 作用范围：以下 L1/L2/L3/L4 记忆仅属于当前角色，不能套用到其他角色',
      '- 注入方式：L1 直接插入；L2 以 skill 索引和命中详情插入；L3 以召回回忆插入',
    ].join('\n'),
  ];

  if (profileLines.isNotEmpty) {
    sections.add([
      '### L1 用户攻略',
      ...profileLines,
    ].join('\n'));
  }

  if (l2SkillIndex.isNotEmpty) {
    sections.add([
      '### L2 技能索引',
      ...l2SkillIndex,
    ].join('\n'));
  }

  if (l2SkillDetails.isNotEmpty) {
    sections.add([
      '### 已命中的 L2 技能详情',
      ...l2SkillDetails,
    ].join('\n\n'));
  }

  if (recallLines.isNotEmpty) {
    final buffer = StringBuffer()
      ..writeln('### L2/L3/L4 相关记忆')
      ..writeln('以下是当前角色记忆库中命中的 L3/L4 回忆摘要：');
    for (final memory in recallLines) {
      buffer.writeln('- $memory');
    }
    sections.add(buffer.toString().trim());
  }

  return sections.join('\n\n');
}

List<String> _normalizeProfilePromptLines(String profilePrompt) {
  return profilePrompt
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .where((line) => !line.startsWith('## '))
      .map((line) => line.startsWith('- ') ? line : '- $line')
      .toList(growable: false);
}

String formatL2SkillIndexEntry(MemoryEntity memory) {
  final snapshot = _extractL2SkillSnapshot(memory);
  return [
    '- 技能名：${snapshot.title}',
    '  时间：${snapshot.timePrefix}',
    '  触发线索：${snapshot.triggerHints.join(' / ')}',
  ].join('\n');
}

String formatL2SkillDetailBlock(MemoryEntity memory) {
  final snapshot = _extractL2SkillSnapshot(memory);
  final indentedDetails =
      snapshot.contentLines.map((line) => '    $line').join('\n');
  return [
    '- 技能：${snapshot.title}',
    '  时间：${snapshot.timePrefix}',
    '  详细内容：',
    indentedDetails,
  ].join('\n');
}

_L2SkillSnapshot _extractL2SkillSnapshot(MemoryEntity memory) {
  final lines = memory.content
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  final title = _extractL2Title(lines, memory.content);
  final triggerHints = <String?>[
    title,
    _extractStructuredValue(lines, '事件：'),
    _extractStructuredValue(lines, '情绪：'),
    _extractStructuredValue(lines, '性格分析：'),
  ]
      .whereType<String>()
      .map((value) => _truncateText(value, maxChars: 24))
      .where((value) => value.trim().isNotEmpty)
      .toSet()
      .take(4)
      .toList(growable: false);
  return _L2SkillSnapshot(
    title: title,
    timePrefix: MemoryTimeFormatter.getTimePrefix(memory.createdAt),
    triggerHints: triggerHints.isEmpty ? <String>[title] : triggerHints,
    contentLines: lines,
  );
}

String _extractL2Title(List<String> lines, String content) {
  for (final line in lines) {
    final match = RegExp(r'^【(.+?)】$').firstMatch(line);
    if (match != null) {
      final title = match.group(1)?.trim();
      if (title != null && title.isNotEmpty) {
        return title;
      }
    }
  }
  final normalized = content.trim();
  if (normalized.isEmpty) {
    return 'L2 记忆技能';
  }
  return _truncateText(normalized, maxChars: 18);
}

String? _extractStructuredValue(List<String> lines, String prefix) {
  for (final line in lines) {
    if (!line.startsWith(prefix)) continue;
    final value = line.substring(prefix.length).trim();
    if (value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

String _truncateText(String text, {required int maxChars}) {
  final normalized = text.trim();
  if (normalized.length <= maxChars) {
    return normalized;
  }
  return '${normalized.substring(0, maxChars)}...';
}

class _L2SkillSnapshot {
  final String title;
  final String timePrefix;
  final List<String> triggerHints;
  final List<String> contentLines;

  const _L2SkillSnapshot({
    required this.title,
    required this.timePrefix,
    required this.triggerHints,
    required this.contentLines,
  });
}

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
  final Map<String, List<MemoryEntity>> _lastRetrievedByConversation = {};

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

    List<MemoryEntity> related = const <MemoryEntity>[];
    if (isFiller) {
      related = _lastRetrievedByConversation[resolvedConversationId] ??
          const <MemoryEntity>[];
    }

    if (!isFiller || related.isEmpty) {
      try {
        related = await service.search(
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
    final l2Skills = related.where((memory) => memory.layer == 'L2').toList();
    final l3Recalls = related
        .where((memory) => memory.layer != 'L1' && memory.layer != 'L2')
        .map((memory) =>
            MemoryTimeFormatter.format(memory.createdAt, memory.content))
        .toList(growable: false);
    if (profilePrompt.trim().isEmpty && l2Skills.isEmpty && l3Recalls.isEmpty) {
      return null;
    }

    final roleLabel = await _resolveRoleLabel(resolvedConversationId);
    return buildRoleScopedMemoryPrompt(
      roleLabel: roleLabel,
      profilePrompt: profilePrompt,
      l2SkillIndex: [
        for (final memory in l2Skills) formatL2SkillIndexEntry(memory),
      ],
      l2SkillDetails: [
        for (final memory in l2Skills) formatL2SkillDetailBlock(memory),
      ],
      l3Memories: l3Recalls,
    );
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

  void clearConversationCache(String conversationId) {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) return;
    _lastRetrievedByConversation.remove(normalizedConversationId);
  }

  Future<String> _resolveRoleLabel(String conversationId) async {
    final conversation =
        await _ref.read(conversationRepositoryProvider).getById(conversationId);
    if (conversation == null) {
      return '当前角色';
    }
    final displayName = conversation.displayName.trim();
    if (displayName.isNotEmpty) {
      return displayName;
    }
    final title = conversation.title.trim();
    if (title.isNotEmpty) {
      return title;
    }
    return '当前角色';
  }

  MemoryService? get service => _service;
}
