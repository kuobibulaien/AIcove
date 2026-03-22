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

  test('聊天首屏窗口默认应为 20 条消息', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final visibleCount =
        container.read(conversationVisibleCountProvider('conv-1'));

    expect(kConversationInitialVisibleCount, 20);
    expect(kConversationVisiblePageSize, 20);
    expect(visibleCount, kConversationInitialVisibleCount);
  });

  test('分页加载应按 20 轮递增', () {
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

  test('真实时间线应按最近 20 条原始消息收口，并按 20 条继续向上扩展', () async {
    tempDir = await Directory.systemTemp.createTemp('timeline_window_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final baseTime = DateTime(2026, 3, 19, 10, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-turn-window', baseTime);

    final rows = List<({String id, String role, int offset})>.generate(
      30,
      (index) => (
        id: 'm${index + 1}',
        role: index.isEven ? 'user' : 'assistant',
        offset: index,
      ),
      growable: false,
    );
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
      List<String>.generate(20, (index) => 'm${index + 11}', growable: false),
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
      rows.map((row) => row.id).toList(),
    );
    expect(expandedWindow.hasMore, isFalse);
  });
}
