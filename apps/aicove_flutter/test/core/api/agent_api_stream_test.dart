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
  });
}
