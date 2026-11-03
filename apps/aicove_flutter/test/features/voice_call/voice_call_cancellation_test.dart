import 'dart:async';
import 'dart:io';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_session.dart';
import 'package:aicove_flutter/src/features/voice_call/data/api_runner_call_reply_generator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'voice_call_fakes.dart';

/// Check the actual transport error, not only the cooperative cancellation flag.
class _Transport extends http.BaseClient {
  final inner = http.Client();
  final aborted = Completer<void>();
  int requests = 0;

  void record(Object error) {
    if (error is http.RequestAbortedException && !aborted.isCompleted) {
      aborted.complete();
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    expect(request, isA<http.AbortableRequest>());
    try {
      final response = await inner.send(request);
      return http.StreamedResponse(
        response.stream.handleError((Object error) {
          record(error);
          throw error;
        }),
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    } catch (error) {
      record(error);
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'hangUp cancels the real in-flight voice HTTP stream without retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final started = Completer<void>();
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.set('content-type', 'text/event-stream');
        request.response.write(': waiting\n\n');
        await request.response.flush();
        if (!started.isCompleted) started.complete();
      });
      final transport = _Transport();
      addTearDown(transport.close);
      final input = FakeInput();
      final output = FakeOutput();
      final tts = FakeTts();
      final recognizer = FakeRecognizer();
      final session = VoiceCallSession(
        recognizer: recognizer,
        tts: tts,
        input: input,
        output: output,
        greetOnConnect: false,
        userTurnGap: Duration.zero,
        generator: ApiRunnerCallReplyGenerator(
          runner: KernelApiRunner.withAgentClientFactory(
            agentClientFactory: (_) => AgentApiClient(client: transport),
          ),
          base: ApiConfig(
            settings: mapUiModelsToAppSettings({}),
            modelFullId: 'openai:test',
            providerApiBase: 'http://127.0.0.1:${server.port}',
            providerApiKey: 'local-test-only',
            customConfig: const {},
            messages: const [],
          ),
          sessionId: 'voice_cancel',
        ),
      );
      addTearDown(session.hangUp);
      await session.start();
      expect(session.sendText('等待'), isTrue);
      await started.future.timeout(const Duration(seconds: 3));
      await session.hangUp().timeout(const Duration(seconds: 1));
      await transport.aborted.future.timeout(const Duration(seconds: 1));
      expect(session.phase, VoiceCallPhase.ended);
      expect(transport.requests, 1);
      expect(tts.spoken, isEmpty);
      expect(
        input.stopped && output.stopped && tts.closed && recognizer.disposed,
        isTrue,
      );
    },
  );
}
