import '../../../core/app_logger.dart';
import '../../../core/utils/token_estimator.dart';
import '../../chat/domain/message.dart';
import '../../chat/services/chat_request_message_builder.dart';
import '../../../core/models/message_block.dart';
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
    this.beforeManualPrepare,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final ContextSummaryStorePort store;
  final Future<List<Message>> Function(String ownerId) loadMessages;
  final Future<String?> Function(String ownerId) readBoundary;
  final Future<ContextSummarizerPort> Function() summarizerFactory;
  final Future<void> Function(String ownerId) publishBoundary;
  final void Function(String ownerId) ensureIdle;
  final CompactionListener? onCompacted;
  final Future<void> Function(String ownerId)? beforeManualPrepare;
  final _busy = <String>{};
  final DateTime Function() _now;
  final _recoverFailedAt = <String, DateTime>{};
  static const recoverRetryCooldown = Duration(minutes: 10);

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
    await beforeManualPrepare?.call(ownerId);
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
    final summary = await _recover(ownerId, boundaryId);
    // 重放旧轮次时，不把覆盖它之后内容的摘要倒灌回去。
    if (summary == null ||
        history.any((m) => summary.sourceIds.contains(m.id))) {
      return null;
    }
    return summary;
  }

  /// 边界存在但摘要缺失时尽力补整理，失败不阻塞正常聊天。
  Future<ContextSummary?> _recover(String ownerId, String boundaryId) async {
    final key = '$ownerId\n$boundaryId';
    final existing = await store.manualFor(ownerId, boundaryId);
    if (existing != null) {
      _recoverFailedAt.remove(key);
      return existing;
    }
    final all = await _loadThrough(ownerId, boundaryId);
    if (all == null) {
      throw const ContextCompactionException('话题边界已失效，请先恢复或撤销上次压缩，本轮未发送。');
    }
    final failedAt = _recoverFailedAt[key];
    if (failedAt != null &&
        _now().difference(failedAt) < recoverRetryCooldown) {
      return null;
    }
    if (_busy.contains(ownerId)) {
      AppLogger.warning(
        'ContextManager',
        '该角色正在整理上下文，本轮跳过补整理直接发送',
        metadata: {'conversationId': ownerId, 'boundaryId': boundaryId},
      );
      return null;
    }
    return _exclusive(ownerId, () async {
      try {
        final again = await store.manualFor(ownerId, boundaryId);
        if (again != null) {
          _recoverFailedAt.remove(key);
          return again;
        }
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
          '话题边界缺少摘要，尝试补整理',
          metadata: {
            'conversationId': ownerId,
            'messages': snapshot.messages.length,
          },
        );
        final summary = await (await summarizerFactory()).summarize(
          snapshot,
          kind: ContextSummaryKind.manual,
          onProgress: (_, __) {},
          isCancelled: () => false,
        );
        final record = await store.saveRecoveredManual(snapshot, summary);
        _recoverFailedAt.remove(key);
        _notify(ownerId);
        return record;
      } catch (error) {
        _recoverFailedAt[key] = _now();
        AppLogger.warning(
          'ContextManager',
          '上一段话题的摘要缺失，补整理失败，本轮跳过摘要直接发送',
          metadata: {
            'conversationId': ownerId,
            'boundaryId': boundaryId,
            'error': error.toString(),
          },
        );
        return null;
      }
    });
  }

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
            '${m.role == 'assistant' ? ChatRequestMessageBuilder.stripAssistantDraftTags(m.content) : m.content} ${m.blocks?.map((b) => m.role == 'assistant' && b is TextBlock ? {...b.toJson(), 'content': ChatRequestMessageBuilder.stripAssistantDraftTags(b.content)} : b.toJson()).toList() ?? []}',
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

class ManualCompactionNotice {
  const ManualCompactionNotice({
    required this.id,
    required this.message,
    required this.isError,
  });

  final int id;
  final String message;
  final bool isError;
}

class ManualCompactionSessionState {
  const ManualCompactionSessionState({
    this.currentSummary,
    this.draft,
    this.draftText = '',
    this.preparing = false,
    this.committing = false,
    this.backgrounded = false,
    this.progress = '',
    this.error,
    this.notice,
  });

  final ContextSummary? currentSummary;
  final ManualCompactionDraft? draft;
  final String draftText;
  final bool preparing;
  final bool committing;
  final bool backgrounded;
  final String progress;
  final String? error;
  final ManualCompactionNotice? notice;

  static const _unchanged = Object();

  /// Nullable fields accept explicit null to clear their value.
  ManualCompactionSessionState copyWith({
    Object? currentSummary = _unchanged,
    Object? draft = _unchanged,
    String? draftText,
    bool? preparing,
    bool? committing,
    bool? backgrounded,
    String? progress,
    Object? error = _unchanged,
    Object? notice = _unchanged,
  }) => ManualCompactionSessionState(
    currentSummary: identical(currentSummary, _unchanged)
        ? this.currentSummary
        : currentSummary as ContextSummary?,
    draft: identical(draft, _unchanged)
        ? this.draft
        : draft as ManualCompactionDraft?,
    draftText: draftText ?? this.draftText,
    preparing: preparing ?? this.preparing,
    committing: committing ?? this.committing,
    backgrounded: backgrounded ?? this.backgrounded,
    progress: progress ?? this.progress,
    error: identical(error, _unchanged) ? this.error : error as String?,
    notice: identical(notice, _unchanged)
        ? this.notice
        : notice as ManualCompactionNotice?,
  );
}

/// Keeps manual compaction alive independently of the page displaying it.
class ManualCompactionSessionStore {
  ManualCompactionSessionStore(this._portResolver);
  ManualCompactionSessionStore.fromPort(ManualCompactionPort port)
    : this(() => port);

  final ManualCompactionPort Function() _portResolver;
  final _states = <String, ManualCompactionSessionState>{};
  final _runGeneration = <String, int>{};
  final _loadGeneration = <String, int>{};
  final _listeners = <void Function(String ownerId)>[];
  int _noticeSeq = 0;
  bool _disposed = false;

  void addListener(void Function(String ownerId) listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(void Function(String ownerId) listener) {
    _listeners.remove(listener);
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }

  ManualCompactionSessionState stateOf(String ownerId) =>
      _states[ownerId] ?? const ManualCompactionSessionState();

  void _update(String ownerId, ManualCompactionSessionState state) {
    if (_disposed) return;
    _states[ownerId] = state;
    for (final listener in List.of(_listeners)) {
      if (_disposed) return;
      listener(ownerId);
    }
  }

  static String _errorMessage(Object error) =>
      error is ContextCompactionException
      ? error.message
      : '整理或保存失败，请检查模型/网络后重试。确认前原话题不会改变。';

  Future<void> loadCurrent(String ownerId) async {
    if (_disposed) return;
    final gen = (_loadGeneration[ownerId] ?? 0) + 1;
    _loadGeneration[ownerId] = gen;
    ContextSummary? current;
    try {
      current = await _portResolver().current(ownerId);
    } catch (_) {
      current = null;
    }
    if (_disposed || _loadGeneration[ownerId] != gen) return;
    _update(ownerId, stateOf(ownerId).copyWith(currentSummary: current));
  }

  void markForeground(String ownerId) {
    final state = stateOf(ownerId);
    if (state.backgrounded || state.notice != null) {
      _update(ownerId, state.copyWith(backgrounded: false, notice: null));
    }
  }

  void enterBackground(String ownerId) {
    final state = stateOf(ownerId);
    if (state.preparing) {
      _update(ownerId, state.copyWith(backgrounded: true));
    }
  }

  void clearNotice(String ownerId, int noticeId) {
    final state = stateOf(ownerId);
    if (state.notice?.id == noticeId) {
      _update(ownerId, state.copyWith(notice: null));
    }
  }

  void updateDraftText(String ownerId, String text) {
    final state = stateOf(ownerId);
    if (!_disposed && state.draftText != text) {
      _states[ownerId] = state.copyWith(draftText: text);
    }
  }

  void discardDraft(String ownerId) {
    _update(
      ownerId,
      stateOf(
        ownerId,
      ).copyWith(draft: null, draftText: '', error: null, notice: null),
    );
  }

  void cancelPrepare(String ownerId) {
    _runGeneration[ownerId] = (_runGeneration[ownerId] ?? 0) + 1;
    _update(
      ownerId,
      stateOf(ownerId).copyWith(
        preparing: false,
        backgrounded: false,
        progress: '',
        error: null,
        notice: null,
      ),
    );
  }

  Future<void> prepare(String ownerId) async {
    final state = stateOf(ownerId);
    if (_disposed || state.preparing || state.committing) return;
    final gen = (_runGeneration[ownerId] ?? 0) + 1;
    _runGeneration[ownerId] = gen;
    bool isCancelled() => _disposed || _runGeneration[ownerId] != gen;
    _update(
      ownerId,
      state.copyWith(
        preparing: true,
        backgrounded: false,
        progress: '正在读取原始聊天…',
        error: null,
        notice: null,
      ),
    );
    try {
      final draft = await _portResolver().prepare(
        ownerId,
        isCancelled: isCancelled,
        onProgress: (done, total) {
          if (isCancelled()) return;
          _update(
            ownerId,
            stateOf(ownerId).copyWith(progress: '整理内容 $done / $total'),
          );
        },
      );
      if (isCancelled()) return;
      final current = stateOf(ownerId);
      _update(
        ownerId,
        current.copyWith(
          draft: draft,
          draftText: draft.summary,
          preparing: false,
          backgrounded: false,
          progress: '',
          error: null,
          notice: current.backgrounded
              ? ManualCompactionNotice(
                  id: ++_noticeSeq,
                  message: '摘要已整理好，打开「更多 → 压缩上下文」即可确认开启。',
                  isError: false,
                )
              : null,
        ),
      );
    } catch (error) {
      if (isCancelled()) return;
      final message = _errorMessage(error);
      final current = stateOf(ownerId);
      _update(
        ownerId,
        current.copyWith(
          preparing: false,
          backgrounded: false,
          progress: '',
          error: message,
          notice: current.backgrounded
              ? ManualCompactionNotice(
                  id: ++_noticeSeq,
                  message: message,
                  isError: true,
                )
              : null,
        ),
      );
    }
  }

  Future<bool> commit(String ownerId, String summary) async {
    final state = stateOf(ownerId);
    final draft = state.draft;
    if (_disposed || draft == null || state.committing) return false;
    _update(
      ownerId,
      state.copyWith(
        committing: true,
        draftText: summary,
        progress: '正在保存内容交接…',
        error: null,
      ),
    );
    try {
      final saved = await _portResolver().commit(draft, summary);
      if (_disposed) return false;
      _update(ownerId, ManualCompactionSessionState(currentSummary: saved));
      return true;
    } catch (error) {
      _update(
        ownerId,
        stateOf(ownerId).copyWith(
          committing: false,
          draftText: summary,
          progress: '',
          error: _errorMessage(error),
        ),
      );
      return false;
    }
  }

  Future<bool> undo(String ownerId) async {
    final state = stateOf(ownerId);
    if (_disposed || state.committing) return false;
    _update(
      ownerId,
      state.copyWith(committing: true, progress: '正在恢复…', error: null),
    );
    try {
      final port = _portResolver();
      await port.undo(ownerId);
      if (_disposed) return false;
      ContextSummary? current;
      try {
        current = await port.current(ownerId);
      } catch (_) {
        current = null;
      }
      if (_disposed) return false;
      _update(
        ownerId,
        stateOf(ownerId).copyWith(
          currentSummary: current,
          draft: null,
          draftText: '',
          error: null,
          notice: null,
          committing: false,
          progress: '',
        ),
      );
      return true;
    } catch (error) {
      _update(
        ownerId,
        stateOf(ownerId).copyWith(
          committing: false,
          progress: '',
          error: _errorMessage(error),
        ),
      );
      return false;
    }
  }
}
