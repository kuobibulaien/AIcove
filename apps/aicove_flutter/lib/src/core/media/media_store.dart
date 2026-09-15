import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_asset.dart';
import 'media_index.dart';

typedef DownloadMediaBlob = Future<void> Function(String digest, File target);

class LocalMedia {
  const LocalMedia(this.asset, {this.originalPath, this.thumbnailPath});
  final MediaAsset asset;
  final String? originalPath;
  final String? thumbnailPath;
  Map<String, dynamic> toJson() => {
    'asset': asset.toJson(),
    'original_path': originalPath,
    'thumbnail_path': thumbnailPath,
  };
  factory LocalMedia.fromJson(Map<String, dynamic> json) => LocalMedia(
    MediaAsset.fromJson(Map<String, dynamic>.from(json['asset'] as Map)),
    originalPath: json['original_path'] as String?,
    thumbnailPath: json['thumbnail_path'] as String?,
  );
}

/// Originals stay in their existing location. This store never expires them.
class MediaStore {
  MediaStore(this.root, this.deviceId);
  final Directory root;
  final String deviceId;
  final _arrivals = StreamController<String>.broadcast();
  Stream<String> get arrivals => _arrivals.stream;
  DownloadMediaBlob? downloadBlob;
  final Map<String, Future<LocalMedia>> _registrations = {};
  static Future<MediaStore>? _default;
  Future<MediaIndex>? _indexFuture;
  Future<MediaIndex> get _index => _indexFuture ??= () async {
    await root.create(recursive: true);
    final index = MediaIndex(root);
    await index.importLegacy(root);
    return index;
  }();

  Future<void> close() async {
    await _arrivals.close();
    final index = _indexFuture;
    _indexFuture = null;
    if (index != null) await (await index).close();
  }

  static Future<String>? _deviceIdentity;
  static Future<String> get localDeviceId => _deviceIdentity ??= () async {
    final preferences = await SharedPreferences.getInstance();
    var device = preferences.getString('aicove.cloud.device_id');
    if (device == null) {
      device = const Uuid().v4();
      if (!await preferences.setString('aicove.cloud.device_id', device)) {
        throw const FileSystemException('设备标识保存失败，媒体尚未修改');
      }
    }
    return device;
  }();

  static Future<MediaStore> get shared => _default ??= () async {
    final support = await getApplicationSupportDirectory();
    return MediaStore(
      Directory(p.join(support.path, 'cloud_media')),
      await localDeviceId,
    );
  }();

  static void use(MediaStore store) => _default = Future.value(store);

  File _record(String id) {
    if (!validMediaId(id)) throw const FormatException('无效的图片 ID');
    return File(p.join(root.path, 'assets', id, 'record.json'));
  }

  String _sourceKey(String source) =>
      sha256.convert(utf8.encode(source)).toString();

  Future<LocalMedia?> load(String id) async {
    if (!validMediaId(id)) throw const FormatException('无效的图片 ID');
    final json = await (await _index).read('assets', id);
    return json == null ? null : LocalMedia.fromJson(json);
  }

  Future<void> save(LocalMedia record) async {
    final sources = <String, Map<String, dynamic>>{};
    for (final path in [record.originalPath, record.thumbnailPath]) {
      if (path == null) continue;
      final stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.file) {
        sources[_sourceKey(path)] = {
          'id': record.asset.id,
          'size': stat.size,
          'modified': stat.modified.millisecondsSinceEpoch,
        };
      }
    }
    final index = await _index;
    await index.transaction(() async {
      final previousJson = await index.read('assets', record.asset.id);
      final previous = previousJson == null
          ? null
          : LocalMedia.fromJson(previousJson);
      final last = record.asset.lastChatAtMs ?? record.asset.createdAtMs;
      final previousLast =
          previous?.asset.lastChatAtMs ?? previous?.asset.createdAtMs ?? 0;
      final locations = <String, Map<String, String>>{
        for (final location in [
          ...?previous?.asset.locations,
          ...record.asset.locations,
        ])
          '${location['device_id']}\u0000${location['path']}': location,
      };
      if (record.originalPath != null && record.asset.originalSha256 != null) {
        locations['$deviceId\u0000${record.originalPath}'] = {
          'device_id': deviceId,
          'path': record.originalPath!,
        };
      }
      final json = record.toJson();
      json['original_path'] = record.originalPath ?? previous?.originalPath;
      if (record.thumbnailPath == null &&
          previous?.asset.thumbnailBlob == record.asset.thumbnailBlob) {
        json['thumbnail_path'] = previous?.thumbnailPath;
      }
      json['asset'] = {
        ...record.asset.toJson(),
        'original_required':
            record.asset.originalRequired ||
            (previous?.asset.originalRequired ?? false),
        'last_chat_at_ms': last > previousLast ? last : previousLast,
        'original_blob':
            record.asset.originalBlob ?? previous?.asset.originalBlob,
        'locations': locations.values.toList(),
      };
      await index.put('assets', record.asset.id, json);
      for (final source in sources.entries) {
        await index.put('sources', source.key, source.value);
      }
    });
  }

  Stream<LocalMedia> records() async* {
    await for (final json in (await _index).records()) {
      yield LocalMedia.fromJson(json);
    }
  }

  Future<LocalMedia> unavailable(
    String source, {
    required int createdAtMs,
    String mimeType = 'image/unknown',
  }) async {
    final id = sha256.convert(utf8.encode('$deviceId:$source')).toString();
    final existing = await load(id);
    if (existing != null) return existing;
    final record = LocalMedia(
      MediaAsset(
        id: id,
        mimeType: mimeType,
        byteLength: 0,
        createdAtMs: createdAtMs,
        locations: [
          {'device_id': deviceId, 'path': source},
        ],
      ),
    );
    await save(record);
    return record;
  }

  Future<LocalMedia> register(
    String source, {
    required int createdAtMs,
    String? mimeType,
    bool inlineImage = false,
    bool originalRequired = false,
  }) {
    final managed = mediaIdFromReference(source);
    if (managed != null) {
      return noteUsage(
        managed,
        createdAtMs: createdAtMs,
        originalRequired: originalRequired,
      );
    }
    return _registrations
        .putIfAbsent(source, () async {
          try {
            return await _register(
              source,
              createdAtMs,
              mimeType,
              inlineImage,
              originalRequired,
            );
          } finally {
            _registrations.remove(source);
          }
        })
        .then(
          (record) => noteUsage(
            record.asset.id,
            createdAtMs: createdAtMs,
            originalRequired: originalRequired,
          ),
        );
  }

  Future<LocalMedia> noteUsage(
    String id, {
    required int createdAtMs,
    required bool originalRequired,
  }) async {
    final record = await load(id);
    if (record == null) throw const FormatException('缺少图片身份信息');
    return _withUsage(record, createdAtMs, originalRequired);
  }

  Future<LocalMedia> _withUsage(
    LocalMedia record,
    int timestamp,
    bool originalRequired,
  ) async {
    final date = record.asset.createdAtMs == 0 && timestamp > 0
        ? timestamp
        : record.asset.createdAtMs;
    final last = record.asset.lastChatAtMs ?? record.asset.createdAtMs;
    final nextLast = originalRequired
        ? last
        : (timestamp > last ? timestamp : last);
    final required = record.asset.originalRequired || originalRequired;
    if (date == record.asset.createdAtMs &&
        nextLast == last &&
        required == record.asset.originalRequired) {
      return record;
    }
    final updated = LocalMedia(
      MediaAsset.fromJson({
        ...record.asset.toJson(),
        'created_at_ms': date,
        'last_chat_at_ms': nextLast,
        'original_required': required,
      }),
      originalPath: record.originalPath,
      thumbnailPath: record.thumbnailPath,
    );
    await save(updated);
    return updated;
  }

  Future<LocalMedia> _register(
    String source,
    int createdAtMs,
    String? mimeType,
    bool inlineImage,
    bool originalRequired,
  ) async {
    final uri = Uri.tryParse(source);
    File file;
    if (source.startsWith('data:') || inlineImage) {
      final data = source.startsWith('data:') ? UriData.parse(source) : null;
      final bytes = data?.contentAsBytes() ?? base64Decode(source);
      mimeType ??= lookupMimeType('', headerBytes: bytes) ?? data?.mimeType;
      final digest = sha256.convert(bytes).toString();
      final existing = await load(digest);
      final canonical = File(
        p.join(
          root.path,
          'inline',
          '$digest.${mediaFileExtension(mimeType ?? 'application/octet-stream')}',
        ),
      );
      final legacy = File(p.join(root.path, 'inline', digest));
      if (existing?.originalPath != null &&
          await File(existing!.originalPath!).exists() &&
          (await sha256.bind(File(existing.originalPath!).openRead()).first)
                  .toString() ==
              digest) {
        if (existing.originalPath == legacy.path && !await canonical.exists()) {
          await legacy.rename(canonical.path);
          final moved = LocalMedia(
            existing.asset,
            originalPath: canonical.path,
            thumbnailPath: existing.thumbnailPath,
          );
          await save(moved);
          return _withUsage(moved, createdAtMs, originalRequired);
        }
        return _withUsage(existing, createdAtMs, originalRequired);
      }
      file = canonical;
      if (!await file.exists() &&
          await legacy.exists() &&
          (await sha256.bind(legacy.openRead()).first).toString() == digest) {
        await legacy.rename(file.path);
      }
      if (!await file.exists()) await _atomicBytes(file, bytes);
    } else if (uri?.scheme == 'http' || uri?.scheme == 'https') {
      final previous = await (await _index).read('sources', _sourceKey(source));
      if (previous != null) {
        final known = await load(previous['id'] as String);
        if (known != null &&
            known.originalPath != null &&
            await File(known.originalPath!).exists()) {
          return _withUsage(known, createdAtMs, originalRequired);
        }
      }
      file = File(
        p.join(
          root.path,
          'remote',
          sha256.convert(utf8.encode(source)).toString(),
        ),
      );
      if (!await file.exists()) await _downloadSource(uri!, file);
    } else {
      file = File(uri?.scheme == 'file' ? uri!.toFilePath() : source);
    }
    if (!await file.exists()) {
      final alias = await (await _index).read('sources', _sourceKey(source));
      final known = alias == null ? null : await load(alias['id'] as String);
      if (known != null && alias?['pending'] == true) {
        return _withUsage(known, createdAtMs, originalRequired);
      }
      if (known?.originalPath != null &&
          await File(known!.originalPath!).exists()) {
        return _withUsage(known, createdAtMs, originalRequired);
      }
      throw const FileSystemException('附件原文件不存在，已保留本地记录');
    }
    final stat = await file.stat();
    final sourceKey = _sourceKey(source);
    final cached = await (await _index).read('sources', sourceKey);
    if (cached != null) {
      if (cached['size'] == stat.size &&
          cached['modified'] == stat.modified.millisecondsSinceEpoch) {
        final previous = await load(cached['id'] as String);
        if (previous != null) {
          return _withUsage(previous, createdAtMs, originalRequired);
        }
      }
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final existing = await load(digest);
    final header = await file.open();
    final bytes = await header.read(32);
    await header.close();
    mimeType ??=
        lookupMimeType(source, headerBytes: bytes) ??
        'application/octet-stream';
    String? thumbnail = existing?.thumbnailPath;
    String? thumbnailDigest = existing?.asset.thumbnailBlob;
    int? width = existing?.asset.width, height = existing?.asset.height;
    if (mimeType.startsWith('image/') &&
        (thumbnail == null || !await File(thumbnail).exists())) {
      try {
        final decoded = await _createThumbnail(file.path);
        width = decoded.$2;
        height = decoded.$3;
        final thumb = File(
          p.join(_record(digest).parent.path, 'thumbnail.jpg'),
        );
        await _atomicBytes(thumb, decoded.$1);
        thumbnail = thumb.path;
        thumbnailDigest = sha256.convert(decoded.$1).toString();
      } on FormatException {
        // An unsupported image codec must not block the surrounding history.
        // Its original remains intact and the receiving UI shows availability.
      }
    }
    final locations = <Map<String, String>>[...?existing?.asset.locations];
    if (!locations.any(
      (e) => e['device_id'] == deviceId && e['path'] == file.path,
    )) {
      locations.add({'device_id': deviceId, 'path': file.path});
    }
    final asset = MediaAsset(
      id: digest,
      mimeType: mimeType,
      byteLength: stat.size,
      createdAtMs: existing != null && existing.asset.createdAtMs != 0
          ? existing.asset.createdAtMs
          : createdAtMs,
      originalRequired:
          originalRequired || (existing?.asset.originalRequired ?? false),
      lastChatAtMs: originalRequired
          ? (existing?.asset.lastChatAtMs ?? 0)
          : ((existing?.asset.lastChatAtMs ?? 0) > createdAtMs
                ? existing!.asset.lastChatAtMs
                : createdAtMs),
      width: width,
      height: height,
      thumbnailBlob: thumbnailDigest,
      originalBlob: existing?.asset.originalBlob,
      originalSha256: digest,
      locations: locations,
    );
    // Picker/temporary files may be reclaimed independently of sync. Keep a
    // private original before publishing their identity. Durable generated
    // images already live in Documents and are not copied a second time.
    if (p
            .split(file.path)
            .any(
              (part) => const {'cache', 'Caches', 'tmp', 'T'}.contains(part),
            ) &&
        !p.isWithin(root.path, file.path)) {
      final protected = File(
        p.join(
          _record(digest).parent.path,
          'original.${mediaFileExtension(mimeType)}',
        ),
      );
      if (!await protected.exists()) {
        await protected.parent.create(recursive: true);
        final temporary = await file.copy(
          '${protected.path}.${const Uuid().v4()}.copy',
        );
        if ((await sha256.bind(temporary.openRead()).first).toString() !=
            digest) {
          throw const FileSystemException('原图备份校验失败，未修改已有文件');
        }
        await temporary.rename(protected.path);
      }
      file = protected;
      locations.add({'device_id': deviceId, 'path': file.path});
    }
    final record = LocalMedia(
      asset,
      originalPath: file.path,
      thumbnailPath: thumbnail,
    );
    await save(record);
    await (await _index).put('sources', sourceKey, {
      'id': digest,
      'size': stat.size,
      'modified': stat.modified.millisecondsSinceEpoch,
    });
    return record;
  }

  Future<LocalMedia> receive(
    MediaAsset asset, {
    required DateTime now,
    bool includeRecentOriginal = true,
    bool download = true,
  }) async {
    final previous = await load(asset.id);
    String? original = previous?.originalPath;
    String? thumbnail = previous?.thumbnailPath;
    if (previous?.asset.thumbnailBlob != asset.thumbnailBlob) thumbnail = null;
    if (download && asset.thumbnailBlob != null) {
      final target = File(
        p.join(_record(asset.id).parent.path, 'thumbnail.jpg'),
      );
      if (thumbnail == null ||
          !await target.exists() ||
          previous?.asset.thumbnailBlob != asset.thumbnailBlob) {
        await _fetch(asset.thumbnailBlob!, target);
      }
      thumbnail = target.path;
    }
    if (download &&
        (includeRecentOriginal || asset.originalRequired || !asset.isImage) &&
        asset.shouldTransferOriginal(now) &&
        asset.originalBlob != null &&
        (original == null || !await File(original).exists())) {
      original = (await _fetchOriginal(asset)).path;
    }
    final record = LocalMedia(
      asset,
      originalPath: original,
      thumbnailPath: thumbnail,
    );
    await save(record);
    if (download && !_arrivals.isClosed) _arrivals.add(asset.id);
    return record;
  }

  /// Stable destination lets business rows commit before their files arrive.
  Future<String> originalDestination(String id) async {
    final record = await load(id);
    if (record == null) throw OriginalMediaUnavailable(id);
    final destination =
        record.originalPath ??
        p.join(
          _record(id).parent.path,
          'original.${mediaFileExtension(record.asset.mimeType)}',
        );
    if (record.originalPath == null) {
      await (await _index).put('sources', _sourceKey(destination), {
        'id': id,
        'pending': true,
      });
    }
    return destination;
  }

  Future<File> original(String id, {bool allowDownload = true}) async {
    final record = await load(id);
    if (record?.originalPath != null &&
        await File(record!.originalPath!).exists()) {
      final file = File(record.originalPath!);
      if (record.asset.originalSha256 == null ||
          (await sha256.bind(file.openRead()).first).toString() ==
              record.asset.originalSha256) {
        return file;
      }
      throw const FileSystemException('原图内容已变化，请重新选择图片后再操作');
    }
    if (allowDownload &&
        record?.asset.originalBlob != null &&
        downloadBlob != null) {
      final file = await _fetchOriginal(record!.asset);
      await save(
        LocalMedia(
          record.asset,
          originalPath: file.path,
          thumbnailPath: record.thumbnailPath,
        ),
      );
      if (!_arrivals.isClosed) _arrivals.add(id);
      return file;
    }
    throw OriginalMediaUnavailable(id);
  }

  Future<File?> display(String id) async {
    final record = await load(id);
    for (final path in [record?.originalPath, record?.thumbnailPath]) {
      if (path != null && await File(path).exists()) return File(path);
    }
    return null;
  }

  Future<File> _fetchOriginal(MediaAsset asset) async {
    final extension = mediaFileExtension(asset.mimeType);
    final target = File(
      p.join(_record(asset.id).parent.path, 'original.$extension'),
    );
    await _fetch(asset.originalBlob!, target);
    return target;
  }

  Future<void> _fetch(String digest, File target) async {
    if (downloadBlob == null) throw const FileSystemException('附件下载服务尚未连接');
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.${const Uuid().v4()}.download');
    await downloadBlob!(digest, temporary);
    if ((await sha256.bind(temporary.openRead()).first).toString() != digest) {
      throw const FormatException('附件校验失败，未替换已有文件');
    }
    await temporary.rename(target.path);
  }
}

Future<void> _atomicBytes(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.${const Uuid().v4()}.writing');
  await temporary.writeAsBytes(bytes, flush: true);
  await temporary.rename(file.path);
}

(Uint8List, int, int) _createThumbnailFallback(String path) {
  final source = img.decodeImage(File(path).readAsBytesSync());
  if (source == null) throw const FormatException('无法读取图片，未替换原文件');
  final thumb = img.copyResize(
    source,
    width: source.width >= source.height
        ? (source.width > 320 ? 320 : source.width)
        : null,
    height: source.height > source.width
        ? (source.height > 320 ? 320 : source.height)
        : null,
  );
  return (img.encodeJpg(thumb, quality: 72), source.width, source.height);
}

Future<void> _downloadSource(Uri uri, File target) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode != 200) throw const FileSystemException('无法读取远程附件');
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.${const Uuid().v4()}.download');
    final sink = temporary.openWrite();
    var size = 0;
    try {
      await for (final chunk in response) {
        size += chunk.length;
        if (size > 128 * 1024 * 1024) {
          throw const FileSystemException('单个附件超过 128 MiB');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    await temporary.rename(target.path);
  } finally {
    client.close(force: true);
  }
}

Future<(Uint8List, int, int)> _createThumbnail(String path) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    // Decode directly at thumbnail size in the engine. Decoding the full
    // original in Dart costs substantial CPU and memory during first sync.
    buffer = await ui.ImmutableBuffer.fromFilePath(path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width, height = descriptor.height;
    final longest = width > height ? width : height;
    final scale = longest > 320 ? 320 / longest : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: (width * scale).round().clamp(1, 320),
      targetHeight: (height * scale).round().clamp(1, 320),
    );
    image = (await codec.getNextFrame()).image;
    final pixels = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (pixels == null) throw const FormatException('无法读取缩略图像素');
    final bytes = await _encodeThumbnailInWorker(
      pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
      image.width,
      image.height,
    );
    return (bytes, width, height);
  } on Exception {
    // Retain support for image formats only handled by the Dart decoder.
    return _thumbnailFallbackInWorker(path);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<(Uint8List, int, int)> _thumbnailFallbackInWorker(String path) =>
    Isolate.run(() => _createThumbnailFallback(path));

Future<Uint8List> _encodeThumbnailInWorker(
  Uint8List bytes,
  int width,
  int height,
) => Isolate.run(
  () => img.encodeJpg(
    img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      bytesOffset: bytes.offsetInBytes,
      numChannels: 4,
    ),
    quality: 72,
  ),
);
