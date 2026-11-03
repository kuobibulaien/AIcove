import 'dart:async';

import '../../../core/app_logger.dart';
import '../../../core/models/message_block.dart';
import '../../chat/domain/message.dart';
import '../data/background_memory_agent_adapter.dart';
import '../domain/memory_item.dart';
import '../domain/memory_ports.dart';

const kMemoryRollingWindow = Duration(hours: 24);
const kMemoryContinuityGap = Duration(minutes: 10);
const kMemoryRoundSplitThreshold = 20;
const kMemoryRoundGap = Duration(hours: 1);
const kMemoryCheckThrottle = Duration(minutes: 10);

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
  final _needsRerun = <String>{};
  final _lastCheckedAt = <String, DateTime>{};
  final _changes = StreamController<String>.broadcast();

  /// 某个角色的记忆或进度变化时发出其 id，供界面刷新。
  Stream<String> get changes => _changes.stream;
  bool isRunning(String ownerId) => _running.containsKey(ownerId);

  @override
  void schedule(String ownerId) {
    if (_running.containsKey(ownerId)) {
      _needsRerun.add(ownerId);
      return;
    }
    _running[ownerId] = _run(ownerId).whenComplete(() {
      _running.remove(ownerId);
      _changes.add(ownerId);
      if (_needsRerun.remove(ownerId)) schedule(ownerId);
    });
  }

  /// 按时间节流检查上次中途退出留下的整理。
  void resumeOnce(String ownerId, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final last = _lastCheckedAt[ownerId];
    if (last != null && current.difference(last) < kMemoryCheckThrottle) return;
    _lastCheckedAt[ownerId] = current;
    schedule(ownerId);
  }

  /// 等待当前任务结束（测试与界面暂停时使用）。
  Future<void> idle(String ownerId) => _running[ownerId] ?? Future.value();

  /// 只保留参与记忆整理的原文：用户与助手的已发送消息。杂活回执与控制事件
  /// 不是对话内容，不进记忆（ADR0088）；角色转告的那条消息照常参与。
  static List<Message> eligible(List<Message> all) => all
      .where(
        (m) =>
            (m.role == 'user' || m.role == 'assistant') &&
            m.status != 'failed' &&
            m.status != 'sending' &&
            !(m.blocks?.any(
                  (b) => b is TaskReceiptBlock || b is TaskControlBlock,
                ) ??
                false),
      )
      .toList();

  Future<MemoryRebuildEstimate> estimateRebuild(
    String ownerId, {
    int? batchTokenBudget,
  }) async {
    final messages = eligible(await loadMessages(ownerId));
    final budget = batchTokenBudget ?? (await agentFactory()).batchTokenBudget;
    final batches = buildBatches(
      messages,
      startIndex: 0,
      targetIndex: messages.length - 1,
      budget: budget,
    );
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
    final start = state.pendingStart(all);
    if (start >= all.length) return const [];
    final target = await _targetIndex(ownerId, raw, all, state, start);
    if (target < start) return const [];
    return all.sublist(start, target + 1);
  }

  Future<int> _targetIndex(
    String ownerId,
    List<Message> raw,
    List<Message> all,
    MemoryProgress state,
    int start,
  ) async {
    final targets = {
      ...await compactedBoundaries(ownerId),
      if (state.rebuildUntilId != null) state.rebuildUntilId!,
    };
    var targetTime = -1;
    for (final message in raw) {
      if (targets.contains(message.id)) {
        final time = message.createdAt.millisecondsSinceEpoch;
        if (time > targetTime) targetTime = time;
      }
    }
    final boundary = targetTime < 0
        ? -1
        : all.lastIndexWhere(
            (m) => m.createdAt.millisecondsSinceEpoch <= targetTime,
          );
    final rolling = rollingTargetIndex(all, startIndex: start);
    return boundary > rolling ? boundary : rolling;
  }

  static int rollingTargetIndex(List<Message> all, {int startIndex = 0}) {
    if (all.isEmpty || startIndex >= all.length) return -1;
    final cutoff = all.last.createdAt.subtract(kMemoryRollingWindow);
    var index = all.lastIndexWhere((m) => m.createdAt.isBefore(cutoff));
    if (index < startIndex) return -1;
    while (index + 1 < all.length &&
        all[index + 1].createdAt.difference(all[index].createdAt) <=
            kMemoryContinuityGap) {
      index++;
    }
    return index;
  }

  static List<List<Message>> splitRounds(List<Message> all) {
    final days = <DateTime, List<Message>>{};
    for (final message in all) {
      final local = message.createdAt.toLocal();
      (days[DateTime(local.year, local.month, local.day)] ??= []).add(message);
    }
    final rounds = <List<Message>>[];
    for (final day in days.values) {
      if (day.where((m) => m.role == 'user').length <=
          kMemoryRoundSplitThreshold) {
        rounds.add(day);
        continue;
      }
      var round = <Message>[];
      for (var i = 0; i < day.length; i++) {
        if (i > 0 &&
            day[i].createdAt.difference(day[i - 1].createdAt) >
                kMemoryRoundGap) {
          rounds.add(round);
          round = [];
        }
        round.add(day[i]);
      }
      rounds.add(round);
    }
    return rounds;
  }

  static List<List<Message>> buildBatches(
    List<Message> all, {
    required int startIndex,
    required int targetIndex,
    required int budget,
  }) {
    if (all.isEmpty || targetIndex < startIndex) return const [];
    final batches = <List<Message>>[];
    var offset = 0;
    for (final round in splitRounds(all)) {
      final from = startIndex > offset ? startIndex - offset : 0;
      final end = targetIndex + 1 < offset + round.length
          ? targetIndex + 1 - offset
          : round.length;
      if (from < end && from < round.length && end > 0) {
        batches.addAll(_batches(round.sublist(from, end), budget));
      }
      offset += round.length;
    }
    return batches;
  }

  Future<void> _run(String ownerId) async {
    MemoryAgentPort? agent;
    while (true) {
      final progress = await store.progress(ownerId);
      if (progress.paused || !await allowed(ownerId)) return;
      final raw = await loadMessages(ownerId);
      final all = eligible(raw);
      final start = progress.pendingStart(all);
      final target = start >= all.length
          ? -1
          : await _targetIndex(ownerId, raw, all, progress, start);
      if (target < start) {
        if (progress.rebuildUntilId != null) {
          await store.clearRebuildTarget(ownerId, progress.generation);
        }
        return;
      }
      try {
        agent ??= await agentFactory();
        final batch = buildBatches(
          all,
          startIndex: start,
          targetIndex: target,
          budget: agent.batchTokenBudget,
        ).first;
        final core = await store.list(ownerId, layer: MemoryLayer.core);
        final related = await store.searchKeyword(
          ownerId,
          batch.map((m) => m.displayText).join('\n'),
          limit: 12,
        );
        final ops = await agent.propose(
          ownerId: ownerId,
          core: core,
          related: related
              .where((i) => i.layer == MemoryLayer.archive)
              .toList(),
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
