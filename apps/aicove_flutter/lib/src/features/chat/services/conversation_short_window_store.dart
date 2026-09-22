import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/database.dart' as db;
import '../../../core/database/database_provider.dart';
import '../../../core/models/message_block.dart';
import '../domain/message.dart';
import '../../observability/frontend_diagnostics_port.dart';
import 'history_display_decoder.dart';
import '../../observability/frontend_diagnostics_provider.dart';
import 'image_dimension_probe/image_dimension_probe.dart';

const int kConversationTimelineSeedMessageCount = 20;

class ConversationTimelineWindowState {
  const ConversationTimelineWindowState({
    required this.messages,
    required this.hasMoreMessages,
  });

  final List<Message> messages;
  final bool hasMoreMessages;
}

/// Frontend-only timeline cache.
///
/// 数据库继续保存 raw message；这里仅缓存“已投影好的前端消息窗口”。
///
/// 图片尺寸维护（宽高回填）作为低频维护轮运行：
/// - 读取路径（`peekWindow`／热快照 `watchWindow` 首值）严格纯读，不触发维护；
/// - 内容写入路径安装快照时调度维护，但绝不 await 探测；
/// - 每个来源（raw 消息 id＋复合来源指纹）本生命周期内至多探测一次，
///   失败即记入 attempted 状态收敛，成功尺寸经 CAS 写回 `message_blocks`。
class ConversationTimelineCache {
  ConversationTimelineCache(this._ref);

  static const int _maintenanceBatchSize = 4;

  final Ref _ref;
  final Map<String, _ConversationTimelineSnapshot> _snapshotsByConversation =
      <String, _ConversationTimelineSnapshot>{};
  final Map<String, _ConversationFrontendVisibilityState>
  _visibilityByConversation = <String, _ConversationFrontendVisibilityState>{};
  final Map<String, StreamController<void>> _changeControllers =
      <String, StreamController<void>>{};
  final Map<String, Future<void>> _conversationTasks = <String, Future<void>>{};
  final Map<String, Future<void>> _snapshotUpgradeTasks =
      <String, Future<void>>{};

  /// 统一来源状态表：attempted 与成功尺寸合一（同进同出的单 LRU）。
  final Map<String, LinkedHashMap<String, _SourceProbeState>>
  _sourceProbeStates = <String, LinkedHashMap<String, _SourceProbeState>>{};

  /// 在途维护任务存在时收到的重跑请求（由尾处理消费）。
  final Set<String> _maintenanceRerunRequested = <String>{};

  /// 会话维护 epoch：clear/delete 在自身入队前递增使在途/在队任务失效。
  ///
  /// 条目只增不删（dispose 也不清理）——有意以极小常驻内存换竞态安全：
  /// 若删除/重置条目，旧任务捕获的 epoch 可能与重建后的默认值再次相等而
  /// “复活”。
  final Map<String, int> _maintenanceEpoch = <String, int>{};

  /// 块实例 → 来源身份部件缓存。
  ///
  /// 身份计算含 base64 流式采样（O(n) 扫描）；块对象不可变，按实例缓存
  /// 避免候选扫描/安装回放反复扫描大 payload。Expando 弱引用不延长块生命。
  final Expando<_ImageSourceParts> _sourcePartsByBlock =
      Expando<_ImageSourceParts>();

  bool _disposed = false;

  /// 每会话来源状态表容量上限（超限逐出最早条目，attempted 与尺寸同进同出）。
  @visibleForTesting
  int sourceProbeStateCapacityPerConversation = 512;

  /// 维护任务实际入队次数（非调度请求次数）。
  @visibleForTesting
  int debugMaintenanceEnqueueCount = 0;

  /// 探测执行次数（含注入 fake 的调用）。
  @visibleForTesting
  int debugProbeCount = 0;

  /// CAS 写回因行内容已变（stale）而跳过的次数。
  @visibleForTesting
  int debugStaleWriteBackSkipCount = 0;

  /// 完整 base64 规范化拷贝的构造次数（应恒为 0）。
  ///
  /// 契约：候选扫描、状态表、安装回放与精确门一律使用流式实现
  /// （采样哈希＋逐字符比较器），不得构造完整规范化 payload 副本；
  /// 任何未来确需全量拷贝的代码必须自增此计数，使回归测试可见。
  @visibleForTesting
  int debugFullBase64NormalizationCount = 0;

  /// 维护尾处理故障注入钩子（仅测试）：在尾处理逻辑前调用。
  @visibleForTesting
  void Function(String conversationId)? debugMaintenanceTailHook;

  /// 探测实现唯一注入点：经 [imageDimensionProbeProvider] 获取，测试
  /// override 该 provider。
  ImageDimensionProbe get _probe => _ref.read(imageDimensionProbeProvider);

  ConversationTimelineWindowState? peekWindow({
    required String conversationId,
    required int limit,
  }) {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return const ConversationTimelineWindowState(
        messages: <Message>[],
        hasMoreMessages: false,
      );
    }

    final snapshot = _snapshotsByConversation[normalizedConversationId];
    if (snapshot == null) {
      return null;
    }
    // 严格纯读：不调度维护、不产生任何副作用。
    return _buildWindow(
      snapshot,
      limit: limit,
      visibility: _visibilityFor(normalizedConversationId),
    );
  }

  Stream<ConversationTimelineWindowState> watchWindow({
    required String conversationId,
    required int limit,
  }) async* {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      yield const ConversationTimelineWindowState(
        messages: <Message>[],
        hasMoreMessages: false,
      );
      return;
    }

    final normalizedLimit = limit < 1 ? 1 : limit;
    // 在读取首值前先建立变更订阅（缓冲）：保证「首值与监听建立之间」
    // 完成的任何变更不丢失。
    final changes = StreamController<void>();
    final subscription = _controllerFor(normalizedConversationId).stream.listen(
      changes.add,
      onError: changes.addError,
      onDone: changes.close,
    );
    try {
      yield await _resolveWindow(
        normalizedConversationId,
        limit: normalizedLimit,
      );
      yield* changes.stream.asyncMap((_) {
        return _resolveWindow(normalizedConversationId, limit: normalizedLimit);
      });
    } finally {
      await subscription.cancel();
      // 不 await close：未被监听的单订阅 controller 的 done future
      // 永不完成，await 会挂死消费方（如 `.first`）的取消链。
      unawaited(changes.close());
    }
  }

  Future<void> upsertMessage({
    required String conversationId,
    required Message message,
  }) {
    return upsertMessages(
      conversationId: conversationId,
      messages: <Message>[message],
    );
  }

  Future<void> upsertMessages({
    required String conversationId,
    required List<Message> messages,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty || messages.isEmpty) {
      return;
    }

    await _runConversationTask(normalizedConversationId, () async {
      final current = await _ensureConversationReadyUnlocked(
        normalizedConversationId,
        minMessages: kConversationTimelineSeedMessageCount,
      );
      final mergedById = <String, Message>{
        for (final message in current.messages) message.id: message,
      };
      for (final message in messages) {
        final existing = mergedById[message.id];
        final sourceMessageId = message.sourceMessageId?.trim();
        // Media callbacks may retain a stream timestamp from before a history
        // reload or supplement insertion. Keep the current projection's slot;
        // resolve its timestamp inside this queue, alongside snapshot updates.
        final preservePosition =
            existing != null &&
            sourceMessageId != null &&
            sourceMessageId.isNotEmpty &&
            sourceMessageId != message.id &&
            _messageRawSourceId(existing) == sourceMessageId;
        mergedById[message.id] = preservePosition
            ? message.copyWith(createdAt: existing.createdAt)
            : message;
      }

      final normalizedMessages = _normalizeMessages(mergedById.values);
      final next = await _normalizeAndSyncSnapshotUnlocked(
        _ConversationTimelineSnapshot(
          conversationId: normalizedConversationId,
          messages: normalizedMessages,
          hasMoreMessages: current.hasMoreMessages,
          oldestRawCursor:
              current.oldestRawCursor ??
              _estimateOldestRawCursor(normalizedMessages),
          loadedRawMessageCount: current.loadedRawMessageCount > 0
              ? current.loadedRawMessageCount
              : _estimateLoadedRawMessageCount(normalizedMessages),
        ),
        affectedRawMessageIds: {
          for (final message in messages) _messageRawSourceId(message),
        },
      );
      _installSnapshot(
        normalizedConversationId,
        next,
        scheduleMaintenance: true,
      );
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<void> replaceMessages({
    required String conversationId,
    List<String> removeMessageIds = const <String>[],
    List<Message> messages = const <Message>[],
  }) async {
    return _replaceMessagesInternal(
      conversationId: conversationId,
      removeMessageIds: removeMessageIds,
      messages: messages,
      syncProjectionMappings: true,
    );
  }

  Future<void> replaceMessagesTransient({
    required String conversationId,
    List<String> removeMessageIds = const <String>[],
    List<Message> messages = const <Message>[],
  }) async {
    return _replaceMessagesInternal(
      conversationId: conversationId,
      removeMessageIds: removeMessageIds,
      messages: messages,
      syncProjectionMappings: false,
    );
  }

  Future<void> hideMessages({
    required String conversationId,
    List<String> rawMessageIds = const <String>[],
    List<String> projectedMessageIds = const <String>[],
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return;
    }

    final normalizedRawIds = {
      for (final rawMessageId in rawMessageIds)
        if (rawMessageId.trim().isNotEmpty) rawMessageId.trim(),
    };
    final normalizedProjectedIds = {
      for (final projectedMessageId in projectedMessageIds)
        if (projectedMessageId.trim().isNotEmpty) projectedMessageId.trim(),
    };
    if (normalizedRawIds.isEmpty && normalizedProjectedIds.isEmpty) {
      return;
    }

    await _runConversationTask(normalizedConversationId, () async {
      await _loadVisibility(normalizedConversationId);
      final current = _visibilityFor(normalizedConversationId);
      final next = current.merge(
        hiddenRawMessageIds: normalizedRawIds,
        hiddenProjectedMessageIds: normalizedProjectedIds,
      );
      final preferences = await SharedPreferences.getInstance();
      final saved = await preferences.setString(
        _visibilityKey(normalizedConversationId),
        jsonEncode({
          'raw': next.hiddenRawMessageIds.toList(),
          'projected': next.hiddenProjectedMessageIds.toList(),
        }),
      );
      if (!saved) throw StateError('消息隐藏记录保存失败');
      _visibilityByConversation[normalizedConversationId] = next;
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  // Local presentation preferences only: never stored in raw history or synced.
  String _visibilityKey(String conversationId) =>
      'aicove.frontend_hidden.v1.$conversationId';

  Future<void> _loadVisibility(String conversationId) async {
    if (_visibilityByConversation.containsKey(conversationId)) return;
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_visibilityKey(conversationId));
    final value = encoded == null
        ? const <String, dynamic>{}
        : jsonDecode(encoded) as Map<String, dynamic>;
    _visibilityByConversation[conversationId] =
        _ConversationFrontendVisibilityState(
          hiddenRawMessageIds: Set<String>.from(
            value['raw'] as List? ?? const [],
          ),
          hiddenProjectedMessageIds: Set<String>.from(
            value['projected'] as List? ?? const [],
          ),
        );
  }

  Future<void> _replaceMessagesInternal({
    required String conversationId,
    required List<String> removeMessageIds,
    required List<Message> messages,
    required bool syncProjectionMappings,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return;
    }

    final normalizedRemoveIds = removeMessageIds
        .map((messageId) => messageId.trim())
        .where((messageId) => messageId.isNotEmpty)
        .toSet();
    if (normalizedRemoveIds.isEmpty && messages.isEmpty) {
      return;
    }

    await _runConversationTask(normalizedConversationId, () async {
      final current = await _ensureConversationReadyUnlocked(
        normalizedConversationId,
        minMessages: kConversationTimelineSeedMessageCount,
      );
      final mergedById = <String, Message>{
        for (final message in current.messages)
          if (!normalizedRemoveIds.contains(message.id)) message.id: message,
      };
      for (final message in messages) {
        mergedById[message.id] = message;
      }

      final affectedRawMessageIds = <String>{
        for (final message in messages) _messageRawSourceId(message),
        for (final message in current.messages)
          if (normalizedRemoveIds.contains(message.id))
            _messageRawSourceId(message),
      };
      final normalizedMessages = _normalizeMessages(mergedById.values);
      final baseSnapshot = _ConversationTimelineSnapshot(
        conversationId: normalizedConversationId,
        messages: normalizedMessages,
        hasMoreMessages: current.hasMoreMessages,
        oldestRawCursor:
            current.oldestRawCursor ??
            _estimateOldestRawCursor(normalizedMessages),
        loadedRawMessageCount: current.loadedRawMessageCount > 0
            ? current.loadedRawMessageCount
            : _estimateLoadedRawMessageCount(normalizedMessages),
      );
      final next = syncProjectionMappings
          ? await _normalizeAndSyncSnapshotUnlocked(
              baseSnapshot,
              affectedRawMessageIds: affectedRawMessageIds,
            )
          : _buildInMemorySnapshot(baseSnapshot);
      // 瞬态（流式）内容不参与尺寸升级调度；持久路径正常调度。
      _installSnapshot(
        normalizedConversationId,
        next,
        scheduleMaintenance: syncProjectionMappings,
      );
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<int> loadOlderMessages({
    required String conversationId,
    int pageSize = kConversationTimelineSeedMessageCount,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return 0;
    }

    final normalizedPageSize = pageSize < 1 ? 1 : pageSize;
    return _runConversationTask(normalizedConversationId, () async {
      final current = await _ensureConversationReadyUnlocked(
        normalizedConversationId,
        minMessages: kConversationTimelineSeedMessageCount,
      );
      final oldestCursor = current.oldestRawCursor;
      if (oldestCursor == null ||
          current.messages.isEmpty ||
          !current.hasMoreMessages) {
        return 0;
      }

      final olderPage = await _loadOlderPageFromDb(
        normalizedConversationId,
        beforeCursor: oldestCursor,
        pageSize: normalizedPageSize,
      );
      if (olderPage.messages.isEmpty) {
        if (current.hasMoreMessages) {
          final next = await _normalizeAndSyncSnapshotUnlocked(
            current.copyWith(hasMoreMessages: false),
          );
          _installSnapshot(
            normalizedConversationId,
            next,
            scheduleMaintenance: true,
          );
          _notifyConversationChanged(normalizedConversationId);
        }
        return 0;
      }

      final nextMessages = _normalizeMessages(<Message>[
        ...olderPage.messages,
        ...current.messages,
      ]);
      final next = await _normalizeAndSyncSnapshotUnlocked(
        current.copyWith(
          messages: nextMessages,
          hasMoreMessages: olderPage.hasMoreMessages,
          oldestRawCursor: olderPage.oldestRawCursor ?? current.oldestRawCursor,
          loadedRawMessageCount:
              current.loadedRawMessageCount + olderPage.loadedRawMessageCount,
        ),
      );
      _installSnapshot(
        normalizedConversationId,
        next,
        scheduleMaintenance: true,
      );
      _notifyConversationChanged(normalizedConversationId);
      return olderPage.loadedRawMessageCount;
    });
  }

  Set<String> get loadedConversationIds => {
    ..._snapshotsByConversation.keys,
    ..._conversationTasks.keys,
  };

  /// Refresh committed remote changes in warm windows. This is explicit so
  /// projection-maintenance writes cannot trigger a database notification loop.
  Future<Set<String>> refreshConversationsFromRawStore(
    Set<String> conversationIds, {
    required bool Function(String conversationId) canRefresh,
  }) async {
    final deferred = <String>{};
    for (final id in conversationIds) {
      if (_disposed) return {};
      final refreshed = await _runConversationTask(id, () async {
        if (_disposed) return true;
        final current = _snapshotsByConversation[id];
        if (current == null) return true;
        if (!canRefresh(id)) return false;
        final diagnostics = _ref.read(frontendDiagnosticsProvider);
        final operation = diagnostics.enabled
            ? diagnostics.child(
                null,
                FrontendStage.historyReady,
                conversationId: id,
              )
            : null;
        var rebuilt = await _loadRecentSnapshotFromDb(
          id,
          targetCount: _maxInt(
            kConversationTimelineSeedMessageCount,
            current.loadedRawMessageCount,
          ),
        );
        // Once the user has paged backwards, keep their oldest loaded anchor
        // while including newly arrived messages above it, with no page gaps.
        final anchor = current.oldestRawCursor;
        if (anchor != null &&
            current.loadedRawMessageCount >
                kConversationTimelineSeedMessageCount) {
          while (rebuilt.hasMoreMessages &&
              rebuilt.oldestRawCursor != null &&
              !rebuilt.oldestRawCursor!.createdAt.isBefore(anchor.createdAt) &&
              !rebuilt.messages.any(
                (m) => _messageRawSourceId(m) == anchor.messageId,
              )) {
            if (_disposed || !canRefresh(id)) return false;
            rebuilt = await _expandSnapshotFromDb(
              rebuilt,
              minMessages:
                  rebuilt.loadedRawMessageCount +
                  kConversationTimelineSeedMessageCount,
            );
          }
        }
        if (_disposed || !canRefresh(id)) return false;
        // Remote snapshots already contain canonical projection mappings.
        // Refreshing the view must not rewrite them into local sync mutations.
        final next = _buildInMemorySnapshot(rebuilt);
        _installSnapshot(id, next, scheduleMaintenance: true);
        _notifyConversationChanged(id);
        diagnostics.record(
          operation,
          FrontendStage.historyReady,
          itemCount: next.messages.length,
          facts: DiagnosticFacts(
            phase: DiagnosticPhase.end,
            state: {
              'syncRefresh': true,
              'rawReadCount': next.loadedRawMessageCount,
              'projectedCount': next.messages.length,
            },
          ),
        );
        return true;
      });
      if (!refreshed) deferred.add(id);
    }
    return deferred;
  }

  Future<void> reloadConversationFromRawStore(
    String conversationId, {
    int? targetMessageCount,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return;
    }

    await _runConversationTask(normalizedConversationId, () async {
      final current = _snapshotsByConversation[normalizedConversationId];
      final normalizedTargetCount = targetMessageCount == null
          ? _maxInt(
              kConversationTimelineSeedMessageCount,
              current?.loadedRawMessageCount ?? 0,
            )
          : targetMessageCount < 1
          ? 1
          : targetMessageCount;

      final rebuilt = await _loadRecentSnapshotFromDb(
        normalizedConversationId,
        targetCount: normalizedTargetCount,
      );
      final next = await _normalizeAndSyncSnapshotUnlocked(rebuilt);
      _installSnapshot(
        normalizedConversationId,
        next,
        scheduleMaintenance: true,
      );
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<void> clearConversation(String conversationId) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return;
    }

    // 在自身入队前递增 epoch：使在途维护任务的探测结果失效。
    // epoch 条目只递增、永不删除或重置（否则旧任务捕获值可能与重建后的
    // 默认值再次相等）。
    _maintenanceEpoch[normalizedConversationId] =
        (_maintenanceEpoch[normalizedConversationId] ?? 0) + 1;
    _sourceProbeStates.remove(normalizedConversationId);

    await _runConversationTask(normalizedConversationId, () async {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.remove(_visibilityKey(normalizedConversationId))) {
        throw StateError('消息隐藏记录清理失败');
      }
      _installSnapshot(
        normalizedConversationId,
        _ConversationTimelineSnapshot(
          conversationId: normalizedConversationId,
          messages: const <Message>[],
          hasMoreMessages: false,
          oldestRawCursor: null,
          loadedRawMessageCount: 0,
        ),
        scheduleMaintenance: false,
      );
      _visibilityByConversation.remove(normalizedConversationId);
      _sourceProbeStates.remove(normalizedConversationId);
      await _ref
          .read(messageProjectionMappingRepositoryProvider)
          .deleteByConversation(normalizedConversationId);
      _notifyConversationChanged(normalizedConversationId);
    });
  }

  Future<void> deleteConversation(String conversationId) {
    return clearConversation(conversationId);
  }

  Future<List<Message>> loadCachedMessages(String conversationId) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return const <Message>[];
    }
    final snapshot = await _loadSnapshot(normalizedConversationId);
    return List<Message>.unmodifiable(snapshot.messages);
  }

  Future<int> loadCachedMessageCount(String conversationId) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      return 0;
    }
    final snapshot = await _loadSnapshot(normalizedConversationId);
    return snapshot.loadedRawMessageCount;
  }

  bool isMessageHidden(String conversationId, Message message) =>
      _isMessageHiddenByFrontendVisibility(
        message,
        _visibilityByConversation[conversationId] ??
            const _ConversationFrontendVisibilityState(),
      );

  Future<Message?> findCachedMessageById(
    String messageId, {
    String? conversationId,
  }) async {
    final normalizedMessageId = messageId.trim();
    if (normalizedMessageId.isEmpty) {
      return null;
    }

    final normalizedConversationId = conversationId?.trim();
    if (normalizedConversationId != null &&
        normalizedConversationId.isNotEmpty) {
      final messages = await loadCachedMessages(normalizedConversationId);
      for (final message in messages) {
        if (message.id == normalizedMessageId) {
          return message;
        }
      }
      return null;
    }

    for (final snapshot in _snapshotsByConversation.values) {
      for (final message in snapshot.messages) {
        if (message.id == normalizedMessageId) {
          return message;
        }
      }
    }
    return null;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final controller in _changeControllers.values) {
      unawaited(controller.close());
    }
    _changeControllers.clear();
    _sourceProbeStates.clear();
    _maintenanceRerunRequested.clear();
  }

  Future<ConversationTimelineWindowState> _resolveWindow(
    String conversationId, {
    required int limit,
  }) async {
    // 热旁路：内存快照命中时为无副作用纯读，不排入会话串行队列。
    final hot = _snapshotsByConversation[conversationId];
    if (hot != null) {
      return _buildWindow(
        hot,
        limit: limit,
        visibility: _visibilityFor(conversationId),
      );
    }
    final snapshot = await _loadSnapshot(conversationId);
    return _buildWindow(
      snapshot,
      limit: limit,
      visibility: _visibilityFor(conversationId),
    );
  }

  Future<_ConversationTimelineSnapshot> _loadSnapshot(String conversationId) {
    final queued = Stopwatch()..start();
    return _runConversationTask(
      conversationId,
      () => _loadSnapshotUnlocked(
        conversationId,
        queueMs: queued.elapsedMilliseconds,
      ),
    );
  }

  Future<_ConversationTimelineSnapshot> _loadSnapshotUnlocked(
    String conversationId, {
    required int queueMs,
  }) async {
    final hot = _snapshotsByConversation[conversationId];
    if (hot != null) {
      return _installSnapshot(conversationId, hot, scheduleMaintenance: true);
    }
    final diagnostics = _ref.read(frontendDiagnosticsProvider);
    final operation = diagnostics.enabled
        ? diagnostics.child(
            null,
            FrontendStage.historyColdLoad,
            conversationId: conversationId,
          )
        : null;
    final metrics = operation == null
        ? null
        : <String, Object?>{'queueMs': queueMs};
    try {
      final snapshot = await _loadRecentSnapshotFromDb(
        conversationId,
        targetCount: kConversationTimelineSeedMessageCount,
        coldLoadMetrics: metrics,
      );
      final clock = Stopwatch()..start();
      final installed = _installSnapshot(
        conversationId,
        snapshot,
        scheduleMaintenance: true,
      );
      metrics?['installMs'] = clock.elapsedMilliseconds;
      diagnostics.record(
        operation,
        FrontendStage.historyColdLoad,
        itemCount: installed.messages.length,
        facts: DiagnosticFacts(
          phase: DiagnosticPhase.end,
          state: metrics ?? const {},
        ),
      );
      return installed;
    } catch (error, stack) {
      diagnostics.record(
        operation,
        FrontendStage.historyFailed,
        error: error,
        stackTrace: stack,
        facts: DiagnosticFacts(
          phase: DiagnosticPhase.error,
          reason: DiagnosticReason.operationFailed,
          state: metrics ?? const {},
        ),
      );
      rethrow;
    }
  }

  Future<_ConversationTimelineSnapshot> _ensureConversationReadyUnlocked(
    String conversationId, {
    required int minMessages,
  }) async {
    final normalizedMinMessages = minMessages < 1 ? 1 : minMessages;
    var snapshot = _snapshotsByConversation[conversationId];
    snapshot ??= await _loadRecentSnapshotFromDb(
      conversationId,
      targetCount: kConversationTimelineSeedMessageCount,
    );

    if (snapshot.loadedRawMessageCount < normalizedMinMessages &&
        snapshot.hasMoreMessages) {
      final expanded = await _expandSnapshotFromDb(
        snapshot,
        minMessages: normalizedMinMessages,
      );
      snapshot = await _normalizeAndSyncSnapshotUnlocked(expanded);
    }

    return _installSnapshot(
      conversationId,
      snapshot,
      scheduleMaintenance: true,
    );
  }

  /// 唯一的内存快照安装入口。
  ///
  /// 1. 安装前按来源状态表回放已解析尺寸（纯同步内存操作）；
  /// 2. 写入快照 map；
  /// 3. [scheduleMaintenance] 为 true 且存在待探测候选时调度维护。
  ///
  /// 返回实际安装的快照（可能已被回放补齐宽高）。
  _ConversationTimelineSnapshot _installSnapshot(
    String conversationId,
    _ConversationTimelineSnapshot next, {
    required bool scheduleMaintenance,
  }) {
    final replayed =
        _replaySnapshotWithResolvedDimensions(conversationId, next) ?? next;
    _snapshotsByConversation[conversationId] = replayed;
    if (scheduleMaintenance &&
        _hasDimensionUpgradeCandidates(conversationId, replayed)) {
      _requestMaintenance(conversationId);
    }
    return replayed;
  }

  // ---------------------------------------------------------------------------
  // 图片尺寸维护：调度、单轮执行、来源状态表
  // ---------------------------------------------------------------------------

  void _requestMaintenance(String conversationId) {
    if (_disposed) {
      return;
    }
    if (_snapshotUpgradeTasks.containsKey(conversationId)) {
      // 在途任务存在：只置位，由尾处理接力，避免请求被去重吞掉。
      _maintenanceRerunRequested.add(conversationId);
      return;
    }
    _enqueueMaintenanceTask(conversationId);
  }

  void _enqueueMaintenanceTask(String conversationId) {
    debugMaintenanceEnqueueCount++;
    // B1：epoch 固定在入队时刻，任务启动时禁止重捕获——否则「已排队未
    // 启动」的任务会吸收期间发生的 clear/delete 失效并复活。
    final capturedEpoch = _maintenanceEpoch[conversationId] ?? 0;
    late final Future<void> task;
    task =
        _runConversationTask(conversationId, () {
          return _runSnapshotMaintenanceRound(conversationId, capturedEpoch);
        }).catchError((Object _) {}).whenComplete(() {
          if (identical(_snapshotUpgradeTasks[conversationId], task)) {
            _snapshotUpgradeTasks.remove(conversationId);
          }
          try {
            debugMaintenanceTailHook?.call(conversationId);
            _handleMaintenanceTail(conversationId, capturedEpoch);
          } on Object {
            // S1：尾处理异常必须就地密封——维护任务无人 await，
            // 不得让 task 以 error 完成产生未处理异常。
          }
        });
    _snapshotUpgradeTasks[conversationId] = task;
  }

  /// 唯一尾处理：在维护任务标记移除之后运行。
  ///
  /// 若在途期间收到重跑请求，或当前快照仍有候选（本轮截断的剩余），
  /// 重新入队下一批；因为是重新入队，期间排入的内容任务先执行。
  void _handleMaintenanceTail(String conversationId, int capturedEpoch) {
    final rerunRequested = _maintenanceRerunRequested.remove(conversationId);
    if (_disposed) {
      return;
    }
    if ((_maintenanceEpoch[conversationId] ?? 0) != capturedEpoch) {
      return;
    }
    final snapshot = _snapshotsByConversation[conversationId];
    final hasCandidates =
        snapshot != null &&
        _hasDimensionUpgradeCandidates(conversationId, snapshot);
    if (rerunRequested || hasCandidates) {
      _requestMaintenance(conversationId);
    }
  }

  /// 维护单轮：候选截取（上限 [_maintenanceBatchSize]）→ 预标记 attempted →
  /// 解析 backing rows（捕获原文）→ 探测 → CAS 先行、分类提交 → 单次通知。
  ///
  /// 全程 try/catch，绝不抛未处理异常；epoch/_disposed 失效即放弃
  /// （不写 DB、不安装、不通知、不写状态表尺寸）。
  Future<void> _runSnapshotMaintenanceRound(
    String conversationId,
    int epoch,
  ) async {
    try {
      bool invalidated() =>
          _disposed || (_maintenanceEpoch[conversationId] ?? 0) != epoch;
      if (invalidated()) {
        return;
      }
      final snapshot = _snapshotsByConversation[conversationId];
      if (snapshot == null) {
        return;
      }

      final candidates = _collectUpgradeCandidates(conversationId, snapshot);
      if (candidates.isEmpty) {
        return;
      }
      final batch = candidates.length > _maintenanceBatchSize
          ? candidates.sublist(0, _maintenanceBatchSize)
          : candidates;

      var anyResolvedStored = false;
      for (final candidate in batch) {
        // 探测前原子预标记 attempted。
        _markSourceAttempted(conversationId, candidate);

        List<_BackingBlockRow> backingRows;
        try {
          backingRows = await _resolveBackingRows(candidate);
        } on Object {
          backingRows = const <_BackingBlockRow>[];
        }
        if (invalidated()) {
          return;
        }

        debugProbeCount++;
        ImageDimensions? probed;
        try {
          probed = await _probe(candidate.probeInput);
        } on Object {
          probed = null;
        }
        if (invalidated()) {
          return;
        }
        if (probed == null || probed.width <= 0 || probed.height <= 0) {
          continue;
        }
        final dimensions = (width: probed.width, height: probed.height);

        if (backingRows.isEmpty) {
          // 无 backing row（投影/raw payload 来源）：仅内存生效＋状态表尺寸。
          _storeResolvedDimensions(conversationId, candidate, dimensions);
          anyResolvedStored = true;
          continue;
        }

        // CAS 先行：逐行独立提交，行间互不回滚。
        var casSuccessCount = 0;
        var casErrorCount = 0;
        var casStaleCount = 0;
        // 返回 false 表示任务已失效（调用方需立即整轮放弃）。
        Future<bool> runCasPass(List<_BackingBlockRow> rows) async {
          for (final row in rows) {
            if (invalidated()) {
              return false;
            }
            try {
              final newData = _mergeDimensionsIntoBlockData(
                row.dataText,
                dimensions,
              );
              if (newData == null) {
                casErrorCount++;
                continue;
              }
              final affected = await _ref
                  .read(messageBlockRepositoryProvider)
                  .updateDataIfUnchanged(
                    id: row.rowId,
                    expectedData: row.dataText,
                    newData: newData,
                  );
              if (invalidated()) {
                return false;
              }
              if (affected > 0) {
                casSuccessCount++;
              } else {
                casStaleCount++;
                debugStaleWriteBackSkipCount++;
              }
            } on Object {
              casErrorCount++;
            }
          }
          return true;
        }

        if (!await runCasPass(backingRows)) {
          return;
        }

        if (casSuccessCount == 0 && casErrorCount == 0 && casStaleCount > 0) {
          // B3：全部 stale ≠ 一定是换图。重新读取目标行并按规范化来源
          // 精确比较：来源仍相等（仅 prompt/status/未知键等非来源字段
          // 变化）→ 用新 data 原文重试一次 CAS（仅本轮一次）；来源已变
          // 或行已删 → 重查结果为空，维持 stale 丢弃。
          // 注意：重查为空绝不视为「无 backing row」，不得据此提交内存。
          List<_BackingBlockRow> refreshedRows;
          try {
            refreshedRows = await _resolveBackingRows(candidate);
          } on Object {
            refreshedRows = const <_BackingBlockRow>[];
          }
          if (invalidated()) {
            return;
          }
          if (refreshedRows.isNotEmpty && !await runCasPass(refreshedRows)) {
            return;
          }
        }

        if (casSuccessCount > 0 || casErrorCount > 0) {
          // ≥1 行成功，或有行但仅异常无成功行（内存降级）：
          // 分类完成后才写状态表尺寸。
          _storeResolvedDimensions(conversationId, candidate, dimensions);
          anyResolvedStored = true;
        }
        // 全部 stale（成功 0 且异常 0）：不进内存、不写状态表尺寸。
      }

      if (!anyResolvedStored) {
        // 全败/全 stale 的维护轮：不替换快照、不发通知（无自激）。
        return;
      }
      if (invalidated()) {
        return;
      }
      final current = _snapshotsByConversation[conversationId];
      if (current == null) {
        return;
      }
      // 对照当前快照按精确来源校验应用（经安装回放），有实际变化才通知。
      final installed = _installSnapshot(
        conversationId,
        current,
        scheduleMaintenance: false,
      );
      if (!identical(installed, current)) {
        _notifyConversationChanged(conversationId);
      }
    } on Object {
      // 维护轮绝不向外抛异常。
    }
  }

  List<_DimensionUpgradeCandidate> _collectUpgradeCandidates(
    String conversationId,
    _ConversationTimelineSnapshot snapshot,
  ) {
    final states = _sourceProbeStates[conversationId];
    final seenKeys = <String>{};
    final result = <_DimensionUpgradeCandidate>[];
    for (final message in snapshot.messages) {
      final blocks = message.blocks;
      if (blocks == null || blocks.isEmpty) {
        continue;
      }
      for (final block in blocks) {
        if (block is! ImageBlock || _hasImageDimensions(block)) {
          continue;
        }
        final parts = _sourcePartsForBlock(block);
        if (parts == null || !parts.hasProbeSource) {
          // 仅 http(s) 远程图：不做隐式下载取尺寸，永不成为候选。
          continue;
        }
        final rawMessageId = _messageRawSourceId(message);
        final sourceKey = '$rawMessageId|${parts.fingerprint}';
        if (states != null && states.containsKey(sourceKey)) {
          // 已 attempted（或已有尺寸待回放）：不再探测；S2 触碰保持 LRU 语义。
          _touchSourceState(states, sourceKey);
          continue;
        }
        if (!seenKeys.add(sourceKey)) {
          continue;
        }
        result.add(
          _DimensionUpgradeCandidate(
            sourceKey: sourceKey,
            rawMessageId: rawMessageId,
            sourceTriple: parts.triple,
            probeInput: _probeInputForBlock(block),
          ),
        );
      }
    }
    return result;
  }

  bool _hasDimensionUpgradeCandidates(
    String conversationId,
    _ConversationTimelineSnapshot snapshot,
  ) {
    final states = _sourceProbeStates[conversationId];
    for (final message in snapshot.messages) {
      final blocks = message.blocks;
      if (blocks == null || blocks.isEmpty) {
        continue;
      }
      for (final block in blocks) {
        if (block is! ImageBlock || _hasImageDimensions(block)) {
          continue;
        }
        final parts = _sourcePartsForBlock(block);
        if (parts == null || !parts.hasProbeSource) {
          continue;
        }
        final sourceKey =
            '${_messageRawSourceId(message)}|${parts.fingerprint}';
        if (states != null && states.containsKey(sourceKey)) {
          _touchSourceState(states, sourceKey);
          continue;
        }
        return true;
      }
    }
    return false;
  }

  ImageDimensionProbeInput _probeInputForBlock(ImageBlock block) {
    final url = block.url?.trim();
    return ImageDimensionProbeInput(
      localPath: block.localPath,
      fileUrl: (url != null && url.startsWith('file://')) ? url : null,
      base64: block.base64,
    );
  }

  /// 解析候选来源的 backing rows：该 raw 消息未软删的 image 行中，
  /// 来源精确匹配（规范化比较器）的行；捕获行 id 与 data 原文供 CAS。
  Future<List<_BackingBlockRow>> _resolveBackingRows(
    _DimensionUpgradeCandidate candidate,
  ) async {
    final rows = await _ref
        .read(messageBlockRepositoryProvider)
        .getByMessage(candidate.rawMessageId);
    final matches = <_BackingBlockRow>[];
    for (final row in rows) {
      // S3：DB type 列与 data JSON type 双校验，防导入脏数据两者不一致时误写。
      if (row.type != 'image') {
        continue;
      }
      _SourceTriple rowTriple;
      try {
        final parsed = jsonDecode(row.data);
        if (parsed is! Map<String, dynamic>) {
          continue;
        }
        if (parsed['type'] != 'image') {
          continue;
        }
        rowTriple = _SourceTriple(
          localPath: parsed['localPath'] as String?,
          url: parsed['url'] as String?,
          base64: parsed['base64'] as String?,
        );
      } on Object {
        continue;
      }
      if (!_sourceTriplesExactlyEqual(rowTriple, candidate.sourceTriple)) {
        continue;
      }
      matches.add(_BackingBlockRow(rowId: row.id, dataText: row.data));
    }
    return matches;
  }

  /// merge contract：在行 data 原文解出的 Map 上仅覆盖 width/height 两键
  /// 为正整数；其余键（含未知键）原样保留。解析失败返回 null。
  String? _mergeDimensionsIntoBlockData(
    String dataText,
    ({int width, int height}) dimensions,
  ) {
    try {
      final parsed = jsonDecode(dataText);
      if (parsed is! Map<String, dynamic>) {
        return null;
      }
      parsed['width'] = dimensions.width;
      parsed['height'] = dimensions.height;
      return jsonEncode(parsed);
    } on Object {
      return null;
    }
  }

  LinkedHashMap<String, _SourceProbeState> _sourceStatesFor(
    String conversationId,
  ) {
    return _sourceProbeStates.putIfAbsent(
      conversationId,
      LinkedHashMap<String, _SourceProbeState>.new,
    );
  }

  void _markSourceAttempted(
    String conversationId,
    _DimensionUpgradeCandidate candidate,
  ) {
    final states = _sourceStatesFor(conversationId);
    final existing = states.remove(candidate.sourceKey);
    states[candidate.sourceKey] = _SourceProbeState(
      attempted: true,
      dimensions: existing?.dimensions,
      sourceRef: candidate.sourceTriple,
    );
    _evictSourceStatesOverCapacity(conversationId, states);
  }

  void _storeResolvedDimensions(
    String conversationId,
    _DimensionUpgradeCandidate candidate,
    ({int width, int height}) dimensions,
  ) {
    final states = _sourceStatesFor(conversationId);
    states.remove(candidate.sourceKey);
    states[candidate.sourceKey] = _SourceProbeState(
      attempted: true,
      dimensions: dimensions,
      sourceRef: candidate.sourceTriple,
    );
    _evictSourceStatesOverCapacity(conversationId, states);
  }

  /// S2：命中即触碰（remove＋重插到尾部），维持真 LRU 语义。
  void _touchSourceState(
    LinkedHashMap<String, _SourceProbeState> states,
    String sourceKey,
  ) {
    final state = states.remove(sourceKey);
    if (state != null) {
      states[sourceKey] = state;
    }
  }

  /// B2：软上限淘汰——当前快照中仍缺尺寸的「活跃」来源不可逐出。
  ///
  /// 若逐出活跃失败源，它会立刻重新成为候选并与尾接力形成永久重探测
  /// 循环；活跃源数量超过容量时允许暂时超限，收敛性优先于硬容量。
  void _evictSourceStatesOverCapacity(
    String conversationId,
    LinkedHashMap<String, _SourceProbeState> states,
  ) {
    final capacity = sourceProbeStateCapacityPerConversation < 1
        ? 1
        : sourceProbeStateCapacityPerConversation;
    if (states.length <= capacity) {
      return;
    }
    Set<String>? activeKeys;
    final removableKeys = <String>[];
    for (final sourceKey in states.keys) {
      if (states.length - removableKeys.length <= capacity) {
        break;
      }
      activeKeys ??= _activeMissingDimensionSourceKeys(conversationId);
      if (activeKeys.contains(sourceKey)) {
        continue;
      }
      removableKeys.add(sourceKey);
    }
    for (final sourceKey in removableKeys) {
      states.remove(sourceKey);
    }
  }

  /// 当前已安装快照中仍缺尺寸的来源 key 集合（活跃来源）。
  Set<String> _activeMissingDimensionSourceKeys(String conversationId) {
    final snapshot = _snapshotsByConversation[conversationId];
    if (snapshot == null) {
      return const <String>{};
    }
    final keys = <String>{};
    for (final message in snapshot.messages) {
      final blocks = message.blocks;
      if (blocks == null || blocks.isEmpty) {
        continue;
      }
      for (final block in blocks) {
        if (block is! ImageBlock || _hasImageDimensions(block)) {
          continue;
        }
        final parts = _sourcePartsForBlock(block);
        if (parts == null) {
          continue;
        }
        keys.add('${_messageRawSourceId(message)}|${parts.fingerprint}');
      }
    }
    return keys;
  }

  /// 按来源状态表回放已解析尺寸：对快照内缺尺寸的图片块，来源 key 命中
  /// 且规范化精确比较（无大分配的流式比较器）通过时补上宽高。
  /// 无任何变化返回 null。
  _ConversationTimelineSnapshot? _replaySnapshotWithResolvedDimensions(
    String conversationId,
    _ConversationTimelineSnapshot snapshot,
  ) {
    final states = _sourceProbeStates[conversationId];
    if (states == null || states.isEmpty) {
      return null;
    }
    var changed = false;
    final nextMessages = <Message>[];
    for (final message in snapshot.messages) {
      final blocks = message.blocks;
      if (blocks == null || blocks.isEmpty) {
        nextMessages.add(message);
        continue;
      }
      var messageChanged = false;
      final nextBlocks = <MessageBlock>[];
      for (final block in blocks) {
        if (block is ImageBlock && !_hasImageDimensions(block)) {
          final parts = _sourcePartsForBlock(block);
          if (parts != null) {
            final sourceKey =
                '${_messageRawSourceId(message)}|${parts.fingerprint}';
            final state = states[sourceKey];
            final dimensions = state?.dimensions;
            if (state != null &&
                dimensions != null &&
                _sourceTriplesExactlyEqual(state.sourceRef, parts.triple)) {
              // S2：回放命中触碰条目。
              _touchSourceState(states, sourceKey);
              messageChanged = true;
              changed = true;
              nextBlocks.add(
                ImageBlock(
                  id: block.id,
                  messageId: block.messageId,
                  url: block.url,
                  localPath: block.localPath,
                  base64: block.base64,
                  width: dimensions.width,
                  height: dimensions.height,
                  prompt: block.prompt,
                  generationSnapshot: block.generationSnapshot,
                  status: block.status,
                ),
              );
              continue;
            }
          }
        }
        nextBlocks.add(block);
      }
      nextMessages.add(
        messageChanged ? message.copyWith(blocks: nextBlocks) : message,
      );
    }
    if (!changed) {
      return null;
    }
    return snapshot.copyWith(messages: nextMessages);
  }

  // ---------------------------------------------------------------------------
  // 来源身份：复合指纹（索引层）＋规范化精确比较器（正确性层）
  //
  // B4 契约：索引路径（候选扫描/状态表/回放判断）不构造完整规范化
  // payload 副本——base64 只产出「长度＋采样哈希」紧凑元数据；精确门用
  // 无大分配的流式比较器；状态表持有原始来源引用而非全量签名。
  // ---------------------------------------------------------------------------

  /// 按块实例缓存来源身份部件（块不可变，安全；Expando 弱引用不延长块生命）。
  _ImageSourceParts? _sourcePartsForBlock(ImageBlock block) {
    final cached = _sourcePartsByBlock[block];
    if (cached != null) {
      return cached;
    }
    final parts = _buildSourceParts(
      localPath: block.localPath,
      url: block.url,
      base64: block.base64,
    );
    if (parts != null) {
      _sourcePartsByBlock[block] = parts;
    }
    return parts;
  }

  _ImageSourceParts? _buildSourceParts({
    String? localPath,
    String? url,
    String? base64,
  }) {
    final normalizedLocalPath = _normalizeLocalPathValue(localPath);
    final trimmedUrl = url?.trim();
    final isFileUrl = trimmedUrl != null && trimmedUrl.startsWith('file://');
    final normalizedFileUrlPath = isFileUrl
        ? _normalizeLocalPathValue(trimmedUrl)
        : null;
    final remoteUrl =
        (trimmedUrl != null && trimmedUrl.isNotEmpty && !isFileUrl)
        ? trimmedUrl
        : null;
    // 流式采样：不构造完整规范化 payload 副本。
    final base64Metadata = _sampledBase64Metadata(base64);

    final fingerprintParts = <String>[];
    if (normalizedLocalPath != null) {
      fingerprintParts.add('lp:$normalizedLocalPath');
    }
    if (normalizedFileUrlPath != null &&
        normalizedFileUrlPath != normalizedLocalPath) {
      fingerprintParts.add('lp:$normalizedFileUrlPath');
    }
    if (remoteUrl != null) {
      fingerprintParts.add('url:$remoteUrl');
    }
    if (base64Metadata != null) {
      fingerprintParts.add(
        'b64:${base64Metadata.length}:${base64Metadata.hashHex}',
      );
    }
    if (fingerprintParts.isEmpty) {
      return null;
    }
    return _ImageSourceParts(
      fingerprint: fingerprintParts.join('\u0000'),
      triple: _SourceTriple(localPath: localPath, url: url, base64: base64),
      hasProbeSource:
          normalizedLocalPath != null ||
          normalizedFileUrlPath != null ||
          base64Metadata != null,
    );
  }

  Future<_ConversationTimelineSnapshot> _expandSnapshotFromDb(
    _ConversationTimelineSnapshot snapshot, {
    required int minMessages,
  }) async {
    var current = snapshot;
    while (current.loadedRawMessageCount < minMessages &&
        current.hasMoreMessages) {
      final oldestCursor = current.oldestRawCursor;
      if (oldestCursor == null || current.messages.isEmpty) {
        current = current.copyWith(hasMoreMessages: false);
        break;
      }

      final page = await _loadOlderPageFromDb(
        current.conversationId,
        beforeCursor: oldestCursor,
        pageSize: _maxInt(5, minMessages - current.loadedRawMessageCount),
      );
      if (page.messages.isEmpty) {
        current = current.copyWith(hasMoreMessages: false);
        break;
      }
      current = current.copyWith(
        messages: _normalizeMessages(<Message>[
          ...page.messages,
          ...current.messages,
        ]),
        hasMoreMessages: page.hasMoreMessages,
        oldestRawCursor: page.oldestRawCursor ?? current.oldestRawCursor,
        loadedRawMessageCount:
            current.loadedRawMessageCount + page.loadedRawMessageCount,
      );
    }

    // 纯计算：不安装、不调度，由调用方统一安装。
    return current;
  }

  Future<_ConversationTimelineSnapshot> _loadRecentSnapshotFromDb(
    String conversationId, {
    required int targetCount,
    Map<String, Object?>? coldLoadMetrics,
  }) async {
    if (!_visibilityByConversation.containsKey(conversationId)) {
      await _loadVisibility(conversationId);
    }
    final normalizedTargetCount = targetCount < 1 ? 1 : targetCount;
    final clock = Stopwatch()..start();
    final dbMessages = await _ref
        .read(messageRepositoryProvider)
        .getByConversationForDisplay(
          conversationId,
          limit: normalizedTargetCount + 1,
        );
    coldLoadMetrics?.addAll({
      'rawReadMs': clock.elapsedMilliseconds,
      'rawReadCount': dbMessages.length,
    });
    final hasMoreMessages = dbMessages.length > normalizedTargetCount;
    final trimmedDbMessages = hasMoreMessages
        ? dbMessages.take(normalizedTargetCount).toList(growable: false)
        : dbMessages;
    final orderedDbMessages = trimmedDbMessages.reversed.toList(
      growable: false,
    );
    final orderedMessages = await _buildMessagesFromDb(
      orderedDbMessages,
      coldLoadMetrics: coldLoadMetrics,
    );

    return _ConversationTimelineSnapshot(
      conversationId: conversationId,
      messages: orderedMessages,
      hasMoreMessages: hasMoreMessages,
      oldestRawCursor: _rawCursorFromDbMessage(
        orderedDbMessages.isEmpty ? null : orderedDbMessages.first,
      ),
      loadedRawMessageCount: orderedDbMessages.length,
    );
  }

  Future<_OlderPageResult> _loadOlderPageFromDb(
    String conversationId, {
    required _RawMessageCursor beforeCursor,
    required int pageSize,
  }) async {
    final normalizedPageSize = pageSize < 1 ? 1 : pageSize;
    final dbMessages = await _ref
        .read(messageRepositoryProvider)
        .getByConversationForDisplay(
          conversationId,
          limit: normalizedPageSize + 1,
          beforeTime: beforeCursor.createdAt.millisecondsSinceEpoch,
          beforeId: beforeCursor.messageId,
        );
    final hasMoreMessages = dbMessages.length > normalizedPageSize;
    final trimmedDbMessages = hasMoreMessages
        ? dbMessages.take(normalizedPageSize).toList(growable: false)
        : dbMessages;
    final orderedDbMessages = trimmedDbMessages.reversed.toList(
      growable: false,
    );
    final orderedMessages = await _buildMessagesFromDb(orderedDbMessages);

    return _OlderPageResult(
      messages: orderedMessages,
      hasMoreMessages: hasMoreMessages,
      oldestRawCursor: _rawCursorFromDbMessage(
        orderedDbMessages.isEmpty ? null : orderedDbMessages.first,
      ),
      loadedRawMessageCount: orderedDbMessages.length,
    );
  }

  /// 内容路径的快照归一化＋投影映射同步。
  ///
  /// 原 `_persistSnapshotUnlocked` 按职责拆分后的产物：不再内联图片尺寸
  /// 升级（几何维护移入独立维护轮，且不触碰投影映射）。
  Future<_ConversationTimelineSnapshot> _normalizeAndSyncSnapshotUnlocked(
    _ConversationTimelineSnapshot snapshot, {
    Set<String>? affectedRawMessageIds,
  }) async {
    final normalizedSnapshot = _buildInMemorySnapshot(snapshot);
    await _syncProjectionMappingsUnlocked(
      normalizedSnapshot,
      affectedRawMessageIds: affectedRawMessageIds,
    );
    return normalizedSnapshot;
  }

  _ConversationTimelineSnapshot _buildInMemorySnapshot(
    _ConversationTimelineSnapshot snapshot,
  ) {
    final normalizedMessages = _normalizeMessages(snapshot.messages);
    return _ConversationTimelineSnapshot(
      conversationId: snapshot.conversationId,
      messages: normalizedMessages,
      hasMoreMessages:
          snapshot.hasMoreMessages &&
          (normalizedMessages.isNotEmpty || snapshot.oldestRawCursor != null),
      oldestRawCursor:
          snapshot.oldestRawCursor ??
          _estimateOldestRawCursor(normalizedMessages),
      loadedRawMessageCount: snapshot.loadedRawMessageCount > 0
          ? snapshot.loadedRawMessageCount
          : _estimateLoadedRawMessageCount(normalizedMessages),
    );
  }

  bool _hasImageDimensions(ImageBlock block) {
    final width = block.width;
    final height = block.height;
    return width != null && width > 0 && height != null && height > 0;
  }

  Future<List<Message>> _buildMessagesFromDb(
    List<db.Message> dbMessages, {
    Map<String, Object?>? coldLoadMetrics,
  }) async {
    coldLoadMetrics?.addAll({
      'rawCount': dbMessages.length,
      'rawPayloadChars': dbMessages.fold<int>(
        0,
        (n, m) => n + (m.rawPayload?.length ?? 0),
      ),
      'blockReadMs': 0,
      'blockCount': 0,
      'blockDataChars': 0,
      'decodeMs': 0,
      'projectionMs': 0,
      'projectedCount': 0,
    });
    if (dbMessages.isEmpty) {
      return const <Message>[];
    }

    final clock = Stopwatch()..start();
    final messageIds = dbMessages
        .map((message) => message.id)
        .toList(growable: false);
    final dbBlocks = await _ref
        .read(messageBlockRepositoryProvider)
        .getByMessages(messageIds);
    coldLoadMetrics?.addAll({
      'blockReadMs': clock.elapsedMilliseconds,
      'blockCount': dbBlocks.length,
      'blockDataChars': dbBlocks.fold<int>(0, (n, b) => n + b.data.length),
    });
    var result = await decodeHistoryDisplay(
      HistoryDisplayBatch(
        dbMessages,
        dbBlocks,
        collectStats: coldLoadMetrics != null,
      ),
    );
    final fallbackCount = result.fallbackIds.length;
    if (fallbackCount > 0) {
      final initialMetrics = result.metrics;
      clock.reset();
      final fallbackIds = result.fallbackIds.toSet();
      final repository = _ref.read(messageRepositoryProvider);
      final completeRows = <db.Message>[];
      for (final row in dbMessages) {
        final complete = fallbackIds.contains(row.id)
            ? await repository.getById(row.id)
            : row;
        if (complete != null) completeRows.add(complete);
      }
      if (coldLoadMetrics != null) {
        coldLoadMetrics['rawReadMs'] =
            (coldLoadMetrics['rawReadMs'] as int? ?? 0) +
            clock.elapsedMilliseconds;
        coldLoadMetrics['rawPayloadChars'] = completeRows.fold<int>(
          0,
          (n, m) => n + (m.rawPayload?.length ?? 0),
        );
      }
      result = await decodeHistoryDisplay(
        HistoryDisplayBatch(
          completeRows,
          dbBlocks,
          collectStats: coldLoadMetrics != null,
        ),
      );
      for (final key in [
        'decodeMs',
        'projectionMs',
        'payloadStatsMs',
        'workerMs',
      ]) {
        if (result.metrics[key] is int && initialMetrics[key] is int) {
          result.metrics[key] =
              (result.metrics[key] as int) + (initialMetrics[key] as int);
        }
      }
      result.metrics['backgroundDecode'] =
          result.metrics['backgroundDecode'] == true ||
          initialMetrics['backgroundDecode'] == true;
    }
    coldLoadMetrics?.addAll({
      ...result.metrics,
      'displayRead': true,
      'displayFallbackCount': fallbackCount,
    });
    return result.messages;
  }

  Future<void> _syncProjectionMappingsUnlocked(
    _ConversationTimelineSnapshot snapshot, {
    Set<String>? affectedRawMessageIds,
  }) async {
    final normalizedAffectedRawIds = affectedRawMessageIds == null
        ? null
        : {
            for (final rawMessageId in affectedRawMessageIds)
              if (rawMessageId.trim().isNotEmpty) rawMessageId.trim(),
          };
    if (normalizedAffectedRawIds != null && normalizedAffectedRawIds.isEmpty) {
      return;
    }
    final segmentIndexesByRawMessageId = <String, int>{};
    final mappingsByRawMessageId =
        <String, List<db.MessageProjectionMappingsCompanion>>{};
    for (final message in snapshot.messages) {
      final rawMessageId = message.sourceMessageId?.trim();
      if (rawMessageId == null || rawMessageId.isEmpty) {
        continue;
      }
      if (normalizedAffectedRawIds != null &&
          !normalizedAffectedRawIds.contains(rawMessageId)) {
        continue;
      }
      final segmentIndex = segmentIndexesByRawMessageId.update(
        rawMessageId,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      mappingsByRawMessageId
          .putIfAbsent(
            rawMessageId,
            () => <db.MessageProjectionMappingsCompanion>[],
          )
          .add(
            db.MessageProjectionMappingsCompanion.insert(
              id: '$rawMessageId::${message.id}',
              conversationId: snapshot.conversationId,
              rawMessageId: rawMessageId,
              projectedMessageId: message.id,
              projectionKind: Value(_projectionKindFor(message)),
              segmentIndex: Value(segmentIndex),
              projectionVersion: const Value(null),
              createdAt: message.createdAt.millisecondsSinceEpoch,
            ),
          );
    }
    if (normalizedAffectedRawIds != null) {
      for (final rawMessageId in normalizedAffectedRawIds) {
        mappingsByRawMessageId.putIfAbsent(
          rawMessageId,
          () => <db.MessageProjectionMappingsCompanion>[],
        );
      }
    }
    final repository = _ref.read(messageProjectionMappingRepositoryProvider);
    for (final entry in mappingsByRawMessageId.entries) {
      await repository.replaceForRawMessage(
        rawMessageId: entry.key,
        mappings: entry.value,
      );
    }
  }

  _RawMessageCursor? _rawCursorFromDbMessage(db.Message? message) {
    if (message == null) {
      return null;
    }
    return _RawMessageCursor(
      messageId: message.id,
      createdAt: DateTime.fromMillisecondsSinceEpoch(message.createdAt),
    );
  }

  _RawMessageCursor? _estimateOldestRawCursor(Iterable<Message> messages) {
    for (final message in messages) {
      final rawMessageId = (message.sourceMessageId?.trim().isNotEmpty ?? false)
          ? message.sourceMessageId!.trim()
          : message.id;
      if (rawMessageId.trim().isEmpty) {
        continue;
      }
      return _RawMessageCursor(
        messageId: rawMessageId,
        createdAt: message.createdAt,
      );
    }
    return null;
  }

  int _estimateLoadedRawMessageCount(Iterable<Message> messages) {
    final rawMessageIds = <String>{};
    for (final message in messages) {
      final rawMessageId = (message.sourceMessageId?.trim().isNotEmpty ?? false)
          ? message.sourceMessageId!.trim()
          : message.id.trim();
      if (rawMessageId.isNotEmpty) {
        rawMessageIds.add(rawMessageId);
      }
    }
    return rawMessageIds.length;
  }

  StreamController<void> _controllerFor(String conversationId) {
    return _changeControllers.putIfAbsent(
      conversationId,
      () => StreamController<void>.broadcast(),
    );
  }

  void _notifyConversationChanged(String conversationId) {
    final controller = _changeControllers[conversationId];
    if (controller == null || controller.isClosed) {
      return;
    }
    controller.add(null);
  }

  Future<T> _runConversationTask<T>(
    String conversationId,
    Future<T> Function() action,
  ) {
    final previousTask =
        _conversationTasks[conversationId] ?? Future<void>.value();
    final completer = Completer<T>();
    late final Future<void> currentTask;
    currentTask = previousTask
        .catchError((_) {})
        .then((_) async {
          try {
            completer.complete(await action());
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .whenComplete(() {
          if (identical(_conversationTasks[conversationId], currentTask)) {
            _conversationTasks.remove(conversationId);
          }
        });
    _conversationTasks[conversationId] = currentTask;
    return completer.future;
  }

  _ConversationFrontendVisibilityState _visibilityFor(String conversationId) {
    return _visibilityByConversation[conversationId] ??
        const _ConversationFrontendVisibilityState();
  }
}

class _OlderPageResult {
  const _OlderPageResult({
    required this.messages,
    required this.hasMoreMessages,
    required this.oldestRawCursor,
    required this.loadedRawMessageCount,
  });

  final List<Message> messages;
  final bool hasMoreMessages;
  final _RawMessageCursor? oldestRawCursor;
  final int loadedRawMessageCount;
}

class _ConversationTimelineSnapshot {
  const _ConversationTimelineSnapshot({
    required this.conversationId,
    required this.messages,
    required this.hasMoreMessages,
    required this.oldestRawCursor,
    required this.loadedRawMessageCount,
  });

  final String conversationId;
  final List<Message> messages;
  final bool hasMoreMessages;
  final _RawMessageCursor? oldestRawCursor;
  final int loadedRawMessageCount;

  _ConversationTimelineSnapshot copyWith({
    List<Message>? messages,
    bool? hasMoreMessages,
    _RawMessageCursor? oldestRawCursor,
    int? loadedRawMessageCount,
  }) {
    return _ConversationTimelineSnapshot(
      conversationId: conversationId,
      messages: messages ?? this.messages,
      hasMoreMessages: hasMoreMessages ?? this.hasMoreMessages,
      oldestRawCursor: oldestRawCursor ?? this.oldestRawCursor,
      loadedRawMessageCount:
          loadedRawMessageCount ?? this.loadedRawMessageCount,
    );
  }
}

/// 图片来源三元组：原始来源引用（不做拷贝）。
///
/// 精确门比较时经流式规范化比较器逐项核对，不构造大字符串副本。
class _SourceTriple {
  const _SourceTriple({
    required this.localPath,
    required this.url,
    required this.base64,
  });

  final String? localPath;
  final String? url;
  final String? base64;
}

/// 来源状态表条目：attempted 与成功尺寸合一（同进同出）。
class _SourceProbeState {
  const _SourceProbeState({
    required this.attempted,
    required this.dimensions,
    required this.sourceRef,
  });

  final bool attempted;
  final ({int width, int height})? dimensions;

  /// 原始来源引用：回放/应用前的正确性门（流式精确比较）。
  final _SourceTriple sourceRef;
}

/// 来源身份部件：指纹（索引层，含 base64 紧凑采样元数据）＋原始来源
/// 三元组（正确性层输入）。
class _ImageSourceParts {
  const _ImageSourceParts({
    required this.fingerprint,
    required this.triple,
    required this.hasProbeSource,
  });

  final String fingerprint;
  final _SourceTriple triple;

  /// 是否存在本地类可探测来源（localPath / file:// / base64）。
  final bool hasProbeSource;
}

class _DimensionUpgradeCandidate {
  const _DimensionUpgradeCandidate({
    required this.sourceKey,
    required this.rawMessageId,
    required this.sourceTriple,
    required this.probeInput,
  });

  final String sourceKey;
  final String rawMessageId;
  final _SourceTriple sourceTriple;
  final ImageDimensionProbeInput probeInput;
}

class _BackingBlockRow {
  const _BackingBlockRow({required this.rowId, required this.dataText});

  final String rowId;
  final String dataText;
}

class _ConversationFrontendVisibilityState {
  const _ConversationFrontendVisibilityState({
    this.hiddenRawMessageIds = const <String>{},
    this.hiddenProjectedMessageIds = const <String>{},
  });

  final Set<String> hiddenRawMessageIds;
  final Set<String> hiddenProjectedMessageIds;

  _ConversationFrontendVisibilityState merge({
    Set<String> hiddenRawMessageIds = const <String>{},
    Set<String> hiddenProjectedMessageIds = const <String>{},
  }) {
    return _ConversationFrontendVisibilityState(
      hiddenRawMessageIds: {
        ...this.hiddenRawMessageIds,
        ...hiddenRawMessageIds,
      },
      hiddenProjectedMessageIds: {
        ...this.hiddenProjectedMessageIds,
        ...hiddenProjectedMessageIds,
      },
    );
  }
}

class _RawMessageCursor {
  const _RawMessageCursor({required this.messageId, required this.createdAt});

  final String messageId;
  final DateTime createdAt;
}

ConversationTimelineWindowState _buildWindow(
  _ConversationTimelineSnapshot snapshot, {
  required int limit,
  required _ConversationFrontendVisibilityState visibility,
}) {
  final normalizedLimit = limit < 1 ? 1 : limit;
  final filteredMessages = _filterMessagesByVisibility(
    snapshot.messages,
    visibility,
  );
  final visibleMessages = List<Message>.unmodifiable(
    _selectNewestProjectedMessagesByRawWindow(
      filteredMessages,
      rawMessageLimit: normalizedLimit,
    ),
  );
  final visibleRawCount = _countVisibleRawMessages(filteredMessages);
  return ConversationTimelineWindowState(
    messages: visibleMessages,
    hasMoreMessages:
        snapshot.hasMoreMessages || visibleRawCount > normalizedLimit,
  );
}

List<Message> _filterMessagesByVisibility(
  List<Message> messages,
  _ConversationFrontendVisibilityState visibility,
) {
  if (messages.isEmpty ||
      (visibility.hiddenRawMessageIds.isEmpty &&
          visibility.hiddenProjectedMessageIds.isEmpty)) {
    return messages;
  }

  return <Message>[
    for (final message in messages)
      if (!_isMessageHiddenByFrontendVisibility(message, visibility)) message,
  ];
}

bool _isMessageHiddenByFrontendVisibility(
  Message message,
  _ConversationFrontendVisibilityState visibility,
) {
  final rawMessageId = _messageRawSourceId(message);
  if (visibility.hiddenRawMessageIds.contains(rawMessageId)) {
    return true;
  }
  return visibility.hiddenProjectedMessageIds.contains(message.id);
}

int _countVisibleRawMessages(Iterable<Message> messages) {
  final rawMessageIds = <String>{};
  for (final message in messages) {
    rawMessageIds.add(_messageRawSourceId(message));
  }
  return rawMessageIds.length;
}

List<Message> _selectNewestProjectedMessagesByRawWindow(
  List<Message> messages, {
  required int rawMessageLimit,
}) {
  if (messages.isEmpty) {
    return const <Message>[];
  }

  final normalizedLimit = rawMessageLimit < 1 ? 1 : rawMessageLimit;
  final selectedRawIds = <String>{};
  var firstSelectedIndex = messages.length;
  for (var index = messages.length - 1; index >= 0; index -= 1) {
    final rawId = _messageRawSourceId(messages[index]);
    if (selectedRawIds.add(rawId)) {
      firstSelectedIndex = index;
      if (selectedRawIds.length >= normalizedLimit) {
        break;
      }
    } else if (selectedRawIds.isNotEmpty) {
      firstSelectedIndex = index;
    }
  }

  if (selectedRawIds.isEmpty) {
    return const <Message>[];
  }

  return <Message>[
    for (var index = firstSelectedIndex; index < messages.length; index += 1)
      if (selectedRawIds.contains(_messageRawSourceId(messages[index])))
        messages[index],
  ];
}

String _messageRawSourceId(Message message) {
  final sourceMessageId = message.sourceMessageId?.trim();
  if (sourceMessageId != null && sourceMessageId.isNotEmpty) {
    return sourceMessageId;
  }
  return message.id.trim();
}

List<Message> _normalizeMessages(Iterable<Message> messages) {
  final deduped = <String, ({int index, Message message})>{};
  var index = 0;
  for (final message in messages) {
    deduped[_timelineMessageDedupeKey(message)] = (
      index: index,
      message: message,
    );
    index += 1;
  }
  final normalizedEntries = deduped.values.toList(growable: false)
    ..sort((left, right) {
      final byTime = left.message.createdAt.compareTo(right.message.createdAt);
      if (byTime != 0) {
        return byTime;
      }
      return left.index.compareTo(right.index);
    });
  return <Message>[for (final entry in normalizedEntries) entry.message];
}

String _timelineMessageDedupeKey(Message message) {
  final sourceMessageId = message.sourceMessageId?.trim();
  if (sourceMessageId == null ||
      sourceMessageId.isEmpty ||
      sourceMessageId == message.id) {
    return 'id:${message.id}';
  }
  return jsonEncode(<String, Object?>{
    'sourceMessageId': sourceMessageId,
    'role': message.role,
    'kind': _projectionKindFor(message),
    'content': message.content,
    'blocks': <Map<String, dynamic>>[
      for (final block in message.blocks ?? const <MessageBlock>[])
        block.toJson(),
    ],
  });
}

int _maxInt(int left, int right) => left > right ? left : right;

String _projectionKindFor(Message message) {
  final blocks = message.blocks;
  if (blocks != null && blocks.isNotEmpty) {
    final first = blocks.first;
    if (first is ImageBlock) return 'image';
    if (first is AudioBlock) return 'audio';
    if (first is EmojiBlock) return 'emoji';
    if (first is FileBlock) return 'file';
    if (first is ToolBlock) return 'tool';
  }
  return 'text';
}

/// 规范化本地路径：trim → `file://` 先 `Uri.toFilePath()`（含 percent-decode）
/// → `package:path` 按当前平台 normalize+absolute → Windows 额外统一分隔符、
/// 不区分大小写折叠（盘符保留大写）。不解析符号链接。
String? _normalizeLocalPathValue(String? raw) {
  final trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  var candidate = trimmed;
  if (candidate.startsWith('file://')) {
    try {
      candidate = Uri.parse(candidate).toFilePath();
    } on Object {
      return null;
    }
  }
  if (candidate.trim().isEmpty) {
    return null;
  }
  String normalized;
  try {
    normalized = p.normalize(p.absolute(candidate));
  } on Object {
    return null;
  }
  if (p.context.style == p.Style.windows) {
    normalized = normalized.replaceAll('/', r'\').toLowerCase();
    if (normalized.length >= 2 && normalized.codeUnitAt(1) == 0x3a) {
      normalized = normalized[0].toUpperCase() + normalized.substring(1);
    }
  }
  return normalized;
}

/// base64 身份用的空白判定（ASCII 空白集）。
///
/// 流式指纹与流式精确比较器共用同一定义，保证两层结论一致。
bool _isBase64WhitespaceCodeUnit(int codeUnit) {
  return codeUnit == 0x20 || // space
      codeUnit == 0x09 || // \t
      codeUnit == 0x0a || // \n
      codeUnit == 0x0d || // \r
      codeUnit == 0x0b || // \v
      codeUnit == 0x0c; // \f
}

/// 返回规范化 payload 的起始下标：跳过前导空白与 `data:` 前缀。
/// data URL 无逗号（malformed）返回 -1，按无有效 payload 处理。
int _base64PayloadStart(String raw) {
  var index = 0;
  while (index < raw.length &&
      _isBase64WhitespaceCodeUnit(raw.codeUnitAt(index))) {
    index += 1;
  }
  if (raw.startsWith('data:', index)) {
    final commaIndex = raw.indexOf(',', index);
    if (commaIndex < 0) {
      return -1;
    }
    return commaIndex + 1;
  }
  return index;
}

/// 是否存在非空白的规范化 payload 内容（零分配）。
bool _hasNormalizedBase64Content(String? raw) {
  if (raw == null || raw.isEmpty) {
    return false;
  }
  var index = _base64PayloadStart(raw);
  if (index < 0) {
    return false;
  }
  while (index < raw.length) {
    if (!_isBase64WhitespaceCodeUnit(raw.codeUnitAt(index))) {
      return true;
    }
    index += 1;
  }
  return false;
}

/// 流式计算 base64 来源的紧凑索引元数据：规范化长度＋FNV-1a 64 采样哈希
/// （前 4096＋后 4096 规范化 code unit＋长度）。
///
/// B4：单遍扫描、零 O(n) 字符串分配（固定 4096 槽环形缓冲），与
/// 「先全量规范化再采样」的实现产出一致的哈希。FNV 用 32 位半字拆分
/// 乘法，VM 与 Web（JS 数值语义）结果一致；仅作索引用途，碰撞后果限于
/// 多一次/漏一次探测，不参与正确性决策。返回 null 表示无有效 payload。
({int length, String hashHex})? _sampledBase64Metadata(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final start = _base64PayloadStart(raw);
  if (start < 0) {
    return null;
  }

  // FNV-1a 64 offset basis: 0xcbf29ce484222325
  var hi = 0xcbf29ce4;
  var lo = 0x84222325;
  // FNV-1a 64 prime: 0x00000100000001b3 = 2^40 + 0x1b3
  void mixCodeUnit(int codeUnit) {
    lo ^= codeUnit & 0xff;
    final productLow = lo * 0x1b3;
    final carry = productLow ~/ 0x100000000;
    final nextLo = productLow % 0x100000000;
    final nextHi = (lo * 0x100 + hi * 0x1b3 + carry) % 0x100000000;
    hi = nextHi;
    lo = nextLo;
  }

  const sampleSize = 4096;
  final tailRing = List<int>.filled(sampleSize, 0);
  var normalizedLength = 0;
  for (var index = start; index < raw.length; index += 1) {
    final codeUnit = raw.codeUnitAt(index);
    if (_isBase64WhitespaceCodeUnit(codeUnit)) {
      continue;
    }
    if (normalizedLength < sampleSize) {
      mixCodeUnit(codeUnit);
    } else {
      tailRing[(normalizedLength - sampleSize) % sampleSize] = codeUnit;
    }
    normalizedLength += 1;
  }
  if (normalizedLength == 0) {
    return null;
  }
  final tailCount = normalizedLength - sampleSize;
  if (tailCount > 0) {
    // 环形缓冲里保存的是「第 4096 位之后」的最后至多 4096 个规范化单元；
    // 按原顺序回放，等价于旧实现的「后 4096」（或 ≤8192 时的全量）。
    final effectiveTail = tailCount < sampleSize ? tailCount : sampleSize;
    final ringStart = tailCount <= sampleSize ? 0 : tailCount % sampleSize;
    for (var i = 0; i < effectiveTail; i += 1) {
      mixCodeUnit(tailRing[(ringStart + i) % sampleSize]);
    }
  }
  final lengthSuffix = '#$normalizedLength';
  for (var i = 0; i < lengthSuffix.length; i += 1) {
    mixCodeUnit(lengthSuffix.codeUnitAt(i));
  }

  final hashHex =
      hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
  return (length: normalizedLength, hashHex: hashHex);
}

/// 无大分配的规范化 base64 相等比较器：跳过 `data:` 前缀与空白逐字符
/// 比较；裸 base64 无空白的常见情形先走 identical/== 快路径。
bool _normalizedBase64Equals(String left, String right) {
  if (identical(left, right) || left == right) {
    return true;
  }
  var leftIndex = _base64PayloadStart(left);
  var rightIndex = _base64PayloadStart(right);
  if (leftIndex < 0 || rightIndex < 0) {
    // malformed（无有效 payload）只与同为 malformed 的一侧相等。
    return (leftIndex < 0) == (rightIndex < 0);
  }
  while (true) {
    while (leftIndex < left.length &&
        _isBase64WhitespaceCodeUnit(left.codeUnitAt(leftIndex))) {
      leftIndex += 1;
    }
    while (rightIndex < right.length &&
        _isBase64WhitespaceCodeUnit(right.codeUnitAt(rightIndex))) {
      rightIndex += 1;
    }
    final leftDone = leftIndex >= left.length;
    final rightDone = rightIndex >= right.length;
    if (leftDone || rightDone) {
      return leftDone && rightDone;
    }
    if (left.codeUnitAt(leftIndex) != right.codeUnitAt(rightIndex)) {
      return false;
    }
    leftIndex += 1;
    rightIndex += 1;
  }
}

/// 复合来源三元组的规范化精确相等（正确性门）。
///
/// lp 域按字段顺序与去重语义比较（localPath 优先、file:// url 归一）；
/// 远程 url trim 相等；base64 用流式比较器，无大字符串分配。
bool _sourceTriplesExactlyEqual(_SourceTriple left, _SourceTriple right) {
  if (!_stringListEquals(
    _localPathComponentsOf(left),
    _localPathComponentsOf(right),
  )) {
    return false;
  }
  if (_remoteUrlOf(left) != _remoteUrlOf(right)) {
    return false;
  }
  final leftBase64 = left.base64;
  final rightBase64 = right.base64;
  final leftHasPayload = _hasNormalizedBase64Content(leftBase64);
  final rightHasPayload = _hasNormalizedBase64Content(rightBase64);
  if (leftHasPayload != rightHasPayload) {
    return false;
  }
  if (leftHasPayload && !_normalizedBase64Equals(leftBase64!, rightBase64!)) {
    return false;
  }
  return true;
}

List<String> _localPathComponentsOf(_SourceTriple triple) {
  final normalizedLocalPath = _normalizeLocalPathValue(triple.localPath);
  final url = triple.url?.trim();
  final normalizedFileUrlPath = (url != null && url.startsWith('file://'))
      ? _normalizeLocalPathValue(url)
      : null;
  return <String>[
    if (normalizedLocalPath != null) normalizedLocalPath,
    if (normalizedFileUrlPath != null &&
        normalizedFileUrlPath != normalizedLocalPath)
      normalizedFileUrlPath,
  ];
}

String? _remoteUrlOf(_SourceTriple triple) {
  final url = triple.url?.trim();
  if (url == null || url.isEmpty || url.startsWith('file://')) {
    return null;
  }
  return url;
}

bool _stringListEquals(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i += 1) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

final conversationTimelineCacheProvider = Provider<ConversationTimelineCache>((
  ref,
) {
  final store = ConversationTimelineCache(ref);
  ref.onDispose(store.dispose);
  return store;
});
