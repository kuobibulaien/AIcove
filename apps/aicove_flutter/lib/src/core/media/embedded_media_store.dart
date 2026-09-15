import 'dart:convert';

import 'media_store.dart';

/// All embedded occurrences reuse the same content-addressed media store.
/// Text, tool arguments and generation parameters retain their original values.
class EmbeddedMediaStore {
  EmbeddedMediaStore({Future<MediaStore> Function()? store})
    : _store = store ?? (() => MediaStore.shared);
  final Future<MediaStore> Function() _store;
  static final shared = EmbeddedMediaStore();
  static const _mediaKeys = {
    'audioUrl',
    'audio_url',
    'imageUrl',
    'image_url',
    'url',
    'localPath',
    'local_path',
    'imagePath',
    'image_path',
    'avatarUrl',
    'avatar_url',
    'characterImage',
    'character_image',
    'chatBackgroundImage',
    'chat_background_image',
  };

  Future<String> compactJson(String raw) async {
    if (!raw.contains('data:audio/') &&
        !raw.contains('data:image/') &&
        !raw.contains('data:video/')) {
      return raw;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return raw;
    }
    final files = <String, String>{};
    var changed = false;
    Future<Object?> visit(
      Object? value,
      String key, {
      bool image = false,
    }) async {
      if (const {
        'arguments',
        'parameters',
        'generationSnapshot',
        'rawToolResults',
      }.contains(key)) {
        return value;
      }
      if (value is Map) {
        final imageNode =
            image ||
            const {
              'image',
              'image_url',
              'input_image',
              'emoji',
            }.contains(value['type']);
        final result = <String, dynamic>{};
        for (final entry in value.entries) {
          result[entry.key.toString()] = await visit(
            entry.value,
            entry.key.toString(),
            image: imageNode,
          );
        }
        return result;
      }
      if (value is List) {
        final result = <Object?>[];
        for (final item in value) {
          result.add(await visit(item, key, image: image));
        }
        return result;
      }
      if (value is! String ||
          !_mediaKeys.contains(key) ||
          !value.startsWith('data:')) {
        return value;
      }
      final known = files['${image ? 'image' : 'file'}:$value'];
      if (known != null) return known;
      UriData data;
      try {
        data = UriData.parse(value);
      } on FormatException {
        return value;
      }
      if (!['audio/', 'image/', 'video/'].any(data.mimeType.startsWith)) {
        return value;
      }
      final media = await _store();
      final record = await media.register(value, createdAtMs: 0);
      final file = await media.original(record.asset.id, allowDownload: false);
      changed = true;
      return files['${image ? 'image' : 'file'}:$value'] =
          image && record.asset.isImage ? record.asset.reference : file.path;
    }

    final result = await visit(decoded, '');
    return changed ? jsonEncode(result) : raw;
  }
}
