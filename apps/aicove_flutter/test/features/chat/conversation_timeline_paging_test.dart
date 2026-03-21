import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

Future<void> _insertConversation(
  db.AppDatabase database,
  String conversationId,
  int timestamp,
) {
  return database.into(database.conversations).insert(
        db.ConversationsCompanion.insert(
          id: conversationId,
          title: '测试会话',
          displayName: '测试会话',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
}

Future<void> _insertMessage(
  db.AppDatabase database,
  String conversationId, {
  required String id,
  required String role,
  required String content,
  required int createdAt,
}) {
  return database.into(database.messages).insert(
        db.MessagesCompanion.insert(
          id: id,
          conversationId: conversationId,
          role: role,
          content: content,
          createdAt: createdAt,
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform previousPathProvider;
  Directory? tempDir;

  setUp(() {
    previousPathProvider = PathProviderPlatform.instance;
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  test('聊天首屏窗口默认应为 5 轮', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final visibleCount =
        container.read(conversationVisibleCountProvider('conv-1'));

    expect(kConversationInitialVisibleCount, 5);
    expect(kConversationVisiblePageSize, 5);
    expect(visibleCount, kConversationInitialVisibleCount);
  });

  test('分页加载应按 5 轮递增', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier =
        container.read(conversationVisibleCountProvider('conv-2').notifier);

    notifier.state += kConversationVisiblePageSize;

    expect(
      container.read(conversationVisibleCountProvider('conv-2')),
      kConversationInitialVisibleCount + kConversationVisiblePageSize,
    );
  });

  test('真实时间线应按最近 5 条原始消息收口，并按 5 条继续向上扩展', () async {
    tempDir = await Directory.systemTemp.createTemp('timeline_window_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final baseTime = DateTime(2026, 3, 19, 10, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-turn-window', baseTime);

    final rows = <({String id, String role, int offset})>[
      (id: 'u1', role: 'user', offset: 0),
      (id: 'a1', role: 'assistant', offset: 1),
      (id: 'u2', role: 'user', offset: 2),
      (id: 'a2', role: 'assistant', offset: 3),
      (id: 'u3', role: 'user', offset: 4),
      (id: 'a3', role: 'assistant', offset: 5),
      (id: 'u4', role: 'user', offset: 6),
      (id: 'a4', role: 'assistant', offset: 7),
      (id: 'u5', role: 'user', offset: 8),
      (id: 'a5_text', role: 'assistant', offset: 9),
      (id: 'a5_audio', role: 'assistant', offset: 10),
      (id: 'u6', role: 'user', offset: 11),
      (id: 'a6_text', role: 'assistant', offset: 12),
      (id: 'a6_image', role: 'assistant', offset: 13),
      (id: 'a6_audio', role: 'assistant', offset: 14),
    ];
    for (final row in rows) {
      await _insertMessage(
        database,
        'conv-turn-window',
        id: row.id,
        role: row.role,
        content: row.id,
        createdAt: baseTime + row.offset,
      );
    }

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    final initialWindow = await container.read(
      conversationMessageWindowProvider('conv-turn-window').future,
    );

    expect(
      initialWindow.messages.map((message) => message.id).toList(),
      <String>[
        'a5_audio',
        'u6',
        'a6_text',
        'a6_image',
        'a6_audio',
      ],
    );
    expect(initialWindow.hasMore, isTrue);

    final notifier = container.read(
      conversationVisibleCountProvider('conv-turn-window').notifier,
    );
    notifier.state += kConversationVisiblePageSize;
    await container.pump();

    final expandedWindow = await container.read(
      conversationMessageWindowProvider('conv-turn-window').future,
    );
    expect(
      expandedWindow.messages.map((message) => message.id).toList(),
      <String>[
        'a3',
        'u4',
        'a4',
        'u5',
        'a5_text',
        'a5_audio',
        'u6',
        'a6_text',
        'a6_image',
        'a6_audio',
      ],
    );
    expect(expandedWindow.hasMore, isTrue);

    notifier.state += kConversationVisiblePageSize;
    await container.pump();

    final fullWindow = await container.read(
      conversationMessageWindowProvider('conv-turn-window').future,
    );
    expect(
      fullWindow.messages.map((message) => message.id).toList(),
      rows.map((row) => row.id).toList(),
    );
    expect(fullWindow.hasMore, isFalse);
  });
}
