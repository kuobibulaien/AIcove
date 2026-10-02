import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../../core/media/media_asset.dart';
import '../../../core/media/media_store.dart';
import '../domain/lan_contract.dart';
import 'cloud_local_store.dart';
import 'lan_transport.dart';

const lanChunkSize = 512 * 1024;
const lanFileLimit = 128 * 1024 * 1024;
typedef LanMediaRpc =
    Future<Map<String, dynamic>> Function(
      LanPeer peer,
      Map<String, dynamic> body,
    );

class LanMedia {
  LanMedia(this.local, this.media, this.rpc);
  final CloudLocalStore local;
  final MediaStore media;
  final LanMediaRpc rpc;
  final _verified = <String, (int, int, String)>{};
  String _after = '';

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

  Future<void> prepare(LanPeer peer, List<String> ids) async {
    for (final id in ids) {
      final response = await rpc(peer, {'method': 'media', 'id': id});
      final asset = validate(
        Map<String, dynamic>.from(response['asset'] as Map),
        id,
      );
      await media.receive(asset, now: DateTime.now(), download: false);
      await local.execute(
        '''INSERT INTO lan_media_queue(media_id,peer_id,asset_json) VALUES(?,?,?)
        ON CONFLICT(media_id) DO UPDATE SET peer_id=excluded.peer_id,asset_json=excluded.asset_json''',
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

  Future<void> drain(Map<String, LanPeer> peers, bool Function() active) async {
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
    for (final row in queue) {
      if (!active()) return;
      final id = row['media_id'] as String;
      _after = id;
      final peer = peers[row['peer_id']];
      if (peer == null || !peer.approved || !peer.online) continue;
      try {
        // Recheck availability: an original may arrive on the source later.
        final response = await rpc(peer, {'method': 'media', 'id': id});
        final asset = validate(
          Map<String, dynamic>.from(response['asset'] as Map),
          id,
        );
        final previous = await media.load(id);
        final root = Directory(p.join(media.root.path, 'assets', id));
        String? original = previous?.originalPath,
            thumbnail = previous?.thumbnailPath;
        if (asset.thumbnailBlob != null) {
          final target = File(p.join(root.path, 'thumbnail.jpg'));
          await _download(peer, asset, asset.thumbnailBlob!, target, active);
          thumbnail = target.path;
        }
        if (asset.originalBlob != null) {
          final target = File(await media.originalDestination(id));
          await _download(peer, asset, asset.originalBlob!, target, active);
          original = target.path;
        }
        await media.saveReceived(
          LocalMedia(asset, originalPath: original, thumbnailPath: thumbnail),
        );
        if (asset.originalBlob == null && original == null) {
          await local.execute(
            'UPDATE lan_media_queue SET asset_json=? WHERE media_id=?',
            [
              jsonEncode({...asset.toJson(), 'unavailable': true}),
              id,
            ],
          );
        } else {
          await local.execute(
            'DELETE FROM lan_media_queue WHERE media_id=? AND peer_id=?',
            [id, peer.id],
          );
        }
      } on IOException {
        /* Retry persisted partial files next round. */
      } on LanSyncFailure {
        /* Preserve the queue and the surrounding history. */
      }
    }
  }

  Future<(int, int)> counts() async {
    final rows = await local.rows('SELECT asset_json FROM lan_media_queue');
    final unavailable = rows
        .where(
          (row) =>
              (jsonDecode(row['asset_json'] as String) as Map)['unavailable'] ==
              true,
        )
        .length;
    return (rows.length - unavailable, unavailable);
  }
}
