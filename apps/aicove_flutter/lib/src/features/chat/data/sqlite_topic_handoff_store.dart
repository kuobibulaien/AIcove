import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../../../core/database/database.dart' as db;
import '../../../core/app_logger.dart';
import '../domain/message.dart';
import '../domain/automatic_context_port.dart';
import '../../memory/data/sqlite_compaction_memory_queue.dart';
import '../domain/topic_compaction_port.dart';

class SqliteTopicHandoffStore
    implements TopicHandoffStorePort, AutomaticContextStorePort {
  SqliteTopicHandoffStore(this.database, this.loadMessages);
  final db.AppDatabase database;
  final Future<List<Message>> Function(String owner) loadMessages;

  @override
  Future<TopicHandoff?> loadAutomatic(
    String owner,
    String? topicBoundary,
    List<Message> history,
  ) async {
    final rows = await database
        .customSelect(
          "SELECT * FROM topic_handoffs WHERE owner_id = ? "
          "AND previous_boundary_id IS ? AND memory_state = 'automatic' "
          "ORDER BY created_at DESC, rowid DESC LIMIT 1",
          variables: [Variable(owner), Variable<String>(topicBoundary)],
        )
        .get();
    if (rows.isEmpty) return null;
    final record = _decode(rows.single);
    // 历史重放、编辑和删除使摘要失效，重新使用原文；不倒灌未来内容。
    if (!_valid(record, history)) return null;
    validateTopicSummary(record.summary);
    return record;
  }

  @override
  Future<TopicHandoff> saveAutomatic(
    TopicSnapshot snapshot,
    String summary,
  ) async {
    validateTopicSummary(summary);
    return database.transaction(() async {
      final owner = await _owner(snapshot.ownerId);
      final all = await loadMessages(snapshot.ownerId);
      final ids = snapshot.sourceIds.toSet();
      final sources = all.where((m) => ids.contains(m.id)).toList();
      if (owner.contextStartMessageId != snapshot.previousBoundaryId ||
          sources.length != ids.length ||
          topicSourceDigest(sources) != snapshot.sourceDigest) {
        throw const TopicCompactionException('压缩期间聊天已变化，本轮未发送，请重试。');
      }
      final created = DateTime.now();
      final id = 'auto_${snapshot.id}';
      await database.customStatement(
        """
INSERT OR REPLACE INTO topic_handoffs
(id, owner_id, boundary_id, previous_boundary_id, summary, source_ids, source_digest, created_at, memory_state)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'automatic')
""",
        [
          id,
          snapshot.ownerId,
          snapshot.boundaryId,
          snapshot.previousBoundaryId,
          summary.trim(),
          jsonEncode(snapshot.sourceIds),
          snapshot.sourceDigest,
          created.millisecondsSinceEpoch,
        ],
      );
      await enqueueCompactionMemory(
        database,
        id: id,
        owner: snapshot.ownerId,
        sourceIds: snapshot.sourceIds,
        digest: snapshot.sourceDigest,
        updates: snapshot.memoryUpdates,
      );
      AppLogger.info(
        'AutomaticContext',
        '自动压缩已保存',
        metadata: {
          'conversationId': snapshot.ownerId,
          'sourceCount': ids.length,
        },
      );
      return TopicHandoff(
        id: id,
        ownerId: snapshot.ownerId,
        boundaryId: snapshot.boundaryId,
        previousBoundaryId: snapshot.previousBoundaryId,
        summary: summary.trim(),
        sourceIds: snapshot.sourceIds,
        sourceDigest: snapshot.sourceDigest,
        createdAt: created,
        memoryState: 'automatic',
      );
    });
  }

  Future<db.Conversation> _owner(String owner) async {
    final row =
        await (database.select(database.conversations)
              ..where((t) => t.id.equals(owner) & t.deletedAt.isNull()))
            .getSingleOrNull();
    if (owner.trim().isEmpty || row == null) {
      throw const TopicCompactionException('角色不存在或已删除。');
    }
    return row;
  }

  Future<TopicHandoff?> _record(String owner, String? boundary) async {
    if (boundary == null) return null;
    final row = await database
        .customSelect(
          'SELECT * FROM topic_handoffs WHERE owner_id = ? AND boundary_id = ? '
          "AND memory_state != 'automatic' ORDER BY created_at DESC, rowid DESC LIMIT 1",
          variables: [Variable(owner), Variable(boundary)],
        )
        .getSingleOrNull();
    return row == null ? null : _decode(row);
  }

  TopicHandoff _decode(QueryRow row) => TopicHandoff(
    id: row.read<String>('id'),
    ownerId: row.read<String>('owner_id'),
    boundaryId: row.read<String>('boundary_id'),
    previousBoundaryId: row.readNullable<String>('previous_boundary_id'),
    summary: row.read<String>('summary'),
    sourceIds: (jsonDecode(row.read<String>('source_ids')) as List)
        .cast<String>(),
    sourceDigest: row.read<String>('source_digest'),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at')),
    memoryState: row.read<String>('memory_state'),
  );

  bool _valid(TopicHandoff record, List<Message> all) {
    final ids = record.sourceIds.toSet();
    final sources = all.where((m) => ids.contains(m.id)).toList();
    return all.any((m) => m.id == record.boundaryId) &&
        sources.length == ids.length &&
        topicSourceDigest(sources) == record.sourceDigest;
  }

  @override
  Future<TopicHandoff?> active(String ownerId, String? boundaryId) async {
    if (boundaryId == null) return null;
    final owner = await _owner(ownerId);
    if (owner.contextStartMessageId != boundaryId) return null;
    final record = await _record(ownerId, boundaryId);
    if (record == null) return null;
    if (!_valid(record, await loadMessages(ownerId))) {
      AppLogger.warning(
        'TopicCompaction',
        '摘要来源已变化，本轮不使用旧摘要',
        metadata: {'conversationId': ownerId, 'handoffId': record.id},
      );
      return null;
    }
    validateTopicSummary(record.summary);
    return record;
  }

  @override
  Future<TopicSnapshot> snapshot(String ownerId) async {
    final owner = await _owner(ownerId);
    final all = await loadMessages(ownerId);
    if (all.isEmpty) throw const TopicCompactionException('当前没有可整理的聊天记录。');
    if (all.any((m) => m.status == 'sending')) {
      throw const TopicCompactionException('请等本轮回复结束后再压缩。');
    }
    final previous = await _record(ownerId, owner.contextStartMessageId);
    if (previous != null && !_valid(previous, all)) {
      throw const TopicCompactionException('旧摘要的来源已被编辑，请先撤销上次压缩，再重新整理。');
    }
    var start = 0;
    if (owner.contextStartMessageId != null) {
      final index = all.indexWhere((m) => m.id == owner.contextStartMessageId);
      if (index < 0) throw const TopicCompactionException('话题边界已失效，请先撤销上次压缩。');
      start = index + 1;
    }
    final messages = all
        .skip(start)
        .where(
          (m) =>
              (m.role == 'user' || m.role == 'assistant') &&
              m.status != 'failed',
        )
        .toList();
    if (messages.isEmpty) {
      throw const TopicCompactionException('新话题还没有可整理的消息，无需再次压缩。');
    }
    return TopicSnapshot(
      ownerId: ownerId,
      previousBoundaryId: owner.contextStartMessageId,
      allMessages: all,
      messages: messages,
      previous: previous,
    );
  }

  @override
  Future<TopicHandoff> commit(
    TopicSnapshot snapshot,
    String summary, {
    required bool archive,
  }) async {
    validateTopicSummary(summary);
    return database.transaction(() async {
      final owner = await _owner(snapshot.ownerId);
      final all = await loadMessages(snapshot.ownerId);
      if (owner.contextStartMessageId != snapshot.previousBoundaryId ||
          topicSourceDigest(all) != snapshot.revision) {
        throw const TopicCompactionException('聊天已发生变化，草稿仍保留；请重新整理后再开启新话题。');
      }
      final created = DateTime.now();
      final id = sha256
          .convert(utf8.encode(jsonEncode([snapshot.id, summary.trim()])))
          .toString();
      await database.customStatement(
        '''
INSERT OR REPLACE INTO topic_handoffs
(id, owner_id, boundary_id, previous_boundary_id, summary, source_ids, source_digest, created_at, memory_state)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
        [
          id,
          snapshot.ownerId,
          snapshot.boundaryId,
          snapshot.previousBoundaryId,
          summary.trim(),
          jsonEncode(snapshot.sourceIds),
          snapshot.sourceDigest,
          created.millisecondsSinceEpoch,
          archive
              ? (snapshot.memoryUpdatesPrepared ? 'pending_updates' : 'pending')
              : 'off',
        ],
      );
      if (archive) {
        await enqueueCompactionMemory(
          database,
          id: id,
          owner: snapshot.ownerId,
          sourceIds: snapshot.sourceIds,
          digest: snapshot.sourceDigest,
          updates: snapshot.memoryUpdates,
        );
      }
      await (database.update(
        database.conversations,
      )..where((t) => t.id.equals(snapshot.ownerId))).write(
        db.ConversationsCompanion(
          contextStartMessageId: Value(snapshot.boundaryId),
          updatedAt: Value(created.millisecondsSinceEpoch),
        ),
      );
      return (await _record(snapshot.ownerId, snapshot.boundaryId))!;
    });
  }

  @override
  Future<List<TopicHandoff>> pending(String ownerId) async {
    await _owner(ownerId);
    final rows = await database
        .customSelect(
          "SELECT * FROM topic_handoffs WHERE owner_id = ? AND memory_state IN ('pending', 'pending_updates') ORDER BY created_at LIMIT 32",
          variables: [Variable(ownerId)],
        )
        .get();
    final all = await loadMessages(ownerId);
    final result = <TopicHandoff>[];
    for (final row in rows) {
      final record = _decode(row);
      if (record.memoryState == 'pending' ||
          record.memoryState == 'pending_updates') {
        if (!_valid(record, all)) {
          throw const TopicCompactionException('待归档摘要的来源已变化，为避免保存错误记忆，本批未补写。');
        }
        result.add(record);
      }
    }
    return result;
  }

  @override
  Future<void> markArchived(String id) => database.customStatement(
    "UPDATE topic_handoffs SET memory_state = 'archived' WHERE id = ?",
    [id],
  );

  @override
  Future<void> undo(String ownerId) => database.transaction(() async {
    final owner = await _owner(ownerId);
    final record = await _record(ownerId, owner.contextStartMessageId);
    if (record == null) {
      throw const TopicCompactionException('没有可以撤销的压缩记录。');
    }
    // 撤销尚未完成的归档授权；已写入文件的记忆不回滚。
    await database.customStatement(
      "UPDATE topic_handoffs SET memory_state = 'cancelled' WHERE id = ? AND memory_state IN ('pending', 'pending_updates')",
      [record.id],
    );
    await database.customStatement(
      "UPDATE compaction_memory_jobs SET state = 'discarded' WHERE id = ? AND state = 'pending'",
      [record.id],
    );
    // 新消息保留；撤销只恢复上一次上下文边界，不回滚角色卡或 MD。
    await (database.update(
      database.conversations,
    )..where((t) => t.id.equals(ownerId))).write(
      db.ConversationsCompanion(
        contextStartMessageId: Value(record.previousBoundaryId),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  });
}
