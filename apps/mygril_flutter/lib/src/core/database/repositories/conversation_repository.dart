import 'package:drift/drift.dart';
import '../database.dart';

/// 会话 Repository
class ConversationRepository {
  final AppDatabase _db;

  ConversationRepository(this._db);

  /// 获取所有会话（不含已删除）
  Future<List<Conversation>> getAll() async {
    return (_db.select(_db.conversations)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.isPinned),
            (t) => OrderingTerm.desc(t.updatedAt),
          ]))
        .get();
  }

  /// 获取单个会话
  Future<Conversation?> getById(String id) async {
    return (_db.select(_db.conversations)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 创建或更新会话
  Future<void> upsert(ConversationsCompanion data) async {
    await _db.into(_db.conversations).insertOnConflictUpdate(data);
  }

  /// 软删除会话
  Future<void> softDelete(String id, int deletedAt, int purgeAt) async {
    await (_db.update(_db.conversations)..where((t) => t.id.equals(id)))
        .write(ConversationsCompanion(
      deletedAt: Value(deletedAt),
      purgeAt: Value(purgeAt),
    ));
  }

  /// 恢复会话
  Future<void> restore(String id) async {
    await (_db.update(_db.conversations)..where((t) => t.id.equals(id)))
        .write(const ConversationsCompanion(
      deletedAt: Value(null),
      purgeAt: Value(null),
    ));
  }

  /// 更新会话摘要
  Future<void> updateSummary(
      String id, String lastMessage, int lastMessageTime) async {
    await (_db.update(_db.conversations)..where((t) => t.id.equals(id)))
        .write(ConversationsCompanion(
      lastMessage: Value(lastMessage),
      lastMessageTime: Value(lastMessageTime),
      updatedAt: Value(lastMessageTime),
    ));
  }

  /// 获取回收站中的会话
  Future<List<Conversation>> getDeleted() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (_db.select(_db.conversations)
          ..where((t) => t.deletedAt.isNotNull() & t.purgeAt.isBiggerThanValue(now)))
        .get();
  }

  /// 获取 since 之后更新的会话（用于同步）
  Future<List<Conversation>> getChangesSince(int since) async {
    return (_db.select(_db.conversations)
          ..where((t) => t.updatedAt.isBiggerThanValue(since)))
        .get();
  }

  /// 物理删除过期数据
  Future<int> purgeExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (_db.delete(_db.conversations)
          ..where((t) => t.purgeAt.isNotNull() & t.purgeAt.isSmallerOrEqualValue(now)))
        .go();
  }
}
