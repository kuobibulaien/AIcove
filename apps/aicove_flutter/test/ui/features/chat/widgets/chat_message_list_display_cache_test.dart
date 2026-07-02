import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
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

  test('结构化首屏缓存可通过内存 cache 直接命中', () {
    const rawItems = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'meta',
        'hasMoreMessages': false,
        'visibleTurnCount': 5,
        'lastMessagePreview': '首屏缓存命中',
        'lastMessageTime': 1234,
      },
      <String, dynamic>{
        'type': 'message',
        'messageId': 'm-1',
        'message': <String, dynamic>{
          'id': 'm-1',
          'role': 'assistant',
          'content': '首屏缓存命中',
          'createdAt': 1234,
          'status': 'sent',
          'blocks': <Map<String, dynamic>>[],
        },
        'showCorner': false,
        'showAvatar': true,
      },
    ];

    ChatMessageListDisplayCache.write(
      conversationId: 'conv-warm-boot',
      windowSignature: 'viewport_boot_v2',
      formatSignature: 'format-rich',
      listItems: rawItems.cast<Object>(),
      chatImages: const [],
    );

    final hit = ChatMessageListDisplayCache.read(
      conversationId: 'conv-warm-boot',
      windowSignature: 'viewport_boot_v2',
      formatSignature: 'format-rich',
    );

    expect(hit, isNotNull);
    expect(hit!.listItems, rawItems.cast<Object>());
  });

  test('聊天页位图快照可按联系人持久读写', () async {
    tempDir = await Directory.systemTemp.createTemp('chat_display_cache_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    await ChatMessageListDisplayCache.writeViewportSnapshot(
      conversationId: 'conv-viewport',
      pngBytes: Uint8List.fromList(const <int>[1, 2, 3, 4]),
      logicalWidth: 360,
      logicalHeight: 720,
      lastMessagePreview: '快照摘要',
      lastMessageTime: DateTime.fromMillisecondsSinceEpoch(1234),
    );

    final hit = await ChatMessageListDisplayCache.readViewportSnapshot(
      conversationId: 'conv-viewport',
    );

    expect(hit, isNotNull);
    expect(hit!.logicalWidth, 360);
    expect(hit.logicalHeight, 720);
    expect(hit.lastMessagePreview, '快照摘要');
    expect(
      hit.lastMessageTime,
      DateTime.fromMillisecondsSinceEpoch(1234),
    );
    expect(hit.imageBytes, const <int>[1, 2, 3, 4]);
  });
}
