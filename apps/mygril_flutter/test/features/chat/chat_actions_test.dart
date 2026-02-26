import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart'
    hide Conversation, Message;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/services/attachment_picker_service.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(this._seed);

  final List<Conversation> _seed;

  @override
  Future<List<Conversation>> build() async => _seed;

  @override
  Future<void> setAll(List<Conversation> list) async {
    state = AsyncValue.data(list);
  }
}

Future<void> _insertConversation(AppDatabase db, Conversation conv) async {
  await db.into(db.conversations).insert(
        ConversationsCompanion.insert(
          id: conv.id,
          title: conv.title,
          displayName: conv.displayName,
          personaPrompt: Value(conv.personaPrompt),
          createdAt: conv.createdAt.millisecondsSinceEpoch,
          updatedAt: conv.updatedAt.millisecondsSinceEpoch,
        ),
      );
}

Future<void> _insertMessage(AppDatabase db, String convId, Message msg) async {
  await db.into(db.messages).insert(
        MessagesCompanion.insert(
          id: msg.id,
          conversationId: convId,
          role: msg.role,
          content: msg.content,
          status: Value(msg.status ?? 'sent'),
          createdAt: msg.createdAt.millisecondsSinceEpoch,
        ),
      );
}

Future<void> _insertTextBlock(AppDatabase db, String messageId, String blockId,
    {int sortOrder = 0}) async {
  final block = TextBlock(
    id: blockId,
    messageId: messageId,
    content: 'block:$blockId',
  );
  await db.into(db.messageBlocks).insert(
        MessageBlocksCompanion.insert(
          id: block.id,
          messageId: block.messageId,
          type: 'mainText',
          data: jsonEncode(block.toJson()),
          sortOrder: Value(sortOrder),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recallFailedMessage 会删除失败消息并软删除数据库记录', () async {
    final now = DateTime.now();
    final failed = Message(
      id: 'msg_failed',
      role: 'user',
      content: '发送失败内容',
      createdAt: now,
      status: 'failed',
    );
    final conv = Conversation(
      id: 'conv_1',
      title: 'C1',
      displayName: 'C1',
      createdAt: now,
      updatedAt: now,
      messages: [failed],
      lastMessage: failed.displayText,
      lastMessageTime: failed.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, failed);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.recallFailedMessage(failed.id);

    final updated = container.read(conversationsProvider).valueOrNull!.first;
    expect(updated.messages, isEmpty);
    expect(container.read(editingTextProvider), failed.displayText);

    final repo = container.read(messageRepositoryProvider);
    final dbMessage = await repo.getById(failed.id);
    expect(dbMessage, isNotNull);
    expect(dbMessage!.deletedAt, isNotNull);
  });

  test('recallFailedMessage 会回填失败图文消息的文字和图片附件', () async {
    final now = DateTime.now();
    const imagePath = r'C:\tmp\demo_recall.png';
    final failed = Message.fromBlocks(
      id: 'msg_failed_img',
      role: 'user',
      blocks: [
        ImageBlock(
          messageId: 'msg_failed_img',
          localPath: imagePath,
        ),
        TextBlock(
          messageId: 'msg_failed_img',
          content: '这是撤回后的说明文字',
        ),
      ],
      createdAt: now,
      status: 'failed',
    );
    final conv = Conversation(
      id: 'conv_img',
      title: 'C_IMG',
      displayName: 'C_IMG',
      createdAt: now,
      updatedAt: now,
      messages: [failed],
      lastMessage: failed.displayText,
      lastMessageTime: failed.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, failed);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.recallFailedMessage(failed.id);

    expect(container.read(editingTextProvider), '这是撤回后的说明文字');

    final recalledAttachment = container.read(recalledAttachmentProvider);
    expect(recalledAttachment, isNotNull);
    expect(recalledAttachment!.type, AttachmentType.image);
    expect(recalledAttachment.path, imagePath);
  });

  test('deleteMessage 会删除单条消息并清理引用态', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_user',
      role: 'user',
      content: '第一条',
      createdAt: now.subtract(const Duration(minutes: 1)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_ai',
      role: 'assistant',
      content: '第二条',
      createdAt: now,
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_2',
      title: 'C2',
      displayName: 'C2',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);
    await _insertTextBlock(db, userMsg.id, 'blk_user_1');
    await _insertTextBlock(db, aiMsg.id, 'blk_ai_1');

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    container.read(quotedMessageProvider.notifier).state = const QuotedMessage(
      id: 'msg_ai',
      content: '第二条',
      isUser: false,
    );

    await actions.deleteMessage(aiMsg.id);

    final updated = container.read(conversationsProvider).valueOrNull!.first;
    expect(updated.messages.length, 1);
    expect(updated.messages.first.id, userMsg.id);
    expect(updated.lastMessage, userMsg.displayText);
    expect(container.read(quotedMessageProvider), isNull);

    final repo = container.read(messageRepositoryProvider);
    final blockRepo = container.read(messageBlockRepositoryProvider);
    final deleted = await repo.getById(aiMsg.id);
    final remained = await repo.getById(userMsg.id);
    final deletedBlocks = await blockRepo.getByMessage(aiMsg.id);
    final remainedBlocks = await blockRepo.getByMessage(userMsg.id);
    expect(deleted, isNotNull);
    expect(deleted!.deletedAt, isNotNull);
    expect(remained, isNotNull);
    expect(remained!.deletedAt, isNull);
    expect(deletedBlocks, isEmpty);
    expect(remainedBlocks.length, 1);

    final deletedBlockRaw = await blockRepo.getById('blk_ai_1');
    final remainedBlockRaw = await blockRepo.getById('blk_user_1');
    expect(deletedBlockRaw, isNotNull);
    expect(deletedBlockRaw!.deletedAt, isNotNull);
    expect(remainedBlockRaw, isNotNull);
    expect(remainedBlockRaw!.deletedAt, isNull);
  });
}
