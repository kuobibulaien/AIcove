import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../../core/media/media_asset.dart';
import '../../../core/media/media_store.dart';
import '../../chat/services/chat_message_projection_codec.dart';
import '../domain/lan_contract.dart';
import 'cloud_local_store.dart';
import 'cloud_media_codec.dart';
import 'lan_transport.dart';

const lanChunkSize = 512 * 1024;
const lanFileLimit = 128 * 1024 * 1024;
typedef LanMediaRpc =
    Future<Map<String, dynamic>> Function(
      LanPeer peer,
      Map<String, dynamic> body,
    );

typedef LanPreparedMedia = ({MediaAsset asset, Map<String, dynamic>? queued});

class LanMedia {
  LanMedia(this.local, this.media, this.rpc);
  final CloudLocalStore local;
  final MediaStore media;
  final LanMediaRpc rpc;
  final _verified = <String, (int, int, String)>{};
  String _after = '';

  static bool _pathTombstone(MediaAsset asset) =>
      asset.originalSha256 == null &&
      asset.originalBlob == null &&
      asset.thumbnailBlob == null;

  Future<bool> _hasOriginal(String id, MediaAsset asset) async {
    final record = await media.load(id);
    final digest = asset.originalSha256 ?? record?.asset.originalSha256;
    return record != null &&
        digest != null &&
        await _source(record, digest) != null;
  }

  Future<void> _remove(Map<String, dynamic> row) => local.execute(
    'DELETE FROM lan_media_queue WHERE media_id=? AND peer_id=? AND asset_json=?',
    [row['media_id'], row['peer_id'], row['asset_json']],
  );

  /// Only current business references own download work. Historical revisions
  /// still retain their media identities and remain decodable.
  Future<Set<String>> _activeReferences(Iterable<String> candidates) async {
    final ids = <String>{};
    final paths = <String>{};
    void visit(Object? node, [String key = '']) {
      if (const {
        'text',
        'content',
        'prompt',
        'negativePrompt',
        'promptText',
        'arguments',
      }.contains(key))
        return;
      if (node is Map) {
        for (final entry in node.entries) {
          visit(entry.value, entry.key.toString());
        }
      } else if (node is List) {
        for (final value in node) {
          visit(value);
        }
      } else if (node is String) {
        if (node.startsWith('{') || node.startsWith('[')) {
          try {
            visit(jsonDecode(node));
          } on FormatException {
            /* Ordinary string setting. */
          }
        } else {
          final id = mediaIdFromReference(node);
          if (id != null) ids.add(id);
          final path = node.startsWith('file://') ? node.substring(7) : node;
          if (p.isAbsolute(path)) paths.add(path);
          final localId = RegExp(
            r'/assets/([0-9a-f]{64})/original\.[a-z0-9]+$',
          ).firstMatch(path);
          if (localId != null && path.startsWith('${media.root.path}/'))
            ids.add(localId[1]!);
        }
      }
    }

    final blocks = <String, List<Map<String, dynamic>>>{};
    for (final b in await local.rows(
      '''SELECT b.* FROM message_blocks b JOIN messages m ON m.id=b.message_id
      WHERE m.deleted_at IS NULL AND m.replaced_by IS NULL AND b.deleted_at IS NULL''',
    )) {
      (blocks[b['message_id'] as String] ??= []).add(b);
    }
    for (final row in await local.rows(
      'SELECT * FROM messages WHERE deleted_at IS NULL AND replaced_by IS NULL',
    )) {
      final document = CloudMediaCodec.normalizeMessagePayload('messages', {
        'row': row,
        'message_blocks': blocks[row['id']] ?? [],
      });
      final current = Map<String, dynamic>.from(document['row'] as Map);
      final raw = current['raw_payload'];
      if (current['role'] == 'assistant' && raw is String) {
        try {
          final payload = jsonDecode(raw);
          if (payload is Map &&
              ChatMessageProjectionCodec.hasProjectionSemantics(
                Map<String, dynamic>.from(payload),
              )) {
            // Retained snapshots are aliases, not extra current file owners.
            current['raw_payload'] = jsonEncode(
              ChatMessageProjectionCodec.removeProjectedMessages(
                Map<String, dynamic>.from(payload),
              ),
            );
          }
        } on FormatException {
          // Legacy malformed payloads still have independently stored blocks.
        }
      }
      visit({...document, 'row': current});
    }
    for (final table in ['conversations', 'providers']) {
      for (final row in await local.rows('SELECT * FROM $table')) {
        visit(row);
      }
    }
    for (final document in await local.external()) {
      visit(document.payload);
    }
    // Audio decode preserves an existing originalDestination, including a
    // missing picker/cache path outside this store's managed assets directory.
    for (final id in candidates) {
      final record = await media.load(id);
      if (paths.contains(record?.originalPath)) ids.add(id);
    }
    return ids;
  }

  /// Called at startup and once per transfer round, never by idle UI counts.
  Future<int> reconcileQueue({Set<String>? ids}) async {
    final queue = await local.rows('SELECT * FROM lan_media_queue');
    final candidates = <Map<String, dynamic>>[];
    var removed = 0;
    for (final row in queue) {
      final id = row['media_id'] as String;
      if (ids != null && !ids.contains(id)) continue;
      final asset = MediaAsset.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(row['asset_json'] as String) as Map,
        ),
      );
      if (_pathTombstone(asset) || await _hasOriginal(id, asset)) {
        await _remove(row);
        removed++;
      } else {
        candidates.add(row);
      }
    }
    if (candidates.isNotEmpty) {
      await local.db.transaction(() async {
        final references = await _activeReferences(
          candidates.map((row) => row['media_id'] as String),
        );
        for (final row in candidates) {
          if (!references.contains(row['media_id'])) {
            await _remove(row);
            removed++;
          }
        }
      });
    }
    return removed;
  }

  Future<File?> _source(LocalMedia record, String digest) async {
    final path =
        digest == record.asset.originalSha256 ||
            digest == record.asset.originalBlob
        ? record.originalPath
        : digest == record.asset.thumbnailBlob
        ? record.thumbnailPath
        : null;
    if (path == null) return null;
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size > lanFileLimit) {
      return null;
    }
    final cached = _verified[path];
    if (cached == null ||
        cached.$1 != stat.size ||
        cached.$2 != stat.modified.microsecondsSinceEpoch) {
      _verified[path] = (
        stat.size,
        stat.modified.microsecondsSinceEpoch,
        (await sha256.bind(file.openRead()).first).toString(),
      );
    }
    return _verified[path]!.$3 == digest ? file : null;
  }

  Future<Map<String, dynamic>> metadata(String id) async {
    if (!validMediaId(id)) throw const LanSyncFailure('附件编号无效');
    final record = await media.load(id);
    if (record == null) throw const LanSyncFailure('附件资料暂不可用');
    final original = record.asset.originalSha256;
    final thumbnail = record.asset.thumbnailBlob;
    return {
      ...record.asset.toJson(),
      'locations': <Object>[],
      'original_blob':
          original != null && await _source(record, original) != null
          ? original
          : null,
      'thumbnail_blob':
          thumbnail != null && await _source(record, thumbnail) != null
          ? thumbnail
          : null,
    };
  }

  static MediaAsset validate(Map<String, dynamic> json, String id) {
    final asset = MediaAsset.fromJson(json);
    if (asset.id != id ||
        asset.byteLength < 0 ||
        asset.byteLength > lanFileLimit ||
        asset.mimeType.length > 150 ||
        asset.locations.isNotEmpty ||
        asset.blobIds.any((digest) => !validMediaId(digest)) ||
        (asset.originalSha256 != null && !validMediaId(asset.originalSha256)) ||
        (asset.originalBlob != null &&
            asset.originalBlob != asset.originalSha256)) {
      throw const LanSyncFailure('附件资料无效或超过 128 MB');
    }
    return asset;
  }

  Future<Map<String, dynamic>> chunk(
    String id,
    String digest,
    int offset,
  ) async {
    if (!validMediaId(id) ||
        !validMediaId(digest) ||
        offset < 0 ||
        offset > lanFileLimit) {
      throw const LanSyncFailure('附件分块请求无效');
    }
    final record = await media.load(id);
    final file = record == null ? null : await _source(record, digest);
    if (file == null) throw const LanSyncFailure('附件原文件暂不可用');
    final length = await file.length();
    if (offset > length) throw const LanSyncFailure('附件偏移无效');
    final handle = await file.open();
    try {
      await handle.setPosition(offset);
      return {
        'offset': offset,
        'length': length,
        'bytes': base64Encode(await handle.read(lanChunkSize)),
      };
    } finally {
      await handle.close();
    }
  }

  Future<void> prepare(
    LanPeer peer,
    List<String> ids, {
    bool download = true,
  }) async {
    final prepared = await prepareIdentities(peer, ids);
    if (download) await enqueuePrepared(peer, prepared);
  }

  /// Decode dependencies arrive first; callers commit business references before
  /// enqueueing file work. The queue snapshot protects against delayed old RPCs.
  Future<List<LanPreparedMedia>> prepareIdentities(
    LanPeer peer,
    List<String> ids,
  ) async {
    final prepared = <LanPreparedMedia>[];
    for (final id in ids) {
      final before = await local.rows(
        'SELECT * FROM lan_media_queue WHERE media_id=?',
        [id],
      );
      final response = await rpc(peer, {'method': 'media', 'id': id});
      final asset = validate(
        Map<String, dynamic>.from(response['asset'] as Map),
        id,
      );
      await media.receive(asset, now: DateTime.now(), download: false);
      prepared.add((asset: asset, queued: before.firstOrNull));
    }
    return prepared;
  }

  Future<void> enqueuePrepared(
    LanPeer peer,
    List<LanPreparedMedia> prepared,
  ) async {
    for (final item in prepared) {
      final asset = item.asset;
      final id = asset.id;
      final before = item.queued;
      if (_pathTombstone(asset) || await _hasOriginal(id, asset)) {
        // The row can have changed sources while the metadata RPC was running.
        // Only the source represented by this response may be consumed here.
        if (before != null) await _remove(before);
        continue;
      }
      if (before != null) {
        await local.execute(
          'UPDATE lan_media_queue SET peer_id=?,asset_json=? WHERE media_id=? AND peer_id=? AND asset_json=?',
          [
            peer.id,
            jsonEncode(asset.toJson()),
            id,
            before['peer_id'],
            before['asset_json'],
          ],
        );
      }
      await local.execute(
        'INSERT OR IGNORE INTO lan_media_queue(media_id,peer_id,asset_json) VALUES(?,?,?)',
        [id, peer.id, jsonEncode(asset.toJson())],
      );
    }
  }

  Future<void> _download(
    LanPeer peer,
    MediaAsset asset,
    String digest,
    File target,
    bool Function() active,
    Future<void> Function(double)? onProgress,
  ) async {
    if (await target.exists() &&
        (await sha256.bind(target.openRead()).first).toString() == digest) {
      return;
    }
    await target.parent.create(recursive: true);
    final staging = File('${target.path}.$digest.lan-part');
    var offset = await staging.exists() ? await staging.length() : 0;
    if (offset > lanFileLimit) throw const LanSyncFailure('附件暂存文件过大');
    while (active()) {
      final reply = await rpc(peer, {
        'method': 'chunk',
        'id': asset.id,
        'digest': digest,
        'offset': offset,
      });
      final length = reply['length'] as int;
      final bytes = base64Decode(reply['bytes'] as String);
      if (reply['offset'] != offset ||
          length < offset ||
          length > lanFileLimit ||
          bytes.length > lanChunkSize ||
          offset + bytes.length > length ||
          (bytes.isEmpty && offset < length)) {
        throw const LanSyncFailure('附件分块校验失败');
      }
      if (!active()) throw const LanSyncFailure('附件传输已暂停');
      if (bytes.isNotEmpty) {
        final handle = await staging.open(mode: FileMode.append);
        try {
          await handle.writeFrom(bytes);
          await handle.flush();
        } finally {
          await handle.close();
        }
      } else if (!await staging.exists()) {
        await staging.writeAsBytes([], flush: true);
      }
      offset += bytes.length;
      await onProgress?.call(length == 0 ? 1 : offset / length);
      if (offset == length) {
        if ((await sha256.bind(staging.openRead()).first).toString() !=
            digest) {
          // This is our partial transfer only; the existing original is intact.
          await staging.writeAsBytes([], flush: true);
          throw const LanSyncFailure('附件完整校验失败，保留已有原文件并等待重传');
        }
        if (digest == asset.originalBlob && length != asset.byteLength) {
          throw const LanSyncFailure('附件大小与资料不一致');
        }
        await staging.rename(target.path);
        return;
      }
    }
    throw const LanSyncFailure('附件传输已暂停');
  }

  Future<void> drain(
    Map<String, LanPeer> peers,
    bool Function() active, {
    int completedOffset = 0,
    int? totalFiles,
    Future<void> Function(double? progress, String label)? onProgress,
  }) async {
    var queue = await local.rows(
      'SELECT * FROM lan_media_queue WHERE media_id>? ORDER BY media_id LIMIT 8',
      [_after],
    );
    if (queue.isEmpty && _after.isNotEmpty) {
      _after = '';
      queue = await local.rows(
        'SELECT * FROM lan_media_queue ORDER BY media_id LIMIT 8',
      );
    }
    if (queue.isEmpty) return;
    final initialTotal = totalFiles ?? (await counts()).$1;
    final safeTotal = math.max(
      1,
      math.max(initialTotal, completedOffset + queue.length),
    );
    for (var index = 0; index < queue.length; index++) {
      final row = queue[index];
      if (!active()) return;
      final id = row['media_id'] as String;
      _after = id;
      final queued = MediaAsset.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(row['asset_json'] as String) as Map,
        ),
      );
      if (_pathTombstone(queued) || await _hasOriginal(id, queued)) {
        await _remove(row);
        continue;
      }
      final peer = peers[row['peer_id']];
      if (peer == null || !peer.approved || !peer.online) continue;
      final doneFiles = completedOffset + index;
      try {
        await onProgress?.call(
          (doneFiles / safeTotal).clamp(0.0, 1.0),
          '正在接收附件（${doneFiles + 1} / $safeTotal）',
        );
        // Recheck availability: an original may arrive on the source later.
        final response = await rpc(peer, {'method': 'media', 'id': id});
        final asset = validate(
          Map<String, dynamic>.from(response['asset'] as Map),
          id,
        );
        if (_pathTombstone(asset)) {
          await media.receive(asset, now: DateTime.now(), download: false);
          await _remove(row);
          continue;
        }
        final previous = await media.load(id);
        final root = Directory(p.join(media.root.path, 'assets', id));
        String? original = await _hasOriginal(id, asset)
                ? previous?.originalPath
                : null,
            thumbnail = previous?.thumbnailPath;
        final hasThumb = asset.thumbnailBlob != null;
        final hasOriginal = asset.originalBlob != null;
        if (hasThumb) {
          final target = File(p.join(root.path, 'thumbnail.jpg'));
          await _download(
            peer,
            asset,
            asset.thumbnailBlob!,
            target,
            active,
            (progress) async => onProgress?.call(
              ((doneFiles + (hasOriginal ? 0.1 * progress : progress)) /
                      safeTotal)
                  .clamp(0.0, 1.0),
              '正在接收附件（${doneFiles + 1} / $safeTotal）',
            ),
          );

          thumbnail = target.path;
        }
        if (hasOriginal) {
          final target = File(await media.originalDestination(id));
          await _download(
            peer,
            asset,
            asset.originalBlob!,
            target,
            active,
            (progress) async => onProgress?.call(
              ((doneFiles + (hasThumb ? 0.1 + 0.9 * progress : progress)) /
                      safeTotal)
                  .clamp(0.0, 1.0),
              '正在接收附件（${doneFiles + 1} / $safeTotal）',
            ),
          );

          original = target.path;
        }
        await media.saveReceived(
          LocalMedia(asset, originalPath: original, thumbnailPath: thumbnail),
        );
        if (asset.originalBlob == null && original == null) {
          await local.execute(
            'UPDATE lan_media_queue SET asset_json=? WHERE media_id=? AND peer_id=? AND asset_json=?',
            [
              jsonEncode({...asset.toJson(), 'unavailable': true}),
              id,
              row['peer_id'],
              row['asset_json'],
            ],
          );
        } else {
          await _remove(row);
        }
      } on IOException {
        /* Retry persisted partial files next round. */
      } on LanSyncFailure {
        /* Preserve the queue and the surrounding history. */
      } finally {
        await onProgress?.call(
          ((doneFiles + 1) / safeTotal).clamp(0.0, 1.0),
          '正在接收附件（${doneFiles + 1} / $safeTotal）',
        );
      }
    }
  }

  Future<(int, int)> counts() async {
    final row = (await local.rows('''
      SELECT COUNT(*) AS total,
        COALESCE(SUM(CASE
          WHEN json_type(asset_json,'\$.unavailable')='true' THEN 1 ELSE 0
        END),0) AS unavailable,
        COALESCE(SUM(CASE
          WHEN json_type(asset_json)='object' THEN 0 ELSE 1
        END),0) AS invalid
      FROM lan_media_queue
    ''')).single;
    if (row['invalid'] != 0) {
      throw const FormatException(
        'LAN media queue entries must be JSON objects',
      );
    }
    final total = row['total'] as int;
    final unavailable = row['unavailable'] as int;
    return (total - unavailable, unavailable);
  }
}
