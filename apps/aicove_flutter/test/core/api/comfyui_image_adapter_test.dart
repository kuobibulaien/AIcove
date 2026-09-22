import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/image_providers/comfyui_image_adapter.dart';
import 'package:aicove_flutter/src/core/api/image_providers/comfyui_workflow.dart';
import 'package:aicove_flutter/src/core/api/image_providers/image_provider_adapter.dart';
import 'package:aicove_flutter/src/features/settings/ui_models_api.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/models/image_generation_snapshot.dart';

Map<String, dynamic> config() => {
  'requestFormat': 'comfyui',
  'comfyWorkflow': {
    '6': {
      'class_type': 'CLIPTextEncode',
      'inputs': {
        'text': 'old prompt',
        'clip': ['4', 1],
      },
    },
    '7': {
      'class_type': 'CLIPTextEncode',
      'inputs': {'text': 'bad'},
    },
    '5': {
      'class_type': 'EmptyLatentImage',
      'inputs': {'width': 512, 'height': 512, 'batch_size': 1},
    },
    '3': {
      'class_type': 'KSampler',
      'inputs': {
        'seed': 1,
        'steps': 20,
        'cfg': 7,
        'positive': ['6', 0],
      },
    },
    '9': {
      'class_type': 'SaveImage',
      'inputs': {
        'images': ['8', 0],
      },
    },
  },
  'comfyBindings': {
    'prompt': '6.text',
    'negative_prompt': '7.text',
    'width': '5.width',
    'seed': '3.seed',
  },
};

ImageProviderRequest request({
  Map<String, dynamic>? customConfig,
  String key = '',
}) => ImageProviderRequest(
  provider: 'comfyui',
  model: ComfyUIWorkflow.modelId,
  prompt: 'cat "rain"\nnew line',
  width: 768,
  height: 1024,
  count: 1,
  baseUrl: 'http://localhost:8188/proxy/',
  apiKey: key,
  customConfig: customConfig ?? config(),
  seed: 42,
);

http.Response json(Object value) => http.Response(jsonEncode(value), 200);

Map<String, dynamic> finished({bool error = false, bool empty = false}) => {
  'job': {
    'status': {
      'status_str': error ? 'error' : 'success',
      'completed': true,
      'messages': [],
    },
    'outputs': empty
        ? {}
        : {
            '8': {
              'images': [
                {'filename': 'preview.png', 'subfolder': '', 'type': 'temp'},
              ],
            },
            '9': {
              'images': [
                {
                  'filename': 'a & b.png',
                  'subfolder': 'test folder',
                  'type': 'output',
                },
              ],
            },
          },
  },
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'explicit format wins and credential-bearing workflow cannot enter history',
    () {
      expect(
        ComfyUIWorkflow.isProvider('comfyui', {'requestFormat': 'openai'}),
        false,
      );
      final value = config();
      final snapshot = {
        'version': 1,
        'providerId': 'local',
        'modelId': ComfyUIWorkflow.modelId,
        'requestProvider': 'comfyui',
        'prompt': 'cat',
        'width': 768,
        'height': 1024,
        'steps': 20,
        'guidanceScale': 5.0,
        'customParameters': {
          'comfyWorkflow': value['comfyWorkflow'],
          'comfyBindings': value['comfyBindings'],
        },
      };
      expect(ImageGenerationSnapshot.tryRead(snapshot), isNotNull);
      value['comfyWorkflow']['6']['inputs']['api_key'] = 'never-store-this';
      expect(ImageGenerationSnapshot.tryRead(snapshot), isNull);
    },
  );

  test('bindings copy the graph and preserve unbound values and links', () {
    final original = config();
    final graph = ComfyUIWorkflow.build(original, {
      'prompt': 'new',
      'negative_prompt': '',
      'width': 768,
      'seed': 42,
    });
    expect(graph['6']['inputs']['text'], 'new');
    expect(graph['6']['inputs']['clip'], ['4', 1]);
    expect(graph['5']['inputs']['width'], 768);
    expect(graph['3']['inputs']['steps'], 20);
    expect(original['comfyWorkflow']['6']['inputs']['text'], 'old prompt');
  });

  test(
    'typed placeholders escape prompt text without replacing node links',
    () {
      final value = config();
      value['comfyBindings'] = {};
      value['comfyWorkflow']['6']['inputs']['text'] = 'portrait %prompt%';
      value['comfyWorkflow']['3']['inputs']['seed'] = '%seed%';
      final built = ComfyUIWorkflow.build(value, {
        'prompt': '"cat"\nnew',
        'seed': 900,
      });
      final roundtrip = jsonDecode(jsonEncode(built));
      expect(roundtrip['6']['inputs']['text'], 'portrait "cat"\nnew');
      expect(roundtrip['3']['inputs']['seed'], 900);
    },
  );

  test(
    'rejects canvas JSON, unbound prompts, stale and duplicate bindings',
    () {
      expect(() => ComfyUIWorkflow.parse({'nodes': []}), throwsFormatException);
      final value = config();
      value['comfyBindings'] = {};
      expect(() => ComfyUIWorkflow.validate(value), throwsFormatException);
      value['comfyBindings'] = {'prompt': 'missing.text'};
      expect(() => ComfyUIWorkflow.validate(value), throwsFormatException);
      value['comfyBindings'] = {
        'prompt': '6.text',
        'negative_prompt': '6.text',
      };
      expect(() => ComfyUIWorkflow.validate(value), throwsFormatException);
    },
  );

  test(
    'submit once, poll queued job, download output with encoded filename',
    () async {
      var polls = 0;
      var submissions = 0;
      final client = MockClient((req) async {
        expect(req.headers.containsKey('authorization'), false);
        if (req.method == 'POST') {
          submissions++;
          expect(req.url.path, '/proxy/prompt');
          final body = jsonDecode(req.body);
          expect(body['prompt']['6']['inputs']['text'], 'cat "rain"\nnew line');
          expect(body['prompt']['3']['inputs']['seed'], 42);
          return json({'prompt_id': 'job'});
        }
        if (req.url.path.contains('/history/')) {
          return json(++polls == 1 ? {} : finished());
        }
        expect(req.url.path, '/proxy/view');
        expect(req.url.queryParameters['filename'], 'a & b.png');
        expect(req.url.queryParameters['subfolder'], 'test folder');
        return http.Response.bytes([137, 80, 78, 71], 200);
      });
      final result =
          await const ComfyUIImageAdapter(pollInterval: Duration.zero).generate(
            client: client,
            timeout: const Duration(seconds: 1),
            request: request(),
          );
      expect(submissions, 1);
      expect(polls, 2);
      expect(result.images.single, [137, 80, 78, 71]);
    },
  );

  test('explicit output node and optional Bearer token are honored', () async {
    final value = config()..['comfyOutputNode'] = '9';
    final client = MockClient((req) async {
      expect(req.headers['authorization'], 'Bearer private-token');
      if (req.method == 'POST') return json({'prompt_id': 'job'});
      if (req.url.path.contains('history')) return json(finished());
      return http.Response.bytes([1], 200);
    });
    final result = await const ComfyUIImageAdapter().generate(
      client: client,
      timeout: const Duration(seconds: 1),
      request: request(customConfig: value, key: 'private-token'),
    );
    expect(result.images, hasLength(1));
  });

  for (final mode in [
    'rejected',
    'execution_error',
    'empty_output',
    'download_error',
  ]) {
    test(
      '$mode surfaces failure without resubmitting or changing providers',
      () async {
        var posts = 0;
        final client = MockClient((req) async {
          if (req.method == 'POST') {
            posts++;
            return mode == 'rejected'
                ? json({'error': 'bad node'})
                : json({'prompt_id': 'job'});
          }
          if (req.url.path.contains('history')) {
            return json(
              finished(
                error: mode == 'execution_error',
                empty: mode == 'empty_output',
              ),
            );
          }
          return http.Response('no image', 500);
        });
        await expectLater(
          const ComfyUIImageAdapter().generate(
            client: client,
            timeout: const Duration(seconds: 1),
            request: request(),
          ),
          throwsStateError,
        );
        expect(posts, 1);
      },
    );
  }

  test(
    'whole-job deadline stops polling without interrupting shared server',
    () async {
      final paths = <String>[];
      final client = MockClient((req) async {
        paths.add(req.url.path);
        return json(req.method == 'POST' ? {'prompt_id': 'job'} : {});
      });
      await expectLater(
        const ComfyUIImageAdapter(
          pollInterval: Duration(milliseconds: 5),
        ).generate(
          client: client,
          timeout: const Duration(milliseconds: 20),
          request: request(),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(paths.where((p) => p.endsWith('prompt')), hasLength(1));
      expect(paths.any((p) => p.contains('interrupt')), false);
    },
  );

  test(
    'AgentApiClient dispatches custom ComfyUI provider without a key',
    () async {
      final client = AgentApiClient(
        client: MockClient((req) async {
          if (req.method == 'POST') return json({'prompt_id': 'job'});
          if (req.url.path.contains('history')) return json(finished());
          return http.Response.bytes([1], 200);
        }),
      );
      final result = await client.generateImage(
        provider: 'custom-1',
        model: ComfyUIWorkflow.modelId,
        prompt: 'cat',
        providerApiBase: 'http://localhost:8188',
        customConfig: config(),
      );
      expect(result.provider, 'comfyui');
      expect(result.images, hasLength(1));
    },
  );

  test(
    'import persists keyless workflow as image model without /models request',
    () async {
      final api = UiModelsApi(
        httpClient: MockClient(
          (req) async => throw StateError('unexpected request'),
        ),
      );
      expect(
        await api.previewProvider(
          providerId: 'custom-1',
          apiKey: '',
          apiBaseUrl: 'http://localhost:8188',
          customConfig: config(),
        ),
        [ComfyUIWorkflow.modelId],
      );
      final stored = await api.importProvider(
        providerId: 'custom-1',
        apiKey: '',
        apiBaseUrl: 'http://localhost:8188',
        customConfig: config(),
      );
      final settings = mapUiModelsToAppSettings(stored);
      expect(
        settings.getProviderVisibleModelsByType(
          'custom-1',
          type: ModelType.image,
        ),
        [ComfyUIWorkflow.modelId],
      );
      final provider = settings.providers.firstWhere((p) => p.id == 'custom-1');
      expect(provider.apiKeys, isEmpty);
      expect(provider.customConfig['comfyWorkflow'], config()['comfyWorkflow']);
    },
  );

  test('connection test only GETs system_stats', () async {
    final api = UiModelsApi(
      httpClient: MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/system_stats');
        return json({
          'system': {'os': 'posix'},
        });
      }),
    );
    expect(
      await api.testModel(
        providerId: 'custom-1',
        apiKey: '',
        apiBaseUrl: 'http://localhost:8188',
        modelId: ComfyUIWorkflow.modelId,
        customConfig: config(),
      ),
      contains('未执行生图'),
    );
  });
}
