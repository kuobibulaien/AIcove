import 'package:drift/drift.dart';

import '../../../core/database/database.dart';

/// Finds task messages that arrived through chat sync and still need this
/// device (ADR0088 §6–7): receipts without a local delivery record, and
/// control events not yet consumed here. Only recent messages count, so a
/// device joining later does not relay or replay old history.
class TaskSyncScanner {
  TaskSyncScanner(
    this._db, {
    DateTime Function()? clock,
    this.window = const Duration(days: 2),
  }) : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;
  final Duration window;

  int get _since => _now().subtract(window).millisecondsSinceEpoch;

  /// (message id, conversation id) of receipts with no delivery record.
  Future<List<(String, String)>> receiptsWithoutDelivery() => _pairs(
    r"SELECT m.id, m.conversation_id FROM messages m "
    r"WHERE m.id LIKE 'task\_receipt\_%' ESCAPE '\' "
    'AND m.deleted_at IS NULL AND m.created_at >= ? '
    'AND NOT EXISTS (SELECT 1 FROM agent_task_deliveries d '
    "WHERE 'task_receipt_' || d.receipt_id = m.id) "
    'ORDER BY m.created_at',
  );

  /// (message id, conversation id) of controls not consumed on this device.
  Future<List<(String, String)>> unconsumedControls() => _pairs(
    r"SELECT m.id, m.conversation_id FROM messages m "
    r"WHERE m.id LIKE 'task\_control\_%' ESCAPE '\' "
    'AND m.deleted_at IS NULL AND m.created_at >= ? '
    'AND NOT EXISTS (SELECT 1 FROM agent_task_controls c '
    "WHERE 'task_control_' || c.control_id = m.id) "
    'ORDER BY m.created_at',
  );

  Future<List<(String, String)>> _pairs(String sql) async => [
    for (final row in await _db
        .customSelect(sql, variables: [Variable(_since)])
        .get())
      (row.read<String>('id'), row.read<String>('conversation_id')),
  ];
}
