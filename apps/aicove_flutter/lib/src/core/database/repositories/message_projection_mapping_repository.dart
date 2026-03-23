import 'package:drift/drift.dart';
import '../database.dart';

class MessageProjectionMappingRepository {
  final AppDatabase _db;

  MessageProjectionMappingRepository(this._db);

  Future<List<MessageProjectionMapping>> getByConversation(
    String conversationId,
  ) {
    return (_db.select(_db.messageProjectionMappings)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.segmentIndex),
            (t) => OrderingTerm.asc(t.projectedMessageId),
          ]))
        .get();
  }

  Future<List<MessageProjectionMapping>> getByRawMessage(String rawMessageId) {
    return (_db.select(_db.messageProjectionMappings)
          ..where((t) => t.rawMessageId.equals(rawMessageId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.segmentIndex),
            (t) => OrderingTerm.asc(t.projectedMessageId),
          ]))
        .get();
  }

  Future<void> upsert(MessageProjectionMappingsCompanion data) async {
    await _db.into(_db.messageProjectionMappings).insertOnConflictUpdate(data);
  }

  Future<void> replaceForRawMessage({
    required String rawMessageId,
    required List<MessageProjectionMappingsCompanion> mappings,
  }) async {
    await _db.transaction(() async {
      await (_db.delete(_db.messageProjectionMappings)
            ..where((t) => t.rawMessageId.equals(rawMessageId)))
          .go();
      if (mappings.isEmpty) {
        return;
      }
      await _db.batch((batch) {
        batch.insertAll(_db.messageProjectionMappings, mappings);
      });
    });
  }

  Future<void> replaceForConversation({
    required String conversationId,
    required List<MessageProjectionMappingsCompanion> mappings,
  }) async {
    await _db.transaction(() async {
      await (_db.delete(_db.messageProjectionMappings)
            ..where((t) => t.conversationId.equals(conversationId)))
          .go();
      if (mappings.isEmpty) {
        return;
      }
      await _db.batch((batch) {
        batch.insertAll(_db.messageProjectionMappings, mappings);
      });
    });
  }

  Future<int> deleteByConversation(String conversationId) {
    return (_db.delete(_db.messageProjectionMappings)
          ..where((t) => t.conversationId.equals(conversationId)))
        .go();
  }

  Future<int> deleteByRawMessage(String rawMessageId) {
    return (_db.delete(_db.messageProjectionMappings)
          ..where((t) => t.rawMessageId.equals(rawMessageId)))
        .go();
  }
}
