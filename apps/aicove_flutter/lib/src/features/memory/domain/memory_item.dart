import '../../chat/domain/message.dart';

/// 长期记忆的两层：常驻层每轮都注入；档案层按本轮对话检索后注入。
enum MemoryLayer {
  core,
  archive;

  static MemoryLayer parse(String value) =>
      value == 'core' ? MemoryLayer.core : MemoryLayer.archive;
}

/// 一条长期记忆。真相源是 SQLite `memory_items`，按角色（owner）隔离。
class MemoryItem {
  const MemoryItem({
    required this.id,
    required this.ownerId,
    required this.layer,
    required this.title,
    required this.content,
    required this.sourceIds,
    required this.locked,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id, ownerId, title, content;
  final MemoryLayer layer;
  final List<String> sourceIds;

  /// 用户手动编辑或锁定过；记忆 Agent 只能读，不能改或删。
  final bool locked;
  final DateTime createdAt, updatedAt;

  MemoryItem copyWith({
    MemoryLayer? layer,
    String? title,
    String? content,
    List<String>? sourceIds,
    bool? locked,
    DateTime? updatedAt,
  }) => MemoryItem(
    id: id,
    ownerId: ownerId,
    layer: layer ?? this.layer,
    title: title ?? this.title,
    content: content ?? this.content,
    sourceIds: sourceIds ?? this.sourceIds,
    locked: locked ?? this.locked,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// 记忆 Agent 提出的一次变更；由代码校验后在事务里执行。
sealed class MemoryOp {
  const MemoryOp();
}

class AddMemory extends MemoryOp {
  const AddMemory({
    required this.layer,
    required this.title,
    required this.content,
    required this.sourceIds,
  });
  final MemoryLayer layer;
  final String title, content;
  final List<String> sourceIds;
}

class UpdateMemory extends MemoryOp {
  const UpdateMemory({
    required this.id,
    this.layer,
    this.title,
    this.content,
    this.sourceIds = const [],
  });
  final String id;
  final MemoryLayer? layer;
  final String? title, content;
  final List<String> sourceIds;
}

class DeleteMemory extends MemoryOp {
  const DeleteMemory(this.id);
  final String id;
}

/// 每个角色的提取进度。
/// - `until`：这条（含）之前的原文已经交给记忆 Agent 处理过；
/// - `rebuildUntil`：从聊天记录重建时要处理到的位置；
/// - `generation`：重建代次，重建一次加一，旧任务据此放弃写入。
/// 压缩带来的处理目标不存这里，而是从 `context_summaries` 推算。
class MemoryProgress {
  const MemoryProgress({
    required this.ownerId,
    this.untilAt,
    this.untilId,
    this.rebuildUntilId,
    this.generation = 0,
    this.paused = false,
    this.lastError,
  });
  final String ownerId;
  final int? untilAt;
  final String? untilId, rebuildUntilId, lastError;
  final int generation;
  final bool paused;

  /// 返回 [ordered]（按时间排好的原文）里尚未处理部分的起始下标。
  int pendingStart(List<Message> ordered) {
    if (untilId == null && untilAt == null) return 0;
    final index = ordered.indexWhere((m) => m.id == untilId);
    if (index >= 0) return index + 1;
    // 书签那条消息被删了：退回按时间比较。
    final next = ordered.indexWhere(
      (m) => m.createdAt.millisecondsSinceEpoch > (untilAt ?? 0),
    );
    return next < 0 ? ordered.length : next;
  }
}

class MemoryException implements Exception {
  const MemoryException(this.message);
  final String message;
  @override
  String toString() => message;
}
