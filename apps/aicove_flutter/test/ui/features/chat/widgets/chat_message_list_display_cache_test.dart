import 'dart:convert';
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

String _persistentCacheFileName(String conversationId) {
  return base64UrlEncode(utf8.encode(conversationId)).replaceAll('=', '');
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

  test('持久缓存可保存首屏渲染所需的富消息载荷', () async {
    tempDir = await Directory.systemTemp.createTemp('chat_display_cache_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    await ChatMessageListDisplayCache.writePersistent(
      conversationId: 'conv-rich',
      windowSignature: 'viewport_boot_v2',
      formatSignature: 'format-rich',
      listItems: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'meta',
          'hasMoreMessages': true,
          'visibleTurnCount': 25,
          'lastMessagePreview': '最后一条',
          'lastMessageTime': 1000,
        },
        <String, dynamic>{
          'type': 'message',
          'messageId': 'm-1',
          'message': <String, dynamic>{
            'id': 'm-1',
            'role': 'assistant',
            'content': '首屏内容',
            'createdAt': 1000,
            'status': 'sent',
            'blocks': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'b-1',
                'messageId': 'm-1',
                'type': 'mainText',
                'status': 'success',
                'content': '首屏内容',
                'createdAt': '2026-01-01T12:00:00.000',
              },
            ],
          },
          'showCorner': false,
          'showAvatar': true,
        },
      ],
    );

    final hit = await ChatMessageListDisplayCache.readPersistent(
      conversationId: 'conv-rich',
      windowSignature: 'viewport_boot_v2',
      formatSignature: 'format-rich',
    );

    expect(hit, isNotNull);
    expect(hit!.listItems, hasLength(2));
    expect(hit.listItems.first['type'], 'meta');
    expect(hit.listItems.first['visibleTurnCount'], 25);
    expect(hit.listItems.last['type'], 'message');
    expect((hit.listItems.last['message'] as Map)['content'], '首屏内容');
  });

  test('损坏的持久缓存文件会在读取失败后自愈删除', () async {
    tempDir = await Directory.systemTemp.createTemp('chat_display_cache_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    final cacheDir = Directory('${tempDir!.path}/chat_message_list_cache');
    await cacheDir.create(recursive: true);
    final file = File(
      '${cacheDir.path}/${_persistentCacheFileName('conv-corrupt')}.json',
    );
    await file
        .writeAsString('{"version":1,"listItems":[{"type":"message"}]坏掉了');

    final hit = await ChatMessageListDisplayCache.readPersistent(
      conversationId: 'conv-corrupt',
      windowSignature: 'window-a',
      formatSignature: 'format-a',
    );

    expect(hit, isNull);
    expect(await file.exists(), isFalse);
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

  test('同一会话连续并发写持久缓存不会损坏最终文件', () async {
    tempDir = await Directory.systemTemp.createTemp('chat_display_cache_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    Future<void> writeVersion(int version) {
      return ChatMessageListDisplayCache.writePersistent(
        conversationId: 'conv-serial',
        windowSignature: 'window-a',
        formatSignature: 'format-a',
        listItems: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'meta',
            'visibleTurnCount': version,
          },
          <String, dynamic>{
            'type': 'message',
            'messageId': 'm-$version',
            'message': <String, dynamic>{
              'id': 'm-$version',
              'role': 'assistant',
              'content': 'payload-$version',
              'createdAt': version,
              'status': 'sent',
              'blocks': <Map<String, dynamic>>[],
            },
            'showCorner': false,
            'showAvatar': true,
          },
        ],
      );
    }

    await Future.wait(<Future<void>>[
      writeVersion(1),
      writeVersion(2),
      writeVersion(3),
      writeVersion(4),
    ]);

    final hit = await ChatMessageListDisplayCache.readPersistent(
      conversationId: 'conv-serial',
      windowSignature: 'window-a',
      formatSignature: 'format-a',
    );
    final cacheDir = Directory('${tempDir!.path}/chat_message_list_cache');
    final tmpFiles = cacheDir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.tmp'))
        .toList();

    expect(hit, isNotNull);
    expect(hit!.listItems.first['visibleTurnCount'], 4);
    expect((hit.listItems.last['message'] as Map)['content'], 'payload-4');
    expect(tmpFiles, isEmpty);
  });
}
