import 'package:drift/drift.dart';
import '../database.dart';
import '../../media/embedded_media_store.dart';

/// 消息 Repository
class MessageRepository {
  final AppDatabase _db;

  MessageRepository(this._db, {EmbeddedMediaStore? mediaStore})
      : _mediaStore = mediaStore ?? EmbeddedMediaStore.shared;
  final EmbeddedMediaStore _mediaStore;

  Future<MessagesCompanion> _compact(MessagesCompanion data) async {
    final raw = data.rawPayload;
    if (!raw.present || raw.value == null) return data;
    return data.copyWith(rawPayload: Value(await _mediaStore.compactJson(raw.value!)));
  }

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

  /// 仅供前端时间线读取。已有显示快照时，SQLite 只返回该快照，
  /// 避免把同一音频的 raw/补充副本跨 isolate 搬运。原始行不修改。
  /// 无法反序列化快照的调用方必须通过 getById 回退完整 raw。
  Future<List<Message>> getByConversationForDisplay(
    String conversationId, {
    int limit = 50,
    int? beforeTime,
    String? beforeId,
  }) => _queryStableConversationMessages(
    conversationId: conversationId,
    limit: limit,
    beforeTime: beforeTime,
    beforeId: beforeId,
    displayOnly: true,
  );

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

  /// 跨会话按关键词搜索用户与助手消息，最新的在前。
  Future<List<Message>> searchAll(String keyword, {int limit = 100}) {
    final k = keyword.trim();
    if (k.isEmpty) return Future.value(const <Message>[]);
    final query = _db.select(_db.messages)
      ..where((t) =>
          t.deletedAt.isNull() &
          t.replacedBy.isNull() &
          t.role.isIn(const ['user', 'assistant']) &
          t.content.like('%$k%'))
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
    await _db.into(_db.messages).insert(await _compact(data));
  }

  /// 创建或更新消息（upsert）
  Future<void> upsert(MessagesCompanion data) async {
    await _db.into(_db.messages).insertOnConflictUpdate(await _compact(data));
  }

  /// 批量创建消息
  Future<void> insertAll(List<MessagesCompanion> messages) async {
    final compact = <MessagesCompanion>[];
    for (final message in messages) { compact.add(await _compact(message)); }
    await _db.batch((batch) {
      batch.insertAll(_db.messages, compact);
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

  Future<List<Message>> _queryStableConversationMessages({
    required String conversationId,
    required int? limit,
    int? beforeTime,
    String? beforeId,
    String? role,
    bool descending = true,
    bool displayOnly = false,
  }) async {
    final query = _buildStableConversationQuery(
      conversationId: conversationId,
      limit: limit,
      beforeTime: beforeTime,
      beforeId: beforeId,
      role: role,
      descending: descending,
      displayOnly: displayOnly,
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
    bool displayOnly = false,
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
    final columns = displayOnly
        ? _db.messages.$columns.map((column) {
            if (column.$name != 'raw_payload') return 'm.${column.$name}';
            return "CASE WHEN json_valid(m.raw_payload) THEN "
                "CASE WHEN json_type(m.raw_payload, '\$.projectedMessages') = 'array' "
                "AND json_array_length(m.raw_payload, '\$.projectedMessages') > 0 "
                "THEN json_object('__aicoveDisplayRead', 1, 'projectedMessages', "
                "json_extract(m.raw_payload, '\$.projectedMessages')) "
                "ELSE m.raw_payload END ELSE m.raw_payload END AS raw_payload";
          }).join(', ')
        : 'm.*';
    final sql = StringBuffer()
      ..writeln('SELECT $columns')
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
