import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/image_providers/comfyui_image_adapter.dart';
import 'package:aicove_flutter/src/core/api/image_providers/image_provider_adapter.dart';
import 'package:aicove_flutter/src/core/api/image_providers/openai_compatible_image_adapter.dart';
import 'package:aicove_flutter/src/core/api/request_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

class _AbortTrackingClient extends http.BaseClient {
  final _inner = http.Client();
  final aborted = Completer<void>();

  void _record(Object error) {
    if (error is http.RequestAbortedException && !aborted.isCompleted) {
      aborted.complete();
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      final response = await _inner.send(request);
      return http.StreamedResponse(
        response.stream.handleError((Object error) {
          _record(error);
          throw error;
        }),
        response.statusCode,
        headers: response.headers,
      );
    } catch (error) {
      _record(error);
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

http.StreamedResponse _json(Object body) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  200,
  headers: {'content-type': 'application/json'},
);

ImageProviderRequest _imageRequest(String provider) => ImageProviderRequest(
  provider: provider,
  model: provider == 'comfyui' ? 'template/test' : 'image-model',
  prompt: 'test',
  width: 512,
  height: 512,
  count: 1,
  baseUrl: 'https://local.test',
  apiKey: 'test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  const timeout = Duration(milliseconds: 30);
  for (final mode in [
    'error body',
    'Gemini JSON body',
    'SSE body',
    'direct body',
  ]) {
    test('$mode times out after headers when the body stalls', () async {
      final body = StreamController<List<int>>();
      addTearDown(() => body.close());
      final api = AgentApiClient(
        timeout: timeout,
        client: _Client(
          (_) async => http.StreamedResponse(
            body.stream,
            mode == 'error body' ? 500 : 200,
            headers: {
              'content-type': mode == 'Gemini JSON body'
                  ? 'application/json'
                  : 'text/event-stream',
            },
          ),
        ),
      );
      final pending = mode == 'direct body'
          ? api.sendMessageRich(
              agentId: 'a',
              sessionId: 's',
              modelFullId: 'openai:test',
              messages: [],
              userText: '',
              providerApiBase: 'https://local.test',
              providerApiKey: 'test',
            )
          : api.sendMessageRichStream(
              agentId: 'a',
              sessionId: 's',
              modelFullId: mode == 'Gemini JSON body'
                  ? 'gemini:test'
                  : 'openai:test',
              messages: [],
              userText: '',
              providerApiBase: 'https://local.test',
              providerApiKey: 'test',
            );
      await expectLater(
        pending.timeout(
          const Duration(milliseconds: 250),
          onTimeout: () => throw StateError('body read did not time out'),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  }

  test(
    'SSE timeout resets on raw chunks before a complete line arrives',
    () async {
      final body = StreamController<List<int>>();
      final client = _Client((_) async {
        unawaited(() async {
          for (final chunk in [
            'data:',
            ' {"choices":',
            '[{"delta":',
            '{"content":"ok"}}]}\n\n',
            'data: [DONE]\n\n',
          ]) {
            await Future<void>.delayed(const Duration(milliseconds: 15));
            body.add(utf8.encode(chunk));
          }
          await body.close();
        }());
        return http.StreamedResponse(
          body.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final api = AgentApiClient(
        client: client,
        timeout: const Duration(milliseconds: 50),
      );
      final result = await api.sendMessageRichStream(
        agentId: 'a',
        sessionId: 's',
        modelFullId: 'openai:test',
        messages: [],
        userText: '',
        providerApiBase: 'https://local.test',
        providerApiKey: 'test',
      );
      expect(result.text, 'ok');
    },
  );

  for (final provider in ['novelai', 'openai', 'comfyui']) {
    test('$provider submits an abortable image request', () async {
      http.BaseRequest? sent;
      final signal = KernelCancellation();
      final client = _Client((request) async {
        sent = request;
        await Future<void>.delayed(Duration.zero);
        signal.cancel();
        return _json({
          'data': [
            {'b64_json': 'AQ=='},
          ],
          'prompt_id': 'job',
        });
      });
      final checked = expectLater(
        RequestControl.run(
          signal,
          () => AgentApiClient(client: client).generateImage(
            provider: provider,
            model: provider == 'comfyui' ? 'template/test' : 'image-model',
            prompt: 'test',
            providerApiBase: 'https://local.test',
            providerApiKey: 'test',
          ),
        ),
        throwsA(isA<KernelCancelledException>()),
      );
      await checked;
      expect(sent, isA<http.AbortableRequest>());
      await (sent as http.AbortableRequest).abortTrigger!.timeout(
        const Duration(seconds: 1),
      );
    });
  }

  for (final provider in ['novelai', 'openai', 'comfyui']) {
    test(
      '$provider cancellation aborts the actual image response body',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final started = Completer<void>();
        server.listen((request) async {
          await request.drain<void>();
          request.response.write('{');
          await request.response.flush();
          started.complete();
        });
        final client = _AbortTrackingClient();
        addTearDown(client.close);
        final signal = KernelCancellation();
        final checked = expectLater(
          RequestControl.run(
            signal,
            () => AgentApiClient(client: client).generateImage(
              provider: provider,
              model: provider == 'comfyui' ? 'template/test' : 'image-model',
              prompt: 'test',
              providerApiBase: 'http://127.0.0.1:${server.port}',
              providerApiKey: 'test',
            ),
          ),
          throwsA(isA<KernelCancelledException>()),
        );
        await started.future.timeout(const Duration(seconds: 2));
        signal.cancel();
        await checked.timeout(const Duration(seconds: 1));
        await client.aborted.future.timeout(const Duration(seconds: 1));
      },
    );
  }

  for (final provider in ['openai', 'comfyui']) {
    test('$provider discards a body completed after cancellation', () async {
      final body = StreamController<List<int>>();
      final signal = KernelCancellation();
      final received = Completer<void>();
      final client = _Client((_) async {
        received.complete();
        return http.StreamedResponse(body.stream, 200);
      });
      final ImageProviderAdapter adapter = provider == 'openai'
          ? OpenAICompatibleImageAdapter()
          : const ComfyUIImageAdapter();
      late Future<ImageProviderResponse> operation;
      final outer = expectLater(
        RequestControl.run(signal, () {
          operation = adapter.generate(
            client: client,
            timeout: const Duration(seconds: 1),
            request: _imageRequest(provider),
          );
          return operation;
        }),
        throwsA(isA<KernelCancelledException>()),
      );
      final inner = expectLater(
        operation,
        throwsA(isA<KernelCancelledException>()),
      );
      await received.future;
      await Future<void>.delayed(Duration.zero);
      signal.cancel();
      body.add(
        utf8.encode(
          jsonEncode({
            'data': [
              {'b64_json': 'AQ=='},
            ],
            'prompt_id': 'job',
          }),
        ),
      );
      await body.close();
      await outer;
      await inner;
    });
  }

  test('OpenAI image URL downloads are abortable', () async {
    final signal = KernelCancellation();
    var calls = 0;
    final client = _Client((request) async {
      expect(request, isA<http.AbortableRequest>());
      if (++calls == 1) {
        return _json({
          'data': [
            {'url': 'https://local.test/image'},
          ],
        });
      }
      signal.cancel();
      return http.StreamedResponse(Stream.value([1]), 200);
    });
    await expectLater(
      RequestControl.run(
        signal,
        () => OpenAICompatibleImageAdapter().generate(
          client: client,
          timeout: const Duration(seconds: 1),
          request: _imageRequest('openai'),
        ),
      ),
      throwsA(isA<KernelCancelledException>()),
    );
    expect(calls, 2);
  });

  test(
    'ComfyUI cancellation interrupts polling delay without another request',
    () async {
      final signal = KernelCancellation();
      final polled = Completer<void>();
      var calls = 0;
      final client = _Client((request) async {
        if (++calls == 1) return _json({'prompt_id': 'job'});
        polled.complete();
        return _json({});
      });
      // Run in the cancellation zone without racing the whole operation: the
      // adapter itself must leave its polling delay promptly.
      late Future<ImageProviderResponse> pending;
      final outer = expectLater(
        RequestControl.run(signal, () {
          pending =
              const ComfyUIImageAdapter(
                pollInterval: Duration(seconds: 5),
              ).generate(
                client: client,
                timeout: const Duration(seconds: 10),
                request: _imageRequest('comfyui'),
              );
          return pending;
        }),
        throwsA(isA<KernelCancelledException>()),
      );
      final checked = expectLater(
        pending.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => throw StateError('poll delay ignored cancellation'),
        ),
        throwsA(isA<KernelCancelledException>()),
      );
      await polled.future.timeout(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      signal.cancel();
      await checked;
      await outer;
      expect(calls, 2);
    },
  );
}
