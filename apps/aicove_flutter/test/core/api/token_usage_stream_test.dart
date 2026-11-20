import 'dart:async';
import 'dart:convert';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/features/observability/token_usage_ledger.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

class _UsageClient extends http.BaseClient {
  _UsageClient(this.respond);
  final FutureOr<http.StreamedResponse> Function(int index) respond;
  final List<Map<String, dynamic>> bodies = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    bodies.add(
      jsonDecode(utf8.decode((request as http.Request).bodyBytes))
          as Map<String, dynamic>,
    );
    return respond(bodies.length - 1);
  }
}

http.StreamedResponse _sse(List<Object> events, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(
        utf8.encode(
          [
            for (final event in events)
              'data: ${event is String ? event : jsonEncode(event)}\n\n',
          ].join(),
        ),
      ),
      status,
      headers: {'content-type': 'text/event-stream'},
    );

http.StreamedResponse _json(Object body, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
      headers: {'content-type': 'application/json'},
    );

Future<SendMessageRichResult> _call(
  _UsageClient transport, {
  bool stream = true,
  String model = 'openai:test-model',
  String endpoint = 'https://proxy.example/v1',
  Map<String, dynamic>? config,
  String? traceId,
  TokenUsageCaptureScope? capture,
}) {
  final client = AgentApiClient(client: transport);
  final send = stream ? client.sendMessageRichStream : client.sendMessageRich;
  Future<SendMessageRichResult> invoke() => send(
    agentId: 'test',
    sessionId: 'conversation',
    turnId: 'turn',
    roundIndex: 1,
    traceId: traceId,
    modelFullId: model,
    providerApiBase: endpoint,
    providerApiKey: 'test-key',
    messages: const [
      {'role': 'system', 'content': 'You are helpful.'},
    ],
    userText: '你好，请给我一个答案',
    customConfig: config,
  );
  return capture == null ? invoke() : capture.run(invoke);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AgentApiClient.clearStreamUsageFallbackCache();
    ApiLogger.clear();
    TraceStore.instance.debugResetForTest();
  });

  test(
    'OpenAI empty choices usage is retained and propagated to logs and trace',
    () async {
      final client = _UsageClient(
        (_) => _sse([
          {
            'choices': [
              {
                'delta': {'content': 'hello'},
              },
            ],
          },
          {
            'choices': [],
            'usage': {
              'prompt_tokens': 100,
              'completion_tokens': 30,
              'prompt_tokens_details': {'cached_tokens': 40},
              'completion_tokens_details': {'reasoning_tokens': 10},
            },
          },
          '[DONE]',
        ]),
      );
      final result = await _call(client, traceId: 'usage-openai');
      expect(client.bodies.single['stream_options'], {'include_usage': true});
      expect(result.text, 'hello');
      expect(result.usage?.toJson(), {
        'inputTokens': 100,
        'outputTokens': 30,
        'cachedInputTokens': 40,
        'cacheWriteTokens': 0,
        'reasoningTokens': 10,
        'isEstimated': false,
      });
      final log = ApiLogger.entries.value.last;
      expect(log.inputTokens, 100);
      expect(log.outputTokens, 30);
      expect(log.cachedInputTokens, 40);
      expect(log.cacheWriteTokens, 0);
      expect(log.reasoningTokens, 10);
      expect(log.usageEstimated, false);
      final event = TraceStore.instance.debugInMemoryEvents().lastWhere(
        (event) => event.stage == TraceStage.modelStreamAggregated.value,
      );
      expect(event.meta?['inputTokens'], 100);
      expect(event.meta?['usageEstimated'], false);
    },
  );

  test(
    'OpenAI uses the latest cumulative usage snapshot rather than summing',
    () async {
      final result = await _call(
        _UsageClient(
          (_) => _sse([
            {
              'usage': {'prompt_tokens': 10, 'completion_tokens': 2},
            },
            {
              'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
            },
            '[DONE]',
          ]),
        ),
      );
      expect(result.usage?.totalTokens, 15);
    },
  );

  test(
    'Responses nested usage works without choices and never injects options',
    () async {
      final client = _UsageClient(
        (_) => _sse([
          {'type': 'response.output_text.delta', 'delta': 'done'},
          {
            'type': 'response.completed',
            'response': {
              'usage': {
                'input_tokens': 80,
                'output_tokens': 20,
                'input_tokens_details': {'cached_tokens': 50},
                'output_tokens_details': {'reasoning_tokens': 8},
              },
            },
          },
          '[DONE]',
        ]),
      );
      final result = await _call(client, config: {'apiPath': '/responses'});
      expect(client.bodies.single.containsKey('stream_options'), false);
      expect(result.usage?.inputTokens, 80);
      expect(result.usage?.outputTokens, 20);
      expect(result.usage?.cachedInputTokens, 50);
      expect(result.usage?.reasoningTokens, 8);
    },
  );

  test(
    'Claude start and delta usage merge non-null fields without double counting',
    () async {
      final client = _UsageClient(
        (_) => _sse([
          {
            'type': 'message_start',
            'message': {
              'usage': {
                'input_tokens': 10,
                'cache_read_input_tokens': 20,
                'cache_creation_input_tokens': 5,
                'output_tokens': 0,
              },
            },
          },
          {
            'type': 'content_block_delta',
            'delta': {'type': 'text_delta', 'text': 'ok'},
          },
          {
            'type': 'message_delta',
            'usage': {'input_tokens': null, 'output_tokens': 3},
          },
          {
            'type': 'message_delta',
            'usage': {'output_tokens': 7},
          },
          {'type': 'message_stop'},
        ]),
      );
      final result = await _call(client, model: 'claude:claude-test');
      expect(client.bodies.single.containsKey('stream_options'), false);
      expect(result.usage?.inputTokens, 35);
      expect(result.usage?.uncachedInputTokens, 10);
      expect(result.usage?.cachedInputTokens, 20);
      expect(result.usage?.cacheWriteTokens, 5);
      expect(result.usage?.outputTokens, 7);
    },
  );

  for (final jsonBody in [false, true]) {
    test(
      'Gemini latest cumulative usage includes thought output, JSON=$jsonBody',
      () async {
        final events = [
          {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
              },
            ],
            'usageMetadata': {
              'promptTokenCount': 100,
              'candidatesTokenCount': 3,
              'totalTokenCount': 103,
            },
          },
          {
            'usageMetadata': {
              'promptTokenCount': 100,
              'cachedContentTokenCount': 50,
              'candidatesTokenCount': 5,
              'thoughtsTokenCount': 8,
              'totalTokenCount': 113,
            },
          },
        ];
        final result = await _call(
          _UsageClient((_) => jsonBody ? _json(events) : _sse(events)),
          model: 'gemini:gemini-test',
          endpoint: 'https://generativelanguage.googleapis.com/v1beta',
        );
        expect(result.usage?.inputTokens, 100);
        expect(result.usage?.cachedInputTokens, 50);
        expect(result.usage?.outputTokens, 13);
        expect(result.usage?.reasoningTokens, 8);
      },
    );
  }

  for (final status in [400, 422]) {
    test(
      'auto injected options fall back once and cache by endpoint/model, HTTP $status',
      () async {
        final client = _UsageClient(
          (index) =>
              index == 0
                  ? _json({
                    'error': 'unsupported stream_options.include_usage',
                  }, status: status)
                  : _sse([
                    {
                      'usage': {'prompt_tokens': 10, 'completion_tokens': 2},
                    },
                    '[DONE]',
                  ]),
        );
        final capture = TokenUsageCaptureScope();
        await _call(client, capture: capture);
        expect(capture.usage.totalTokens, 12);
        expect(client.bodies.length, 2);
        expect(client.bodies.first['stream_options'], {'include_usage': true});
        expect(client.bodies[1].containsKey('stream_options'), false);
        await _call(client);
        expect(client.bodies[2].containsKey('stream_options'), false);
        await _call(client, model: 'openai:another-model');
        expect(client.bodies[3]['stream_options'], {'include_usage': true});
        await _call(client, endpoint: 'https://other.example/v1');
        expect(client.bodies[4]['stream_options'], {'include_usage': true});
      },
    );
  }

  for (final extraBody in [false, true]) {
    test(
      'explicit options are preserved and never silently retried, extraBody=$extraBody',
      () async {
        final client = _UsageClient(
          (_) => _json({'error': 'include_usage unsupported'}, status: 400),
        );
        final explicit = {'include_usage': false, 'custom': true};
        await expectLater(
          _call(
            client,
            config:
                extraBody
                    ? {
                      'extraBody': {'stream_options': explicit},
                    }
                    : {'stream_options': explicit},
          ),
          throwsException,
        );
        expect(client.bodies, hasLength(1));
        expect(client.bodies.single['stream_options'], explicit);
        expect(ApiLogger.entries.value.last.inputTokens, isNull);
      },
    );
  }

  for (final rejection in [
    (400, 'invalid model'),
    (500, 'stream_options unsupported'),
  ]) {
    test('unrelated or server rejection is not retried: $rejection', () async {
      final client = _UsageClient(
        (_) => _json({'error': rejection.$2}, status: rejection.$1),
      );
      final capture = TokenUsageCaptureScope();
      await expectLater(_call(client, capture: capture), throwsException);
      expect(capture.usage.totalTokens, 0);
      expect(client.bodies, hasLength(1));
      expect(ApiLogger.entries.value.last.inputTokens, isNull);
    });
  }

  test(
    'repeated rejection retries once only and does not log/count the rejected first attempt',
    () async {
      final client = _UsageClient(
        (_) => _json({'error': 'include_usage unsupported'}, status: 400),
      );
      await expectLater(_call(client), throwsException);
      expect(client.bodies, hasLength(2));
      expect(
        ApiLogger.entries.value.where(
          (entry) => entry.eventType == 'round_stream',
        ),
        hasLength(1),
      );
      expect(ApiLogger.entries.value.last.inputTokens, isNull);
    },
  );

  for (final stream in [false, true]) {
    test(
      'missing usage estimates sent context and received output, stream=$stream',
      () async {
        final client = _UsageClient(
          (_) =>
              stream
                  ? _sse([
                    {
                      'choices': [
                        {
                          'delta': {'content': '你好世界'},
                        },
                      ],
                    },
                    '[DONE]',
                  ])
                  : _json({
                    'choices': [
                      {
                        'message': {'content': '你好世界'},
                      },
                    ],
                  }),
        );
        final result = await _call(client, stream: stream);
        expect(result.usage?.isEstimated, true);
        expect(result.usage?.inputTokens, greaterThan(0));
        expect(result.usage?.outputTokens, greaterThan(0));
        expect(ApiLogger.entries.value.last.usageEstimated, true);
        if (!stream) {
          expect(client.bodies.single.containsKey('stream_options'), false);
        }
      },
    );
  }

  test('non-stream exact usage propagates through result/log/trace', () async {
    final result = await _call(
      _UsageClient(
        (_) => _json({
          'choices': [
            {
              'message': {'content': 'ok'},
            },
          ],
          'usage': {
            'prompt_tokens': 25,
            'completion_tokens': 4,
            'prompt_cache_hit_tokens': 12,
          },
        }),
      ),
      stream: false,
      traceId: 'usage-direct',
    );
    expect(result.usage?.inputTokens, 25);
    expect(result.usage?.cachedInputTokens, 12);
    expect(result.usage?.isEstimated, false);
    expect(ApiLogger.entries.value.last.outputTokens, 4);
    final event = TraceStore.instance.debugInMemoryEvents().lastWhere(
      (event) => event.stage == TraceStage.modelResponseReceived.value,
    );
    expect(event.meta?['inputTokens'], 25);
  });

  for (final stream in [false, true]) {
    for (final cancelled in [false, true]) {
      test(
        'partial 2xx interruption retains estimated usage, stream=$stream cancellation=$cancelled',
        () async {
          final error =
              cancelled
                  ? http.RequestAbortedException()
                  : StateError('connection closed');
          final client = _UsageClient(
            (_) => http.StreamedResponse(
              (() async* {
                yield utf8.encode(
                  stream
                      ? 'data: {"choices":[{"delta":{"content":"已收到的回答"}}]}\n\n'
                      : '{"choices":[{"message":{"content":"已收到的回答',
                );
                throw error;
              })(),
              200,
            ),
          );
          final capture = TokenUsageCaptureScope();
          await expectLater(
            _call(client, stream: stream, capture: capture),
            throwsA(same(error)),
          );
          expect(capture.usage.totalTokens, greaterThan(0));
          expect(capture.usage.isEstimated, true);
          final log = ApiLogger.entries.value.last;
          expect(log.ok, false);
          expect(log.status, 200);
          expect(log.usageEstimated, true);
          expect(log.inputTokens, greaterThan(0));
          expect(log.outputTokens, greaterThan(0));
        },
      );
    }
  }

  test(
    'Claude interruption preserves any usage already returned by the provider',
    () async {
      final client = _UsageClient(
        (_) => http.StreamedResponse(
          (() async* {
            yield utf8.encode(
              'data: {"type":"message_start","message":{"usage":{"input_tokens":50,"output_tokens":0}}}\n\n'
              'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"已收到回答"}}\n\n',
            );
            throw StateError('closed');
          })(),
          200,
        ),
      );
      await expectLater(_call(client, model: 'claude:test'), throwsStateError);
      expect(ApiLogger.entries.value.last.usageEstimated, false);
      expect(ApiLogger.entries.value.last.inputTokens, 50);
      expect(ApiLogger.entries.value.last.outputTokens, 0);
    },
  );

  for (final stream in [false, true]) {
    test('connection failure does not invent usage, stream=$stream', () async {
      final client = _UsageClient(
        (_) => throw http.ClientException('not connected'),
      );
      final capture = TokenUsageCaptureScope();
      await expectLater(
        _call(client, stream: stream, capture: capture),
        throwsA(isA<http.ClientException>()),
      );
      expect(capture.usage.totalTokens, 0);
      expect(ApiLogger.entries.value.last.inputTokens, isNull);
      expect(ApiLogger.entries.value.last.usageEstimated, isNull);
    });
  }

  for (final cancelled in [false, true]) {
    test('empty 2xx interrupted stream does not record input, cancellation=$cancelled', () async {
      final error = cancelled ? http.RequestAbortedException() : StateError('closed before content');
      final client = _UsageClient((_) => http.StreamedResponse(Stream.error(error), 200));
      final capture = TokenUsageCaptureScope();
      await expectLater(_call(client, capture: capture), throwsA(same(error)));
      expect(capture.usage.totalTokens, 0);
      expect(ApiLogger.entries.value.last.inputTokens, isNull);
      expect(ApiLogger.entries.value.last.usageEstimated, isNull);
    });
  }

  test('normally completed empty 2xx stream still estimates sent input', () async {
    final capture = TokenUsageCaptureScope();
    final result = await _call(_UsageClient((_) => _sse(['[DONE]'])), capture: capture);
    expect(result.usage?.isEstimated, true);
    expect(result.usage?.inputTokens, greaterThan(0));
    expect(capture.usage.inputTokens, result.usage?.inputTokens);
  });

  test(
    'HTTP ledger persists one row after fallback and partial cancellation, none after failures',
    () async {
      SharedPreferences.setMockInitialValues({
        'aicove.cloud.device_id': 'usage-test-device',
      });
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      TokenUsageLedger.instance.bindDatabase(
        database,
        isBackgroundIsolate: true,
      );
      addTearDown(() async {
        TokenUsageLedger.instance.unbindDatabase(database);
        await database.close();
      });
      final capture = TokenUsageCaptureScope(
        purpose: 'context_compaction',
        conversationId: 'actual-conversation',
      );
      final fallback = _UsageClient(
        (index) =>
            index == 0
                ? _json({'error': 'include_usage unsupported'}, status: 422)
                : _sse([
                  {
                    'usage': {'prompt_tokens': 80, 'completion_tokens': 10},
                  },
                  '[DONE]',
                ]),
      );
      await _call(fallback, capture: capture);
      final cancelled = _UsageClient(
        (_) => http.StreamedResponse(
          (() async* {
            yield utf8.encode(
              'data: {"choices":[{"delta":{"content":"received answer"}}]}\n\n',
            );
            throw http.RequestAbortedException();
          })(),
          200,
        ),
      );
      await expectLater(
        _call(cancelled, capture: capture),
        throwsA(isA<http.RequestAbortedException>()),
      );
      final rejected = _UsageClient(
        (_) => _json({'error': 'forbidden'}, status: 403),
      );
      await expectLater(_call(rejected, capture: capture), throwsException);
      final disconnected = _UsageClient(
        (_) => throw http.ClientException('offline'),
      );
      await expectLater(
        _call(disconnected, capture: capture),
        throwsA(isA<http.ClientException>()),
      );
      final rows = await TokenUsageLedger.instance.all();
      expect(rows, hasLength(2));
      rows.sort((a, b) => a.occurredAtMs.compareTo(b.occurredAtMs));
      expect(rows[0].purpose, 'context_compaction');
      expect(rows[0].conversationId, 'actual-conversation');
      expect(rows[0].requestId, isNot(rows[1].requestId));
      expect(capture.usage.inputTokens, greaterThan(80));
      expect(capture.usage.outputTokens, greaterThan(10));
      expect(capture.usage.isEstimated, true);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((key) => key.startsWith(tokenUsageRollupPrefix)),
        isEmpty,
      );
    },
  );
}
