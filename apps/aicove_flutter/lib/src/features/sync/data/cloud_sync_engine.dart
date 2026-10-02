import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../../core/media/media_asset.dart';
import '../../../core/sync/cloud_local_write.dart';
import '../../../core/sync/cloud_tracking.dart';
import '../../../core/sync/cloud_setting_policy.dart';
import '../../../core/media/media_store.dart';
import 'cloud_api.dart';
import 'cloud_document.dart';
import 'cloud_local_store.dart';
import 'cloud_media_codec.dart';

class CloudProgress {
  const CloudProgress(
    this.message, {
    this.busy = false,
    this.enabled = false,
    this.completed = 0,
    this.pending = 0,
    this.conflicts = 0,
    this.error,
    this.confirmedMessages = 0,
    this.totalMessages = 0,
    this.uploadedFiles = 0,
    this.uploadedBytes = 0,
  });
  final String message;
  final bool busy, enabled;
  final int completed, pending, conflicts;
  final String? error;
  final int confirmedMessages, totalMessages, uploadedFiles, uploadedBytes;
}

/// Immutable outbox operations survive response loss. Inbox pages and their
/// cursor commit together; business data is applied only after dependencies.
class CloudSyncEngine {
  CloudSyncEngine(
    this.local,
    this.remote,
    this.media,
    this.accountKey, {
    this.onProgress,
    this.onApplied,
    DateTime Function()? clock,
  }) : now = clock ?? DateTime.now,
       codec = CloudMediaCodec(media) {
    media.downloadBlob = remote.download;
  }
  final CloudLocalStore local;
  final CloudRemote remote;
  final MediaStore media;
  final String accountKey;
  final CloudMediaCodec codec;
  final DateTime Function() now;
  final void Function(CloudProgress)? onProgress;
  final void Function(Set<String>)? onApplied;
  bool _running = false, _closed = false;
  String? _epoch;
  bool _indexedRead = false, _probeBlobs = false;
  bool _settingTimes = false;
  int _mediaPriority = 0;
  Future<void>? _mediaWork;

  Future<void> waitForMedia() async {
    while (_mediaWork != null) {
      await _mediaWork;
    }
  }

  int _completed = 0;
  int _confirmedMessages = 0,
      _totalMessages = 0,
      _uploadedFiles = 0,
      _uploadedBytes = 0;
  final _uploaded = <String>{};

  void _report(CloudProgress progress) => onProgress?.call(
    CloudProgress(
      progress.message,
      busy: progress.busy,
      enabled: progress.enabled,
      completed: progress.completed,
      pending: progress.pending,
      conflicts: progress.conflicts,
      error: progress.error,
      confirmedMessages: _confirmedMessages,
      totalMessages: _totalMessages,
      uploadedFiles: _uploadedFiles,
      uploadedBytes: _uploadedBytes,
    ),
  );

  void close() {
    _closed = true;
    media.downloadBlob = null;
    remote.close();
  }

  void _checkOpen() {
    if (_closed) throw const CloudSyncFailure('账号已退出，同步已暂停');
  }

  Future<void> enable() async {
    await local.execute('UPDATE cloud_client_state SET enabled=1 WHERE id=1');
    await synchronize();
  }

  Future<void> pause() async {
    await local.execute('UPDATE cloud_client_state SET enabled=0 WHERE id=1');
  }

  Future<void> synchronize({bool pollOnly = false}) async {
    if (_running || _closed) return;
    _running = true;
    _completed = _confirmedMessages = _totalMessages = _uploadedFiles =
        _uploadedBytes = 0;
    try {
      var state = await local.state();
      if (state['enabled'] != 1) {
        _report(const CloudProgress('云同步尚未启用'));
        return;
      }
      if (!pollOnly) {
        _report(const CloudProgress('正在连接云端', busy: true, enabled: true));
      }
      final status = await remote.get('status');
      if (status['media_version'] != 1) {
        throw const CloudSyncFailure('服务器需要升级图片同步协议');
      }
      if (status['message_snapshot_version'] != 1 ||
          status['media_usage_version'] != 1) {
        throw const CloudSyncFailure('服务器需要升级消息快照与图片用途协议');
      }
      _epoch = status['epoch'] as String;
      _indexedRead = status['indexed_read_version'] == 1;
      _probeBlobs = status['blob_probe_version'] == 1;
      _settingTimes = status['setting_times_version'] == 1;
      if (state['account_key'] != null && state['account_key'] != accountKey) {
        throw const CloudSyncFailure('本机数据属于另一账号，已停止同步');
      }
      if (state['epoch'] != null && state['epoch'] != _epoch) {
        throw const CloudSyncFailure('云端数据版本已变化，已暂停自动同步并保留本机数据');
      }
      if (pollOnly &&
          state['initialized'] == 1 &&
          status['cursor'] == state['cursor'] &&
          (await local.rows('''SELECT 1 FROM cloud_dirty
            UNION ALL SELECT 1 FROM cloud_outbox
            UNION ALL SELECT 1 FROM cloud_inbox LIMIT 1''')).isEmpty) {
        _startMediaTransfer();
        return;
      }
      if (pollOnly) {
        _report(const CloudProgress('正在同步更新', busy: true, enabled: true));
      }
      if (state['initialized'] == 0) {
        final receiving =
            state['mode'] == 'receive' ||
            (state['mode'] == null && status['cursor'] != 0);
        if (state['mode'] == null) {
          if (receiving && await local.hasHistory()) {
            throw const CloudSyncFailure('云端与本机都有历史记录，需要先选择合并来源；现有数据已保留');
          }
          final backup = await local.backup();
          await local.execute(
            'UPDATE cloud_client_state SET account_key=?,epoch=?,mode=?,backup_path=? WHERE id=1',
            [accountKey, _epoch, receiving ? 'receive' : 'source', backup],
          );
          if (receiving) await local.execute('DELETE FROM cloud_dirty');
        }
        if (receiving) {
          if (_indexedRead) {
            await _readInitialState();
          } else {
            await _pull(bootstrap: true);
            await _applyInbox(initial: true);
          }
        } else {
          await local.seed();
        }
        await local.execute(
          'UPDATE cloud_client_state SET initialized=1 WHERE id=1',
        );
      }
      // Retry a previously frozen operation before reading remote changes.
      await _sendOutbox();
      await local.prepareMessageSnapshots(
        onProgress: (done, total) {
          _report(
            CloudProgress(
              '正在升级本地同步索引（$done/$total）',
              busy: true,
              enabled: true,
            ),
          );
        },
      );
      await local.captureExternal(trackSettingTimes: _settingTimes);
      await local.pruneUnchangedReceiverEdits(trackSettingTimes: _settingTimes);
      if (_indexedRead && (await local.state())['mode'] == 'receive') {
        final window = await local.rows(
          'SELECT stage FROM cloud_read_state WHERE id=1',
        );
        if (window.isEmpty || window.single['stage'] != 'done') {
          await _readInitialState(initial: false);
        }
      }
      await local.compactEmbeddedMedia(
        mediaStore: media,
        onProgress: (done, total) {
          _report(
            CloudProgress(
              '正在整理本地媒体引用（$done/$total）',
              busy: true,
              enabled: true,
            ),
          );
        },
      );
      await _pull();
      await _applyInbox();
      await _pushDirty();
      await _pull();
      await _applyInbox();
      // History and thumbnails are durable first. Large originals follow and
      // resume independently; old originals are never queued by age alone.
      _startMediaTransfer();
      state = await local.state();
      final pending =
          (await local.rows(
                'SELECT COUNT(*) AS n FROM cloud_dirty',
              )).single['n']
              as int;
      final conflicts =
          (await local.rows(
                'SELECT COUNT(*) AS n FROM cloud_versions WHERE conflict_id IS NOT NULL',
              )).single['n']
              as int;
      _report(
        CloudProgress(
          conflicts > 0
              ? '有 $conflicts 项同时修改，两个版本均已保留'
              : _mediaWork != null
              ? '记录已同步，正在传输附件'
              : '同步完成',
          enabled: state['enabled'] == 1,
          completed: _completed,
          pending: pending,
          conflicts: conflicts,
        ),
      );
    } catch (error) {
      if (!_closed) {
        _report(
          CloudProgress(
            '同步暂停，稍后重试',
            enabled: true,
            completed: _completed,
            error: error is CloudSyncFailure
                ? error.message
                : error is OriginalMediaUnavailable
                ? error.toString()
                : '同步未完成，已有数据与进度已保留',
          ),
        );
      }
      rethrow;
    } finally {
      _running = false;
    }
  }

  Future<Map<String, dynamic>> previewConflicts() async {
    final before = await remote.get('status');
    final conflicts = await remote.get('conflicts');
    final after = await remote.get('status');
    if (before['cursor'] != after['cursor']) {
      throw const CloudSyncFailure('云端已有变化，请刷新后查看');
    }
    return {...conflicts, 'cursor': after['cursor'], 'epoch': after['epoch']};
  }

  Future<void> resolveConflict(
    Map<String, dynamic> preview,
    String id, {
    required bool incoming,
  }) async {
    if (_running) throw const CloudSyncFailure('请等待本轮同步完成后处理');
    _running = true;
    try {
      await remote.post('conflicts/$id/resolve?use_incoming=$incoming', {
        'op_id': const Uuid().v4(),
        'device_id': media.deviceId,
        'epoch': preview['epoch'],
        'expected_cursor': preview['cursor'],
      });
    } finally {
      _running = false;
    }
    await synchronize();
  }

  Future<void> _readInitialState({bool initial = true}) async {
    if ((await local.rows('SELECT 1 FROM cloud_read_state')).isEmpty) {
      final status = await remote.get('status');
      await local.execute("INSERT INTO cloud_read_state VALUES(1,?,'head',0)", [
        status['cursor'],
      ]);
    }
    while (true) {
      final state = (await local.rows('SELECT * FROM cloud_read_state')).single;
      if (state['stage'] == 'done') {
        _mediaPriority = 0;
        return;
      }
      _checkOpen();
      if ((await local.state())['enabled'] != 1) {
        throw const CloudSyncFailure('同步已暂停');
      }
      final page = await remote.get('read', {
        'epoch': _epoch,
        'through': state['through'],
        'after': state['after_seq'],
        'stage': state['stage'],
        'limit': 512,
      });
      await local.db.transaction(() async {
        await _stageReadPage(page, priority: state['stage'] == 'head' ? 0 : 1);
        if (page['has_more'] == true) {
          await local.execute('UPDATE cloud_read_state SET after_seq=?', [
            page['next_cursor'],
          ]);
        } else if (state['stage'] == 'head') {
          await local.execute(
            "UPDATE cloud_read_state SET stage='history',after_seq=0",
          );
        } else {
          await local.execute(
            "UPDATE cloud_read_state SET stage='done',after_seq=0",
          );
          await local.execute(
            'UPDATE cloud_client_state SET cursor=? WHERE id=1',
            [state['through']],
          );
        }
      });
      _mediaPriority = state['stage'] == 'head' ? 0 : 1;
      await _applyInbox(
        initial: initial,
        sequences: {
          for (final d in [
            ...page['dependencies'] as List,
            ...page['documents'] as List,
          ])
            d['seq'] as int,
        },
      );
      _startMediaTransfer();
    }
  }

  Future<void> _stageReadPage(
    Map<String, dynamic> page, {
    int priority = 0,
  }) async {
    for (final document in [
      ...page['dependencies'] as List,
      ...page['documents'] as List,
    ]) {
      await local.execute(
        'INSERT OR IGNORE INTO cloud_inbox(seq,kind,entity_id,document_json) VALUES(?,?,?,?)',
        [
          document['seq'],
          document['kind'],
          document['entity_id'],
          canonicalJson(document),
        ],
      );
      if (document['kind'] == 'media_assets' && document['deleted'] != true) {
        await _queueMedia(document['entity_id'] as String, priority: priority);
      }
    }
  }

  Future<void> _pull({bool bootstrap = false}) async {
    var cursor = (await local.state())['cursor'] as int;
    if (_indexedRead && !bootstrap) {
      cursor = await _consumeAcknowledgements(cursor);
    }
    int? through;
    while (true) {
      _checkOpen();
      _report(const CloudProgress('正在读取云端变更', busy: true, enabled: true));
      final page = await remote.get(
        _indexedRead && !bootstrap
            ? 'read'
            : bootstrap
            ? 'bootstrap'
            : 'pull',
        {
          'epoch': _epoch,
          'after': cursor,
          'limit': _indexedRead && !bootstrap ? 512 : 100,
          if (_indexedRead && !bootstrap) 'stage': 'delta',
          if (through != null) 'through': through,
        },
      );
      through ??= page['through'] as int;
      final documents =
          (page[_indexedRead && !bootstrap
                      ? 'documents'
                      : bootstrap
                      ? 'entities'
                      : 'changes']
                  as List)
              .cast<Map>();
      await local.db.transaction(() async {
        for (final document in [
          ...?page['dependencies'] as List?,
          ...documents,
        ]) {
          await local.execute(
            'INSERT OR IGNORE INTO cloud_inbox(seq,kind,entity_id,document_json) VALUES(?,?,?,?)',
            [
              document['seq'],
              document['kind'],
              document['entity_id'],
              canonicalJson(document),
            ],
          );
        }
        cursor = page['next_cursor'] as int;
        await local.execute(
          'UPDATE cloud_client_state SET cursor=? WHERE id=1',
          [cursor],
        );
      });
      if (_indexedRead && !bootstrap) {
        _mediaPriority = 0;
        await _applyInbox();
      }
      if (page['has_more'] != true) return;
    }
  }

  static int _order(String kind) => switch (kind) {
    'media_assets' => 0,
    'settings' => 1,
    'plugin_presets' => 2,
    'providers' => 3,
    'conversations' => 4,
    'messages' => 5,
    'message_blocks' => 6,
    'message_projection_mappings' => 7,
    _ => 8,
  };

  Future<void> _applyInbox({bool initial = false, Set<int>? sequences}) async {
    // Keep only IDs and ordering flags in memory, not the entire account's raw
    // message history. Each payload is read separately when its turn arrives.
    final ordered = await local.rows(
      r"""SELECT seq,kind,entity_id,
      json_extract(document_json,'$.deleted') AS deleted FROM cloud_inbox
      WHERE seq IN (SELECT MAX(seq) FROM cloud_inbox GROUP BY kind,entity_id)""",
    );
    if (sequences != null) {
      ordered.removeWhere((row) => !sequences.contains(row['seq']));
    }
    for (final row in ordered.where(
      (row) => row['kind'] == '_conflicts' && row['deleted'] == 1,
    )) {
      await local.execute(
        'UPDATE cloud_versions SET conflict_id=NULL WHERE conflict_id=?',
        [row['entity_id']],
      );
    }
    ordered.sort((a, b) {
      final ad = a['deleted'] == 1, bd = b['deleted'] == 1;
      if (ad != bd) return ad ? 1 : -1;
      return (ad ? -1 : 1) *
          _order(a['kind'] as String).compareTo(_order(b['kind'] as String));
    });
    // Register identities first; file I/O belongs to the independent queue.
    await _applyMediaInbox(
      ordered.where((row) => row['kind'] == 'media_assets').toList(),
    );
    final applied = <String>{};
    final candidates = ordered
        .where((row) => row['kind'] != 'media_assets')
        .toList();
    for (var offset = 0; offset < candidates.length; offset += 64) {
      await cloudLocalWrite(
        () => local.db.transaction(() async {
          for (final row in candidates.skip(offset).take(64)) {
            _checkOpen();
            final document = await _inboxDocument(row);
            final kind = document['kind'] as String,
                id = document['entity_id'] as String;
            // 退役类型：只消费收件箱推进进度，不写本地、不回传删除（ADR0038）。
            if (retiredCloudKinds.contains(kind)) {
              await _clearInbox(kind, id, document['seq'] as int);
              continue;
            }
            final childOwner = cloudMessageChildren[kind];
            if (childOwner != null) {
              final owner =
                  (document['payload'] as Map)['row'][childOwner] as String;
              final parent = await _version('messages', owner);
              if (parent?['conflict_id'] != null ||
                  (await local.rows(
                    'SELECT 1 FROM cloud_dirty WHERE kind=? AND entity_id=?',
                    ['messages', owner],
                  )).isNotEmpty) {
                continue;
              }
              if (parent != null &&
                  jsonDecode(
                        parent['cloud_json'] as String,
                      )['payload']['message_snapshot_version'] ==
                      1) {
                await _clearInbox(kind, id, document['seq'] as int);
                continue;
              }
            }
            await _acceptMatchingInboxEdit(document);
            final known = await _version(kind, id);
            if (kind == '_conflicts' ||
                (known != null &&
                    (known['version'] as int) >=
                        (document['version'] as int))) {
              await _clearInbox(kind, id, document['seq'] as int);
              continue;
            }
            if (known?['conflict_id'] != null) continue;
            if ((await local.rows(
              'SELECT 1 FROM cloud_dirty WHERE kind=? AND entity_id=?',
              [kind, id],
            )).isNotEmpty) {
              continue;
            }
            final expected = await local.read(kind, id);
            if (!initial &&
                known != null &&
                expected?.localJson != known['local_json']) {
              await local.mark(kind, id);
              continue;
            }
            final payload = await codec.decode(
              kind,
              Map<String, dynamic>.from(document['payload'] as Map),
            );
            await cloudLocalWrite(
              () => local.db.transaction(() async {
                // DB writers serialize behind this transaction. External files use a
                // second comparison after attachment preparation, before replacement.
                if (childOwner != null &&
                    (await local.rows(
                      'SELECT 1 FROM cloud_dirty WHERE kind=? AND entity_id=?',
                      ['messages', (payload['row'] as Map)[childOwner]],
                    )).isNotEmpty) {
                  return;
                }
                if ((await local.rows(
                  'SELECT 1 FROM cloud_dirty WHERE kind=? AND entity_id=?',
                  [kind, id],
                )).isNotEmpty) {
                  return;
                }
                if ((await local.read(kind, id))?.localJson !=
                    expected?.localJson) {
                  await local.mark(kind, id);
                  return;
                }
                await local.execute(
                  'UPDATE cloud_client_state SET suspended=1 WHERE id=1',
                );
                try {
                  await local.apply(
                    kind,
                    id,
                    payload,
                    document['deleted'] == true,
                  );
                  final updated = await local.read(kind, id);
                  await _remember(document, updated?.localJson);
                  if (childOwner != null) {
                    final owner = (payload['row'] as Map)[childOwner] as String;
                    final message = await local.read('messages', owner);
                    await local.execute(
                      'UPDATE cloud_versions SET local_json=? WHERE kind=? AND entity_id=?',
                      [message?.localJson, 'messages', owner],
                    );
                  }
                  await _clearInbox(kind, id, document['seq'] as int);
                  applied.add(kind);
                } finally {
                  await local.execute(
                    'UPDATE cloud_client_state SET suspended=0 WHERE id=1',
                  );
                }
              }),
            );
          }
        }),
      );
      if (applied.isNotEmpty) {
        onApplied?.call(Set.of(applied));
        applied.clear();
      }
    }
    if (applied.isNotEmpty) onApplied?.call(applied);
  }

  /// An old comparison baseline can disagree even when every current field is
  /// identical to the incoming version. Repair only exact matches, under the
  /// same database transaction, and never consume a frozen or conflicted edit.
  Future<void> _acceptMatchingInboxEdit(Map<String, dynamic> document) async {
    if (document['deleted'] == true || document['kind'] == '_conflicts') return;
    final kind = document['kind'] as String,
        id = document['entity_id'] as String;
    final pending = await local.rows(
      'SELECT d.revision,v.version FROM cloud_dirty d JOIN cloud_versions v USING(kind,entity_id) LEFT JOIN cloud_outbox o USING(kind,entity_id) WHERE d.kind=? AND d.entity_id=? AND v.conflict_id IS NULL AND o.op_id IS NULL',
      [kind, id],
    );
    if (pending.isEmpty ||
        (pending.single['version'] as int) > (document['version'] as int)) {
      return;
    }
    final current = await local.read(kind, id);
    if (current == null) return;
    final incoming = await codec.decode(
      kind,
      Map<String, dynamic>.from(document['payload'] as Map),
    );
    if (canonicalJson(current.payload) != canonicalJson(incoming)) return;
    if ((await local.read(kind, id))?.localJson != current.localJson) return;
    await local.execute(
      'UPDATE cloud_versions SET local_json=? WHERE kind=? AND entity_id=?',
      [current.localJson, kind, id],
    );
    await local.execute(
      'DELETE FROM cloud_dirty WHERE kind=? AND entity_id=? AND revision=?',
      [kind, id, pending.single['revision']],
    );
  }

  Future<Map<String, dynamic>> _inboxDocument(Map<String, dynamic> row) async =>
      Map<String, dynamic>.from(
        jsonDecode(
              (await local.rows(
                    'SELECT document_json FROM cloud_inbox WHERE seq=?',
                    [row['seq']],
                  )).single['document_json']
                  as String,
            )
            as Map,
      );

  Future<void> _applyMediaInbox(List<Map<String, dynamic>> rows) async {
    var next = 0, completed = 0;
    Future<void> worker() async {
      while (next < rows.length) {
        _checkOpen();
        final document = await _inboxDocument(rows[next++]);
        final id = document['entity_id'] as String;
        final known = await _version('media_assets', id);
        if (known != null &&
            (known['version'] as int) >= (document['version'] as int)) {
          await _clearInbox('media_assets', id, document['seq'] as int);
          continue;
        }
        if (known?['conflict_id'] != null) continue;
        if (document['deleted'] != true) {
          await media.receive(
            MediaAsset.fromJson(
              Map<String, dynamic>.from(document['payload'] as Map),
            ),
            now: now(),
            includeRecentOriginal: false,
            download: false,
          );
        }
        await local.db.transaction(() async {
          await _remember(document, null);
          if (document['deleted'] != true) {
            await _queueMedia(id, priority: _mediaPriority);
          }
          await _clearInbox('media_assets', id, document['seq'] as int);
        });
        _report(
          CloudProgress(
            '正在接收附件资料（${++completed}/${rows.length}）',
            busy: true,
            enabled: true,
            completed: _completed,
          ),
        );
      }
    }

    await Future.wait(List.generate(rows.length.clamp(0, 3), (_) => worker()));
  }

  Future<void> _clearInbox(String kind, String id, int seq) => local.execute(
    'DELETE FROM cloud_inbox WHERE kind=? AND entity_id=? AND seq<=?',
    [kind, id, seq],
  );
  Future<Map<String, dynamic>?> _version(String kind, String id) async =>
      (await local.rows(
        'SELECT * FROM cloud_versions WHERE kind=? AND entity_id=?',
        [kind, id],
      )).firstOrNull;
  Future<void> _remember(
    Map<String, dynamic> document,
    String? localJson, {
    String? conflict,
  }) => local.execute(
    '''
    INSERT INTO cloud_versions(kind,entity_id,version,local_json,cloud_json,conflict_id) VALUES(?,?,?,?,?,?)
    ON CONFLICT(kind,entity_id) DO UPDATE SET version=excluded.version,local_json=excluded.local_json,
      cloud_json=excluded.cloud_json,conflict_id=excluded.conflict_id
      WHERE excluded.version>=cloud_versions.version''',
    [
      document['kind'],
      document['entity_id'],
      document['version'],
      localJson,
      canonicalJson(
        document['kind'] == 'messages' &&
                document['payload']['message_snapshot_version'] == 1 &&
                conflict == null
            ? {
                ...document,
                'payload': {'message_snapshot_version': 1},
              }
            : document,
      ),
      conflict,
    ],
  );

  Future<Map<String, dynamic>> _keepNewerLocalSettings(
    String kind,
    String id,
    Map<String, dynamic> incoming,
  ) async {
    final current = await local.read(kind, id);
    if (current == null) return incoming;
    final localTimes = await local.settingTimes(kind, id, media.deviceId);
    final times = Map<String, dynamic>.from(
      incoming['setting_times'] as Map? ?? {},
    );
    final row = kind == 'conversations' || kind == 'providers';
    final key = incoming['key'] as String? ?? '';
    Map<String, dynamic> fields(Map<String, dynamic> payload) => row
        ? Map<String, dynamic>.from(payload['row'] as Map)
        : cloudPreferenceFields(key, payload['json_value']);
    final merged = fields(incoming), localFields = fields(current.payload);
    for (final entry in localTimes.entries) {
      final stamp = entry.value as Map;
      final remote = times[entry.key] as Map? ?? {};
      final at = (stamp['at_ms'] as num?)?.toInt() ?? 0;
      final otherAt = (remote['at_ms'] as num?)?.toInt() ?? 0;
      final newer =
          at > otherAt ||
          (at == otherAt &&
              (stamp['device_id'] as String).compareTo(
                    remote['device_id'] as String? ?? '',
                  ) >
                  0);
      if (!newer) continue;
      if (localFields.containsKey(entry.key)) {
        merged[entry.key] = localFields[entry.key];
      } else {
        merged.remove(entry.key);
      }
      times[entry.key] = entry.value;
    }
    final payload = {...incoming, 'setting_times': times};
    if (row) {
      payload['row'] = merged;
    } else {
      final value = incoming['json_value'];
      var objectValue = false;
      if (value is String) {
        try {
          objectValue = jsonDecode(value) is Map;
        } on FormatException {
          /* Plain string. */
        }
      }
      payload['json_value'] = objectValue
          ? canonicalSettingJson(merged)
          : merged['value'];
    }
    return payload;
  }

  Future<void> _sendOutbox() async {
    while (true) {
      final pending = await local.rows(
        'SELECT op_id,kind,entity_id,revision,length(CAST(mutation_json AS BLOB)) AS bytes FROM cloud_outbox ORDER BY rowid LIMIT 100',
      );
      if (pending.isEmpty) return;
      // Keep requests below the server's byte limit even for large raw messages.
      final batch = <Map<String, dynamic>>[];
      var size = 0;
      for (final row in pending) {
        final bytes = row['bytes'] as int;
        if (batch.isNotEmpty && size + bytes > 8 * 1024 * 1024) break;
        row['mutation_json'] = (await local.rows(
          'SELECT mutation_json FROM cloud_outbox WHERE op_id=?',
          [row['op_id']],
        )).single['mutation_json'];
        batch.add(row);
        size += bytes;
      }
      final mutations = [
        for (final row in batch)
          jsonDecode(row['mutation_json'] as String) as Map<String, dynamic>,
      ];
      await _publishMediaBatch({
        for (final mutation in mutations)
          ...List<String>.from(mutation['media_ids'] as List? ?? []),
      }, metadataOnly: true);
      _checkOpen();
      final response = await remote.post('push', {
        'protocol_version': 3,
        'epoch': _epoch,
        'device_id': media.deviceId,
        'mutations': mutations,
      });
      final results = {
        for (final result in response['results'] as List)
          result['op_id']: result,
      };
      final mergedPayloads = <String, Map<String, dynamic>>{};
      for (final row in batch) {
        final result = results[row['op_id']];
        if (result?['status'] == 'merged') {
          mergedPayloads[row['op_id'] as String] = await codec.decode(
            row['kind'] as String,
            Map<String, dynamic>.from(result['document']['payload'] as Map),
          );
        }
      }
      final appliedKinds = <String>{};
      await cloudLocalWrite(
        () => local.db.transaction(() async {
          for (final row in batch) {
            final result = results[row['op_id']];
            if (result == null) {
              throw const CloudSyncFailure('服务器未确认完整批次，稍后安全重试');
            }
            final conflict = result['status'] == 'conflict';
            final document = Map<String, dynamic>.from(
              result[conflict ? 'current' : 'document'] as Map,
            );
            final frozen =
                (await local.rows(
                      'SELECT local_json FROM cloud_outbox WHERE op_id=?',
                      [row['op_id']],
                    )).single['local_json']
                    as String?;
            var rememberedLocal = frozen;
            final merged = mergedPayloads[row['op_id']];
            if (merged != null) {
              final deletedDuringUpload =
                  frozen != null &&
                  await local.read(
                        row['kind'] as String,
                        row['entity_id'] as String,
                      ) ==
                      null;
              final payload = await _keepNewerLocalSettings(
                row['kind'] as String,
                row['entity_id'] as String,
                merged,
              );
              await local.execute(
                'UPDATE cloud_client_state SET suspended=1 WHERE id=1',
              );
              try {
                if (!deletedDuringUpload) {
                  await local.apply(
                    row['kind'] as String,
                    row['entity_id'] as String,
                    payload,
                    false,
                  );
                  appliedKinds.add(row['kind'] as String);
                }
                // Compare against the receipt, not the overlay containing an
                // edit made during upload, or receiver pruning loses that edit.
                final baseline = Map<String, dynamic>.from(merged)
                  ..remove('setting_times_version')
                  ..remove('setting_times');
                if (baseline['storage'] == 'preference') {
                  baseline['json_value'] = projectCloudPreference(
                    baseline['key'] as String,
                    baseline['json_value'],
                  );
                }
                rememberedLocal = CloudLocalDocument(
                  row['kind'] as String,
                  row['entity_id'] as String,
                  baseline,
                ).localJson;
              } finally {
                await local.execute(
                  'UPDATE cloud_client_state SET suspended=0 WHERE id=1',
                );
              }
            } else if (!conflict &&
                (document['payload'] as Map)['setting_times_version'] == 1 &&
                (await local.read(
                      row['kind'] as String,
                      row['entity_id'] as String,
                    ))?.localJson ==
                    frozen) {
              // An identical receipt may already carry another device's clocks.
              // Inherit them only while the frozen local value is still current.
              await local.rememberSettingTimes(
                row['kind'] as String,
                row['entity_id'] as String,
                Map<String, dynamic>.from(document['payload'] as Map),
              );
            }
            await _remember(
              document,
              rememberedLocal,
              conflict: result['conflict_id'] as String?,
            );
            await _acknowledge(document);
            await local.execute(
              'DELETE FROM cloud_dirty WHERE kind=? AND entity_id=? AND revision=?',
              [row['kind'], row['entity_id'], row['revision']],
            );
            await local.execute('DELETE FROM cloud_outbox WHERE op_id=?', [
              row['op_id'],
            ]);
          }
        }),
      );
      if (appliedKinds.isNotEmpty) onApplied?.call(appliedKinds);
      _completed += batch.length;
      _confirmedMessages += batch
          .where((row) => row['kind'] == 'messages')
          .length;
    }
  }

  Future<void> _publishMediaBatch(
    Iterable<String> ids, {
    bool original = false,
    bool metadataOnly = false,
  }) async {
    final unique = ids.toSet().toList();
    for (var offset = 0; offset < unique.length; offset += 100) {
      final records = <String, LocalMedia>{};
      final mutations = <Map<String, dynamic>>[];
      final files = <String, File>{};
      for (final id in unique.skip(offset).take(100)) {
        final record = await media.load(id);
        if (record == null) throw const CloudSyncFailure('缺少附件身份信息');
        final metadata = record.asset.toJson();
        final known = await _version('media_assets', id);
        final previous = known == null
            ? null
            : jsonDecode(known['cloud_json'] as String)['payload'] as Map;
        metadata['original_blob'] ??= previous?['original_blob'];
        if (metadataOnly) {
          metadata['original_blob'] = previous?['original_blob'];
          metadata['thumbnail_blob'] = previous?['thumbnail_blob'];
          await _queueMedia(id, priority: 0);
        }
        final thumb = record.asset.thumbnailBlob;
        if (!metadataOnly &&
            thumb != null &&
            record.thumbnailPath != null &&
            previous?['thumbnail_blob'] != thumb &&
            !_uploaded.contains(thumb)) {
          files[thumb] = File(record.thumbnailPath!);
        }
        if (!metadataOnly &&
            (original ||
                record.asset.originalRequired ||
                !record.asset.isImage) &&
            record.asset.originalSha256 != null &&
            metadata['original_blob'] == null) {
          final digest = record.asset.originalSha256!;
          if (!_uploaded.contains(digest)) {
            files[digest] = await media.original(id, allowDownload: false);
          }
          metadata['original_blob'] = digest;
        }
        if (previous != null &&
            canonicalJson(previous) == canonicalJson(metadata)) {
          continue;
        }
        records[id] = record;
        final asset = MediaAsset.fromJson(metadata);
        mutations.add({
          'op_id': const Uuid().v4(),
          'kind': 'media_assets',
          'entity_id': id,
          'base_version': known?['version'] ?? 0,
          'action': 'put',
          'payload_version': 1,
          'payload': metadata,
          'blob_ids': asset.blobIds,
          'media_ids': <String>[],
        });
      }
      if (files.isNotEmpty && _probeBlobs) {
        final inventory = await remote.post('missing-blobs', {
          'digests': files.keys.toList(),
        });
        final missing = Set<String>.from(inventory['missing'] as List);
        if (!files.keys.toSet().containsAll(missing)) {
          throw const CloudSyncFailure('服务器附件清单无效');
        }
        _uploaded.addAll(files.keys.where((id) => !missing.contains(id)));
        files.removeWhere((id, _) => !missing.contains(id));
      }
      if (files.isNotEmpty) {
        _checkOpen();
        await remote.uploadBatch(files);
        _uploadedFiles += files.length;
        for (final file in files.values) {
          _uploadedBytes += await file.length();
        }
        _uploaded.addAll(files.keys);
      }
      if (mutations.isEmpty) continue;
      _checkOpen();
      final response = await remote.post('push', {
        'protocol_version': 3,
        'epoch': _epoch,
        'device_id': media.deviceId,
        'mutations': mutations,
      });
      final results = response['results'] as List;
      if (results.length != mutations.length) {
        throw const CloudSyncFailure('服务器未确认完整附件资料，稍后重试');
      }
      for (final result in results) {
        if (result['status'] != 'applied') {
          throw const CloudSyncFailure('附件资料发生同时修改，已保留原文件');
        }
        final document = Map<String, dynamic>.from(result['document'] as Map);
        final record = records[document['entity_id']];
        if (record == null) throw const CloudSyncFailure('服务器附件确认不匹配');
        final merged = MediaAsset.fromJson(
          Map<String, dynamic>.from(document['payload'] as Map),
        );
        if (!metadataOnly) {
          await media.receive(
            merged,
            now: now(),
            includeRecentOriginal: false,
            download: false,
          );
        }
        await local.db.transaction(() async {
          await _remember(document, null);
          await _acknowledge(document);
        });
      }
    }
  }

  Future<void> _pushDirty() async {
    final pending = await local.rows(
      '''SELECT d.*,m.created_at AS message_time FROM cloud_dirty d LEFT JOIN cloud_versions v
      ON d.kind=v.kind AND d.entity_id=v.entity_id
      LEFT JOIN messages m ON d.kind='messages' AND d.entity_id=m.id
      WHERE v.conflict_id IS NULL''',
    );
    _totalMessages =
        _confirmedMessages +
        pending.where((row) => row['kind'] == 'messages').length;
    pending.sort((a, b) {
      final kind = _order(
        a['kind'] as String,
      ).compareTo(_order(b['kind'] as String));
      return kind != 0
          ? kind
          : ((b['message_time'] as num?) ?? 0).compareTo(
              (a['message_time'] as num?) ?? 0,
            );
    });
    final frozen = <List<Object?>>[];
    var frozenBytes = 0;
    Future<void> flush() async {
      if (frozen.isEmpty) return;
      await local.db.transaction(() async {
        for (final row in frozen) {
          await local.execute(
            'INSERT OR IGNORE INTO cloud_outbox(op_id,kind,entity_id,revision,mutation_json,local_json) VALUES(?,?,?,?,?,?)',
            row,
          );
        }
      });
      frozen.clear();
      frozenBytes = 0;
      await _sendOutbox();
    }

    for (var index = 0; index < pending.length; index++) {
      _checkOpen();
      if ((await local.state())['enabled'] != 1) return;
      final item = pending[index],
          kind = pending[index]['kind'] as String,
          id = pending[index]['entity_id'] as String;
      if (retiredCloudKinds.contains(kind)) {
        await local.execute(
          'DELETE FROM cloud_dirty WHERE kind=? AND entity_id=?',
          [kind, id],
        );
        continue;
      }
      final document = await local.read(kind, id);
      final known = await _version(kind, id);
      if (document == null && known == null) {
        await local.execute(
          'DELETE FROM cloud_dirty WHERE kind=? AND entity_id=? AND revision=?',
          [kind, id, item['revision']],
        );
        continue;
      }
      final wire = document == null ? null : await codec.encode(document);
      final operation = {
        'op_id': const Uuid().v4(),
        'kind': kind,
        'entity_id': id,
        'base_version': known?['version'] ?? 0,
        'action': document == null ? 'delete' : 'put',
        'payload_version': 1,
        'payload': {
          ...?wire?.payload,
          if (_settingTimes &&
              document != null &&
              const {
                'conversations',
                'providers',
                'settings',
              }.contains(kind)) ...{
            'setting_times_version': 1,
            'setting_times': await local.settingTimes(kind, id, media.deviceId),
          },
        },
        'blob_ids': <String>[],
        'media_ids': wire?.mediaIds ?? <String>[],
      };
      final encoded = canonicalJson(operation);
      final bytes = utf8.encode(encoded).length;
      if (frozen.isNotEmpty && frozenBytes + bytes > 8 * 1024 * 1024) {
        await flush();
      }
      frozen.add([
        operation['op_id'],
        kind,
        id,
        item['revision'],
        encoded,
        document?.localJson,
      ]);
      frozenBytes += bytes;
      if (frozen.length == 100) await flush();
      _report(
        CloudProgress(
          '正在上传消息和配置',
          busy: true,
          enabled: true,
          completed: _completed,
          pending: pending.length - index - 1,
        ),
      );
    }
    await flush();
    await _sendOutbox();
  }

  Future<void> _acknowledge(Map<String, dynamic> document) => local.execute(
    'INSERT OR IGNORE INTO cloud_acknowledged(seq) VALUES(?)',
    [document['seq']],
  );

  /// Only a contiguous prefix can advance the cursor. A gap may contain another
  /// device's edit, so receipts beyond that gap never hide unread remote data.
  Future<int> _consumeAcknowledgements(
    int cursor,
  ) => local.db.transaction(() async {
    var through = cursor;
    while (true) {
      final rows = await local.rows(
        'SELECT seq FROM cloud_acknowledged WHERE seq>? ORDER BY seq LIMIT 1024',
        [through],
      );
      var gap = false;
      for (final row in rows) {
        if (row['seq'] != through + 1) {
          gap = true;
          break;
        }
        through++;
      }
      if (gap || rows.length < 1024) break;
    }
    if (through > cursor) {
      await local.execute('UPDATE cloud_client_state SET cursor=? WHERE id=1', [
        through,
      ]);
    }
    await local.execute('DELETE FROM cloud_acknowledged WHERE seq<=?', [
      through,
    ]);
    return through;
  });

  Future<void> _queueMedia(String id, {int priority = 1}) => local.execute(
    'INSERT INTO cloud_media_queue(id,priority) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET revision=revision+1,priority=MIN(priority,excluded.priority),retry_after=0',
    [id, priority],
  );

  void _startMediaTransfer() {
    if (_mediaWork != null || _closed) return;
    final completer = Completer<void>();
    _mediaWork = completer.future;
    unawaited(() async {
      try {
        await _transferMedia();
      } catch (_) {
        /* The durable queue is retried by the next synchronization. */
      } finally {
        try {
          if (!_closed && !_running && (await local.state())['enabled'] == 1) {
            final pending =
                (await local.rows(
                      'SELECT count(*) n FROM cloud_media_queue',
                    )).single['n']
                    as int;
            final dirty =
                (await local.rows(
                      'SELECT count(*) n FROM cloud_dirty',
                    )).single['n']
                    as int;
            final conflicts =
                (await local.rows(
                      'SELECT count(*) n FROM cloud_versions WHERE conflict_id IS NOT NULL',
                    )).single['n']
                    as int;
            if (dirty == 0 && conflicts == 0) {
              _report(
                CloudProgress(
                  pending == 0 ? '同步完成' : '记录已同步，部分附件稍后重试',
                  enabled: true,
                  pending: pending,
                ),
              );
            }
          }
        } finally {
          _mediaWork = null;
          completer.complete();
        }
      }
    }());
  }

  Future<void> _transferMedia() async {
    Future<void> worker() async {
      while (!_closed && (await local.state())['enabled'] == 1) {
        final pending = await local.db.transaction(() async {
          final rows = await local.rows(
            'SELECT * FROM cloud_media_queue WHERE retry_after<=? ORDER BY priority,id LIMIT 32',
            [now().millisecondsSinceEpoch],
          );
          for (final item in rows) {
            await local.execute(
              'UPDATE cloud_media_queue SET retry_after=? WHERE id=?',
              [
                now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
                item['id'],
              ],
            );
          }
          return rows;
        });
        if (pending.isEmpty) return;
        try {
          final originals = <String>[], thumbnails = <String>[];
          for (final item in pending) {
            final id = item['id'] as String;
            final record = await media.load(id);
            if (record == null) continue;
            final hasLocal =
                record.originalPath != null &&
                await File(record.originalPath!).exists();
            if (hasLocal && record.asset.shouldTransferOriginal(now())) {
              originals.add(id);
            } else if (record.thumbnailPath != null) {
              thumbnails.add(id);
            }
          }
          await _publishMediaBatch(originals, original: true);
          await _publishMediaBatch(thumbnails);
          var next = 0;
          await Future.wait(
            List.generate(3, (_) async {
              while (next < pending.length) {
                final item = pending[next++];
                _checkOpen();
                final id = item['id'] as String;
                final record = await media.load(id);
                if (record == null) throw const CloudSyncFailure('附件身份尚未入库');
                await media.receive(record.asset, now: now());
                await local.execute(
                  'DELETE FROM cloud_media_queue WHERE id=? AND revision=?',
                  [id, item['revision']],
                );
              }
            }),
          );
          onApplied?.call({'media_assets', 'settings'});
        } catch (_) {
          for (final item in pending) {
            await local.execute(
              'UPDATE cloud_media_queue SET retry_after=? WHERE id=? AND revision=?',
              [
                now().add(const Duration(seconds: 30)).millisecondsSinceEpoch,
                item['id'],
                item['revision'],
              ],
            );
          }
        }
      }
    }

    await worker();
  }
}
