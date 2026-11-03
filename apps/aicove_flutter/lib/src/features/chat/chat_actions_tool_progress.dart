part of 'chat_actions.dart';

extension ChatActionsToolProgress on ChatActions {
  /// 覆盖写入本次尝试的轮次与调用；界面仍只显示已完成的工具卡片。
  /// 不动会话摘要：预览和时间仍跟着真正的链尾。
  Future<void> _writeToolProgress(
    String convId,
    _ToolProgress progress,
  ) async {
    if (progress.allCalls.isEmpty) {
      // 写过就删（软删幂等）：上次写入可能只提交了 raw 就报错。
      if (progress.touched) {
        await _historyPort.softDeleteMessages(convId, [progress.rawId]);
        progress
          ..touched = false
          ..stored = false;
      }
      return;
    }
    // 重新生成：新过程第一次落库时撤掉旧回复，和首段正文同一时机。
    if (!progress.stored) await progress.beforeFirstWrite?.call();
    final built = _sendPort.buildAssistantMessages(
      apiResult: ApiCallResult(
        status: progress.status,
        replyText: '',
        processedText: '',
        pluginEvents: const [],
        toolResults: const [],
        toolCalls: List.of(progress.calls),
        rawToolResults: List.of(progress.results),
      ),
      settings: await _ref.read(appSettingsProvider.future),
    );
    final raw = built.rawMessage;
    if (raw == null) return;
    // Keep the existing tool-card projection; request replay reads the complete
    // product-stage snapshot, including calls whose execution has not settled.
    final rounds = progress.rounds;
    final text = rounds.map((r) => r.replyText).join('\n');
    final payload = ChatMessageProjectionCodec.buildRawAssistantPayload(
      apiResult: ApiCallResult(
        status: progress.status,
        stopReason: progress.running && rounds.isNotEmpty ? 'inProgress' : null,
        replyText: text,
        processedText: text,
        pluginEvents: const [],
        toolResults: const [],
        toolCalls: progress.allCalls,
        rawToolResults: List.of(progress.results),
        // Progress owns execution history, not revealed dialogue. Visible text
        // is saved once by _savePartialStream; rawText retains model replay.
        replyRounds: [for (final round in rounds)
          ReplyRound(
            replyText: '',
            processedText: '',
            rawText: round.rawText ?? round.replyText,
            reasoning: round.reasoning,
            toolCallIds: round.toolCallIds,
          ),
        ],
        reasoning: joinRoundReasonings([for (final r in rounds) r.reasoning]),
      ),
    );
    // 每次重建都换回固定 id，覆盖写入而不是追加新消息。
    Message rehome(Message message, String id, {String? sourceMessageId}) =>
        message.copyWith(
          id: id,
          sourceMessageId: sourceMessageId,
          createdAt: progress.createdAt,
          blocks: message.blocks == null
              ? null
              : [
                  for (final (index, block) in message.blocks!.indexed)
                    MessageBlock.fromJson({
                      ...block.toJson(),
                      'id': '${id}_$index',
                      'messageId': id,
                    }),
                ],
        );
    progress.touched = true;
    await _historyPort.appendAssistantRawMessage(
      conversationId: convId,
      userMessageId: '',
      rawMessage: rehome(
        raw.copyWith(content: text, rawPayload: payload),
        progress.rawId,
      ),
      projectedMessages: [
        for (final (index, message) in built.messages.indexed)
          rehome(
            message,
            '${progress.rawId}_p$index',
            sourceMessageId: progress.rawId,
          ),
      ],
      lastMessagePreview: built.lastMessageText,
      updateSummary: false,
    );
    progress.stored = true;
  }

  /// 正式 raw 落库之后调用（交付可能还在分段展示、也可能已被取消）。正式
  /// raw 带着交付它的那次执行尝试的全部工具调用，这些步骤从过程消息里去掉；
  /// 失败切换前的尝试做过的留在过程消息里。
  Future<void> _settleToolProgress(_GenerationTask task) async {
    final progress = task.toolProgress;
    await progress.close();
    await progress.exclusive(() => _settleQueued(task));
  }

  /// 已在写入队列里执行。清理写库成功后才算交接完成；失败退回原状，
  /// 取消补写或生成收尾会再试一次。
  Future<void> _settleQueued(_GenerationTask task) async {
    final progress = task.toolProgress;
    if (progress.settled) return;
    final snapshot = progress.snapshot();
    progress.dropAttempt(progress.attempt);
    if (progress.rounds.isNotEmpty) progress.status = ApiRunStatus.failed;
    try {
      // 总是重写：之前某次写库失败时，库里可能缺步骤。
      await _writeToolProgress(task.convId, progress);
    } catch (_) {
      progress.restore(snapshot);
      rethrow;
    }
    progress.settled = true;
  }

  /// 正式 raw 是否已在库里：在库就由它接手最后一次尝试的步骤。
  Future<bool> _formalRawStored(_GenerationTask task) async {
    final rawId = task.toolProgress.formalRawId;
    return rawId != null &&
        await _ref.read(chatHistoryStoreProvider).isRawMessageActive(
              conversationId: task.convId,
              messageId: rawId,
            );
  }

  /// 生成没有正式 raw 接手就结束（取消、失败）：排队的写完后，把全部已完成
  /// 步骤按 [status] 补写一遍。
  Future<void> _keepToolProgress(
    _GenerationTask task,
    ApiRunStatus status,
  ) async {
    final progress = task.toolProgress;
    try {
      await progress.close();
      await progress.exclusive(() async {
        if (progress.settled) return;
        progress.status = status;
        // 正式 raw 已落库、交付还在分段展示时被取消：当场交接，下一轮
        // 上下文不会读到两份同样的工具调用。
        if (await _formalRawStored(task)) return _settleQueued(task);
        await _writeToolProgress(task.convId, progress);
      });
    } catch (e) {
      AppLogger.warning('ChatActions', '保存已完成的工具步骤失败',
          metadata: {'convId': task.convId, 'error': e.toString()});
    }
  }

}

/// 一次生成的轮次快照与已结算结果，写入串行排队。
class _ToolProgress {
  final rawId = genId('raw_msg');

  /// 生成开始的时间：过程消息排在用户消息之后、本轮正文之前。
  final createdAt = DateTime.now();
  final calls = <ToolCall>[];
  final results = <ToolResult>[];
  final _attempts = <int>[];
  final _rounds = <int, List<ReplyRound>>{};
  final _roundCalls = <int, List<ToolCall>>{};

  bool get running => !_closed;
  List<ReplyRound> get rounds => [for (final value in _rounds.values) ...value];
  List<ToolCall> get allCalls => [
    for (var i = 1; i <= attempt; i++) ...[
      ...?_roundCalls[i],
      for (final (index, call) in calls.indexed)
        if (_attempts[index] == i &&
            !(_roundCalls[i]?.any((c) => c.id == call.id) ?? false))
          call,
    ],
  ];

  Future<void> recordRounds(
    List<ReplyRound> rounds,
    List<ToolCall> calls,
    int attempt,
    Future<void> Function() write,
  ) async {
    if (_closed) return;
    _rounds[attempt] = List.of(rounds);
    _roundCalls[attempt] = List.of(calls);
    try {
      await exclusive(write);
    } catch (e) {
      AppLogger.warning(
        'ChatActions',
        '工具轮次落库失败',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// 当前执行尝试的序号；失败切换模型或重试都会开始新的一次。
  int attempt = 0;
  Future<void> _writes = Future<void>.value();
  Future<void> Function()? _pendingRecordWrite;
  bool _closed = false;

  /// 过程消息已在库里。
  bool stored = false;

  /// 写库动过（可能只成功一半），清理时据此删除。
  bool touched = false;

  /// 本轮正式回复的 raw id，交付开始时记下。
  String? formalRawId;

  /// 写入时标在过程消息上的状态：取消、失败收尾时改掉。
  ApiRunStatus status = ApiRunStatus.completed;

  /// 正式回复已落库并接手了它带上的步骤。
  bool settled = false;

  /// 第一次落库前执行一次（重新生成用来撤掉旧回复）。
  Future<void> Function()? beforeFirstWrite;

  int beginAttempt() => ++attempt;

  ({
    List<ToolCall> calls,
    List<ToolResult> results,
    List<int> attempts,
    Map<int, List<ReplyRound>> rounds,
    Map<int, List<ToolCall>> roundCalls,
  })
  snapshot() => (
    calls: List.of(calls),
    results: List.of(results),
    attempts: List.of(_attempts),
    rounds: Map.of(_rounds),
    roundCalls: Map.of(_roundCalls),
  );

  void restore(
    ({
      List<ToolCall> calls,
      List<ToolResult> results,
      List<int> attempts,
      Map<int, List<ReplyRound>> rounds,
      Map<int, List<ToolCall>> roundCalls,
    })
    snapshot,
  ) {
    calls
      ..clear()
      ..addAll(snapshot.calls);
    results
      ..clear()
      ..addAll(snapshot.results);
    _rounds
      ..clear()
      ..addAll(snapshot.rounds);
    _roundCalls
      ..clear()
      ..addAll(snapshot.roundCalls);
    _attempts
      ..clear()
      ..addAll(snapshot.attempts);
  }

  void dropAttempt(int attempt) {
    _rounds.remove(attempt);
    _roundCalls.remove(attempt);
    for (var index = calls.length - 1; index >= 0; index--) {
      if (_attempts[index] != attempt) continue;
      calls.removeAt(index);
      results.removeAt(index);
      _attempts.removeAt(index);
    }
  }

  void record(
    ToolCall call,
    ToolResult result,
    int attempt,
    Future<void> Function() write,
  ) {
    if (_closed) return;
    calls.add(call);
    results.add(result);
    _attempts.add(attempt);
    final alreadyQueued = _pendingRecordWrite != null;
    _pendingRecordWrite = write;
    if (alreadyQueued) return;
    _writes = _writes.then((_) async {
      final pendingWrite = _pendingRecordWrite!;
      // 一旦开始执行，后续结果可以再排一次写入，不能丢掉运行期间的变化。
      _pendingRecordWrite = null;
      if (_closed) return;
      try {
        await pendingWrite();
      } catch (e) {
        AppLogger.warning(
          'ChatActions',
          '工具步骤落库失败',
          metadata: {'error': e.toString()},
        );
      }
    });
  }

  /// 停止后续写入，并等已排队的写完。
  Future<void> close() {
    _closed = true;
    return _writes;
  }

  /// 收尾写入也排进同一条队列，交接与取消补写不会交错。
  Future<void> exclusive(Future<void> Function() task) {
    final run = _writes.then((_) => task());
    _writes = run.catchError((Object _) {});
    return run;
  }
}

