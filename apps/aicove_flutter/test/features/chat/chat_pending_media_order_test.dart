import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final time = DateTime(2026, 9, 22, 10);
  const owner = 'pending-media-order';
  const rawId = 'assistant-raw';
  late db.AppDatabase database;
  late ProviderContainer container;

  ProviderContainer newContainer() => ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(database)],
  );
  ChatHistoryStore history() => container.read(chatHistoryStoreProvider);
  Future<List<Message>> timeline() =>
      history().loadCachedTimelineMessages(owner);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.customStatement('PRAGMA foreign_keys = ON');
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: owner,
            title: owner,
            displayName: owner,
            createdAt: time.millisecondsSinceEpoch,
            updatedAt: time.millisecondsSinceEpoch,
          ),
        );
    container = newContainer();
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  Future<List<Message>> seed() async {
    final segments = <Message>[
      for (var i = 0; i < 5; i++)
        if (i.isEven)
          Message.text(
            id: 'segment-$i',
            role: 'assistant',
            sourceMessageId: rawId,
            content: '文字 $i',
            createdAt: time.add(Duration(milliseconds: i * 100)),
          )
        else
          Message.fromBlocks(
            id: 'segment-$i',
            role: 'assistant',
            sourceMessageId: rawId,
            blocks: [
              AudioBlock(
                messageId: 'segment-$i',
                url: '',
                text: '语音 $i',
                status: BlockStatus.pending,
              ),
            ],
            createdAt: time.add(Duration(milliseconds: i * 100)),
          ),
    ];
    await history().appendAssistantRawMessage(
      conversationId: owner,
      userMessageId: '',
      rawMessage: Message.text(
        id: rawId,
        role: 'assistant',
        content: '文字 0<tts>语音 1</tts>文字 2<tts>语音 3</tts>文字 4',
        createdAt: time.add(const Duration(seconds: 1)),
      ),
      projectedMessages: segments,
      lastMessagePreview: '文字 4',
    );
    await history().appendMessage(
      conversationId: owner,
      message: Message.text(
        id: 'next-user',
        role: 'user',
        content: '下一轮',
        createdAt: time.add(const Duration(seconds: 2)),
      ),
    );
    return segments;
  }

  test('历史刷新与迟到语音同时入队时仍保留刷新后的原位', () async {
    final original = await seed();
    final refresh = container
        .read(conversationTimelineCacheProvider)
        .reloadConversationFromRawStore(owner);
    final update = history().updateMessage(
      conversationId: owner,
      message: original[3].copyWith(
        blocks: [
          AudioBlock(
            messageId: original[3].id,
            url: '/test-only/voice-3.wav',
            text: '语音 3',
            status: BlockStatus.success,
          ),
        ],
      ),
    );
    await Future.wait([refresh, update]);
    expect((await timeline()).map((m) => m.id), [
      ...original.map((m) => m.id),
      'next-user',
    ]);
  });

  for (final reload in [false, true]) {
    for (final fallback in [false, true]) {
      test('迟到语音逆序回填保留原位 reload=$reload fallback=$fallback', () async {
        final original = await seed();
        final expectedIds = [...original.map((m) => m.id), 'next-user'];
        if (reload) {
          await container
              .read(conversationTimelineCacheProvider)
              .reloadConversationFromRawStore(owner);
        }
        final before = await timeline();
        expect(before.map((m) => m.id), expectedIds);
        final positions = {for (final m in before) m.id: m.createdAt};

        // The callback retains the stream-time message while history reload
        // may already have normalized every sibling to the raw timestamp.
        for (final i in [3, 1]) {
          final pending = original[i];
          final resolved = fallback
              ? Message.text(
                  id: pending.id,
                  role: pending.role,
                  sourceMessageId: pending.sourceMessageId,
                  content: '语音 $i',
                  createdAt: pending.createdAt,
                )
              : pending.copyWith(
                  blocks: [
                    AudioBlock(
                      messageId: pending.id,
                      url: '/test-only/voice-$i.wav',
                      text: '语音 $i',
                      status: BlockStatus.success,
                    ),
                  ],
                );
          await history().updateMessage(
            conversationId: owner,
            message: resolved,
          );
          final after = await timeline();
          expect(
            after.map((m) => m.id),
            expectedIds,
            reason: '回填第 $i 段不能重新插入或改变兄弟消息顺序',
          );
          expect(
            after.firstWhere((m) => m.id == pending.id).createdAt,
            positions[pending.id],
          );
        }

        container.dispose();
        container = newContainer();
        final restored = await timeline();
        expect(restored.map((m) => m.id), expectedIds);
        for (final i in [1, 3]) {
          final message = restored.firstWhere((m) => m.id == 'segment-$i');
          if (fallback) {
            expect(
              message.blocks!.whereType<TextBlock>().single.content,
              '语音 $i',
            );
          } else {
            expect(
              message.blocks!.whereType<AudioBlock>().single.url,
              '/test-only/voice-$i.wav',
            );
          }
        }
        final raw = await history().loadAllRawMessages(owner);
        expect(raw.map((m) => m.id), [rawId, 'next-user']);
        expect(raw.first.content, '文字 0<tts>语音 1</tts>文字 2<tts>语音 3</tts>文字 4');
        expect(
          await database.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      });
    }
  }
}
