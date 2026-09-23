import '../../chat/domain/message.dart';
import 'memory_item.dart';

/// 长期记忆存储。所有方法显式传 owner，不跟随当前打开的页面。
abstract interface class MemoryStorePort {
  Future<List<MemoryItem>> list(String ownerId, {MemoryLayer? layer});
  Future<MemoryItem?> get(String ownerId, String id);

  /// 用户在界面上新增或编辑；保存后自动锁定，记忆 Agent 不再改动。
  Future<MemoryItem> saveByUser({
    required String ownerId,
    String? id,
    required MemoryLayer layer,
    required String title,
    required String content,
  });
  Future<void> setLocked(String ownerId, String id, bool locked);
  Future<void> deleteByUser(String ownerId, String id);

  /// 在一个事务里执行记忆 Agent 的变更并推进提取书签。
  /// 重建代次与 [generation] 不一致时整批放弃并返回 null；
  /// 锁定条目、跨角色目标会被跳过；否则返回实际生效的条数。
  Future<int?> applyAgentOps(
    String ownerId,
    List<MemoryOp> ops, {
    required Message processedUntil,
    required int generation,
  });

  Future<MemoryProgress> progress(String ownerId);
  Future<void> setPaused(String ownerId, bool paused);
  Future<void> recordError(String ownerId, String? error);

  /// 从聊天记录重建：删除未锁定条目，书签归零，代次加一，重建目标设为 [until]。
  Future<void> resetForRebuild(String ownerId, Message until);

  /// 重建目标已处理完时清除它。
  Future<void> clearRebuildTarget(String ownerId, int generation);

  /// 清空聊天时调用：删除未锁定条目与进度，用户锁定的条目保留。
  Future<void> clearDerived(String ownerId);

  /// 关键词检索档案层；[query] 为原始文本，分词在实现内完成。
  Future<List<MemoryItem>> searchKeyword(
    String ownerId,
    String query, {
    int limit = 8,
  });
}

/// 窗口外记忆的检索接口。本期只有关键词实现；以后接向量检索只需再写一个实现。
abstract interface class MemoryRetriever {
  Future<List<MemoryItem>> retrieve(
    String ownerId,
    String query, {
    int limit = 6,
  });
}

/// 记忆 Agent 的模型端口：读一批原文和现有记忆，返回待执行的变更。
/// 只允许调用只读的记忆检索工具，不直接写库。
abstract interface class MemoryAgentPort {
  /// 一批原文允许的估算 tokens（按记忆模型窗口计算）。
  int get batchTokenBudget;

  Future<List<MemoryOp>> propose({
    required String ownerId,
    required List<MemoryItem> core,
    required List<MemoryItem> related,
    required List<Message> messages,
  });
}

/// 压缩摘要所覆盖到的原文 id（手动摘要的边界、自动摘要覆盖到的最后一条）。
/// 记忆 Agent 据此推算要处理到哪里，不需要单独登记任务。
typedef CompactedBoundaryReader = Future<Set<String>> Function(String ownerId);

/// 压缩成功后通知长期记忆维护。不阻塞调用方；任务本身已由摘要落库决定。
abstract interface class MemoryMaintenancePort {
  void schedule(String ownerId);
}
