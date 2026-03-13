import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/database.dart' as db;
import '../../../core/database/repositories/memory_repository.dart';
import '../../../core/database/repositories/message_repository.dart';
import '../../../core/network/json_http_client.dart';
import '../../chat/domain/message.dart' as chat;
import '../models/memory_entity.dart';
import '../utils/memory_time_formatter.dart';
import 'embedding_service.dart';
import 'hybrid_embedding_service.dart';
import 'memory_compressor_service.dart';
import 'memory_merger_service.dart';
import 'profile_service.dart';

List<Map<String, String?>> parseMemorySummaryItemsForTest(String raw) {
  final parsed = _parseSummaryPayload(raw);
  return [
    for (final item in parsed.items)
      <String, String?>{
        'fact': item.fact,
        'category': item.category,
        'targetLayer': item.targetLayer,
      }
  ];
}

String? resolveMemoryTargetLayerForTest({
  String? preferredLayer,
  required String category,
  required int totalMessages,
  required double avgUserChars,
}) {
  return _resolveTargetLayer(
    preferredLayer: preferredLayer,
    category: category,
    quality: _ConversationQuality(
      totalMessages: totalMessages,
      userMessages: totalMessages,
      avgUserChars: avgUserChars,
    ),
  );
}

String? _resolveTargetLayer({
  required String? preferredLayer,
  required String category,
  required _ConversationQuality quality,
}) {
  final explicitLayer = _normalizeTargetLayer(preferredLayer);
  if (explicitLayer != null) {
    return explicitLayer;
  }
  return _routeLayerByRules(category: category, quality: quality);
}

String? _routeLayerByRules({
  required String category,
  required _ConversationQuality quality,
}) {
  if (category == 'core_preference' ||
      category == 'identity_fact' ||
      category == 'emotional_event') {
    return 'L2';
  }
  if (category == 'ongoing_plan') {
    return (quality.totalMessages >= 8 || quality.avgUserChars >= 25)
        ? 'L2'
        : 'L3';
  }
  if (category == 'temporary_state') return 'L3';
  if (category == 'daily_chatter') {
    if (quality.totalMessages <= 3 && quality.avgUserChars < 15) return null;
    return 'L4';
  }
  return 'L4';
}

class ResolvedModelConfig {
  final String apiKey;
  final String baseUrl;
  final String model;

  const ResolvedModelConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  bool get isValid =>
      apiKey.isNotEmpty && baseUrl.isNotEmpty && model.isNotEmpty;
}

class MemoryServiceConfig {
  final bool enabled;
  final String summarizePrompt;
  final ResolvedModelConfig? summarizeModel;
  final ResolvedModelConfig? embeddingModel;
  final ResolvedModelConfig? fallbackEmbeddingModel;
  final bool fallbackEnabled;
  final int roundSplitThreshold;
  final bool enableCategoryClassification;
  final bool enableHybridSearch;
  final bool enableProfileLayer;
  final bool enableNextDayTrigger;
  final bool enableMemoryMerge;
  final bool enableCapacityCompress;
  final bool enablePreFlush;
  final int localMaxMemories;

  const MemoryServiceConfig({
    this.enabled = true,
    this.summarizePrompt = '',
    this.summarizeModel,
    this.embeddingModel,
    this.fallbackEmbeddingModel,
    this.fallbackEnabled = false,
    this.roundSplitThreshold = 20,
    this.enableCategoryClassification = true,
    this.enableHybridSearch = true,
    this.enableProfileLayer = true,
    this.enableNextDayTrigger = true,
    this.enableMemoryMerge = true,
    this.enableCapacityCompress = true,
    this.enablePreFlush = true,
    this.localMaxMemories = 800,
  });
}

class MemoryService {
  final MemoryServiceConfig config;
  final MemoryRepository _memoryRepository;
  final MessageRepository _messageRepository;

  late final ProfileService _profileService;
  late final MemoryMergerService _mergerService;
  late final MemoryCompressorService _compressorService;

  EmbeddingService? _embeddingService;

  MemoryService(
    this.config,
    this._memoryRepository,
    this._messageRepository,
  ) {
    _memoryRepository.setLocalMaxMemories(config.localMaxMemories);
    _profileService = ProfileService(_memoryRepository);
    _mergerService = MemoryMergerService(_memoryRepository,
        mergeModel: config.summarizeModel);
    _compressorService = MemoryCompressorService(_memoryRepository);
    _initEmbeddingService();
  }

  bool get isInFallbackMode {
    final service = _embeddingService;
    return service is HybridEmbeddingService && service.isInFallbackMode;
  }

  bool get isEmbeddingAvailable => _embeddingService != null;

  void _initEmbeddingService() {
    final primary = config.embeddingModel;
    final fallback = config.fallbackEmbeddingModel;
    if (primary == null || !primary.isValid) {
      _embeddingService = null;
      AppLogger.warning(
          'MemoryService', 'No valid embedding model configured.');
      return;
    }
    _embeddingService = HybridEmbeddingService(
      primaryApiKey: primary.apiKey,
      primaryBaseUrl: primary.baseUrl,
      primaryModel: primary.model,
      fallbackEnabled:
          config.fallbackEnabled && fallback != null && fallback.isValid,
      fallbackBaseUrl: fallback?.baseUrl ?? '',
      fallbackModel: fallback?.model ?? '',
      fallbackApiKey: fallback?.apiKey ?? '',
    );
  }

  Future<void> summarizeAndStore(
    List<chat.Message> messages, {
    required String conversationId,
  }) async {
    if (!config.enabled || messages.isEmpty) return;
    if (_embeddingService == null) {
      AppLogger.warning('MemoryService', 'Embedding service unavailable.');
      return;
    }

    final parsed = await _summarizeWithClassification(messages);
    if (parsed.items.isEmpty) {
      if (config.enableCapacityCompress) {
        await _reEnrichMarkedMemories(
          conversationId: conversationId,
          recentMessages: messages,
        );
      }
      return;
    }

    final now = DateTime.now();
    final quality = _conversationQuality(messages);

    for (final item in parsed.items) {
      final category = _normalizeCategory(item.category);
      final targetLayer = _resolveTargetLayer(
        preferredLayer: item.targetLayer,
        category: category,
        quality: quality,
      );
      if (targetLayer == null) continue;

      var content = _formatByLayer(
        targetLayer: targetLayer,
        fact: item.fact,
        chatProcess: item.chatProcess,
        emotion: item.emotion,
        personalityInsight: item.personalityInsight,
        aiStrategy: item.aiStrategy,
      );
      final contentHash = _sha256(content);
      final duplicated = await _memoryRepository.findByContentHash(
          conversationId, contentHash);
      if (duplicated != null) continue;

      final embedding = await _embeddingService!.getEmbedding(content);

      if (targetLayer == 'L2' && config.enableMemoryMerge) {
        final related = await _mergerService.findRelatedMemory(
          conversationId: conversationId,
          newFact: item.fact,
          newEmbedding: embedding,
        );
        if (related != null) {
          final merged = await _mergerService.mergeMemories(
            oldContent: related.content,
            newFact: item.fact,
          );
          final mergedEmbedding = await _embeddingService!.getEmbedding(merged);
          await _memoryRepository.updateMemory(
            related.copyWith(
              content: merged,
              contentHash: _sha256(merged),
              embedding: mergedEmbedding,
              updatedAt: now,
            ),
          );
          continue;
        }
      }

      final memory = MemoryEntity(
        id: const Uuid().v4(),
        content: content,
        embedding: embedding,
        layer: targetLayer,
        category: category,
        conversationId: conversationId,
        contentHash: contentHash,
        persistenceP: MemoryEntity.categoryToPersistenceP(category),
        createdAt: now,
      ).recalculateImportance();
      await _memoryRepository.addMemory(memory, triggerEviction: false);
    }

    if (config.enableProfileLayer &&
        parsed.profileSuggestionTrait != null &&
        parsed.profileSuggestionTrait!.trim().isNotEmpty) {
      await _profileService.checkAndPromoteProfile(
        conversationId: conversationId,
        trait: parsed.profileSuggestionTrait!,
        evidence: parsed.profileSuggestionEvidence ?? '',
      );
    }

    if (config.enableCapacityCompress) {
      await _reEnrichMarkedMemories(
        conversationId: conversationId,
        recentMessages: messages,
      );
    }

    if (config.enableCapacityCompress) {
      await _compressorService.evictIfNeeded(conversationId);
    }
  }

  Future<void> checkAndTriggerDailySummarization({
    required String conversationId,
  }) async {
    if (!config.enabled || !config.enableNextDayTrigger) return;

    final all =
        await _messageRepository.getAllByConversationOrdered(conversationId);
    if (all.isEmpty) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final rounds = _splitByOneHourGap(all);

    // Always group by full-day rounds first (including already summarized
    // messages), so round_key generation stays stable across retries.
    final grouped = <String, List<_DbMessageRound>>{};
    for (final round in rounds) {
      final start = DateTime.fromMillisecondsSinceEpoch(round.first.createdAt);
      final dateKey = _dateKey(start);
      final day = DateTime(start.year, start.month, start.day);
      if (!day.isBefore(today)) continue;
      grouped.putIfAbsent(dateKey, () => []).add(round);
    }
    if (grouped.isEmpty) return;

    for (final entry in grouped.entries) {
      final dateKey = entry.key;
      final dayRounds = entry.value;
      final dayMessages = dayRounds.expand((r) => r).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (!dayMessages.any((m) => !m.summarized)) continue;
      final userCount = dayMessages.where((m) => m.role == 'user').length;

      final units = <_RoundUnit>[];
      if (userCount <= config.roundSplitThreshold || dayRounds.length <= 1) {
        final rk = 'day:$dateKey';
        units.add(_RoundUnit(
          dateKey: dateKey,
          roundKey: rk,
          roundIndex: 0,
          messages: dayMessages,
        ));
      } else {
        for (var i = 0; i < dayRounds.length; i++) {
          final r = dayRounds[i];
          final first = r.first.createdAt;
          final last = r.last.createdAt;
          final rk = _sha1('$dateKey|$first|$last');
          units.add(_RoundUnit(
            dateKey: dateKey,
            roundKey: rk,
            roundIndex: i,
            messages: r,
          ));
        }
      }

      for (final unit in units) {
        final unsummarizedMessageIds =
            unit.messages.where((m) => !m.summarized).map((m) => m.id).toList();
        final existing = await _messageRepository.getSummarizationRecord(
          conversationId: conversationId,
          dateKey: unit.dateKey,
          roundKey: unit.roundKey,
        );

        // Heal historical data where round is marked summarized but some
        // messages are not. This can happen if old non-atomic writes existed.
        if (existing?.summarized == true) {
          if (unsummarizedMessageIds.isNotEmpty) {
            final fixAt =
                existing!.summarizedAt ?? DateTime.now().millisecondsSinceEpoch;
            await _messageRepository.markMessagesSummarized(
                unsummarizedMessageIds, fixAt);
            AppLogger.warning(
              'MemoryService',
              'Fixed inconsistent summarized flags for successful round',
              metadata: {
                'conversationId': conversationId,
                'dateKey': unit.dateKey,
                'roundKey': unit.roundKey,
                'fixedCount': unsummarizedMessageIds.length,
              },
            );
          }
          continue;
        }

        if (unsummarizedMessageIds.isEmpty) {
          if (existing != null && existing.summarized == false) {
            final summarizedAt = DateTime.now().millisecondsSinceEpoch;
            await _messageRepository.markRoundSuccessAndMessages(
              conversationId: conversationId,
              dateKey: unit.dateKey,
              roundKey: unit.roundKey,
              summarizedAt: summarizedAt,
              messageIds: const [],
            );
          }
          continue;
        }

        await _messageRepository.upsertSummarizationRecord(
          conversationId: conversationId,
          dateKey: unit.dateKey,
          roundKey: unit.roundKey,
          roundIndex: unit.roundIndex,
          firstMsgTime: unit.messages.first.createdAt,
          lastMsgTime: unit.messages.last.createdAt,
          messageCount: unit.messages.length,
          summarized: false,
          errorMessage: null,
        );

        try {
          final domainMessages = unit.messages
              .map((m) => chat.Message(
                    id: m.id,
                    role: m.role,
                    content: m.content,
                    createdAt: DateTime.fromMillisecondsSinceEpoch(m.createdAt),
                    status: m.status,
                  ))
              .toList();
          await summarizeAndStore(domainMessages,
              conversationId: conversationId);

          final summarizedAt = DateTime.now().millisecondsSinceEpoch;
          await _messageRepository.markRoundSuccessAndMessages(
            conversationId: conversationId,
            dateKey: unit.dateKey,
            roundKey: unit.roundKey,
            summarizedAt: summarizedAt,
            messageIds: unsummarizedMessageIds,
          );
        } catch (e) {
          await _messageRepository.markRoundFailure(
            conversationId: conversationId,
            dateKey: unit.dateKey,
            roundKey: unit.roundKey,
            errorMessage: e.toString(),
          );
        }
      }
    }
  }

  Future<void> runPreFlush({
    required String conversationId,
    required List<chat.Message> messagesLikelyToLose,
  }) async {
    if (!config.enabled ||
        !config.enablePreFlush ||
        messagesLikelyToLose.isEmpty) return;
    final focus = messagesLikelyToLose.length > 12
        ? messagesLikelyToLose.sublist(messagesLikelyToLose.length - 12)
        : messagesLikelyToLose;
    await summarizeAndStore(focus, conversationId: conversationId);
  }

  Future<String> getProfilePrompt(String conversationId) async {
    if (!config.enableProfileLayer) return '';
    return _profileService.getProfilePrompt(conversationId);
  }

  Future<List<String>> searchFormatted({
    required String conversationId,
    required String query,
  }) async {
    final memories = await search(conversationId: conversationId, query: query);
    return memories
        .map((m) => MemoryTimeFormatter.format(m.createdAt, m.content))
        .toList();
  }

  Future<List<MemoryEntity>> search({
    required String conversationId,
    required String query,
    int topK = 5,
  }) async {
    if (_embeddingService == null || query.trim().isEmpty) return const [];
    final embedding = await _embeddingService!.getEmbedding(query);
    if (config.enableHybridSearch) {
      return _memoryRepository.searchTopKHybrid(
        embedding,
        query,
        conversationId: conversationId,
        k: topK,
      );
    }
    return _memoryRepository.searchTopK(
      embedding,
      conversationId: conversationId,
      k: topK,
    );
  }

  Future<int> purgeExpiredTrash() => _memoryRepository.purgeExpired();
  Future<void> deleteMemory(String id, {String reason = 'user_delete'}) =>
      _memoryRepository.softDelete(id, reason: reason);
  Future<void> restoreMemory(String id) => _memoryRepository.restore(id);
  Future<List<MemoryEntity>> getTrashMemories({String? conversationId}) =>
      _memoryRepository.getTrash(conversationId: conversationId);
  Future<List<MemoryEntity>> getAllMemories(
          {String? conversationId, bool includeProfile = true}) =>
      _memoryRepository.getAllActive(
          conversationId: conversationId, includeProfile: includeProfile);
  Future<int> getActiveCount({String? conversationId}) =>
      _memoryRepository.getActiveCount(conversationId: conversationId);

  Future<void> _reEnrichMarkedMemories({
    required String conversationId,
    required List<chat.Message> recentMessages,
  }) async {
    if (_embeddingService == null) return;
    final marked = await _memoryRepository.getMemoriesNeedingEnrichment(
      conversationId: conversationId,
      limit: 20,
    );
    if (marked.isEmpty) return;

    for (final memory in marked) {
      final enriched = await _compressorService.reEnrich(
        compressedContent: memory.content,
        recentMessages: recentMessages,
      );
      if (enriched.trim().isEmpty) continue;
      final embedding = await _embeddingService!.getEmbedding(enriched);
      await _memoryRepository.updateMemory(
        memory.copyWith(
          layer: 'L2',
          content: enriched,
          contentHash: _sha256(enriched),
          embedding: embedding,
          needsEnrichment: false,
          updatedAt: DateTime.now(),
        ),
      );
    }
  }

  Future<_ParsedSummary> _summarizeWithClassification(
      List<chat.Message> messages) async {
    final prompt = _buildSummaryPrompt(messages);
    final raw = await _callSummarizeLLM(prompt);
    if (raw == null || raw.trim().isEmpty)
      return const _ParsedSummary(items: []);
    return _parseSummaryPayload(raw);
  }

  String _buildSummaryPrompt(List<chat.Message> messages) {
    final conversationText =
        messages.map((m) => '${m.role}: ${m.content}').join('\n');
    final base = config.summarizePrompt.trim().isEmpty
        ? _defaultSummaryPrompt
        : config.summarizePrompt;
    return '$base\n\n聊天记录：\n$conversationText';
  }

  Future<String?> _callSummarizeLLM(String prompt) async {
    final model = config.summarizeModel;
    if (model == null || !model.isValid) return null;
    final url = Uri.parse('${model.baseUrl}/chat/completions');
    try {
      final response = await JsonHttpClient.postJson(
        uri: url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${model.apiKey}',
        },
        jsonBody: {
          'model': model.model,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': 0.2,
        },
      );
      return response.data['choices']?[0]?['message']?['content'] as String?;
    } on JsonHttpRequestException {
      return null;
    }
  }

  _ConversationQuality _conversationQuality(List<chat.Message> messages) {
    final userMsgs = messages.where((m) => m.role == 'user').toList();
    final avgLen = userMsgs.isEmpty
        ? 0.0
        : userMsgs.map((m) => m.content.trim().length).reduce((a, b) => a + b) /
            userMsgs.length;
    return _ConversationQuality(
      totalMessages: messages.length,
      userMessages: userMsgs.length,
      avgUserChars: avgLen,
    );
  }

  String _normalizeCategory(String? category) {
    final c = (category ?? '').trim();
    const allowed = {
      'core_preference',
      'identity_fact',
      'emotional_event',
      'ongoing_plan',
      'temporary_state',
      'daily_chatter',
    };
    return allowed.contains(c) ? c : 'daily_chatter';
  }

  String _formatByLayer({
    required String targetLayer,
    required String fact,
    String? chatProcess,
    String? emotion,
    String? personalityInsight,
    String? aiStrategy,
  }) {
    switch (targetLayer) {
      case 'L2':
        return formatL2Content(
          fact: fact,
          chatProcess: chatProcess,
          emotion: emotion,
          personalityInsight: personalityInsight,
          aiStrategy: aiStrategy,
        );
      case 'L3':
        return '${_nowYmd()}，$fact';
      case 'L4':
      default:
        final title = _extractTitle(fact);
        return '${_nowYmd()}，$title';
    }
  }

  String formatL2Content({
    required String fact,
    String? chatProcess,
    String? emotion,
    String? personalityInsight,
    String? aiStrategy,
    String? currentStatus,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('【${_extractTitle(fact)}】');
    buffer.writeln('事件：$fact');
    if (chatProcess != null && chatProcess.isNotEmpty)
      buffer.writeln('聊天经过：$chatProcess');
    if (emotion != null && emotion.isNotEmpty) buffer.writeln('情绪：$emotion');
    if (personalityInsight != null && personalityInsight.isNotEmpty) {
      buffer.writeln('性格分析：$personalityInsight');
    }
    if (aiStrategy != null && aiStrategy.isNotEmpty)
      buffer.writeln('应对策略：$aiStrategy');
    if (currentStatus != null && currentStatus.isNotEmpty)
      buffer.writeln('→ 当前状态：$currentStatus');
    return buffer.toString().trim();
  }

  String _extractTitle(String fact) {
    final t = fact.trim();
    if (t.isEmpty) return '记忆条目';
    return t.length <= 18 ? t : '${t.substring(0, 18)}...';
  }

  List<_DbMessageRound> _splitByOneHourGap(List<db.Message> orderedMessages) {
    final rounds = <_DbMessageRound>[];
    if (orderedMessages.isEmpty) return rounds;

    var current = <db.Message>[orderedMessages.first];
    for (var i = 1; i < orderedMessages.length; i++) {
      final prev = orderedMessages[i - 1];
      final now = orderedMessages[i];
      final gap = now.createdAt - prev.createdAt;
      if (gap > const Duration(hours: 1).inMilliseconds) {
        rounds.add(current);
        current = [now];
      } else {
        current.add(now);
      }
    }
    if (current.isNotEmpty) rounds.add(current);
    return rounds;
  }

  String _dateKey(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _nowYmd() => _dateKey(DateTime.now());
  String _sha256(String input) => sha256.convert(utf8.encode(input)).toString();
  String _sha1(String input) => sha1.convert(utf8.encode(input)).toString();
}

_ParsedSummary _parseSummaryPayload(String raw) {
  final jsonPart = _extractJsonBlock(raw);
  if (jsonPart == null) {
    return _parsePlainTextSummary(raw);
  }

  try {
    final data = jsonDecode(jsonPart) as Map<String, dynamic>;
    final itemsJson = (data['items'] as List?) ?? const [];
    final items = <_SummaryItem>[];
    for (final rawItem in itemsJson) {
      if (rawItem is! Map<String, dynamic>) continue;
      final fact = (rawItem['fact'] as String?)?.trim() ?? '';
      if (fact.isEmpty) continue;
      items.add(
        _SummaryItem(
          fact: fact,
          category: (rawItem['category'] as String?)?.trim() ?? 'daily_chatter',
          targetLayer: (rawItem['target_layer'] as String?)?.trim(),
          chatProcess: (rawItem['chat_process'] as String?)?.trim(),
          emotion: (rawItem['emotion'] as String?)?.trim(),
          personalityInsight:
              (rawItem['personality_insight'] as String?)?.trim(),
          aiStrategy: (rawItem['ai_strategy'] as String?)?.trim(),
        ),
      );
    }

    String? trait;
    String? evidence;
    final profile = data['profile_suggestion'];
    if (profile is Map<String, dynamic>) {
      final t = (profile['trait'] as String?)?.trim();
      if (t != null && t.isNotEmpty && t.toLowerCase() != 'null') {
        trait = t;
        evidence = (profile['evidence'] as String?)?.trim();
      }
    }

    return _ParsedSummary(
      items: items,
      profileSuggestionTrait: trait,
      profileSuggestionEvidence: evidence,
    );
  } catch (_) {
    return _parsePlainTextSummary(raw);
  }
}

_ParsedSummary _parsePlainTextSummary(String raw) {
  final lines = LineSplitter.split(raw)
      .map((e) => e.replaceFirst(RegExp(r'^[\s\-*•\d\.\)\(]+'), '').trim())
      .where((e) => e.isNotEmpty)
      .toList();
  return _ParsedSummary(
    items: lines
        .take(8)
        .map(
          (e) => _SummaryItem(
            fact: e,
            category: 'daily_chatter',
            targetLayer: 'L3',
          ),
        )
        .toList(),
  );
}

String? _extractJsonBlock(String raw) {
  final fence =
      RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true).firstMatch(raw);
  final candidate = fence?.group(1) ?? raw;
  final start = candidate.indexOf('{');
  final end = candidate.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  return candidate.substring(start, end + 1);
}

String? _normalizeTargetLayer(String? layer) {
  final normalized = (layer ?? '').trim().toUpperCase();
  const allowed = {'L2', 'L3', 'L4'};
  return allowed.contains(normalized) ? normalized : null;
}

const String _defaultSummaryPrompt = '''
你是一位经验老道的心理分析师和关系策略师。
请分析以下聊天记录，提取值得记忆的事实。
按 JSON 输出，不要解释性文本：
{
  "items": [
    {
      "fact": "事件概要，20~80字",
      "category": "core_preference|identity_fact|emotional_event|ongoing_plan|temporary_state|daily_chatter",
      "target_layer": "L2|L3|L4",
      "chat_process": "仅L2可填",
      "emotion": "仅L2可填",
      "personality_insight": "仅L2可填",
      "ai_strategy": "仅L2可填"
    }
  ],
  "profile_suggestion": {
    "trait": "可空",
    "evidence": "可空"
  }
}
硬约束：
- 不要编造；不确定就不输出
- 输出 0~8 条，宁缺毋滥
''';

class _SummaryItem {
  final String fact;
  final String category;
  final String? targetLayer;
  final String? chatProcess;
  final String? emotion;
  final String? personalityInsight;
  final String? aiStrategy;

  const _SummaryItem({
    required this.fact,
    required this.category,
    this.targetLayer,
    this.chatProcess,
    this.emotion,
    this.personalityInsight,
    this.aiStrategy,
  });
}

class _ParsedSummary {
  final List<_SummaryItem> items;
  final String? profileSuggestionTrait;
  final String? profileSuggestionEvidence;

  const _ParsedSummary({
    required this.items,
    this.profileSuggestionTrait,
    this.profileSuggestionEvidence,
  });
}

class _ConversationQuality {
  final int totalMessages;
  final int userMessages;
  final double avgUserChars;

  const _ConversationQuality({
    required this.totalMessages,
    required this.userMessages,
    required this.avgUserChars,
  });
}

typedef _DbMessageRound = List<db.Message>;

class _RoundUnit {
  final String dateKey;
  final String roundKey;
  final int roundIndex;
  final List<db.Message> messages;

  const _RoundUnit({
    required this.dateKey,
    required this.roundKey,
    required this.roundIndex,
    required this.messages,
  });
}
