import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase appDb;
  late ProviderContainer container;
  late ChatHistoryStore store;
  final t = DateTime(2026, 10, 12, 9);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appDb = db.AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(appDb)],
    );
    store = container.read(chatHistoryStoreProvider);
    final conv = Conversation(
      id: 'nahida',
      title: '纳西妲',
      displayName: '纳西妲',
      createdAt: t,
      updatedAt: t,
    );
    await container
        .read(conversationRepositoryProvider)
        .upsert(ConversationConverter.toCompanion(conv));
    final block = CallRecordBlock(
      messageId: 'bubble',
      callId: 'call1',
      duration: const Duration(minutes: 2),
    );
    final bubble = Message(
      id: 'bubble',
      role: 'user',
      content: block.content,
      blocks: [block],
      createdAt: t,
      status: 'sent',
    );
    await store.appendUserMessage(
      conversationId: conv.id,
      message: bubble,
      displayText: bubble.displayText,
    );
    // 挂断后用户又聊了几句：会话预览已经是更新的消息。
    await container
        .read(conversationRepositoryProvider)
        .updateSummary(
          'nahida',
          '最新的回复',
          t.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
        );
  });

  tearDown(() async {
    container.dispose();
    await appDb.close();
  });

  Future<bool> attach({String callId = 'call1'}) => store.attachCallSummary(
    conversationId: 'nahida',
    messageId: 'bubble',
    callId: callId,
    summary: '用户说面试结束了。',
  );

  test(
    'fills in the summary without touching the conversation preview',
    () async {
      expect(await attach(), isTrue);
      final message = await store.loadMessageById(
        'bubble',
        conversationId: 'nahida',
        preferProjection: false,
      );
      final block = message!.blocks!.single as CallRecordBlock;
      expect(block.summary, '用户说面试结束了。');
      expect(message.content, contains('通话摘要：用户说面试结束了。'));
      final conv = await container
          .read(conversationRepositoryProvider)
          .getById('nahida');
      expect(conv!.lastMessage, '最新的回复');
      expect(
        conv.lastMessageTime,
        t.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      );
    },
  );

  test('a bubble deleted before the summary is ready stays deleted', () async {
    await store.softDeleteMessages('nahida', ['bubble']);
    expect(await attach(), isFalse);
    expect(
      await container
          .read(conversationTimelineCacheProvider)
          .findCachedMessageById('bubble', conversationId: 'nahida'),
      isNull,
    );
  });

  test('a bubble that is no longer this call is left alone', () async {
    expect(await attach(callId: 'other'), isFalse);
  });
}
