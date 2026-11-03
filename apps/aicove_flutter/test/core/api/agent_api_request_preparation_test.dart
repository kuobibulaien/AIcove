import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';

class _CapturingFailureClient extends http.BaseClient {
  late http.Request request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request as http.Request;
    throw http.ClientException('request preparation test');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ApiLogger.clear();
    AppLogger.clear();
    TraceStore.instance.debugResetForTest();
  });

  for (final streaming in [false, true]) {
    test('request bytes retain images while ${streaming ? 'stream' : 'direct'} '
        'diagnostics and logs omit image data', () async {
      final transport = _CapturingFailureClient();
      final client = AgentApiClient(client: transport);
      final imageData = base64Encode(List<int>.filled(3000, 73));
      final imageUrl = 'data:image/png;base64,$imageData';
      final messages = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': imageUrl},
            },
            {'type': 'text', 'text': '请看图片里的中文'},
          ],
        },
      ];
      final before = jsonEncode(messages);
      final pending = streaming
          ? client.sendMessageRichStream(
              agentId: 'agent',
              sessionId: 'session',
              modelFullId: 'openai:gpt-4o-mini',
              messages: messages,
              userText: '',
              providerApiKey: 'test-key',
              providerApiBase: 'https://example.invalid/v1',
            )
          : client.sendMessageRich(
              agentId: 'agent',
              sessionId: 'session',
              modelFullId: 'openai:gpt-4o-mini',
              messages: messages,
              userText: '',
              providerApiKey: 'test-key',
              providerApiBase: 'https://example.invalid/v1',
            );
      await expectLater(pending, throwsA(isA<http.ClientException>()));

      final wireJson = utf8.decode(transport.request.bodyBytes);
      final wire = jsonDecode(wireJson) as Map<String, dynamic>;
      expect(wire['messages'][0]['content'][0]['image_url']['url'], imageUrl);
      expect(wire['messages'][0]['content'][1]['text'], '请看图片里的中文');
      expect(wire['stream'], streaming);
      expect(
        transport.request.headers['content-type'],
        contains('application/json'),
      );
      expect(jsonEncode(messages), before);

      final log = ApiLogger.entries.value.last;
      expect(log.rawRequestBody, contains('image_metadata'));
      expect(log.rawContext, contains('image_metadata'));
      expect(log.rawRequestBody, isNot(contains(imageData)));
      expect(log.rawContext, isNot(contains(imageData)));
      expect(log.requestBody, ApiLogger.safeSnippet(log.rawRequestBody!));

      final diagnostic = AppLogger.entries.value
          .lastWhere(
            (entry) =>
                entry.metadata?.containsKey('requestBodyPreview') ?? false,
          )
          .metadata!;
      expect(
        diagnostic['requestBodyBytes'],
        transport.request.bodyBytes.length,
      );
      expect(diagnostic['requestBodyPreview'], contains('image_metadata'));
      expect(
        diagnostic['requestBodyPreview'],
        isNot(contains('data:image/png')),
      );
    });
  }

  test('safe snippets retain secret masking and system prompt truncation', () {
    final systemPrompt = List.filled(250, '长').join();
    final payload = {
      'api_key': 'private-api-key',
      'credential': 'sk-abcdefghijklmnop',
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': '中文请求'},
      ],
    };

    final snippet = ApiLogger.safeSnippet(jsonEncode(payload), max: 2000);
    final decoded = jsonDecode(snippet) as Map<String, dynamic>;
    expect(decoded['api_key'], '***');
    expect(decoded['credential'], 'sk-****');
    expect(decoded['messages'][0]['content'], isNot(systemPrompt));
    expect(decoded['messages'][1]['content'], '中文请求');
    expect(payload['messages'], [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': '中文请求'},
    ]);
  });
}
