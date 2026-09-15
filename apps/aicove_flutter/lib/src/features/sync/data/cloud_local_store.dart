import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/database.dart';
import '../../../core/media/embedded_media_store.dart';
import '../../../core/media/media_store.dart';
import '../../../core/sync/cloud_tracking.dart';
import 'cloud_document.dart';

/// Files and preferences retain their existing owners. Their last synchronized
/// value is compared before every remote write, so an offline edit is queued.
class CloudLocalStore {
  CloudLocalStore(this.db, this.preferences, this.documents, this.support);
  final AppDatabase db;
  final SharedPreferences preferences;
  final Directory documents, support;
  final _columns = <String, Set<Object?>>{};

  static bool syncPreference(String key) =>
      key == 'aicove.ui_models.v1' ||
      key == 'aicove.prompt_custom_nodes.v1' ||
      key == 'aicove.auto_triggers.v1' ||
      (key.startsWith('aicove.plugins.') && !key.contains('.backup')) ||
      const {
        'direct.enable',
        'direct.api_base',
        'direct.api_key',
        'direct.model',
      }.contains(key);

  Map<String, Directory> get fileRoots => {
    'presets': Directory(
      p.join(documents.path, 'aicove', 'sillytavern_presets'),
    ),
    'variables': Directory(
      p.join(documents.path, 'aicove', 'sillytavern_preset_variables'),
    ),
    'notebooks': Directory(p.join(support.path, 'contact_memories')),
  };

  Future<List<Map<String, dynamic>>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) async =>
      (await db
              .customSelect(
                sql,
                variables: [for (final arg in args) Variable(arg)],
              )
              .get())
          .map((e) => e.data)
          .toList();
  Future<void> execute(String sql, [List<Object?> args = const []]) =>
      db.customStatement(sql, args);
  Future<Map<String, dynamic>> state() async =>
      (await rows('SELECT * FROM cloud_client_state WHERE id=1')).single;

  Future<CloudLocalDocument?> read(
    String kind,
    String id, {
    bool includeRelated = true,
  }) async {
    if (kind == 'messages' && includeRelated) {
      return db.transaction(() async {
        final message = await read(kind, id, includeRelated: false);
        if (message == null) return null;
        return CloudLocalDocument(kind, id, {
          ...message.payload,
          'message_snapshot_version': 1,
          for (final child in cloudMessageChildren.entries)
            child.key: await rows(
              'SELECT * FROM ${child.key} WHERE ${child.value}=? ORDER BY id',
              [id],
            ),
        });
      });
    }
    if (cloudTables.containsKey(kind)) {
      final result = await rows(
        'SELECT * FROM "$kind" WHERE "${cloudTables[kind]}"=?',
        [id],
      );
      if (result.isEmpty) return null;
      return CloudLocalDocument(kind, id, {
        'client_schema': db.schemaVersion,
        'row': result.single,
      });
    }
    final entries = await external();
    return entries.where((e) => e.kind == kind && e.id == id).firstOrNull;
  }

  Future<List<CloudLocalDocument>> external() async {
    await preferences.reload();
    final result = <CloudLocalDocument>[];
    for (final key in preferences.getKeys().where(syncPreference)) {
      result.add(
        CloudLocalDocument('settings', cloudObjectId('preference:$key'), {
          'storage': 'preference',
          'key': key,
          'json_value': preferences.get(key),
        }),
      );
    }
    for (final entry in fileRoots.entries) {
      if (!await entry.value.exists()) continue;
      await for (final entity in entry.value.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File ||
            !(entity.path.endsWith('.json') ||
                p.basename(entity.path) == 'MEMORY.md')) {
          continue;
        }
        final relative = p
            .split(p.relative(entity.path, from: entry.value.path))
            .join('/');
        final kind = entry.key == 'notebooks'
            ? 'contact_memory'
            : 'plugin_presets';
        result.add(
          CloudLocalDocument(kind, cloudObjectId('${entry.key}:$relative'), {
            'storage': 'file',
            'root': entry.key,
            'path': relative,
            'json_value': await entity.readAsString(),
          }),
        );
      }
    }
    return result;
  }

  Future<void> mark(String kind, String id) => execute(
    '''INSERT INTO cloud_dirty(kind,entity_id,revision)
    VALUES(?,?,1) ON CONFLICT(kind,entity_id) DO UPDATE SET revision=revision+1''',
    [kind, id],
  );

  Future<void> captureExternal() async {
    final documents = await external();
    final current = {for (final doc in documents) '${doc.kind}/${doc.id}': doc};
    final previous = await rows(
      "SELECT * FROM cloud_versions WHERE kind IN ('settings','plugin_presets','contact_memory')",
    );
    final known = {
      for (final row in previous) '${row['kind']}/${row['entity_id']}': row,
    };
    for (final key in {...current.keys, ...known.keys}) {
      final local = current[key];
      final old = known[key];
      if (local?.localJson == old?['local_json']) continue;
      final kind = local?.kind ?? old!['kind'] as String;
      final id = local?.id ?? old!['entity_id'] as String;
      // Existing dirty rows already own the pending change; avoid revising them
      // on every poll while an immutable outbox operation is being retried.
      if ((await rows(
        'SELECT 1 FROM cloud_dirty WHERE kind=? AND entity_id=?',
        [kind, id],
      )).isEmpty) {
        await mark(kind, id);
      }
    }
  }

  Future<void> seed() async {
    for (final table in cloudTables.entries) {
      if (cloudMessageChildren.containsKey(table.key)) continue;
      await execute(
        '''INSERT OR IGNORE INTO cloud_dirty(kind,entity_id,revision)
        SELECT '${table.key}', "${table.value}", 1 FROM "${table.key}"''',
      );
    }
    await captureExternal();
  }

  /// Preserve already frozen operations before calling this one-time upgrade.
  /// Only the source reseeds complete message snapshots; receivers retain edits
  /// and wait for those snapshots instead of publishing incomplete history.
  Future<void> prepareMessageSnapshots({
    void Function(int, int)? onProgress,
  }) async {
    if ((await rows(
      "SELECT 1 FROM cloud_local_migrations WHERE name='message_snapshots_v1'",
    )).isNotEmpty) {
      return;
    }
    final state = await this.state();
    final known = await rows(
      'SELECT kind,entity_id FROM cloud_versions WHERE local_json IS NOT NULL',
    );
    // Bound the transaction so a large account avoids one fsync per baseline
    // without holding every raw payload or locking the database for the run.
    for (var start = 0; start < known.length; start += 100) {
      final end = start + 100 < known.length ? start + 100 : known.length;
      await db.transaction(() async {
        for (final key in known.sublist(start, end)) {
          final kind = key['kind'] as String, id = key['entity_id'] as String;
          final old =
              (await rows(
                    'SELECT local_json FROM cloud_versions WHERE kind=? AND entity_id=?',
                    [kind, id],
                  )).single['local_json']
                  as String;
          if (old.startsWith('sha256:')) continue;
          var fingerprint = 'sha256:${cloudObjectId(old)}';
          if (kind == 'messages' &&
              (await read(kind, id, includeRelated: false))?.localJson ==
                  fingerprint) {
            fingerprint = (await read(kind, id))!.localJson;
          }
          await execute(
            'UPDATE cloud_versions SET local_json=? WHERE kind=? AND entity_id=? AND local_json=?',
            [fingerprint, kind, id, old],
          );
        }
      });
      onProgress?.call(end, known.length);
    }
    await db.transaction(() async {
      for (final child in cloudMessageChildren.entries) {
        final dirty = await rows(
          'SELECT entity_id FROM cloud_dirty WHERE kind=?',
          [child.key],
        );
        for (final item in dirty) {
          final row = await read(child.key, item['entity_id'] as String);
          var parent = (row?.payload['row'] as Map?)?[child.value] as String?;
          if (parent == null) {
            final previous = await rows(
              'SELECT cloud_json FROM cloud_versions WHERE kind=? AND entity_id=?',
              [child.key, item['entity_id']],
            );
            if (previous.isNotEmpty) {
              parent =
                  jsonDecode(
                        previous.single['cloud_json'] as String,
                      )['payload']['row'][child.value]
                      as String?;
            }
          }
          if (parent != null) await mark('messages', parent);
        }
        await execute('DELETE FROM cloud_dirty WHERE kind=?', [child.key]);
      }
      if (state['mode'] == 'source') {
        for (final table in ['messages', 'conversations']) {
          await execute(
            "INSERT INTO cloud_dirty(kind,entity_id,revision) SELECT ?,id,1 FROM $table WHERE true ON CONFLICT(kind,entity_id) DO UPDATE SET revision=revision+1",
            [table],
          );
        }
        for (final doc in await external()) {
          await mark(doc.kind, doc.id);
        }
      }
      await execute(
        "INSERT INTO cloud_local_migrations VALUES('message_snapshots_v1')",
      );
    });
  }

  Future<void> pruneUnchangedReceiverEdits() async {
    if ((await state())['mode'] != 'receive') return;
    final candidates = await rows(
      """SELECT d.kind,d.entity_id,d.revision,v.local_json FROM cloud_dirty d
      JOIN cloud_versions v USING(kind,entity_id)
      LEFT JOIN cloud_outbox o USING(kind,entity_id)
      WHERE v.conflict_id IS NULL AND o.op_id IS NULL""",
    );
    for (final item in candidates) {
      await db.transaction(() async {
        final current = await read(
          item['kind'] as String,
          item['entity_id'] as String,
        );
        if (current?.localJson != item['local_json']) return;
        await execute(
          'DELETE FROM cloud_dirty WHERE kind=? AND entity_id=? AND revision=?',
          [item['kind'], item['entity_id'], item['revision']],
        );
      });
    }
  }

  Future<bool> hasHistory() async =>
      (await rows('SELECT COUNT(*) AS n FROM messages')).single['n'] != 0;

  Future<void> compactEmbeddedMedia({
    required MediaStore mediaStore,
    void Function(int, int)? onProgress,
  }) async {
    final targets = <(String, String, String)>[];
    for (final entry in {
      'messages': 'raw_payload',
      'message_blocks': 'data',
    }.entries) {
      for (final row in await rows(
        "SELECT id FROM ${entry.key} WHERE instr(${entry.value},'data:audio/')>0 OR instr(${entry.value},'data:image/')>0 OR instr(${entry.value},'data:video/')>0",
      )) {
        targets.add((entry.key, entry.value, row['id'] as String));
      }
    }
    if (targets.isEmpty) {
      await _finishMediaCompaction();
      return;
    }
    if ((await rows(
      "SELECT 1 FROM cloud_local_migrations WHERE name='embedded_media_backup_v1'",
    )).isEmpty) {
      final previous = (await state())['backup_path'] as String?;
      if (previous == null ||
          !await File(p.join(previous, 'aicove.db')).exists()) {
        final path = await backup();
        await execute(
          'UPDATE cloud_client_state SET backup_path=? WHERE id=1',
          [path],
        );
      }
      await execute(
        "INSERT INTO cloud_local_migrations VALUES('embedded_media_backup_v1')",
      );
    }
    final media = EmbeddedMediaStore(store: () async => mediaStore);
    var completed = 0;
    for (final target in targets) {
      if ((await state())['enabled'] != 1) return;
      final row = await rows(
        'SELECT ${target.$2} AS value FROM ${target.$1} WHERE id=?',
        [target.$3],
      );
      if (row.isEmpty) continue;
      final raw = row.single['value'] as String;
      final compact = await media.compactJson(raw);
      if (compact != raw) {
        // The original JSON is retained unless the durable file exists and no
        // concurrent edit changed this row while its media was being written.
        await db.transaction(() async {
          final parentId = target.$1 == 'messages'
              ? target.$3
              : (await rows(
                      'SELECT message_id FROM message_blocks WHERE id=?',
                      [target.$3],
                    )).single['message_id']
                    as String;
          final baseline = await rows(
            'SELECT local_json FROM cloud_versions WHERE kind=? AND entity_id=?',
            ['messages', parentId],
          );
          final cleanReceiver =
              (await state())['mode'] == 'receive' &&
              (await rows(
                'SELECT 1 FROM cloud_dirty WHERE kind=? AND entity_id=?',
                ['messages', parentId],
              )).isEmpty &&
              baseline.isNotEmpty &&
              baseline.single['local_json'] ==
                  (await read('messages', parentId))?.localJson;
          await execute(
            'UPDATE ${target.$1} SET ${target.$2}=? WHERE id=? AND ${target.$2}=?',
            [compact, target.$3, raw],
          );
          if (cleanReceiver) {
            // A representation-only migration is not a new edit. Receivers
            // must still accept the source's complete parent/children snapshot.
            await execute(
              'UPDATE cloud_versions SET local_json=? WHERE kind=? AND entity_id=?',
              [
                (await read('messages', parentId))?.localJson,
                'messages',
                parentId,
              ],
            );
            await execute(
              'DELETE FROM cloud_dirty WHERE kind=? AND entity_id=?',
              ['messages', parentId],
            );
          }
        });
      }
      onProgress?.call(++completed, targets.length);
    }
    await _finishMediaCompaction();
  }

  Future<void> _finishMediaCompaction() async {
    final names = (await rows(
      "SELECT name FROM cloud_local_migrations WHERE name IN ('embedded_media_backup_v1','embedded_media_compacted_v1')",
    )).map((row) => row['name']).toSet();
    if (!names.contains('embedded_media_backup_v1') ||
        names.contains('embedded_media_compacted_v1')) {
      return;
    }
    // Reclaim pages once after replacing inline media. Repeated syncs do not
    // compact the database; ordinary writes already persist file references.
    await execute('VACUUM');
    await execute(
      "INSERT INTO cloud_local_migrations VALUES('embedded_media_compacted_v1')",
    );
  }

  Future<String> backup() async {
    final root = Directory(
      p.join(support.path, 'cloud_backups', const Uuid().v4()),
    );
    await root.create(recursive: true);
    // SQLite makes the consistent database copy internally; never pull the
    // complete raw-message table into Dart memory for a large first sync.
    await execute('VACUUM INTO ?', [p.join(root.path, 'aicove.db')]);
    final sink = File(
      p.join(root.path, 'settings-and-presets.jsonl'),
    ).openWrite();
    try {
      for (final doc in await external()) {
        sink.writeln(
          jsonEncode({
            'kind': doc.kind,
            'entity_id': doc.id,
            'payload': doc.payload,
          }),
        );
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return root.path;
  }

  Future<void> apply(
    String kind,
    String id,
    Map<String, dynamic> payload,
    bool deleted,
  ) async {
    if (cloudTables.containsKey(kind)) {
      final key = cloudTables[kind]!;
      final row = Map<String, dynamic>.from(payload['row'] as Map);
      if (row[key] != id ||
          (payload['client_schema'] as int) > db.schemaVersion) {
        throw const CloudSyncFailure('云端数据格式较新，请先更新应用');
      }
      final columns = _columns[kind] ??= (await rows(
        'PRAGMA table_info("$kind")',
      )).map((e) => e['name']).toSet();
      if (!columns.containsAll(row.keys)) {
        throw const CloudSyncFailure('云端包含此版本无法读取的数据字段');
      }
      final snapshot =
          kind == 'messages' && payload.containsKey('message_snapshot_version');
      if (snapshot) {
        if (payload['message_snapshot_version'] != 1) {
          throw const CloudSyncFailure('消息快照版本较新，请更新应用');
        }
        for (final child in cloudMessageChildren.entries) {
          final children = payload[child.key];
          if (children is! List) throw const CloudSyncFailure('消息快照缺少显示结构');
          final ids = <String>{};
          for (final item in children) {
            if (item is! Map ||
                item[child.value] != id ||
                item['id'] is! String ||
                !ids.add(item['id'] as String)) {
              throw const CloudSyncFailure('消息快照的所属关系无效');
            }
            final existing = await rows(
              'SELECT ${child.value} AS owner FROM ${child.key} WHERE id=?',
              [item['id']],
            );
            if (existing.isNotEmpty && existing.single['owner'] != id) {
              throw const CloudSyncFailure('消息快照不能覆盖其他消息的数据');
            }
          }
          if (deleted) {
            await execute('DELETE FROM ${child.key} WHERE ${child.value}=?', [
              id,
            ]);
          }
        }
      }
      if (deleted) {
        await execute('DELETE FROM "$kind" WHERE "$key"=?', [id]);
      } else {
        final names = row.keys.toList();
        final updates = names
            .where((name) => name != key)
            .map((name) => '"$name"=excluded."$name"')
            .join(',');
        await execute(
          'INSERT INTO "$kind" (${names.map((name) => '"$name"').join(',')}) VALUES(${names.map((_) => '?').join(',')}) ON CONFLICT("$key") DO UPDATE SET $updates',
          row.values.toList(),
        );
      }
      db.markTablesUpdated(
        db.allTables.where((table) => table.actualTableName == kind).toSet(),
      );
      if (snapshot && !deleted) {
        for (final child in cloudMessageChildren.entries) {
          final children = (payload[child.key] as List).cast<Map>();
          await execute(
            'DELETE FROM ${child.key} WHERE ${child.value}=? AND id NOT IN (SELECT value FROM json_each(?))',
            [id, jsonEncode(children.map((row) => row['id']).toList())],
          );
          for (final item in children) {
            await apply(child.key, item['id'] as String, {
              'client_schema': payload['client_schema'],
              'row': Map<String, dynamic>.from(item),
            }, false);
          }
        }
      }
      return;
    }
    if (payload['storage'] == 'preference') {
      final key = payload['key'] as String;
      if (!syncPreference(key) || id != cloudObjectId('preference:$key')) {
        throw const CloudSyncFailure('云端设置标识无效');
      }
      final value = payload['json_value'];
      final bool saved;
      if (deleted) {
        saved = await preferences.remove(key);
      } else if (value is String) {
        saved = await preferences.setString(key, value);
      } else if (value is bool) {
        saved = await preferences.setBool(key, value);
      } else if (value is int) {
        saved = await preferences.setInt(key, value);
      } else if (value is double) {
        saved = await preferences.setDouble(key, value);
      } else if (value is List) {
        saved = await preferences.setStringList(key, value.cast<String>());
      } else {
        throw const CloudSyncFailure('云端设置类型无效');
      }
      if (!saved) throw const CloudSyncFailure('设置保存失败，稍后继续同步');
      return;
    }
    final rootName = payload['root'] as String;
    final relative = payload['path'] as String;
    final root = fileRoots[rootName];
    if (root == null ||
        p.isAbsolute(relative) ||
        p.split(relative).contains('..') ||
        relative.contains('\\') ||
        id != cloudObjectId('$rootName:$relative')) {
      throw const CloudSyncFailure('云端文件路径无效');
    }
    final target = File(p.joinAll([root.path, ...relative.split('/')]));
    if (deleted) {
      if (await target.exists()) {
        await target.rename('${target.path}.${const Uuid().v4()}.deleted');
      }
    } else {
      await target.parent.create(recursive: true);
      final temporary = File('${target.path}.${const Uuid().v4()}.tmp');
      await temporary.writeAsString(
        payload['json_value'] as String,
        flush: true,
      );
      await temporary.rename(target.path);
    }
  }
}
