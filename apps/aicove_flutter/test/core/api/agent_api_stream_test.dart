import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();
  group('AgentApiClient.sendMessageRichStream', () {
    setUp(() {
      ApiLogger.clear();
      TraceStore.instance.debugResetForTest();
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

    test('writes ApiLogEntry.eventSeq from TraceStore when traceId is provided',
        () async {
      final client = AgentApiClient(
        client: _FakeStreamingClient(
          statusCode: 200,
          responseLines: const <String>[
            'data: {"choices":[{"delta":{"content":"Hello"}}]}',
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
        turnId: 'turn_1',
        roundIndex: 1,
        traceId: 'tr_test_stream',
      );

      expect(result.text, 'Hello');
      final latest = ApiLogger.entries.value.last;
      expect(latest.eventSeq, isNotNull);
      expect(latest.eventSeq!, greaterThan(0));
    });

    test('supports gemini stream with text/functionCall parts and preserves thoughtSignature',
        () async {
      final client = AgentApiClient(
        client: _FakeStreamingClient(
          statusCode: 200,
          responseLines: const <String>[
            'data: {"candidates":[{"content":{"role":"model","parts":[{"text":"你好"}]}}]}',
            '',
            'data: {"candidates":[{"content":{"role":"model","parts":[{"text":"，世界"},{"functionCall":{"name":"lookup_weather","args":{"city":"Shanghai"}},"thoughtSignature":"sig_lookup_weather"}]}}]}',
            '',
          ],
        ),
      );

      final result = await client.sendMessageRichStream(
        agentId: 'agent_1',
        sessionId: 'session_1',
        modelFullId: 'gemini:gemini-2.0-flash',
        messages: const <Map<String, dynamic>>[],
        userText: '继续',
        providerApiBase: 'https://generativelanguage.googleapis.com/v1beta',
        providerApiKey: 'test-key',
      );

      expect(result.text, '你好，世界');
      expect(result.toolCalls, hasLength(1));
      expect(result.toolCalls.first.name, 'lookup_weather');
      expect(result.toolCalls.first.arguments['city'], 'Shanghai');
      expect(result.toolCalls.first.thoughtSignature, 'sig_lookup_weather');

      final rawCandidates = result.rawResponse?['candidates'];
      expect(rawCandidates, isA<List>());
      expect((rawCandidates as List).isNotEmpty, isTrue);
      final firstCandidate = rawCandidates.first as Map<String, dynamic>;
      final content = firstCandidate['content'] as Map<String, dynamic>?;
      final parts = content?['parts'] as List?;
      expect(parts, isNotNull);
      final functionCallPart =
          parts!.last as Map<String, dynamic>;
      expect(functionCallPart['thoughtSignature'], 'sig_lookup_weather');

      final latest = ApiLogger.entries.value.last;
      expect(latest.url, contains(':streamGenerateContent'));
      expect(latest.url, contains('alt=sse'));
    });

    test('supports claude stream with text_delta and input_json_delta',
        () async {
      final client = AgentApiClient(
        client: _FakeStreamingClient(
          statusCode: 200,
          responseLines: const <String>[
            'event: message_start',
            'data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[]}}',
            '',
            'event: content_block_start',
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
            '',
            'event: content_block_delta',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}',
            '',
            'event: content_block_start',
            'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"lookup_weather","input":{}}}',
            '',
            'event: content_block_delta',
            'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":\\"Shanghai\\"}"}}',
            '',
            'event: content_block_stop',
            'data: {"type":"content_block_stop","index":1}',
            '',
            'event: message_stop',
            'data: {"type":"message_stop"}',
            '',
          ],
        ),
      );

      final result = await client.sendMessageRichStream(
        agentId: 'agent_1',
        sessionId: 'session_1',
        modelFullId: 'claude:claude-sonnet-4-6',
        messages: const <Map<String, dynamic>>[],
        userText: '继续',
        providerApiBase: 'https://api.anthropic.com',
        providerApiKey: 'test-key',
      );

      expect(result.text, '你好');
      expect(result.toolCalls, hasLength(1));
      expect(result.toolCalls.first.id, 'toolu_1');
      expect(result.toolCalls.first.name, 'lookup_weather');
      expect(result.toolCalls.first.arguments['city'], 'Shanghai');

      final rawContent = result.rawResponse?['content'];
      expect(rawContent, isA<List>());
      expect((rawContent as List).length, 2);
    });
  });
}
