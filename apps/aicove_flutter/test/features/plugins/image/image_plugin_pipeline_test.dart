import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/models/image_generation_snapshot.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late AppSettings settings;
  const config = ImageConfig(
    selectedProviderId: 'local',
    selectedModelId: 'local:image',
    defaultNegativePrompt: 'blur',
    artistPresets: [
      ArtistPreset(
        name: 'style',
        content: 'artist',
        negativeContent: 'bad artist',
      ),
    ],
    selectedArtistPresetName: 'style',
  );

  ImagePlugin plugin({ImageConfig drawing = config, AppSettings? current}) =>
      container.read(
        Provider(
          (ref) => ImagePlugin(
            drawing,
            ref,
            requestSettings: current ?? settings,
            isRequestSnapshot: true,
          ),
        ),
      );

  Future<void> stubImageStorage() async {
    final output = await Directory(
      'build',
    ).createTemp('image-plugin-pipeline-');
    addTearDown(() => output.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => output.absolute.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    addTearDown(container.dispose);
    settings = mapUiModelsToAppSettings({}).copyWith(
      imageGenerationEnabled: true,
      modelTypes: {'local:image': 'image'},
      modelProviderMap: {'local:image': 'local'},
      providers: [
        const ProviderAuth(
          id: 'local',
          apiKeys: ['fixture-secret'],
          apiBaseUrl: 'https://local.test/v1',
          models: ['image'],
          visibleModels: ['image'],
          capabilities: ['image'],
        ),
      ],
    );
  });

  test(
    'only first eight closed inline images generate and all excess tags are stripped',
    () {
      final image = plugin();
      final result = image.convertInlineImageTags(
        'before\n${List.generate(10, (i) => '<image>page-$i</image>').join('\n')}\nafter',
      );
      expect(ImagePlugin.maxInlineImagesPerTurn, 8);
      expect(
        result.events.map((event) => event.data['prompt']),
        List.generate(8, (i) => 'page-$i'),
      );
      expect(result.processedText, 'before\n\nafter');
      expect(
        image.convertInlineImageTags('<image>next round</image>').events,
        hasLength(1),
      );
    },
  );

  test('history image tags and unclosed tags do not consume the inline cap', () {
    final result = plugin().convertInlineImageTags(
      '<image source="history">old</image>'
      '${List.generate(8, (i) => '<image>page-$i</image>').join()}<image>unfinished',
    );
    expect(result.events, hasLength(8));
    expect(
      result.processedText,
      contains('<image source="history">old</image>'),
    );
    expect(result.processedText, contains('<image>unfinished'));
  });

  test(
    'pending snapshot captures style, normalized parameters and no credentials',
    () {
      final snapshot = plugin().buildPendingSnapshot(
        prompt:
            '{"prompt":"cat","width":512,"height":768,"negative_prompt":"noise"}',
      )!;
      expect(snapshot.basePrompt, 'cat');
      expect(snapshot.prompt, 'artist, cat');
      expect(snapshot.negativePrompt, 'bad artist, blur, noise');
      expect(snapshot.baseNegativePrompt, 'blur, noise');
      expect((snapshot.width, snapshot.height), (512, 768));
      expect((snapshot.providerId, snapshot.modelId), ('local', 'image'));
      final encoded = jsonEncode(snapshot.toJson());
      expect(encoded, isNot(contains('fixture-secret')));
      expect(encoded, isNot(contains('local.test')));
    },
  );

  test('漫画模式清理画师词并保存在待生成快照', () {
    final image = container.read(Provider((ref) => ImagePlugin(
      const ImageConfig(
        selectedProviderId: 'local', selectedModelId: 'local:image',
        defaultNegativePrompt: 'text, watermark, screentone',
        artistPresets: [ArtistPreset(name: 'style', content: '<artist>, solo, 0.7::close-up::, no text', negativeContent: 'text, halftone, lowres')],
        selectedArtistPresetName: 'style',
      ), ref, requestSettings: settings, isRequestSnapshot: true, postProcessor: 'novelai_manga',
    )));
    final snapshot = image.buildPendingSnapshot(prompt: '@page\nmanga\n@panel 1\n1girl, 1boy\n@panel 2\nclose up')!;
    expect(snapshot.postProcessor, 'novelai_manga');
    expect(snapshot.prompt, isNot(contains('solo')));
    expect(snapshot.prompt, isNot(contains('no text')));
    expect(snapshot.negativePrompt, 'lowres, watermark');
    expect(snapshot.baseNegativePrompt, 'watermark');
    expect(ImageGenerationSnapshot.tryRead(snapshot.toJson()), snapshot);
    expect(snapshot.copyWith(postProcessor: 'plain').postProcessor, 'plain');
    final event = image.convertInlineImageTags('<image>test</image>').events.single;
    expect(event.data['drawingConfig']['postProcessor'], 'novelai_manga');
  });

  test('missing target and malformed arguments have no replay snapshot', () {
    expect(
      plugin(
        drawing: const ImageConfig(selectedProviderId: 'missing'),
      ).buildPendingSnapshot(prompt: 'cat'),
      isNull,
    );
    expect(
      plugin().buildPendingSnapshot(prompt: '{"prompt":"cat","width":"oops"}'),
      isNull,
    );
    expect(plugin().buildPendingSnapshot(prompt: '{"prompt":"cat"'), isNull);
  });

  test(
    'network failure retains the prepared snapshot and estimated dimensions',
    () async {
      final image = plugin();
      const prompt = '{"prompt":"cat","width":512,"height":768}';
      final before = image.buildPendingSnapshot(prompt: prompt)!;
      final client = MockClient(
        (_) async => http.Response('{"error":"fixture failed"}', 400),
      );
      addTearDown(client.close);
      final result = await http.runWithClient(
        () => image.generateInlineImage(prompt: prompt),
        () => client,
      );
      expect(result.success, isFalse);
      expect(result.error, contains('400'));
      expect(result.rawPrompt, 'cat');
      expect((result.width, result.height), (512, 768));
      expect(result.generationSnapshot!.toJson(), before.toJson());
      expect(result.localPaths, isEmpty);
    },
  );

  test(
    'regeneration override reapplies style once and saves new base and dimensions',
    () async {
      await stubImageStorage();
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'data': [
              {
                'b64_json': base64Encode([1, 2, 3]),
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      final original = plugin().buildPendingSnapshot(
        prompt: '{"prompt":"cat","width":512,"height":768}',
      )!;
      await http.runWithClient(() async {
        for (final override in <String?>[
          null,
          '  dog  ',
          '{"prompt":"spread","width":1216,"height":832}',
        ]) {
          final result = await plugin().regenerateImage(
            original,
            overrideBasePrompt: override,
          );
          expect(result.success, isTrue);
          final expected = override == null
              ? 'cat'
              : override.contains('spread')
              ? 'spread'
              : 'dog';
          expect(result.rawPrompt, expected);
          expect(result.prompt, 'artist, $expected');
          expect(result.generationSnapshot!.basePrompt, expected);
          expect((
            result.generationSnapshot!.width,
            result.generationSnapshot!.height,
          ), expected == 'spread' ? (1216, 832) : (512, 768));
        }
      }, () => client);
      expect(requests.map((request) => request['n']), [1, 1, 1]);
      expect(requests.map((request) => request['size']), [
        '512x768',
        '512x768',
        '1216x832',
      ]);
      expect(original.basePrompt, 'cat');
    },
  );
  test(
    'persisted blank storyboard snapshot can be redrawn with a custom prompt',
    () async {
      await stubImageStorage();
      final image = plugin();
      final pending = image.buildPendingSnapshot(
        prompt: '{"id":2,"status":"pending","width":512,"height":768}',
        allowEmptyPrompt: true,
      )!;
      final restored = ImageGenerationSnapshot.tryRead(
        jsonDecode(jsonEncode(pending.toJson())),
      )!;
      expect(restored.basePrompt, '');
      await expectLater(
        image.regenerateImage(restored),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '该图片尚未生成分镜提示词，请长按选择「改词重画」输入画面描述',
          ),
        ),
      );
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'data': [
              {
                'b64_json': base64Encode([1, 2, 3]),
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      final result = await http.runWithClient(
        () => image.regenerateImage(restored, overrideBasePrompt: 'beach'),
        () => client,
      );
      expect(result.success, isTrue);
      expect(result.generationSnapshot!.basePrompt, 'beach');
      expect(requests.single['prompt'], 'artist, beach');
      expect(requests.single['size'], '512x768');
    },
  );

  test(
    'spread keywords orient edited portrait pages without changing canvas area',
    () async {
      await stubImageStorage();
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'data': [
              {
                'b64_json': base64Encode([1, 2, 3]),
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      final image = plugin();
      final original = image.buildPendingSnapshot(
        prompt: '{"prompt":"cat","width":512,"height":768}',
      )!;
      await http.runWithClient(() async {
        for (final keyword in [
          '見開きページ',
          '2ページ見開き',
          '見開き',
          'double-page spread',
          '2-page spread',
          'WIDE SPREAD',
          '跨页',
          '跨頁',
          '双页',
          '雙頁',
          '双开',
          '雙開',
        ]) {
          final result = await image.regenerateImage(
            original,
            overrideBasePrompt: '$keyword, cat',
          );
          expect(requests.last['size'], '768x512', reason: keyword);
          expect(
            (
              result.generationSnapshot!.width,
              result.generationSnapshot!.height,
            ),
            (768, 512),
          );
        }
        final cases = <(ImageGenerationSnapshot, String?, String)>[
          (original, null, '512x768'),
          (original, 'cat in a garden', '512x768'),
          (original, '{"prompt":"跨页","width":512,"height":1024}', '512x1024'),
          (original, '{"prompt":"跨页","width":1024,"height":512}', '1024x512'),
          (original, '{"prompt":"跨页","height":1024}', '512x1024'),
          (
            ImageGenerationSnapshot.tryRead({
              ...original.toJson(),
              'width': 768,
              'height': 512,
            })!,
            '跨页',
            '768x512',
          ),
          (
            ImageGenerationSnapshot.tryRead({
              ...original.toJson(),
              'width': 512,
              'height': 512,
            })!,
            '跨页',
            '512x512',
          ),
          (
            ImageGenerationSnapshot.tryRead({
              ...original.toJson(),
              'basePrompt': '跨页',
            })!,
            null,
            '512x768',
          ),
        ];
        for (final (snapshot, override, size) in cases) {
          final result = await image.regenerateImage(
            snapshot,
            overrideBasePrompt: override,
          );
          expect(requests.last['size'], size, reason: override);
          expect(
            '${result.generationSnapshot!.width}x${result.generationSnapshot!.height}',
            size,
          );
        }
      }, () => client);
    },
  );

  test(
    'MOSS inline, enveloped, tool and regeneration prompts retain JSON and artist style',
    () async {
      await stubImageStorage();
      const model = 'template/moss_image';
      final current = settings.copyWith(
        providers: [
          settings.providers.single.copyWith(
            models: [model],
            visibleModels: [model],
            customConfig: {'requestFormat': 'comfyui'},
          ),
        ],
        modelTypes: {'local:$model': 'image'},
        modelProviderMap: {'local:$model': 'local'},
      );
      final drawing = config.copyWith(
        selectedModelId: 'local:$model',
        defaultWidth: 1088,
        defaultHeight: 1920,
      );
      final image = plugin(drawing: drawing, current: current);
      final object = <String, dynamic>{
        'layout': 'balanced_2',
        'summary': {'caption': 'Travel manga', 'note': 'retain'},
        'items': [
          {
            'panel': 1,
            'slot': 'S',
            'label': 'character',
            'caption': 'Traveler',
          },
          {'panel': 2, 'slot': 'T', 'label': 'text', 'text': '到家了'},
        ],
      };
      final symbolic = jsonEncode(object);
      final before = image.buildPendingSnapshot(prompt: symbolic)!;
      expect(before.basePrompt, symbolic);
      expect(
        jsonDecode(before.prompt)['summary']['caption'],
        'artist, Travel manga',
      );
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{"prompt_id":"job"}', 200);
        }
        if (request.url.path.contains('/history/')) {
          return http.Response(
            jsonEncode({
              'job': {
                'status': {'completed': true, 'status_str': 'success'},
                'outputs': {
                  '9': {
                    'images': [
                      {'filename': 'manga.png', 'type': 'output'},
                    ],
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response.bytes([1, 2, 3], 200);
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        for (final input in [
          symbolic,
          jsonEncode({'prompt': symbolic, 'width': 1088, 'height': 1920}),
        ]) {
          final result = await image.generateInlineImage(prompt: input);
          expect(result.success, isTrue, reason: result.error);
          expect(result.generationSnapshot!.basePrompt, symbolic);
          expect(
            jsonDecode(result.prompt!)['summary']['caption'],
            'artist, Travel manga',
          );
          expect(jsonDecode(result.prompt!)['items'], object['items']);
        }
        final toolResult =
            jsonDecode(
                  (await image.runDrawImageToolForDebug(prompt: symbolic))!,
                )
                as Map;
        expect(toolResult['success'], isTrue);
        expect(
          jsonDecode(toolResult['prompt'])['summary']['caption'],
          'artist, Travel manga',
        );
        final restyled = plugin(
          current: current,
          drawing: drawing.copyWith(
            artistPresets: [
              const ArtistPreset(name: 'next', content: 'new artist'),
            ],
            selectedArtistPresetName: 'next',
          ),
        );
        final edited = jsonEncode({
          ...object,
          'summary': {'caption': 'New story', 'note': 'retain'},
        });
        final result = await restyled.regenerateImage(
          before,
          overrideBasePrompt: edited,
        );
        expect(result.success, isTrue, reason: result.error);
        expect(result.generationSnapshot!.basePrompt, edited);
        expect(
          jsonDecode(result.prompt!)['summary']['caption'],
          'new artist, New story',
        );
        expect(jsonDecode(result.prompt!)['items'], object['items']);
      }, () => client);
      expect(requests, hasLength(4));
      for (var i = 0; i < requests.length; i++) {
        final compiled = jsonDecode(requests[i]['prompt']) as Map;
        expect(compiled['summary']['caption'], startsWith('Page frame guide:'));
        expect(
          compiled['summary']['caption'],
          endsWith(i == 3 ? 'new artist, New story' : 'artist, Travel manga'),
        );
        expect(compiled['summary']['note'], 'retain');
        expect(compiled['items'][0]['bbox'], isList);
        expect(compiled['items'][1]['text'], '到家了');
      }
    },
  );

  test(
    'non-ComfyUI rejects MOSS while ordinary ComfyUI JSON keeps the artist prefix',
    () async {
      final symbolic = jsonEncode({
        'layout': 'balanced_1',
        'summary': {'caption': 'story'},
        'items': [
          {'panel': 1, 'slot': 'S', 'caption': 'cat'},
        ],
      });
      final ordinary = jsonEncode({
        'layout': 'balanced_1',
        'items': [
          {'caption': 'cat'},
        ],
      });
      final image = plugin();
      expect(image.buildPendingSnapshot(prompt: symbolic), isNull);
      final wrapped = jsonEncode({'prompt': symbolic});
      final snapshot = image.buildPendingSnapshot(prompt: wrapped)!;
      expect(snapshot.prompt, 'artist, $symbolic');
      final comfySettings = settings.copyWith(
        providers: [
          settings.providers.single.copyWith(
            customConfig: {'requestFormat': 'comfyui'},
          ),
        ],
      );
      final ordinarySnapshot = plugin(
        current: comfySettings,
      ).buildPendingSnapshot(prompt: jsonEncode({'prompt': ordinary}))!;
      expect(ordinarySnapshot.prompt, 'artist, $ordinary');
      var requests = 0;
      final client = MockClient((request) async {
        requests += 1;
        return http.Response('{"error":"unexpected network request"}', 400);
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        for (final input in [symbolic, wrapped]) {
          final result = await image.generateInlineImage(prompt: input);
          expect(result.success, isFalse);
          expect(result.error, 'MOSS 多格漫画排版仅支持 ComfyUI 渠道');
          expect(result.generationSnapshot, isNull);
          expect(result.localPaths, isEmpty);
          expect(requests, 0);
        }
      }, () => client);
    },
  );
  test(
    'NovelAI replays resolved dimensions without overriding explicit portrait edits',
    () async {
      const model = 'nai-diffusion-5-full';
      final current = settings.copyWith(
        providers: [
          settings.providers.single.copyWith(
            models: [model],
            visibleModels: [model],
            customConfig: {'requestFormat': 'novelai'},
          ),
        ],
        modelTypes: {'local:$model': 'image'},
        modelProviderMap: {'local:$model': 'local'},
      );
      final image = plugin(
        current: current,
        drawing: config.copyWith(selectedModelId: 'local:$model'),
      );
      final original = image.buildPendingSnapshot(
        prompt: '{"prompt":"cat","width":512,"height":768}',
      )!;
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{"error":"fixture failed"}', 400);
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        for (final (override, width, height) in <(String?, int, int)>[
          (null, 512, 768),
          ('見開き, cat', 768, 512),
          ('跨页, cat', 768, 512),
          (
            '{"prompt":"double-page spread, cat","width":512,"height":1024}',
            512,
            1024,
          ),
        ]) {
          await expectLater(
            image.regenerateImage(original, overrideBasePrompt: override),
            throwsA(isA<Exception>()),
          );
          final parameters = requests.last['parameters'] as Map;
          expect(
            (parameters['width'], parameters['height']),
            (width, height),
            reason: override,
          );
        }
      }, () => client);
    },
  );
}
