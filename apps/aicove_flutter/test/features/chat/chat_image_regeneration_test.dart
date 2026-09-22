import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_media_regeneration.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';

typedef RegenerateChatImage = Future<String> Function(
    String owner, String prompt);

class _ImageGenerator implements ChatMediaGenerationPort {
  _ImageGenerator(this.generateImage);
  final RegenerateChatImage generateImage;
  @override
  Future<GeneratedChatMedia> generate(String owner, String input,
          {ImageGenerationSnapshot? imageSnapshot}) async =>
      GeneratedChatMedia.image(await generateImage(owner, input));
}

class _ImageSettings extends AppSettingsNotifier {
  _ImageSettings(this.settings);
  final AppSettings settings;
  @override
  Future<AppSettings> build() async => settings;
}

class _LocalHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  ChatHistoryStore store() => container.read(chatHistoryStoreProvider);
  Message imageMessage({String role = 'assistant'}) => Message.fromBlocks(
          id: 'm',
          role: role,
          createdAt: DateTime.fromMillisecondsSinceEpoch(10),
          blocks: [
            TextBlock(id: 'text', messageId: 'm', content: '保留文字'),
            ImageBlock(
                id: 'image',
                messageId: 'm',
                localPath: '/old.png',
                prompt: 'style, cat',
                generationSnapshot: const ImageGenerationSnapshot(
                    providerId: 'local',
                    modelId: 'original',
                    requestProvider: 'openai',
                    prompt: 'style, cat',
                    negativePrompt: 'old',
                    width: 1024,
                    height: 768,
                    steps: 31,
                    guidanceScale: 6.5)),
            ImageBlock(
                id: 'other',
                messageId: 'm',
                localPath: '/other.png',
                prompt: 'dog'),
          ]);
  Future<void> seed({bool projected = false, String role = 'assistant'}) async {
    final message = imageMessage(role: role);
    await store().updateMessage(
        conversationId: 'a',
        message: projected
            ? Message(
                id: 'raw',
                role: 'assistant',
                content: '原始模型回答',
                createdAt: message.createdAt,
                rawPayload:
                    ChatMessageProjectionCodec.copyWithProjectedMessages({
                  'rawReplyText': '原始模型回答',
                  'processedText': '原始模型回答'
                }, [
                  message.copyWith(sourceMessageId: 'raw'),
                  Message(
                      id: 'sibling',
                      role: 'assistant',
                      content: '保留后续回复',
                      sourceMessageId: 'raw',
                      createdAt: message.createdAt)
                ]))
            : message);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.customStatement('PRAGMA foreign_keys = ON');
    container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)]);
    for (final owner in ['a', 'b']) {
      await database.into(database.conversations).insert(
          db.ConversationsCompanion.insert(
              id: owner,
              title: owner,
              displayName: owner,
              createdAt: 0,
              updatedAt: 0));
    }
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });
  Future<void> run(ChatMediaRegeneration action) =>
      action.regenerate(conversationId: 'a', messageId: 'm', blockId: 'image');
  ChatMediaRegeneration action(RegenerateChatImage generate) =>
      ChatMediaRegeneration(
          store: store(),
          generators: {RegeneratableMediaKind.image: _ImageGenerator(generate)},
          isSending: (_) => false);

  for (final projected in [false, true]) {
    test('单图替换并重新加载，保留其他块与原文 projected=$projected', () async {
      await seed(projected: projected);
      await run(action((owner, prompt) async {
        expect(owner, 'a');
        expect(prompt, 'style, cat');
        return '/new.png';
      }));
      container.dispose();
      container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(database)]);
      final message =
          await store().loadFrontendMessageById('m', conversationId: 'a');
      expect(message!.images.first.localPath, '/new.png');
      expect(message.images.first.generationSnapshot!.steps, 31);
      expect(message.images.first.generationSnapshot!.width, 1024);
      expect(message.images.last.localPath, '/other.png');
      expect(message.displayText, '保留文字');
      expect(message.createdAt.millisecondsSinceEpoch, 10);
      if (projected) {
        final raw =
            await store().loadMessageById('raw', preferProjection: false);
        expect(raw!.content, '原始模型回答');
        expect(
            (await store()
                    .loadFrontendMessageById('sibling', conversationId: 'a'))!
                .content,
            '保留后续回复');
      }
    });
  }
  test('真实拆分图片气泡重画后重新加载仍只有目标图改变', () async {
    await seed();
    final projected = await store()
        .loadFrontendMessageById('m__proj_01_image', conversationId: 'a');
    expect(projected, isNotNull);
    await action((_, __) async => '/new.png').regenerate(
        conversationId: 'a',
        messageId: projected!.id,
        blockId: projected.images.single.id);
    container.dispose();
    container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)]);
    final rebuilt = await store()
        .loadFrontendMessageById(projected.id, conversationId: 'a');
    expect(rebuilt!.images.single.localPath, '/new.png');
    final other = await store()
        .loadFrontendMessageById('m__proj_02_image', conversationId: 'a');
    expect(other!.images.single.localPath, '/other.png');
    final raw = await store().loadMessageById('m', preferProjection: false);
    expect(raw!.images.first.localPath, '/new.png');
    expect(raw.images.last.localPath, '/other.png');
  });
  for (final projected in [false, true]) {
    test('保存失败不发布新图且事务回滚 projected=$projected', () async {
      await seed(projected: projected);
      await database.customStatement(
          "CREATE TRIGGER fail_image_write BEFORE UPDATE ON messages BEGIN SELECT RAISE(ABORT, 'disk failure'); END");
      await expectLater(
          run(action((_, __) async => '/new.png')), throwsA(anything));
      expect(
          (await store().loadFrontendMessageById('m', conversationId: 'a'))!
              .images
              .first
              .localPath,
          '/old.png');
      container.dispose();
      container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(database)]);
      expect(
          (await store().loadFrontendMessageById('m', conversationId: 'a'))!
              .images
              .first
              .localPath,
          '/old.png');
    });
  }
  test('无提示词图片和发送期间不调用供应商', () async {
    await store().updateMessage(
        conversationId: 'a',
        message: Message.fromBlocks(
            id: 'm',
            role: 'assistant',
            createdAt: DateTime(2026),
            blocks: [
              ImageBlock(id: 'image', messageId: 'm', localPath: '/upload.png')
            ]));
    await expectLater(
        run(action((_, __) async => fail('不可调用供应商'))), throwsStateError);
    await seed();
    await expectLater(
        run(ChatMediaRegeneration(
            store: store(),
            generators: {
              RegeneratableMediaKind.image:
                  _ImageGenerator((_, __) async => fail('不可调用供应商'))
            },
            isSending: (_) => true)),
        throwsStateError);
  });
  test('同一源图出现两次时只替换选中的第二处原始附件', () async {
    final base = imageMessage();
    await store().updateMessage(
        conversationId: 'a',
        message: base.copyWith(blocks: [
          base.blocks!.first,
          base.images.first,
          ImageBlock(
              id: 'duplicate',
              messageId: 'm',
              localPath: '/old.png',
              prompt: 'style, cat'),
        ]));
    final selected = (await store()
        .loadFrontendMessageById('m__proj_02_image', conversationId: 'a'))!;
    await action((_, __) async => '/new.png').regenerate(
        conversationId: 'a',
        messageId: selected.id,
        blockId: selected.images.single.id);
    final raw = (await store().loadMessageById('m', preferProjection: false))!;
    expect(raw.images.map((b) => b.localPath), ['/old.png', '/new.png']);
  });

  test('真实重画适配器向本机HTTP发送原提示词和单张参数，供应商失败保留旧图', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <Map<String, dynamic>>[];
    server.listen((request) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response.statusCode = 400;
      request.response.write('{"error":"offline fixture"}');
      await request.response.close();
    });
    const model = 'nai-diffusion-5-full';
    final settings = mapUiModelsToAppSettings({})
        .copyWith(imageGenerationEnabled: true, modelTypes: {
      'local:$model': 'image'
    }, modelProviderMap: {
      'local:$model': 'local'
    }, providers: [
      ProviderAuth(
          id: 'local',
          apiKeys: ['test-only'],
          apiBaseUrl: 'http://127.0.0.1:${server.port}',
          models: [model],
          visibleModels: [model],
          capabilities: ['image'],
          customConfig: const {'requestFormat': 'novelai'})
    ]);
    const config = ImageConfig(
        selectedProviderId: 'local',
        selectedModelId: 'local:$model',
        defaultCount: 4,
        defaultSteps: 23,
        defaultWidth: 768,
        defaultHeight: 1024,
        artistPresets: [
          ArtistPreset(name: 'style', content: 'new style', negativeContent: 'blur')
        ],
        selectedArtistPresetName: 'style');
    SharedPreferences.setMockInitialValues({
      PreferencesDrawingPresetStore.storageKey:
          jsonEncode(DrawingPresetCatalog.migrate(config).toJson())
    });
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      appSettingsProvider.overrideWith(() => _ImageSettings(settings))
    ]);
    await seed();
    final original = imageMessage();
    await store().updateMessage(
        conversationId: 'a',
        message: original.copyWith(blocks: [
          ImageBlock.fromJson({
            ...original.images.first.toJson(),
            'generationSnapshot': {
              'version': 1,
              'providerId': 'local',
              'modelId': model,
              'requestProvider': 'novelai',
              'prompt': 'style, cat',
              'negativePrompt': 'original negative',
              'basePrompt': 'cat',
              'baseNegativePrompt': 'original negative',
              'width': 1024,
              'height': 768,
              'steps': 31,
              'guidanceScale': 6.5,
              'customParameters': <String, dynamic>{},
            }
          }),
        ]));

    await HttpOverrides.runWithHttpOverrides(() async {
      await expectLater(
          container.read(chatMediaRegenerationProvider).regenerate(
              conversationId: 'a', messageId: 'm', blockId: 'image'),
          throwsStateError);
    }, _LocalHttpOverrides());
    expect(bodies, hasLength(1));
    expect(bodies.single['input'], 'new style, cat');
    final parameters = bodies.single['parameters'] as Map;
    expect(parameters['n_samples'], 1);
    expect(parameters['steps'], 31);
    expect(parameters['width'], 1024);
    expect(parameters['height'], 768);
    expect(parameters['scale'], 6.5);
    expect(parameters['negative_prompt'], 'blur, original negative');
    expect((parameters['v4_prompt'] as Map)['caption']['base_caption'], 'new style, cat');
    expect((parameters['v4_negative_prompt'] as Map)['caption']['base_caption'], 'blur, original negative');
    expect(
        (await store().loadFrontendMessageById('m', conversationId: 'a'))!
            .images
            .first
            .localPath,
        '/old.png');
  });

  test('失败保留原图，释放锁后允许重试', () async {
    await seed();
    var attempts = 0;
    final operation = action((_, __) async {
      if (++attempts == 1) throw StateError('provider failure');
      return '/retry.png';
    });
    await expectLater(run(operation), throwsStateError);
    expect(
        (await store().loadFrontendMessageById('m', conversationId: 'a'))!
            .images
            .first
            .localPath,
        '/old.png');
    await run(operation);
    expect(attempts, 2);
  });
  test('重复点击只调用一次生成', () async {
    await seed();
    final started = Completer<void>();
    final result = Completer<String>();
    var calls = 0;
    final operation = action((_, __) {
      calls++;
      started.complete();
      return result.future;
    });
    final first = run(operation);
    await started.future;
    await expectLater(run(operation), throwsStateError);
    result.complete('/new.png');
    await first;
    expect(calls, 1);
  });
  for (final change in ['hidden', 'deleted', 'changed']) {
    test('生成期间消息$change时拒绝迟到结果', () async {
      await seed();
      await expectLater(run(action((_, __) async {
        if (change == 'hidden') {
          await store().hideMessagesInFrontendTimeline('a', ['m']);
        } else if (change == 'deleted') {
          await store().softDeleteMessages('a', ['m']);
        } else {
          await store().updateMessage(
              conversationId: 'a',
              message: imageMessage().copyWith(content: '新版本'));
        }
        return '/late.png';
      })), throwsStateError);
    });
  }
  test('拒绝用户图片与跨角色请求', () async {
    await seed(role: 'user');
    final operation = action((_, __) async => fail('不得调用供应商'));
    await expectLater(run(operation), throwsStateError);
    await expectLater(
        operation.regenerate(
            conversationId: 'b', messageId: 'm', blockId: 'image'),
        throwsStateError);
  });
}
