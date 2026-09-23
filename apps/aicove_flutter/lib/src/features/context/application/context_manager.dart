import '../../../core/app_logger.dart';
import '../../../core/utils/token_estimator.dart';
import '../../chat/domain/message.dart';
import '../domain/context_summary.dart';

/// 压缩成功（摘要已落库）后的通知；长期记忆据此在后台整理，不阻塞调用方。
typedef CompactionListener = void Function(String ownerId);

/// 上下文管理器：手动压缩（翻篇）、自动压缩（腾地方），以及边界缺摘要时的补整理。
/// 摘要只由压缩 Agent 写；长期记忆由监听者在压缩成功后另行维护。
class ContextManager implements ManualCompactionPort, ConversationContextPort {
  ContextManager({
    required this.store,
    required this.loadMessages,
    required this.readBoundary,
    required this.summarizerFactory,
    required this.publishBoundary,
    required this.ensureIdle,
    this.onCompacted,
  });
  final ContextSummaryStorePort store;
  final Future<List<Message>> Function(String ownerId) loadMessages;
  final Future<String?> Function(String ownerId) readBoundary;
  final Future<ContextSummarizerPort> Function() summarizerFactory;
  final Future<void> Function(String ownerId) publishBoundary;
  final void Function(String ownerId) ensureIdle;
  final CompactionListener? onCompacted;
  final _busy = <String>{};

  /// 用户发起的操作：先确认该角色没有在生成回复，再独占执行。
  Future<T> _userAction<T>(String owner, Future<T> Function() action) async {
    ensureIdle(owner);
    return _exclusive(owner, action);
  }

  Future<T> _exclusive<T>(String owner, Future<T> Function() action) async {
    if (!_busy.add(owner)) {
      throw const ContextCompactionException('该角色正在整理上下文，请稍后重试。');
    }
    try {
      return await action();
    } finally {
      _busy.remove(owner);
    }
  }

  void _notify(String owner) {
    try {
      onCompacted?.call(owner);
    } catch (error) {
      AppLogger.warning(
        'ContextManager',
        '压缩已保存，长期记忆整理未能启动',
        metadata: {'conversationId': owner, 'error': error.toString()},
      );
    }
  }

  // ---- 手动压缩 ----

  @override
  Future<ManualCompactionDraft> prepare(
    String ownerId, {
    required void Function(int completed, int total) onProgress,
    required bool Function() isCancelled,
  }) => _userAction(ownerId, () async {
      final snapshot = await store.manualSnapshot(ownerId);
      final summary = await (await summarizerFactory()).summarize(
        snapshot,
        kind: ContextSummaryKind.manual,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      if (isCancelled()) {
        throw const ContextCompactionException('已取消整理。');
      }
      validateContextSummary(summary);
      return ManualCompactionDraft(snapshot: snapshot, summary: summary);
    });

  @override
  Future<ContextSummary> commit(ManualCompactionDraft draft, String summary) {
    final owner = draft.snapshot.ownerId;
    return _userAction(owner, () async {
      final record = await store.commitManual(draft.snapshot, summary);
      // 数据库已原子保存摘要与边界；界面状态刷新失败不能误报为“没有切换”。
      try {
        await publishBoundary(owner);
      } catch (error) {
        AppLogger.warning(
          'ContextManager',
          '压缩已保存，界面状态刷新失败',
          metadata: {
            'conversationId': owner,
            'errorType': error.runtimeType.toString(),
          },
        );
      }
      AppLogger.info(
        'ContextManager',
        '手动压缩完成',
        metadata: {
          'conversationId': owner,
          'summaryId': record.id,
          'sourceCount': record.sourceIds.length,
        },
      );
      _notify(owner);
      return record;
    });
  }

  @override
  Future<ContextSummary?> current(String ownerId) async =>
      store.manualFor(ownerId, await readBoundary(ownerId));

  @override
  Future<void> undo(String ownerId) => _userAction(ownerId, () async {
    await store.undoManual(ownerId);
    await publishBoundary(ownerId);
  });

  // ---- 发送链路 ----

  @override
  Future<ContextSummary?> manualSummary(
    String ownerId,
    String? boundaryId,
    List<Message> history,
  ) async {
    if (boundaryId == null) return null;
    final existing = await store.manualFor(ownerId, boundaryId);
    final summary = existing ?? await _recover(ownerId, boundaryId);
    // 重放旧轮次时，不把覆盖它之后内容的摘要倒灌回去。
    if (summary == null ||
        history.any((m) => summary.sourceIds.contains(m.id))) {
      return null;
    }
    return summary;
  }

  /// 边界存在但没有有效摘要（例如别的设备同步来的边界、来源被编辑过）：
  /// 把边界前最近一段原文整理成摘要，保存后再发送。失败则阻止发送。
  Future<ContextSummary?> _recover(String ownerId, String boundaryId) =>
      _exclusive(ownerId, () async {
        final again = await store.manualFor(ownerId, boundaryId);
        if (again != null) return again;
        final all = await _loadThrough(ownerId, boundaryId);
        if (all == null) return null;
        final eligible = all
            .where(
              (m) =>
                  (m.role == 'user' || m.role == 'assistant') &&
                  m.status != 'failed',
            )
            .toList();
        if (eligible.isEmpty) return null;
        // 只取边界前最近约 24k tokens；更早的内容交给长期记忆。
        var used = 0;
        var start = eligible.length;
        while (start > 0) {
          final size = estimateTokenCount(eligible[start - 1].displayText) + 16;
          if (used + size > 24000 && start < eligible.length) break;
          used += size;
          start--;
        }
        final snapshot = ContextSnapshot(
          ownerId: ownerId,
          previousBoundaryId: null,
          allMessages: all,
          messages: eligible.sublist(start),
          previous: null,
        );
        AppLogger.info(
          'ContextManager',
          '话题边界缺少摘要，补整理后再发送',
          metadata: {
            'conversationId': ownerId,
            'messages': snapshot.messages.length,
          },
        );
        try {
          final summary = await (await summarizerFactory()).summarize(
            snapshot,
            kind: ContextSummaryKind.manual,
            onProgress: (_, __) {},
            isCancelled: () => false,
          );
          final record = await store.saveRecoveredManual(snapshot, summary);
          _notify(ownerId);
          return record;
        } on ContextCompactionException {
          rethrow;
        } catch (error) {
          throw ContextCompactionException(
            '上一段话题的摘要缺失，补整理失败，本轮未发送：$error',
          );
        }
      });

  /// 返回截至边界（含）的原文；边界已不在原文里时返回 null。
  Future<List<Message>?> _loadThrough(String ownerId, String boundaryId) async {
    final all = await loadMessages(ownerId);
    final index = all.indexWhere((m) => m.id == boundaryId);
    return index < 0 ? null : all.sublist(0, index + 1);
  }

  @override
  Future<ContextSummary?> loadAuto(
    String ownerId,
    String? topicBoundary,
    List<Message> history,
  ) => store.loadAuto(ownerId, topicBoundary, history);

  @override
  Future<void> compactAuto({
    required String ownerId,
    required String? topicBoundary,
    required List<Message> history,
    required ContextSummary? previous,
    required bool keepOnlyLatestTurn,
    required int retainTokens,
  }) => _exclusive(ownerId, () async {
    final covered = previous?.sourceIds.toSet() ?? <String>{};
    final pending = history.where((m) => !covered.contains(m.id)).toList();
    // 从 user 边界保留完整轮次，工具调用和结果随所属轮次保留。
    final starts = <int>[
      for (var i = 0; i < pending.length; i++)
        if (pending[i].role == 'user') i,
    ];
    if (starts.isEmpty || starts.last == 0) {
      throw const ContextCompactionException(
        '上下文已达到压缩阈值，但没有可压缩的旧轮次；请缩短当前消息或角色设置。',
      );
    }
    int size(Iterable<Message> messages) => messages.fold(
      0,
      (n, m) =>
          n +
          estimateTokenCount(
            '${m.content} ${m.blocks?.map((b) => b.toJson()).toList() ?? []}',
          ),
    );
    var cut = starts.last;
    var retained = size(pending.skip(cut));
    if (!keepOnlyLatestTurn) {
      for (var i = starts.length - 2; i >= 1; i--) {
        final turn = size(pending.sublist(starts[i], cut));
        if (retained + turn > retainTokens) break;
        cut = starts[i];
        retained += turn;
      }
    }
    final prefix = pending.take(cut).toList();
    final ids = {...covered, ...prefix.map((m) => m.id)};
    final snapshot = ContextSnapshot(
      ownerId: ownerId,
      previousBoundaryId: topicBoundary,
      allMessages: history.where((m) => ids.contains(m.id)).toList(),
      messages: prefix,
      previous: previous,
    );
    final summary = await (await summarizerFactory()).summarize(
      snapshot,
      kind: ContextSummaryKind.auto,
      onProgress: (_, __) {},
      isCancelled: () => false,
    );
    validateContextSummary(summary);
    await store.saveAuto(snapshot, summary);
    _notify(ownerId);
  });
}
