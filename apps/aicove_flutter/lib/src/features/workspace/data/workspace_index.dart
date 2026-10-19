import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

void _configureWorkspaceIndex(dynamic database) {
  database.execute('PRAGMA busy_timeout=5000');
  database.execute('PRAGMA journal_mode=WAL');
  database.execute('PRAGMA synchronous=NORMAL');
}

/// Per-device workspace index `workspaces/.index.sqlite`, separate from
/// `aicove.db` (ADR0087 §2). Every writer, in any isolate, commits through
/// `BEGIN IMMEDIATE` here, which serialises them across connections.
///
/// Tables:
/// - `workspaces`: local registry; not synced with settings.
/// - `files`: one row per path; `revision` is the content SHA-256 and is
///   empty for a tombstone; `last_op` is the op that last changed the path.
/// - `ops`: intent records and history, grouped by run.
/// - `claims`: paths an unfinished op occupies, by case-folded path.
/// - `blobs`: content kept in `.history/blobs` for undo.
/// - `undo_runs`: persisted undo progress.
/// - `sync_dirty`: paths changed since the last sync publish (W5).
class WorkspaceIndex extends GeneratedDatabase {
  WorkspaceIndex(File file)
    : super(
        NativeDatabase.createInBackground(
          file,
          setup: _configureWorkspaceIndex,
        ),
      );

  WorkspaceIndex.forExecutor(super.executor);

  Future<void> _tail = Future.value();

  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final statement in _schema) {
        await customStatement(statement);
      }
    },
  );

  static const _schema = [
    'CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, '
        'description TEXT NOT NULL, created_at INTEGER NOT NULL)',
    'CREATE TABLE files (ws TEXT NOT NULL, path TEXT NOT NULL, '
        'fold TEXT NOT NULL, revision TEXT NOT NULL, size INTEGER NOT NULL, '
        'last_op TEXT NOT NULL, updated_at INTEGER NOT NULL, '
        'PRIMARY KEY (ws, path))',
    'CREATE UNIQUE INDEX files_fold ON files (ws, fold)',
    'CREATE TABLE ops (id TEXT PRIMARY KEY, ws TEXT NOT NULL, '
        'run_id TEXT NOT NULL, seq INTEGER NOT NULL, kind TEXT NOT NULL, '
        'path TEXT NOT NULL, to_path TEXT, before_hash TEXT NOT NULL, '
        'after_hash TEXT NOT NULL, undoes TEXT, phase TEXT NOT NULL, '
        'created_at INTEGER NOT NULL)',
    'CREATE INDEX ops_run ON ops (run_id, ws, seq)',
    'CREATE INDEX ops_phase ON ops (phase)',
    'CREATE INDEX ops_undoes ON ops (undoes)',
    'CREATE TABLE claims (ws TEXT NOT NULL, fold TEXT NOT NULL, '
        'op_id TEXT NOT NULL, PRIMARY KEY (ws, fold))',
    'CREATE TABLE blobs (hash TEXT PRIMARY KEY, size INTEGER NOT NULL, '
        'created_at INTEGER NOT NULL)',
    'CREATE TABLE undo_runs (run_id TEXT NOT NULL, ws TEXT NOT NULL, '
        'undo_run_id TEXT NOT NULL, status TEXT NOT NULL, '
        'skipped TEXT NOT NULL, conflicts TEXT NOT NULL, '
        'created_at INTEGER NOT NULL, PRIMARY KEY (run_id, ws))',
    'CREATE TABLE sync_dirty (ws TEXT NOT NULL, path TEXT NOT NULL, '
        'PRIMARY KEY (ws, path))',
  ];

  /// Runs [body] in one `BEGIN IMMEDIATE` transaction. Calls on this
  /// connection are queued so no statement slips between BEGIN and COMMIT.
  Future<T> immediate<T>(Future<T> Function() body) => _serial(() async {
    await customStatement('BEGIN IMMEDIATE');
    try {
      final result = await body();
      await customStatement('COMMIT');
      return result;
    } catch (_) {
      await customStatement('ROLLBACK');
      rethrow;
    }
  });

  /// A read outside any transaction, queued behind running ones.
  Future<List<QueryRow>> fetch(String sql, [List<Object?> args = const []]) =>
      _serial(() => rows(sql, args));

  /// Inside [immediate] only.
  Future<List<QueryRow>> rows(String sql, [List<Object?> args = const []]) =>
      customSelect(
        sql,
        variables: [for (final arg in args) _variable(arg)],
      ).get();

  /// Inside [immediate] only.
  Future<void> run(String sql, [List<Object?> args = const []]) =>
      customStatement(sql, args);

  Future<T> _serial<T>(Future<T> Function() body) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }

  static Variable<Object> _variable(Object? value) => switch (value) {
    null => const Variable(null),
    final String text => Variable<String>(text),
    final int number => Variable<int>(number),
    final bool flag => Variable<bool>(flag),
    _ => Variable<String>(value.toString()),
  };
}
