import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/database.dart' as db;
import '../../../core/database/repositories/conversation_repository.dart';
import '../../../core/database/repositories/diary_repository.dart';
import '../../../core/database/repositories/memory_repository.dart';
import '../../../core/database/repositories/message_repository.dart';
import '../../background_agent/background_agent_service.dart';
import '../../background_agent/domain/background_agent_definition.dart';
import '../../background_agent/domain/background_context_spec.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import '../../chat/domain/message.dart' as chat;
import '../../diary/models/diary_entry.dart';
import '../models/memory_entity.dart';
import '../utils/memory_time_formatter.dart';
import 'embedding_service.dart';
import 'hybrid_embedding_service.dart';
import 'memory_compressor_service.dart';
import 'memory_merger_service.dart';
import 'profile_service.dart';

const Duration _summaryProtectionWindow = Duration(hours: 24);
const Duration _boundaryMergeWindow = Duration(minutes: 10);

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
  final String? summarizeModelRef;
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
    this.summarizeModelRef,
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

enum MemoryIngestTrigger { daily, preFlush, manual }

class MemoryService {
  final MemoryServiceConfig config;
  final MemoryRepository _memoryRepository;
  final MessageRepository _messageRepository;
  final BackgroundAgentService? _backgroundAgentService;
  final ConversationRepository? _conversationRepository;
  final DiaryRepository? _diaryRepository;
  static final Map<String, Future<void>> _conversationIngestLocks = {};

  late final ProfileService _profileService;
  late final MemoryMergerService _mergerService;
  late final MemoryCompressorService _compressorService;

  EmbeddingService? _embeddingService;

  MemoryService(
    this.config,
    this._memoryRepository,
    this._messageRepository, {
    BackgroundAgentService? backgroundAgentService,
    ConversationRepository? conversationRepository,
    DiaryRepository? diaryRepository,
    EmbeddingService? embeddingServiceOverride,
  })  : _backgroundAgentService = backgroundAgentService,
        _conversationRepository = conversationRepository,
        _diaryRepository = diaryRepository {
    _memoryRepository.setLocalMaxMemories(config.localMaxMemories);
    _profileService = ProfileService(_memoryRepository);
    _mergerService = MemoryMergerService(_memoryRepository,
        mergeModel: config.summarizeModel);
    _compressorService = MemoryCompressorService(_memoryRepository);
    if (embeddingServiceOverride != null) {
      _embeddingService = embeddingServiceOverride;
    } else {
      _initEmbeddingService();
    }
  }

  bool get isInFallbackMode {
    final service = _embeddingService;
    return service is HybridEmbeddingService && service.isInFallbackMode;
  }

  bool get isEmbeddingAvailable => _embeddingService != null;

  Future<void> _withConversationIngestLock(
    String conversationId,
    Future<void> Function() action,
  ) async {
    final previous =
        _conversationIngestLocks[conversationId] ?? Future<void>.value();
    final operation = previous
        .catchError((Object _, StackTrace __) {})
        .then<void>((_) => action());
    _conversationIngestLocks[conversationId] = operation;
    try {
      await operation;
    } finally {
      if (identical(_conversationIngestLocks[conversationId], operation)) {
        _conversationIngestLocks.remove(conversationId);
      }
    }
  }

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

    final parsed = await _summarizeWithClassification(
      messages,
      conversationId: conversationId,
    );
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
    final summaryDate = _resolveSummaryDate(messages);
    final summaryDateKey = _dateKey(summaryDate);
    final l3Facts = <String>[];

    for (final item in parsed.items) {
      final category = _normalizeCategory(item.category);
      final targetLayer = _resolveTargetLayer(
        preferredLayer: item.targetLayer,
        category: category,
        quality: quality,
      );
      if (targetLayer == null) continue;
      if (targetLayer == 'L3') {
        final normalizedFact = item.fact.trim();
        if (normalizedFact.isNotEmpty) {
          l3Facts.add(normalizedFact);
        }
      }

      var content = _formatByLayer(
        summaryDateKey: summaryDateKey,
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

    if (l3Facts.isNotEmpty) {
      await _saveDiaryFromL3Facts(
        conversationId: conversationId,
        summaryDate: summaryDate,
        facts: l3Facts,
      );
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

  /// 统一的记忆入库入口。
  ///
  /// - 幂等：仅处理当前仍处于未总结状态的消息；已成功的 round 会直接跳过。
  /// - 线程安全：同一会话的入库过程会被串行化，避免 daily / pre-flush 并发重复入库。
  /// - 触发器职责：调用方只负责提供候选范围，完整生命周期由本方法统一处理。
  Future<void> ingestMessages({
    required String conversationId,
    Iterable<String>? candidateMessageIds,
    int? beforeTimestampExclusive,
    required MemoryIngestTrigger trigger,
  }) {
    return _withConversationIngestLock(conversationId, () async {
      final candidateRows = await _messageRepository.getIngestCandidates(
        conversationId: conversationId,
        candidateMessageIds: candidateMessageIds,
        beforeTimestampExclusive: beforeTimestampExclusive,
      );
      if (candidateRows.isEmpty) return;

      final planningRows = await _loadPlanningRowsForIngest(
        conversationId: conversationId,
        candidateRows: candidateRows,
        beforeTimestampExclusive: beforeTimestampExclusive,
        trigger: trigger,
      );
      final candidateIds = {for (final row in candidateRows) row.id};
      final units = _buildIngestUnits(
        planningRows,
        trigger: trigger,
        candidateMessageIds: candidateIds,
      );
      for (final unit in units) {
        await _ingestUnit(conversationId: conversationId, unit: unit);
      }
    });
  }

  Future<void> checkAndTriggerDailySummarization({
    required String conversationId,
    DateTime? disturbanceTime,
  }) async {
    if (!config.enabled || !config.enableNextDayTrigger) return;

    final resolvedDisturbanceTime =
        await _resolveDisturbanceTime(conversationId, disturbanceTime);
    if (resolvedDisturbanceTime == null) return;

    final cutoffTimestamp = resolvedDisturbanceTime
        .subtract(_summaryProtectionWindow)
        .millisecondsSinceEpoch;
    final agedCandidates = await _messageRepository.getIngestCandidates(
      conversationId: conversationId,
      beforeTimestampExclusive: cutoffTimestamp,
    );
    if (agedCandidates.isEmpty) return;

    final ingestBoundaryExclusive = await _resolveIngestBoundaryExclusive(
      conversationId: conversationId,
      cutoffTimestamp: cutoffTimestamp,
    );
    await ingestMessages(
      conversationId: conversationId,
      beforeTimestampExclusive: ingestBoundaryExclusive,
      trigger: MemoryIngestTrigger.daily,
    );
  }

  Future<DateTime?> _resolveDisturbanceTime(
    String conversationId,
    DateTime? explicitDisturbanceTime,
  ) async {
    if (explicitDisturbanceTime != null) {
      return explicitDisturbanceTime;
    }
    final latestUserMessage = await _messageRepository.getLastMessageByRole(
      conversationId,
      role: 'user',
    );
    if (latestUserMessage == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(latestUserMessage.createdAt);
  }

  Future<int> _resolveIngestBoundaryExclusive({
    required String conversationId,
    required int cutoffTimestamp,
  }) async {
    final orderedMessages =
        await _messageRepository.getAllByConversationOrdered(conversationId);
    if (orderedMessages.isEmpty) return cutoffTimestamp;

    final orderedUserMessages = orderedMessages
        .where((row) => row.role.trim().toLowerCase() == 'user')
        .toList(growable: false);
    if (orderedUserMessages.isEmpty) {
      return cutoffTimestamp;
    }

    final firstProtectedUserIndex = orderedUserMessages.indexWhere(
      (row) => row.createdAt >= cutoffTimestamp,
    );
    if (firstProtectedUserIndex <= 0) {
      return cutoffTimestamp;
    }

    // Trigger continuity by adjacent user-message gaps across the 24h boundary,
    // and only absorb protected messages up to the last user message that
    // stays continuous. This preserves the 24h protection window unless the
    // user-message chain explicitly bridges the boundary.
    var lastIncludedUserTimestamp =
        orderedUserMessages[firstProtectedUserIndex - 1].createdAt;
    var boundaryExclusive = cutoffTimestamp;
    for (var i = firstProtectedUserIndex; i < orderedUserMessages.length; i++) {
      final currentUser = orderedUserMessages[i];
      final gap = currentUser.createdAt - lastIncludedUserTimestamp;
      if (gap > _boundaryMergeWindow.inMilliseconds) {
        break;
      }
      lastIncludedUserTimestamp = currentUser.createdAt;
      boundaryExclusive = currentUser.createdAt + 1;
    }
    return boundaryExclusive;
  }

  Future<void> runPreFlush({
    required String conversationId,
    required List<chat.Message> messagesLikelyToLose,
  }) async {
    if (!config.enabled ||
        !config.enablePreFlush ||
        messagesLikelyToLose.isEmpty) {
      return;
    }
    final focus = messagesLikelyToLose.length > 12
        ? messagesLikelyToLose.sublist(messagesLikelyToLose.length - 12)
        : messagesLikelyToLose;
    final messageIds = focus
        .map((m) => m.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (messageIds.isEmpty) return;
    await ingestMessages(
      conversationId: conversationId,
      candidateMessageIds: messageIds,
      trigger: MemoryIngestTrigger.preFlush,
    );
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

  Future<List<db.Message>> _loadPlanningRowsForIngest({
    required String conversationId,
    required List<db.Message> candidateRows,
    int? beforeTimestampExclusive,
    required MemoryIngestTrigger trigger,
  }) async {
    if (candidateRows.isEmpty || trigger != MemoryIngestTrigger.daily) {
      return candidateRows;
    }

    final candidateDateKeys = {
      for (final row in candidateRows)
        _dateKey(DateTime.fromMillisecondsSinceEpoch(row.createdAt)),
    };
    final allRows =
        await _messageRepository.getAllByConversationOrdered(conversationId);
    final scoped = allRows.where((row) {
      if (beforeTimestampExclusive != null &&
          row.createdAt >= beforeTimestampExclusive) {
        return false;
      }
      final dateKey =
          _dateKey(DateTime.fromMillisecondsSinceEpoch(row.createdAt));
      return candidateDateKeys.contains(dateKey);
    }).toList(growable: false);
    return scoped.isEmpty ? candidateRows : scoped;
  }

  List<_RoundUnit> _buildIngestUnits(
    List<db.Message> orderedMessages, {
    required MemoryIngestTrigger trigger,
    required Set<String> candidateMessageIds,
  }) {
    if (orderedMessages.isEmpty || candidateMessageIds.isEmpty) return const [];

    final rounds = _splitByOneHourGap(orderedMessages);
    final grouped = <String, List<_DbMessageRound>>{};
    for (final round in rounds) {
      if (!round.any((m) => candidateMessageIds.contains(m.id))) continue;
      final start = DateTime.fromMillisecondsSinceEpoch(round.first.createdAt);
      final dateKey = _dateKey(start);
      grouped.putIfAbsent(dateKey, () => []).add(round);
    }
    if (grouped.isEmpty) return const [];

    final units = <_RoundUnit>[];
    for (final entry in grouped.entries) {
      final dateKey = entry.key;
      final dayRounds = entry.value;
      final dayMessages = dayRounds.expand((r) => r).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final dayMessageIds = [
        for (final message in dayMessages)
          if (candidateMessageIds.contains(message.id)) message.id,
      ];
      if (dayMessageIds.isEmpty) continue;

      final userCount = dayMessages.where((m) => m.role == 'user').length;
      final allowDayAggregation = trigger == MemoryIngestTrigger.daily &&
          !dayMessages.any((m) => m.summarized) &&
          (userCount <= config.roundSplitThreshold || dayRounds.length <= 1);
      if (allowDayAggregation) {
        units.add(_RoundUnit(
          dateKey: dateKey,
          roundKey: 'day:$dateKey',
          roundIndex: 0,
          messages: dayMessages,
          messageIds: dayMessageIds,
        ));
        continue;
      }

      for (var i = 0; i < dayRounds.length; i++) {
        final roundMessages = dayRounds[i];
        final roundMessageIds = [
          for (final message in roundMessages)
            if (candidateMessageIds.contains(message.id)) message.id,
        ];
        if (roundMessageIds.isEmpty) continue;
        final first = roundMessages.first.createdAt;
        final last = roundMessages.last.createdAt;
        units.add(_RoundUnit(
          dateKey: dateKey,
          roundKey: _sha1('$dateKey|$first|$last'),
          roundIndex: i,
          messages: roundMessages,
          messageIds: roundMessageIds,
        ));
      }
    }
    return units;
  }

  Future<void> _ingestUnit({
    required String conversationId,
    required _RoundUnit unit,
  }) async {
    final unsummarizedMessageIds = unit.messageIds;
    final existing = await _messageRepository.getSummarizationRecord(
      conversationId: conversationId,
      dateKey: unit.dateKey,
      roundKey: unit.roundKey,
    );

    // Heal historical data where round is marked summarized but some messages
    // are not. This can happen if old non-atomic writes existed.
    if (existing?.summarized == true) {
      if (unsummarizedMessageIds.isNotEmpty) {
        final fixAt =
            existing!.summarizedAt ?? DateTime.now().millisecondsSinceEpoch;
        await _messageRepository.markMessagesSummarized(
          unsummarizedMessageIds,
          fixAt,
        );
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
      return;
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
      return;
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
          .toList(growable: false);
      await summarizeAndStore(domainMessages, conversationId: conversationId);

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

  Future<_ParsedSummary> _summarizeWithClassification(
    List<chat.Message> messages, {
    required String conversationId,
  }) async {
    final raw = await _runSummaryBackgroundAgent(
      messages: messages,
      conversationId: conversationId,
    );
    if (raw == null || raw.trim().isEmpty) {
      return const _ParsedSummary(items: []);
    }
    return _parseSummaryPayload(raw);
  }

  Future<String?> _runSummaryBackgroundAgent({
    required List<chat.Message> messages,
    required String conversationId,
  }) async {
    final backgroundAgentService = _backgroundAgentService;
    final modelRef = config.summarizeModelRef?.trim();
    if (messages.isEmpty) {
      return null;
    }
    if (backgroundAgentService == null ||
        modelRef == null ||
        modelRef.isEmpty) {
      throw StateError(
        'MemoryService 需要 BackgroundAgentService 和 summarizeModelRef 才能执行记忆总结。',
      );
    }
    final extraInstruction =
        await _buildMemorySummaryExtraInstruction(conversationId);

    final result = await backgroundAgentService.run(
      definition: BackgroundAgentDefinition(
        id: 'memory_manager',
        name: '记忆管理',
        objectivePrompt: config.summarizePrompt.trim().isEmpty
            ? _defaultSummaryPrompt
            : config.summarizePrompt,
        contextSpec: BackgroundContextSpec(
          lastMessages: messages.length,
          includeUser: true,
          includeAssistant: true,
          includeSystem: false,
          includeTimestamps: true,
        ),
        allowedToolNames: const <String>[],
        modelRef: modelRef,
        temperature: 0.2,
        maxRounds: 1,
      ),
      conversationId: conversationId,
      extraInstruction: extraInstruction,
      contextMessages: messages,
    );
    final text = result.text.trim();
    return text.isEmpty ? null : text;
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
    required String summaryDateKey,
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
        return '$summaryDateKey，$fact';
      case 'L4':
      default:
        final title = _extractTitle(fact);
        return '$summaryDateKey，$title';
    }
  }

  Future<String> _buildMemorySummaryExtraInstruction(
    String conversationId,
  ) async {
    final sections = <String>[_memorySummaryExtraInstruction.trim()];
    final roleInstruction = await _buildRolePersonaInstruction(conversationId);
    if (roleInstruction.isNotEmpty) {
      sections.add(roleInstruction);
    }
    return sections.join('\n\n');
  }

  Future<String> _buildRolePersonaInstruction(String conversationId) async {
    const genericInstruction = '''
当 target_layer = L3 时：
- fact 必须用角色第一视角写成单条日记事件，像角色自己在回顾“我和用户发生了什么”
- 可以输出同一天的多条不同事件，每条只聚焦一件事
- 不要写成旁白、观察报告或分析结论
''';

    final conversationRepository = _conversationRepository;
    if (conversationRepository == null) {
      return genericInstruction.trim();
    }

    final conversation = await conversationRepository.getById(conversationId);
    if (conversation == null) {
      return genericInstruction.trim();
    }

    final roleName = conversation.displayName.trim().isEmpty
        ? conversation.title.trim()
        : conversation.displayName.trim();
    final selfAddress = conversation.selfAddress?.trim().isNotEmpty == true
        ? conversation.selfAddress!.trim()
        : '我';
    final addressUser = conversation.addressUser?.trim().isNotEmpty == true
        ? conversation.addressUser!.trim()
        : '你';
    final personaPrompt =
        PersonaPromptCodec.parse(conversation.personaPrompt).userPrompt;
    final personaSummary = _truncateForPrompt(personaPrompt, maxChars: 600);

    final buffer = StringBuffer()
      ..writeln('当前需要你以指定角色的人设来整理记忆：')
      ..writeln('- 角色名：$roleName')
      ..writeln('- 角色自称优先使用：$selfAddress')
      ..writeln('- 对用户称呼优先使用：$addressUser');
    if (personaSummary.isNotEmpty) {
      buffer.writeln('- 角色设定摘要：$personaSummary');
    }
    buffer.writeln(genericInstruction.trim());
    buffer.writeln('- 单日内允许输出多条 L3 事件，这些事件之后会被拼接为同一篇日记展示');
    return buffer.toString().trim();
  }

  String _truncateForPrompt(String text, {required int maxChars}) {
    final normalized = text.trim();
    if (normalized.length <= maxChars) {
      return normalized;
    }
    return '${normalized.substring(0, maxChars)}...';
  }

  DateTime _resolveSummaryDate(List<chat.Message> messages) {
    var earliest = messages.first.createdAt;
    for (final message in messages.skip(1)) {
      if (message.createdAt.isBefore(earliest)) {
        earliest = message.createdAt;
      }
    }
    return DateTime(earliest.year, earliest.month, earliest.day);
  }

  Future<void> _saveDiaryFromL3Facts({
    required String conversationId,
    required DateTime summaryDate,
    required List<String> facts,
  }) async {
    final diaryRepository = _diaryRepository;
    if (diaryRepository == null) return;

    final incomingParagraphs = _normalizeDiaryParagraphs(facts);
    if (incomingParagraphs.isEmpty) return;

    final existing = await diaryRepository.getDiaryByDate(
      conversationId,
      summaryDate,
    );
    final mergedParagraphs = _mergeDiaryParagraphs(
      existing?.content,
      incomingParagraphs,
    );
    final mergedContent = mergedParagraphs.join('\n\n').trim();
    if (mergedContent.isEmpty) return;
    if (existing != null && existing.content.trim() == mergedContent) {
      return;
    }

    final now = DateTime.now();
    final embedding = _embeddingService == null
        ? const <double>[]
        : await _embeddingService!.getEmbedding(mergedContent);
    final diary = (existing ??
            DiaryEntry(
              id: const Uuid().v4(),
              conversationId: conversationId,
              date: summaryDate,
              content: mergedContent,
              createdAt: now,
            ))
        .copyWith(
      date: summaryDate,
      content: mergedContent,
      embedding: embedding,
      updatedAt: now,
      isSynced: false,
      syncState: existing == null ? 'local' : 'modified',
    );
    await diaryRepository.saveDiary(diary);
  }

  List<String> _normalizeDiaryParagraphs(List<String> facts) {
    final seen = <String>{};
    final normalized = <String>[];
    for (final fact in facts) {
      final paragraph = fact.trim();
      if (paragraph.isEmpty || !seen.add(paragraph)) {
        continue;
      }
      normalized.add(paragraph);
    }
    return normalized;
  }

  List<String> _mergeDiaryParagraphs(
    String? existingContent,
    List<String> incomingParagraphs,
  ) {
    final seen = <String>{};
    final merged = <String>[];
    for (final paragraph in _splitDiaryParagraphs(existingContent)) {
      if (seen.add(paragraph)) {
        merged.add(paragraph);
      }
    }
    for (final paragraph in incomingParagraphs) {
      if (seen.add(paragraph)) {
        merged.add(paragraph);
      }
    }
    return merged;
  }

  List<String> _splitDiaryParagraphs(String? content) {
    if (content == null || content.trim().isEmpty) {
      return const [];
    }
    return content
        .split(RegExp(r'\n\s*\n+'))
        .map((paragraph) => paragraph.trim())
        .where((paragraph) => paragraph.isNotEmpty)
        .toList(growable: false);
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
    if (chatProcess != null && chatProcess.isNotEmpty) {
      buffer.writeln('聊天经过：$chatProcess');
    }
    if (emotion != null && emotion.isNotEmpty) buffer.writeln('情绪：$emotion');
    if (personalityInsight != null && personalityInsight.isNotEmpty) {
      buffer.writeln('性格分析：$personalityInsight');
    }
    if (aiStrategy != null && aiStrategy.isNotEmpty) {
      buffer.writeln('应对策略：$aiStrategy');
    }
    if (currentStatus != null && currentStatus.isNotEmpty) {
      buffer.writeln('→ 当前状态：$currentStatus');
    }
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
      "fact": "事件概要；若 target_layer=L3，必须写成角色第一视角的单条日记事件，20~80字",
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
- 认真使用消息时间戳，判断事情发生在多久前、现在是否还在持续
- L3 允许同一天输出多条事件，每条都是可独立展示的日记片段
''';

const String _memorySummaryExtraInstruction = '''
你当前收到的是已经按记忆触发规则挑选过的一批旧消息：
- 核心部分是当前用户消息之前 24 小时保护期之外、且尚未总结的消息
- 如果保护期边界前后的用户消息连续间隔不超过 10 分钟，保护期内相邻消息也可能被并入
请强烈关注每条消息中的时间戳，判断事件发生在多久前、是否已经结束，不要把短期状态误写成长期稳定事实。
严格按要求输出 JSON，不要输出 markdown。
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
  final List<String> messageIds;

  const _RoundUnit({
    required this.dateKey,
    required this.roundKey,
    required this.roundIndex,
    required this.messages,
    required this.messageIds,
  });
}
