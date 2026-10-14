import 'package:drift/drift.dart';

import '../../../core/database/database.dart';

/// One proactive call's lifecycle (plan 12, §13).
enum ProactiveCallState {
  /// Ringing in the app or as a notification, until [ProactiveCall.answerUntil].
  ringing('ringing'),

  /// Picked up; settled at once.
  answered('answered'),

  /// Declined or not picked up; the bubble is written when it is settled.
  missed('missed');

  const ProactiveCallState(this.id);
  final String id;

  static ProactiveCallState fromId(Object? id) =>
      values.firstWhere((s) => s.id == id, orElse: () => missed);
}

class ProactiveCall {
  const ProactiveCall({
    required this.triggerId,
    required this.conversationId,
    required this.openingLine,
    required this.rangAt,
    required this.answerUntil,
    this.state = ProactiveCallState.ringing,
  });

  final String triggerId;
  final String conversationId;
  final String openingLine;
  final DateTime rangAt;

  /// After this a ringing call counts as missed.
  final DateTime answerUntil;
  final ProactiveCallState state;
}

/// Proactive calls in SQLite, shared by the app and the WorkManager and
/// notification isolates (plan 12, §13). Every step is one statement, so the
/// SQLite file lock makes it atomic across isolates:
/// - [reserve] takes the single ringing slot; a second call cannot ring.
///   The call only counts once [confirm]ed (its delivery claimed): until then
///   nothing shows or answers it, it does not count toward the pause, and if
///   it is never confirmed it is dropped at its deadline.
/// - [answer] / [miss] move a call out of `ringing` once; only the winner
///   acts on it, and a call past its deadline can no longer be answered.
/// - A missed call's bubble has an id derived from the trigger, so it is
///   written before [markSettled] and a retry after a crash rewrites the
///   same bubble instead of losing it.
///
/// The missed-call pause is derived from these rows ([callsPaused]) instead
/// of a counter, so no stale state can undo it. Another isolate may hold the
/// write lock, so every statement retries briefly ([_locked]). Local only,
/// not synced; the table is created on open
/// (`AppDatabase._ensureProactiveCallTable`).
class ProactiveCallLedger {
  ProactiveCallLedger(this._db);

  final AppDatabase _db;

  /// Calls in a row the user did not pick up before the role stops calling.
  static const int missedCallPauseThreshold = 2;

  /// Starts ringing [call] unless another call still rings; false when busy
  /// or when this trigger already rang.
  Future<bool> reserve(ProactiveCall call, {DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final affected = await _update(
      'INSERT OR IGNORE INTO proactive_calls '
      '(trigger_id, conversation_id, opening_line, rang_at, answer_until, '
      'state, confirmed) '
      'SELECT ?, ?, ?, ?, ?, ?, 0 WHERE NOT EXISTS ('
      'SELECT 1 FROM proactive_calls WHERE state = ? AND answer_until > ?)',
      [
        Variable.withString(call.triggerId),
        Variable.withString(call.conversationId),
        Variable.withString(call.openingLine),
        Variable.withInt(call.rangAt.millisecondsSinceEpoch),
        Variable.withInt(call.answerUntil.millisecondsSinceEpoch),
        Variable.withString(ProactiveCallState.ringing.id),
        Variable.withString(ProactiveCallState.ringing.id),
        Variable.withInt(at),
      ],
    );
    return affected == 1;
  }

  /// The delivery of a reserved call is claimed: it may be shown and answered.
  Future<void> confirm(String triggerId) => _update(
    'UPDATE proactive_calls SET confirmed = 1 WHERE trigger_id = ? AND state = ?',
    [
      Variable.withString(triggerId),
      Variable.withString(ProactiveCallState.ringing.id),
    ],
  );

  /// Gives the slot back when the trigger could not be delivered after all.
  Future<void> release(String triggerId) => _update(
    'DELETE FROM proactive_calls WHERE trigger_id = ? AND state = ?',
    [
      Variable.withString(triggerId),
      Variable.withString(ProactiveCallState.ringing.id),
    ],
  );

  /// Picks up a ringing call; false when it was already answered or missed,
  /// or its deadline passed.
  Future<bool> answer(String triggerId, {DateTime? now}) =>
      _leaveRinging(triggerId, ProactiveCallState.answered, now: now);

  /// Declines or times out a ringing call; false when already handled.
  Future<bool> miss(String triggerId, {DateTime? now}) =>
      _leaveRinging(triggerId, ProactiveCallState.missed, now: now);

  Future<bool> _leaveRinging(
    String triggerId,
    ProactiveCallState to, {
    DateTime? now,
  }) async {
    final answering = to == ProactiveCallState.answered;
    // The time is taken on each attempt: a lock held past the deadline must
    // not let a late answer through.
    final affected = await _locked(() {
      final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
      return _db.customUpdate(
        'UPDATE proactive_calls SET state = ?, settled_at = ? '
        'WHERE trigger_id = ? AND state = ?'
        '${answering ? ' AND confirmed = 1 AND answer_until > ?' : ''}',
        variables: [
          Variable.withString(to.id),
          // An answered call needs nothing more; a missed one owes a bubble.
          answering ? Variable.withInt(at) : const Variable<int>(null),
          Variable.withString(triggerId),
          Variable.withString(ProactiveCallState.ringing.id),
          if (answering) Variable.withInt(at),
        ],
        updates: const {},
      );
    });
    return affected == 1;
  }

  /// Ringing calls past their deadline become missed; one never confirmed
  /// was never delivered and is dropped.
  Future<void> expire({DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    await _update(
      'DELETE FROM proactive_calls '
      'WHERE state = ? AND confirmed = 0 AND answer_until <= ?',
      [
        Variable.withString(ProactiveCallState.ringing.id),
        Variable.withInt(at),
      ],
    );
    await _update(
      'UPDATE proactive_calls SET state = ? WHERE state = ? AND answer_until <= ?',
      [
        Variable.withString(ProactiveCallState.missed.id),
        Variable.withString(ProactiveCallState.ringing.id),
        Variable.withInt(at),
      ],
    );
  }

  /// Missed calls whose bubble is not written yet.
  Future<List<ProactiveCall>> unsettledMissed() async {
    final rows = await _select(
      'SELECT * FROM proactive_calls WHERE state = ? AND settled_at IS NULL '
      'ORDER BY rang_at',
      [Variable.withString(ProactiveCallState.missed.id)],
    );
    return rows.map(_fromRow).toList();
  }

  /// Records that a missed call's bubble is written. Call it after writing,
  /// so a crash in between only means writing the same bubble again.
  Future<void> markSettled(String triggerId, {DateTime? now}) => _update(
    'UPDATE proactive_calls SET settled_at = ? '
    'WHERE trigger_id = ? AND state = ? AND settled_at IS NULL',
    [
      Variable.withInt((now ?? DateTime.now()).millisecondsSinceEpoch),
      Variable.withString(triggerId),
      Variable.withString(ProactiveCallState.missed.id),
    ],
  );

  Future<ProactiveCall?> find(String triggerId) async {
    final rows = await _select(
      'SELECT * FROM proactive_calls WHERE trigger_id = ?',
      [Variable.withString(triggerId)],
    );
    return rows.isEmpty ? null : _fromRow(rows.single);
  }

  /// The confirmed call still ringing at [now], if any (at most one).
  Future<ProactiveCall?> ringing({DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await _select(
      'SELECT * FROM proactive_calls WHERE state = ? AND confirmed = 1 '
      'AND answer_until > ? ORDER BY rang_at LIMIT 1',
      [
        Variable.withString(ProactiveCallState.ringing.id),
        Variable.withInt(at),
      ],
    );
    return rows.isEmpty ? null : _fromRow(rows.single);
  }

  /// The earliest deadline among ringing calls, to settle it on time.
  Future<DateTime?> nextDeadline() async {
    final rows = await _select(
      'SELECT MIN(answer_until) AS at FROM proactive_calls WHERE state = ?',
      [Variable.withString(ProactiveCallState.ringing.id)],
    );
    final at = rows.single.data['at'] as int?;
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// Whether the role stopped calling: its latest calls since the user last
  /// wrote were missed [missedCallPauseThreshold] times in a row. Writing or
  /// answering clears it, because only later calls count. A call still marked
  /// ringing past its deadline counts as missed: only the app moves it, and
  /// the background task must not wait for that.
  Future<bool> callsPaused(String conversationId, {DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await _select(
      'SELECT state = ? OR (state = ? AND answer_until <= ?) AS missed '
      'FROM proactive_calls WHERE conversation_id = ? AND confirmed = 1 '
      'AND rang_at > COALESCE((SELECT MAX(created_at) FROM messages '
      "WHERE conversation_id = ? AND role = 'user'), 0) "
      'ORDER BY rang_at DESC LIMIT ?',
      [
        Variable.withString(ProactiveCallState.missed.id),
        Variable.withString(ProactiveCallState.ringing.id),
        Variable.withInt(at),
        Variable.withString(conversationId),
        Variable.withString(conversationId),
        Variable.withInt(missedCallPauseThreshold),
      ],
    );
    return rows.length >= missedCallPauseThreshold &&
        rows.every((row) => row.read<int>('missed') == 1);
  }

  /// Drops settled calls older than [age].
  Future<void> prune({
    Duration age = const Duration(days: 30),
    DateTime? now,
  }) async {
    final before = (now ?? DateTime.now()).subtract(age).millisecondsSinceEpoch;
    await _update(
      'DELETE FROM proactive_calls WHERE settled_at IS NOT NULL AND rang_at < ?',
      [Variable.withInt(before)],
    );
  }

  Future<int> _update(String sql, List<Variable> variables) => _locked(
    () => _db.customUpdate(sql, variables: variables, updates: const {}),
  );

  Future<List<QueryRow>> _select(String sql, List<Variable> variables) =>
      _locked(() => _db.customSelect(sql, variables: variables).get());

  /// Retries while another isolate holds the database lock (about 6 s in
  /// all), then gives up with the error.
  static Future<T> _locked<T>(Future<T> Function() body) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await body();
      } catch (e) {
        final text = e.toString();
        final locked = text.contains('(code 5)') || text.contains('(code 6)');
        if (!locked || attempt >= 7) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 50 * (1 << attempt)));
      }
    }
  }

  static ProactiveCall _fromRow(QueryRow row) => ProactiveCall(
    triggerId: row.read<String>('trigger_id'),
    conversationId: row.read<String>('conversation_id'),
    openingLine: row.read<String>('opening_line'),
    rangAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('rang_at')),
    answerUntil: DateTime.fromMillisecondsSinceEpoch(
      row.read<int>('answer_until'),
    ),
    state: ProactiveCallState.fromId(row.read<String>('state')),
  );
}
