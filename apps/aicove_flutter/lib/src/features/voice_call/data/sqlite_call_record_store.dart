import 'package:drift/drift.dart';

import '../../../core/database/database.dart' as db;
import '../domain/call_record_port.dart';
import '../domain/voice_call_ports.dart';

/// 读取 `call_sessions`／`call_turns` 里的旧通话记录（参数化 SQL，不走 Drift 表定义）。
/// 新通话不再写这两张表，见 [CallRecordStorePort]。
class SqliteCallRecordStore implements CallRecordStorePort {
  SqliteCallRecordStore(this.database);

  final db.AppDatabase database;

  @override
  Future<CallRecord?> load(String callId) async {
    final session = await database
        .customSelect(
          'SELECT * FROM call_sessions WHERE id = ?',
          variables: [Variable(callId)],
        )
        .getSingleOrNull();
    if (session == null) return null;
    final turns = await database
        .customSelect(
          'SELECT role, text, interrupted FROM call_turns '
          'WHERE call_id = ? ORDER BY seq',
          variables: [Variable(callId)],
        )
        .get();
    DateTime at(String column) =>
        DateTime.fromMillisecondsSinceEpoch(session.read<int>(column));
    return CallRecord(
      id: callId,
      conversationId: session.read<String>('conversation_id'),
      startedAt: at('started_at'),
      endedAt: at('ended_at'),
      duration: Duration(milliseconds: session.read<int>('duration_ms')),
      turns: [
        for (final row in turns)
          CallTurn(
            role: row.read<String>('role'),
            text: row.read<String>('text'),
            interrupted: row.read<int>('interrupted') != 0,
          ),
      ],
    );
  }
}
