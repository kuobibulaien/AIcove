import 'dart:convert';
import 'dart:io';

import 'media_asset.dart';
import 'media_store.dart';

/// Resolves only structured media parts; arbitrary text/tool arguments remain
/// byte-for-byte unchanged. Uses local originals only. Missing historical images
/// become text; missing images in the last user message block the request.
Future<List<Map<String, dynamic>>> resolveModelMedia(
  List<Map<String, dynamic>> messages, {
  MediaStore? store,
}) async {
  // The message being sent is the last user message with no reply after it;
  // a request that already ends past a reply (e.g. a proactive turn without
  // a reminder) carries history only.
  final lastUser = messages.lastIndexWhere(
    (message) => message['role'] == 'user',
  );
  final currentUserIndex =
      messages.skip(lastUser + 1).any((m) => m['role'] == 'assistant')
      ? -1
      : lastUser;

  Future<Object?> visit(
    Object? value, {
    bool mediaPart = false,
    required bool currentUser,
  }) async {
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
      try {
        return {
          for (final entry in value.entries)
            entry.key.toString(): await visit(
              entry.value,
              currentUser: currentUser,
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
      } on OriginalMediaUnavailable catch (error) {
        if (!const {'image_url', 'input_image', 'image'}.contains(type)) {
          rethrow;
        }
        if (currentUser) {
          throw OriginalMediaUnavailable(
            error.mediaId,
            message: '这条消息里的图片取不到原图，本轮没有发出。请重新选择图片后再发。',
          );
        }
        return {'type': 'text', 'text': '[图片：原图不在本机]'};
      }
    }
    if (value is List) {
      return [
        for (final item in value)
          await visit(item, mediaPart: mediaPart, currentUser: currentUser),
      ];
    }
    if (value is! String || !mediaPart) return value;
    final id = mediaIdFromReference(value);
    if (id == null) return value;
    final library = store ?? await MediaStore.shared;
    final record = await library.load(id);
    try {
      final file = await library.original(id, allowDownload: false);
      return 'data:${record!.asset.mimeType};base64,${base64Encode(await file.readAsBytes())}';
    } on FileSystemException {
      throw OriginalMediaUnavailable(id);
    }
  }

  return [
    for (var i = 0; i < messages.length; i++)
      Map<String, dynamic>.from(
        await visit(messages[i], currentUser: i == currentUserIndex) as Map,
      ),
  ];
}
