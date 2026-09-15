import 'dart:convert';
import 'package:drift/drift.dart';
import '../../../core/database/database.dart' as db;
import '../../memory/domain/compaction_memory.dart';
import '../../memory/data/sqlite_compaction_memory_queue.dart';
import '../domain/runtime_context_port.dart';
import '../domain/message.dart';
import '../domain/topic_compaction_port.dart';

class SqliteRuntimeContextStore implements RuntimeContextStorePort {
  SqliteRuntimeContextStore(this.database, this.loadRaw);
  final Future<List<Message>> Function(String) loadRaw;
  final db.AppDatabase database;
  @override
  Future<String> save({
    required String owner,
    required List<Map<String, dynamic>> source,
    required List<Map<String, dynamic>> replacement,
    List<CompactionMemoryUpdate> updates = const [],
    String? expectedSourceId,
  }) async {
    final text = jsonEncode(source);
    final id = memoryTextDigest('$owner\n$text\n${jsonEncode(replacement)}');
    await database.transaction(() async {
      final raw = await loadRaw(owner);
      final role = await (database.select(
        database.conversations,
      )..where((t) => t.id.equals(owner))).getSingleOrNull();
      if (role == null || role.deletedAt != null) {
        throw StateError('Conversation unavailable');
      }
      if (expectedSourceId != null) {
        final expected = await database
            .customSelect(
              'SELECT raw_ids, raw_digest FROM runtime_context_records WHERE id = ? AND owner_id = ?',
              variables: [Variable(expectedSourceId), Variable(owner)],
            )
            .getSingleOrNull();
        if (expected == null) throw StateError('Context source unavailable');
        final ids = (jsonDecode(expected.read<String>('raw_ids')) as List)
            .cast<String>()
            .toSet();
        final selected = raw.where((m) => ids.contains(m.id)).toList();
        if (selected.length != ids.length ||
            topicSourceDigest(selected) !=
                expected.read<String>('raw_digest')) {
          throw const TopicCompactionException('整理期间原始聊天已变化，本轮未采用旧摘要。');
        }
      }
      await database.customStatement(
        'INSERT OR IGNORE INTO runtime_context_records (id,owner_id,source_json,replacement_json,created_at,raw_ids,raw_digest) VALUES (?,?,?,?,?,?,?)',
        [
          id,
          owner,
          text,
          jsonEncode(replacement),
          DateTime.now().millisecondsSinceEpoch,
          jsonEncode(raw.map((m) => m.id).toList()),
          topicSourceDigest(raw),
        ],
      );
      await enqueueCompactionMemory(
        database,
        id: id,
        owner: owner,
        sourceIds: raw.map((m) => m.id).toList(),
        digest: topicSourceDigest(raw),
        updates: updates,
        runtimeRecord: id,
      );
    });
    return id;
  }

  @override
  Future<String?> read(
    String owner,
    String id,
    int messageIndex, {
    int offset = 0,
    String? query,
  }) async {
    final row = await database
        .customSelect(
          'SELECT source_json FROM runtime_context_records WHERE id = ? AND owner_id = ? AND EXISTS (SELECT 1 FROM conversations WHERE id = ? AND deleted_at IS NULL)',
          variables: [Variable(id), Variable(owner), Variable(owner)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final messages = jsonDecode(row.read<String>('source_json')) as List;
    if (messageIndex < 0 || messageIndex >= messages.length || offset < 0) {
      return null;
    }
    final content = messages[messageIndex]['content'];
    final text = content is String ? content : jsonEncode(content);
    final runes = text.runes.toList();
    var start = offset.clamp(0, runes.length);
    if (query != null && query.isNotEmpty) {
      final suffix = String.fromCharCodes(runes.skip(start));
      final found = suffix.indexOf(query);
      if (found < 0) return jsonEncode({'found': false});
      start += suffix.substring(0, found).runes.length;
    }
    final end = (start + 2048).clamp(0, runes.length);
    return jsonEncode({
      'text': String.fromCharCodes(runes.sublist(start, end)),
      'offset': start,
      'nextOffset': end < runes.length ? end : null,
      'total': runes.length,
    });
  }
}
