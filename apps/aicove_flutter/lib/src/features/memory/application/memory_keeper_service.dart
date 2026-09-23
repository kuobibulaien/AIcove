import 'dart:async';

import '../../../core/app_logger.dart';
import '../../chat/domain/message.dart';
import '../data/background_memory_agent_adapter.dart';
import '../domain/memory_item.dart';
import '../domain/memory_ports.dart';

/// 重建前给用户看的估算。
class MemoryRebuildEstimate {
  const MemoryRebuildEstimate({
    required this.messages,
    required this.inputTokens,
    required this.batches,
  });
  final int messages, inputTokens, batches;
}

/// 长期记忆维护：按时间顺序把「已被压缩、但还没整理过」的原文分批交给记忆 Agent，
/// 并在同一事务里写入变更与推进书签。每个角色同一时间只有一个任务。
class MemoryKeeperService implements MemoryMaintenancePort {
  MemoryKeeperService({
    required this.store,
    required this.loadMessages,
    required this.compactedBoundaries,
    required this.agentFactory,
    required this.allowed,
  });
  final MemoryStorePort store;
  final Future<List<Message>> Function(String ownerId) loadMessages;
  final CompactedBoundaryReader compactedBoundaries;
  final Future<MemoryAgentPort> Function() agentFactory;
  final Future<bool> Function(String ownerId) allowed;

  final _running = <String, Future<void>>{};
  final _resumeChecked = <String>{};
  final _changes = StreamController<String>.broadcast();

  /// 某个角色的记忆或进度变化时发出其 id，供界面刷新。
  Stream<String> get changes => _changes.stream;
  bool isRunning(String ownerId) => _running.containsKey(ownerId);

  @override
  void schedule(String ownerId) {
    if (_running.containsKey(ownerId)) return;
    _running[ownerId] = _run(ownerId).whenComplete(() {
      _running.remove(ownerId);
      _changes.add(ownerId);
    });
  }

  /// 续跑上次中途退出留下的整理。每个角色每次启动只检查一次，
  /// 避免每轮发送都读取全部原文；平时的整理由压缩触发。
  void resumeOnce(String ownerId) {
    if (_resumeChecked.add(ownerId)) schedule(ownerId);
  }

  /// 等待当前任务结束（测试与界面暂停时使用）。
  Future<void> idle(String ownerId) => _running[ownerId] ?? Future.value();

  /// 只保留参与记忆整理的原文：用户与助手的已发送消息。
  static List<Message> eligible(List<Message> all) => all
      .where(
        (m) =>
            (m.role == 'user' || m.role == 'assistant') &&
            m.status != 'failed' &&
            m.status != 'sending',
      )
      .toList();

  Future<MemoryRebuildEstimate> estimateRebuild(
    String ownerId, {
    int? batchTokenBudget,
  }) async {
    final messages = eligible(await loadMessages(ownerId));
    final budget = batchTokenBudget ?? (await agentFactory()).batchTokenBudget;
    final batches = _batches(messages, budget);
    return MemoryRebuildEstimate(
      messages: messages.length,
      inputTokens: messages.fold(
        0,
        (n, m) => n + estimateMemoryMessageTokens(m),
      ),
      batches: batches.length,
    );
  }

  Future<void> startRebuild(String ownerId) async {
    if (!await allowed(ownerId)) {
      throw const MemoryException('该角色没有启用长期记忆。');
    }
    final messages = eligible(await loadMessages(ownerId));
    if (messages.isEmpty) throw const MemoryException('还没有可整理的聊天记录。');
    await store.resetForRebuild(ownerId, messages.last);
    _changes.add(ownerId);
    schedule(ownerId);
  }

  Future<void> pause(String ownerId) async {
    await store.setPaused(ownerId, true);
    _changes.add(ownerId);
  }

  Future<void> resume(String ownerId) async {
    await store.setPaused(ownerId, false);
    _changes.add(ownerId);
    schedule(ownerId);
  }

  /// 返回还需要处理的原文（按时间顺序）。
  Future<List<Message>> pendingMessages(
    String ownerId, {
    MemoryProgress? progress,
  }) async {
    final state = progress ?? await store.progress(ownerId);
    final raw = await loadMessages(ownerId);
    final all = eligible(raw);
    final targets = {
      ...await compactedBoundaries(ownerId),
      if (state.rebuildUntilId != null) state.rebuildUntilId!,
    };
    // 摘要边界可能是工具或失败消息，按完整原文定位后映射回可整理的消息。
    var targetTime = -1;
    for (final message in raw) {
      if (targets.contains(message.id)) {
        final time = message.createdAt.millisecondsSinceEpoch;
        if (time > targetTime) targetTime = time;
      }
    }
    if (targetTime < 0) return const [];
    final start = state.pendingStart(all);
    final targetIndex = all.lastIndexWhere(
      (m) => m.createdAt.millisecondsSinceEpoch <= targetTime,
    );
    if (targetIndex < start) return const [];
    return all.sublist(start, targetIndex + 1);
  }

  Future<void> _run(String ownerId) async {
    MemoryAgentPort? agent;
    while (true) {
      final progress = await store.progress(ownerId);
      if (progress.paused || !await allowed(ownerId)) return;
      final pending = await pendingMessages(ownerId, progress: progress);
      if (pending.isEmpty) {
        if (progress.rebuildUntilId != null) {
          await store.clearRebuildTarget(ownerId, progress.generation);
        }
        return;
      }
      try {
        agent ??= await agentFactory();
        final batch = _batches(pending, agent.batchTokenBudget).first;
        final core = await store.list(ownerId, layer: MemoryLayer.core);
        final related = await store.searchKeyword(
          ownerId,
          batch.map((m) => m.displayText).join('\n'),
          limit: 12,
        );
        final ops = await agent.propose(
          ownerId: ownerId,
          core: core,
          related: related.where((i) => i.layer == MemoryLayer.archive).toList(),
          messages: batch,
        );
        if (!await allowed(ownerId)) return;
        final applied = await store.applyAgentOps(
          ownerId,
          ops,
          processedUntil: batch.last,
          generation: progress.generation,
        );
        AppLogger.info(
          'MemoryKeeper',
          applied == null ? '重建已重新开始，丢弃旧批次' : '记忆整理完成一批',
          metadata: {
            'conversationId': ownerId,
            'messages': batch.length,
            'ops': ops.length,
            'applied': applied,
          },
        );
        _changes.add(ownerId);
      } catch (error) {
        AppLogger.warning(
          'MemoryKeeper',
          '记忆整理失败，下次压缩或手动继续时重试',
          metadata: {
            'conversationId': ownerId,
            'errorType': error.runtimeType.toString(),
            'error': error.toString(),
          },
        );
        await store.recordError(ownerId, error.toString());
        return;
      }
    }
  }

  /// 整条消息优先，单条过大时单独成批（适配器会截断超长正文）。
  static List<List<Message>> _batches(List<Message> messages, int budget) {
    final batches = <List<Message>>[];
    var batch = <Message>[];
    var used = 0;
    for (final message in messages) {
      final size = estimateMemoryMessageTokens(message);
      if (batch.isNotEmpty && used + size > budget) {
        batches.add(batch);
        batch = [];
        used = 0;
      }
      batch.add(message);
      used += size;
    }
    if (batch.isNotEmpty) batches.add(batch);
    return batches;
  }
}
