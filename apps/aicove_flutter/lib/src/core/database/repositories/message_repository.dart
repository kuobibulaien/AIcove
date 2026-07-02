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

  Future<List<Message>> getByConversationStable(
    String conversationId, {
    int limit = 50,
    int? beforeTime,
    String? beforeId,
  }) async {
    return _queryStableConversationMessages(
      conversationId: conversationId,
      limit: limit,
      beforeTime: beforeTime,
      beforeId: beforeId,
    );
  }

  Stream<List<Message>> watchByConversationStable(
    String conversationId, {
    int limit = 50,
  }) {
    return _watchStableConversationMessages(
      conversationId: conversationId,
      limit: limit,
    );
  }

  /// 在单个会话内搜索消息（按关键词 + 可选时间范围）
  ///
  /// - keyword: 文本关键字（会用 LIKE 做包含匹配）
  /// - startTime/endTime: 毫秒时间戳范围，[startTime, endTime)（endTime 为开区间）
  /// - 默认返回最新的在前（createdAt desc）
  Future<List<Message>> searchByConversation(
    String conversationId, {
    String? keyword,
    int? startTime,
    int? endTime,
    int limit = 200,
  }) async {
    final k = keyword?.trim();

    var query = _db.select(_db.messages)
      ..where((t) =>
          t.conversationId.equals(conversationId) &
          t.deletedAt.isNull() &
          t.replacedBy.isNull());

    if (k != null && k.isNotEmpty) {
      // SQLite LIKE 默认对英文大小写不敏感；中文无大小写概念。
      query = query..where((t) => t.content.like('%$k%'));
    }

    if (startTime != null) {
      query = query..where((t) => t.createdAt.isBiggerOrEqualValue(startTime));
    }
    if (endTime != null) {
      query = query..where((t) => t.createdAt.isSmallerThanValue(endTime));
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

  /// 创建或更新消息（upsert）
  Future<void> upsert(MessagesCompanion data) async {
    await _db.into(_db.messages).insertOnConflictUpdate(data);
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

  Future<void> softDeleteMany(
    List<String> ids,
    int deletedAt,
    int purgeAt,
  ) async {
    if (ids.isEmpty) return;
    await (_db.update(_db.messages)..where((t) => t.id.isIn(ids))).write(
      MessagesCompanion(
        deletedAt: Value(deletedAt),
        purgeAt: Value(purgeAt),
      ),
    );
  }

  /// 重生成覆盖（旧消息标记 replacedBy）
  Future<void> markReplaced(
      String oldId, String newId, int deletedAt, int purgeAt) async {
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

  Future<Message?> getLastMessageStable(String conversationId) {
    return _queryStableConversationMessages(
      conversationId: conversationId,
      limit: 1,
    ).then((messages) => messages.isEmpty ? null : messages.first);
  }

  Future<Message?> getLastMessageByRole(
    String conversationId, {
    required String role,
  }) {
    return _queryStableConversationMessages(
      conversationId: conversationId,
      role: role,
      limit: 1,
    ).then((messages) => messages.isEmpty ? null : messages.first);
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
          ..where((t) =>
              t.purgeAt.isNotNull() & t.purgeAt.isSmallerOrEqualValue(now)))
        .go();
  }

  /// 删除会话的所有消息
  Future<int> deleteByConversation(String conversationId) async {
    return (_db.delete(_db.messages)
          ..where((t) => t.conversationId.equals(conversationId)))
        .go();
  }

  /// 软删除会话的所有消息
  Future<void> softDeleteByConversation(
      String conversationId, int deletedAt, int purgeAt) async {
    await (_db.update(_db.messages)
          ..where((t) =>
              t.conversationId.equals(conversationId) & t.deletedAt.isNull()))
        .write(MessagesCompanion(
      deletedAt: Value(deletedAt),
      purgeAt: Value(purgeAt),
    ));
  }

  /// 获取会话的全量有效消息（按时间升序）
  Future<List<Message>> getAllByConversationOrdered(
      String conversationId) async {
    return (_db.select(_db.messages)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.deletedAt.isNull() &
              t.replacedBy.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
  }

  Future<List<Message>> getAllByConversationOrderedStable(
      String conversationId) async {
    return _queryStableConversationMessages(
      conversationId: conversationId,
      limit: null,
      descending: false,
    );
  }

  /// 获取记忆入库候选消息（仅未总结、未删除、未被替换）
  Future<List<Message>> getIngestCandidates({
    required String conversationId,
    Iterable<String>? candidateMessageIds,
    int? beforeTimestampExclusive,
  }) async {
    final normalizedIds = candidateMessageIds
        ?.map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (candidateMessageIds != null &&
        (normalizedIds == null || normalizedIds.isEmpty)) {
      return const [];
    }

    final query = _db.select(_db.messages)
      ..where((t) =>
          t.conversationId.equals(conversationId) &
          t.deletedAt.isNull() &
          t.replacedBy.isNull() &
          t.summarized.equals(false));

    if (normalizedIds != null) {
      query.where((t) => t.id.isIn(normalizedIds));
    }
    if (beforeTimestampExclusive != null) {
      query.where(
          (t) => t.createdAt.isSmallerThanValue(beforeTimestampExclusive));
    }

    query.orderBy([
      (t) => OrderingTerm.asc(t.createdAt),
      (t) => OrderingTerm.asc(t.id),
    ]);

    return query.get();
  }

  Future<int> countByConversation(String conversationId) async {
    final countExpr = _db.messages.id.count();
    final query = _db.selectOnly(_db.messages)
      ..addColumns([countExpr])
      ..where(_db.messages.conversationId.equals(conversationId) &
          _db.messages.deletedAt.isNull() &
          _db.messages.replacedBy.isNull());
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }

  /// 获取会话中截止某时刻前未总结的消息
  Future<List<Message>> getUnsummarizedBefore(
      String conversationId, int beforeTimestamp) async {
    return (_db.select(_db.messages)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.deletedAt.isNull() &
              t.replacedBy.isNull() &
              t.summarized.equals(false) &
              t.createdAt.isSmallerThanValue(beforeTimestamp))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
  }

  /// 批量标记消息为已总结
  Future<void> markMessagesSummarized(
      List<String> messageIds, int summarizedAt) async {
    if (messageIds.isEmpty) return;
    await (_db.update(_db.messages)..where((t) => t.id.isIn(messageIds))).write(
      MessagesCompanion(
        summarized: const Value(true),
        summarizedAt: Value(summarizedAt),
      ),
    );
  }

  Future<SummarizationRecord?> getSummarizationRecord({
    required String conversationId,
    required String dateKey,
    required String roundKey,
  }) {
    return (_db.select(_db.summarizationRecords)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.dateKey.equals(dateKey) &
              t.roundKey.equals(roundKey))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> upsertSummarizationRecord({
    required String conversationId,
    required String dateKey,
    required String roundKey,
    required int roundIndex,
    required int firstMsgTime,
    required int lastMsgTime,
    required int messageCount,
    bool summarized = false,
    int? summarizedAt,
    String? errorMessage,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.into(_db.summarizationRecords).insertOnConflictUpdate(
          SummarizationRecordsCompanion.insert(
            id: '${conversationId}_$roundKey',
            conversationId: conversationId,
            dateKey: dateKey,
            roundKey: roundKey,
            roundIndex: Value(roundIndex),
            firstMsgTime: firstMsgTime,
            lastMsgTime: lastMsgTime,
            messageCount: messageCount,
            summarized: Value(summarized),
            summarizedAt: Value(summarizedAt),
            errorMessage: Value(errorMessage),
            createdAt: now,
          ),
        );
  }

  Future<void> markRoundSuccess({
    required String conversationId,
    required String dateKey,
    required String roundKey,
    required int summarizedAt,
  }) async {
    await (_db.update(_db.summarizationRecords)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.dateKey.equals(dateKey) &
              t.roundKey.equals(roundKey)))
        .write(
      SummarizationRecordsCompanion(
        summarized: const Value(true),
        summarizedAt: Value(summarizedAt),
        errorMessage: const Value(null),
      ),
    );
  }

  Future<void> markRoundSuccessAndMessages({
    required String conversationId,
    required String dateKey,
    required String roundKey,
    required int summarizedAt,
    required List<String> messageIds,
  }) async {
    await _db.transaction(() async {
      await (_db.update(_db.summarizationRecords)
            ..where((t) =>
                t.conversationId.equals(conversationId) &
                t.dateKey.equals(dateKey) &
                t.roundKey.equals(roundKey)))
          .write(
        SummarizationRecordsCompanion(
          summarized: const Value(true),
          summarizedAt: Value(summarizedAt),
          errorMessage: const Value(null),
        ),
      );

      if (messageIds.isNotEmpty) {
        await (_db.update(_db.messages)..where((t) => t.id.isIn(messageIds)))
            .write(
          MessagesCompanion(
            summarized: const Value(true),
            summarizedAt: Value(summarizedAt),
          ),
        );
      }
    });
  }

  Future<void> markRoundFailure({
    required String conversationId,
    required String dateKey,
    required String roundKey,
    required String errorMessage,
  }) async {
    await (_db.update(_db.summarizationRecords)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.dateKey.equals(dateKey) &
              t.roundKey.equals(roundKey)))
        .write(
      SummarizationRecordsCompanion(
        summarized: const Value(false),
        errorMessage: Value(errorMessage),
      ),
    );
  }

  Future<List<Message>> _queryStableConversationMessages({
    required String conversationId,
    required int? limit,
    int? beforeTime,
    String? beforeId,
    String? role,
    bool descending = true,
  }) async {
    final query = _buildStableConversationQuery(
      conversationId: conversationId,
      limit: limit,
      beforeTime: beforeTime,
      beforeId: beforeId,
      role: role,
      descending: descending,
    );
    final rows = await _db.customSelect(
      query.sql,
      variables: query.variables,
      readsFrom: {_db.messages},
    ).get();
    return <Message>[
      for (final row in rows) _db.messages.map(row.data),
    ];
  }

  Stream<List<Message>> _watchStableConversationMessages({
    required String conversationId,
    required int limit,
  }) {
    final query = _buildStableConversationQuery(
      conversationId: conversationId,
      limit: limit,
    );
    return _db
        .customSelect(
          query.sql,
          variables: query.variables,
          readsFrom: {_db.messages},
        )
        .watch()
        .map(
          (rows) => <Message>[
            for (final row in rows) _db.messages.map(row.data),
          ],
        );
  }

  ({String sql, List<Variable> variables}) _buildStableConversationQuery({
    required String conversationId,
    required int? limit,
    int? beforeTime,
    String? beforeId,
    String? role,
    bool descending = true,
  }) {
    final variables = <Variable>[
      Variable<String>(conversationId),
    ];
    final filters = <String>[
      'm.conversation_id = ?',
      'm.deleted_at IS NULL',
      'm.replaced_by IS NULL',
    ];

    final normalizedRole = role?.trim();
    if (normalizedRole != null && normalizedRole.isNotEmpty) {
      filters.add('m.role = ?');
      variables.add(Variable<String>(normalizedRole));
    }

    if (beforeTime != null) {
      final cursorId = beforeId?.trim();
      if (cursorId == null || cursorId.isEmpty) {
        filters.add('m.created_at < ?');
        variables.add(Variable<int>(beforeTime));
      } else {
        filters.add(
          '(m.created_at < ? OR (m.created_at = ? AND '
          'm.rowid < (SELECT rowid FROM messages WHERE id = ? LIMIT 1)))',
        );
        variables.add(Variable<int>(beforeTime));
        variables.add(Variable<int>(beforeTime));
        variables.add(Variable<String>(cursorId));
      }
    }

    final direction = descending ? 'DESC' : 'ASC';
    final sql = StringBuffer()
      ..writeln('SELECT m.*')
      ..writeln('FROM messages m')
      ..writeln('WHERE ${filters.join(' AND ')}')
      ..writeln('ORDER BY m.created_at $direction, m.rowid $direction');
    if (limit != null) {
      sql.writeln('LIMIT ?');
      variables.add(Variable<int>(limit));
    }

    return (
      sql: sql.toString(),
      variables: variables,
    );
  }
}
