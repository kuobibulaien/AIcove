import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/database.dart';
import '../../../core/media/embedded_media_store.dart';
import '../../../core/media/media_asset.dart';
import '../../../core/media/media_store.dart';
import '../../../core/sync/cloud_tracking.dart';
import '../../../core/sync/cloud_local_write.dart';
import '../../../core/sync/cloud_setting_policy.dart';
import 'cloud_document.dart';
import 'cloud_media_codec.dart';
import 'device_names.dart';
import '../../memory/utils/lexical_tokenizer_zh.dart';

/// Files and preferences retain their existing owners. Their last synchronized
/// value is compared before every remote write, so an offline edit is queued.
class CloudLocalStore {
  CloudLocalStore(this.db, this.preferences, this.documents, this.support);
  final AppDatabase db;
  final SharedPreferences preferences;
  final Directory documents, support;
  final _columns = <String, Set<Object?>>{};
  // Unchanged size and modification time mean unchanged content, so a scan
  // reads only files written since the previous one.
  final _files = <String, (int, DateTime, String)>{};

  static bool syncPreference(String key) =>
      key == 'aicove.ui_models.v1' ||
      key == 'aicove.prompt_custom_nodes.v1' ||
      key == 'aicove.auto_triggers.v1' ||
      key == deviceNamesKey ||
      key == privacySpacePasswordKey ||
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

  /// Reads the actual local value, including legacy incoming sending messages.
  /// Outgoing collectors must defer [CloudLocalDocument.isSendingMessage],
  /// not turn it into null: null denotes a deletion in both sync engines.
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
      final row = Map<String, dynamic>.of(result.single);
      if (kind == 'memory_items') row['embedding'] = null;
      return CloudLocalDocument(kind, id, {
        'client_schema': kCloudRowSchema,
        'row': row,
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
          'json_value': projectCloudPreference(key, preferences.get(key)),
        }),
      );
    }
    for (final entry in fileRoots.entries) {
      if (!await entry.value.exists()) continue;
      await for (final entity in entry.value.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final relative = p
            .split(p.relative(entity.path, from: entry.value.path))
            .join('/');
        result.add(
          CloudLocalDocument(
            'plugin_presets',
            cloudObjectId('${entry.key}:$relative'),
            {
              'storage': 'file',
              'root': entry.key,
              'path': relative,
              'json_value': await _readCached(entity),
            },
          ),
        );
      }
    }
    return result;
  }

  Future<String> _readCached(File file) async {
    final stat = await file.stat();
    final cached = _files[file.path];
    if (cached != null &&
        cached.$1 == stat.size &&
        cached.$2 == stat.modified) {
      return cached.$3;
    }
    final text = await file.readAsString();
    _files[file.path] = (stat.size, stat.modified, text);
    return text;
  }

  Future<void> mark(String kind, String id) => execute(
    '''INSERT INTO cloud_dirty(kind,entity_id,revision)
    VALUES(?,?,1) ON CONFLICT(kind,entity_id) DO UPDATE SET revision=revision+1''',
    [kind, id],
  );

  /// Queues an edit received over LAN. Its origin normally uploads it first;
  /// this device uploads only once [until] passes without that happening.
  Future<void> markRelay(String kind, String id, int until) => execute(
    '''INSERT INTO cloud_dirty(kind,entity_id,revision,relay_until,relay_revision)
    VALUES(?,?,1,?,1) ON CONFLICT(kind,entity_id) DO UPDATE SET
      relay_until=CASE WHEN revision=relay_revision THEN excluded.relay_until ELSE relay_until END,
      relay_revision=CASE WHEN revision=relay_revision THEN revision+1 ELSE relay_revision END,
      revision=revision+1''',
    [kind, id, until],
  );

  Future<Map<String, dynamic>> settingTimes(
    String kind,
    String id,
    String device, {
    CloudLocalDocument? document,
  }) async {
    if (kind == 'conversations' || kind == 'providers') {
      return {
        for (final row in await rows(
          'SELECT field,at_ms,device_id FROM cloud_setting_times WHERE kind=? AND entity_id=?',
          [kind, id],
        ))
          row['field'] as String: {
            'at_ms': row['at_ms'],
            'device_id': row['device_id'] == '' ? device : row['device_id'],
          },
      };
    }
    final doc = document ?? await read(kind, id);
    if (kind == 'settings' && doc?.payload['storage'] == 'preference') {
      final key = doc!.payload['key'] as String;
      return cloudPreferenceTimes(
        preferences,
        key,
        doc.payload['json_value'],
        device,
      );
    }
    return {};
  }

  Future<void> rememberSettingTimes(
    String kind,
    String id,
    Map<String, dynamic> payload,
  ) async {
    if (payload['setting_times_version'] != 1) return;
    final times = payload['setting_times'] as Map;
    if (kind == 'conversations' || kind == 'providers') {
      await execute(
        'DELETE FROM cloud_setting_times WHERE kind=? AND entity_id=?',
        [kind, id],
      );
      for (final entry in times.entries) {
        final stamp = entry.value as Map;
        await execute(
          'INSERT INTO cloud_setting_times(kind,entity_id,field,at_ms,device_id) VALUES(?,?,?,?,?)',
          [kind, id, entry.key, stamp['at_ms'], stamp['device_id']],
        );
      }
    } else if (kind == 'settings' && payload['storage'] == 'preference') {
      final key = payload['key'] as String;
      await rememberCloudPreferenceTimes(
        preferences,
        key,
        preferences.get(key),
        times,
      );
    }
  }

  Future<bool> hasChangedSettingTimes(
    String kind,
    String id,
    String? cloudJson,
  ) async {
    if (!const {'conversations', 'providers', 'settings'}.contains(kind)) {
      return false;
    }
    final remote = cloudJson == null
        ? const {}
        : (jsonDecode(cloudJson) as Map)['payload'] as Map;
    final times = remote['setting_times'] as Map? ?? {};
    for (final entry in (await settingTimes(kind, id, '')).entries) {
      if ((entry.value as Map)['at_ms'] > 0 &&
          canonicalSettingJson(entry.value) !=
              canonicalSettingJson(times[entry.key])) {
        return true;
      }
    }
    return false;
  }

  Future<void> captureExternal({bool trackSettingTimes = false}) async {
    final documents = await external();
    final current = {for (final doc in documents) '${doc.kind}/${doc.id}': doc};
    final previous = await rows(
      "SELECT * FROM cloud_versions WHERE kind IN ('settings','plugin_presets')",
    );
    final known = {
      for (final row in previous) '${row['kind']}/${row['entity_id']}': row,
    };
    for (final key in {...current.keys, ...known.keys}) {
      final local = current[key];
      final old = known[key];
      final kind = local?.kind ?? old!['kind'] as String;
      final id = local?.id ?? old!['entity_id'] as String;
      if (local?.localJson == old?['local_json'] &&
          !(trackSettingTimes &&
              await hasChangedSettingTimes(
                kind,
                id,
                old?['cloud_json'] as String?,
              ))) {
        continue;
      }
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

  /// Upgrade comparison tokens only when the old token proves that the local
  /// value is unchanged, including rows already marked dirty or frozen.
  Future<void> prepareSchemaFingerprints() async {
    const migration = 'cloud_content_fingerprint_v1';
    if ((await rows('SELECT 1 FROM cloud_local_migrations WHERE name=?', [
      migration,
    ])).isNotEmpty) {
      return;
    }
    final keys = await rows(
      'SELECT kind,entity_id FROM cloud_versions WHERE local_json IS NOT NULL',
    );
    for (var start = 0; start < keys.length; start += 100) {
      await db.transaction(() async {
        for (final key in keys.skip(start).take(100)) {
          final kind = key['kind'] as String, id = key['entity_id'] as String;
          if (!cloudTables.containsKey(kind)) continue;
          final known = (await rows(
            'SELECT local_json,cloud_json FROM cloud_versions WHERE kind=? AND entity_id=?',
            [kind, id],
          )).single;
          final current = await read(kind, id);
          if (current == null || current.localJson == known['local_json']) {
            continue;
          }
          final remote =
              (jsonDecode(known['cloud_json'] as String) as Map)['payload']
                  as Map?;
          if (!_matchesSchemaFingerprint(
            current,
            known['local_json'] as String,
            remote?['client_schema'],
          )) {
            continue;
          }
          await execute(
            'UPDATE cloud_versions SET local_json=? WHERE kind=? AND entity_id=? AND local_json=?',
            [current.localJson, kind, id, known['local_json']],
          );
        }
      });
    }
    await execute('INSERT OR IGNORE INTO cloud_local_migrations VALUES(?)', [
      migration,
    ]);
  }

  bool _matchesSchemaFingerprint(
    CloudLocalDocument current,
    String baseline,
    Object? previousSchema,
  ) =>
      {
        kCloudRowSchema,
        if (previousSchema is int) previousSchema,
        // Older snapshot receipts omitted the wire schema. Each candidate still
        // has to reproduce the saved hash exactly; this cannot rebase a real edit.
        for (var schema = kCloudRowSchema - 1; schema >= 1; schema--) schema,
      }.any((schema) {
        final old = canonicalJson({
          ...current.payload,
          'client_schema': schema,
        });
        return baseline == 'sha256:${cloudObjectId(old)}' || baseline == old;
      });

  /// Preserve already frozen operations before calling this one-time upgrade.
  /// Only the source reseeds complete message snapshots; receivers retain edits
  /// and wait for those snapshots instead of publishing incomplete history.
  Future<void> prepareMessageSnapshots({
    void Function(int, int)? onProgress,
  }) async {
    await normalizeLegacyMessageMedia();
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
          if (kind == 'messages') {
            final current = await read(kind, id, includeRelated: false);
            final previous = jsonDecode(old) as Map;
            if (current != null &&
                (current.localJson == fingerprint ||
                    _matchesSchemaFingerprint(
                      current,
                      old,
                      previous['client_schema'],
                    ))) {
              fingerprint = (await read(kind, id))!.localJson;
            }
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

  Future<void> pruneUnchangedReceiverEdits({
    bool trackSettingTimes = false,
  }) async {
    if ((await state())['mode'] != 'receive') return;
    final candidates = await rows(
      """SELECT d.kind,d.entity_id,d.revision,v.local_json,v.cloud_json FROM cloud_dirty d
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
        if (current?.isSendingMessage == true) return;
        if (current?.localJson != item['local_json']) return;
        if (trackSettingTimes &&
            await hasChangedSettingTimes(
              item['kind'] as String,
              item['entity_id'] as String,
              item['cloud_json'] as String?,
            )) {
          return;
        }
        await execute(
          'DELETE FROM cloud_dirty WHERE kind=? AND entity_id=? AND revision=?',
          [item['kind'], item['entity_id'], item['revision']],
        );
      });
    }
  }

  Future<bool> hasHistory() async =>
      (await rows('SELECT COUNT(*) AS n FROM messages')).single['n'] != 0;

  /// Representation-only upgrade. Frozen operations retain their original bytes;
  /// only proven-clean receive baselines advance without creating an own edit.
  Future<int> normalizeLegacyMessageMedia() async {
    const migration = 'legacy_message_media_v1';
    if ((await rows('SELECT 1 FROM cloud_local_migrations WHERE name=?', [
      migration,
    ])).isNotEmpty) {
      return 0;
    }
    var after = '';
    var repaired = 0;
    while (true) {
      final batch = await rows(
        "SELECT id FROM messages WHERE id>? AND instr(raw_payload,'projectedMessages')>0 ORDER BY id LIMIT 100",
        [after],
      );
      if (batch.isEmpty) break;
      await db.transaction(() async {
        for (final item in batch) {
          final id = item['id'] as String;
          final current = await read('messages', id);
          if (current == null) continue;
          final normalized = CloudMediaCodec.normalizeMessagePayload(
            'messages',
            current.payload,
          );
          final raw = (current.payload['row'] as Map)['raw_payload'];
          final next = (normalized['row'] as Map)['raw_payload'];
          if (raw == next) continue;
          final baseline = await rows(
            "SELECT local_json FROM cloud_versions WHERE kind='messages' AND entity_id=?",
            [id],
          );
          final cleanReceiver =
              (await state())['mode'] == 'receive' &&
              (await rows(
                "SELECT 1 FROM cloud_dirty WHERE kind='messages' AND entity_id=?",
                [id],
              )).isEmpty &&
              baseline.isNotEmpty &&
              baseline.single['local_json'] == current.localJson;
          await execute(
            'UPDATE messages SET raw_payload=? WHERE id=? AND raw_payload=?',
            [next, id, raw],
          );
          if (cleanReceiver) {
            await execute(
              "UPDATE cloud_versions SET local_json=? WHERE kind='messages' AND entity_id=?",
              [(await read('messages', id))!.localJson, id],
            );
            await execute(
              "DELETE FROM cloud_dirty WHERE kind='messages' AND entity_id=?",
              [id],
            );
          }
          repaired++;
        }
      });
      after = batch.last['id'] as String;
    }
    await execute('INSERT OR IGNORE INTO cloud_local_migrations VALUES(?)', [
      migration,
    ]);
    if (repaired > 0) db.markTablesUpdated({db.messages});
    return repaired;
  }

  /// Source-only attachment upgrade. Ordinary writes deliberately keep both
  /// dirty journals: peers need a new causal revision, not a rewritten baseline.
  Future<int> repairLegacyStickerMedia({
    required MediaStore mediaStore,
  }) => cloudLocalWrite(() async {
    const migration = 'sticker_message_media_v1';
    if ((await rows('SELECT 1 FROM cloud_local_migrations WHERE name=?', [
      migration,
    ])).isNotEmpty) {
      return 0;
    }
    var repaired = 0;
    for (final table in ['messages', 'message_blocks']) {
      final column = table == 'messages' ? 'raw_payload' : 'data';
      final filter = table == 'messages'
          ? "(instr(raw_payload,'sticker_convert')>0 OR instr(raw_payload,'sticker')>0 OR instr(raw_payload,'emoji')>0)"
          : "type='emoji' AND EXISTS (SELECT 1 FROM messages m "
                "WHERE m.id=message_blocks.message_id AND m.deleted_at IS NULL "
                "AND m.replaced_by IS NULL AND m.status<>'sending')";
      var after = '';
      while (true) {
        final batch = await rows(
          'SELECT id,$column AS value,created_at FROM $table '
          "WHERE id>? AND $filter AND deleted_at IS NULL "
          '${table == 'messages' ? "AND replaced_by IS NULL AND status<>'sending' " : ''}'
          'ORDER BY id LIMIT 100',
          [after],
        );
        if (batch.isEmpty) break;
        for (final row in batch) {
          final raw = row['value'];
          if (raw is! String) continue;
          Object? decoded;
          try {
            decoded = jsonDecode(raw);
          } on FormatException {
            continue;
          }
          final timestamp = (row['created_at'] as num?)?.toInt() ?? 0;
          final at = timestamp > 0 && timestamp < 100000000000
              ? timestamp * 1000
              : timestamp;
          final next = await CloudMediaCodec.rewriteStickerAttachments(
            decoded,
            (path) async {
              final uri = Uri.tryParse(path);
              if (path.isEmpty ||
                  mediaIdFromReference(path) != null ||
                  path.startsWith('assets/') ||
                  path.startsWith('packages/') ||
                  (uri?.scheme.isNotEmpty == true &&
                      uri?.scheme != 'file' &&
                      !p.windows.isAbsolute(path))) {
                return path;
              }
              final file = File(
                uri?.scheme == 'file' ? uri!.toFilePath() : path,
              );
              try {
                if (!await file.exists()) return path;
                final record = await mediaStore.register(
                  file.path,
                  createdAtMs: at,
                  originalRequired: true,
                  allowNetworkDownload: false,
                );
                return record.asset.reference;
              } on IOException {
                // A missing source (including one removed during the scan)
                // is not a local edit and must not block unrelated history.
                return path;
              }
            },
            emojiData: table == 'message_blocks',
          );
          if (identical(next, decoded)) continue;
          await db.transaction(() async {
            final updated = await db.customUpdate(
              'UPDATE $table SET $column=? WHERE id=? AND $column=? '
              'AND $filter AND deleted_at IS NULL '
              '${table == 'messages' ? "AND replaced_by IS NULL AND status<>'sending'" : ''}',
              variables: [
                Variable(jsonEncode(next)),
                Variable(row['id'] as String),
                Variable(raw),
              ],
            );
            repaired += updated;
          });
        }
        after = batch.last['id'] as String;
      }
    }
    await execute('INSERT OR IGNORE INTO cloud_local_migrations VALUES(?)', [
      migration,
    ]);
    if (repaired > 0) db.markTablesUpdated({db.messages, db.messageBlocks});
    return repaired;
  });

  Future<void> compactEmbeddedMedia({
    required MediaStore mediaStore,
    void Function(int, int)? onProgress,
  }) async {
    await repairLegacyStickerMedia(mediaStore: mediaStore);
    await normalizeLegacyMessageMedia();
    // After the one-time full pass, only messages with pending edits can hold
    // new inline media, so routine syncs never rescan the whole history.
    final incremental = (await rows(
      "SELECT 1 FROM cloud_local_migrations WHERE name='embedded_media_scanned_v1'",
    )).isNotEmpty;
    const dirtyMessages =
        "SELECT entity_id FROM cloud_dirty WHERE kind='messages'";
    final targets = <(String, String, String)>[];
    for (final entry in {
      'messages': ('raw_payload', 'id'),
      'message_blocks': ('data', 'message_id'),
    }.entries) {
      final (column, owner) = entry.value;
      for (final row in await rows(
        "SELECT id FROM ${entry.key} WHERE (instr($column,'data:audio/')>0 OR instr($column,'data:image/')>0 OR instr($column,'data:video/')>0)"
        "${incremental ? ' AND $owner IN ($dirtyMessages)' : ''}",
      )) {
        targets.add((entry.key, column, row['id'] as String));
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
    await execute(
      "INSERT OR IGNORE INTO cloud_local_migrations VALUES('embedded_media_scanned_v1')",
    );
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

  /// Also used by equal-content shortcuts, which must not bypass wire checks.
  Future<void> validateRowPayload(
    String kind,
    String id,
    Map<String, dynamic> payload,
  ) async {
    if (!cloudTables.containsKey(kind)) return;
    final row = payload['row'] as Map;
    if (row[cloudTables[kind]] != id ||
        (payload['client_schema'] as int) > kCloudRowSchema) {
      throw const CloudSyncFailure('云端数据格式较新，请先更新应用');
    }
    final columns = _columns[kind] ??= (await rows(
      'PRAGMA table_info("$kind")',
    )).map((e) => e['name']).toSet();
    if (!columns.containsAll(row.keys)) {
      throw const CloudSyncFailure('云端包含此版本无法读取的数据字段');
    }
  }

  Future<void> apply(
    String kind,
    String id,
    Map<String, dynamic> payload,
    bool deleted,
  ) async {
    // 退役类型：不写本地（ADR0038）。
    if (retiredCloudKinds.contains(kind)) return;
    if (!deleted) {
      payload = CloudMediaCodec.normalizeMessagePayload(kind, payload);
    }
    if (cloudTables.containsKey(kind)) {
      return db.transaction(() async {
        final key = cloudTables[kind]!;
        final rawRow = payload['row'];
        if (!deleted || rawRow is Map) {
          await validateRowPayload(kind, id, payload);
        }
        final row = rawRow is Map
            ? Map<String, dynamic>.from(rawRow)
            : <String, dynamic>{};
        if (!deleted &&
            const {
              'context_summaries',
              'memory_items',
              'memory_progress',
            }.contains(kind)) {
          final owner = row['owner_id'];
          if (owner is! String ||
              (await rows('SELECT 1 FROM conversations WHERE id=?', [
                owner,
              ])).isEmpty) {
            throw const CloudSyncFailure('同步数据缺少所属会话，请稍后重试');
          }
        }
        if (kind == 'memory_items') {
          final old = await rows(
            'SELECT owner_id FROM memory_items WHERE id=?',
            [id],
          );
          if (old.isNotEmpty) {
            await execute(
              'DELETE FROM memory_items_fts WHERE item_id=? AND owner_id=?',
              [id, old.single['owner_id']],
            );
          }
          if (!deleted) {
            await execute(
              'DELETE FROM memory_items_fts WHERE item_id=? AND owner_id=?',
              [id, row['owner_id']],
            );
            await execute(
              'INSERT INTO memory_items_fts(item_id,owner_id,tokens) VALUES(?,?,?)',
              [
                id,
                row['owner_id'],
                LexicalTokenizerZh.tokenizeForFts(
                  '${row['title']}\n${row['content']}',
                ),
              ],
            );
          }
        }
        final snapshot =
            kind == 'messages' &&
            payload.containsKey('message_snapshot_version');
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
        await rememberSettingTimes(kind, id, payload);
      });
    }
    if (payload['storage'] == 'preference') {
      await cloudLocalWrite(() async {
        final key = payload['key'] as String;
        if (!syncPreference(key) || id != cloudObjectId('preference:$key')) {
          throw const CloudSyncFailure('云端设置标识无效');
        }
        final value = keepLocalGeneralSettings(
          key,
          payload['json_value'],
          preferences.get(key),
        );
        final bool saved;
        if (deleted && key == cloudUiModelsKey) {
          final local = preferences.getString(key);
          final fields = local == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(local) as Map);
          saved = await preferences.setString(
            key,
            jsonEncode({
              for (final entry in fields.entries)
                if (localGeneralSettings.contains(entry.key))
                  entry.key: entry.value,
            }),
          );
        } else if (deleted) {
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
        await rememberSettingTimes(kind, id, payload);
      });
      return;
    }
    if (payload['storage'] != 'file' ||
        payload['root'] is! String ||
        payload['path'] is! String) {
      throw const CloudSyncFailure('云端包含无法识别的数据类型，请更新应用');
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
