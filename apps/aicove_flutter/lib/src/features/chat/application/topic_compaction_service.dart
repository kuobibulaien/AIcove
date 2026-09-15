import '../../memory/domain/compaction_memory.dart';
import '../../../core/app_logger.dart';
import '../../memory/domain/contact_memory_port.dart';
import '../domain/topic_compaction_port.dart';

class TopicCompactionService implements TopicCompactionPort {
  TopicCompactionService({
    required this.store,
    required this.summaryFactory,
    required this.memory,
    required this.memoryAllowed,
    required this.readBoundary,
    required this.publishBoundary,
    required this.ensureIdle,
    this.compactionMemory,
  });
  final CompactionMemoryPort? compactionMemory;
  final TopicHandoffStorePort store;
  final Future<TopicSummaryPort> Function() summaryFactory;
  final ContactMemoryPort memory;
  final Future<bool> Function(String owner) memoryAllowed;
  final Future<String?> Function(String owner) readBoundary;
  final Future<void> Function(String owner) publishBoundary;
  final void Function(String owner) ensureIdle;
  final _busy = <String>{};

  Future<T> _run<T>(String owner, Future<T> Function() action) async {
    ensureIdle(owner);
    if (!_busy.add(owner)) {
      throw const TopicCompactionException('该角色正在整理，请勿重复操作。');
    }
    try {
      return await action();
    } finally {
      _busy.remove(owner);
    }
  }

  Future<bool> _canArchive(String owner) async {
    try {
      return await memoryAllowed(owner) && (await memory.load(owner)).enabled;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<TopicCompactionDraft> prepare(
    String ownerId, {
    required void Function(int completed, int total) onProgress,
    required bool Function() isCancelled,
  }) => _run(ownerId, () async {
    final snapshot = await store.snapshot(ownerId);
    final summarizer = await summaryFactory();
    final output = await summarizeContext(
      summarizer,
      snapshot,
      memory: await compactionMemory?.prepare(ownerId),
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    if (isCancelled()) throw const TopicCompactionException('已取消整理。');
    validateTopicSummary(output.summary);
    return TopicCompactionDraft(
      snapshot: compactionMemory == null
          ? snapshot
          : snapshot.withMemoryUpdates(output.memoryUpdates),
      summary: output.summary,
      canArchive: await _canArchive(ownerId),
    );
  });

  @override
  Future<TopicCompactionResult> commit(
    TopicCompactionDraft draft,
    String summary, {
    required bool archive,
  }) => _run(draft.snapshot.ownerId, () async {
    final record = await store.commit(
      summary.trim() == draft.summary.trim()
          ? draft.snapshot
          : draft.snapshot.withMemoryUpdates(
              draft.snapshot.memoryUpdates
                  .where((u) => summary.contains(u.body))
                  .toList(),
            ),
      summary,
      archive: archive,
    );
    // DB 已原子保存摘要与边界，内存同步失败不能误报为“没有切换”。
    try {
      await publishBoundary(record.ownerId);
    } catch (error) {
      AppLogger.warning(
        'TopicCompaction',
        '压缩已保存，界面状态刷新失败',
        metadata: {
          'conversationId': record.ownerId,
          'errorType': error.runtimeType.toString(),
        },
      );
    }
    final saved = !archive || await _archive(record);
    AppLogger.info(
      'TopicCompaction',
      '手动压缩完成',
      metadata: {
        'conversationId': record.ownerId,
        'handoffId': record.id,
        'sourceCount': record.sourceIds.length,
        'memoryPending': !saved,
      },
    );
    return TopicCompactionResult(record, memoryPending: !saved);
  });

  Future<bool> _archive(TopicHandoff record) async {
    try {
      if (!await _canArchive(record.ownerId)) return false;
      if (record.memoryState == 'pending_updates') {
        final saved = await compactionMemory?.flush(record.ownerId) ?? false;
        if (saved) await store.markArchived(record.id);
        return saved;
      }
      final notebook = await memory.load(record.ownerId);
      if (!notebook.enabled || !await memoryAllowed(record.ownerId)) {
        return false;
      }
      final eventId = 'topic_${record.id}';
      // 文件成功而 DB 标记失败时重试不重复写；用户已编辑同 ID 往事时也不覆盖。
      if (!notebook.events.any((e) => e.id == eventId)) {
        // 交接摘要会携带上段事实；归档只追加尚未存在的相同行。
        // 这是保守的文字去重，不声称能合并模型改写后的同义经历。
        String key(String line) =>
            line.trim().replaceFirst(RegExp(r'^[-*•]\s*'), '');
        final existing = notebook.events
            .expand((e) => e.body.split('\n\n来源：').first.split('\n'))
            .map(key)
            .where((line) => line.isNotEmpty)
            .toSet();
        final fresh = record.summary
            .split('\n')
            .where(
              (line) => key(line).isNotEmpty && !existing.contains(key(line)),
            )
            .join('\n');
        if (fresh.isEmpty) {
          await store.markArchived(record.id);
          return true;
        }
        await memory.save(
          notebook.copyWith(
            events: [
              ...notebook.events,
              ContactMemoryEvent(
                id: eventId,
                title:
                    '话题归档 ${record.createdAt.toLocal().toIso8601String().substring(0, 10)}',
                body:
                    '$fresh\n\n来源：话题整理 ${record.id}（数据库保留原始消息范围）。\n此为历史内容，不是当前角色卡或回复格式指令。',
                occurredAt: record.createdAt,
              ),
            ],
          ),
        );
      }
      await store.markArchived(record.id);
      return true;
    } catch (error) {
      AppLogger.warning(
        'TopicCompaction',
        '内容交接已保存，角色记忆待补写',
        metadata: {
          'conversationId': record.ownerId,
          'handoffId': record.id,
          'errorType': error.runtimeType.toString(),
        },
      );
      return false;
    }
  }

  @override
  Future<TopicHandoff?> current(String ownerId) async =>
      store.active(ownerId, await readBoundary(ownerId));

  @override
  Future<bool> retryArchive(String ownerId) => _run(ownerId, () async {
    var success = true;
    for (final record in await store.pending(ownerId)) {
      if (!await _archive(record)) success = false;
    }
    return success;
  });

  @override
  Future<void> undo(String ownerId) => _run(ownerId, () async {
    await store.undo(ownerId);
    await publishBoundary(ownerId);
  });
}
