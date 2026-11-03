import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_media_regeneration.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_content.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const projection = ChatFrontendMessageProjectionService();
  final time = DateTime(2026, 10, 28);
  const snapshot = ImageGenerationSnapshot(
    providerId: 'provider',
    modelId: 'model',
    requestProvider: 'openai',
    prompt: 'artist, revised page',
    basePrompt: 'revised page',
    negativePrompt: null,
    width: 1200,
    height: 800,
    steps: 20,
    guidanceScale: 5,
  );
  final versions = [
    ImageVersionEntry(
      localPath: '/old.png',
      prompt: 'old page',
      width: 800,
      height: 1200,
      createdAt: time,
    ),
    ImageVersionEntry(
      localPath: '/new.png',
      prompt: snapshot.prompt,
      width: 1200,
      height: 800,
      generationSnapshot: snapshot,
      createdAt: time.add(const Duration(minutes: 1)),
    ),
  ];

  ImageBlock page(String id, String messageId) => ImageBlock(
    id: id,
    messageId: messageId,
    localPath: '/old.png',
    createdAt: time,
    prompt: 'old page',
    width: 800,
    height: 1200,
    versions: versions,
  );

  List<ImageBlock> images(Iterable<Message> messages) => [
    for (final message in messages) ...?message.blocks?.whereType<ImageBlock>(),
  ];

  Map<String, dynamic> roundTrip(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  test(
    'plugin contents and reply rounds reproject complete image versions',
    () {
      for (final inline in [false, true]) {
        final content = PluginImageContent(
          '/new.png',
          caption: snapshot.prompt,
          width: 1200,
          height: 800,
          generationSnapshot: snapshot,
          versions: versions,
          activeVersionIndex: 1,
        );
        final reply = inline ? 'before<image>page</image>after' : 'text';
        final events = [
          if (inline)
            PluginEvent(
              pluginId: 'image',
              type: 'image_generate',
              data: {'prompt': 'page'},
            ),
        ];
        for (final rounds in [false, true]) {
          final payload = ChatMessageProjectionCodec.buildRawAssistantPayload(
            apiResult: ApiCallResult(
              replyText: reply,
              processedText: reply,
              pluginEvents: events,
              toolResults: const [],
              pluginContents: [content],
              replyRounds: [
                if (rounds)
                  ReplyRound(
                    replyText: reply,
                    processedText: reply,
                    pluginEvents: events,
                    pluginContents: [content],
                  ),
              ],
            ),
          );
          final decoded =
              ChatMessageProjectionCodec.pluginContents(
                    roundTrip(payload),
                  ).single
                  as PluginImageContent;
          expect(
            decoded.versions.map((v) => v.toJson()),
            versions.map((v) => v.toJson()),
          );
          expect(decoded.activeVersionIndex, 1);
          final result = images(
            projection.projectMessage(
              Message(
                id: 'raw',
                role: 'assistant',
                content: reply,
                createdAt: time,
                rawPayload: roundTrip(payload),
              ),
            ),
          ).single;
          expect(
            result.versions.map((v) => v.toJson()),
            versions.map((v) => v.toJson()),
          );
          expect(result.activeVersionIndex, 1);
          expect(
            (result.localPath, result.width, result.height),
            ('/new.png', 1200, 800),
          );
          expect(result.generationSnapshot?.toJson(), snapshot.toJson());
        }
      }
    },
  );

  test('legacy plugin contents and supplements omit version fields', () {
    final payload = ChatMessageProjectionCodec.copyWithSupplementInsertOps(
      ChatMessageProjectionCodec.copyWithPluginContents(null, [
        const PluginImageContent('/old.png'),
      ]),
      [
        const StoredSupplementInsertOp(
          kind: 'image',
          textCharsBefore: 0,
          forceAppendToTail: true,
          localPath: '/old.png',
        ),
      ],
    );
    for (final field in ['pluginContents', 'supplementInsertOps']) {
      final item = (payload[field] as List).single as Map;
      expect(item.containsKey('versions'), isFalse);
      expect(item.containsKey('activeVersionIndex'), isFalse);
    }
    expect(
      ChatMessageProjectionCodec.pluginContents(
        payload,
      ).whereType<PluginImageContent>().single.versions,
      isEmpty,
    );
    expect(
      ChatMessageProjectionCodec.supplementInsertOps(
        payload,
      ).single.activeVersionIndex,
      0,
    );
    final blockWithDims = ImageBlock(
      id: 'img_dim',
      messageId: 'm_dim',
      localPath: '/old.png',
      width: 1024,
      height: 1536,
      versions: [
        ImageVersionEntry(localPath: '/old.png', createdAt: time),
      ],
      activeVersionIndex: 0,
    ).withActiveVersion(0);
    expect((blockWithDims.width, blockWithDims.height), (1024, 1536));
  });

  group('persistent page selection', () {
    late db.AppDatabase database;
    late ProviderContainer container;
    ChatHistoryStore getStore() => container.read(chatHistoryStoreProvider);
    ConversationTimelineCache getTimeline() =>
        container.read(conversationTimelineCacheProvider);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      await database
          .into(database.conversations)
          .insert(
            db.ConversationsCompanion.insert(
              id: 'conv',
              title: 'test',
              displayName: 'test',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
    });
    tearDown(() async {
      container.dispose();
      await database.close();
    });

    Future<void> coldReload() async {
      container.dispose();
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      await getTimeline().reloadConversationFromRawStore('conv');
    }

    Future<void> appendMixed({
      bool semantic = true,
      bool rawVersions = true,
    }) async {
      ImageBlock rawPage(String id) => rawVersions
          ? page(id, 'raw')
          : ImageBlock(
              id: id,
              messageId: 'raw',
              localPath: '/old.png',
              prompt: 'old page',
              width: 800,
              height: 1200,
              createdAt: time,
            );
      await getStore().appendMessage(
        conversationId: 'conv',
        message: Message.fromBlocks(
          id: 'raw',
          role: 'assistant',
          createdAt: time,
          rawPayload: semantic
              ? ChatMessageProjectionCodec.copyWithPluginContents(
                  {
                    'rawReplyText': 'before',
                    'displayReplyText': 'before',
                    'processedText': 'before',
                  },
                  [
                    for (var index = 0; index < 2; index++)
                      PluginImageContent(
                        '/old.png',
                        caption: 'old page',
                        width: 800,
                        height: 1200,
                        versions: versions,
                      ),
                  ],
                )
              : null,
          blocks: [
            TextBlock(id: 'text', messageId: 'raw', content: 'before'),
            rawPage('first'),
            rawPage('second'),
          ],
        ),
      );
    }

    test(
      'same-source pages update only the selected occurrence in raw and cache',
      () async {
        await appendMixed();
        final original = await getStore().loadProjectedMessagesFromRawStore(
          'conv',
        );
        final selected = original.last;
        await getStore().selectImageVersion(
          conversationId: 'conv',
          messageId: selected.id,
          blockId: selected.blocks!.single.id,
          versionIndex: 1,
        );
        final raw = (await getStore().loadAllRawMessages('conv')).single;
        expect(images([raw]).map((b) => b.localPath), ['/old.png', '/new.png']);
        expect(images([raw]).map((b) => b.id), ['first', 'second']);
        expect(images([raw]).last.createdAt, time);
        expect(raw.displayText, contains('before'));
        final ops = ChatMessageProjectionCodec.supplementInsertOps(
          raw.rawPayload,
        );
        expect(ops.map((op) => op.activeVersionIndex), [0, 1]);
        final contents = ChatMessageProjectionCodec.pluginContents(
          raw.rawPayload,
        ).whereType<PluginImageContent>().toList();
        expect(contents.map((c) => c.activeVersionIndex), [0, 1]);
        expect(contents.last.generationSnapshot?.toJson(), snapshot.toJson());
        final cached = images(await getTimeline().loadCachedMessages('conv'));
        expect(cached.map((b) => b.localPath), ['/old.png', '/new.png']);
        expect(
          cached.last.versions.map((v) => v.toJson()),
          images([raw]).last.versions.map((v) => v.toJson()),
        );
        await coldReload();
        final rebuilt = await getStore().loadProjectedMessagesFromRawStore(
          'conv',
        );
        expect(rebuilt.map((m) => m.id), original.map((m) => m.id));
        expect(images(rebuilt).map((b) => b.activeVersionIndex), [0, 1]);
        expect(
          images(rebuilt).last.generationSnapshot?.toJson(),
          snapshot.toJson(),
        );
        await getStore().selectImageVersion(
          conversationId: 'conv',
          messageId: selected.id,
          blockId: selected.blocks!.single.id,
          versionIndex: 0,
        );
        expect(
          images(
            await getStore().loadAllRawMessages('conv'),
          ).map((b) => b.localPath),
          ['/old.png', '/old.png'],
        );
      },
    );

    test(
      'mixed raw blocks keep all projection identities without semantic migration',
      () async {
        await appendMixed(semantic: false);
        final before = await getStore().loadProjectedMessagesFromRawStore(
          'conv',
        );
        final selected = before.last;
        await getStore().selectImageVersion(
          conversationId: 'conv',
          messageId: selected.id,
          blockId: selected.blocks!.single.id,
          versionIndex: 1,
        );
        await coldReload();
        final after = await getStore().loadProjectedMessagesFromRawStore(
          'conv',
        );
        expect(after.map((m) => m.id), before.map((m) => m.id));
        expect(
          after.expand((m) => m.blocks ?? <MessageBlock>[]).map((b) => b.id),
          before.expand((m) => m.blocks ?? <MessageBlock>[]).map((b) => b.id),
        );
        expect(images(after).map((b) => b.localPath), ['/old.png', '/new.png']);
        expect(
          (await getStore().loadAllRawMessages('conv')).single.rawPayload,
          isNull,
        );
      },
    );

    test(
      'selection copies projection history into a legacy raw attachment',
      () async {
        await appendMixed(rawVersions: false);
        final selected = (await getStore().loadProjectedMessagesFromRawStore(
          'conv',
        )).last;
        await getStore().selectImageVersion(
          conversationId: 'conv',
          messageId: selected.id,
          blockId: selected.blocks!.single.id,
          versionIndex: 1,
        );
        final raw = images(await getStore().loadAllRawMessages('conv'));
        expect(raw.first.versions, isEmpty);
        expect(raw.last.localPath, '/new.png');
        expect(
          raw.last.versions.map((v) => v.toJson()),
          versions.map((v) => v.toJson()),
        );
      },
    );

    test(
      'database failure rolls selection back before cache publication',
      () async {
        await appendMixed();
        final selected = (await getStore().loadProjectedMessagesFromRawStore(
          'conv',
        )).last;
        final before = (await getStore().loadAllRawMessages('conv')).single;
        final cached = ChatMessageProjectionCodec.serializeMessages(
          await getTimeline().loadCachedMessages('conv'),
        );
        await database.customStatement(
          "CREATE TRIGGER fail_select BEFORE UPDATE ON messages BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
        );
        await expectLater(
          getStore().selectImageVersion(
            conversationId: 'conv',
            messageId: selected.id,
            blockId: selected.blocks!.single.id,
            versionIndex: 1,
          ),
          throwsA(predicate((e) => e.toString().contains('disk failure'))),
        );
        final after = (await getStore().loadAllRawMessages('conv')).single;
        expect(after.rawPayload, before.rawPayload);
        expect(
          after.blocks!.map((b) => b.toJson()),
          before.blocks!.map((b) => b.toJson()),
        );
        expect(
          ChatMessageProjectionCodec.serializeMessages(
            await getTimeline().loadCachedMessages('conv'),
          ),
          cached,
        );
      },
    );

    test(
      'invalid index and wrong conversation leave raw and cache untouched',
      () async {
        await appendMixed();
        final selected = (await getStore().loadProjectedMessagesFromRawStore(
          'conv',
        )).last;
        final before = (await getStore().loadAllRawMessages('conv')).single;
        final cachedBefore = ChatMessageProjectionCodec.serializeMessages(
          await getTimeline().loadCachedMessages('conv'),
        );
        for (final index in [-1, 2]) {
          await expectLater(
            getStore().selectImageVersion(
              conversationId: 'conv',
              messageId: selected.id,
              blockId: selected.blocks!.single.id,
              versionIndex: index,
            ),
            throwsRangeError,
          );
        }
        await expectLater(
          getStore().selectImageVersion(
            conversationId: 'other',
            messageId: selected.id,
            blockId: selected.blocks!.single.id,
            versionIndex: 1,
          ),
          throwsStateError,
        );
        final after = (await getStore().loadAllRawMessages('conv')).single;
        expect(after.rawPayload, before.rawPayload);
        expect(
          after.blocks!.map((b) => b.toJson()),
          before.blocks!.map((b) => b.toJson()),
        );
        expect(
          ChatMessageProjectionCodec.serializeMessages(
            await getTimeline().loadCachedMessages('conv'),
          ),
          cachedBefore,
        );
      },
    );

    test('version switching does not require a regeneration prompt', () async {
      final original =
          ImageBlock(
            id: 'page',
            messageId: 'raw',
            localPath: '/first.png',
            createdAt: time,
          ).withAddedVersion(
            ImageVersionEntry(localPath: '/second.png', createdAt: time),
          );
      await getStore().appendMessage(
        conversationId: 'conv',
        message: Message.fromBlocks(
          id: 'raw',
          role: 'assistant',
          createdAt: time,
          blocks: [original],
        ),
      );
      await getStore().selectImageVersion(
        conversationId: 'conv',
        messageId: 'raw',
        blockId: 'page',
        versionIndex: 0,
      );
      final raw = (await getStore().loadAllRawMessages('conv')).single;
      expect(images([raw]).single.localPath, '/first.png');
      expect(images([raw]).single.prompt, isNull);
    });

    test(
      'remote and base64-only historical versions survive supplement reload',
      () async {
        final versioned =
            ImageBlock(
              id: 'page',
              messageId: 'raw',
              url: 'https://example.com/old.png',
              createdAt: time,
              prompt: 'old page',
            ).withAddedVersion(
              ImageVersionEntry(
                base64: 'cGFnZQ==',
                prompt: 'embedded page',
                createdAt: time,
              ),
            );
        await getStore().appendMessage(
          conversationId: 'conv',
          message: Message.fromBlocks(
            id: 'raw',
            role: 'assistant',
            createdAt: time,
            blocks: [
              TextBlock(messageId: 'raw', content: 'page'),
              versioned,
            ],
          ),
        );
        final selected = (await getStore().loadProjectedMessagesFromRawStore(
          'conv',
        )).last;
        for (final index in [0, 1]) {
          await getStore().selectImageVersion(
            conversationId: 'conv',
            messageId: selected.id,
            blockId: selected.blocks!.single.id,
            versionIndex: index,
          );
          await coldReload();
          final rebuilt = images(
            await getStore().loadProjectedMessagesFromRawStore('conv'),
          ).single;
          expect(rebuilt.activeVersionIndex, index);
          expect(rebuilt.localPath, isNull);
          expect(
            rebuilt.url,
            index == 0 ? 'https://example.com/old.png' : null,
          );
          expect(rebuilt.base64, index == 1 ? 'cGFnZQ==' : null);
          expect(
            rebuilt.versions.map((v) => v.toJson()),
            versioned.versions.map((v) => v.toJson()),
          );
        }
      },
    );

    test(
      'regeneration reuses one exact version entry in raw, payload and cache',
      () async {
        await appendMixed();
        final selected = (await getStore().loadProjectedMessagesFromRawStore(
          'conv',
        )).last;
        final target = await getStore().loadMediaRegenerationTarget(
          conversationId: 'conv',
          messageId: selected.id,
          blockId: selected.blocks!.single.id,
        );
        await getStore().replaceGeneratedMedia(
          conversationId: 'conv',
          target: target,
          result: const GeneratedChatMedia.image(
            '/regenerated.png',
            width: 1200,
            height: 800,
            imageSnapshot: snapshot,
          ),
        );
        final raw = (await getStore().loadAllRawMessages('conv')).single;
        final saved = images([raw]).last;
        expect(saved.versions, hasLength(3));
        final expected = saved.versions.map((v) => v.toJson()).toList();
        expect(
          images(
            await getTimeline().loadCachedMessages('conv'),
          ).last.versions.map((v) => v.toJson()),
          expected,
        );
        expect(
          images(
            await getStore().loadProjectedMessagesFromRawStore('conv'),
          ).last.versions.map((v) => v.toJson()),
          expected,
        );
      },
    );

    test(
      'failed supplement with no raw image can regenerate and select after restart',
      () async {
        final raw = Message(
          id: 'raw',
          role: 'assistant',
          content: '<image>page</image>',
          createdAt: time,
          rawPayload: {
            'rawReplyText': '<image>page</image>',
            'displayReplyText': '',
            'processedText': '',
          },
        );
        await getStore().appendAssistantRawMessage(
          conversationId: 'conv',
          userMessageId: '',
          rawMessage: raw,
          projectedMessages: const [],
          lastMessagePreview: '',
        );
        await getStore().appendMessage(
          conversationId: 'conv',
          message: Message.fromBlocks(
            id: 'failed_page',
            role: 'assistant',
            sourceMessageId: 'raw',
            createdAt: time,
            blocks: [
              ImageBlock(
                id: 'failed_block',
                messageId: 'failed_page',
                prompt: 'page',
                generationSnapshot: snapshot,
                status: BlockStatus.error,
                createdAt: time,
              ),
            ],
          ),
        );
        await coldReload();
        final failed = images(
          await getStore().loadProjectedMessagesFromRawStore('conv'),
        ).single;
        expect(failed.status, BlockStatus.error);
        final target = await getStore().loadMediaRegenerationTarget(
          conversationId: 'conv',
          messageId: 'failed_page',
          blockId: 'failed_block',
        );
        await getStore().replaceGeneratedMedia(
          conversationId: 'conv',
          target: target,
          result: const GeneratedChatMedia.image(
            '/recovered.png',
            imageSnapshot: snapshot,
          ),
        );
        await coldReload();
        final recovered = images(
          await getStore().loadProjectedMessagesFromRawStore('conv'),
        ).single;
        expect(recovered.status, BlockStatus.success);
        expect(recovered.versions, hasLength(1));
        expect(recovered.localPath, '/recovered.png');
        expect(images(await getStore().loadAllRawMessages('conv')), isEmpty);
        await getStore().selectImageVersion(
          conversationId: 'conv',
          messageId: 'failed_page',
          blockId: 'failed_block',
          versionIndex: 0,
        );
        expect(
          images(
            await getTimeline().loadCachedMessages('conv'),
          ).single.localPath,
          '/recovered.png',
        );
      },
    );
  });
}
