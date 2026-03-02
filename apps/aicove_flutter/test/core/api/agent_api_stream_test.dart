import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';

class _FakeStreamingClient extends http.BaseClient {
  _FakeStreamingClient({
    required this.statusCode,
    required this.responseLines,
  });

  final int statusCode;
  final List<String> responseLines;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final payload = utf8.encode(responseLines.join('\n'));
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[payload]),
      statusCode,
      headers: const <String, String>{
        'content-type': 'text/event-stream',
      },
    );
  }
}

void main() {
  group('AgentApiClient.sendMessageRichStream', () {
    setUp(() {
      ApiLogger.clear();
    });

    test('returns rawResponse carrying assistant tool_calls for next round',
        () async {
      final client = AgentApiClient(
        client: _FakeStreamingClient(
          statusCode: 200,
          responseLines: const <String>[
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup_weather","arguments":"{\\"city\\":\\"Shanghai\\"}"}}]}}]}',
            '',
            'data: [DONE]',
            '',
          ],
        ),
      );

      final result = await client.sendMessageRichStream(
        agentId: 'agent_1',
        sessionId: 'session_1',
        modelFullId: 'openai:gpt-4o-mini',
        messages: const <Map<String, dynamic>>[],
        userText: '帮我查天气',
        providerApiBase: 'https://api.openai.com/v1',
        providerApiKey: 'test-key',
      );

      expect(result.toolCalls, hasLength(1));
      expect(result.toolCalls.first.id, 'call_1');
      expect(result.toolCalls.first.name, 'lookup_weather');
      expect(result.rawResponse, isNotNull);

      final choices = result.rawResponse?['choices'] as List?;
      expect(choices, isNotNull);
      expect(choices, isNotEmpty);
      final firstChoice = choices!.first as Map<String, dynamic>;
      final message = firstChoice['message'] as Map<String, dynamic>?;
      expect(message, isNotNull);
      expect(message?['tool_calls'], isA<List>());

      final logEntries = ApiLogger.entries.value;
      expect(logEntries, isNotEmpty);

      final latest = logEntries.last;
      expect(latest.eventType, 'round_stream');
      expect(latest.rawResponseBody, isNotNull);

      final rawBody = latest.rawResponseBody!;
      final decodedRaw = jsonDecode(rawBody);
      expect(decodedRaw, isA<Map<String, dynamic>>());

      final mapRaw = decodedRaw as Map<String, dynamic>;
      final streamEvents = mapRaw['streamEvents'];
      expect(streamEvents, isA<List>());
      expect((streamEvents as List).isNotEmpty, isTrue);
    });

    test('aggregates reasoning_content into rawResponse assistant message',
        () async {
      final client = AgentApiClient(
        client: _FakeStreamingClient(
          statusCode: 200,
          responseLines: const <String>[
            'data: {"choices":[{"delta":{"reasoning_content":"step_1","tool_calls":[{"index":0,"id":"call_reason","type":"function","function":{"name":"lookup_weather","arguments":"{\\"city\\":\\"Shanghai\\"}"}}]}}]}',
            '',
            'data: {"choices":[{"delta":{"reasoning_content":" + step_2"}}]}',
            '',
            'data: [DONE]',
            '',
          ],
        ),
      );

      final result = await client.sendMessageRichStream(
        agentId: 'agent_1',
        sessionId: 'session_1',
        modelFullId: 'openai:gpt-4o-mini',
        messages: const <Map<String, dynamic>>[],
        userText: 'help me check weather',
        providerApiBase: 'https://api.openai.com/v1',
        providerApiKey: 'test-key',
      );

      expect(result.toolCalls, hasLength(1));
      expect(result.toolCalls.first.id, 'call_reason');
      expect(result.rawResponse, isNotNull);

      final choices = result.rawResponse?['choices'] as List?;
      expect(choices, isNotNull);
      expect(choices, isNotEmpty);

      final firstChoice = choices!.first as Map<String, dynamic>;
      final message = firstChoice['message'] as Map<String, dynamic>?;
      expect(message, isNotNull);
      expect(message?['reasoning_content'], 'step_1 + step_2');
      expect(message?['tool_calls'], isA<List>());
      expect(message?['content'], isNull);
    });

    test('normalizes cumulative text chunks into true deltas', () async {
      final emitted = <String>[];
      final client = AgentApiClient(
        client: _FakeStreamingClient(
          statusCode: 200,
          responseLines: const <String>[
            'data: {"choices":[{"delta":{"content":"纳西妲"}}]}',
            '',
            'data: {"choices":[{"delta":{"content":"纳西妲正在看书"}}]}',
            '',
            'data: {"choices":[{"delta":{"content":"纳西妲正在看书。"}}]}',
            '',
            'data: [DONE]',
            '',
          ],
        ),
      );

      final result = await client.sendMessageRichStream(
        agentId: 'agent_1',
        sessionId: 'session_1',
        modelFullId: 'openai:gpt-4o-mini',
        messages: const <Map<String, dynamic>>[],
        userText: '继续',
        providerApiBase: 'https://api.openai.com/v1',
        providerApiKey: 'test-key',
        onTextDelta: emitted.add,
      );

      expect(result.text, '纳西妲正在看书。');
      expect(emitted.join(), '纳西妲正在看书。');
      expect(emitted, <String>['纳西妲', '正在看书', '。']);
    });

    test('avoids double-emitting when both choices and root delta exist',
        () async {
      final emitted = <String>[];
      final client = AgentApiClient(
        client: _FakeStreamingClient(
          statusCode: 200,
          responseLines: const <String>[
            'data: {"type":"response.output_text.delta","delta":"你好","choices":[{"delta":{"content":"你好"}}]}',
            '',
            'data: [DONE]',
            '',
          ],
        ),
      );

      final result = await client.sendMessageRichStream(
        agentId: 'agent_1',
        sessionId: 'session_1',
        modelFullId: 'openai:gpt-4o-mini',
        messages: const <Map<String, dynamic>>[],
        userText: '继续',
        providerApiBase: 'https://api.openai.com/v1',
        providerApiKey: 'test-key',
        onTextDelta: emitted.add,
      );

      expect(result.text, '你好');
      expect(emitted, <String>['你好']);
    });
  });
}
