import '../../chat/domain/conversation.dart';
import '../../chat/domain/message.dart';
import '../../context/domain/context_summary.dart';

/// 通话只带最近这么多条原文，更早的文字聊天压成一份摘要。
const int kVoiceCallRecentMessages = 8;

/// 把当前话题的原文分成「压成摘要的较早部分」和「原样带上的最近几条」。
({List<Message> earlier, List<Message> recent}) splitVoiceCallWindow(
  List<Message> window, {
  int keepRecent = kVoiceCallRecentMessages,
}) {
  final cut = window.length > keepRecent ? window.length - keepRecent : 0;
  return (earlier: window.sublist(0, cut), recent: window.sublist(cut));
}

/// 接通前文字聊天的压缩摘要（ADR0074 决定 2）：复用自动压缩 Agent，在已有的
/// 自动摘要上合并没覆盖到的较早原文。
///
/// 结果是派生数据，只缓存在内存里，不写 `context_summaries`，不影响打字聊天的
/// 压缩进度；同一段原文再次通话直接复用。
class VoiceCallContextBrief {
  VoiceCallContextBrief({required this.store, required this.summarizer});

  final ContextSummaryStorePort store;
  final Future<ContextSummarizerPort> Function() summarizer;
  final Map<String, String> _cache = {};

  /// [window] 是当前话题的全部原文，[earlier] 是其中要压成摘要的较早部分。
  Future<String?> build(
    Conversation conversation,
    List<Message> window,
    List<Message> earlier,
  ) async {
    if (earlier.isEmpty) return null;
    final previous = await store.loadAuto(
      conversation.id,
      conversation.contextStartMessageId,
      window,
    );
    final covered = previous?.sourceIds.toSet() ?? const <String>{};
    final pending = earlier.where((m) => !covered.contains(m.id)).toList();
    if (pending.isEmpty) return previous?.summary;
    final snapshot = ContextSnapshot(
      ownerId: conversation.id,
      previousBoundaryId: conversation.contextStartMessageId,
      allMessages: earlier,
      messages: pending,
      previous: previous,
    );
    final cached = _cache[snapshot.id];
    if (cached != null) return cached;
    final summary = await (await summarizer()).summarize(
      snapshot,
      kind: ContextSummaryKind.auto,
      onProgress: (_, _) {},
      isCancelled: () => false,
    );
    return _cache[snapshot.id] = summary;
  }
}
