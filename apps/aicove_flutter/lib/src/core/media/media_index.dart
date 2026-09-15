import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

final DatabaseSetup _configureMediaIndex = (database) {
  database.execute('PRAGMA busy_timeout=5000');
  database.execute('PRAGMA journal_mode=WAL');
  database.execute('PRAGMA synchronous=NORMAL');
};

/// One transactional index replaces per-asset and per-source JSON sidecars.
/// Original files and legacy sidecars remain available for rollback.
class MediaIndex extends GeneratedDatabase {
  MediaIndex(Directory root)
    : super(
        NativeDatabase.createInBackground(
          File(p.join(root.path, 'index.db')),
          setup: _configureMediaIndex,
        ),
      );

  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement(
        'CREATE TABLE assets (id TEXT PRIMARY KEY, record TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE sources (key TEXT PRIMARY KEY, record TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
    },
  );

  Future<Map<String, dynamic>?> read(String table, String key) async {
    final column = table == 'assets' ? 'id' : 'key';
    final rows = await customSelect(
      'SELECT record FROM $table WHERE $column=?',
      variables: [Variable(key)],
    ).get();
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single.read<String>('record'))
              as Map<String, dynamic>;
  }

  Future<void> put(String table, String key, Map<String, dynamic> record) =>
      customStatement('INSERT OR REPLACE INTO $table VALUES(?,?)', [
        key,
        jsonEncode(record),
      ]);

  Stream<Map<String, dynamic>> records() async* {
    var after = '';
    while (true) {
      final page = await customSelect(
        'SELECT id,record FROM assets WHERE id>? ORDER BY id LIMIT 100',
        variables: [Variable(after)],
      ).get();
      if (page.isEmpty) return;
      for (final row in page) {
        yield jsonDecode(row.read<String>('record')) as Map<String, dynamic>;
      }
      after = page.last.read<String>('id');
    }
  }

  Future<void> importLegacy(Directory root) async {
    if ((await customSelect(
      "SELECT 1 FROM metadata WHERE key='legacy_imported'",
    ).get()).isNotEmpty) {
      return;
    }
    await transaction(() async {
      final assets = Directory(p.join(root.path, 'assets'));
      if (await assets.exists()) {
        await for (final entry in assets.list(followLinks: false)) {
          if (entry is! Directory) continue;
          final file = File(p.join(entry.path, 'record.json'));
          if (!await file.exists()) continue;
          final id = p.basename(entry.path);
          if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) continue;
          await customStatement('INSERT OR IGNORE INTO assets VALUES(?,?)', [
            id,
            await file.readAsString(),
          ]);
        }
      }
      final sources = Directory(p.join(root.path, 'sources'));
      if (await sources.exists()) {
        await for (final file in sources.list(followLinks: false)) {
          if (file is! File || !file.path.endsWith('.json')) continue;
          final key = p.basenameWithoutExtension(file.path);
          if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) continue;
          await customStatement('INSERT OR IGNORE INTO sources VALUES(?,?)', [
            key,
            await file.readAsString(),
          ]);
        }
      }
      await customStatement(
        "INSERT INTO metadata VALUES('legacy_imported','1')",
      );
    });
  }
}
