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
    'string workflows are normalized before checking snapshot credentials',
    () {
      final graph = config()['comfyWorkflow'];
      final value = {
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
          'comfyWorkflow': jsonEncode(graph),
          'comfyBindings': {'prompt': '6.text'},
        },
      };
      expect(
        ImageGenerationSnapshot.tryRead(
          value,
        )!.customParameters['comfyWorkflow'],
        isA<Map>(),
      );
      for (final key in ['api_key', 'token', 'secret']) {
        graph['6']['inputs'][key] = 'never-store-this';
        (value['customParameters'] as Map)['comfyWorkflow'] = jsonEncode(graph);
        expect(ImageGenerationSnapshot.tryRead(value), isNull);
        (graph['6']['inputs'] as Map).remove(key);
      }
    },
  );

  test('inference follows the saved image branch rather than graph order', () {
    Map<String, dynamic> branch(String prefix) =>
        ComfyUIWorkflow.buildStandardGraph(
          checkpoint: 'model.safetensors',
          values: {'prompt': prefix},
        ).map((id, node) {
          final inputs = Map<String, dynamic>.from(node['inputs'] as Map);
          for (final key in inputs.keys.toList()) {
            final value = inputs[key];
            if (value is List) {
              inputs[key] = ['$prefix${value.first}', value[1]];
            }
          }
          return MapEntry('$prefix$id', {...node, 'inputs': inputs});
        });
    final graph = {...branch('unused'), ...branch('saved')};
    graph.remove('unused9');
    final result = ComfyUIWorkflow.inferBindings(graph);
    expect(result.outputNode, 'saved9');
    expect(result.bindings['prompt'], 'saved6.text');
    expect(result.bindings['negative_prompt'], 'saved7.text');
    expect(result.bindings['seed'], 'saved3.seed');
    expect(result.bindings['width'], 'saved5.width');
  });

  test('inference preserves templates and skips SDXL dual text inputs', () {
    final graph = ComfyUIWorkflow.buildStandardGraph(
      checkpoint: 'model.safetensors',
      values: {
        'prompt': 'masterpiece, %prompt%',
        'negative_prompt': 'lowres, %negative_prompt%',
      },
    );
    final result = ComfyUIWorkflow.inferBindings(graph);
    expect(result.bindings.containsKey('prompt'), false);
    expect(result.bindings.containsKey('negative_prompt'), false);
    final built = ComfyUIWorkflow.build(
      {'comfyWorkflow': graph, 'comfyBindings': result.bindings},
      {'prompt': 'cat', 'negative_prompt': 'blurry'},
    );
    expect(built['6']['inputs']['text'], 'masterpiece, cat');
    expect(built['7']['inputs']['text'], 'lowres, blurry');

    graph['6'] = {
      'class_type': 'CLIPTextEncodeSDXL',
      'inputs': {'text_g': 'old global', 'text_l': 'old local'},
    };
    final dual = ComfyUIWorkflow.inferBindings(graph);
    expect(dual.bindings.containsKey('prompt'), false);
    expect(
      () => ComfyUIWorkflow.validate({
        'comfyWorkflow': graph,
        'comfyBindings': dual.bindings,
      }),
      throwsFormatException,
    );
  });

  test(
    'inference traces SamplerCustom and SD3 latents across long cyclic paths',
    () {
      final graph = ComfyUIWorkflow.buildStandardGraph(
        checkpoint: 'model.safetensors',
        values: {},
      );
      graph['3']['class_type'] = 'SamplerCustom';
      final sampler = graph['3']['inputs'] as Map;
      sampler['noise_seed'] = sampler.remove('seed');
      graph['5']['class_type'] = 'EmptySD3LatentImage';
      sampler['latent_image'] = ['latent-pass', 0];
      graph['latent-pass'] = {
        'class_type': 'LatentPass',
        'inputs': {
          'latent': ['5', 0],
        },
      };
      sampler['positive'] = ['pass0', 0];
      for (var i = 0; i < 8; i++) {
        graph['pass$i'] = {
          'class_type': 'ConditioningPass',
          'inputs': {
            'conditioning': [i == 7 ? '6' : 'pass${i + 1}', 0],
          },
        };
      }
      graph['pass7']['inputs']['cycle'] = ['pass0', 0];
      final result = ComfyUIWorkflow.inferBindings(graph);
      expect(result.bindings['prompt'], '6.text');
      expect(result.bindings['seed'], '3.noise_seed');
      expect(result.bindings['width'], '5.width');
      expect(result.bindings['height'], '5.height');
    },
  );

  test(
    'disconnected inference falls back but does not replace prompt templates',
    () {
      final graph = config()['comfyWorkflow'] as Map<String, dynamic>;
      graph.remove('3');
      final result = ComfyUIWorkflow.inferBindings(graph);
      expect(result.bindings['prompt'], '6.text');
      expect(result.bindings['negative_prompt'], '7.text');
      expect(result.bindings['width'], '5.width');
      graph['6']['inputs']['text'] = 'portrait %prompt%';
      expect(
        ComfyUIWorkflow.inferBindings(graph).bindings.containsKey('prompt'),
        false,
      );
    },
  );

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
    'import fetches checkpoint list from /object_info and falls back to workflow entry when offline',
    () async {
      final offlineApi = UiModelsApi(
        httpClient: MockClient(
          (req) async => throw http.ClientException('offline'),
        ),
      );
      expect(
        await offlineApi.previewProvider(
          providerId: 'custom-1',
          apiKey: '',
          apiBaseUrl: 'http://localhost:8188',
          customConfig: config(),
        ),
        [ComfyUIWorkflow.modelId],
      );
      final onlineApi = UiModelsApi(
        httpClient: MockClient((req) async {
          expect(req.url.path, '/object_info/CheckpointLoaderSimple');
          return json({
            'CheckpointLoaderSimple': {
              'input': {
                'required': {
                  'ckpt_name': [
                    ['illustrious_v1.safetensors', 'animagine_xl.safetensors'],
                  ],
                },
              },
            },
          });
        }),
      );
      expect(
        await onlineApi.previewProvider(
          providerId: 'custom-1',
          apiKey: '',
          apiBaseUrl: 'http://localhost:8188',
          customConfig: const {'requestFormat': 'comfyui'},
        ),
        [
          'illustrious_v1.safetensors',
          'animagine_xl.safetensors',
          ComfyUIWorkflow.modelId,
        ],
      );
      final stored = await onlineApi.importProvider(
        providerId: 'custom-1',
        apiKey: '',
        apiBaseUrl: 'http://localhost:8188',
        customConfig: const {'requestFormat': 'comfyui'},
      );
      final settings = mapUiModelsToAppSettings(stored);
      expect(
        settings.getProviderVisibleModelsByType(
          'custom-1',
          type: ModelType.image,
        ),
        [
          'illustrious_v1.safetensors',
          'animagine_xl.safetensors',
          ComfyUIWorkflow.modelId,
        ],
      );
      final provider = settings.providers.firstWhere((p) => p.id == 'custom-1');
      expect(provider.apiKeys, isEmpty);
      expect(
        provider.customConfig['defaultImageModel'],
        'illustrious_v1.safetensors',
      );
    },
  );

  for (final status in [401, 403, 503]) {
    test(
      'catalog HTTP $status is surfaced for LoRAs and Checkpoints',
      () async {
        final client = MockClient(
          (req) async => http.Response('error', status),
        );
        final matcher = throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('HTTP $status'),
          ),
        );
        await expectLater(
          ComfyUIImageAdapter.fetchLoras(
            baseUrl: 'http://localhost:8188',
            client: client,
          ),
          matcher,
        );
        await expectLater(
          UiModelsApi(httpClient: client).previewProvider(
            providerId: 'local',
            apiKey: '',
            apiBaseUrl: 'http://localhost:8188',
            customConfig: const {'requestFormat': 'comfyui'},
          ),
          matcher,
        );
      },
    );
  }

  test(
    'LoRA catalog normalizes options and preserves auth, proxy and client',
    () async {
      var requests = 0;
      final client = MockClient((req) async {
        requests++;
        expect(req.url.path, '/proxy/object_info/LoraLoader');
        expect(req.headers['authorization'], 'Bearer private-key');
        return json({
          'LoraLoader': {
            'input': {
              'required': {
                'lora_name': [
                  requests == 1
                      ? [' style.safetensors ', '', 'style.safetensors']
                      : [],
                ],
              },
            },
          },
        });
      });
      for (final expected in [
        <String>['style.safetensors'],
        <String>[],
      ]) {
        expect(
          await ComfyUIImageAdapter.fetchLoras(
            baseUrl: 'http://localhost:8188/proxy/',
            apiKey: ' private-key ',
            client: client,
          ),
          expected,
        );
      }
      expect(requests, 2);
    },
  );

  test('catalog distinguishes malformed responses from empty lists', () async {
    for (final body in ['not json', '{}', '{"LoraLoader":{}}']) {
      await expectLater(
        ComfyUIImageAdapter.fetchLoras(
          baseUrl: 'http://localhost:8188',
          client: MockClient((_) async => http.Response(body, 200)),
        ),
        throwsFormatException,
      );
    }
    await expectLater(
      ComfyUIImageAdapter.fetchLoras(
        baseUrl: 'http://localhost:8188',
        timeout: const Duration(milliseconds: 1),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return json({});
        }),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test(
    'standard checkpoint + LoRA workflow builds graph without custom JSON and auto-infers bindings on import',
    () {
      final standardGraph = ComfyUIWorkflow.build(
        const {
          'requestFormat': 'comfyui',
          'comfyLoraName': 'style_lora.safetensors',
          'comfyLoraStrength': 0.8,
        },
        {
          'prompt': '1girl, smile',
          'negative_prompt': 'lowres',
          'width': 832,
          'height': 1216,
          'steps': 24,
          'cfg_scale': 5.5,
          'seed': 123,
        },
        checkpointModel: 'illustrious_v1.safetensors',
      );
      expect(
        standardGraph['4']['inputs']['ckpt_name'],
        'illustrious_v1.safetensors',
      );
      expect(
        standardGraph['10']['inputs']['lora_name'],
        'style_lora.safetensors',
      );
      expect(standardGraph['10']['inputs']['strength_model'], 0.8);
      expect(standardGraph['3']['inputs']['model'], ['10', 0]);
      expect(standardGraph['6']['inputs']['clip'], ['10', 1]);
      expect(standardGraph['6']['inputs']['text'], '1girl, smile');

      final inferred = ComfyUIWorkflow.inferBindings(standardGraph);
      expect(inferred.bindings['prompt'], '6.text');
      expect(inferred.bindings['negative_prompt'], '7.text');
      expect(inferred.bindings['width'], '5.width');
      expect(inferred.bindings['height'], '5.height');
      expect(inferred.bindings['steps'], '3.steps');
      expect(inferred.bindings['cfg_scale'], '3.cfg');
      expect(inferred.bindings['seed'], '3.seed');
      expect(inferred.outputNode, '9');
    },
  );

  test(
    'preset sampler, scheduler and model reach standard and custom graphs',
    () async {
      Future<Map<String, dynamic>> submit(
        Map<String, dynamic> customConfig, {
        String model = 'anime.safetensors',
      }) async {
        late Map<String, dynamic> graph;
        await const ComfyUIImageAdapter(pollInterval: Duration.zero).generate(
          client: MockClient((req) async {
            if (req.method == 'POST') {
              graph = Map<String, dynamic>.from(
                (jsonDecode(req.body) as Map)['prompt'] as Map,
              );
              return json({'prompt_id': 'job'});
            }
            if (req.url.path.contains('history')) return json(finished());
            return http.Response.bytes([1], 200);
          }),
          timeout: const Duration(seconds: 5),
          request: ImageProviderRequest(
            provider: 'comfyui',
            model: model,
            prompt: 'cat',
            width: 768,
            height: 1024,
            count: 1,
            baseUrl: 'http://localhost:8188',
            apiKey: '',
            customConfig: customConfig,
            seed: 7,
          ),
        );
        return graph;
      }

      final standard = await submit({
        ComfyUIWorkflow.modeKey: ComfyUIWorkflow.standardMode,
        ComfyUIWorkflow.samplerKey: 'dpmpp_2m',
        ComfyUIWorkflow.schedulerKey: 'karras',
      });
      expect(standard['3']['inputs']['sampler_name'], 'dpmpp_2m');
      expect(standard['3']['inputs']['scheduler'], 'karras');
      expect(standard['4']['inputs']['ckpt_name'], 'anime.safetensors');
      final defaults = await submit({
        ComfyUIWorkflow.modeKey: ComfyUIWorkflow.standardMode,
      });
      expect(defaults['3']['inputs']['sampler_name'], 'euler');
      expect(defaults['3']['inputs']['scheduler'], 'normal');

      final workflow = ComfyUIWorkflow.buildStandardGraph(
        checkpoint: 'original.safetensors',
        values: const {'sampler_name': 'euler', 'scheduler': 'simple'},
      );
      final inferred = ComfyUIWorkflow.inferBindings(workflow);
      expect(inferred.bindings['model'], '4.ckpt_name');
      expect(inferred.bindings['scheduler'], '3.scheduler');
      final custom = {
        ComfyUIWorkflow.modeKey: ComfyUIWorkflow.customMode,
        ComfyUIWorkflow.workflowKey: workflow,
        ComfyUIWorkflow.bindingsKey: inferred.bindings,
      };
      final picked = await submit({
        ...custom,
        ComfyUIWorkflow.schedulerKey: 'karras',
      });
      expect(picked['4']['inputs']['ckpt_name'], 'anime.safetensors');
      expect(picked['3']['inputs']['scheduler'], 'karras');
      // The workflow placeholder model and an empty preset keep JSON values.
      final kept = await submit(custom, model: ComfyUIWorkflow.modelId);
      expect(kept['4']['inputs']['ckpt_name'], 'original.safetensors');
      expect(kept['3']['inputs']['scheduler'], 'simple');

      // st-chatu8 style templates use %MODEL_NAME% for the Checkpoint.
      final template = jsonDecode(jsonEncode(workflow)) as Map<String, dynamic>;
      template['4']['inputs']['ckpt_name'] = '%MODEL_NAME%';
      template['3']['inputs']['scheduler'] = '%scheduler%';
      final replaced = await submit({
        ComfyUIWorkflow.modeKey: ComfyUIWorkflow.customMode,
        ComfyUIWorkflow.workflowKey: template,
        ComfyUIWorkflow.bindingsKey: {'prompt': '6.text'},
        ComfyUIWorkflow.schedulerKey: 'exponential',
      });
      expect(replaced['4']['inputs']['ckpt_name'], 'anime.safetensors');
      expect(replaced['3']['inputs']['scheduler'], 'exponential');
    },
  );

  test('sampler and scheduler catalogs read KSampler options', () async {
    final client = MockClient((req) async {
      expect(req.url.path, '/object_info/KSampler');
      return json({
        'KSampler': {
          'input': {
            'required': {
              'sampler_name': [
                ['euler', 'dpmpp_2m'],
              ],
              'scheduler': [
                'COMBO',
                {
                  'options': ['normal', 'karras'],
                },
              ],
            },
          },
        },
      });
    });
    expect(
      await ComfyUIImageAdapter.fetchSamplers(
        baseUrl: 'http://localhost:8188',
        client: client,
      ),
      ['euler', 'dpmpp_2m'],
    );
    expect(
      await ComfyUIImageAdapter.fetchSchedulers(
        baseUrl: 'http://localhost:8188',
        client: client,
      ),
      ['normal', 'karras'],
    );
  });

  group('modal-comfy gateway', () {
    // Mirrors modal_gateway.py: no /object_info, Bearer auth, templates,
    // /api/generate returns a Modal call id used as prompt_id and subfolder.
    late List<http.Request> requests;
    late MockClient gateway;
    var budgetExceeded = false;
    setUp(() {
      requests = [];
      budgetExceeded = false;
      gateway = MockClient((req) async {
        requests.add(req);
        if (req.headers['authorization'] != 'Bearer gw-key') {
          return http.Response('{"error":"unauthorized"}', 401);
        }
        final path = req.url.path;
        if (path.startsWith('/object_info/')) {
          return http.Response('{"detail":"Not Found"}', 404);
        }
        if (path == '/api/templates') {
          return json({
            'templates': [
              {'name': 'zimage_turbo', 'bindings': ['prompt']},
              {'name': 'moss_image', 'bindings': ['prompt']},
            ],
          });
        }
        if (path == '/api/models') {
          return json({
            'models': [
              {'path': 'diffusion_models/z_image.safetensors', 'gb': 12},
              {'path': 'loras/anime_style.safetensors', 'gb': 0.2},
            ],
          });
        }
        if (path == '/api/generate') {
          if (budgetExceeded) {
            return http.Response.bytes(
              utf8.encode(jsonEncode({'detail': '本月 GPU 预算已用完'})),
              402,
            );
          }
          return json({'prompt_id': 'fc-01ABC', 'number': 0});
        }
        if (path == '/history/fc-01ABC') {
          return json({
            'fc-01ABC': {
              'status': {'status_str': 'success', 'completed': true},
              'outputs': {
                '9': {
                  'images': [
                    {
                      'filename': '1.png',
                      'subfolder': 'fc-01ABC',
                      'type': 'output',
                    },
                  ],
                },
              },
            },
          });
        }
        if (path == '/view' &&
            req.url.queryParameters['subfolder'] == 'fc-01ABC') {
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response('{"detail":"Not Found"}', 404);
      });
    });

    test('channel lists gateway templates as image models', () async {
      final api = UiModelsApi(httpClient: gateway);
      final models = await api.previewProvider(
        providerId: 'custom-1',
        apiKey: 'gw-key',
        apiBaseUrl: 'https://gw.modal.run/',
        customConfig: const {'requestFormat': 'comfyui'},
      );
      expect(models, [
        'template/zimage_turbo',
        'template/moss_image',
        ComfyUIWorkflow.modelId,
      ]);
      expect(
        await ComfyUIImageAdapter.fetchLoras(
          baseUrl: 'https://gw.modal.run',
          apiKey: 'gw-key',
          client: gateway,
        ),
        ['anime_style.safetensors'],
      );
    });

    test('template model generates through /api/generate', () async {
      Future<ImageProviderResponse> generate(Map<String, dynamic> config) =>
          const ComfyUIImageAdapter(pollInterval: Duration.zero).generate(
            client: gateway,
            timeout: const Duration(seconds: 5),
            request: ImageProviderRequest(
              provider: 'comfyui',
              model: 'template/zimage_turbo',
              prompt: '一只橘猫',
              negativePrompt: '水印',
              width: 1104,
              height: 1472,
              count: 1,
              steps: 28,
              guidanceScale: 5,
              baseUrl: 'https://gw.modal.run/',
              apiKey: 'gw-key',
              customConfig: config,
              seed: 928188022,
            ),
          );

      final result = await generate({
        ComfyUIWorkflow.modeKey: ComfyUIWorkflow.standardMode,
        ComfyUIWorkflow.loraNameKey: 'anime_style.safetensors',
        ComfyUIWorkflow.loraStrengthKey: 0.6,
        ComfyUIWorkflow.samplerKey: 'dpmpp_2m',
      });
      expect(result.images.single, [1, 2, 3]);
      final submitted = requests.singleWhere(
        (r) => r.url.path == '/api/generate',
      );
      final body = jsonDecode(submitted.body) as Map;
      expect(body['template'], 'zimage_turbo');
      expect(body['prompt'], '一只橘猫');
      expect(body['negative_prompt'], '水印');
      expect(body['seed'], 928188022);
      expect(body['width'], 1104);
      expect(body['loras'], [
        {'name': 'anime_style.safetensors', 'strength': 0.6},
      ]);
      // Template-tuned values must never be overridden.
      for (final key in ['steps', 'cfg_scale', 'sampler_name']) {
        expect(body.containsKey(key), false, reason: key);
      }
      expect(requests.any((r) => r.url.path == '/prompt'), false);

      budgetExceeded = true;
      await expectLater(
        generate({ComfyUIWorkflow.modeKey: ComfyUIWorkflow.standardMode}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('402'), contains('本月 GPU 预算已用完')),
          ),
        ),
      );
    });

    test('preset JSON on a template model submits the graph natively', () async {
      final workflow = ComfyUIWorkflow.buildStandardGraph(
        checkpoint: 'own.safetensors',
        values: const {},
      );
      await const ComfyUIImageAdapter(pollInterval: Duration.zero).generate(
        client: MockClient((req) async {
          requests.add(req);
          if (req.method == 'POST') return json({'prompt_id': 'job'});
          if (req.url.path.contains('history')) return json(finished());
          return http.Response.bytes([1], 200);
        }),
        timeout: const Duration(seconds: 5),
        request: ImageProviderRequest(
          provider: 'comfyui',
          model: 'template/zimage_turbo',
          prompt: 'cat',
          width: 512,
          height: 512,
          count: 1,
          baseUrl: 'http://localhost:8188',
          apiKey: '',
          customConfig: {
            ComfyUIWorkflow.modeKey: ComfyUIWorkflow.customMode,
            ComfyUIWorkflow.workflowKey: workflow,
            ComfyUIWorkflow.bindingsKey: ComfyUIWorkflow.inferBindings(
              workflow,
            ).bindings,
          },
        ),
      );
      final graph =
          (jsonDecode(requests.firstWhere((r) => r.method == 'POST').body)
                  as Map)['prompt']
              as Map;
      expect(requests.first.url.path, '/prompt');
      // The template ID is not a Checkpoint name; keep the JSON's own model.
      expect(graph['4']['inputs']['ckpt_name'], 'own.safetensors');
    });
  });

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
