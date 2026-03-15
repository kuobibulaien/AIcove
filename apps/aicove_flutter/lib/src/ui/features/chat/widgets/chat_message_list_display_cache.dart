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

class ChatMessageListPersistentCacheEntry {
  const ChatMessageListPersistentCacheEntry({
    required this.windowSignature,
    required this.formatSignature,
    required this.listItems,
  });

  final String windowSignature;
  final String formatSignature;
  final List<Map<String, dynamic>> listItems;
}

class ChatMessageListDisplayCache {
  ChatMessageListDisplayCache._();

  static const int _maxEntries = 5;
  static const int _persistentCacheVersion = 1;
  static final LinkedHashMap<String, ChatMessageListDisplayCacheEntry>
      _entries = LinkedHashMap<String, ChatMessageListDisplayCacheEntry>();
  static Directory? _persistentDir;

  static ChatMessageListDisplayCacheEntry? read({
    required String conversationId,
    required String windowSignature,
    required String formatSignature,
  }) {
    final cached = _entries.remove(conversationId);
    if (cached == null) return null;
    if (cached.windowSignature != windowSignature ||
        cached.formatSignature != formatSignature) {
      return null;
    }
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

  static Future<ChatMessageListPersistentCacheEntry?> readPersistent({
    required String conversationId,
    required String windowSignature,
    required String formatSignature,
  }) async {
    try {
      final file = await _persistentFileFor(conversationId);
      if (!await file.exists()) {
        return null;
      }

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final data = Map<String, dynamic>.from(decoded);
      if (data['version'] != _persistentCacheVersion) {
        return null;
      }
      if (data['windowSignature'] != windowSignature ||
          data['formatSignature'] != formatSignature) {
        return null;
      }

      final rawItems = data['listItems'];
      if (rawItems is! List) {
        return null;
      }

      final listItems = <Map<String, dynamic>>[];
      for (final item in rawItems) {
        if (item is! Map) {
          return null;
        }
        listItems.add(Map<String, dynamic>.from(item));
      }

      return ChatMessageListPersistentCacheEntry(
        windowSignature: windowSignature,
        formatSignature: formatSignature,
        listItems: List<Map<String, dynamic>>.unmodifiable(listItems),
      );
    } catch (error) {
      debugPrint('读取聊天显示持久缓存失败: $error');
      return null;
    }
  }

  static Future<void> writePersistent({
    required String conversationId,
    required String windowSignature,
    required String formatSignature,
    required List<Map<String, dynamic>> listItems,
  }) async {
    try {
      final file = await _persistentFileFor(conversationId);
      await file.parent.create(recursive: true);
      final payload = jsonEncode(<String, dynamic>{
        'version': _persistentCacheVersion,
        'windowSignature': windowSignature,
        'formatSignature': formatSignature,
        'listItems': listItems,
      });
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(payload, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tempFile.rename(file.path);
    } catch (error) {
      debugPrint('写入聊天显示持久缓存失败: $error');
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

  static Future<File> _persistentFileFor(String conversationId) async {
    final dir = await _createPersistentDirIfNeeded();
    return File('${dir.path}/${_fileNameForConversation(conversationId)}.json');
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
