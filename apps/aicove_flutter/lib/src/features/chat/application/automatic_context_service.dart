import '../../../core/utils/token_estimator.dart';
import '../../memory/domain/compaction_memory.dart';
import '../domain/automatic_context_port.dart';
import '../domain/message.dart';
import '../domain/topic_compaction_port.dart';

class AutomaticContextService implements AutomaticContextPort {
  AutomaticContextService({
    required this.store,
    required this.summaryFactory,
    this.memory,
  });
  final CompactionMemoryPort? memory;
  final AutomaticContextStorePort store;
  final Future<TopicSummaryPort> Function() summaryFactory;
  final _busy = <String>{};

  @override
  Future<TopicHandoff?> load(
    String owner,
    String? topicBoundary,
    List<Message> history,
  ) async {
    await memory?.flush(owner);
    return store.loadAutomatic(owner, topicBoundary, history);
  }

  @override
  Future<void> compact({
    required String owner,
    required String? topicBoundary,
    required List<Message> history,
    required TopicHandoff? previous,
    required bool keepOnlyLatestTurn,
    int retainTokens = 43520,
  }) async {
    if (!_busy.add(owner)) {
      throw const TopicCompactionException('该对话正在自动压缩，请稍后重试。');
    }
    try {
      final covered = previous?.sourceIds.toSet() ?? <String>{};
      final pending = history.where((m) => !covered.contains(m.id)).toList();
      // 从 user 边界保留完整轮次，工具调用和结果随所属轮次保留。
      final starts = <int>[
        for (var i = 0; i < pending.length; i++)
          if (pending[i].role == 'user') i,
      ];
      if (starts.isEmpty || starts.last == 0) {
        throw const TopicCompactionException(
          '上下文已达到压缩阈值，但没有可压缩的旧轮次；请缩短当前消息或角色设置。',
        );
      }
      var cut = starts.last;
      var retained = pending
          .skip(cut)
          .fold<int>(
            0,
            (n, m) =>
                n +
                estimateTokenCount(
                  '${m.content} ${m.blocks?.map((b) => b.toJson()).toList() ?? []}',
                ),
          );
      if (!keepOnlyLatestTurn) {
        for (var i = starts.length - 2; i >= 1; i--) {
          final size = pending
              .sublist(starts[i], cut)
              .fold<int>(
                0,
                (n, m) =>
                    n +
                    estimateTokenCount(
                      '${m.content} ${m.blocks?.map((b) => b.toJson()).toList() ?? []}',
                    ),
              );
          if (retained + size > retainTokens) break;
          cut = starts[i];
          retained += size;
        }
      }
      final prefix = pending.take(cut).toList();
      final ids = {...covered, ...prefix.map((m) => m.id)};
      final snapshot = TopicSnapshot(
        ownerId: owner,
        previousBoundaryId: topicBoundary,
        allMessages: history.where((m) => ids.contains(m.id)).toList(),
        messages: prefix,
        previous: previous,
      );
      final summarizer = await summaryFactory();
      final output = await summarizeContext(
        summarizer,
        snapshot,
        memory: await memory?.prepare(owner),
        onProgress: (_, __) {},
        isCancelled: () => false,
      );
      validateTopicSummary(output.summary);
      await store.saveAutomatic(
        snapshot.withMemoryUpdates(output.memoryUpdates),
        output.summary,
      );
      await memory?.flush(owner);
    } finally {
      _busy.remove(owner);
    }
  }
}
