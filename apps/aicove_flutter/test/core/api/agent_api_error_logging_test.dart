import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';

class _ThrowingClient extends http.BaseClient {
  _ThrowingClient(this.error);

  final Object error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentApiClient exception logging', () {
    setUp(() {
      ApiLogger.clear();
      TraceStore.instance.debugResetForTest();
    });

    test('sendMessageRich should write failed ApiLogEntry on network exception',
        () async {
      final client = AgentApiClient(client: _ThrowingClient(Exception('boom')));

      await expectLater(
        client.sendMessageRich(
          agentId: 'agent_1',
          sessionId: 'session_1',
          modelFullId: 'openai:gpt-4o-mini',
          messages: const <Map<String, dynamic>>[],
          userText: '你好',
          providerApiBase: 'https://api.openai.com/v1',
          providerApiKey: 'test-key',
          turnId: 'turn_1',
          roundIndex: 1,
          traceId: 'tr_error_non_stream',
        ),
        throwsA(isA<Exception>()),
      );

      final logs = ApiLogger.entries.value;
      expect(logs, isNotEmpty);
      final latest = logs.last;
      expect(latest.ok, isFalse);
      expect(latest.eventType, 'round');
      expect(latest.stage, TraceStage.modelResponseReceived.value);
      expect(latest.stageStatus, TraceEventStatus.failed.value);
      expect(latest.eventSeq, isNotNull);
      expect(latest.rawRequestBody, isNotNull);
    });

    test(
        'sendMessageRichStream should write failed ApiLogEntry on network exception',
        () async {
      final client = AgentApiClient(client: _ThrowingClient(Exception('boom')));

      await expectLater(
        client.sendMessageRichStream(
          agentId: 'agent_1',
          sessionId: 'session_1',
          modelFullId: 'openai:gpt-4o-mini',
          messages: const <Map<String, dynamic>>[],
          userText: '你好',
          providerApiBase: 'https://api.openai.com/v1',
          providerApiKey: 'test-key',
          turnId: 'turn_1',
          roundIndex: 1,
          traceId: 'tr_error_stream',
        ),
        throwsA(isA<Exception>()),
      );

      final logs = ApiLogger.entries.value;
      expect(logs, isNotEmpty);
      final latest = logs.last;
      expect(latest.ok, isFalse);
      expect(latest.eventType, 'round_stream');
      expect(latest.stage, TraceStage.modelStreamAggregated.value);
      expect(latest.stageStatus, TraceEventStatus.failed.value);
      expect(latest.eventSeq, isNotNull);
      expect(latest.rawRequestBody, isNotNull);
    });
  });
}
