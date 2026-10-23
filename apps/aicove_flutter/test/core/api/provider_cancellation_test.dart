import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/request_control.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_http_client.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Observes the transport error, not just the runner racing a pending Future.
class AbortTrackingClient extends http.BaseClient {
  final inner = http.Client();
  final aborted = Completer<void>();
  int requests = 0;
  void record(Object error) {
    if (error is http.RequestAbortedException && !aborted.isCompleted)
      aborted.complete();
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
    'cancelling a shared MCP initialization does not cancel another task',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final initializing = Completer<void>();
      var initializations = 0;
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (body['method'] == 'initialize' && ++initializations == 1) {
          initializing.complete();
          return;
        }
        final result = body['method'] == 'tools/call'
            ? {
                'content': [
                  {'type': 'text', 'text': 'second task finished'},
                ],
              }
            : {'protocolVersion': McpHttpClient.protocolVersion};
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
        );
        await request.response.close();
      });
      final transport = http.Client();
      addTearDown(transport.close);
      final url = 'http://127.0.0.1:${server.port}';
      final mcp = McpHttpClient(url: url, client: transport);
      final tool = McpConnectorPlugin(
        McpConnector(
          id: 'shared',
          url: url,
          tools: const [McpToolInfo(name: 'read')],
        ),
        clientFactory: () => mcp,
      ).getTools().single;
      final firstSignal = KernelCancellation();
      final secondSignal = KernelCancellation();
      Future<ToolOutput> invoke(KernelCancellation signal, String id) =>
          ToolCallContext(
            sessionId: id,
            turnId: id,
            round: 1,
            toolCallId: id,
            cancellation: signal,
          ).run(() => tool.invoke({}));
      final first = expectLater(
        invoke(firstSignal, 'first'),
        throwsA(isA<KernelCancelledException>()),
      );
      await initializing.future;
      final second = invoke(secondSignal, 'second');
      firstSignal.cancel();
      await first;
      final output = await second.timeout(const Duration(seconds: 3));
      expect(output.text, 'second task finished');
      expect(secondSignal.isCancelled, false);
      expect(initializations, 2);
    },
  );

  for (final provider in ['openai', 'claude', 'gemini', 'minimax']) {
    for (final streaming in [false, true]) {
      test('$provider aborts in-flight HTTP (streaming=$streaming)', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final started = Completer<void>();
        server.listen((request) async {
          await request.drain<void>();
          // Streaming cancellation is checked after response headers, while
          // non-streaming cancellation is checked before any response arrives.
          if (streaming) {
            request.response.headers.set('content-type', 'text/event-stream');
            request.response.write(': waiting\n\n');
            await request.response.flush();
          }
          if (!started.isCompleted) started.complete();
        });
        final transport = AbortTrackingClient();
        addTearDown(transport.close);
        final cancellation = KernelCancellation();
        final api = KernelApiRunner.withAgentClientFactory(
          agentClientFactory: (_) => AgentApiClient(client: transport),
        );
        var fallbacks = 0;
        final future = api.executeApiCall(
          config: ApiConfig(
            settings: mapUiModelsToAppSettings({}),
            modelFullId: '$provider:test',
            providerApiBase: 'http://127.0.0.1:${server.port}',
            providerApiKey: 'local-test-only',
            customConfig: const {},
            messages: const [
              {'role': 'user', 'content': 'wait'},
            ],
          ),
          sessionId: 'cancel',
          userText: null,
          responseProcessors: const [],
          enableStreaming: streaming,
          cancellation: cancellation,
          onStreamingFallback: () => fallbacks++,
        );
        final checked = expectLater(
          future,
          throwsA(isA<KernelCancelledException>()),
        );
        await started.future.timeout(const Duration(seconds: 3));
        final stopwatch = Stopwatch()..start();
        cancellation.cancel();
        await checked.timeout(const Duration(seconds: 1));
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
        await transport.aborted.future.timeout(const Duration(seconds: 1));
        expect(fallbacks, 0);
        expect(
          transport.requests,
          1,
          reason: 'Cancellation must not trigger streaming fallback or retries',
        );
      });
    }
  }

  test(
    'provider HTTP errors preserve status and Retry-After for current-round retry',
    () async {
      final client = AgentApiClient(
        client: MockClient(
          (_) async =>
              http.Response('busy', 429, headers: {'retry-after': '7'}),
        ),
      );
      await expectLater(
        client.sendMessageRich(
          agentId: 'test',
          sessionId: 'test',
          modelFullId: 'openai:test',
          messages: const [],
          userText: '',
          providerApiBase: 'https://invalid.test',
          providerApiKey: 'test',
        ),
        throwsA(
          isA<ModelHttpException>()
              .having((e) => e.status, 'status', 429)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 7),
              ),
        ),
      );
    },
  );

  test(
    'MCP cooperative handler aborts only its request and reports progress',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final started = Completer<void>();
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final method = body['method'];
        if (method == 'tools/call') {
          started.complete();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': {'protocolVersion': McpHttpClient.protocolVersion},
          }),
        );
        await request.response.close();
      });
      final transport = AbortTrackingClient();
      addTearDown(transport.close);
      final url = 'http://127.0.0.1:${server.port}';
      final mcp = McpHttpClient(url: url, client: transport);
      final plugin = McpConnectorPlugin(
        McpConnector(
          id: 'test',
          url: url,
          tools: const [McpToolInfo(name: 'wait')],
        ),
        clientFactory: () => mcp,
      );
      final cancellation = KernelCancellation();
      final progress = <String>[];
      final context = ToolCallContext(
        sessionId: 'c',
        turnId: 't',
        round: 1,
        toolCallId: 'mcp',
        cancellation: cancellation,
        onProgress: progress.add,
      );
      final checked = expectLater(
        context.run(() => plugin.getTools().single.invoke({})),
        throwsA(isA<KernelCancelledException>()),
      );
      await started.future.timeout(const Duration(seconds: 3));
      cancellation.cancel();
      await checked.timeout(const Duration(seconds: 1));
      await transport.aborted.future.timeout(const Duration(seconds: 1));
      expect(progress, ['Calling MCP wait']);
      // Client is reusable: cancellation never closes a pooled MCP connection.
      expect(transport.requests, 3);
    },
  );
}
