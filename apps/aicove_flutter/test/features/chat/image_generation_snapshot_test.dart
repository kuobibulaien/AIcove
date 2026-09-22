import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/drift.dart' show Value;
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:drift/native.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_media_regeneration.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_content.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

class _Settings extends AppSettingsNotifier {
  _Settings(this.value);
  final AppSettings value;
  @override
  Future<AppSettings> build() async => value;
  void replace(AppSettings value) => state = AsyncData(value);
}

class _Http extends HttpOverrides {}

class _DrawingStore implements DrawingPresetStore {
  _DrawingStore(this.catalog);
  DrawingPresetCatalog catalog;
  @override
  Future<DrawingPresetCatalog> load() async => catalog;
  @override
  Future<void> save(DrawingPresetCatalog value) async => catalog = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late db.AppDatabase database;
  late ProviderContainer container;
  late HttpServer server;
  late AppSettings settings;
  late _DrawingStore drawingStore;
  final bodies = <Map<String, dynamic>>[];
  const png =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJ1kAAAAASUVORK5CYII=';
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    bodies.clear();
    drawingStore = _DrawingStore(DrawingPresetCatalog.migrate(const ImageConfig(
      artistPresets: [
        ArtistPreset(
            name: 'old',
            content: 'old style',
            negativeContent: 'old style negative')
      ],
      selectedArtistPresetName: 'old',
    )));
    temporary = await Directory.systemTemp.createTemp('image-snapshot-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temporary.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'data': [
          {'b64_json': png}
        ]
      }));
      await request.response.close();
    });
    settings = mapUiModelsToAppSettings({})
        .copyWith(imageGenerationEnabled: true, modelTypes: {
      'local:original': 'image',
      'local:new-default': 'image'
    }, modelProviderMap: {
      'local:original': 'local',
      'local:new-default': 'local'
    }, providers: [
      ProviderAuth(
          id: 'local',
          apiKeys: ['test-key'],
          apiBaseUrl: 'http://127.0.0.1:${server.port}',
          models: ['original', 'new-default'],
          visibleModels: ['original', 'new-default'],
          capabilities: ['image'],
          customConfig: const {
            'requestFormat': 'openai',
            'image_parameters': {'quality': 'hd', 'n': 3},
            'privateCredential': 'never-copy-this',
          })
    ]);
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.into(database.conversations).insert(
        db.ConversationsCompanion.insert(
            id: 'owner',
            title: 'owner',
            displayName: 'owner',
            createdAt: 0,
            updatedAt: 0));
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      drawingPresetStoreProvider.overrideWithValue(drawingStore),
      appSettingsProvider.overrideWith(() => _Settings(settings)),
    ]);
    await container.read(appSettingsProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    await temporary.delete(recursive: true);
  });
  ImagePlugin plugin() => container.read(Provider((ref) => ImagePlugin(
      const ImageConfig(
          selectedProviderId: 'local',
          selectedModelId: 'local:original',
          defaultWidth: 768,
          defaultHeight: 1024,
          defaultNegativePrompt: 'old negative',
          artistPresets: [
            ArtistPreset(
                name: 'old',
                content: 'old style',
                negativeContent: 'old style negative')
          ],
          selectedArtistPresetName: 'old'),
      ref,
      isRequestSnapshot: true)));

  for (final mode in ['inline', 'tool', 'async', 'legacy']) {
    test(
        '$mode stores original parameters and replays after defaults change and DB reload',
        () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        ImageGenerationSnapshot? snapshot;
        String? path;
        if (mode == 'inline' || mode == 'legacy') {
          final result = await plugin().generateInlineImage(
              prompt: jsonEncode({
            'prompt': 'cat',
            'width': 1024,
            'height': 768,
            'negative_prompt': 'runtime negative'
          }));
          expect(result.success, true, reason: result.error);
          snapshot = result.generationSnapshot;
          path = result.localPath;
        } else {
          final result = jsonDecode((await plugin().getTools().single.handler({
            'prompt': 'cat',
            'width': 1024,
            'height': 768,
            'negative_prompt': 'runtime negative',
            if (mode == 'async') ...{
              '_aicove_async': true,
              '_aicove_session_id': 'owner'
            },
          }))!) as Map;
          expect(result['success'], true);
          if (mode == 'async') {
            for (var i = 0; i < 200; i++) {
              final rows = await database.select(database.messages).get();
              if (rows.isNotEmpty) {
                final message = await container
                    .read(chatHistoryStoreProvider)
                    .loadMessageById(rows.first.id, preferProjection: false);
                snapshot = message!.images.single.generationSnapshot;
                path = message.images.single.localPath;
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
          } else {
            final image = (result['images'] as List).single as Map;
            snapshot =
                ImageGenerationSnapshot.tryRead(image['generationSnapshot']);
            path = image['localPath'] as String;
          }
        }
        expect(snapshot, isNotNull);
        expect(snapshot!.width, 1024);
        expect(snapshot.height, 768);
        expect(snapshot.prompt, 'old style, cat');
        expect(snapshot.negativePrompt,
            'old style negative, old negative, runtime negative');
        expect(snapshot.basePrompt, 'cat');
        expect(snapshot.baseNegativePrompt, 'old negative, runtime negative');
        if (mode == 'legacy') {
          snapshot = ImageGenerationSnapshot.tryRead(snapshot.toJson()
            ..remove('basePrompt')
            ..remove('baseNegativePrompt'))!;
        }
        expect(
            jsonEncode(snapshot.toJson()), isNot(contains('never-copy-this')));
        final block = ImageBlock(
            id: 'img',
            messageId: 'message',
            localPath: path,
            prompt: snapshot.prompt,
            generationSnapshot: snapshot);
        // Both raw blocks and encoded plugin content must survive serialization.
        final payload =
            ChatMessageProjectionCodec.copyWithPluginContents(null, [
          PluginImageContent(path!,
              caption: snapshot.prompt, generationSnapshot: snapshot)
        ]);
        expect(
            ChatMessageProjectionCodec.pluginContents(payload)
                .whereType<PluginImageContent>()
                .single
                .generationSnapshot!
                .toJson(),
            snapshot.toJson());
        await container.read(chatHistoryStoreProvider).updateMessage(
            conversationId: 'owner',
            message: Message.fromBlocks(
                id: 'message', role: 'assistant', blocks: [block]));
        container.dispose();
        drawingStore.catalog = drawingStore.catalog
            .upsert(const DrawingPreset(
              id: 'new-style',
              name: 'new-style',
              config: ImageConfig(
                defaultWidth: 256,
                defaultHeight: 256,
                defaultSteps: 23,
                defaultNegativePrompt: 'changed base negative',
                artistPresets: [
                  ArtistPreset(
                      name: 'new',
                      content: 'new style',
                      negativeContent: 'new style negative')
                ],
                selectedArtistPresetName: 'new',
              ),
            ))
            .withDefault('new-style');
        final changed = settings.copyWith(providers: [
          settings.providers.single.copyWith(customConfig: {
            'requestFormat': 'openai',
            'defaultImageModel': 'new-default',
            'image_parameters': {
              'quality': 'standard',
              'size': '256x256',
              'n': 4
            }
          })
        ]);
        container = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(database),
          drawingPresetStoreProvider.overrideWithValue(drawingStore),
          appSettingsProvider.overrideWith(() => _Settings(changed))
        ]);
        await container.read(appSettingsProvider.future);
        await container.read(chatMediaRegenerationProvider).regenerate(
            conversationId: 'owner', messageId: 'message', blockId: 'img');
        expect(bodies.last['model'], 'original');
        expect(bodies.last['size'], '1024x768');
        expect(bodies.last['quality'], 'hd');
        expect(bodies.last['prompt'], 'new style, cat');
        expect(bodies.last['negative_prompt'],
            'new style negative, old negative, runtime negative');
        expect(bodies.last['n'], 1);
        final reloaded = await container
            .read(chatHistoryStoreProvider)
            .loadMessageById('message', preferProjection: false);
        expect(reloaded!.images.single.generationSnapshot!.width, 1024);
        expect(reloaded.images.single.prompt, 'new style, cat');
        expect(reloaded.images.single.generationSnapshot!.basePrompt, 'cat');
        final catalog = container.read(drawingPresetCatalogProvider.notifier);
        // Editing the same preset and then disabling it must never accumulate
        // previous positive or negative artist strings, even after DB reload.
        for (final artist in [
          const ArtistPreset(
              name: 'third',
              content: 'third style',
              negativeContent: 'third negative'),
          null,
        ]) {
          await catalog.savePreset(DrawingPreset(
              id: 'new-style',
              name: 'edited',
              config: ImageConfig(
                  artistPresets: artist == null ? const [] : [artist],
                  selectedArtistPresetName: artist?.name,
                  defaultNegativePrompt:
                      'do not replace the original base negative')));
          await container.read(chatMediaRegenerationProvider).regenerate(
              conversationId: 'owner', messageId: 'message', blockId: 'img');
          expect(bodies.last['prompt'],
              artist == null ? 'cat' : 'third style, cat');
          expect(
              bodies.last['negative_prompt'],
              artist == null
                  ? 'old negative, runtime negative'
                  : 'third negative, old negative, runtime negative');
          expect(bodies.last['size'], '1024x768');
          expect(bodies.last['quality'], 'hd');
        }
        final count = bodies.length;
        (container.read(appSettingsProvider.notifier) as _Settings)
            .replace(changed.copyWith(providers: []));
        await expectLater(
            container.read(chatMediaRegenerationProvider).regenerate(
                conversationId: 'owner', messageId: 'message', blockId: 'img'),
            throwsStateError);
        expect(bodies.length, count);
      }, _Http());
    });
  }
  test(
      'regeneration resolves the persisted owner binding instead of the default',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final original = await plugin().generateInlineImage(prompt: 'cat');
      await container.read(chatHistoryStoreProvider).updateMessage(
          conversationId: 'owner',
          message: Message.fromBlocks(id: 'bound', role: 'assistant', blocks: [
            ImageBlock(
                id: 'img',
                messageId: 'bound',
                prompt: original.prompt,
                localPath: original.localPath,
                generationSnapshot: original.generationSnapshot)
          ]));
      final catalog = container.read(drawingPresetCatalogProvider.notifier);
      await catalog.savePreset(const DrawingPreset(
          id: 'bound-style',
          name: 'bound',
          config: ImageConfig(artistPresets: [
            ArtistPreset(name: 'bound', content: 'bound style')
          ], selectedArtistPresetName: 'bound')));
      await (database.update(database.conversations)
            ..where((r) => r.id.equals('owner')))
          .write(db.ConversationsCompanion(
              personaPrompt: Value(PersonaPromptCodec.compose(
                  userPrompt: '', drawingPresetId: 'bound-style'))));
      await container.read(chatMediaRegenerationProvider).regenerate(
          conversationId: 'owner', messageId: 'bound', blockId: 'img');
      expect(bodies.last['prompt'], 'bound style, cat');
      await (database.update(database.conversations)
            ..where((r) => r.id.equals('owner')))
          .write(db.ConversationsCompanion(
              personaPrompt: Value(PersonaPromptCodec.compose(
                  userPrompt: '', drawingPresetId: 'missing'))));
      final count = bodies.length;
      await expectLater(
          container.read(chatMediaRegenerationProvider).regenerate(
              conversationId: 'owner', messageId: 'bound', blockId: 'img'),
          throwsStateError);
      expect(bodies.length, count);
    }, _Http());
  });

  test('unknown legacy artist is rejected without mixing old and new styles',
      () async {
    const snapshot = ImageGenerationSnapshot(
        providerId: 'local',
        modelId: 'original',
        requestProvider: 'openai',
        prompt: 'unknown style, cat',
        negativePrompt: null,
        width: 1024,
        height: 768,
        steps: 31,
        guidanceScale: 6.5);
    await container.read(chatHistoryStoreProvider).updateMessage(
        conversationId: 'owner',
        message: Message.fromBlocks(id: 'unknown', role: 'assistant', blocks: [
          ImageBlock(
              id: 'img',
              messageId: 'unknown',
              prompt: snapshot.prompt,
              localPath: '/old.png',
              generationSnapshot: snapshot)
        ]));
    await expectLater(
        container.read(chatMediaRegenerationProvider).regenerate(
            conversationId: 'owner', messageId: 'unknown', blockId: 'img'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'reason', contains('分离信息'))));
    expect(bodies, isEmpty);
    expect(
        (await container
                .read(chatHistoryStoreProvider)
                .loadMessageById('unknown', preferProjection: false))!
            .images
            .single
            .localPath,
        '/old.png');
  });

  for (final overridden in [false, true]) {
    test('saved prompt overrides cannot hide the artist change: $overridden',
        () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final snapshot = ImageGenerationSnapshot(
            providerId: 'local',
            modelId: 'original',
            requestProvider: 'openai',
            prompt: 'old style, cat',
            negativePrompt: 'old style negative, base',
            basePrompt: 'cat',
            baseNegativePrompt: 'base',
            width: 1024,
            height: 768,
            steps: 31,
            guidanceScale: 6.5,
            customParameters: {
              'prompt': overridden ? 'different subject' : 'old style, cat',
              'negative_prompt': 'old style negative, base',
            });
        final stylePlugin = container.read(Provider((ref) => ImagePlugin(
            const ImageConfig(
                selectedProviderId: 'local',
                selectedModelId: 'original',
                artistPresets: [
                  ArtistPreset(
                      name: 'new',
                      content: 'new style',
                      negativeContent: 'new negative')
                ],
                selectedArtistPresetName: 'new'),
            ref,
            isRequestSnapshot: true)));
        if (overridden) {
          await expectLater(
              stylePlugin.regenerateImage(snapshot), throwsStateError);
          expect(bodies, isEmpty);
        } else {
          final result = await stylePlugin.regenerateImage(snapshot);
          expect(result.success, true);
          expect(bodies.single['prompt'], 'new style, cat');
          expect(bodies.single['negative_prompt'], 'new negative, base');
          expect(result.generationSnapshot!.customParameters['prompt'],
              'new style, cat');
        }
      }, _Http());
    });
  }

  test(
      'snapshot survives supplemental projection and rejects unknown or unsafe metadata',
      () {
    const snapshot = ImageGenerationSnapshot(
        providerId: 'local',
        modelId: 'original',
        requestProvider: 'openai',
        prompt: 'cat',
        negativePrompt: 'old',
        width: 1024,
        height: 768,
        steps: 31,
        guidanceScale: 6.5,
        customParameters: {'quality': 'hd'});
    final payload =
        ChatMessageProjectionCodec.copyWithSupplementInsertOps(null, [
      const StoredSupplementInsertOp(
          kind: 'image',
          textCharsBefore: 3,
          forceAppendToTail: false,
          localPath: '/old.png',
          prompt: 'cat',
          generationSnapshot: snapshot)
    ]);
    expect(
        ChatMessageProjectionCodec.supplementInsertOps(payload)
            .single
            .generationSnapshot!
            .toJson(),
        snapshot.toJson());
    expect(
        ImageGenerationSnapshot.tryRead({...snapshot.toJson(), 'version': 2}),
        isNull);
    expect(
        ImageGenerationSnapshot.tryRead({
          ...snapshot.toJson(),
          'customParameters': {'api_key': 'secret'}
        }),
        isNull);
    expect(
        ImageGenerationSnapshot.tryRead(
            {...snapshot.toJson(), 'steps': double.nan}),
        isNull);
  });
  test('legacy image has no complete snapshot and does not call provider',
      () async {
    await container.read(chatHistoryStoreProvider).updateMessage(
        conversationId: 'owner',
        message: Message.fromBlocks(id: 'legacy', role: 'assistant', blocks: [
          ImageBlock(
              id: 'image',
              messageId: 'legacy',
              localPath: '/old.png',
              prompt: 'cat')
        ]));
    await expectLater(
        container.read(chatMediaRegenerationProvider).regenerate(
            conversationId: 'owner', messageId: 'legacy', blockId: 'image'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('未保存完整生成参数'))));
    expect(bodies, isEmpty);
  });
}
