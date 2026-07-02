import 'dart:convert';
import 'dart:io';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../ui/shared/widgets/media/moe_image_preview.dart';

class ChatMessageListDisplayCacheEntry {
  const ChatMessageListDisplayCacheEntry({
    required this.windowSignature,
    required this.formatSignature,
    required this.listItems,
    required this.chatImages,
  });

  final String windowSignature;
  final String formatSignature;
  final List<Object> listItems;
  final List<ImagePreviewItem> chatImages;
}

class ChatPageViewportSnapshotEntry {
  const ChatPageViewportSnapshotEntry({
    required this.imageBytes,
    required this.logicalWidth,
    required this.logicalHeight,
    this.lastMessagePreview,
    this.lastMessageTime,
  });

  final Uint8List imageBytes;
  final double logicalWidth;
  final double logicalHeight;
  final String? lastMessagePreview;
  final DateTime? lastMessageTime;
}

class ChatMessageListDisplayCache {
  ChatMessageListDisplayCache._();

  static const int _maxEntries = 5;
  static final LinkedHashMap<String, ChatMessageListDisplayCacheEntry>
      _entries = LinkedHashMap<String, ChatMessageListDisplayCacheEntry>();
  static Directory? _persistentDir;

  static ChatMessageListDisplayCacheEntry? read({
    required String conversationId,
    required String windowSignature,
    required String formatSignature,
  }) {
    final cached = _entries[conversationId];
    if (cached == null) return null;
    if (cached.windowSignature != windowSignature ||
        cached.formatSignature != formatSignature) {
      return null;
    }
    _entries.remove(conversationId);
    _entries[conversationId] = cached;
    return cached;
  }

  static void write({
    required String conversationId,
    required String windowSignature,
    required String formatSignature,
    required List<Object> listItems,
    required List<ImagePreviewItem> chatImages,
  }) {
    _entries.remove(conversationId);
    _entries[conversationId] = ChatMessageListDisplayCacheEntry(
      windowSignature: windowSignature,
      formatSignature: formatSignature,
      listItems: List<Object>.unmodifiable(listItems),
      chatImages: List<ImagePreviewItem>.unmodifiable(chatImages),
    );
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  static Future<ChatPageViewportSnapshotEntry?> readViewportSnapshot({
    required String conversationId,
  }) async {
    try {
      final metaFile = await _viewportSnapshotMetaFileFor(conversationId);
      if (!await metaFile.exists()) {
        return null;
      }

      final decoded = jsonDecode(await metaFile.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final data = Map<String, dynamic>.from(decoded);
      final rawWidth = data['logicalWidth'];
      final rawHeight = data['logicalHeight'];
      if (rawWidth is! num || rawHeight is! num) {
        return null;
      }

      final imageFile = await _viewportSnapshotImageFileFor(conversationId);
      if (!await imageFile.exists()) {
        return null;
      }
      final imageBytes = await imageFile.readAsBytes();
      if (imageBytes.isEmpty) {
        return null;
      }

      final rawTime = data['lastMessageTime'];
      return ChatPageViewportSnapshotEntry(
        imageBytes: imageBytes,
        logicalWidth: rawWidth.toDouble(),
        logicalHeight: rawHeight.toDouble(),
        lastMessagePreview: data['lastMessagePreview'] as String?,
        lastMessageTime: rawTime is num
            ? DateTime.fromMillisecondsSinceEpoch(rawTime.toInt())
            : null,
      );
    } catch (error) {
      debugPrint('读取聊天页位图快照失败: $error');
      return null;
    }
  }

  static Future<void> writeViewportSnapshot({
    required String conversationId,
    required Uint8List pngBytes,
    required double logicalWidth,
    required double logicalHeight,
    String? lastMessagePreview,
    DateTime? lastMessageTime,
  }) async {
    try {
      final imageFile = await _viewportSnapshotImageFileFor(conversationId);
      final metaFile = await _viewportSnapshotMetaFileFor(conversationId);
      await imageFile.parent.create(recursive: true);

      final tempImageFile = File('${imageFile.path}.tmp');
      await tempImageFile.writeAsBytes(pngBytes, flush: true);
      if (await imageFile.exists()) {
        await imageFile.delete();
      }
      await tempImageFile.rename(imageFile.path);

      final payload = jsonEncode(<String, dynamic>{
        'logicalWidth': logicalWidth,
        'logicalHeight': logicalHeight,
        'lastMessagePreview': lastMessagePreview,
        'lastMessageTime': lastMessageTime?.millisecondsSinceEpoch,
      });
      final tempMetaFile = File('${metaFile.path}.tmp');
      await tempMetaFile.writeAsString(payload, flush: true);
      if (await metaFile.exists()) {
        await metaFile.delete();
      }
      await tempMetaFile.rename(metaFile.path);
    } catch (error) {
      debugPrint('写入聊天页位图快照失败: $error');
    }
  }

  @visibleForTesting
  static void clear() {
    _entries.clear();
  }

  @visibleForTesting
  static Future<void> clearPersistent() async {
    try {
      final dir = _persistentDir ?? await _createPersistentDirIfNeeded();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // 测试辅助：忽略不存在等清理异常
    } finally {
      _persistentDir = null;
    }
  }

  @visibleForTesting
  static int get debugSize => _entries.length;

  static Future<File> _viewportSnapshotImageFileFor(
      String conversationId) async {
    final dir = await _createPersistentDirIfNeeded();
    return File(
        '${dir.path}/${_fileNameForConversation(conversationId)}.viewport.png');
  }

  static Future<File> _viewportSnapshotMetaFileFor(
      String conversationId) async {
    final dir = await _createPersistentDirIfNeeded();
    return File(
        '${dir.path}/${_fileNameForConversation(conversationId)}.viewport.json');
  }

  static Future<Directory> _createPersistentDirIfNeeded() async {
    if (_persistentDir != null) {
      return _persistentDir!;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/chat_message_list_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _persistentDir = dir;
    return dir;
  }

  static String _fileNameForConversation(String conversationId) {
    return base64UrlEncode(utf8.encode(conversationId)).replaceAll('=', '');
  }
}
