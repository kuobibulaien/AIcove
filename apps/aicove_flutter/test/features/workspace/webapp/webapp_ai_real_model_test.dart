// Real-model check for ADR0109 acceptance gate 3 (opt-in).
//
// A page-style POST to /__aicove/ai/chat (and the OpenAI-compatible
// /__aicove/v1/chat/completions) reaches DeepSeek Flash through the
// stored channel key; the reply carries model text and never the key.
// Skipped unless DEEPSEEK_API_KEY is set; the key is read from the
// environment only.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_ai.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final String? _apiKey = Platform.environment['DEEPSEEK_API_KEY'];

void main() {
  test(
    'page calls DeepSeek through the local server without seeing the key',
    () async {
      final root = await Directory.systemTemp.createTemp('webapp_ai_real');
      final store = await WorkspaceStore.open(
        Directory(p.join(root.path, 'workspaces')),
      );
      final ws = (await store.create(name: 'Game')).id;
      await store.write(
        ws,
        'game.html',
        utf8.encode('<!doctype html>'),
        runId: 'seed',
      );
      final settings = mapUiModelsToAppSettings({}).copyWith(
        defaultChatModels: const ['deepseek:deepseek-flash'],
        defaultModelName: 'deepseek:deepseek-flash',
        providers: [
          ProviderAuth(
            id: 'deepseek',
            apiKeys: [_apiKey!],
            apiBaseUrl: 'https://api.deepseek.com',
            models: const ['deepseek-flash'],
          ),
        ],
      );
      final server = WebAppServer(
        store: store,
        dataDir: root,
        candidatePorts: [0],
        shimSource: '',
        aiChat: createWebAppAiChat(loadSettings: () async => settings),
        setWebAppActive: (_) async {},
      );
      final client = HttpClient();
      try {
        await server.start();
        server.allow(ws);
        final request = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:${server.port}/__aicove/ai/chat?page=game.html',
          ),
        );
        final host = '$ws.localhost:${server.port}';
        request.headers
          ..set('Host', host)
          ..set('Origin', 'http://$host')
          ..set('Sec-Fetch-Site', 'same-origin')
          ..contentType = ContentType.json;
        request.write(
          jsonEncode({
            'messages': [
              {'role': 'system', 'content': '你是游戏里的村民 NPC，只用一句中文回答。'},
              {'role': 'user', 'content': '村子东边有什么？'},
            ],
            'max_tokens': 2000,
          }),
        );
        final response = await request.close();
        final text = await utf8.decodeStream(response);
        // ignore: avoid_print
        print('status=${response.statusCode} body=$text');
        expect(response.statusCode, 200);
        expect(text, isNot(contains(_apiKey!)));
        final reply = (jsonDecode(text) as Map)['text'] as String;
        expect(reply.trim(), isNotEmpty);

        // Third-party pages pointed at the OpenAI-compatible base.
        final openAi = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:${server.port}/__aicove/v1/chat/completions',
          ),
        );
        openAi.headers
          ..set('Host', host)
          ..set('Origin', 'http://$host')
          ..set('Sec-Fetch-Site', 'same-origin')
          ..set('Authorization', 'Bearer placeholder')
          ..contentType = ContentType.json;
        openAi.write(
          jsonEncode({
            'model': 'aicove-default',
            'stream': true,
            'messages': [
              {'role': 'system', 'content': '你是游戏旁白，只用一句中文回答。'},
              {'role': 'user', 'content': '描述一下城门口的样子。'},
            ],
          }),
        );
        final streamed = await openAi.close();
        final events = await utf8.decodeStream(streamed);
        // ignore: avoid_print
        print('status=${streamed.statusCode} events=$events');
        expect(streamed.statusCode, 200);
        expect(events, isNot(contains(_apiKey!)));
        expect(events.trimRight(), endsWith('data: [DONE]'));
      } finally {
        client.close(force: true);
        await server.close();
        await store.close();
        await root.delete(recursive: true);
      }
    },
    skip: _apiKey == null ? '未设置 DEEPSEEK_API_KEY' : false,
    tags: ['real_model'],
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
