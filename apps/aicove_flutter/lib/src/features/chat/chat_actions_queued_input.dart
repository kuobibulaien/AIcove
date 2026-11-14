part of 'chat_actions.dart';

/// 一条正在发送的排队输入走到哪一步：还没落库（停止时退回）、落库中
/// （落库失败才退回）、已落库（不再退回）。
enum _QueuedPhase { pending, persisting, committed }

class _QueuedSend {
  _QueuedSend(this.text);
  final String text;
  _QueuedPhase phase = _QueuedPhase.pending;
  String? messageId;
}

/// Agent 运行中的插话与排队（ADR0112，对照 Pi 的 steer／follow-up）。
///
/// 两者都不打断正在执行的工具。插话让当前运行在这批工具结算后、下一次
/// 模型请求前结束（[_GenerationTask.setYield]），已完成的步骤照常落库，
/// 再把插话作为新的用户消息发出；排队等整轮结束才发。每次只发一条，插话优先。
/// 下一条在上一轮收尾时同步登记成新任务，中间没有空闲空档，停止与撤回都
/// 直接作用于它。停止或失败时没发出的输入转入 [returnedQueuedInputsProvider]，
/// 留在输入框上方等用户放回，不自动写进输入框，避免切会话或编辑时被覆盖。
extension ChatActionsQueuedInput on ChatActions {
  bool _queueWhileRunning(String text, {required bool steer, String? convId}) {
    final id = convId ?? _ref.read(activeConversationProvider)?.id;
    final trimmed = text.trim();
    if (id == null || trimmed.isEmpty) return false;
    final task = _activeGenerations[id];
    final conv = _ref.read(conversationSnapshotByIdProvider(id)) ??
        _ref.read(activeConversationProvider);
    if (task == null || conv?.id != id) {
      return false;
    }
    final queue = _ref.read(conversationQueuedInputsProvider(id).notifier);
    queue.state = [...queue.state, QueuedChatInput(trimmed, steer: steer)];
    if (steer) task.setYield(true);
    return true;
  }

  /// 取走未发出的和排队中的全部输入，按先后顺序；撤回插话后本次运行照常继续。
  List<String> _takeQueuedInputs(String convId) {
    final queue = _ref.read(conversationQueuedInputsProvider(convId).notifier);
    final returned = _ref.read(returnedQueuedInputsProvider(convId).notifier);
    final texts = [
      ...returned.state,
      for (final input in queue.state) input.text,
    ];
    queue.state = const [];
    returned.state = const [];
    _activeGenerations[convId]?.setYield(false);
    return texts;
  }

  /// 每个新任务（含重新生成重建的任务）都按队里有没有插话决定是否让出。
  void _applyQueuedSteer(String convId, _GenerationTask task) {
    final queue = _ref.read(conversationQueuedInputsProvider(convId));
    task.setYield(queue.any((input) => input.steer));
  }

  void _returnQueuedInputs(String convId, {List<String> first = const []}) {
    final queue = _ref.read(conversationQueuedInputsProvider(convId).notifier);
    final returned = _ref.read(returnedQueuedInputsProvider(convId).notifier);
    final next = [
      ...first,
      ...returned.state,
      for (final input in queue.state) input.text,
    ];
    queue.state = const [];
    if (next.isNotEmpty) returned.state = next;
  }

  /// [task] 结束后：[deliver] 时把下一条（插话优先）登记成新任务并返回 true，
  /// 调用方不要把会话置为空闲；否则连同 [task] 里还没落库的那条一起转为未发出。
  bool _settleQueuedInputs(
    String convId,
    _GenerationTask task, {
    required bool deliver,
  }) {
    final conv = _ref.read(conversationSnapshotByIdProvider(convId));
    if (!deliver || conv == null) {
      final queued = task.queued;
      _returnQueuedInputs(
        convId,
        first: [
          if (queued != null && queued.phase == _QueuedPhase.pending)
            queued.text,
        ],
      );
      return false;
    }
    final queue = _ref.read(conversationQueuedInputsProvider(convId).notifier);
    final pending = queue.state;
    if (pending.isEmpty) return false;
    final next = pending.firstWhere(
      (input) => input.steer,
      orElse: () => pending.first,
    );
    queue.state = [
      for (final input in pending)
        if (!identical(input, next)) input,
    ];
    // _sendText 在第一个 await 前就登记了新任务。
    unawaited(_deliverQueuedInput(conv, _QueuedSend(next.text)));
    return true;
  }

  Future<void> _deliverQueuedInput(Conversation conv, _QueuedSend send) async {
    try {
      await _sendText(send.text, targetConversation: conv, queued: send);
    } catch (e) {
      AppLogger.warning('ChatActions', '排队输入发送出错',
          metadata: {'convId': conv.id, 'error': e.toString()});
      final task = _activeGenerations[conv.id];
      if (task != null && identical(task.queued, send)) {
        // 落库之后、进入正式生成前出错：消息标失败，按失败收尾（剩余队列转
        // 未发出），不留下卡住的发送中。
        task.failed = true;
        _setConversationError(conv.id, e.toString());
        final messageId = send.messageId;
        try {
          if (send.phase == _QueuedPhase.committed && messageId != null) {
            await _sendPort.markUserMessageFailed(
                convId: conv.id, userMsgId: messageId);
          }
        } catch (markError) {
          AppLogger.warning('ChatActions', '排队消息标记失败出错',
              metadata: {'convId': conv.id, 'error': markError.toString()});
        } finally {
          await _finishGeneration(conv.id, task.id);
        }
      }
      // 落库报错且查不到这条（写库后刷新缓存失败不算）：只把这一条排回
      // 未发出最前面；当前队列可能已属于后来的新任务，不去动它。查询本身
      // 出错时也排回：未发出不会自动重发，由用户决定是否放回，宁可多留
      // 一条可能已发过的文字，也不丢字。
      if (send.phase == _QueuedPhase.persisting && !await _queuedSaved(send)) {
        final returned =
            _ref.read(returnedQueuedInputsProvider(conv.id).notifier);
        returned.state = [send.text, ...returned.state];
      }
    }
  }

  Future<bool> _queuedSaved(_QueuedSend send) async {
    final messageId = send.messageId;
    if (messageId == null) return false;
    try {
      return await _ref
              .read(chatHistoryStoreProvider)
              .loadMessageById(messageId, preferProjection: false) !=
          null;
    } catch (_) {
      return false;
    }
  }
}
