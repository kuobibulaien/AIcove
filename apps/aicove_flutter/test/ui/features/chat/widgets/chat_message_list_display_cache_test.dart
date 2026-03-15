import 'dart:io';

import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

void main() {
  late PathProviderPlatform previousPathProvider;
  Directory? tempDir;

  setUp(() {
    previousPathProvider = PathProviderPlatform.instance;
  });

  tearDown(() async {
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
    PathProviderPlatform.instance = previousPathProvider;
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  test('显示缓存应仅在窗口签名与格式签名都一致时命中', () {
    ChatMessageListDisplayCache.write(
      conversationId: 'conv-1',
      windowSignature: 'window-a',
      formatSignature: 'format-a',
      listItems: const <Object>['item-1'],
      chatImages: const [],
    );

    final hit = ChatMessageListDisplayCache.read(
      conversationId: 'conv-1',
      windowSignature: 'window-a',
      formatSignature: 'format-a',
    );
    final miss = ChatMessageListDisplayCache.read(
      conversationId: 'conv-1',
      windowSignature: 'window-b',
      formatSignature: 'format-a',
    );

    expect(hit, isNotNull);
    expect(hit!.listItems, const <Object>['item-1']);
    expect(miss, isNull);
  });

  test('显示缓存应按最近使用保留最多 5 个会话', () {
    for (var i = 0; i < 6; i++) {
      ChatMessageListDisplayCache.write(
        conversationId: 'conv-$i',
        windowSignature: 'window-$i',
        formatSignature: 'format',
        listItems: <Object>['item-$i'],
        chatImages: const [],
      );
    }

    final oldest = ChatMessageListDisplayCache.read(
      conversationId: 'conv-0',
      windowSignature: 'window-0',
      formatSignature: 'format',
    );
    final newest = ChatMessageListDisplayCache.read(
      conversationId: 'conv-5',
      windowSignature: 'window-5',
      formatSignature: 'format',
    );

    expect(ChatMessageListDisplayCache.debugSize, 5);
    expect(oldest, isNull);
    expect(newest, isNotNull);
  });

  test('持久缓存应仅在窗口签名与格式签名都一致时命中', () async {
    tempDir = await Directory.systemTemp.createTemp('chat_display_cache_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    await ChatMessageListDisplayCache.writePersistent(
      conversationId: 'conv-1',
      windowSignature: 'window-a',
      formatSignature: 'format-a',
      listItems: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'message',
          'messageId': 'm-1',
          'showCorner': false,
          'showAvatar': true,
        },
      ],
    );

    final hit = await ChatMessageListDisplayCache.readPersistent(
      conversationId: 'conv-1',
      windowSignature: 'window-a',
      formatSignature: 'format-a',
    );
    final miss = await ChatMessageListDisplayCache.readPersistent(
      conversationId: 'conv-1',
      windowSignature: 'window-b',
      formatSignature: 'format-a',
    );

    expect(hit, isNotNull);
    expect(hit!.listItems, hasLength(1));
    expect(hit.listItems.first['messageId'], 'm-1');
    expect(miss, isNull);
  });

  test('持久缓存应按联系人隔离', () async {
    tempDir = await Directory.systemTemp.createTemp('chat_display_cache_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    await ChatMessageListDisplayCache.writePersistent(
      conversationId: 'conv-a',
      windowSignature: 'window-a',
      formatSignature: 'format',
      listItems: const <Map<String, dynamic>>[
        <String, dynamic>{'type': 'new_topic'},
      ],
    );
    await ChatMessageListDisplayCache.writePersistent(
      conversationId: 'conv-b',
      windowSignature: 'window-b',
      formatSignature: 'format',
      listItems: const <Map<String, dynamic>>[
        <String, dynamic>{'type': 'time', 'time': 1000},
      ],
    );

    final first = await ChatMessageListDisplayCache.readPersistent(
      conversationId: 'conv-a',
      windowSignature: 'window-a',
      formatSignature: 'format',
    );
    final second = await ChatMessageListDisplayCache.readPersistent(
      conversationId: 'conv-b',
      windowSignature: 'window-b',
      formatSignature: 'format',
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first!.listItems.single['type'], 'new_topic');
    expect(second!.listItems.single['type'], 'time');
  });
}
