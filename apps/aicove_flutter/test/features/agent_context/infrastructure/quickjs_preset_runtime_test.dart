import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/domain/kemini_transport_config.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/preset_script_runtime.dart';
import 'package:aicove_flutter/src/features/agent_context/infrastructure/quickjs_preset_runtime.dart';
import 'package:aicove_quickjs/aicove_quickjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

Map<String, dynamic> ateConfig({String settings = ''}) =>
    KeminiTransportConfig.read({
      'tavern_helper': {
        'scripts': [
          {
            'id': KeminiTransportConfig.ateScriptId,
            'enabled': true,
            'content':
                r'''
          const HOOK_MARKER = Symbol.for('__ATE_FETCH_HOOK__');
          const PRIMARY_CONTENT_KEY = 'buffer_content';
          perspectiveRules = `second ${novelTitle}`;
          perspectiveRules = `first ${novelTitle}`;
          perspectiveRules = `third ${novelTitle}`;
          throw Error('Imported JavaScript must not execute');
        ''' +
                settings,
          },
        ],
      },
    });

List<Map<String, dynamic>> messages() => [
  {
    'role': 'system',
    'content':
        'novel_title="Garden"\ntarget_length = 2300\nmode="first_person" protagonist="Alice"',
  },
  {'role': 'system', 'content': '<已归档历史章节>'},
  {'role': 'user', 'content': '旧输入'},
  {'role': 'assistant', 'content': '旧故事'},
  {'role': 'system', 'content': '</已归档历史章节>'},
  {'role': 'user', 'content': '【LAST_USER_INPUT】去花园'},
  {
    'role': 'system',
    'content':
        '【ToolCall引导】工具说明\nTool %TOOL_NAME% {{novel_title}} {{perspective_rules}}',
  },
  {
    'role': 'system',
    'content': '【ToolCall引导】字段说明\n{{target_length}} {{perspective}}',
  },
  {
    'role': 'system',
    'content':
        '【ToolCall引导】[SYSTEM_CONTEXT]\n{{novel_title}} {{current_chapter_file}}',
  },
  {
    'role': 'user',
    'content':
        '【ToolCall引导】[UserProjectTrigger]\n%TOOL_NAME% {{current_preview_file}}',
  },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<QuickJsPresetRuntime> open({
    bool capable = true,
    String? choice,
    Map<String, dynamic>? config,
  }) async {
    final runtime = await QuickJsPresetRuntime.open(
      PresetScriptSnapshot(
        jsonEncode({
          'config': {},
          'activeIds': [],
          'transport': config ?? ateConfig(),
        }),
        toolsAllowed: false,
        modelSupportsTools: capable,
        callerToolChoice: choice,
      ),
    );
    addTearDown(runtime.close);
    return runtime;
  }

  test(
    'recognizes ATE metadata without executing imported JavaScript',
    () async {
      expect(ateConfig()['protocol'], 'ate_buffer_v1');
      final snapshot = PresetScriptSnapshot(
        jsonEncode({'transport': ateConfig()}),
      );
      expect(snapshot.hasContentTransport, isTrue);
      final runtime = await open();
      expect(runtime.businessTools, isEmpty);
      expect(runtime.transportTools, isEmpty);
      await runtime.prepare(messages());
      expect(
        runtime.transportTools.single['function']['name'],
        startsWith('view_file_stream_'),
      );
      expect(runtime.toolChoice, 'auto');
    },
  );

  test(
    'ATE CONFIG defaults preserve the original transport mode and prefix',
    () {
      final config = ateConfig();
      expect(config['mode'], 'AUTO_TOOL');
      expect(config['prefix'], 'view_file_stream_');
    },
  );

  test(
    'reads literal CONFIG mode and prefix, not unrelated variables or comments',
    () async {
      final config = ateConfig(
        settings: r"""
      const mode = 'FORCED_SPECIFIC_TOOL';
      const prefix = 'wrong_';
      // const CONFIG = {mode: 'NONE', prefix: 'comment_'};
      const quoted = "CONFIG = {mode: 'NONE', prefix: 'quoted_'}";
      const CONFIG = {
        mode: 'AUTO_TOOL',
        toolPrefix: 'legacy_',
        prefix: "custom_\u005f",
      };
    """,
      );
      expect(config['mode'], 'AUTO_TOOL');
      expect(config['prefix'], 'custom__');
      final runtime = await open(config: config);
      await runtime.prepare(messages());
      expect(
        runtime.transportTools.single['function']['name'],
        startsWith('custom__'),
      );
    },
  );

  test('legacy toolPrefix is supported only inside CONFIG', () {
    expect(
      ateConfig(settings: "const CONFIG = {toolPrefix:'legacy_'};")['prefix'],
      'legacy_',
    );
    expect(
      ateConfig(settings: "const toolPrefix = 'outside_';")['prefix'],
      'view_file_stream_',
    );
  });

  for (final settings in [
    "const CONFIG = {mode: determineMode()};",
    "const CONFIG = {prefix: 'custom_' + suffix};",
    "const CONFIG = {mode:'UNKNOWN'};",
    "const CONFIG = {prefix:'invalid prefix'};",
  ]) {
    test(
      'computed or invalid ATE settings are diagnosed without execution: $settings',
      () {
        final config = ateConfig(settings: settings);
        expect(config['enabled'], isFalse);
        expect(config['diagnostics'], contains('transport_config_read_failed'));
      },
    );
  }

  test(
    'CONFIG NONE bypasses requests and leaves the display policy disabled',
    () async {
      final config = ateConfig(
        settings: "const CONFIG = {mode:'NONE', prefix:'off_'};",
      );
      final snapshot = PresetScriptSnapshot(jsonEncode({'transport': config}));
      expect(snapshot.hasContentTransport, isFalse);
      final runtime = await open(config: config);
      final input = messages();
      expect(await runtime.prepare(input), input);
      expect(runtime.tools, isEmpty);
      expect(runtime.toolChoice, isNull);
      expect(runtime.diagnostics, contains('transport_disabled'));
    },
  );

  test(
    'CONFIG forced mode fails explicitly even without a message probe',
    () async {
      final runtime = await open(
        config: ateConfig(
          settings: "const CONFIG = {mode:'FORCED_SPECIFIC_TOOL'};",
        ),
      );
      await expectLater(
        runtime.prepare(messages()),
        throwsA(
          isA<QuickJsException>().having(
            (error) => error.toString(),
            'message',
            contains('named tool choice'),
          ),
        ),
      );
    },
  );

  test(
    'each round checks ordinary tools for collisions and owns one precise identity',
    () async {
      final runtime = await open(
        config: ateConfig(settings: "const CONFIG = {prefix:'round_'};"),
      );
      await runtime.prepareWithTools(messages(), tools: const []);
      final previous =
          runtime.transportTools.single['function']['name'] as String;
      final ordinary = {
        'type': 'function',
        'function': {
          'name': previous,
          'parameters': {'type': 'object'},
        },
      };
      final prepared = await runtime.prepareWithTools(
        messages(),
        tools: [ordinary],
      );
      final current =
          runtime.transportTools.single['function']['name'] as String;
      expect(current, startsWith('round_'));
      expect(current, isNot(previous));
      expect(jsonEncode(prepared), contains(current));
      expect(jsonEncode(prepared), isNot(contains(previous)));
      expect(
        runtime.transportTools.single['function']['description'],
        contains(current),
      );
      final calls = [
        {
          'id': 'ordinary',
          'name': previous,
          'arguments': {'buffer_content': 'ordinary tool arguments'},
        },
        {
          'id': 'transport',
          'name': current,
          'arguments': {'buffer_content': 'current transport'},
        },
      ];
      await runtime.reset(true);
      expect(await runtime.update('', calls: calls), 'current transport');
      expect((await runtime.response('', calls)).consumedIndexes, {1});
      final next = await runtime.prepareWithTools(
        messages(),
        tools: [ordinary],
      );
      final nextName =
          runtime.transportTools.single['function']['name'] as String;
      expect({previous, current, nextName}, hasLength(3));
      expect(jsonEncode(next), contains(nextName));
      expect((await runtime.response('', calls)).consumedIndexes, isEmpty);
      expect(await runtime.update('', calls: calls), isEmpty);
    },
  );

  test(
    'extracts guide chain and complete context with chapter and control substitutions',
    () async {
      final runtime = await open();
      final input = messages();
      final saved = jsonEncode(input);
      final prepared = await runtime.prepare(input);
      final definition = runtime.transportTools.single['function'] as Map;
      final description = definition['description'] as String;
      expect(prepared, hasLength(2));
      expect(prepared.first['role'], 'system');
      expect(
        prepared.first['content'],
        '[SYSTEM_CONTEXT]\nGarden chapter_02.txt',
      );
      expect(prepared.last['content'], contains('chapter_02_preview.txt'));
      expect(prepared.last['content'], contains(definition['name']));
      expect(description, contains('first Garden'));
      expect(
        description,
        contains('Historical Chapter Transcripts & Literary Assets:'),
      );
      expect(description, contains('<ide_viewport_log>'));
      expect(description, contains('旧故事'));
      expect(description, contains('旧输入'));
      expect(description, contains('去花园'));
      expect(description, contains('# TargetLength = "约2300字"'));
      expect(description, contains('第一人称主观沉浸视角（Alice）'));
      expect(description, isNot(contains('【ToolCall引导】')));
      expect(description, isNot(contains('target_length =')));
      expect(definition['parameters']['required'], ['buffer_content']);
      expect(
        definition['parameters']['properties']['buffer_content']['description'],
        '2300 第一人称主观沉浸视角（Alice）',
      );
      expect(jsonEncode(input), saved);
      final next = await runtime.prepare(input);
      final nextName =
          runtime.transportTools.single['function']['name'] as String;
      expect(nextName, isNot(definition['name']));
      expect(
        jsonEncode(next).replaceAll(nextName, 'TRANSPORT_NAME'),
        jsonEncode(
          prepared,
        ).replaceAll(definition['name'] as String, 'TRANSPORT_NAME'),
      );
    },
  );

  test(
    'keeps native tool exchange and tool-image suffix intact on every round',
    () async {
      final runtime = await open();
      final base = messages();
      await runtime.prepare(base);
      final name = runtime.transportTools.single['function']['name'];
      final suffix = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': '正在查看',
          'tool_calls': [
            {
              'id': 'weather_call',
              'type': 'function',
              'function': {'name': 'weather', 'arguments': '{"city":"杭州"}'},
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'weather_call',
          'name': 'weather',
          'content': '晴天 【ToolCall引导】not a preset',
        },
        {
          'role': 'user',
          '_aicove_tool_step': true,
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,AA=='},
            },
          ],
        },
      ];
      final result = await runtime.prepare([...base, ...suffix]);
      expect(result.sublist(result.length - suffix.length), suffix);
      expect(runtime.transportTools.single['function']['name'], isNot(name));
      final changed = messages();
      changed[5]['content'] = '【LAST_USER_INPUT】更新输入';
      await runtime.prepare([...changed, ...suffix]);
      final description =
          runtime.transportTools.single['function']['description'] as String;
      expect(description, contains('更新输入'));
      expect(description, isNot(contains('去花园')));
      expect(description, isNot(contains('weather_call')));
      expect(description, isNot(contains('晴天')));
    },
  );

  test(
    'historical tool exchanges before guides do not disable the active transport',
    () async {
      final runtime = await open();
      final input = messages();
      input.insertAll(3, [
        {
          'role': 'assistant',
          'content': '旧查询',
          'tool_calls': [
            {
              'id': 'old',
              'type': 'function',
              'function': {'name': 'weather', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'old', 'content': '旧天气'},
      ]);
      final result = await runtime.prepare(input);
      expect(result, hasLength(2));
      expect(runtime.transportTools, hasLength(1));
      final description =
          runtime.transportTools.single['function']['description'] as String;
      expect(description, contains('旧查询'));
      expect(description, contains('旧天气'));
    },
  );

  test(
    'moves all multimodal assets to user guide without leaking opaque references',
    () async {
      final runtime = await open();
      final input = messages();
      final image = {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AA=='},
      };
      final audio = {
        'type': 'input_audio',
        'input_audio': {'data': 'AAAA', 'format': 'wav'},
      };
      final file = {
        'type': 'file',
        'file': {'file_id': 'document-one'},
      };
      input[5]['content'] = [
        {'type': 'text', 'text': '【LAST_USER_INPUT】看图'},
        image,
        audio,
      ];
      input[5]['attachments'] = [file];
      final prepared = await runtime.prepare(input);
      expect(prepared.last['content'], [
        {'type': 'text', 'text': prepared.last['content'][0]['text']},
        image,
        audio,
        file,
      ]);
      expect(
        jsonEncode(runtime.transportTools),
        isNot(contains('__aicove_image_ref')),
      );
      expect(jsonEncode(runtime.transportTools), isNot(contains('base64')));
      expect(
        runtime.transportTools.single['function']['description'],
        contains('[AttachedAssets]: 3'),
      );
    },
  );

  for (final choice in ['none', 'required', 'weather']) {
    test('caller selection $choice bypasses ATE unchanged', () async {
      final runtime = await open(choice: choice);
      final input = messages();
      expect(await runtime.prepare(input), input);
      expect(runtime.transportTools, isEmpty);
      expect(runtime.toolChoice, isNull);
      expect(
        runtime.diagnostics,
        contains('transport_skipped_caller_tool_choice'),
      );
    });
  }

  test('no guide and model without tools bypass unchanged', () async {
    final runtime = await open();
    final input = [
      {'role': 'user', 'content': '你好'},
    ];
    expect(await runtime.prepare(input), input);
    expect(runtime.tools, isEmpty);
    expect(
      runtime.diagnostics,
      contains('transport_skipped_no_toolcall_guide'),
    );
    await runtime.prepare(messages());
    expect(runtime.transportTools, hasLength(1));
    expect(await runtime.prepare(input), input);
    expect(runtime.tools, isEmpty);
    final incapable = await open(capable: false);
    final full = messages();
    expect(await incapable.prepare(full), full);
    expect(incapable.tools, isEmpty);
    expect(
      incapable.diagnostics,
      contains('transport_skipped_model_without_tools'),
    );
  });

  test(
    'forced named choice reports unsupported contract instead of silently using auto',
    () async {
      final runtime = await open();
      await expectLater(
        runtime.prepare([
          ...messages(),
          {'role': 'system', 'content': 'mode = "FORCED_SPECIFIC_TOOL"'},
        ]),
        throwsA(
          isA<QuickJsException>().having(
            (e) => e.toString(),
            'message',
            contains('named tool choice'),
          ),
        ),
      );
    },
  );

  test(
    'only exact current transport identity is consumed in full and streamed responses',
    () async {
      final runtime = await open();
      await runtime.prepare(messages());
      final name = runtime.transportTools.single['function']['name'] as String;
      final calls = <Map<String, dynamic>>[
        {
          'id': 'transport',
          'name': name,
          'arguments': {'buffer_content': '完整正文'},
        },
        {
          'id': 'business',
          'name': 'draw_image',
          'arguments': {'buffer_content': '不能吞掉'},
        },
        {
          'id': 'foreign',
          'name': '${name}_other',
          'arguments': {'buffer_content': '不能吞掉'},
        },
      ];
      await runtime.reset(false);
      final result = await runtime.response('短', calls);
      expect(result.text, '完整正文');
      expect(result.consumedIndexes, {0});
      expect(result.consumedIds, {'transport'});
      await runtime.reset(true);
      expect(await runtime.update('', calls: calls), '完整正文');
      for (final sample in <String, String>{
        r'{"buffer_content":"花\n开\u4e86': '花\n开了',
        r'{"meta":{"buffer_content":"不得取"},"buffer_content":"花': '花',
        r'{"meta":{"buffer_content":"不得取': '',
        r'{"buffer_content":"花\uD83D': '花',
        r'{"buffer_content":"花\uD83D\uDE00': '花😀',
      }.entries) {
        final call = {
          'id': 'transport',
          'name': name,
          'arguments': {},
          'rawArguments': sample.key,
        };
        expect(await runtime.update('', calls: [call]), sample.value);
        expect((await runtime.response('', [call])).text, sample.value);
      }
    },
  );

  for (final streaming in [false, true]) {
    test(
      'ATE HTTP pipeline keeps three rounds and expands image prompt (stream=$streaming)',
      () async {
        final server = _AteServer();
        var weatherCalls = 0;
        final prompts = <String>[];
        final tools = [
          AITool(
            name: 'weather',
            description: 'Get weather',
            parameters: const {},
            handler: (args) async {
              weatherCalls++;
              return '晴天';
            },
          ),
          AITool(
            name: 'draw_image',
            description: 'Draw image',
            parameters: const {},
            inputSchema: const {
              'type': 'object',
              'properties': {
                'prompt': {'type': 'string'},
              },
              'required': ['prompt'],
            },
            handler: (args) async {
              prompts.add(args['prompt'] as String);
              return '{"ok":true}';
            },
          ),
        ];
        final schemaSnapshots = <List<Map<String, dynamic>>>[];
        final runner = KernelApiRunner.withAgentClientFactory(
          agentClientFactory: (_) => AgentApiClient(client: server),
        );
        final result = await runner.executeApiCall(
          config: ApiConfig(
            settings: mapUiModelsToAppSettings({
              'call_flow_settings': {'mode': 'call'},
            }),
            modelFullId: 'openai:gpt-4o',
            providerApiBase: 'https://offline.invalid',
            providerApiKey: 'offline-placeholder',
            customConfig: const {},
            messages: messages(),
            presetScript: PresetScriptSnapshot(
              jsonEncode({
                'config': {},
                'transport': ateConfig(),
                'activeIds': [],
              }),
            ),
            tools: [for (final tool in tools) tool.toOpenAISchema()],
            boundTools: tools,
            onToolSchemasChanged: (schemas) => schemaSnapshots.add(schemas),
          ),
          sessionId: 'ate-test',
          userText: '去花园',
          responseProcessors: const [],
          enableStreaming: streaming,
        );
        expect(server.requests, hasLength(3));
        expect(weatherCalls, 1);
        expect(prompts, ['green hair, red dress']);
        expect(result.toolCalls.map((call) => call.name), [
          'weather',
          'draw_image',
        ]);
        expect(result.rawReplyText, contains('完成。'));
        expect(schemaSnapshots, hasLength(3));
        final names = <String>{};
        for (final request in server.requests) {
          final schemas = request['tools'] as List;
          final transport = schemas.singleWhere(
            (tool) => (tool['function']['name'] as String).startsWith(
              'view_file_stream_',
            ),
          );
          names.add(transport['function']['name'] as String);
          expect(transport['function']['description'], contains('旧故事'));
          expect(transport['function']['parameters']['required'], [
            'buffer_content',
          ]);
          expect(request['tool_choice'], 'auto');
          expect(
            jsonEncode(request['messages']),
            contains(transport['function']['name']),
          );
        }
        expect(names, hasLength(3));
        final continuation = server.requests[1]['messages'] as List;
        final assistant = continuation.singleWhere(
          (message) => message['tool_calls'] != null,
        );
        expect(assistant['tool_calls'].single['function']['name'], 'weather');
        expect(
          continuation.singleWhere(
            (message) => message['role'] == 'tool',
          )['tool_call_id'],
          'weather_call',
        );
        final third = server.requests[2]['messages'] as List;
        expect(
          third
              .where((message) => message['role'] == 'tool')
              .map((message) => message['tool_call_id']),
          ['weather_call', 'image_call'],
        );
      },
    );
  }

  final original = Platform.environment['AICOVE_KUNLUN_FIXTURE'];
  if (original != null) {
    test(
      'private original ATE source contributes configuration without execution',
      () async {
        final source = jsonDecode(File(original).readAsStringSync()) as Map;
        final config = KeminiTransportConfig.read(source['extensions'] as Map);
        expect(config['protocol'], 'ate_buffer_v1');
        expect(config['perspectiveRules'], hasLength(3));
        final runtime = await open(config: config);
        final input = [
          for (final prompt in source['prompts'] as List)
            if ((prompt['content'] as String? ?? '').contains('【ToolCall引导】'))
              {'role': prompt['role'], 'content': prompt['content']},
          {'role': 'user', 'content': '【LAST_USER_INPUT】继续'},
        ];
        final prepared = await runtime.prepare(input);
        expect(prepared, isNotEmpty);
        expect(
          runtime.transportTools.single['function']['parameters']['required'],
          ['buffer_content'],
        );
        expect(jsonEncode(prepared), isNot(contains('【ToolCall引导】')));
      },
    );
  }
}

class _AteServer extends http.BaseClient {
  final requests = <Map<String, dynamic>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body =
        jsonDecode(utf8.decode(await request.finalize().toBytes()))
            as Map<String, dynamic>;
    requests.add(body);
    final round = requests.length;
    final definition = (body['tools'] as List).singleWhere(
      (tool) =>
          (tool['function']['name'] as String).startsWith('view_file_stream_'),
    );
    final name = definition['function']['name'];
    const firstPlan =
        '<comic_plan>\n- 角色母表:\n  - C1:\n    - 固定身份词: silver hair\n    - 初始服装词: white dress\n</comic_plan>';
    const reasoningPlan =
        '<comic_plan>\n- 角色母表:\n  - C1:\n    - 固定身份词: gold hair\n    - 初始服装词: red dress\n</comic_plan>';
    const visiblePlan =
        '<comic_plan>\n- 角色母表:\n  - C1:\n    - 固定身份词: green hair\n</comic_plan>';
    final text = round == 1
        ? firstPlan
        : round == 2
        ? '<think>$reasoningPlan</think>$visiblePlan'
        : '完成。';
    final calls = <Map<String, dynamic>>[
      {
        'id': 'transport_$round',
        'type': 'function',
        'function': {
          'name': name,
          'arguments': jsonEncode({'buffer_content': text}),
        },
      },
      if (round == 1)
        {
          'id': 'weather_call',
          'type': 'function',
          'function': {'name': 'weather', 'arguments': '{}'},
        },
      if (round == 2)
        {
          'id': 'image_call',
          'type': 'function',
          'function': {
            'name': 'draw_image',
            'arguments': jsonEncode({'prompt': '@C1, @C1_outfit'}),
          },
        },
    ];
    final streaming = body['stream'] == true;
    final payload = streaming
        ? 'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    for (var i = 0; i < calls.length; i++) {'index': i, ...calls[i]},
                  ],
                },
              },
            ],
          })}\n\ndata: ${jsonEncode({
            'choices': [
              {'delta': {}, 'finish_reason': 'tool_calls'},
            ],
          })}\n\ndata: [DONE]\n\n'
        : jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': '',
                  'tool_calls': calls,
                },
                'finish_reason': 'tool_calls',
              },
            ],
          });
    return http.StreamedResponse(
      Stream.value(utf8.encode(payload)),
      200,
      headers: {
        'content-type': streaming ? 'text/event-stream' : 'application/json',
      },
    );
  }
}
