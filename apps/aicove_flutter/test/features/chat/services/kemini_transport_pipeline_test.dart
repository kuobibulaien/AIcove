import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/preset_script_runtime.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

import '../../../support/transport_preset_fixture.dart';
import 'api_runner_variants.dart';

/// HTTP boundary fake: real AgentApiClient, provider adapters, stream parsers,
/// QuickJS runtime and business tool loop all run normally; no network I/O.
class _TransportServer extends http.BaseClient {
  _TransportServer(
    this.provider, {
    this.stream = false,
    this.truncated = false,
    this.mixed = false,
    this.partial = false,
    this.jsonArray = false,
    this.progressive = false,
  });
  final String provider;
  final bool stream, truncated, mixed, partial, jsonArray, progressive;
  bool responseEnded = false;
  final requests = <Map<String, dynamic>>[];
  bool get google => provider == 'gemini';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body =
        jsonDecode(utf8.decode(await request.finalize().toBytes()))
            as Map<String, dynamic>;
    requests.add(body);
    final definitions = google
        ? ((body['tools'] as List?)?.first['functionDeclarations'] as List? ??
              [])
        : [for (final t in body['tools'] as List? ?? []) t['function']];
    final transport = definitions
        .where(
          (d) => (d['name'] as String).startsWith('emit_complete_response_'),
        )
        .toList();
    final name = transport.isEmpty ? null : transport.single['name'];
    final firstMixed = mixed && requests.length == 1;
    final reply = firstMixed
        ? '正在查看。'
        : truncated
        ? '花开了'
        : progressive
        ? '花\n开😀了。'
        : '花开了。';
    final args = truncated
        ? '{"content":"$reply'
        : progressive && !firstMixed
        ? r'{"content":"花\n开\uD83D\uDE00了。"}'
        : jsonEncode({'content': reply});
    final calls = <Map<String, dynamic>>[
      if (name != null)
        {
          'id': google ? '' : 'transport_call',
          'type': 'function',
          'function': {'name': name, 'arguments': args},
        },
      if (firstMixed)
        {
          'id': google ? '' : 'weather_call',
          'type': 'function',
          'function': {'name': 'weather', 'arguments': '{"city":"杭州"}'},
        },
    ];
    Map<String, dynamic> googleEvent(
      List<Map<String, dynamic>> parts, {
      bool done = false,
    }) => {
      'candidates': [
        {
          'content': {'role': 'model', 'parts': parts},
          if (done) 'finishReason': 'STOP',
        },
      ],
    };
    final parts = <Map<String, dynamic>>[
      // Same text in both channels must be emitted once.
      if (!truncated && !progressive) {'text': reply},
      for (final call in calls)
        {
          'functionCall': {
            'name': call['function']['name'],
            'args': call['function']['name'] == name && truncated
                ? args
                : jsonDecode(call['function']['arguments'] as String),
          },
        },
    ];
    final events = <Map<String, dynamic>>[];
    Map<String, dynamic> response;
    if (google) {
      response = googleEvent(parts, done: true);
      if (partial && name != null) {
        events.add(
          googleEvent([
            {
              'functionCall': {'name': name, 'willContinue': true},
            },
          ]),
        );
        for (final fragment
            in progressive ? ['花', '\n', '开', '😀', '了', '。'] : ['花', '开了。']) {
          events.add(
            googleEvent([
              {
                'functionCall': {
                  'partialArgs': [
                    {'jsonPath': r'$.content', 'stringValue': fragment},
                  ],
                  'willContinue': true,
                },
              },
            ]),
          );
        }
        events.add(
          googleEvent([
            {
              'functionCall': {
                'partialArgs': [
                  {'jsonPath': r'$.content'},
                ],
              },
            },
          ]),
        );
        events.add(
          googleEvent([
            {'functionCall': {}},
          ], done: true),
        );
      } else {
        events.add(response);
      }
    } else {
      response = {
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': truncated ? '' : reply,
              if (calls.isNotEmpty) 'tool_calls': calls,
            },
            'finish_reason': calls.isEmpty ? 'stop' : 'tool_calls',
          },
        ],
      };
      events.add({
        'choices': [
          {
            'delta': {'content': truncated || progressive ? '' : reply},
          },
        ],
      });
      for (var i = 0; i < calls.length; i++) {
        final fn = calls[i]['function'] as Map;
        final raw = fn['arguments'] as String;
        final fragments = progressive
            ? [for (var j = 0; j < raw.length; j++) raw.substring(j, j + 1)]
            : [
                raw.substring(0, raw.length ~/ 2),
                raw.substring(raw.length ~/ 2),
              ];
        for (var j = 0; j < fragments.length; j++) {
          events.add({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': i,
                      if (j == 0) 'id': 'call_$i',
                      'function': {
                        if (j == 0) 'name': fn['name'],
                        'arguments': fragments[j],
                      },
                    },
                  ],
                },
              },
            ],
          });
        }
      }
      if (!truncated) {
        events.add({
          'choices': [
            {'delta': {}, 'finish_reason': 'tool_calls'},
          ],
        });
      }
    }
    final payload = !stream
        ? jsonEncode(response)
        : jsonArray
        ? jsonEncode(events)
        : '${events.map((e) => 'data: ${jsonEncode(e)}\n\n').join()}${truncated ? '' : 'data: [DONE]\n\ndata: [DONE]\n\n'}';
    Stream<List<int>> chunks() async* {
      responseEnded = false;
      for (final event in events) {
        yield utf8.encode('data: ${jsonEncode(event)}\n\n');
        await Future<void>.delayed(const Duration(milliseconds: 65));
      }
      responseEnded = true;
      yield utf8.encode('data: [DONE]\n\n');
    }

    return http.StreamedResponse(
      progressive && stream ? chunks() : Stream.value(utf8.encode(payload)),
      200,
      headers: {
        'content-type': stream && !jsonArray
            ? 'text/event-stream'
            : 'application/json',
      },
    );
  }
}

void _runAll(RunnerFactory createRunner) {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> verify(
    String provider, {
    bool stream = false,
    bool truncated = false,
    bool mixed = false,
    bool capable = true,
    bool partial = false,
    bool jsonArray = false,
    bool progressive = false,
  }) async {
    final server = _TransportServer(
      provider,
      stream: stream,
      truncated: truncated,
      mixed: mixed,
      partial: partial,
      jsonArray: jsonArray,
      progressive: progressive,
    );
    var executions = 0;
    final weather = AITool(
      name: 'weather',
      description: 'Get weather',
      parameters: const {},
      handler: (args) async {
        expect(args, {'city': '杭州'});
        executions++;
        return '晴';
      },
    );
    final source = keminiSource();
    if (mixed) source['function_calling'] = true;
    final snapshot = PresetScriptSnapshot.fromPreset(
      keminiPreset(source),
      macros: {},
      toolsAllowed: mixed,
      modelSupportsTools: capable,
    )!;
    final raw = <Map<String, dynamic>>[
      {'role': 'user', 'content': '去花园'},
    ];
    final before = jsonEncode(raw);
    final custom = <String, dynamic>{};
    var displayed = '';
    final previews = <String>[];
    var beforeEnd = false;
    final result =
        await createRunner(
          agentClientFactory: (_) => AgentApiClient(client: server),
        ).executeApiCall(
          config: ApiConfig(
            settings: mapUiModelsToAppSettings({}),
            modelFullId: '$provider:test-model',
            providerApiBase: 'https://offline.invalid',
            providerApiKey: 'offline-placeholder',
            customConfig: custom,
            toolPrefs: const {},
            messages: raw,
            presetScript: snapshot,
            tools: mixed ? [weather.toOpenAISchema()] : null,
            boundTools: mixed ? [weather] : null,
          ),
          sessionId: 'kemini-offline',
          userText: '去花园',
          effectivePlugins: const [],
          enableStreaming: stream,
          onStreamTextDelta: (s) {
            displayed += s;
            previews.add(displayed);
            beforeEnd |= !server.responseEnded;
          },
          onStreamTextReset: () => displayed = '',
        );
    expect(jsonEncode(raw), before);
    expect(custom, isEmpty);
    expect(server.requests, hasLength(mixed ? 2 : 1));
    for (final request in server.requests) {
      expect(request.containsKey('tools'), capable);
      if (provider == 'openai') {
        expect(request['tool_choice'], capable ? 'auto' : null);
      } else {
        expect(
          request['toolConfig'],
          capable
              ? {
                  'functionCallingConfig': {'mode': 'AUTO'},
                }
              : null,
        );
      }
    }
    expect(executions, mixed ? 1 : 0);
    expect(result.toolCalls.map((c) => c.name), mixed ? ['weather'] : isEmpty);
    final expected = truncated
        ? '花开了'
        : progressive
        ? '花\n开😀了。'
        : '花开了。';
    expect(result.rawReplyText, contains(expected));
    expect(result.rawReplyText, isNot(contains('emit_complete_response_')));
    if (!mixed) {
      expect(result.rawReplyText, expected);
      if (stream) expect(displayed, result.rawReplyText);
    }
    if (progressive && !mixed && stream && (provider == 'openai' || partial)) {
      expect(
        beforeEnd,
        isTrue,
        reason: 'must display before stream completion',
      );
      expect(previews.where((p) => p != expected), isNotEmpty);
      for (var i = 1; i < previews.length; i++) {
        expect(previews[i].startsWith(previews[i - 1]), isTrue);
      }
      for (final preview in previews) {
        expect(
          expected.startsWith(preview),
          isTrue,
          reason: 'no broken escape or Unicode',
        );
      }
    }
    if (mixed) {
      final followup = jsonEncode(server.requests.last);
      expect(followup, contains('weather'));
      // Exactly one synthetic definition and one request-local control prompt.
      expect(
        RegExp('emit_complete_response_').allMatches(followup),
        hasLength(2),
      );
      expect(result.rawToolResults.single.result, '晴');
    }
  }

  for (final provider in ['openai', 'gemini']) {
    for (final stream in [false, true]) {
      test(
        '$provider stream=$stream decodes original Kemini transport',
        () => verify(provider, stream: stream),
      );
      test(
        '$provider stream=$stream recovers truncated content',
        () => verify(provider, stream: stream, truncated: true),
      );
      test(
        '$provider stream=$stream executes mixed business tool',
        () => verify(provider, stream: stream, mixed: true),
      );
      test(
        '$provider stream=$stream unsupported tools still sends',
        () => verify(provider, stream: stream, capable: false),
      );
    }
  }
  for (final provider in ['openai', 'gemini']) {
    test('$provider growing previews and final body match nonstream', () async {
      await verify(
        provider,
        stream: true,
        progressive: true,
        partial: provider == 'gemini',
      );
      await verify(provider, progressive: true);
    });
    test(
      '$provider progressive transport preserves business calls',
      () => verify(provider, stream: true, progressive: true, mixed: true),
    );
  }
  test(
    'Gemini anonymous partialArgs and end markers decode once',
    () => verify('gemini', stream: true, partial: true),
  );
  test(
    'Gemini JSON array response stream decodes',
    () => verify('gemini', stream: true, jsonArray: true),
  );
}

void main() {
  for (final (variant, createRunner) in apiRunnerVariants) {
    group(variant, () => _runAll(createRunner));
  }
}
