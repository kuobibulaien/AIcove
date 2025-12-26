import 'package:drift/drift.dart';
import '../database.dart';

/// 消息 Repository
class MessageRepository {
  final AppDatabase _db;

  MessageRepository(this._db);

  /// 获取会话的消息（分页，不含已删除）
  Future<List<Message>> getByConversation(
    String conversationId, {
    int limit = 50,
    int? beforeTime,
  }) async {
    var query = _db.select(_db.messages)
      ..where((t) =>
          t.conversationId.equals(conversationId) &
          t.deletedAt.isNull() &
          t.replacedBy.isNull());

    if (beforeTime != null) {
      query = query..where((t) => t.createdAt.isSmallerThanValue(beforeTime));
    }

    query
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(limit);

    return query.get();
  }

  /// 获取单条消息
  Future<Message?> getById(String id) async {
    return (_db.select(_db.messages)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 创建消息
  Future<void> insert(MessagesCompanion data) async {
    await _db.into(_db.messages).insert(data);
  }

  /// 批量创建消息
  Future<void> insertAll(List<MessagesCompanion> messages) async {
    await _db.batch((batch) {
      batch.insertAll(_db.messages, messages);
    });
  }

  /// 更新消息状态
  Future<void> updateStatus(String id, String status) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(id)))
        .write(MessagesCompanion(status: Value(status)));
  }

  /// 软删除消息
  Future<void> softDelete(String id, int deletedAt, int purgeAt) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(id)))
        .write(MessagesCompanion(
      deletedAt: Value(deletedAt),
      purgeAt: Value(purgeAt),
    ));
  }

  /// 重生成覆盖（旧消息标记 replacedBy）
  Future<void> markReplaced(String oldId, String newId, int deletedAt, int purgeAt) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(oldId)))
        .write(MessagesCompanion(
      replacedBy: Value(newId),
      deletedAt: Value(deletedAt),
      purgeAt: Value(purgeAt),
    ));
  }

  /// 获取会话最后一条消息
  Future<Message?> getLastMessage(String conversationId) async {
    return (_db.select(_db.messages)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.deletedAt.isNull() &
              t.replacedBy.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// 获取 since 之后创建的消息（用于同步）
  Future<List<Message>> getChangesSince(int since) async {
    return (_db.select(_db.messages)
          ..where((t) => t.createdAt.isBiggerThanValue(since)))
        .get();
  }

  /// 物理删除过期数据
  Future<int> purgeExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (_db.delete(_db.messages)
          ..where((t) => t.purgeAt.isNotNull() & t.purgeAt.isSmallerOrEqualValue(now)))
        .go();
  }

  /// 删除会话的所有消息
  Future<int> deleteByConversation(String conversationId) async {
    return (_db.delete(_db.messages)
          ..where((t) => t.conversationId.equals(conversationId)))
        .go();
  }
}
