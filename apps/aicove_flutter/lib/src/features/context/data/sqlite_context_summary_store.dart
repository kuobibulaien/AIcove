import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database.dart' as db;
import '../../chat/domain/message.dart';
import '../domain/context_summary.dart';

/// `context_summaries` 的专用 Adapter（参数化 SQL，不走 Drift 表定义）。
class SqliteContextSummaryStore implements ContextSummaryStorePort {
  SqliteContextSummaryStore(this.database, this.loadMessages);
  final db.AppDatabase database;
  final Future<List<Message>> Function(String ownerId) loadMessages;

  static const _insert = '''
INSERT OR REPLACE INTO context_summaries
(id, owner_id, kind, boundary_id, topic_boundary, summary, source_ids, source_digest, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''';

  Future<db.Conversation> _owner(String owner) async {
    final row =
        await (database.select(database.conversations)
              ..where((t) => t.id.equals(owner) & t.deletedAt.isNull()))
            .getSingleOrNull();
    if (owner.trim().isEmpty || row == null) {
      throw const ContextCompactionException('角色不存在或已删除。');
    }
    return row;
  }

  ContextSummary _decode(QueryRow row) => ContextSummary(
    id: row.read<String>('id'),
    ownerId: row.read<String>('owner_id'),
    kind: row.read<String>('kind') == 'auto'
        ? ContextSummaryKind.auto
        : ContextSummaryKind.manual,
    boundaryId: row.read<String>('boundary_id'),
    topicBoundary: row.readNullable<String>('topic_boundary'),
    summary: row.read<String>('summary'),
    sourceIds: (jsonDecode(row.read<String>('source_ids')) as List)
        .cast<String>(),
    sourceDigest: row.read<String>('source_digest'),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at')),
  );

  bool _valid(ContextSummary record, List<Message> all) {
    final ids = record.sourceIds.toSet();
    final sources = all.where((m) => ids.contains(m.id)).toList();
    return all.any((m) => m.id == record.boundaryId) &&
        sources.length == ids.length &&
        contextSourceDigest(sources) == record.sourceDigest;
  }

  Future<ContextSummary?> _manualRecord(String owner, String? boundary) async {
    if (boundary == null) return null;
    final row = await database
        .customSelect(
          "SELECT * FROM context_summaries WHERE owner_id = ? AND kind = 'manual' "
          'AND boundary_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1',
          variables: [Variable(owner), Variable(boundary)],
        )
        .getSingleOrNull();
    return row == null ? null : _decode(row);
  }

  List<Object?> _row(
    String id,
    ContextSnapshot snapshot,
    ContextSummaryKind kind,
    String summary,
    DateTime created,
  ) => [
    id,
    snapshot.ownerId,
    kind.name,
    snapshot.boundaryId,
    snapshot.previousBoundaryId,
    summary.trim(),
    jsonEncode(snapshot.sourceIds),
    snapshot.sourceDigest,
    created.millisecondsSinceEpoch,
  ];

  @override
  Future<ContextSnapshot> manualSnapshot(String ownerId) async {
    final owner = await _owner(ownerId);
    final all = await loadMessages(ownerId);
    if (all.isEmpty) {
      throw const ContextCompactionException('当前没有可整理的聊天记录。');
    }
    if (all.any((m) => m.status == 'sending')) {
      throw const ContextCompactionException('请等本轮回复结束后再压缩。');
    }
    final previous = await _manualRecord(ownerId, owner.contextStartMessageId);
    if (previous != null && !_valid(previous, all)) {
      throw const ContextCompactionException('旧摘要的来源已被编辑，请先撤销上次压缩，再重新整理。');
    }
    var start = 0;
    if (owner.contextStartMessageId != null) {
      final index = all.indexWhere((m) => m.id == owner.contextStartMessageId);
      if (index < 0) {
        throw const ContextCompactionException('话题边界已失效，请先撤销上次压缩。');
      }
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
      throw const ContextCompactionException('新话题还没有可整理的消息，无需再次压缩。');
    }
    return ContextSnapshot(
      ownerId: ownerId,
      previousBoundaryId: owner.contextStartMessageId,
      allMessages: all,
      messages: messages,
      previous: previous,
    );
  }

  @override
  Future<ContextSummary?> manualFor(String ownerId, String? boundaryId) async {
    if (boundaryId == null) return null;
    final owner = await _owner(ownerId);
    if (owner.contextStartMessageId != boundaryId) return null;
    final record = await _manualRecord(ownerId, boundaryId);
    if (record == null) return null;
    if (!_valid(record, await loadMessages(ownerId))) {
      AppLogger.warning(
        'ContextSummary',
        '摘要来源已变化，本轮不使用旧摘要',
        metadata: {'conversationId': ownerId, 'summaryId': record.id},
      );
      return null;
    }
    validateContextSummary(record.summary);
    return record;
  }

  @override
  Future<ContextSummary> commitManual(
    ContextSnapshot snapshot,
    String summary,
  ) async {
    validateContextSummary(summary);
    return database.transaction(() async {
      final owner = await _owner(snapshot.ownerId);
      final all = await loadMessages(snapshot.ownerId);
      if (owner.contextStartMessageId != snapshot.previousBoundaryId ||
          contextSourceDigest(all) != snapshot.revision) {
        throw const ContextCompactionException('聊天已发生变化，草稿仍保留；请重新整理后再开启新话题。');
      }
      final created = DateTime.now();
      final id = sha256
          .convert(utf8.encode(jsonEncode([snapshot.id, summary.trim()])))
          .toString();
      await database.customStatement(
        _insert,
        _row(id, snapshot, ContextSummaryKind.manual, summary, created),
      );
      await (database.update(
        database.conversations,
      )..where((t) => t.id.equals(snapshot.ownerId))).write(
        db.ConversationsCompanion(
          contextStartMessageId: Value(snapshot.boundaryId),
          updatedAt: Value(created.millisecondsSinceEpoch),
        ),
      );
      return (await _manualRecord(snapshot.ownerId, snapshot.boundaryId))!;
    });
  }

  @override
  Future<ContextSummary> saveRecoveredManual(
    ContextSnapshot snapshot,
    String summary,
  ) async {
    validateContextSummary(summary);
    return database.transaction(() async {
      final owner = await _owner(snapshot.ownerId);
      if (owner.contextStartMessageId != snapshot.boundaryId) {
        throw const ContextCompactionException('整理期间话题边界已变化，本轮未发送，请重试。');
      }
      final id = 'recovered_${snapshot.id}';
      await database.customStatement(
        _insert,
        _row(id, snapshot, ContextSummaryKind.manual, summary, DateTime.now()),
      );
      return (await _manualRecord(snapshot.ownerId, snapshot.boundaryId))!;
    });
  }

  @override
  Future<void> undoManual(String ownerId) => database.transaction(() async {
    final owner = await _owner(ownerId);
    final record = await _manualRecord(ownerId, owner.contextStartMessageId);
    if (record == null) {
      throw const ContextCompactionException('没有可以撤销的压缩记录。');
    }
    // 新消息保留；撤销只恢复上一次边界。尚未整理进长期记忆的部分随之取消，
    // 已写入的长期记忆不回滚。
    await database.customStatement(
      'DELETE FROM context_summaries WHERE id = ?',
      [record.id],
    );
    await (database.update(
      database.conversations,
    )..where((t) => t.id.equals(ownerId))).write(
      db.ConversationsCompanion(
        contextStartMessageId: Value(record.topicBoundary),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  });

  @override
  Future<ContextSummary?> loadAuto(
    String ownerId,
    String? topicBoundary,
    List<Message> history,
  ) async {
    final row = await database
        .customSelect(
          "SELECT * FROM context_summaries WHERE owner_id = ? AND kind = 'auto' "
          'AND topic_boundary IS ? ORDER BY created_at DESC, rowid DESC LIMIT 1',
          variables: [Variable(ownerId), Variable<String>(topicBoundary)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final record = _decode(row);
    // 历史重放、编辑和删除使摘要失效，改用原文；不倒灌未来内容。
    if (!_valid(record, history)) return null;
    validateContextSummary(record.summary);
    return record;
  }

  @override
  Future<ContextSummary> saveAuto(
    ContextSnapshot snapshot,
    String summary,
  ) async {
    validateContextSummary(summary);
    return database.transaction(() async {
      final owner = await _owner(snapshot.ownerId);
      final all = await loadMessages(snapshot.ownerId);
      final ids = snapshot.sourceIds.toSet();
      final sources = all.where((m) => ids.contains(m.id)).toList();
      if (owner.contextStartMessageId != snapshot.previousBoundaryId ||
          sources.length != ids.length ||
          contextSourceDigest(sources) != snapshot.sourceDigest) {
        throw const ContextCompactionException('压缩期间聊天已变化，本轮未发送，请重试。');
      }
      final created = DateTime.now();
      final id = 'auto_${snapshot.id}';
      await database.customStatement(
        _insert,
        _row(id, snapshot, ContextSummaryKind.auto, summary, created),
      );
      // 只保留每个话题最新的自动摘要，避免无限增长。
      await database.customStatement(
        "DELETE FROM context_summaries WHERE owner_id = ? AND kind = 'auto' "
        'AND topic_boundary IS ? AND id != ?',
        [snapshot.ownerId, snapshot.previousBoundaryId, id],
      );
      AppLogger.info(
        'AutomaticContext',
        '自动压缩已保存',
        metadata: {'conversationId': snapshot.ownerId, 'sourceCount': ids.length},
      );
      return ContextSummary(
        id: id,
        ownerId: snapshot.ownerId,
        kind: ContextSummaryKind.auto,
        boundaryId: snapshot.boundaryId,
        topicBoundary: snapshot.previousBoundaryId,
        summary: summary.trim(),
        sourceIds: snapshot.sourceIds,
        sourceDigest: snapshot.sourceDigest,
        createdAt: created,
      );
    });
  }

  @override
  Future<Set<String>> compactedBoundaries(String ownerId) async {
    // 手动：压缩时话题的最后一条；自动：被概括部分的最后一条。
    final rows = await database
        .customSelect(
          'SELECT boundary_id FROM context_summaries WHERE owner_id = ?',
          variables: [Variable(ownerId)],
        )
        .get();
    return rows.map((row) => row.read<String>('boundary_id')).toSet();
  }

  @override
  Future<void> clear(String ownerId) => database.customStatement(
    'DELETE FROM context_summaries WHERE owner_id = ?',
    [ownerId],
  );
}
