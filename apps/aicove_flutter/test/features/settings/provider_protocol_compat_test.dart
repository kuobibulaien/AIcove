import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/core/api/providers/google_api_mode.dart';
import 'package:aicove_flutter/src/core/api/providers/minimax_compat.dart';
import 'package:aicove_flutter/src/core/api/providers/zai_compat.dart';
import 'package:aicove_flutter/src/features/settings/ui_models_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CapturingClient extends http.BaseClient {
  _CapturingClient(this._onRequest);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      _onRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _onRequest(request);
  }
}

class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future;
  }
}

http.StreamedResponse _jsonResponse(
  Map<String, dynamic> body, {
  int statusCode = 200,
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
    statusCode,
    headers: const <String, String>{
      'content-type': 'application/json',
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Provider protocol compatibility', () {
    setUp(() {
      ApiLogger.clear();
    });

    test('NovelAI V4.5 should build minimal v4 payload', () async {
      Map<String, dynamic>? requestBody;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          if (request is http.Request) {
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          }
          return _jsonResponse({
            'image': base64Encode(
              Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x00]),
            ),
          });
        }),
      );

      final result = await client.generateImage(
        provider: 'novelai',
        model: 'nai-diffusion-4-5-full',
        prompt: '1girl, solo',
        negativePrompt: 'lowres',
        width: 832,
        height: 1216,
        providerApiBase: 'https://image.novelai.net',
        providerApiKey: 'test-key',
      );

      expect(result.images, hasLength(1));
      final parameters =
          requestBody?['parameters'] as Map<String, dynamic>? ?? const {};
      expect(requestBody?['model'], 'nai-diffusion-4-5-full');
      expect(parameters['v4_prompt'], isNotNull);
      expect(parameters['v4_negative_prompt'], isNotNull);
      expect(parameters['qualityToggle'], isNull);
      expect(parameters['ucPreset'], isNull);
      expect(parameters['legacy'], isNull);
      expect(parameters['legacy_v3_extend'], isNull);
      expect(parameters['noise_schedule'], isNull);
      expect(parameters['add_original_image'], isNull);
      expect(parameters['cfg_rescale'], isNull);
      expect(parameters['sm'], isNull);
      expect(parameters['sm_dyn'], isNull);
      expect(parameters['dynamic_thresholding'], isNull);
      expect(parameters['prefer_brownian'], isNull);
      expect(parameters['deliberate_euler_ancestral_bug'], isNull);
      expect(parameters['autoSmea'], isNull);

      final latestLog = ApiLogger.entries.value.last;
      expect(latestLog.eventType, 'image_generation');
      expect(latestLog.url, 'https://image.novelai.net/ai/generate-image');
      expect(latestLog.rawRequestBody, isNotNull);
      final loggedRequest =
          jsonDecode(latestLog.rawRequestBody!) as Map<String, dynamic>;
      expect(loggedRequest['model'], 'nai-diffusion-4-5-full');
      final loggedResponse =
          jsonDecode(latestLog.rawResponseBody!) as Map<String, dynamic>;
      expect(loggedResponse['kind'], 'binary');
      expect(loggedResponse['imageCount'], 1);
      expect(loggedResponse['statusCode'], 200);
    });

    test('NovelAI V4.5 should ignore extra overrides for core payload keys',
        () async {
      Map<String, dynamic>? requestBody;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          if (request is http.Request) {
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          }
          return _jsonResponse({
            'image': base64Encode(
              Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x00]),
            ),
          });
        }),
      );

      await client.generateImage(
        provider: 'novelai',
        model: 'nai-diffusion-4-5-full',
        prompt: '1girl, solo',
        negativePrompt: 'lowres',
        width: 832,
        height: 1216,
        providerApiBase: 'https://image.novelai.net',
        providerApiKey: 'test-key',
        customConfig: const {
          'requestFormat': 'novelai',
          'image_parameters': {
            'sampler': 'ddim',
            'v4_prompt': {
              'caption': {'base_caption': 'broken'},
            },
            'qualityToggle': true,
            'new_toggle': true,
          },
        },
      );

      final parameters =
          requestBody?['parameters'] as Map<String, dynamic>? ?? const {};
      expect(parameters['sampler'], 'k_euler_ancestral');
      expect(
        ((parameters['v4_prompt'] as Map<String, dynamic>)['caption']
            as Map<String, dynamic>)['base_caption'],
        '1girl, solo',
      );
      expect(parameters['qualityToggle'], isNull);
      expect(parameters['new_toggle'], isTrue);
    });

    test('NovelAI V3 should keep legacy generation fields', () async {
      Map<String, dynamic>? requestBody;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          if (request is http.Request) {
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          }
          return _jsonResponse({
            'image': base64Encode(
              Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x00]),
            ),
          });
        }),
      );

      await client.generateImage(
        provider: 'novelai',
        model: 'nai-diffusion-3',
        prompt: '1girl, solo',
        negativePrompt: 'lowres',
        width: 832,
        height: 1216,
        providerApiBase: 'https://image.novelai.net',
        providerApiKey: 'test-key',
      );

      final parameters =
          requestBody?['parameters'] as Map<String, dynamic>? ?? const {};
      expect(parameters['qualityToggle'], true);
      expect(parameters['legacy'], false);
      expect(parameters['legacy_v3_extend'], false);
      expect(parameters['noise_schedule'], 'karras');
      expect(parameters['sm'], false);
      expect(parameters['sm_dyn'], false);
      expect(parameters['v4_prompt'], isNull);
      expect(parameters['v4_negative_prompt'], isNull);
    });

    test('OpenAI compatible image generation should accept url responses',
        () async {
      final calls = <Uri>[];
      final client = MockClient((request) async {
        calls.add(request.url);
        if (request.url.path.endsWith('/images/generations')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'url': 'https://cdn.unit.test/generated/cat.png'}
              ],
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.url.toString() ==
            'https://cdn.unit.test/generated/cat.png') {
          return http.Response.bytes(
            Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x00]),
            200,
            headers: const {'content-type': 'image/png'},
          );
        }
        return http.Response('not found', 404);
      });

      final result = await AgentApiClient(client: client).generateImage(
        provider: 'openai',
        model: 'gpt-image-1',
        prompt: 'a cat',
        providerApiBase: 'https://unit.test/v1',
        providerApiKey: 'test-key',
      );

      expect(result.images, hasLength(1));
      expect(result.images.first, isNotEmpty);
      expect(
        calls.map((e) => e.toString()).toList(),
        <String>[
          'https://unit.test/v1/images/generations',
          'https://cdn.unit.test/generated/cat.png',
        ],
      );
    });

    test('NovelAI timeout should record wait_headers phase in ApiLogger',
        () async {
      final client = AgentApiClient(
        client: _HangingClient(),
        timeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        client.generateImage(
          provider: 'novelai',
          model: 'nai-diffusion-4-5-full',
          prompt: '1girl, solo',
          providerApiBase: 'https://image.novelai.net',
          providerApiKey: 'test-key',
          requestId: 'img_timeout_test',
          requestSource: 'inline_image',
          flowMode: 'fast',
        ),
        throwsA(isA<TimeoutException>()),
      );

      final latestLog = ApiLogger.entries.value.last;
      expect(latestLog.eventType, 'image_generation');
      expect(latestLog.ok, isFalse);
      expect(latestLog.rawRequestBody, isNotNull);
      final loggedResponse =
          jsonDecode(latestLog.rawResponseBody!) as Map<String, dynamic>;
      expect(loggedResponse['kind'], 'timeout');
      expect(loggedResponse['phase'], 'wait_headers');
      expect(loggedResponse['requestId'], 'img_timeout_test');
    });

    test('Gemini sendMessageRich should call models/{model}:generateContent',
        () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          calledUri = request.url;
          calledHeaders = Map<String, String>.from(request.headers);
          return _jsonResponse({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'}
                  ]
                }
              }
            ]
          });
        }),
      );

      final result = await client.sendMessageRich(
        agentId: 'a1',
        sessionId: 's1',
        modelFullId: 'gemini:gemini-2.0-flash',
        messages: const <Map<String, dynamic>>[],
        userText: 'hello',
        providerApiBase: 'https://generativelanguage.googleapis.com/v1beta',
        providerApiKey: 'test-gemini-key',
      );

      expect(result.text, 'ok');
      expect(
        calledUri.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent',
      );
      expect(
        calledHeaders?['x-goog-api-key'],
        'test-gemini-key',
      );
    });

    test('requestFormat=openai should override gemini provider adapter',
        () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          calledUri = request.url;
          calledHeaders = Map<String, String>.from(request.headers);
          return _jsonResponse({
            'choices': [
              {
                'message': {'content': 'ok'}
              }
            ]
          });
        }),
      );

      final result = await client.sendMessageRich(
        agentId: 'a1',
        sessionId: 's1',
        modelFullId: 'gemini:gpt-4o-mini',
        messages: const <Map<String, dynamic>>[],
        userText: 'hello',
        providerApiBase: 'https://unit.test',
        providerApiKey: 'openai-like-key',
        customConfig: const {'requestFormat': 'openai'},
      );

      expect(result.text, 'ok');
      expect(calledUri.toString(), 'https://unit.test/chat/completions');
      expect(calledHeaders?['Authorization'], 'Bearer openai-like-key');
      expect(calledHeaders?.containsKey('x-goog-api-key'), isFalse);
    });

    test('custom apiPath should be used as final request path', () async {
      Uri? calledUri;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          calledUri = request.url;
          return _jsonResponse({
            'choices': [
              {
                'message': {'content': 'ok'}
              }
            ]
          });
        }),
      );

      final result = await client.sendMessageRich(
        agentId: 'a1',
        sessionId: 's1',
        modelFullId: 'openai:gpt-4o-mini',
        messages: const <Map<String, dynamic>>[],
        userText: 'hello',
        providerApiBase: 'https://unit.test/v1',
        providerApiKey: 'openai-like-key',
        customConfig: const {
          'requestFormat': 'openai',
          'apiPath': '/responses',
        },
      );

      expect(result.text, 'ok');
      expect(calledUri.toString(), 'https://unit.test/v1/responses');
    });

    test('MiniMax native endpoint should not be appended twice', () async {
      Uri? calledUri;
      Map<String, dynamic>? requestBody;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          calledUri = request.url;
          if (request is http.Request) {
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          }
          return _jsonResponse({
            'choices': [
              {
                'message': {'content': 'ok'}
              }
            ]
          });
        }),
      );

      final result = await client.sendMessageRich(
        agentId: 'a1',
        sessionId: 's1',
        modelFullId: 'openai:MiniMax-M2.7',
        messages: const <Map<String, dynamic>>[],
        userText: 'hello',
        providerApiBase: 'https://api.minimax.io/v1/text/chatcompletion_v2',
        providerApiKey: 'minimax-key',
        customConfig: const {'requestFormat': 'openai'},
      );

      expect(result.text, 'ok');
      expect(
        calledUri.toString(),
        'https://api.minimax.io/v1/text/chatcompletion_v2',
      );
      expect(requestBody?['requestFormat'], isNull);
      expect(requestBody?['model'], 'MiniMax-M2.7');
    });

    test('Z.AI sendMessageRich should use官方 paas/v4 端点，不拼 /v1', () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          calledUri = request.url;
          calledHeaders = Map<String, String>.from(request.headers);
          return _jsonResponse({
            'choices': [
              {
                'message': {'content': 'ok'}
              }
            ]
          });
        }),
      );

      final result = await client.sendMessageRich(
        agentId: 'a1',
        sessionId: 's1',
        modelFullId: 'zai:glm-5',
        messages: const <Map<String, dynamic>>[],
        userText: 'hello',
        providerApiBase: kZaiGeneralApiBase,
        providerApiKey: 'zai-key',
      );

      expect(result.text, 'ok');
      expect(
        calledUri.toString(),
        'https://api.z.ai/api/paas/v4/chat/completions',
      );
      expect(calledHeaders?['Authorization'], 'Bearer zai-key');
    });

    test('MiniMax OpenAI compatible previewProvider should try /v1/models',
        () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;
      final client = MockClient((request) async {
        calledUri = request.url;
        calledHeaders = Map<String, String>.from(request.headers);
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'MiniMax-M2.7'},
              {'id': 'MiniMax-M2.5-lightning'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'openai',
        apiKey: 'minimax-key',
        apiBaseUrl: 'https://api.minimax.io/v1',
        customConfig: const {'requestFormat': 'openai'},
      );

      expect(calledUri.toString(), 'https://api.minimax.io/v1/models');
      expect(calledHeaders?['Authorization'], 'Bearer minimax-key');
      expect(calledHeaders?.containsKey('x-api-key'), isFalse);
      expect(
        models,
        <String>[
          'MiniMax-M2.7',
          'MiniMax-M2.5-lightning',
          ...kMiniMaxDefaultTtsModels,
        ],
      );
    });

    test(
        'MiniMax Anthropic compatible previewProvider should probe sibling /v1/models',
        () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;
      final client = MockClient((request) async {
        calledUri = request.url;
        calledHeaders = Map<String, String>.from(request.headers);
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'MiniMax-M2.7-highspeed'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'claude',
        apiKey: 'minimax-key',
        apiBaseUrl: 'https://api.minimax.io/anthropic',
        customConfig: const {'requestFormat': 'claude'},
      );

      expect(calledUri.toString(), 'https://api.minimax.io/v1/models');
      expect(calledHeaders?['Authorization'], 'Bearer minimax-key');
      expect(calledHeaders?.containsKey('x-api-key'), isFalse);
      expect(
        models,
        <String>[
          'MiniMax-M2.7-highspeed',
          ...kMiniMaxDefaultTtsModels,
        ],
      );
    });

    test(
        'MiniMax OpenAI compatible previewProvider should fall back when /models fails',
        () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount += 1;
        return http.Response('oops', 500);
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'openai',
        apiKey: 'minimax-key',
        apiBaseUrl: 'https://api.minimaxi.com/v1',
        customConfig: const {'requestFormat': 'openai'},
      );

      expect(requestCount, 1);
      expect(models, kMiniMaxDefaultPreviewModels);
    });

    test('Z.AI previewProvider should fall back to built-in GLM list',
        () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount += 1;
        return http.Response('not found', 404);
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'zai',
        apiKey: 'zai-key',
        apiBaseUrl: kZaiGeneralApiBase,
        customConfig: const {'requestFormat': 'openai'},
      );

      expect(requestCount, 1);
      expect(models, kZaiDefaultChatModels);
    });

    test('Z.AI alias provider should also fall back to built-in GLM list',
        () async {
      final client = MockClient((request) async {
        return http.Response('not found', 404);
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'zhipu',
        apiKey: 'zai-key',
        apiBaseUrl: kZaiGeneralApiBase,
      );

      expect(models, kZaiDefaultChatModels);
    });

    test('Gemini previewProvider should use x-goog-api-key and parse models[]',
        () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;
      final client = MockClient((request) async {
        calledUri = request.url;
        calledHeaders = Map<String, String>.from(request.headers);
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-2.0-flash'},
              {'name': 'models/text-embedding-004'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'gemini',
        apiKey: 'gemini-key',
        apiBaseUrl: 'https://unit.test/v1beta',
      );

      expect(
        calledUri.toString(),
        'https://unit.test/v1beta/models?pageSize=200',
      );
      expect(calledHeaders?['x-goog-api-key'], 'gemini-key');
      expect(calledHeaders?.containsKey('Authorization'), isFalse);
      expect(models, <String>['gemini-2.0-flash', 'text-embedding-004']);
    });

    test('Gemini 通用渠道 previewProvider 应按基础地址直接探测 /models', () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;
      final client = MockClient((request) async {
        calledUri = request.url;
        calledHeaders = Map<String, String>.from(request.headers);
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'publishers/google/models/gemini-2.5-pro'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'gemini',
        apiKey: 'vertex-key',
        apiBaseUrl: 'https://aiplatform.googleapis.com/v1/publishers/google',
        customConfig: const {
          'requestFormat': 'gemini',
        },
      );

      expect(
        calledUri.toString(),
        'https://aiplatform.googleapis.com/v1/publishers/google/models?key=vertex-key&pageSize=200',
      );
      expect(calledHeaders?.containsKey('x-goog-api-key'), isFalse);
      expect(models, <String>['gemini-2.5-pro']);
    });

    test('旧 vertex 渠道别名 previewProvider 应继续走 Gemini models 列表接口', () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;
      final client = MockClient((request) async {
        calledUri = request.url;
        calledHeaders = Map<String, String>.from(request.headers);
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-2.5-pro'},
              {'name': 'models/gemini-2.5-flash'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'vertex',
        apiKey: 'vertex-key',
        apiBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        customConfig: const {
          'requestFormat': 'gemini',
        },
      );

      expect(
        calledUri.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models?pageSize=200',
      );
      expect(calledHeaders?['x-goog-api-key'], 'vertex-key');
      expect(models, <String>['gemini-2.5-pro', 'gemini-2.5-flash']);
    });

    test('带 vertexExpress 标记的 Gemini 渠道 previewProvider 应忽略旧分支', () async {
      Uri? calledUri;
      final client = MockClient((request) async {
        calledUri = request.url;
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-2.5-pro'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'gemini__2',
        apiKey: 'vertex-key',
        apiBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        customConfig: const {
          'requestFormat': 'gemini',
          'vertexExpress': true,
        },
      );

      expect(
        calledUri.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models?pageSize=200',
      );
      expect(models, contains('gemini-2.5-pro'));
    });

    test('MiniMax previewProvider should fall back to documented model list',
        () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount += 1;
        return http.Response('unexpected', 500);
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'openai',
        apiKey: 'minimax-key',
        apiBaseUrl: 'https://api.minimaxi.com/v1/text/chatcompletion_v2',
        customConfig: const {'requestFormat': 'openai'},
      );

      expect(requestCount, 0);
      expect(models, kMiniMaxDefaultPreviewModels);
    });

    test('Gemini importProvider 在探测失败时应保留空模型列表，交给手动添加', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final client = MockClient((request) async {
        return http.Response('unexpected', 500);
      });

      final api = UiModelsApi(httpClient: client);
      final result = await api.importProvider(
        providerId: 'gemini',
        apiKey: 'gemini-key',
        apiBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        customConfig: const {
          'requestFormat': 'gemini',
        },
      );

      final providers =
          (result['providers'] as List).cast<Map<String, dynamic>>();
      final imported =
          providers.firstWhere((provider) => provider['id'] == 'gemini');
      expect(imported['models'], isEmpty);
      expect(imported['visible_models'], isEmpty);
    });

    test('旧 vertex 渠道别名 sendMessageRich 应使用 Gemini 开发者接口', () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          calledUri = request.url;
          calledHeaders = Map<String, String>.from(request.headers);
          return _jsonResponse({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'}
                  ]
                }
              }
            ]
          });
        }),
      );

      final result = await client.sendMessageRich(
        agentId: 'a1',
        sessionId: 's1',
        modelFullId: 'vertex:gemini-2.5-pro',
        messages: const <Map<String, dynamic>>[],
        userText: 'hello',
        providerApiBase: 'https://generativelanguage.googleapis.com/v1beta',
        providerApiKey: 'vertex-key',
        customConfig: const {
          'requestFormat': 'gemini',
        },
      );

      expect(result.text, 'ok');
      expect(
        calledUri.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent',
      );
      expect(calledHeaders?['x-goog-api-key'], 'vertex-key');
    });

    test('旧 vertex 渠道别名 sendMessageRichStream 应使用开发者流式端点', () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          calledUri = request.url;
          calledHeaders = Map<String, String>.from(request.headers);
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              utf8.encode(
                'data: {"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]}}]}\n\n',
              ),
            ]),
            200,
            headers: const <String, String>{
              'content-type': 'text/event-stream',
            },
          );
        }),
      );

      final result = await client.sendMessageRichStream(
        agentId: 'a1',
        sessionId: 's1',
        modelFullId: 'vertex:gemini-2.5-pro',
        messages: const <Map<String, dynamic>>[],
        userText: 'hello',
        providerApiBase: 'https://generativelanguage.googleapis.com/v1beta',
        providerApiKey: 'vertex-key',
        customConfig: const {
          'requestFormat': 'gemini',
        },
      );

      expect(result.text, 'ok');
      expect(
        calledUri.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse',
      );
      expect(calledUri?.queryParameters['alt'], 'sse');
      expect(calledHeaders?['Accept'], 'text/event-stream');
      expect(calledHeaders?['x-goog-api-key'], 'vertex-key');
    });

    test('Gemini 通用渠道流式请求不应自动追加 alt=sse', () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;

      final client = AgentApiClient(
        client: _CapturingClient((request) async {
          calledUri = request.url;
          calledHeaders = Map<String, String>.from(request.headers);
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              utf8.encode(
                'data: {"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]}}]}\n\n',
              ),
            ]),
            200,
            headers: const <String, String>{
              'content-type': 'text/event-stream',
            },
          );
        }),
      );

      final result = await client.sendMessageRichStream(
        agentId: 'a1',
        sessionId: 's1',
        modelFullId: 'gemini:gemini-2.5-pro',
        messages: const <Map<String, dynamic>>[],
        userText: 'hello',
        providerApiBase:
            'https://aiplatform.googleapis.com/v1/publishers/google',
        providerApiKey: 'vertex-key',
        customConfig: const {
          'requestFormat': 'gemini',
        },
      );

      expect(result.text, 'ok');
      expect(
        calledUri.toString(),
        'https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-pro:streamGenerateContent?key=vertex-key',
      );
      expect(calledUri?.queryParameters['alt'], isNull);
      expect(calledHeaders?['Accept'], 'text/event-stream');
      expect(calledHeaders?.containsKey('x-goog-api-key'), isFalse);
    });

    test(
        'Claude previewProvider should use x-api-key + anthropic-version and parse data[]',
        () async {
      Uri? calledUri;
      Map<String, String>? calledHeaders;
      final client = MockClient((request) async {
        calledUri = request.url;
        calledHeaders = Map<String, String>.from(request.headers);
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'claude-3-5-haiku-latest'},
              {'id': 'claude-sonnet-4-5'},
            ]
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final api = UiModelsApi(httpClient: client);
      final models = await api.previewProvider(
        providerId: 'claude',
        apiKey: 'claude-key',
        apiBaseUrl: 'https://unit.test/v1',
      );

      expect(calledUri.toString(), 'https://unit.test/v1/models');
      expect(calledHeaders?['x-api-key'], 'claude-key');
      expect(calledHeaders?['anthropic-version'], '2023-06-01');
      expect(calledHeaders?.containsKey('Authorization'), isFalse);
      expect(models, <String>['claude-3-5-haiku-latest', 'claude-sonnet-4-5']);
    });
  });
}
