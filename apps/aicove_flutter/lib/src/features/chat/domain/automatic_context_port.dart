import 'message.dart';
import 'topic_compaction_port.dart';

/// 自动摘要属于当前话题的请求上下文，不移动用户的新话题边界。
abstract interface class AutomaticContextStorePort {
  Future<TopicHandoff?> loadAutomatic(
    String owner,
    String? topicBoundary,
    List<Message> history,
  );
  Future<TopicHandoff> saveAutomatic(TopicSnapshot snapshot, String summary);
}

abstract interface class AutomaticContextPort {
  Future<TopicHandoff?> load(
    String owner,
    String? topicBoundary,
    List<Message> history,
  );
  Future<void> compact({
    required String owner,
    required String? topicBoundary,
    required List<Message> history,
    required TopicHandoff? previous,
    required bool keepOnlyLatestTurn,
    int retainTokens = 43520,
  });
}
