import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../../../core/media/media_asset.dart';
import '../../../core/media/media_store.dart';
import 'cloud_document.dart';
import '../../chat/services/chat_message_projection_codec.dart';

/// Only attachment references are rewritten; prompt text, tags and call
/// arguments retain their original structure and values.
class CloudMediaCodec {
  CloudMediaCodec(this.media, {this.allowNetworkDownload = true});
  final MediaStore media;
  final bool allowNetworkDownload;

  static Map<String, dynamic> normalizeMessagePayload(
    String kind,
    Map<String, dynamic> payload,
  ) {
    if (kind != 'messages' || payload['row'] is! Map) return payload;
    final row = Map<String, dynamic>.from(payload['row'] as Map);
    final raw = row['raw_payload'];
    if (raw is! String || raw.isEmpty) return payload;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return payload;
    }
    if (decoded is! Map) return payload;
    final source = Map<String, dynamic>.from(decoded);
    final normalized = ChatMessageProjectionCodec.normalizeLegacyMediaPayload(
      rawMessageId: row['id'] as String,
      role: row['role'] as String,
      payload: source,
      blocks: [
        for (final b in (payload['message_blocks'] as List? ?? const []))
          if (b is Map && b['deleted_at'] == null && b['data'] is String)
            if (_blockJson(b['data'] as String) case final block?) block,
      ],
    );
    if (identical(normalized, source)) return payload;
    row['raw_payload'] = jsonEncode(normalized);
    return {...payload, 'row': row};
  }

  static Map<String, dynamic>? _blockJson(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  static const _jsonColumns = {
    'raw_payload',
    'data',
    'custom_config',
    'enabled_plugins',
    'thinking_levels',
    'api_keys',
    'visible_models',
    'hidden_models',
    'capabilities',
    'payload_json',
  };
  static const _imageKeys = {
    'avatarUrl',
    'avatar_url',
    'user_avatar',
    'characterImage',
    'character_image',
    'chatBackgroundImage',
    'chat_background_image',
    'backgroundImage',
    'background_image',
    'image_url',
    'imageUrl',
    'referenceImage',
    'reference_image',
    'imagePath',
    'image_path',
    'coverUrl',
    'background_image_path',
  };
  static const _fileKeys = {
    'url',
    'localPath',
    'local_path',
    'filePath',
    'file_path',
    'path',
    'uri',
    'voiceFile',
    'voice_file',
    'referenceAudioPath',
    'sampleAudioPath',
    'audioPath',
    'audio_path',
    'audioUrl',
    'audio_url',
    'referenceFilePath',
    'localAudioPath',
    'promptAudioUrl',
  };

  static bool _stickerEvent(Map value) =>
      value['pluginId'] == 'sticker' || value['type'] == 'sticker_convert';

  static const _stickerOpaqueKeys = {
    'text',
    'content',
    'prompt',
    'negativePrompt',
    'promptText',
    'arguments',
    'parameters',
    'generationSnapshot',
    'rawToolResults',
  };

  /// Visits only persisted sticker attachments, including JSON-backed columns.
  /// Unchanged nodes retain their identity so migrations do not rewrite JSON
  /// formatting or manufacture edits on devices without the original file.
  static Future<Object?> rewriteStickerAttachments(
    Object? value,
    Future<String> Function(String path) rewrite, {
    bool stickerData = false,
    bool emojiData = false,
    String key = '',
  }) async {
    if (_stickerOpaqueKeys.contains(key)) {
      return value;
    }
    if (value is Map) {
      final emoji = emojiData || value['type'] == 'emoji';
      var changed = false;
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final name = entry.key.toString();
        final previous = entry.value;
        final next =
            previous is String &&
                ((stickerData && name == 'assetPath') ||
                    (emoji && name == 'path'))
            ? await rewrite(previous)
            : await rewriteStickerAttachments(
                previous,
                rewrite,
                key: name,
                stickerData: name == 'data' && _stickerEvent(value),
                emojiData: name == 'data' && emoji,
              );
        result[name] = next;
        changed = changed || !identical(previous, next);
      }
      return changed ? result : value;
    }
    if (value is List) {
      var changed = false;
      final result = <Object?>[];
      for (final item in value) {
        final next = await rewriteStickerAttachments(item, rewrite);
        changed = changed || !identical(item, next);
        result.add(next);
      }
      return changed ? result : value;
    }
    if (value is String &&
        (_jsonColumns.contains(key) || key == 'json_value')) {
      Object? decoded;
      try {
        decoded = jsonDecode(value);
      } on FormatException {
        return value;
      }
      final next = await rewriteStickerAttachments(
        decoded,
        rewrite,
        stickerData: stickerData,
        emojiData: emojiData,
      );
      return identical(next, decoded) ? value : jsonEncode(next);
    }
    return value;
  }

  /// A remote attachment must never address a file on the receiving device.
  static void validateWirePaths(Map<String, dynamic> payload) {
    void visit(
      Object? value,
      String key, {
      bool stickerData = false,
      bool stickerPath = false,
      bool inspectSticker = true,
    }) {
      inspectSticker = inspectSticker && !_stickerOpaqueKeys.contains(key);
      if (value is Map) {
        for (final entry in value.entries) {
          final name = entry.key.toString();
          visit(
            entry.value,
            name,
            stickerData:
                inspectSticker && name == 'data' && _stickerEvent(value),
            stickerPath: inspectSticker && stickerData && name == 'assetPath',
            inspectSticker: inspectSticker,
          );
        }
      } else if (value is List) {
        for (final item in value) {
          visit(item, key, inspectSticker: inspectSticker);
        }
      } else if (value is String && value.isNotEmpty) {
        if (_jsonColumns.contains(key) || key == 'json_value') {
          Object? decoded;
          try {
            decoded = jsonDecode(value);
          } on FormatException {
            return;
          }
          visit(
            decoded,
            '',
            stickerData: stickerData,
            inspectSticker: inspectSticker,
          );
        } else if ((_imageKeys.contains(key) ||
                _fileKeys.contains(key) ||
                stickerPath ||
                key == 'images') &&
            (p.posix.isAbsolute(value) ||
                p.windows.isAbsolute(value) ||
                Uri.tryParse(value)?.scheme == 'file')) {
          throw const FormatException('Remote attachment uses a local path');
        }
      }
    }

    visit(payload, '');
  }

  Future<CloudWireDocument> encode(CloudLocalDocument document) async {
    final ids = <String>{};
    final originalRequired =
        document.kind != 'messages' && document.kind != 'message_blocks';
    final row = document.payload['row'];
    final timestamp = row is Map ? (row['created_at'] as num?)?.toInt() : null;
    final normalizedTimestamp = timestamp != null && timestamp < 100000000000
        ? timestamp * 1000
        : timestamp;
    // Settings images have no history date. Unknown dates never silently
    // qualify as a new original merely because this device imported them now.
    final at = normalizedTimestamp ?? 0;

    Future<Object?> visit(
      Object? value,
      String key, {
      bool image = false,
      bool attachment = false,
    }) async {
      if (value is Map) {
        final type = value['type']?.toString().toLowerCase();
        final imageNode =
            image ||
            const {'image', 'image_url', 'input_image', 'emoji'}.contains(type);
        final attachmentNode =
            attachment ||
            imageNode ||
            const {'audio', 'file', 'video', 'input_audio'}.contains(type);
        final result = <String, dynamic>{};
        // Generated blocks often carry both an expiring URL and a durable local
        // copy. Register the existing copy once and preserve one media identity.
        String? preferred;
        if (imageNode) {
          for (final name in ['localPath', 'local_path', 'base64']) {
            final source = value[name];
            if (source is! String || source.isEmpty) continue;
            if (name == 'base64' ||
                mediaIdFromReference(source) != null ||
                await File(source).exists()) {
              preferred = await visit(source, name, image: true) as String;
              break;
            }
          }
        }
        for (final entry in value.entries) {
          final name = entry.key.toString();
          result[name] =
              preferred != null &&
                  const {
                    'url',
                    'localPath',
                    'local_path',
                    'base64',
                  }.contains(name) &&
                  entry.value is String &&
                  (entry.value as String).isNotEmpty
              ? preferred
              : await visit(
                  entry.value,
                  name,
                  image:
                      imageNode ||
                      _imageKeys.contains(name) ||
                      name == 'images',
                  attachment: attachmentNode,
                );
        }
        return result;
      }
      if (value is List) {
        final result = <Object?>[];
        for (final item in value) {
          result.add(
            await visit(item, key, image: image, attachment: attachment),
          );
        }
        return result;
      }
      if (value is! String || value.isEmpty) return value;
      if (_jsonColumns.contains(key) || key == 'json_value') {
        Object? decoded;
        try {
          decoded = jsonDecode(value);
        } on FormatException {
          return value;
        }
        return jsonEncode(
          await visit(decoded, '', image: image, attachment: attachment),
        );
      }
      if (const {
        'text',
        'content',
        'prompt',
        'negativePrompt',
        'promptText',
        'arguments',
      }.contains(key)) {
        return value;
      }
      final existing = mediaIdFromReference(value);
      if (existing != null) {
        await media.noteUsage(
          existing,
          createdAtMs: at,
          originalRequired: originalRequired,
        );
        ids.add(existing);
        return value;
      }
      final isImage =
          image || _imageKeys.contains(key) || value.startsWith('data:image/');
      final inline = key == 'base64' && image;
      final candidate =
          inline ||
          _imageKeys.contains(key) ||
          _fileKeys.contains(key) ||
          value.startsWith('data:image/');
      if (!candidate || value.startsWith('assets/')) return value;
      final uri = Uri.tryParse(value);
      final network = uri?.scheme == 'https' || uri?.scheme == 'http';
      // A non-file label in a field named "path" is still ordinary data.
      final exists =
          !network &&
          !value.startsWith('data:') &&
          !inline &&
          await File(
            uri?.scheme == 'file' ? uri!.toFilePath() : value,
          ).exists();
      if (network &&
          !isImage &&
          !attachment &&
          !const {
            'audioPath',
            'audio_path',
            'audioUrl',
            'audio_url',
            'voiceFile',
            'voice_file',
            'referenceAudioPath',
            'sampleAudioPath',
            'promptAudioUrl',
            'localAudioPath',
          }.contains(key)) {
        return value;
      }
      if (!exists &&
          !network &&
          !inline &&
          !value.startsWith('data:') &&
          !(p.posix.isAbsolute(value) ||
              p.windows.isAbsolute(value) ||
              uri?.scheme == 'file')) {
        return value;
      }
      LocalMedia record;
      try {
        record = await media.register(
          value,
          createdAtMs: at,
          inlineImage: inline,
          originalRequired: originalRequired,
          allowNetworkDownload: allowNetworkDownload,
        );
      } on IOException {
        record = await media.unavailable(
          value,
          createdAtMs: at,
          mimeType: isImage ? 'image/unknown' : 'application/octet-stream',
        );
      }
      ids.add(record.asset.id);
      return record.asset.reference;
    }

    final stickers = await rewriteStickerAttachments(
      normalizeMessagePayload(document.kind, document.payload),
      (path) async {
        if (path.isEmpty ||
            path.startsWith('assets/') ||
            path.startsWith('packages/')) {
          return path;
        }
        final existing = mediaIdFromReference(path);
        if (existing != null) {
          await media.noteUsage(
            existing,
            createdAtMs: at,
            originalRequired: true,
          );
          return path;
        }
        LocalMedia record;
        try {
          record = await media.register(
            path,
            createdAtMs: at,
            originalRequired: true,
            allowNetworkDownload: allowNetworkDownload,
          );
        } on IOException {
          record = await media.unavailable(path, createdAtMs: at);
        }
        return record.asset.reference;
      },
    );
    final result = await visit(stickers, '') as Map<String, dynamic>;
    return CloudWireDocument(result, ids.toList()..sort());
  }

  Future<Map<String, dynamic>> decode(
    String kind,
    Map<String, dynamic> payload,
  ) async {
    Future<Object?> visit(
      Object? value,
      String key, {
      bool imageBlock = false,
    }) async {
      if (value is Map) {
        final block =
            imageBlock ||
            value['type'] == 'image' ||
            value['type'] == 'image_url' ||
            value['type'] == 'input_image';
        final result = <String, dynamic>{};
        for (final entry in value.entries) {
          result[entry.key.toString()] = await visit(
            entry.value,
            entry.key.toString(),
            imageBlock: block,
          );
        }
        return result;
      }
      if (value is List) {
        final list = <Object?>[];
        for (final item in value) {
          list.add(await visit(item, key, imageBlock: imageBlock));
        }
        return list;
      }
      if (value is! String) return value;
      if (_jsonColumns.contains(key) || key == 'json_value') {
        Object? decoded;
        try {
          decoded = jsonDecode(value);
        } on FormatException {
          return value;
        }
        return jsonEncode(await visit(decoded, '', imageBlock: imageBlock));
      }
      final id = mediaIdFromReference(value);
      if (id == null) return value;
      final record = await media.load(id);
      if (record == null) throw const CloudSyncFailure('图片身份信息尚未下载完成');
      // Raw messages and image blocks keep their ID reference. It is resolved
      // separately for display versus model input; a thumbnail is never a
      // substitute for the original when sending an image to a model.
      if (record.asset.isImage &&
          (kind == 'messages' || kind == 'message_blocks')) {
        return value;
      }
      if (!record.asset.isImage && record.asset.originalSha256 == null) {
        return value;
      }
      return media.originalDestination(id);
    }

    return await visit(normalizeMessagePayload(kind, payload), '')
        as Map<String, dynamic>;
  }
}
