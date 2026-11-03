import 'dart:async';
import 'dart:convert';
import '../../../core/app_logger.dart';
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
  LanRepository(
    this.local,
    this.codec,
    this.deviceId, {
    this.onApplied,
    this.onMessageApplied,
  });
  final CloudLocalStore local;
  final CloudMediaCodec codec;
  final String deviceId;
  final void Function(Set<String>)? onApplied;
  final void Function(String conversationId, String messageId, int createdAt)?
  onMessageApplied;
  Future<void> _tail = Future.value();
  bool _seeded = false;
  // In memory only: the first untargeted scan after launch prunes, later
  // untargeted scans in the same process prune at most once a day.
  DateTime? _lastOrphanPrune;
  static const recentLimit = 128;

  Future<bool> hasPendingChanges() async => (await local.rows('''
    SELECT 1 FROM lan_dirty d WHERE NOT EXISTS (
      SELECT 1 FROM messages m WHERE d.kind='messages'
        AND m.id=d.entity_id AND m.status='sending'
    ) LIMIT 1
  ''')).isNotEmpty;
  final String _recentRun = DateTime.now().microsecondsSinceEpoch.toString();
  int _recentRevision = 0;
  final _recent = <String, (String, String, int)>{};
  static const _revisionCacheLimit = 2048;
  static const _revisionCacheByteLimit = 32 * 1024 * 1024;
  final _revisionCache = <String, (String, LanRevision, int)>{};
  int _revisionCacheBytes = 0;

  /// A bounded acceleration lane backed by the existing dirty journal. Full
  /// manifests remain the recovery path after eviction or process restart.
  Future<Map<String, dynamic>> recentChanges() => _serial(() async {
    final dirty = await local.rows('''SELECT d.* FROM lan_dirty d
      LEFT JOIN messages m ON d.kind='messages' AND m.id=d.entity_id
      WHERE NOT EXISTS (SELECT 1 FROM messages m WHERE d.kind='messages'
        AND m.id=d.entity_id AND m.status='sending')
      ORDER BY (d.revision>0) DESC,
        CASE WHEN d.revision=0 AND d.kind='messages'
          THEN MAX(m.created_at,COALESCE(m.deleted_at,0)) ELSE 0 END DESC,
        d.rowid DESC LIMIT 32''');
    for (final row in dirty) {
      final kind = row['kind'] as String, id = row['entity_id'] as String;
      final clock = Stopwatch()..start();
      try {
        if (kind == 'messages') {
          final message = await local.read(kind, id, includeRelated: false);
          final convId = (message?.payload['row'] as Map?)?['conversation_id'];
          if (convId is String) {
            await _capture(kind: 'conversations', id: convId, seed: false);
          }
        }
        await _capture(kind: kind, id: id, seed: false);
      } catch (e) {
        if (e is! LanSyncFailure &&
            e is! CloudSyncFailure &&
            e is! FormatException) {
          rethrow;
        }
        AppLogger.warning(
          'LanSync',
          'Recent capture failed',
          metadata: {
            'category': 'sync',
            'event': 'lanEntity',
            'entityId': id,
            'kind': kind,
            'phase': 'capture',
            'result': 'failed',
            'errorType': e.runtimeType.toString(),
            'elapsedMs': clock.elapsedMilliseconds,
          },
        );
      }
    }
    final items = <Map<String, dynamic>>[];
    for (final (kind, id, _) in _recent.values) {
      final known = await _entity(kind, id);
      if (known == null) continue;
      final heads = await _readableHeads(known, requireSupported: true);
      if (heads == null) continue;
      final hashes = heads
          .where(
            (r) =>
                r.deleted ||
                !CloudLocalDocument(r.kind, r.id, r.payload).isSendingMessage,
          )
          .map((r) => r.hash)
          .toList();
      if (hashes.isNotEmpty) {
        items.add({'kind': kind, 'entity_id': id, 'hashes': hashes});
      }
    }
    // Parent entities precede new messages even if they were captured long ago.
    final parents = <String>{};
    for (final item in List.of(items)) {
      if (item['kind'] != 'messages') continue;
      final doc = await local.read(
        'messages',
        item['entity_id'] as String,
        includeRelated: false,
      );
      final convId = (doc?.payload['row'] as Map?)?['conversation_id'];
      if (convId is String) parents.add(convId);
    }
    for (final id in parents) {
      final known = await _entity('conversations', id);
      if (known != null &&
          !items.any(
            (i) => i['kind'] == 'conversations' && i['entity_id'] == id,
          )) {
        final heads = await _readableHeads(known, requireSupported: true);
        if (heads == null) continue;
        items.add({
          'kind': 'conversations',
          'entity_id': id,
          'hashes': heads.map((head) => head.hash).toList(),
        });
      }
    }
    items.sort(
      (a, b) => (a['kind'] == 'conversations' ? 0 : 1).compareTo(
        b['kind'] == 'conversations' ? 0 : 1,
      ),
    );
    return {'items': items, 'token': '$_recentRun:$_recentRevision'};
  });

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
    bool seed = true,
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
    await local.repairLegacyStickerMedia(mediaStore: codec.media);
    // This marker records durable enqueueing, not completion: the existing
    // journal resumes unfinished upgrades after interruption or a batch limit.
    await cloudLocalWrite(
      () => local.db.transaction(() async {
        if ((await local.rows(
          "SELECT 1 FROM cloud_local_migrations WHERE name='lan_content_fingerprint_v1_queued'",
        )).isEmpty) {
          await local.execute(
            'INSERT OR IGNORE INTO lan_dirty(kind,entity_id) SELECT kind,entity_id FROM lan_entities',
          );
          await local.execute(
            "INSERT INTO cloud_local_migrations VALUES('lan_content_fingerprint_v1_queued')",
          );
        }
      }),
    );
    if (seed && !_seeded) {
      // Revision zero is a baseline candidate, not a real write. INSERT OR
      // IGNORE preserves preexisting WorkManager dirties; tracking triggers
      // promote any subsequent edit to revision >= 1. No schema change.
      for (final kind in ['conversations', 'providers', 'messages']) {
        await local.execute(
          '''INSERT OR IGNORE INTO lan_dirty(kind,entity_id,revision)
          SELECT ?,c.id,0 FROM "$kind" c
          WHERE NOT EXISTS (SELECT 1 FROM lan_entities e
            WHERE e.kind=? AND e.entity_id=c.id)''',
          [kind, kind],
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
      var applied = false;
      (String, String, int)? messageApplied;
      var applying = false;
      (String, String, int)? captured;
      try {
        await cloudLocalWrite(
          () => local.db.transaction(() async {
            final kind = item['kind'] as String,
                id = item['entity_id'] as String;
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
            final heads = known == null ? <LanRevision>[] : await _heads(known);
            for (final head in heads) {
              await local.validateRowPayload(head.kind, head.id, head.payload);
            }
            final fingerprint = await _fingerprint(current, kind, id);
            final unchanged =
                known != null &&
                (fingerprint == known['local_fingerprint'] ||
                    await _matchesLegacyFingerprint(
                      current,
                      kind,
                      id,
                      heads,
                      known['local_fingerprint'] as String,
                    ));
            if (unchanged) {
              final reduced = reduceLanHeads(heads);
              var updatedFingerprint = fingerprint;
              if (heads.length > 1 && reduced.length == 1) {
                final chosen = reduced.single;
                await _save(chosen);
                final payload = chosen.deleted
                    ? chosen.payload
                    : await codec.decode(kind, chosen.payload);
                final chosenFingerprint = await _fingerprint(
                  chosen.deleted ? null : CloudLocalDocument(kind, id, payload),
                  kind,
                  id,
                );
                if (chosenFingerprint != fingerprint &&
                    chosenFingerprint !=
                        await _fingerprint(
                          current == null ? null : _syncDocument(current),
                          kind,
                          id,
                        )) {
                  await local.execute(
                    'UPDATE lan_state SET suspended=1 WHERE id=1',
                  );
                  await local.execute(
                    'UPDATE cloud_client_state SET suspended=1 WHERE id=1',
                  );
                  try {
                    applying = true;
                    await local.apply(kind, id, payload, chosen.deleted);
                    await local.markRelay(
                      kind,
                      id,
                      DateTime.now().add(lanRelayDelay).millisecondsSinceEpoch,
                    );
                  } finally {
                    await local.execute(
                      'UPDATE lan_state SET suspended=0 WHERE id=1',
                    );
                    await local.execute(
                      'UPDATE cloud_client_state SET suspended=0 WHERE id=1',
                    );
                  }
                  updatedFingerprint = await _fingerprint(
                    await local.read(kind, id),
                    kind,
                    id,
                  );
                  if (kind == 'messages' && onMessageApplied != null) {
                    final row =
                        (payload['row'] ?? current?.payload['row']) as Map?;
                    final convId = row?['conversation_id'] as String?;
                    final createdAt = (row?['created_at'] as num?)?.toInt();
                    if (convId != null && createdAt != null) {
                      messageApplied = (convId, id, createdAt);
                    } else {
                      applied = true;
                    }
                  } else {
                    applied = true;
                  }
                }
              }
              await _setEntity(kind, id, reduced, updatedFingerprint);
            } else {
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
                await local.execute(
                  'UPDATE lan_state SET counter=? WHERE id=1',
                  [next],
                );
                vector[deviceId] = next;
                final wire = current == null
                    ? null
                    : await codec.encode(_syncDocument(current));
                final payload = current == null
                    ? heads.first.payload
                    : {
                        ...wire!.payload,
                        if (lanSettingKinds.contains(kind)) ...{
                          'setting_times_version': 1,
                          'setting_times': await _settingTimes(
                            current,
                            kind,
                            id,
                          ),
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
                final row = current?.payload['row'] as Map?;
                final created = (row?['created_at'] as num?)?.toInt() ?? 0;
                final deleted = (row?['deleted_at'] as num?)?.toInt() ?? 0;
                final priority = known != null || kind != 'messages'
                    ? DateTime.now().millisecondsSinceEpoch
                    : (created > deleted ? created : deleted);
                captured = (kind, id, priority);
              }
            }
            await local.execute(
              'DELETE FROM lan_dirty WHERE kind=? AND entity_id=? AND revision=?',
              [kind, id, item['revision']],
            );
          }),
        );
      } catch (e) {
        if (applying ||
            (e is! LanSyncFailure &&
                e is! CloudSyncFailure &&
                e is! FormatException)) {
          rethrow;
        }
        // The entity transaction has rolled back. A newer queued write must
        // survive even when this snapshot cannot be packaged by this version.
        AppLogger.warning(
          'LanSync',
          '跳过无法打包的同步记录',
          metadata: {
            'kind': item['kind'],
            'entity_id': item['entity_id'],
            'revision': item['revision'],
            'errorType': e.runtimeType.toString(),
          },
        );
        await local.execute(
          'DELETE FROM lan_dirty WHERE kind=? AND entity_id=? AND revision=?',
          [item['kind'], item['entity_id'], item['revision']],
        );
        continue;
      }
      final change = captured;
      if (change != null) {
        _recent['${change.$1}/${change.$2}'] = change;
        _recentRevision++;
        while (_recent.length > recentLimit) {
          final oldest = _recent.keys.reduce(
            (a, b) => _recent[a]!.$3 <= _recent[b]!.$3 ? a : b,
          );
          _recent.remove(oldest);
        }
      }
      if (messageApplied != null) {
        onMessageApplied!(
          messageApplied!.$1,
          messageApplied!.$2,
          messageApplied!.$3,
        );
      } else if (applied) {
        onApplied?.call({item['kind'] as String});
      }
    }
    if (!targeted &&
        (_lastOrphanPrune == null ||
            DateTime.now().difference(_lastOrphanPrune!) >=
                const Duration(days: 1))) {
      await _pruneOrphanRevisions();
      _revisionCache.clear();
      _revisionCacheBytes = 0;
      _lastOrphanPrune = DateTime.now();
    }
  }

  /// There is no durable per-peer version acknowledgement. Keep every version
  /// of a tracked entity, including ancestors and hashes already advertised to
  /// an offline peer. Only revisions whose entity has no row, no lan_entities
  /// index, no pending sync work, and whose hash is no head of any index
  /// (legacy rows may point at another entity's hash) are reclaimed.
  Future<void> _pruneOrphanRevisions() => cloudLocalWrite(
    () => local.db.transaction(() async {
      // External settings/files have owners outside SQLite; their histories
      // stay intact because this transaction cannot prove their absence.
      for (final kind in ['conversations', 'providers', 'messages']) {
        await local.execute(
          '''DELETE FROM lan_revisions AS r
          WHERE r.kind=?
          AND NOT EXISTS (SELECT 1 FROM "$kind" c WHERE c.id=r.entity_id)
          AND NOT EXISTS (SELECT 1 FROM lan_entities e
            WHERE e.kind=r.kind AND e.entity_id=r.entity_id)
          AND NOT EXISTS (SELECT 1 FROM lan_entities e,json_each(e.heads_json) h
            WHERE h.value=r.hash)
          AND NOT EXISTS (SELECT 1 FROM lan_dirty d
            WHERE d.kind=r.kind AND d.entity_id=r.entity_id)
          AND NOT EXISTS (SELECT 1 FROM cloud_dirty d
            WHERE d.kind=r.kind AND d.entity_id=r.entity_id)
          AND NOT EXISTS (SELECT 1 FROM cloud_outbox o
            WHERE o.kind=r.kind AND o.entity_id=r.entity_id)
          AND NOT EXISTS (SELECT 1 FROM cloud_inbox i
            WHERE i.kind=r.kind AND i.entity_id=r.entity_id)
          AND NOT EXISTS (SELECT 1 FROM cloud_versions v
            WHERE v.kind=r.kind AND v.entity_id=r.entity_id)
          AND NOT EXISTS (SELECT 1 FROM lan_pending_deletions p
            WHERE p.hash=r.hash OR (
              json_extract(p.document_json,'\$.kind')=r.kind AND
              json_extract(p.document_json,'\$.entity_id')=r.entity_id))''',
          [kind],
        );
      }
    }),
  );

  /// Keep local history complete. Only the outgoing copy drops verbose shell
  /// output, before media encoding and immutable revision hashing.
  CloudLocalDocument _syncDocument(CloudLocalDocument current) {
    if (current.kind != 'messages') return current;
    final row = current.payload['row'];
    if (row is! Map) return current;
    final raw = row['raw_payload'];
    if (raw is! String || raw.length <= 500000) return current;
    final payload = jsonDecode(raw);
    if (payload is! Map || payload['rawToolResults'] is! List) return current;
    var changed = false;
    for (final tool in payload['rawToolResults'] as List) {
      if (tool is! Map || tool['structured'] is! Map) continue;
      final structured = tool['structured'] as Map;
      final output = structured['output'];
      if (output is! String) continue;
      final bytes = utf8.encode(output);
      if (bytes.length <= 32 * 1024) continue;
      // A 16 KiB tail preserves the useful final diagnostic without splitting
      // a multibyte UTF-8 character or replacing it with a decoding marker.
      var start = bytes.length - 16 * 1024;
      while ((bytes[start] & 0xc0) == 0x80) {
        start++;
      }
      structured['output'] = utf8.decode(bytes.sublist(start));
      changed = true;
    }
    return changed
        ? CloudLocalDocument(current.kind, current.id, {
            ...current.payload,
            'row': {...row, 'raw_payload': jsonEncode(payload)},
          })
        : current;
  }

  Future<String> _fingerprint(
    CloudLocalDocument? current,
    String kind,
    String id,
  ) async => current == null
      ? 'deleted'
      : cloudObjectId(
          canonicalJson({
            'payload': Map<String, dynamic>.of(current.payload)
              ..remove('client_schema'),
            if (lanSettingKinds.contains(kind))
              'setting_times': await _settingTimes(current, kind, id),
          }),
        );

  /// Only a hash of the *current* business data under the legacy algorithm
  /// qualifies. Comparing to head payloads would hide genuine offline edits.
  Future<bool> _matchesLegacyFingerprint(
    CloudLocalDocument? current,
    String kind,
    String id,
    List<LanRevision> heads,
    String known,
  ) async {
    if (current == null) return known == 'deleted';
    final times = lanSettingKinds.contains(kind)
        ? await _settingTimes(current, kind, id)
        : null;
    for (final schema in {
      current.payload['client_schema'],
      ...heads.map((head) => head.payload['client_schema']),
    }) {
      final payload = Map<String, dynamic>.of(current.payload);
      if (schema == null) {
        payload.remove('client_schema');
      } else {
        payload['client_schema'] = schema;
      }
      if (cloudObjectId(
            canonicalJson({
              'payload': payload,
              if (times != null) 'setting_times': times,
            }),
          ) ==
          known) {
        return true;
      }
    }
    return false;
  }

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
  Future<List<LanRevision>> _heads(
    Map<String, dynamic> row, {
    Map<String, String>? documents,
  }) async {
    final result = <LanRevision>[];
    for (final hash in _headHashes(row)) {
      String? document;
      if (documents != null) {
        document = documents[hash];
      } else {
        final stored = await local.rows(
          'SELECT document_json FROM lan_revisions WHERE hash=?',
          [hash],
        );
        if (stored.isNotEmpty) {
          document = stored.single['document_json'] as String;
        }
      }
      if (document == null) throw const LanSyncFailure('同步修订已变化，请重试');
      result.add(_storedRevision(hash, document));
    }
    return result;
  }

  List<String> _headHashes(Map<String, dynamic> row) {
    try {
      return List<String>.from(jsonDecode(row['heads_json'] as String) as List);
    } on FormatException {
      throw const LanSyncFailure('同步修订列表格式无效');
    } on TypeError {
      throw const LanSyncFailure('同步修订列表格式无效');
    }
  }

  /// Only persisted, checksum-validated documents enter this cache. Keep the
  /// original text as well: a changed database row must never reuse stale data.
  LanRevision _storedRevision(String hash, String document) {
    final cached = _revisionCache.remove(hash);
    if (cached != null) {
      if (cached.$1 == document) {
        _revisionCache[hash] = cached;
        return cached.$2;
      }
      _revisionCacheBytes -= cached.$3;
    }
    final LanRevision revision;
    try {
      revision = LanRevision.fromJson(
        Map<String, dynamic>.from(jsonDecode(document) as Map),
      );
    } on FormatException {
      throw const LanSyncFailure('同步修订内容格式无效');
    } on TypeError {
      throw const LanSyncFailure('同步修订内容格式无效');
    }
    if (revision.hash != hash) throw const LanSyncFailure('同步内容校验失败');
    final bytes = utf8.encode(document).length;
    if (bytes <= _revisionCacheByteLimit) {
      _revisionCache[hash] = (document, revision, bytes);
      _revisionCacheBytes += bytes;
      while (_revisionCache.length > _revisionCacheLimit ||
          _revisionCacheBytes > _revisionCacheByteLimit) {
        final oldest = _revisionCache.remove(_revisionCache.keys.first)!;
        _revisionCacheBytes -= oldest.$3;
      }
    }
    return revision;
  }

  /// One unreadable entity must not take the whole conflict list (and LAN
  /// initialization) down with it; it is skipped and logged instead.
  Future<List<LanRevision>?> _readableHeads(
    Map<String, dynamic> row, {
    bool requireSupported = false,
    Map<String, String>? documents,
    bool hideSending = false,
  }) async {
    try {
      final heads = (await _heads(row, documents: documents))
          .where(
            (head) =>
                !hideSending ||
                head.deleted ||
                !CloudLocalDocument(
                  head.kind,
                  head.id,
                  head.payload,
                ).isSendingMessage,
          )
          .toList();
      if (requireSupported) {
        for (final head in heads) {
          await local.validateRowPayload(head.kind, head.id, head.payload);
        }
      }
      return heads;
    } on LanSyncFailure catch (e) {
      AppLogger.warning(
        'LanSync',
        '跳过无法读取的同步记录',
        metadata: {
          'kind': row['kind'],
          'entity_id': row['entity_id'],
          'error': e.message,
        },
      );
      return null;
    } on CloudSyncFailure catch (e) {
      AppLogger.warning(
        'LanSync',
        '跳过当前版本无法读取的同步记录',
        metadata: {
          'kind': row['kind'],
          'entity_id': row['entity_id'],
          'error': e.message,
        },
      );
      return null;
    }
  }

  Future<void> _save(LanRevision r) async {
    await local.validateRowPayload(r.kind, r.id, r.payload);
    await local.execute(
      'INSERT OR IGNORE INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
      [r.hash, r.kind, r.id, canonicalJson(r.toJson())],
    );
  }

  Future<List<LanRevision>> _pendingHeads(String kind, String id) async {
    final rows = await local.rows(
      r"SELECT hash,document_json FROM lan_pending_deletions WHERE json_extract(document_json,'$.kind')=? AND json_extract(document_json,'$.entity_id')=?",
      [kind, id],
    );
    return rows
        .map(
          (row) => _storedRevision(
            row['hash'] as String,
            row['document_json'] as String,
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
      // Read raw JSON so corrupt head lists/documents are isolated per entity,
      // rather than aborting the entire page inside SQLite JSON functions.
      r"""SELECT e.kind,e.entity_id,e.heads_json
      FROM lan_entities e WHERE e.kind||'/'||e.entity_id>?
      ORDER BY e.kind,e.entity_id LIMIT ?""",
      [after, limit + 1],
    );
    final selected = rows.take(limit).toList();
    final hashes = <String>{};
    for (final row in selected) {
      try {
        hashes.addAll(_headHashes(row));
      } on LanSyncFailure {
        // The per-entity read below reports the warning and skips this row.
      }
    }
    final documents = <String, String>{};
    if (hashes.isNotEmpty) {
      for (final row in await local.rows(
        'SELECT hash,document_json FROM lan_revisions WHERE hash IN (${List.filled(hashes.length, '?').join(',')})',
        hashes.toList(),
      )) {
        documents[row['hash'] as String] = row['document_json'] as String;
      }
    }
    final items = <Map<String, dynamic>>[];
    for (final row in selected) {
      final heads = await _readableHeads(
        row,
        requireSupported: true,
        documents: documents,
        // Legacy sending heads remain causal history, but are not advertised.
        // Keep their entity in the page so hidden pages still advance cursors.
        hideSending: true,
      );
      if (heads == null || heads.isEmpty) continue;
      items.add({
        'kind': row['kind'],
        'entity_id': row['entity_id'],
        'hashes': heads.map((head) => head.hash).toList(),
      });
    }
    final total = after.isEmpty
        ? (await local.rows(
                'SELECT COUNT(*) AS n FROM lan_entities',
              )).single['n']
              as int
        : null;
    return {
      'items': items,
      'after': selected.isEmpty
          ? after
          : '${selected.last['kind']}/${selected.last['entity_id']}',
      'has_more': rows.length > limit,
      if (total != null) 'total': total,
    };
  });
  Future<List<String>> missing(Iterable<String> hashes) => _serial(() async {
    final candidates = hashes
        .toSet()
        .where((hash) => !_revisionCache.containsKey(hash))
        .toList();
    final present = <String>{};
    for (var start = 0; start < candidates.length; start += 200) {
      final batch = candidates.skip(start).take(200).toList();
      for (final row in await local.rows(
        'SELECT hash FROM lan_revisions WHERE hash IN (${List.filled(batch.length, '?').join(',')})',
        batch,
      )) {
        present.add(row['hash'] as String);
      }
    }
    return candidates.where((hash) => !present.contains(hash)).toList();
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
    final revision = _storedRevision(
      hash,
      rows.single['document_json'] as String,
    );
    await local.validateRowPayload(
      revision.kind,
      revision.id,
      revision.payload,
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
    await local.validateRowPayload(
      incoming.kind,
      incoming.id,
      incoming.payload,
    );
    try {
      if (!incoming.deleted) {
        CloudMediaCodec.validateWirePaths(incoming.payload);
      }
    } on FormatException {
      throw const LanSyncFailure('附件必须使用媒体引用，不能接收另一台设备的本地文件路径');
    }
    await _capture(kind: incoming.kind, id: incoming.id);
    final applied = <String>{};
    (String, String, int)? messageApplied;
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
            var unchangedMessage = false;
            if (chosen.kind == 'messages' &&
                !chosen.deleted &&
                current != null) {
              final incomingFingerprint = await _fingerprint(
                CloudLocalDocument(chosen.kind, chosen.id, payload),
                chosen.kind,
                chosen.id,
              );
              unchangedMessage =
                  fingerprint == incomingFingerprint ||
                  await _fingerprint(
                        _syncDocument(current),
                        chosen.kind,
                        chosen.id,
                      ) ==
                      incomingFingerprint;
            }
            if (!unchangedMessage) {
              await local.apply(
                chosen.kind,
                chosen.id,
                payload,
                chosen.deleted,
              );
            }
            await local.markRelay(
              chosen.kind,
              chosen.id,
              DateTime.now().add(lanRelayDelay).millisecondsSinceEpoch,
            );
            if (!unchangedMessage) {
              if (chosen.kind == 'messages' && onMessageApplied != null) {
                final row =
                    (payload['row'] ?? current?.payload['row']) as Map?;
                final convId = row?['conversation_id'] as String?;
                final createdAt = (row?['created_at'] as num?)?.toInt();
                if (convId != null && createdAt != null) {
                  messageApplied = (convId, chosen.id, createdAt);
                } else {
                  applied.add(chosen.kind);
                }
              } else {
                applied.add(chosen.kind);
              }
            }
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
    final message = messageApplied;
    if (message != null) {
      onMessageApplied?.call(message.$1, message.$2, message.$3);
    }
  });

  Future<List<List<LanRevision>>> conflicts() async {
    // The serial write lane can be waiting on files or media. Read only the
    // database here, in one short snapshot; parse and assemble after it closes.
    const entitiesSql = r"""SELECT e.*,
      CASE WHEN json_valid(e.heads_json)
        THEN json_array_length(e.heads_json)>1 ELSE 1 END AS is_conflict,
      (e.kind='conversations'
        AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id=e.entity_id)
        AND EXISTS (SELECT 1 FROM lan_pending_deletions p
          WHERE CASE WHEN json_valid(p.document_json) THEN
            json_extract(p.document_json,'$.kind')='conversations'
            AND json_extract(p.document_json,'$.entity_id')=e.entity_id
          ELSE 0 END)) AS has_pending
      FROM lan_entities e WHERE is_conflict OR has_pending""";
    final (entities, pending, documents) = await local.db.transaction(() async {
      final entities = await local.rows(entitiesSql);
      final pending = await local.rows(r"""SELECT hash,document_json,
        CASE WHEN json_valid(document_json)
          THEN json_extract(document_json,'$.kind') END AS kind,
        CASE WHEN json_valid(document_json)
          THEN json_extract(document_json,'$.entity_id') END AS entity_id
        FROM lan_pending_deletions""");
      // Let SQLite extract raw hashes, without decoding revision JSON while
      // holding the transaction. Deduplicate across every selected entity.
      final hashes = await local.rows('''SELECT DISTINCT h.value AS hash
        FROM ($entitiesSql) e,
        json_each(CASE WHEN json_valid(e.heads_json) THEN e.heads_json ELSE '[]' END) h
        WHERE h.type='text' ''');
      final documents = <String, String>{};
      for (var start = 0; start < hashes.length; start += 200) {
        final batch = hashes
            .skip(start)
            .take(200)
            .map((r) => r['hash'] as String)
            .toList();
        for (final row in await local.rows(
          'SELECT hash,document_json FROM lan_revisions WHERE hash IN (${List.filled(batch.length, '?').join(',')})',
          batch,
        )) {
          documents[row['hash'] as String] = row['document_json'] as String;
        }
      }
      return (entities, pending, documents);
    });
    final pendingById = <String, List<Map<String, dynamic>>>{};
    for (final row in pending) {
      if (row['kind'] == 'conversations' && row['entity_id'] is String) {
        (pendingById[row['entity_id'] as String] ??= []).add(row);
      } else if (row['kind'] == null || row['entity_id'] is! String) {
        AppLogger.warning(
          'LanSync',
          '跳过无法读取的待删除同步记录',
          metadata: {'hash': row['hash']},
        );
      }
    }
    final result = <List<LanRevision>>[];
    for (final row in entities) {
      try {
        final heads = <LanRevision>[];
        for (final hash in _headHashes(row)) {
          final document = documents[hash];
          if (document == null) throw const LanSyncFailure('同步修订已变化，请重试');
          final head = _storedRevision(hash, document);
          if (head.kind != row['kind'] || head.id != row['entity_id']) {
            throw const LanSyncFailure('同步修订与实体不一致');
          }
          heads.add(head);
        }
        if (row['has_pending'] == 1) {
          final versions = {for (final head in heads) head.hash: head};
          for (final pending
              in pendingById[row['entity_id']] ?? <Map<String, dynamic>>[]) {
            final revision = _storedRevision(
              pending['hash'] as String,
              pending['document_json'] as String,
            );
            versions[revision.hash] = revision;
          }
          if (versions.length > 1) result.add(versions.values.toList());
        } else if (row['is_conflict'] == 1) {
          result.add(heads);
        }
      } on LanSyncFailure catch (e) {
        AppLogger.warning(
          'LanSync',
          '跳过无法读取的同步记录',
          metadata: {
            'kind': row['kind'],
            'entity_id': row['entity_id'],
            'error': e.message,
          },
        );
      }
    }
    return result;
  }

  Future<void> resolve(
    String kind,
    String id,
    String selectedHash,
    List<String> previewHashes,
  ) => _serial(() async {
    await _capture(kind: kind, id: id);
    var changedSinceCapture = false;
    (String, String, int)? messageApplied;
    await cloudLocalWrite(
      () => local.db.transaction(() async {
        final row = await _entity(kind, id);
        if (row == null) throw const LanSyncFailure('同时修改记录不存在');
        final current = await local.read(kind, id);
        if (current?.isSendingMessage == true ||
            await _fingerprint(current, kind, id) != row['local_fingerprint']) {
          changedSinceCapture = true;
          return;
        }
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
          if (kind == 'settings') {
            // A legacy head may carry device-local General fields; the
            // resolution is a new revision and must not re-publish them.
            final key = payload['key'] as String;
            payload['json_value'] = projectCloudPreference(
              key,
              payload['json_value'],
            );
            if (key == cloudUiModelsKey) {
              fieldsToStamp.removeAll(localGeneralSettings);
            }
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
          await local.mark(kind, id);
          if (kind == 'messages' && onMessageApplied != null) {
            final msgRow =
                (decoded['row'] ?? current?.payload['row']) as Map?;
            final convId = msgRow?['conversation_id'] as String?;
            final createdAt = (msgRow?['created_at'] as num?)?.toInt();
            if (convId != null && createdAt != null) {
              messageApplied = (convId, id, createdAt);
            }
          }
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
    if (changedSinceCapture) {
      // Capture after releasing the failed compare-and-apply transaction so an
      // intervening edit becomes a causal head before the next preview.
      await _capture(kind: kind, id: id);
      throw const LanSyncFailure('内容已有新修改，请刷新后选择');
    }
    if (messageApplied != null) {
      onMessageApplied!(
        messageApplied!.$1,
        messageApplied!.$2,
        messageApplied!.$3,
      );
    } else {
      onApplied?.call({kind});
    }
  });
}
