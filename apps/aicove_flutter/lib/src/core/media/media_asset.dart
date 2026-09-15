import 'package:mime/mime.dart';

/// Permanent identity is separate from the cloud's uploaded file digests.
class MediaAsset {
  const MediaAsset({
    required this.id,
    required this.mimeType,
    required this.byteLength,
    required this.createdAtMs,
    this.originalRequired = false,
    this.lastChatAtMs,
    this.width,
    this.height,
    this.thumbnailBlob,
    this.originalBlob,
    this.originalSha256,
    this.locations = const [],
  });

  final String id;
  final String mimeType;
  final int byteLength;
  final int createdAtMs;
  final bool originalRequired;
  final int? lastChatAtMs;
  final int? width;
  final int? height;
  final String? thumbnailBlob;
  final String? originalBlob;
  final String? originalSha256;
  final List<Map<String, String>> locations;

  bool get isImage => mimeType.startsWith('image/');
  bool shouldTransferOriginal(DateTime now) =>
      !isImage ||
      originalRequired ||
      (lastChatAtMs ?? createdAtMs) == 0 ||
      (lastChatAtMs ?? createdAtMs) >=
          now.subtract(const Duration(days: 30)).millisecondsSinceEpoch;
  String get reference => 'aicove-media://$id';

  Map<String, dynamic> toJson() => {
    'media_version': 1,
    'media_id': id,
    'mime_type': mimeType,
    'byte_length': byteLength,
    'created_at_ms': createdAtMs,
    'original_required': originalRequired,
    'last_chat_at_ms': lastChatAtMs ?? createdAtMs,
    'width': width,
    'height': height,
    'thumbnail_blob': thumbnailBlob,
    'original_blob': originalBlob,
    'original_sha256': originalSha256,
    'locations': locations,
  };

  factory MediaAsset.fromJson(Map<String, dynamic> json) {
    if (json['media_version'] != 1 || !validMediaId(json['media_id'])) {
      throw const FormatException('图片资料版本或 ID 无效');
    }
    return MediaAsset(
      id: json['media_id'] as String,
      mimeType: json['mime_type'] as String,
      byteLength: json['byte_length'] as int,
      createdAtMs: json['created_at_ms'] as int,
      originalRequired: json['original_required'] as bool? ?? false,
      lastChatAtMs: json['last_chat_at_ms'] as int?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      thumbnailBlob: json['thumbnail_blob'] as String?,
      originalBlob: json['original_blob'] as String?,
      originalSha256: json['original_sha256'] as String?,
      locations: (json['locations'] as List? ?? [])
          .map((e) => Map<String, String>.from(e as Map))
          .toList(),
    );
  }

  List<String> get blobIds => {
    if (thumbnailBlob != null) thumbnailBlob!,
    if (originalBlob != null) originalBlob!,
  }.toList()..sort();
}

bool validMediaId(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

String? mediaIdFromReference(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  return uri?.scheme == 'aicove-media' && validMediaId(uri!.host)
      ? uri.host
      : null;
}

String mediaFileExtension(String mime) {
  final type = mime.toLowerCase().split(';').first.trim();
  if (const {
    'audio/wav',
    'audio/wave',
    'audio/x-wav',
    'audio/vnd.wave',
  }.contains(type)) {
    return 'wav';
  }
  if (const {'audio/mp3', 'audio/mpeg'}.contains(type)) return 'mp3';
  final extension = extensionFromMime(type);
  return RegExp(r'^[a-z0-9]{1,12}$').hasMatch(extension) ? extension : 'bin';
}

class OriginalMediaUnavailable implements Exception {
  const OriginalMediaUnavailable(this.mediaId);
  final String mediaId;
  @override
  String toString() => '原图尚未加载，请加载原图后再执行此操作。';
}
