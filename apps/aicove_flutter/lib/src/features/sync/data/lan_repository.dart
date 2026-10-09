import 'dart:async';
import 'dart:convert';
import '../../../core/sync/cloud_local_write.dart';
import '../../../core/sync/cloud_setting_policy.dart';
import '../domain/lan_contract.dart';
import 'cloud_document.dart';
import 'cloud_local_store.dart';
import 'cloud_media_codec.dart';

/// How long a LAN-received edit waits for its origin to reach the cloud
/// before this device uploads it as the fallback.
const lanRelayDelay = Duration(hours: 24);

class LanRepository {
  LanRepository(this.local, this.codec, this.deviceId, {this.onApplied});
  final CloudLocalStore local;
  final CloudMediaCodec codec;
  final String deviceId;
  final void Function(Set<String>)? onApplied;
  Future<void> _tail = Future.value();
  bool _seeded = false;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (e, stack) {
        result.completeError(e, stack);
      }
    });
    return result.future;
  }

  Future<void> capture({bool scanExternal = true}) =>
      _serial(() => _capture(scanExternal: scanExternal));
  Future<void> _capture({
    String? kind,
    String? id,
    bool scanExternal = true,
  }) async {
    final state = (await local.rows(
      'SELECT * FROM lan_state WHERE id=1',
    )).single;
    if (state['device_id'] != null && state['device_id'] != deviceId) {
      throw const LanSyncFailure('设备身份与本地同步记录不一致，已保留数据并停止同步');
    }
    await local.execute('UPDATE lan_state SET device_id=? WHERE id=1', [
      deviceId,
    ]);
    if (!_seeded) {
      for (final kind in ['conversations', 'providers', 'messages']) {
        await local.execute(
          '''INSERT OR IGNORE INTO lan_dirty(kind,entity_id)
          SELECT ?,id FROM "$kind"''',
          [kind],
        );
      }
      _seeded = true;
    }
    final targeted = kind != null && id != null;
    Map<String, CloudLocalDocument>? external;
    if (targeted) {
      // Preserve edits to this entity before merging, including untracked files.
      // Unrelated dirty entities remain queued for the next ordinary capture.
      await local.execute(
        'INSERT OR IGNORE INTO lan_dirty(kind,entity_id) VALUES(?,?)',
        [kind, id],
      );
    } else if (scanExternal) {
      external = {
        for (final doc in await local.external()) '${doc.kind}/${doc.id}': doc,
      };
      final old = await local.rows(
        "SELECT kind,entity_id FROM lan_entities WHERE kind IN ('settings','plugin_presets')",
      );
      final keys = {
        for (final doc in external.values)
          '${doc.kind}/${doc.id}': (doc.kind, doc.id),
        for (final row in old)
          '${row['kind']}/${row['entity_id']}': (
            row['kind'] as String,
            row['entity_id'] as String,
          ),
      };
      for (final key in keys.values) {
        await local.execute(
          'INSERT OR IGNORE INTO lan_dirty(kind,entity_id) VALUES(?,?)',
          [key.$1, key.$2],
        );
      }
    }
    final dirty = targeted
        ? await local.rows(
            'SELECT * FROM lan_dirty WHERE kind=? AND entity_id=?',
            [kind, id],
          )
        : await local.rows(
            // Filter before LIMIT: a backlog of in-flight rows must not starve
            // terminal messages or tombstones later in the journal.
            '''SELECT d.* FROM lan_dirty d
            WHERE NOT EXISTS (
              SELECT 1 FROM messages m WHERE d.kind='messages'
              AND m.id=d.entity_id AND m.status='sending'
            ) ORDER BY d.kind,d.entity_id LIMIT 500''',
          );
    for (final item in dirty) {
      await cloudLocalWrite(
        () => local.db.transaction(() async {
          final kind = item['kind'] as String, id = item['entity_id'] as String;
          if (!lanKinds.contains(kind)) return;
          final current =
              external != null &&
                  (kind == 'settings' || kind == 'plugin_presets')
              ? external['$kind/$id']
              : await local.read(kind, id);
          // Also covers targeted capture and writes after the journal query.
          // Keep the dirty revision and any previous immutable heads intact.
          if (current?.isSendingMessage == true) return;
          final known = await _entity(kind, id);
          final fingerprint = await _fingerprint(current, kind, id);
          if (fingerprint != known?['local_fingerprint']) {
            final heads = known == null ? <LanRevision>[] : await _heads(known);
            if (current != null || heads.isNotEmpty) {
              final vector = joinLanVectors(heads.map((r) => r.vector));
              final counter =
                  (await local.rows(
                        'SELECT counter FROM lan_state WHERE id=1',
                      )).single['counter']
                      as int;
              final next = counter >= (vector[deviceId] ?? 0)
                  ? counter + 1
                  : vector[deviceId]! + 1;
              await local.execute('UPDATE lan_state SET counter=? WHERE id=1', [
                next,
              ]);
              vector[deviceId] = next;
              final wire = current == null ? null : await codec.encode(current);
              final payload = current == null
                  ? heads.first.payload
                  : {
                      ...wire!.payload,
                      if (lanSettingKinds.contains(kind)) ...{
                        'setting_times_version': 1,
                        'setting_times': await _settingTimes(current, kind, id),
                      },
                    };
              final revision = LanRevision(
                kind: kind,
                id: id,
                vector: vector,
                payload: payload,
                deleted: current == null,
                mediaIds: wire?.mediaIds ?? heads.firstOrNull?.mediaIds ?? [],
              );
              LanRevision.fromJson(revision.toJson());
              await _save(revision);
              await _setEntity(kind, id, [revision], fingerprint);
            }
          }
          await local.execute(
            'DELETE FROM lan_dirty WHERE kind=? AND entity_id=? AND revision=?',
            [kind, id, item['revision']],
          );
        }),
      );
    }
  }

  Future<String> _fingerprint(
    CloudLocalDocument? current,
    String kind,
    String id,
  ) async => current == null
      ? 'deleted'
      : cloudObjectId(
          canonicalJson({
            'payload': current.payload,
            if (lanSettingKinds.contains(kind))
              'setting_times': await _settingTimes(current, kind, id),
          }),
        );

  Future<Map<String, dynamic>> _settingTimes(
    CloudLocalDocument current,
    String kind,
    String id,
  ) async {
    if (kind == 'settings' && current.payload['storage'] == 'preference') {
      final key = current.payload['key'] as String;
      return cloudPreferenceTimes(
        local.preferences,
        key,
        local.preferences.get(key),
        deviceId,
      );
    }
    return local.settingTimes(kind, id, deviceId);
  }

  Future<Map<String, dynamic>?> _entity(String kind, String id) async =>
      (await local.rows(
        'SELECT * FROM lan_entities WHERE kind=? AND entity_id=?',
        [kind, id],
      )).firstOrNull;
  Future<List<LanRevision>> _heads(Map<String, dynamic> row) async {
    final result = <LanRevision>[];
    for (final hash in jsonDecode(row['heads_json'] as String) as List) {
      final stored = (await local.rows(
        'SELECT document_json FROM lan_revisions WHERE hash=?',
        [hash],
      )).single;
      result.add(
        LanRevision.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(stored['document_json'] as String) as Map,
          ),
        ),
      );
    }
    return result;
  }

  Future<void> _save(LanRevision r) => local.execute(
    'INSERT OR IGNORE INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
    [r.hash, r.kind, r.id, canonicalJson(r.toJson())],
  );

  Future<List<LanRevision>> _pendingHeads(String kind, String id) async {
    final rows = await local.rows(
      r"SELECT document_json FROM lan_pending_deletions WHERE json_extract(document_json,'$.kind')=? AND json_extract(document_json,'$.entity_id')=?",
      [kind, id],
    );
    return rows
        .map(
          (row) => LanRevision.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(row['document_json'] as String) as Map,
            ),
          ),
        )
        .toList();
  }

  Future<void> _setEntity(
    String kind,
    String id,
    List<LanRevision> heads,
    String fingerprint,
  ) async {
    final hashes = heads.map((r) => r.hash).toList()..sort();
    await local.execute(
      '''INSERT INTO lan_entities(kind,entity_id,heads_json,local_fingerprint) VALUES(?,?,?,?)
      ON CONFLICT(kind,entity_id) DO UPDATE SET heads_json=excluded.heads_json,local_fingerprint=excluded.local_fingerprint''',
      [kind, id, jsonEncode(hashes), fingerprint],
    );
  }

  Future<Map<String, dynamic>> manifest({
    String after = '',
    int limit = 100,
  }) => _serial(() async {
    if (limit < 1 || limit > 200 || after.length > 400) {
      throw const LanSyncFailure('摘要分页参数无效');
    }
    final rows = await local.rows(
      // Old peers/versions may have persisted sending heads. Retain them for
      // causal comparison, but do not advertise them for onward transmission.
      // Keep the original page cursor even when every head on a page is hidden.
      r"""SELECT e.kind,e.entity_id,
      CASE WHEN e.kind='messages' THEN (
        SELECT json_group_array(h.value) FROM json_each(e.heads_json) h
        JOIN lan_revisions r ON r.hash=h.value
        WHERE json_extract(r.document_json,'$.deleted')=1
          OR json_extract(r.document_json,'$.payload.row.status') IS NOT 'sending'
      ) ELSE e.heads_json END AS heads_json
      FROM lan_entities e WHERE e.kind||'/'||e.entity_id>?
      ORDER BY e.kind,e.entity_id LIMIT ?""",
      [after, limit + 1],
    );
    final selected = rows.take(limit).toList();
    return {
      'items': [
        for (final row in selected)
          if ((jsonDecode(row['heads_json'] as String) as List).isNotEmpty)
            {
              'kind': row['kind'],
              'entity_id': row['entity_id'],
              'hashes': jsonDecode(row['heads_json'] as String),
            },
      ],
      'after': selected.isEmpty
          ? after
          : '${selected.last['kind']}/${selected.last['entity_id']}',
      'has_more': rows.length > limit,
    };
  });
  Future<List<String>> missing(Iterable<String> hashes) => _serial(() async {
    final result = <String>[];
    for (final hash in hashes) {
      if ((await local.rows('SELECT 1 FROM lan_revisions WHERE hash=?', [
        hash,
      ])).isEmpty) {
        result.add(hash);
      }
    }
    return result;
  });
  Future<LanRevision> revision(String hash) => _serial(() async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const LanSyncFailure('修订编号无效');
    }
    final rows = await local.rows(
      'SELECT document_json FROM lan_revisions WHERE hash=?',
      [hash],
    );
    if (rows.isEmpty) throw const LanSyncFailure('同步修订已变化，请重试');
    final revision = LanRevision.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(rows.single['document_json'] as String) as Map,
      ),
    );
    if (!revision.deleted &&
        CloudLocalDocument(
          revision.kind,
          revision.id,
          revision.payload,
        ).isSendingMessage) {
      throw const LanSyncFailure('消息仍在本机发送中，终态后再同步');
    }
    return revision;
  });

  /// Persist incoming revisions before applying. A failed apply can be retried
  /// from the immutable record, and never acknowledges a newer local edit.
  Future<void> receive(LanRevision incoming) => _serial(() async {
    try {
      CloudMediaCodec.validateWirePaths(incoming.payload);
    } on FormatException {
      throw const LanSyncFailure('附件必须使用媒体引用，不能接收另一台设备的本地文件路径');
    }
    await _capture(kind: incoming.kind, id: incoming.id);
    final applied = <String>{};
    await cloudLocalWrite(
      () => local.db.transaction(() async {
        final known = await _entity(incoming.kind, incoming.id);
        final existing = known == null ? <LanRevision>[] : await _heads(known);
        final heads = reduceLanHeads([...existing, incoming]);
        if (heads.length > 64) throw const LanSyncFailure('同时修改版本过多，请先处理冲突');
        final current = await local.read(incoming.kind, incoming.id);
        final fingerprint = await _fingerprint(
          current,
          incoming.kind,
          incoming.id,
        );
        // A write committed between scan and this transaction must become its
        // own causal revision before any incoming replacement is allowed.
        if ((known == null && current != null) ||
            (known != null && fingerprint != known['local_fingerprint'])) {
          throw const LanSyncFailure('本机刚有新修改，下一轮继续同步');
        }
        await _save(incoming);
        for (final head in heads) {
          await _save(head);
        }
        if (heads.length == 1 &&
            (existing.length != 1 ||
                existing.single.hash != heads.single.hash)) {
          final chosen = heads.single;
          if (chosen.kind == 'conversations' &&
              chosen.deleted &&
              (await local.rows(
                'SELECT 1 FROM messages WHERE conversation_id=? LIMIT 1',
                [chosen.id],
              )).isNotEmpty) {
            throw const LanSyncFailure(
              '角色仍有保留的聊天，已保留角色和删除请求；请先处理聊天冲突，或在发送端恢复角色',
            );
          }
          final payload = chosen.deleted
              ? chosen.payload
              : await codec.decode(chosen.kind, chosen.payload);
          await local.execute('UPDATE lan_state SET suspended=1 WHERE id=1');
          await local.execute(
            'UPDATE cloud_client_state SET suspended=1 WHERE id=1',
          );
          try {
            // A missing/tombstoned conversation with retained messages can be
            // restored by an explicit choice, never a stale disconnected edit.
            await local.apply(chosen.kind, chosen.id, payload, chosen.deleted);
            if ((await local.state())['enabled'] == 1) {
              await local.markRelay(
                chosen.kind,
                chosen.id,
                DateTime.now().add(lanRelayDelay).millisecondsSinceEpoch,
              );
            }
            applied.add(chosen.kind);
          } finally {
            await local.execute('UPDATE lan_state SET suspended=0 WHERE id=1');
            await local.execute(
              'UPDATE cloud_client_state SET suspended=0 WHERE id=1',
            );
          }
        }
        final updated = await local.read(incoming.kind, incoming.id);
        await _setEntity(
          incoming.kind,
          incoming.id,
          heads,
          await _fingerprint(updated, incoming.kind, incoming.id),
        );
      }),
    );
    if (applied.isNotEmpty) onApplied?.call(applied);
  });

  Future<List<List<LanRevision>>> conflicts() => _serial(() async {
    final result = <List<LanRevision>>[];
    for (final row in await local.rows(
      'SELECT * FROM lan_entities WHERE json_array_length(heads_json)>1',
    )) {
      result.add(await _heads(row));
    }
    final pending = await local.rows(
      r"SELECT DISTINCT json_extract(document_json,'$.entity_id') AS entity_id FROM lan_pending_deletions",
    );
    for (final item in pending) {
      final id = item['entity_id'] as String;
      if ((await local.rows(
        'SELECT 1 FROM messages WHERE conversation_id=? LIMIT 1',
        [id],
      )).isEmpty) {
        continue;
      }
      final row = await _entity('conversations', id);
      if (row == null) continue;
      final versions = {
        for (final r in [
          ...await _heads(row),
          ...await _pendingHeads('conversations', id),
        ])
          r.hash: r,
      }.values.toList();
      if (versions.length > 1) {
        result.removeWhere(
          (group) =>
              group.first.kind == 'conversations' && group.first.id == id,
        );
        result.add(versions);
      }
    }
    return result;
  });

  Future<void> resolve(
    String kind,
    String id,
    String selectedHash,
    List<String> previewHashes,
  ) => _serial(() async {
    await _capture(kind: kind, id: id);
    await cloudLocalWrite(
      () => local.db.transaction(() async {
        final row = await _entity(kind, id);
        if (row == null) throw const LanSyncFailure('同时修改记录不存在');
        final heads = {
          for (final r in [
            ...await _heads(row),
            ...await _pendingHeads(kind, id),
          ])
            r.hash: r,
        }.values.toList();
        final actual = heads.map((r) => r.hash).toList()..sort();
        final expected = List.of(previewHashes)..sort();
        if (canonicalJson(actual) != canonicalJson(expected)) {
          throw const LanSyncFailure('内容已有新修改，请刷新后选择');
        }
        final chosen = heads.where((r) => r.hash == selectedHash).firstOrNull;
        if (chosen == null) throw const LanSyncFailure('选择的版本不存在');
        if (kind == 'conversations' &&
            chosen.deleted &&
            (await local.rows(
              'SELECT 1 FROM messages WHERE conversation_id=? LIMIT 1',
              [id],
            )).isNotEmpty) {
          throw const LanSyncFailure('这张角色卡仍有聊天，请先选择聊天删除版本，或采用保留角色的版本');
        }
        var payload = Map<String, dynamic>.from(chosen.payload);
        if (lanSettingKinds.contains(kind) && !chosen.deleted) {
          final fields = kind == 'settings'
              ? cloudPreferenceFields(
                  payload['key'] as String,
                  payload['json_value'],
                )
              : (Map<String, dynamic>.from(payload['row'] as Map)
                  ..remove('id')
                  ..remove('created_at')
                  ..remove('updated_at'));
          final times = payload['setting_times'] as Map;
          final fieldsToStamp = {...fields.keys, ...times.keys.cast<String>()};
          var now = DateTime.now().millisecondsSinceEpoch;
          for (final head in heads) {
            for (final stamp in (head.payload['setting_times'] as Map).values) {
              if (stamp['at_ms'] >= now) now = stamp['at_ms'] + 1;
            }
            fieldsToStamp.addAll(
              (head.payload['setting_times'] as Map).keys.cast<String>(),
            );
          }
          payload['setting_times'] = {
            for (final field in fieldsToStamp)
              field: {'at_ms': now, 'device_id': deviceId},
          };
        }
        final vector = joinLanVectors(heads.map((r) => r.vector));
        final counter =
            (await local.rows(
                  'SELECT counter FROM lan_state WHERE id=1',
                )).single['counter']
                as int;
        final next = counter >= (vector[deviceId] ?? 0)
            ? counter + 1
            : vector[deviceId]! + 1;
        vector[deviceId] = next;
        await local.execute('UPDATE lan_state SET counter=? WHERE id=1', [
          next,
        ]);
        final resolution = LanRevision(
          kind: kind,
          id: id,
          vector: vector,
          payload: payload,
          deleted: chosen.deleted,
          mediaIds: chosen.mediaIds,
        );
        final decoded = chosen.deleted
            ? payload
            : await codec.decode(kind, payload);
        await local.execute('UPDATE lan_state SET suspended=1 WHERE id=1');
        await local.execute(
          'UPDATE cloud_client_state SET suspended=1 WHERE id=1',
        );
        try {
          await local.apply(kind, id, decoded, resolution.deleted);
          if ((await local.state())['enabled'] == 1) await local.mark(kind, id);
        } finally {
          await local.execute('UPDATE lan_state SET suspended=0 WHERE id=1');
          await local.execute(
            'UPDATE cloud_client_state SET suspended=0 WHERE id=1',
          );
        }
        await _save(resolution);
        for (final head in heads) {
          await _save(head);
        }
        await local.execute(
          r"DELETE FROM lan_pending_deletions WHERE json_extract(document_json,'$.kind')=? AND json_extract(document_json,'$.entity_id')=?",
          [kind, id],
        );
        await _setEntity(kind, id, [
          resolution,
        ], await _fingerprint(await local.read(kind, id), kind, id));
      }),
    );
    onApplied?.call({kind});
  });
}
