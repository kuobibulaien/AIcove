import 'dart:convert';
import 'dart:io';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    hide ApiCallResult;
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_reply_display_transform.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/builtin_prompt_packs.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/image_plugin_detail_page.dart';

class _DecimalToolClient extends AgentApiClient {
  int calls = 0;
  @override
  Future<SendMessageRichResult> sendMessageRich({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    double? topP,
    String? token,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async => SendMessageRichResult(
    text: 'done',
    toolResults: const [],
    toolCalls: calls++ == 0
        ? [
            const ToolCall(
              id: 'decimal',
              name: 'draw_image',
              arguments: {
                'prompt': 'cat',
                'width': 1000.4,
                'height': 999.9,
                'count': 1.2,
                'steps': 35.5,
                'guidance_scale': 15,
              },
            ),
          ]
        : const [],
  );
}

class _LocalHttpOverrides extends HttpOverrides {}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

AppSettings _buildImageSettings({CallFlowMode mode = CallFlowMode.call}) {
  const modelRef = 'openai:test-image-model';
  return AppSettings(
    ttsEnabled: false,
    defaultModelName: modelRef,
    defaultPersonaPrompt: '',
    modelList: <String>[modelRef],
    allKnownModels: <String>[modelRef],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{
      modelRef: 'image',
      'test-image-model': 'image',
    },
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: true,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[
      const ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
        models: <String>['test-image-model'],
        visibleModels: <String>['test-image-model'],
        capabilities: <String>['image'],
      ),
    ],
    modelProviderMap: <String, String>{
      modelRef: 'openai',
      'test-image-model': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: const MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: <String>[modelRef],
    callFlowSettings: CallFlowSettings(mode: mode),
  );
}

AppSettings _buildHiddenOnlyImageSettings() {
  const modelRef = 'openai:hidden-image-model';
  return const AppSettings(
    ttsEnabled: false,
    defaultModelName: modelRef,
    defaultPersonaPrompt: '',
    modelList: <String>[modelRef],
    allKnownModels: <String>[modelRef],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{
      modelRef: 'image',
      'hidden-image-model': 'image',
    },
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: true,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
        models: <String>['hidden-image-model'],
        visibleModels: <String>[],
        hiddenModels: <String>['hidden-image-model'],
        capabilities: <String>['image'],
      ),
    ],
    modelProviderMap: <String, String>{
      modelRef: 'openai',
      'hidden-image-model': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: <String>[modelRef],
    callFlowSettings: CallFlowSettings(mode: CallFlowMode.call),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('image plugin should not inject hidden routing system prompt', () async {
    const config = ImageConfig();
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(_buildImageSettings()),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final pluginProvider = Provider<ImagePlugin>((ref) {
      return ImagePlugin(config, ref);
    });
    final plugin = container.read(pluginProvider);

    final prompt = plugin.buildTagSemanticsPrompt();

    expect(prompt, isNull);
    expect(plugin.getTools().map((tool) => tool.name), contains('draw_image'));
  });

  test(
    'image plugin should inject inline <image> prompt in fast mode',
    () async {
      const config = ImageConfig();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              _buildImageSettings(mode: CallFlowMode.fast),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);

      final pluginProvider = Provider<ImagePlugin>((ref) {
        return ImagePlugin(config, ref);
      });
      final plugin = container.read(pluginProvider);

      final prompt = plugin.buildTagSemanticsPrompt();

      // An OpenAI-compatible unknown model gets the natural-language pack.
      expect(prompt, isNotNull);
      expect(prompt, contains('<image>画面描述</image>'));
      expect(prompt, contains('自然语言'));
      expect(prompt, isNot(contains('NovelAI')));
      expect(plugin.getTools(), isEmpty);
    },
  );

  test(
    'image plugin should parse non-empty <image> tag into generation event',
    () async {
      const config = ImageConfig();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              _buildImageSettings(mode: CallFlowMode.fast),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);

      final pluginProvider = Provider<ImagePlugin>((ref) {
        return ImagePlugin(config, ref);
      });
      final plugin = container.read(pluginProvider);

      final result = plugin.convertInlineImageTags(
        '前文 <image>1girl, cat ears, masterpiece</image> 后文',
      );

      expect(result.processedText, '前文 后文');
      expect(result.events, hasLength(1));
      expect(result.events.single.type, 'image_generate');
      expect(
        result.events.single.data['prompt'],
        '1girl, cat ears, masterpiece',
      );

      final emptyTagResult = plugin.convertInlineImageTags('<image></image>');
      expect(emptyTagResult.events, isEmpty);
      expect(emptyTagResult.processedText, '<image></image>');
    },
  );

  test('display source ignores draft character table inside thinking', () {
    final source = AssistantReplyDisplaySource('''
<comic_plan>
- 角色母表:
  - C1:
    - 固定外貌词: silver hair
    - 当前服装词: blue dress
</comic_plan>
<think><comic_plan>
- 角色母表:
  - C1:
    - 固定身份词: draft
</comic_plan></think>
<image>@C1, @C1_outfit</image>
''');
    expect(source.text, contains('<image>silver hair, blue dress</image>'));
    expect(source.text, isNot(contains('draft')));
  });

  test(
    'duplicate explicit slot IDs advance past reserved and assigned IDs',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final plugin = container.read(
        Provider(
          (ref) => ImagePlugin(
            const ImageConfig(),
            ref,
            requestSettings: _buildImageSettings(mode: CallFlowMode.fast),
          ),
        ),
      );
      final result = plugin.convertInlineImageTags(
        '<image>{"id":2,"prompt":"first"}</image>'
        '<image>{"id":"2","prompt":"second"}</image>'
        '<image>{"id":3,"prompt":"third"}</image>'
        '<image>last</image>',
      );
      expect(result.events.map((e) => e.data['id']), [2, 4, 3, 1]);
    },
  );

  test('tool mode keeps parameterized anchors but still converts MOSS', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final plugin = container.read(
      Provider(
        (ref) => ImagePlugin(
          const ImageConfig(),
          ref,
          requestSettings: _buildImageSettings(),
        ),
      ),
    );
    const anchors =
        '<image>{"id":"2"}</image>'
        '<image>{"id":3,"prompt":""}</image>'
        '<image>{"id":"4","width":512,"steps":31}</image>';
    final result = plugin.convertInlineImageTags(anchors);
    expect(result.processedText, anchors);
    expect(result.events, isEmpty);
    final moss = plugin.convertInlineImageTags(
      '<image>{"id":5,"layout":"balanced_1","items":[{"panel":1}],"width":512}</image>',
    );
    expect(
      jsonDecode(moss.events.single.data['prompt'] as String)['width'],
      512,
    );
  });

  test(
    'MOSS inline parameters survive conversion, snapshot and generation',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final settings = _buildImageSettings(mode: CallFlowMode.fast);
      final comfy = container.read(
        Provider(
          (ref) => ImagePlugin(
            const ImageConfig(),
            ref,
            requestSettings: settings.copyWith(
              providers: [
                settings.providers.single.copyWith(
                  models: ['moss.safetensors'],
                  visibleModels: ['moss.safetensors'],
                  customConfig: {'requestFormat': 'comfyui'},
                ),
              ],
              modelTypes: {'openai:moss.safetensors': 'image'},
            ),
          ),
        ),
      );
      final input = jsonEncode({
        'id': 5,
        'layout': 'balanced_2',
        'summary': {'caption': 'scene'},
        'items': [
          {'panel': 1, 'slot': 'S', 'caption': 'cat'},
        ],
        'width': 512,
        'height': 768,
        'steps': 31,
        'guidance_scale': 6,
        'negative_prompt': 'noise',
        'count': 2,
      });
      final event = comfy
          .convertInlineImageTags('<image>$input</image>')
          .events
          .single;
      final eventPrompt = event.data['prompt'] as String;
      final eventObject = jsonDecode(eventPrompt) as Map;
      expect(eventObject.containsKey('id'), isFalse);
      expect(eventObject['steps'], 31);
      final snapshot = comfy.buildPendingSnapshot(prompt: eventPrompt)!;
      expect(
        (
          snapshot.width,
          snapshot.height,
          snapshot.steps,
          snapshot.guidanceScale,
        ),
        (512, 768, 31, 6.0),
      );
      expect(snapshot.negativePrompt, 'noise');
      final clean = jsonDecode(snapshot.prompt) as Map;
      expect(clean.keys, unorderedEquals(['layout', 'summary', 'items']));
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        final graph = body['prompt'] as Map;
        Map node(String type) =>
            graph.values.firstWhere(
                  (node) => node['class_type'] == type,
                )['inputs']
                as Map;
        expect(node('EmptyLatentImage')['width'], 512);
        expect(node('EmptyLatentImage')['height'], 768);
        expect(node('EmptyLatentImage')['batch_size'], 2);
        expect(node('KSampler')['steps'], 31);
        expect(node('KSampler')['cfg'], 6);
        final captions = graph.values
            .where((node) => node['class_type'] == 'CLIPTextEncode')
            .map((node) => node['inputs']['text'] as String)
            .toList();
        expect(captions, contains('noise'));
        final compiled =
            jsonDecode(captions.firstWhere((text) => text.startsWith('{')))
                as Map;
        expect(compiled.containsKey('steps'), isFalse);
        return http.Response('{"error":"offline fixture"}', 400);
      });
      addTearDown(client.close);
      final result = await http.runWithClient(
        () => comfy.generateInlineImage(prompt: eventPrompt),
        () => client,
      );
      expect(result.success, isFalse);
      expect(result.error, contains('400'));
      expect(result.generationSnapshot!.steps, 31);
      final other = container.read(
        Provider(
          (ref) =>
              ImagePlugin(const ImageConfig(), ref, requestSettings: settings),
        ),
      );
      expect(
        (await other.generateInlineImage(prompt: input)).error,
        'MOSS 多格漫画排版仅支持 ComfyUI 渠道',
      );
    },
  );

  test('MOSS metadata is removed before direct generation', () async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            _buildImageSettings(mode: CallFlowMode.fast),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    final plugin = container.read(
      Provider<ImagePlugin>((ref) => ImagePlugin(const ImageConfig(), ref)),
    );
    final event = plugin
        .convertInlineImageTags(
          '<image>{"id":5,"layout":"grid","summary":{},"items":[{"panel":1}]}</image>',
        )
        .events
        .single;
    expect(event.data['id'], 5);
    expect(jsonDecode(event.data['prompt'] as String), {
      'layout': 'grid',
      'summary': {},
      'items': [
        {'panel': 1},
      ],
    });
  });

  test('tool mode preserves numbered image anchors', () async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(_buildImageSettings()),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    final provider = Provider<ImagePlugin>(
      (ref) => ImagePlugin(const ImageConfig(), ref, isRequestSnapshot: true),
    );
    const text = '前<image>{"id": 2}</image>后';
    final result = container.read(provider).convertInlineImageTags(text);
    expect(result.processedText, text);
    expect(result.events, isEmpty);
  });

  test(
    'the request prompt pack decides the fast-mode text, not old presets',
    () async {
      const config = ImageConfig(
        fastPromptPresets: <DrawingPromptPreset>[
          DrawingPromptPreset(name: '快速预设', content: '旧的快速模式规则'),
        ],
        selectedFastPromptPresetName: '快速预设',
      );
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              _buildImageSettings(mode: CallFlowMode.fast),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final pack = PromptPackLibrary(builtins: kBuiltinPromptPacks).resolve(
        'image',
        const PresetPromptBinding(packId: 'builtin.image.novelai'),
        format: 'openai',
        model: 'hidden-image-model',
      );

      final pluginProvider = Provider<ImagePlugin>((ref) {
        return ImagePlugin(config, ref, isRequestSnapshot: true, prompts: pack);
      });
      final prompt = container.read(pluginProvider).buildTagSemanticsPrompt();

      expect(prompt, contains('提示词规范（NovelAI）'));
      expect(prompt, contains('"width":832'));
      expect(prompt, isNot(contains('旧的快速模式规则')));
    },
  );

  test('image config should preserve fast prompt preset selection', () {
    const preset = DrawingPromptPreset(name: '快速预设', content: '快速模式模板内容');
    final config = ImageConfig(
      fastPromptPresets: const <DrawingPromptPreset>[preset],
      selectedFastPromptPresetName: preset.name,
    );

    final restored = ImageConfig.fromJson(config.toJson());

    expect(restored.fastPromptPresets, hasLength(1));
    expect(restored.selectedFastPromptPreset?.name, preset.name);
    expect(restored.effectiveInlinePromptTemplate, '快速模式模板内容');
  });

  test(
    'image plugin should ignore hidden image models when resolving tools',
    () async {
      const config = ImageConfig();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(_buildHiddenOnlyImageSettings()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);

      final pluginProvider = Provider<ImagePlugin>(
        (ref) => ImagePlugin(config, ref),
      );
      final plugin = container.read(pluginProvider);

      expect(plugin.getTools(), isEmpty);
    },
  );

  test(
    'request image plugin freezes schema, style and deferred event configuration',
    () async {
      final settings = _buildImageSettings().copyWith(
        providers: const [
          ProviderAuth(
            id: 'openai',
            apiKeys: ['test-key'],
            apiBaseUrl: 'https://invalid.example',
            models: ['test-image-model'],
            visibleModels: ['test-image-model'],
            capabilities: ['image'],
            customConfig: {'requestFormat': 'novelai'},
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(settings),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      const config = ImageConfig(
        selectedProviderId: 'openai',
        selectedModelId: 'openai:test-image-model',
        defaultSteps: 23,
        defaultGuidanceScale: 7,
      );
      final plugin = container.read(
        Provider(
          (ref) => ImagePlugin(
            config,
            ref,
            requestSettings: settings,
            isRequestSnapshot: true,
          ),
        ),
      );
      final tool = plugin.getTools().single;
      expect(
        tool.parameters.keys,
        containsAll(['steps', 'guidance_scale', 'count']),
      );
      expect(tool.description, contains('参考 23'));
      expect(tool.parameters['width']!.required, isFalse);
      expect(tool.parameters['prompt']!.required, isTrue);
      expect(tool.parameters.keys, isNot(contains('status')));
      expect(tool.parameters.keys, isNot(contains('summary')));
      final empty = jsonDecode((await tool.handler({'id': 1}))!);
      expect(empty['success'], isFalse);
      expect(empty['error'], 'prompt is empty');
      final events = plugin
          .convertInlineImageTags('<image>{"prompt":"cat","steps":35}</image>')
          .events;
      expect((events.single.data['drawingConfig'] as Map)['defaultSteps'], 23);
      expect(events.single.data['prompt'], contains('35'));
      final result = jsonDecode(
        (await tool.handler({'prompt': 'cat', 'steps': 'abc'}))!,
      );
      expect(result['success'], false);
      expect(result['error'], contains('steps'));
    },
  );

  test(
    'tool and inline requests use preset channels and override only allowed parameters',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final bodies = <Map<String, dynamic>>[];
      final keys = <String?>[];
      server.listen((request) async {
        bodies.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        keys.add(request.headers.value('authorization'));
        request.response.statusCode = 400; // 只核验请求，不生成图片或写用户文件。
        request.response.write('{"error":"offline fixture"}');
        await request.response.close();
      });
      const model = 'nai-diffusion-5-full';
      final settings = _buildImageSettings().copyWith(
        modelTypes: {'a:$model': 'image', 'b:$model': 'image'},
        modelProviderMap: {'a:$model': 'a', 'b:$model': 'b'},
        providers: [
          for (final id in ['a', 'b'])
            ProviderAuth(
              id: id,
              apiKeys: ['key-$id'],
              apiBaseUrl: 'http://127.0.0.1:${server.port}',
              models: [model],
              visibleModels: [model],
              capabilities: ['image'],
              customConfig: const {'requestFormat': 'novelai'},
            ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(settings),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      ImagePlugin pluginFor(String id) => container.read(
        Provider(
          (ref) => ImagePlugin(
            ImageConfig(
              selectedProviderId: id,
              selectedModelId: '$id:$model',
              defaultSteps: 23,
              defaultGuidanceScale: id == 'b' ? 15 : 7,
              artistPresets: [ArtistPreset(name: id, content: 'style-$id')],
              selectedArtistPresetName: id,
            ),
            ref,
            requestSettings: settings,
            isRequestSnapshot: true,
          ),
        ),
      );
      final a = pluginFor('a');
      final b = pluginFor('b');
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = _DecimalToolClient();
        final result =
            await KernelApiRunner.withAgentClientFactory(
              agentClientFactory: (_) => client,
            ).executeApiCall(
              config: ApiConfig(
                settings: settings,
                modelFullId: 'openai:test',
                providerApiBase: 'https://invalid.test',
                providerApiKey: 'test',
                customConfig: const {},
                messages: const [
                  {'role': 'user', 'content': 'draw'},
                ],
              ),
              sessionId: 'owner',
              userText: 'draw',
              responseProcessors: const [],
              availableTools: a.getTools(),
            );
        expect(
          result.rawToolResults.single.result,
          isNot(contains('invalid_tool_arguments')),
        );
        await b.generateInlineImage(
          prompt: '{"prompt":"dog","steps":30,"width":768,"height":1024}',
        );
        await a.generateInlineImage(prompt: '{{{pov}}}, cat');
        await a.generateInlineImage(
          prompt: '''
@page
comic, 1girl, 2 panels, text, chinese text
@panel P1
wide shot, 横書き, 한국어
Text: 净善宫的夜里
@character C1
girl, nahida_(genshin_impact), 縦書き
Text: 又是这个梦……
@negative
adult body, blonde hair
''',
        );
      }, _LocalHttpOverrides());
      expect(bodies, hasLength(4));
      expect(keys, [
        'Bearer key-a',
        'Bearer key-b',
        'Bearer key-a',
        'Bearer key-a',
      ]);
      expect(bodies[2]['input'], 'style-a, {{{pov}}}, cat');
      final comicParams = bodies[3]['parameters'] as Map<String, dynamic>;
      final v4Caption = (comicParams['v4_prompt'] as Map)['caption'] as Map;
      final v4NegCaption =
          (comicParams['v4_negative_prompt'] as Map)['caption'] as Map;
      expect(
        v4Caption['base_caption'],
        'style-a, comic, 1girl, 2 panels, text, chinese text, wide shot, 横書き, 한국어\nText: 净善宫的夜里',
      );
      expect(
        (v4Caption['char_captions'] as List).single['char_caption'],
        'girl, nahida_(genshin_impact), 縦書き\nText: 又是这个梦……',
      );
      expect(
        (v4NegCaption['char_captions'] as List).single['char_caption'],
        'adult body, blonde hair',
      );
      expect(bodies[0]['input'], 'style-a, cat');
      expect(bodies[1]['input'], 'style-b, dog');
      final first = bodies[0]['parameters'] as Map;
      final second = bodies[1]['parameters'] as Map;
      expect(
        [first['width'], first['height'], first['steps'], first['scale']],
        [1024, 1024, 36, 10],
      );
      expect(
        [second['width'], second['height'], second['steps'], second['scale']],
        [768, 1024, 30, 10],
      );
      final event = a
          .convertInlineImageTags('<image>cat</image>')
          .events
          .single;
      expect((event.data['drawingConfig'] as Map)['defaultSteps'], 23);
    },
  );

  test(
    'no usable image channel: request snapshot offers no tool or prompt',
    () async {
      // Fresh install: drawing is on globally, but no provider has image models.
      final settings = _buildImageSettings(
        mode: CallFlowMode.fast,
      ).copyWith(providers: const <ProviderAuth>[]);
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(settings),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      ImagePlugin snapshot(ImageConfig config, AppSettings s) => container.read(
        Provider(
          (ref) => ImagePlugin(
            config,
            ref,
            requestSettings: s,
            isRequestSnapshot: true,
          ),
        ),
      );

      final unconfigured = snapshot(const ImageConfig(), settings);
      expect(unconfigured.isUsable, isFalse);
      expect(unconfigured.getTools(), isEmpty);
      expect(unconfigured.buildRequestSystemPrompt(useFastRoute: true), isNull);

      // A configured channel makes it usable again.
      final configured = snapshot(const ImageConfig(), _buildImageSettings());
      expect(configured.isUsable, isTrue);
      expect(configured.getTools(), hasLength(1));

      // An explicit binding that broke stays usable, so the draw fails loudly
      // instead of silently doing nothing.
      final broken = snapshot(
        const ImageConfig(
          selectedProviderId: 'missing',
          selectedModelId: 'missing:x',
        ),
        settings,
      );
      expect(broken.isUsable, isTrue);
    },
  );

  test(
    'explicit missing provider/model fails without fallback or network request',
    () async {
      final settings = _buildImageSettings();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(settings),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      for (final config in [
        const ImageConfig(
          selectedProviderId: 'missing',
          selectedModelId: 'missing:x',
        ),
        const ImageConfig(
          selectedProviderId: 'openai',
          selectedModelId: 'openai:missing',
        ),
      ]) {
        final plugin = container.read(
          Provider(
            (ref) => ImagePlugin(
              config,
              ref,
              requestSettings: settings,
              isRequestSnapshot: true,
            ),
          ),
        );
        final result = jsonDecode(
          (await plugin.runDrawImageToolForDebug(prompt: 'cat'))!,
        );
        expect(result['success'], false);
        expect(result['error'], contains('no configured image provider/model'));
      }
      final conflicting = container.read(
        Provider(
          (ref) => ImagePlugin(
            const ImageConfig(
              selectedProviderId: 'missing',
              selectedModelId: 'openai:test-image-model',
            ),
            ref,
          ),
        ),
      );
      expect(conflicting.getTools(), isEmpty);
    },
  );

  testWidgets(
    'image settings page should only list visible image-tagged models',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'aicove.ui_models.v1': jsonEncode(<String, dynamic>{
          'providers': [
            {
              'id': 'mixed',
              'displayName': '混合渠道',
              'apiKeys': <String>['test-key'],
              'apiBaseUrl': 'https://example.com/v1',
              'enabled': true,
              'models': <String>['chat-model', 'visible-image', 'hidden-image'],
              'visible_models': <String>['chat-model', 'visible-image'],
              'hidden_models': <String>['hidden-image'],
              'capabilities': <String>['chat', 'image'],
            },
          ],
          'model_types': <String, String>{
            'mixed:visible-image': 'image',
            'mixed:hidden-image': 'image',
          },
          'model_display_names': <String, String>{
            'mixed:chat-model': '对话模型',
            'mixed:visible-image': '可用生图模型',
            'mixed:hidden-image': '隐藏生图模型',
          },
          'default_model': 'mixed:chat-model',
          'default_chat_models': <String>['mixed:chat-model'],
          'visible_models': <String>['mixed:chat-model'],
          'image_generation_enabled': true,
        }),
        'aicove.plugins.image.config': jsonEncode(<String, dynamic>{
          'selectedModelId': 'mixed:hidden-image',
        }),
      });

      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ImagePluginDetailPage())),
      );

      await tester.pumpAndSettle();

      expect(find.text('绘图预设'), findsOneWidget);
      await tester.tap(find.text('默认绘图').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('渠道与模型'));
      await tester.pumpAndSettle();

      expect(find.text('可用生图模型'), findsOneWidget);
      expect(find.text('隐藏生图模型'), findsNothing);
      expect(find.text('对话模型'), findsNothing);
    },
  );
}
