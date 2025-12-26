import 'package:drift/drift.dart';
import '../database.dart';

/// 消息内容块 Repository
class MessageBlockRepository {
  final AppDatabase _db;

  MessageBlockRepository(this._db);

  /// 获取消息的所有内容块
  Future<List<MessageBlock>> getByMessage(String messageId) async {
    return (_db.select(_db.messageBlocks)
          ..where((t) => t.messageId.equals(messageId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// 批量获取多条消息的内容块
  Future<List<MessageBlock>> getByMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return [];
    return (_db.select(_db.messageBlocks)
          ..where((t) => t.messageId.isIn(messageIds) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// 获取单个内容块
  Future<MessageBlock?> getById(String id) async {
    return (_db.select(_db.messageBlocks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 创建内容块
  Future<void> insert(MessageBlocksCompanion data) async {
    await _db.into(_db.messageBlocks).insert(data);
  }

  /// 批量创建内容块
  Future<void> insertAll(List<MessageBlocksCompanion> blocks) async {
    await _db.batch((batch) {
      batch.insertAll(_db.messageBlocks, blocks);
    });
  }

  /// 更新内容块
  Future<void> update(String id, MessageBlocksCompanion data) async {
    await (_db.update(_db.messageBlocks)..where((t) => t.id.equals(id)))
        .write(data);
  }

  /// 软删除内容块
  Future<void> softDelete(String id, int deletedAt) async {
    await (_db.update(_db.messageBlocks)..where((t) => t.id.equals(id)))
        .write(MessageBlocksCompanion(deletedAt: Value(deletedAt)));
  }

  /// 删除消息的所有内容块
  Future<int> deleteByMessage(String messageId) async {
    return (_db.delete(_db.messageBlocks)
          ..where((t) => t.messageId.equals(messageId)))
        .go();
  }
}
