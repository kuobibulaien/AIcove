import 'dart:convert';

import 'media_asset.dart';
import 'media_store.dart';

/// Resolves only structured media parts; arbitrary text/tool arguments remain
/// byte-for-byte unchanged. Throws before the model request if no original exists.
Future<List<Map<String, dynamic>>> resolveModelMedia(
  List<Map<String, dynamic>> messages, {
  MediaStore? store,
}) async {
  Future<Object?> visit(Object? value, {bool mediaPart = false}) async {
    if (value is Map) {
      final type = value['type'];
      final isMedia =
          mediaPart ||
          const {
            'image_url',
            'input_image',
            'image',
            'input_audio',
          }.contains(type);
      return {
        for (final entry in value.entries)
          entry.key.toString(): await visit(
            entry.value,
            mediaPart:
                isMedia &&
                const {
                  'url',
                  'image_url',
                  'source',
                  'data',
                  'base64',
                }.contains(entry.key),
          ),
      };
    }
    if (value is List) {
      return [
        for (final item in value) await visit(item, mediaPart: mediaPart),
      ];
    }
    if (value is! String || !mediaPart) return value;
    final id = mediaIdFromReference(value);
    if (id == null) return value;
    final library = store ?? await MediaStore.shared;
    final record = await library.load(id);
    final file = await library.original(id);
    return 'data:${record!.asset.mimeType};base64,${base64Encode(await file.readAsBytes())}';
  }

  return [
    for (final message in messages)
      Map<String, dynamic>.from(await visit(message) as Map),
  ];
}
