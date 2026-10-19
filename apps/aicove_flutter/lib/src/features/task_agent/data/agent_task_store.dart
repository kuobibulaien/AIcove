import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/database.dart' hide MessageBlock;
import '../../../core/models/message_block.dart';
import '../domain/agent_task.dart';

/// Thrown when a request key is reused by another conversation.
class AgentTaskKeyConflict implements Exception {
  const AgentTaskKeyConflict(this.requestKey);
  final String requestKey;
}

/// A receipt recorded with its state change, ready to become a message.
class RecordedReceipt {
  const RecordedReceipt(this.task, this.block);
  final AgentTask task;
  final TaskReceiptBlock block;

  String get messageId => taskReceiptMessageId(block.receiptId);
}

/// Message id of a receipt; fixed, so writing it again replaces it.
String taskReceiptMessageId(String receiptId) => 'task_receipt_$receiptId';

/// Persists errand tasks in the main database (ADR0088 §5). Every change
/// that produces a receipt records the receipt (outbox column) and, when it
/// is to be relayed, the pending delivery in the same transaction; the chat
/// message is written right after and again on startup until it exists.
class AgentTaskStore {
  AgentTaskStore(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;

  int get _nowMs => _now().millisecondsSinceEpoch;

  // ---------------------------------------------------------------------
  // Tasks
  // ---------------------------------------------------------------------

  /// Creates a queued task; with a known [requestKey] returns the existing
  /// one instead (`created` false). The key must belong to the same chat.
  Future<(AgentTask, bool)> create({
    required String id,
    required String? requestKey,
    required String conversationId,
    required String instruction,
    AgentTaskSource source = AgentTaskSource.chat,
    TaskReceiptNotify notify = TaskReceiptNotify.always,
  }) => _db.transaction(() async {
    if (requestKey != null) {
      final existing = await _one(
        'SELECT * FROM agent_tasks WHERE request_key=?',
        [requestKey],
      );
      if (existing != null) {
        if (existing.conversationId != conversationId) {
          throw AgentTaskKeyConflict(requestKey);
        }
        return (existing, false);
      }
    }
    final now = _nowMs;
    await _db.customStatement(
      'INSERT INTO agent_tasks (id, request_key, conversation_id, source, '
      'instruction, status, notify, created_at, updated_at) '
      'VALUES (?,?,?,?,?,?,?,?,?)',
      [
        id,
        requestKey,
        conversationId,
        source.name,
        instruction,
        AgentTaskStatus.queued.dbName,
        _notifyName(notify),
        now,
        now,
      ],
    );
    return ((await get(id))!, true);
  });

  Future<AgentTask?> get(String id) =>
      _one('SELECT * FROM agent_tasks WHERE id=?', [id]);

  Future<List<AgentTask>> byStatus(AgentTaskStatus status) => _many(
    'SELECT * FROM agent_tasks WHERE status=? ORDER BY created_at',
    [status.dbName],
  );

  /// The newest receipt of a task in the chat history, synced ones included;
  /// what a device without the task row knows about it (ADR0088 §6).
  Future<TaskReceiptBlock?> latestReceipt(String taskId) async {
    final rows = await _db
        .customSelect(
          'SELECT b.data FROM message_blocks b '
          'JOIN messages m ON m.id = b.message_id '
          "WHERE m.id LIKE 'task_receipt_%' AND m.deleted_at IS NULL "
          'AND b.data LIKE ? '
          'ORDER BY m.created_at DESC, m.rowid DESC',
          variables: [Variable('%"task_id":${jsonEncode(taskId)}%')],
        )
        .get();
    for (final row in rows) {
      final block = MessageBlock.fromJson(
        jsonDecode(row.read<String>('data')) as Map<String, dynamic>,
      );
      if (block is TaskReceiptBlock && block.taskId == taskId) return block;
    }
    return null;
  }

  Future<List<AgentTask>> byConversation(String conversationId) => _many(
    'SELECT * FROM agent_tasks WHERE conversation_id=? '
    'ORDER BY created_at DESC',
    [conversationId],
  );

  /// Newest first, for the task list.
  Future<List<AgentTask>> recent({int limit = 100}) => _many(
    'SELECT * FROM agent_tasks ORDER BY created_at DESC LIMIT ?',
    [limit],
  );

  /// Queued and not frozen, oldest first.
  Future<List<AgentTask>> runnable() => _many(
    "SELECT * FROM agent_tasks WHERE status='queued' AND frozen=0 "
    'ORDER BY created_at',
  );

  /// `queued → running`; false when something else moved it first.
  Future<bool> markRunning(String id) => _db.transaction(() async {
    final task = await get(id);
    if (task == null ||
        task.frozen ||
        task.status != AgentTaskStatus.queued) {
      return false;
    }
    await _setStatus(id, AgentTaskStatus.running);
    return true;
  });

  Future<void> markSideEffectUncertain(String id) => _db.customStatement(
    'UPDATE agent_tasks SET side_effect_uncertain=1, updated_at=? WHERE id=?',
    [_nowMs, id],
  );

  /// Moves a task out of one of [from] into a receipt-producing [to] and
  /// records the receipt; null when the task is not in [from].
  Future<RecordedReceipt?> finish(
    String id, {
    required Set<AgentTaskStatus> from,
    required AgentTaskStatus to,
    required String executorDevice,
    String summary = '',
    String? question,
    List<TaskArtifact> artifacts = const [],
  }) => _db.transaction(() async {
    final task = await get(id);
    if (task == null || !from.contains(task.status)) return null;
    final seq = task.receiptSeq + 1;
    final receiptId = '${task.id}_$seq';
    final block = TaskReceiptBlock(
      id: 'task_receipt_block_$receiptId',
      messageId: taskReceiptMessageId(receiptId),
      receiptId: receiptId,
      taskId: task.id,
      receiptStatus: to.receiptStatus!,
      summary: summary,
      question: question,
      artifacts: artifacts,
      executorDevice: executorDevice,
      // Only a stopped run leaves an outside effect in doubt (ADR0088 §4).
      sideEffectUncertain:
          task.sideEffectUncertain &&
          (to == AgentTaskStatus.cancelled ||
              to == AgentTaskStatus.interrupted),
      notify: task.notify,
    );
    await _db.customStatement(
      'UPDATE agent_tasks SET status=?, receipt_seq=?, question_receipt_id=?, '
      'pending_receipt=?, frozen=0, updated_at=? WHERE id=?',
      [
        to.dbName,
        seq,
        to == AgentTaskStatus.needsInput ? receiptId : null,
        jsonEncode(block.toJson()),
        _nowMs,
        id,
      ],
    );
    if (block.relays) {
      await _db.customStatement(
        'INSERT OR IGNORE INTO agent_task_deliveries VALUES (?,?,?,?,?)',
        [receiptId, task.id, task.conversationId, 'pending', _nowMs],
      );
    }
    return RecordedReceipt((await get(id))!, block);
  });

  /// Receipts recorded but not yet confirmed as written messages.
  Future<List<RecordedReceipt>> unwrittenReceipts() async => [
    for (final task in await _many(
      'SELECT * FROM agent_tasks WHERE pending_receipt IS NOT NULL',
    ))
      RecordedReceipt(
        task,
        TaskReceiptBlock.fromJson(
          Map<String, dynamic>.from(jsonDecode(task.pendingReceipt!) as Map),
        ),
      ),
  ];

  /// The receipt message exists now; a newer receipt is left in place.
  Future<void> markReceiptWritten(String taskId, String receiptId) async {
    final task = await get(taskId);
    final pending = task?.pendingReceipt;
    if (pending == null) return;
    final block = TaskReceiptBlock.fromJson(
      Map<String, dynamic>.from(jsonDecode(pending) as Map),
    );
    if (block.receiptId != receiptId) return;
    await _db.customStatement(
      'UPDATE agent_tasks SET pending_receipt=NULL WHERE id=? '
      'AND pending_receipt=?',
      [taskId, pending],
    );
  }

  // ---------------------------------------------------------------------
  // Controls (ADR0088 §6)
  // ---------------------------------------------------------------------

  /// Consumes a reply: only for a `needs_input` task whose open question is
  /// [answersReceiptId]. Marks the control consumed and requeues the task in
  /// one transaction; false when consumed before or not applicable (a reply
  /// to a frozen task stays unconsumed and can be applied after resuming).
  Future<bool> consumeReply({
    required String controlId,
    required String taskId,
    required String? answersReceiptId,
  }) => _db.transaction(() async {
    final task = await get(taskId);
    if (task == null ||
        task.frozen ||
        task.status != AgentTaskStatus.needsInput ||
        task.questionReceiptId != answersReceiptId) {
      return false;
    }
    if (!await _claimControl(controlId, taskId)) return false;
    await _setStatus(taskId, AgentTaskStatus.queued);
    return true;
  });

  /// Consumes a cancel. Returns the task as it was, or null when consumed
  /// before; the caller decides how to stop it.
  Future<AgentTask?> consumeCancel({
    required String controlId,
    required String taskId,
  }) => _db.transaction(() async {
    if (!await _claimControl(controlId, taskId)) return null;
    return get(taskId);
  });

  Future<bool> _claimControl(String controlId, String taskId) async {
    final seen = await _db
        .customSelect(
          'SELECT 1 FROM agent_task_controls WHERE control_id=?',
          variables: [Variable(controlId)],
        )
        .get();
    if (seen.isNotEmpty) return false;
    await _db.customStatement(
      'INSERT INTO agent_task_controls VALUES (?,?,?)',
      [controlId, taskId, _nowMs],
    );
    return true;
  }

  // ---------------------------------------------------------------------
  // Deliveries
  // ---------------------------------------------------------------------

  Future<List<String>> pendingDeliveries() async => [
    for (final row in await _db
        .customSelect(
          "SELECT receipt_id FROM agent_task_deliveries WHERE state='pending' "
          'ORDER BY updated_at',
        )
        .get())
      row.read<String>('receipt_id'),
  ];

  /// Records a pending delivery for a receipt that arrived through sync.
  Future<void> addDelivery({
    required String receiptId,
    required String taskId,
    required String conversationId,
  }) => _db.customStatement(
    'INSERT OR IGNORE INTO agent_task_deliveries VALUES (?,?,?,?,?)',
    [receiptId, taskId, conversationId, 'pending', _nowMs],
  );

  Future<(String, String)?> delivery(String receiptId) async {
    final rows = await _db
        .customSelect(
          'SELECT task_id, conversation_id FROM agent_task_deliveries '
          'WHERE receipt_id=?',
          variables: [Variable(receiptId)],
        )
        .get();
    if (rows.isEmpty) return null;
    return (
      rows.single.read<String>('task_id'),
      rows.single.read<String>('conversation_id'),
    );
  }

  /// `pending → claimed`; false when another path claimed it.
  Future<bool> claimDelivery(String receiptId) async {
    final changed = await _db.customUpdate(
      "UPDATE agent_task_deliveries SET state='claimed', updated_at=? "
      "WHERE receipt_id=? AND state='pending'",
      variables: [Variable(_nowMs), Variable(receiptId)],
    );
    return changed > 0;
  }

  /// [delivered] false puts it back for a later retry.
  Future<void> completeDelivery(String receiptId, {required bool delivered}) =>
      _db.customStatement(
        'UPDATE agent_task_deliveries SET state=?, updated_at=? '
        'WHERE receipt_id=?',
        [delivered ? 'done' : 'pending', _nowMs, receiptId],
      );

  /// Claims left behind by a crash go back to pending.
  Future<void> releaseStaleClaims() => _db.customStatement(
    "UPDATE agent_task_deliveries SET state='pending' WHERE state='claimed'",
  );

  // ---------------------------------------------------------------------
  // Kill switch (ADR0088 §8)
  // ---------------------------------------------------------------------

  Future<(bool, int)> readSwitch() async {
    final rows = await _db
        .customSelect('SELECT enabled, generation FROM agent_task_switch')
        .get();
    if (rows.isEmpty) return (true, 0);
    return (
      rows.single.read<int>('enabled') == 1,
      rows.single.read<int>('generation'),
    );
  }

  /// Turning off freezes queued and waiting tasks; turning on leaves them
  /// frozen until resumed by hand. Returns the new generation.
  Future<int> setSwitch(bool enabled) => _db.transaction(() async {
    final (_, generation) = await readSwitch();
    final next = generation + 1;
    await _db.customStatement(
      'INSERT OR REPLACE INTO agent_task_switch VALUES (1,?,?)',
      [enabled ? 1 : 0, next],
    );
    if (!enabled) {
      await _db.customStatement(
        "UPDATE agent_tasks SET frozen=1, updated_at=? "
        "WHERE status IN ('queued','needs_input')",
        [_nowMs],
      );
    }
    return next;
  });

  /// Lets a frozen task continue from where it stopped.
  Future<void> unfreeze(String id) => _db.customStatement(
    'UPDATE agent_tasks SET frozen=0, updated_at=? WHERE id=?',
    [_nowMs, id],
  );

  // ---------------------------------------------------------------------

  Future<void> _setStatus(String id, AgentTaskStatus status) =>
      _db.customStatement(
        'UPDATE agent_tasks SET status=?, updated_at=? WHERE id=?',
        [status.dbName, _nowMs, id],
      );

  Future<AgentTask?> _one(String sql, [List<Object?> args = const []]) async {
    final rows = await _many(sql, args);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<AgentTask>> _many(
    String sql, [
    List<Object?> args = const [],
  ]) async => [
    for (final row in await _db
        .customSelect(
          sql,
          variables: [for (final arg in args) Variable(arg)],
        )
        .get())
      _taskOf(row),
  ];

  static String _notifyName(TaskReceiptNotify notify) => switch (notify) {
    TaskReceiptNotify.always => 'always',
    TaskReceiptNotify.onFailure => 'on_failure',
    TaskReceiptNotify.never => 'never',
  };

  static AgentTask _taskOf(QueryRow row) => AgentTask(
    id: row.read<String>('id'),
    requestKey: row.readNullable<String>('request_key'),
    conversationId: row.read<String>('conversation_id'),
    source: row.read<String>('source') == 'schedule'
        ? AgentTaskSource.schedule
        : AgentTaskSource.chat,
    instruction: row.read<String>('instruction'),
    status: AgentTaskStatus.parse(row.read<String>('status')),
    frozen: row.read<int>('frozen') == 1,
    notify: switch (row.read<String>('notify')) {
      'never' => TaskReceiptNotify.never,
      'on_failure' => TaskReceiptNotify.onFailure,
      _ => TaskReceiptNotify.always,
    },
    receiptSeq: row.read<int>('receipt_seq'),
    questionReceiptId: row.readNullable<String>('question_receipt_id'),
    pendingReceipt: row.readNullable<String>('pending_receipt'),
    sideEffectUncertain: row.read<int>('side_effect_uncertain') == 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at')),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('updated_at')),
  );
}
