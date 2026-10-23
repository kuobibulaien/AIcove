import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_ai.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _key = 'sk-webapp-secret-123';

AppSettings _settings({bool model = true}) => mapUiModelsToAppSettings({})
    .copyWith(
      defaultChatModels: model ? const ['deepseek:deepseek-flash'] : const [],
      defaultModelName: model ? 'deepseek:deepseek-flash' : '',
      providers: const [
        ProviderAuth(
          id: 'deepseek',
          apiKeys: [_key],
          apiBaseUrl: 'https://api.deepseek.com',
          models: ['deepseek-flash'],
        ),
      ],
    );

ApiCallResult _reply(String text) => ApiCallResult(
  replyText: text,
  processedText: '',
  pluginEvents: const [],
  toolResults: const [],
);

void main() {
  group('WebAppAiRequest.fromJson', () {
    test('accepts messages and options', () {
      final request = WebAppAiRequest.fromJson({
        'messages': [
          {'role': 'system', 'content': 'NPC'},
          {'role': 'user', 'content': '你好'},
        ],
        'temperature': 0.5,
        'max_tokens': 100,
      });
      expect(request.messages.last, {'role': 'user', 'content': '你好'});
      expect(request.temperature, 0.5);
      expect(request.maxTokens, 100);
    });

    test('rejects malformed bodies', () {
      for (final body in <Object?>[
        null,
        [],
        {'messages': []},
        {
          'messages': [
            {'role': 'tool', 'content': 'x'},
          ],
        },
        {
          'messages': [
            {'role': 'user', 'content': 1},
          ],
        },
        {
          'messages': [
            {'role': 'system', 'content': 'only system'},
          ],
        },
        {
          'messages': [
            {'role': 'user', 'content': 'x'},
          ],
          'temperature': 3,
        },
        {
          'messages': [
            {'role': 'user', 'content': 'x'},
          ],
          'max_tokens': 0,
        },
        {
          'messages': List.filled(201, {'role': 'user', 'content': 'x'}),
        },
      ]) {
        expect(
          () => WebAppAiRequest.fromJson(body),
          throwsA(
            isA<WebAppAiException>().having((e) => e.code, 'code', 'bad_request'),
          ),
          reason: '$body',
        );
      }
    });
  });

  group('createWebAppAiChat', () {
    const request = WebAppAiRequest(
      messages: [
        {'role': 'user', 'content': '你好'},
      ],
      temperature: 0.3,
      maxTokens: 64,
    );

    test('uses the default chat model, stored key and no tools', () async {
      ApiConfig? seen;
      final chat = createWebAppAiChat(
        loadSettings: () async => _settings(),
        executor: ({required config}) async {
          seen = config;
          return _reply('嗨');
        },
      );
      expect(await chat(request), '嗨');
      expect(seen!.modelFullId, contains('deepseek-flash'));
      expect(seen!.providerApiKey, _key);
      expect(seen!.tools, isNull);
      expect(seen!.messages, [
        {'role': 'user', 'content': '你好'},
      ]);
      expect(seen!.modelTemperature, 0.3);
      expect(seen!.providerRequestOptions?.maxOutputTokens, 64);
    });

    test('reports a missing model', () async {
      final chat = createWebAppAiChat(
        loadSettings: () async => _settings(model: false),
        executor: ({required config}) async => _reply('x'),
      );
      await expectLater(
        chat(request),
        throwsA(isA<WebAppAiException>().having((e) => e.code, 'code', 'no_model')),
      );
    });

    test('redacts the key from upstream errors and replies', () async {
      final failing = createWebAppAiChat(
        loadSettings: () async => _settings(),
        executor: ({required config}) async =>
            throw StateError('HTTP 401: bad key $_key'),
      );
      await expectLater(
        failing(request),
        throwsA(
          isA<WebAppAiException>()
              .having((e) => e.code, 'code', 'model_failed')
              .having((e) => e.message, 'message', isNot(contains(_key))),
        ),
      );
      final echoing = createWebAppAiChat(
        loadSettings: () async => _settings(),
        executor: ({required config}) async => _reply('key=$_key'),
      );
      expect(await echoing(request), isNot(contains(_key)));
    });

    test('empty replies fail', () async {
      final chat = createWebAppAiChat(
        loadSettings: () async => _settings(),
        executor: ({required config}) async => _reply('  '),
      );
      await expectLater(
        chat(request),
        throwsA(
          isA<WebAppAiException>().having((e) => e.code, 'code', 'model_failed'),
        ),
      );
    });
  });

  group('POST /__aicove/ai/chat', () {
    late Directory root;
    late WorkspaceStore store;
    late WebAppServer server;
    late String ws;
    late HttpClient client;
    late Future<String> Function(WebAppAiRequest) handler;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('webapp_ai_test');
      store = await WorkspaceStore.open(
        Directory(p.join(root.path, 'workspaces')),
      );
      ws = (await store.create(name: 'Web')).id;
      await store.write(
        ws,
        'game.html',
        utf8.encode('<!doctype html>'),
        runId: 'setup',
      );
      handler = (request) async =>
          'echo:${request.messages.last['content']}';
      server = WebAppServer(
        store: store,
        dataDir: root,
        candidatePorts: [0],
        shimSource: '',
        aiChat: (request) => handler(request),
        setWebAppActive: (_) async {},
      );
      await server.start();
      server.allow(ws);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close();
      await store.close();
      await root.delete(recursive: true);
    });

    Future<(int, Map<String, dynamic>?)> post(
      Object? body, {
      bool sameOrigin = true,
      String page = 'game.html',
      List<int>? raw,
    }) async {
      final request = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/__aicove/ai/chat?page=${Uri.encodeComponent(page)}',
        ),
      );
      request.headers
        ..set('Host', '$ws.localhost:${server.port}')
        ..set(
          'Origin',
          sameOrigin
              ? 'http://$ws.localhost:${server.port}'
              : 'https://evil.test',
        )
        ..set('Sec-Fetch-Site', sameOrigin ? 'same-origin' : 'cross-site')
        ..contentType = ContentType.json;
      final bytes = raw ?? utf8.encode(jsonEncode(body));
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (
        response.statusCode,
        text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>,
      );
    }

    const hello = {
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
    };

    test('returns the model text', () async {
      final (status, body) = await post(hello);
      expect(status, 200);
      expect(body, {'text': 'echo:hi'});
    });

    test('keeps the same-origin and page checks', () async {
      expect((await post(hello, sameOrigin: false)).$1, 403);
      expect((await post(hello, page: 'missing.html')).$1, 404);
    });

    test('maps errors to status codes', () async {
      final bad = await post({'messages': []});
      expect(bad.$1, 400);
      expect(bad.$2, {
        'error': 'bad_request',
        'message': 'messages 必须是 1～200 条消息',
      });
      expect((await post(null, raw: utf8.encode('{oops'))).$1, 400);
      expect(
        (await post(null, raw: List.filled(WebAppAiRequest.maxBodyBytes + 1, 32)))
            .$1,
        413,
      );
      handler = (_) async =>
          throw const WebAppAiException('no_model', '没配模型');
      expect((await post(hello)).$2!['error'], 'no_model');
      expect((await post(hello)).$1, 503);
      handler = (_) async =>
          throw const WebAppAiException('model_failed', '上游 500');
      final failed = await post(hello);
      expect(failed.$1, 502);
      expect(failed.$2, {'error': 'model_failed', 'message': '上游 500'});
    });

    test('limits concurrent calls per workspace', () async {
      final gate = Completer<void>();
      handler = (request) async {
        await gate.future;
        return 'done';
      };
      final first = post(hello);
      final second = post(hello);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final third = await post(hello);
      expect(third.$1, 429);
      expect(third.$2!['error'], 'busy');
      gate.complete();
      expect((await first).$1, 200);
      expect((await second).$1, 200);
      expect((await post(hello)).$1, 200);
    });

    Future<HttpClientResponse> openAi(
      String route, {
      Object? body,
      bool sameOrigin = true,
    }) async {
      final uri = Uri.parse(
        'http://127.0.0.1:${server.port}/__aicove/v1/$route',
      );
      final request = body == null
          ? await client.getUrl(uri)
          : await client.postUrl(uri);
      request.headers
        ..set('Host', '$ws.localhost:${server.port}')
        ..set('Authorization', 'Bearer anything');
      if (body != null) {
        request.headers
          ..set(
            'Origin',
            sameOrigin
                ? 'http://$ws.localhost:${server.port}'
                : 'https://evil.test',
          )
          ..set('Sec-Fetch-Site', sameOrigin ? 'same-origin' : 'cross-site')
          ..contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      return request.close();
    }

    test('OpenAI-compatible models and chat completions', () async {
      final models = await openAi('models');
      expect(models.statusCode, 200);
      expect(jsonDecode(await utf8.decodeStream(models)), {
        'object': 'list',
        'data': [
          {'id': 'aicove-default', 'object': 'model', 'owned_by': 'aicove'},
        ],
      });

      WebAppAiRequest? seen;
      handler = (request) async {
        seen = request;
        return 'echo:${request.messages.last['content']}';
      };
      final response = await openAi(
        'chat/completions',
        body: {
          'model': 'gpt-whatever',
          'temperature': 0.5,
          'max_completion_tokens': 64,
          'messages': [
            {'role': 'developer', 'content': 'be brief'},
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'hi '},
                {'type': 'text', 'text': 'there'},
              ],
            },
          ],
        },
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(await utf8.decodeStream(response)) as Map;
      expect(body['object'], 'chat.completion');
      expect(body['choices'], [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': 'echo:hi there'},
          'finish_reason': 'stop',
        },
      ]);
      expect(seen!.messages.first, {'role': 'system', 'content': 'be brief'});
      expect(seen!.temperature, 0.5);
      expect(seen!.maxTokens, 64);
    });

    test('OpenAI-compatible streaming sends one chunk and DONE', () async {
      final response = await openAi(
        'chat/completions',
        body: {
          'stream': true,
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
        },
      );
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'text/event-stream');
      final events = (await utf8.decodeStream(response))
          .split('\n\n')
          .where((e) => e.startsWith('data: '))
          .map((e) => e.substring(6))
          .toList();
      expect(events.last, '[DONE]');
      final first = jsonDecode(events.first) as Map;
      expect(first['object'], 'chat.completion.chunk');
      expect((first['choices'] as List).single['delta'], {
        'role': 'assistant',
        'content': 'echo:hi',
      });
    });

    test('OpenAI-compatible errors and origin checks', () async {
      final crossSite = await openAi(
        'chat/completions',
        body: hello,
        sameOrigin: false,
      );
      expect(crossSite.statusCode, 403);
      await crossSite.drain<void>();

      final bad = await openAi(
        'chat/completions',
        body: {
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:,'},
                },
              ],
            },
          ],
        },
      );
      expect(bad.statusCode, 400);
      expect(
        (jsonDecode(await utf8.decodeStream(bad)) as Map)['error']['code'],
        'bad_request',
      );

      handler = (_) async =>
          throw const WebAppAiException('model_failed', '上游 500');
      final failed = await openAi('chat/completions', body: hello);
      expect(failed.statusCode, 502);
      expect(jsonDecode(await utf8.decodeStream(failed)), {
        'error': {
          'message': '上游 500',
          'type': 'model_failed',
          'code': 'model_failed',
        },
      });

      final unknown = await openAi('embeddings', body: hello);
      expect(unknown.statusCode, 404);
      await unknown.drain<void>();
    });
  });
}
