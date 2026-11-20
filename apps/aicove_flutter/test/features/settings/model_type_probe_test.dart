import 'dart:convert';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/observability/usage/model_pricing_catalog.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_model_probe.dart';
import 'package:aicove_flutter/src/features/settings/settings_models.dart';
import 'package:aicove_flutter/src/features/settings/ui_models_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 1x1 transparent PNG
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

AppSettings _settingsWith(ProviderAuth provider) => AppSettings(
  ttsEnabled: true,
  defaultModelName: '',
  defaultPersonaPrompt: '',
  modelList: const <String>[],
  allKnownModels: const <String>[],
  modelDisplayNames: const <String, String>{},
  modelTypes: const <String, String>{},
  modelConfigs: const <String, ModelConfig>{},
  apiKey: '',
  apiBaseUrl: '',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  contextWindowTokens: 272000,
  customModels: const <CustomModel>[],
  providers: [provider],
  modelProviderMap: const <String, String>{},
  backendApiKey: '',
  messageChunkingEnabled: true,
  messageFormatConfig: const MessageFormatConfig(
    enableChunking: true,
    chunkPunctuations: <String>['。'],
    minSegmentLength: 1,
  ),
  textScaleFactor: 1.0,
  uiScaleFactor: 1.0,
  imagePreviewScale: 1.0,
  autoReplySettings: const AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: true,
  accentColor: 'FC96AA',
  hideUserAvatar: false,
  defaultChatModels: const <String>[],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetModelPricingCachesForTesting();
  });
  tearDown(resetModelPricingCachesForTesting);

  test(
    'preview reads standard per-token prices and skips placeholders',
    () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://openrouter.ai/api/v1/models');
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'vendor/channel-model',
                'pricing': {
                  'prompt': '0.00000125',
                  'completion': '0.00001',
                  'input_cache_read': '0.0000005',
                  'input_cache_write': '0',
                },
              },
              {
                'id': 'vendor/cache-write-model',
                'pricing': {
                  'prompt': 0,
                  'completion': 0,
                  'input_cache_write': 0,
                },
              },
              {
                'id': 'openrouter/auto',
                'pricing': {'prompt': '-1', 'completion': '-1'},
              },
              {
                'id': 'bad-high',
                'pricing': {'prompt': 0.050001, 'completion': 0},
              },
              {
                'id': 'bad-completion',
                'pricing': {'prompt': 0, 'completion': 'Infinity'},
              },
              {
                'id': 'missing-completion',
                'pricing': {'prompt': 0},
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      final models = await UiModelsApi(httpClient: client).previewProvider(
        providerId: 'openrouter',
        apiKey: 'test',
        apiBaseUrl: 'https://openrouter.ai/api/v1',
      );
      expect(models, hasLength(6));

      ModelPricing? price(String id) =>
          lookupBuiltinModelPricing(id, providerId: 'openrouter');
      final channel = price('Vendor/Channel_Model:exacto')!;
      expect(channel.inputPricePerMillion, 1.25);
      expect(channel.outputPricePerMillion, 10);
      expect(channel.cachedInputPricePerMillion, .5);
      expect(channel.cacheWritePricePerMillion, isNull);
      expect(channel.currency, 'USD');
      expect(price('cache-write-model')!.cacheWritePricePerMillion, 0);
      expect(
        lookupBuiltinModelPricing('channel-model', providerId: 'other'),
        isNull,
      );
      for (final id in [
        'openrouter/auto',
        'bad-high',
        'bad-completion',
        'missing-completion',
      ]) {
        expect(price(id), isNull, reason: id);
      }

      // Allow the preview's asynchronous preferences write to complete.
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(
              prefs.getString(
                'aicove.observability.provider_pricing_cache.v1',
              )!,
            )
            as Map,
        contains('openrouter:channel-model'),
      );
      resetModelPricingCachesForTesting();
      expect(price('channel-model'), isNull);
      await ModelPricingCatalog.loadLocalCaches();
      expect(price('channel-model')!.inputPricePerMillion, 1.25);
    },
  );

  test('image model test generates through the image endpoint', () async {
    final requests = <http.Request>[];
    final api = UiModelsApi(
      httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response(
          jsonEncode({
            'data': [
              {'b64_json': _png},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await api.testModel(
      providerId: 'openai',
      apiKey: 'sk-test',
      apiBaseUrl: 'https://img.example.com/v1',
      modelId: 'gpt-image-1',
      modelType: ModelType.image,
    );

    expect(result, contains('生图成功'));
    expect(requests.single.url.path, '/v1/images/generations');
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body['model'], 'gpt-image-1');
    expect(body['n'], 1);
  });

  test('image model test surfaces upstream errors as failure', () async {
    final api = UiModelsApi(
      httpClient: MockClient((_) async => http.Response('bad model', 404)),
    );
    expect(
      api.testModel(
        providerId: 'openai',
        apiKey: 'sk-test',
        apiBaseUrl: 'https://img.example.com/v1',
        modelId: 'missing',
        modelType: ModelType.image,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('tts model test synthesizes a short line via the speech endpoint',
      () async {
    const provider = ProviderAuth(
      id: 'speech_relay',
      apiKeys: ['sk-test'],
      apiBaseUrl: 'https://tts.example.com/v1',
      models: ['tts-1'],
      visibleModels: ['tts-1'],
      capabilities: ['tts'],
    );
    final requests = <http.Request>[];
    final result = await http.runWithClient(
      () => TtsModelProbe.run(
        settings: _settingsWith(provider),
        provider: provider,
        apiKey: 'sk-test',
        modelId: 'tts-1',
      ),
      () => MockClient((req) async {
        requests.add(req);
        return http.Response.bytes(
          List<int>.filled(64, 1),
          200,
          headers: {'content-type': 'audio/mpeg'},
        );
      }),
    );

    expect(result, contains('语音合成成功'));
    final speech = requests.singleWhere(
      (r) => r.url.path.endsWith('/audio/speech'),
    );
    final body = jsonDecode(speech.body) as Map<String, dynamic>;
    expect(body['model'], 'tts-1');
    expect(body['input'], TtsModelProbe.probeText);
  });
}
