import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Writes one kind of [ReversibleChange] state back (batch 2 plan §3.4).
abstract interface class ChangeApplier {
  /// Puts [state] (a change's `before` or `after`) into effect.
  Future<void> apply(Map<String, Object?> state);
}

/// A [ChangeApplier] that can tell whether a state is still in effect, so an
/// undo never overwrites a later edit made elsewhere.
abstract class CheckedChangeApplier implements ChangeApplier {
  Future<bool> isCurrent(Map<String, Object?> state);

  /// Writes [state] only if [expected] is still in effect; false when it is
  /// not. Override to check and write under one lock of the store.
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) async {
    if (!await isCurrent(expected)) return false;
    await apply(state);
    return true;
  }
}

/// Change journal kept in a local JSON file: not in the database, not synced
/// (batch 2 decision 2). Keeps the most recent [capacity] entries.
class FileChangeJournal implements ChangeJournal {
  FileChangeJournal({
    required this.file,
    required this.appliers,
    this.capacity = 50,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The journal under the application support directory.
  static Future<File> defaultFile() async => File(p.join(
        (await getApplicationSupportDirectory()).path,
        'agent_change_journal.json',
      ));

  final Future<File> Function() file;

  /// Appliers by [ReversibleChange.kind].
  final Map<String, ChangeApplier> appliers;
  final int capacity;
  final DateTime Function() _clock;
  int _sequence = 0;

  /// Records [change] and then applies its `after` state; the record exists
  /// before anything is written, so a failed write can still be undone.
  Future<JournalEntry> commit(String toolName, ReversibleChange change) async {
    final applier = _applierOf(change.kind);
    final entry = await append(toolName, change);
    await applier.apply(change.after);
    return entry;
  }

  @override
  Future<JournalEntry> append(String toolName, ReversibleChange change) =>
      _locked(() => _append(toolName, change));

  Future<JournalEntry> _append(String toolName, ReversibleChange change) async {
    final entries = await _read();
    final now = _clock();
    final entry = JournalEntry(
      id: 'chg_${now.microsecondsSinceEpoch}_${_sequence++}',
      toolName: toolName,
      change: change,
      createdAt: now,
    );
    entries.add(entry);
    await _write(entries);
    return entry;
  }

  /// Records [change], runs [write] and keeps the record only if [write]
  /// returns true; null when it refused. All of it holds the journal lock,
  /// so no undo can pick up the record while the write is still undecided.
  Future<JournalEntry?> commitIf(
    String toolName,
    ReversibleChange change,
    Future<bool> Function() write,
  ) =>
      _locked(() async {
        final entry = await _append(toolName, change);
        bool written;
        try {
          written = await write();
        } catch (_) {
          await _drop(entry.id);
          rethrow;
        }
        if (!written) await _drop(entry.id);
        return written ? entry : null;
      });

  Future<void> _drop(String entryId) async {
    final entries = await _read();
    entries.removeWhere((e) => e.id == entryId);
    await _write(entries);
  }

  @override
  Future<List<JournalEntry>> recent({int limit = 50}) async {
    final entries = await _read();
    return entries.reversed.take(limit).toList();
  }

  /// Writes the entry's `before` state back, marks it undone and logs the
  /// reverse change, which is returned.
  @override
  Future<JournalEntry> undo(String entryId) => _locked(() => _undo(entryId));

  Future<JournalEntry> _undo(String entryId) async {
    final entries = await _read();
    final index = entries.indexWhere((e) => e.id == entryId);
    if (index < 0) throw StateError('撤销记录不存在：$entryId');
    final entry = entries[index];
    if (entry.undoneAt != null) throw StateError('已经撤销过：$entryId');
    final applier = _applierOf(entry.change.kind);
    if (applier is CheckedChangeApplier) {
      if (!await applier.applyIfCurrent(
        entry.change.after,
        entry.change.before,
      )) {
        throw StateError('这项修改之后又被改过，为免覆盖新的内容，不能撤销');
      }
    } else {
      await applier.apply(entry.change.before);
    }
    final now = _clock();
    entries[index] = JournalEntry(
      id: entry.id,
      toolName: entry.toolName,
      change: entry.change,
      createdAt: entry.createdAt,
      undoneAt: now,
    );
    final reverse = JournalEntry(
      id: 'chg_${now.microsecondsSinceEpoch}_${_sequence++}',
      toolName: 'undo',
      change: ReversibleChange(
        kind: entry.change.kind,
        description: '撤销：${entry.change.description}',
        before: entry.change.after,
        after: entry.change.before,
      ),
      createdAt: now,
    );
    entries.add(reverse);
    await _write(entries);
    return reverse;
  }

  /// Read–modify–write runs one at a time per journal file, across every
  /// instance in this isolate, so concurrent changes never overwrite each
  /// other's records.
  static final Map<String, Future<void>> _locks = {};

  Future<T> _locked<T>(Future<T> Function() body) async {
    final key = (await file()).absolute.path;
    final previous = _locks[key] ?? Future<void>.value();
    final result = previous.then((_) => body());
    final done = result.then<void>((_) {}, onError: (_) {});
    _locks[key] = done;
    done.whenComplete(() {
      if (identical(_locks[key], done)) _locks.remove(key);
    });
    return result;
  }

  ChangeApplier _applierOf(String kind) =>
      appliers[kind] ?? (throw StateError('没有可写回的修改类型：$kind'));

  Future<List<JournalEntry>> _read() async {
    final journalFile = await file();
    if (!await journalFile.exists()) return [];
    final decoded = jsonDecode(await journalFile.readAsString());
    return [
      for (final item in (decoded as Map)['entries'] as List)
        _entryFromJson(item as Map<String, Object?>),
    ];
  }

  Future<void> _write(List<JournalEntry> entries) async {
    final kept = entries.length > capacity
        ? entries.sublist(entries.length - capacity)
        : entries;
    final journalFile = await file();
    await journalFile.parent.create(recursive: true);
    final tmp = File(
      '${journalFile.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tmp.writeAsString(jsonEncode({
      'schema': 1,
      'entries': [for (final e in kept) _entryToJson(e)],
    }));
    await tmp.rename(journalFile.path);
  }

  static Map<String, Object?> _entryToJson(JournalEntry e) => {
        'id': e.id,
        'toolName': e.toolName,
        'kind': e.change.kind,
        'description': e.change.description,
        'before': e.change.before,
        'after': e.change.after,
        'createdAt': e.createdAt.toIso8601String(),
        if (e.undoneAt != null) 'undoneAt': e.undoneAt!.toIso8601String(),
      };

  static JournalEntry _entryFromJson(Map<String, Object?> json) => JournalEntry(
        id: json['id']! as String,
        toolName: json['toolName']! as String,
        change: ReversibleChange(
          kind: json['kind']! as String,
          description: json['description']! as String,
          before: Map<String, Object?>.from(json['before']! as Map),
          after: Map<String, Object?>.from(json['after']! as Map),
        ),
        createdAt: DateTime.parse(json['createdAt']! as String),
        undoneAt: json['undoneAt'] == null
            ? null
            : DateTime.parse(json['undoneAt']! as String),
      );
}
