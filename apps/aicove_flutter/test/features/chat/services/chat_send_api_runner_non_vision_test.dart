import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'api_runner_variants.dart';

AppSettings _buildTestSettings({
  CallFlowMode mode = CallFlowMode.auto,
}) {
  const modelRef = 'openai:gpt-3.5-turbo';
  return AppSettings(
    ttsEnabled: false,
    defaultModelName: modelRef,
    defaultPersonaPrompt: '',
    modelList: const <String>[modelRef],
    allKnownModels: const <String>[modelRef],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{
      modelRef: ModelConfig(
        chatCapabilities: <String>['tools'],
      ),
    },
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: true,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: const <CustomModel>[],
    providers: const <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
      ),
    ],
    modelProviderMap: const <String, String>{
      modelRef: 'openai',
      'gpt-3.5-turbo': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: const MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: const <String>[modelRef],
    callFlowSettings: CallFlowSettings(mode: mode),
  );
}

class _SingleRoundDrawClient extends http.BaseClient {
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];
  int callCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) {
      return _json(500, <String, dynamic>{'error': 'request type unsupported'});
    }

    callCount += 1;
    payloads.add(jsonDecode(request.body) as Map<String, dynamic>);

    if (callCount == 1) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '收到，我去生成图片',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_draw_fast_1',
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': 'draw_image',
                      'arguments': '{"prompt":"cat"}',
                    },
                  },
                ],
              },
            },
          ],
        },
      );
    }

    return _json(
      500,
      <String, dynamic>{'error': 'unexpected extra round'},
    );
  }

  Future<http.StreamedResponse> _json(int statusCode, Object body) async {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      statusCode,
      headers: const <String, String>{
        'content-type': 'application/json',
      },
    );
  }
}

class _FakeLookupPlugin extends BasePlugin {
  _FakeLookupPlugin()
      : super(
          metadata: const PluginMetadata(
            id: 'lookup',
            name: 'Lookup',
            description: 'fake lookup tool',
            version: '1.0.0',
            author: 'test',
            icon: Icons.search,
          ),
        );

  @override
  bool get enabled => true;

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async {
    return null;
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    return PluginProcessResult(
      processedText: text,
      events: const <PluginEvent>[],
      contents: const [],
    );
  }

  @override
  List<AITool> getTools() {
    return <AITool>[
      AITool(
        name: 'lookup_schedule',
        description: 'lookup schedule for test',
        parameters: const {},
        handler: (args) async {
          return jsonEncode(<String, dynamic>{
            'success': true,
            'result': '今晚八点有空',
          });
        },
      ),
    ];
  }
}

class _FakeWeatherPlugin extends BasePlugin {
  _FakeWeatherPlugin()
      : super(
          metadata: const PluginMetadata(
            id: 'weather',
            name: 'Weather',
            description: 'fake weather tool',
            version: '1.0.0',
            author: 'test',
            icon: Icons.cloud,
          ),
        );

  @override
  bool get enabled => true;

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async {
    return null;
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    return PluginProcessResult(
      processedText: text,
      events: const <PluginEvent>[],
      contents: const [],
    );
  }

  @override
  List<AITool> getTools() {
    return <AITool>[
      AITool(
        name: 'lookup_weather',
        description: 'lookup weather for test',
        parameters: const {},
        handler: (args) async {
          return jsonEncode(<String, dynamic>{
            'success': true,
            'result': '天气晴',
          });
        },
      ),
    ];
  }
}

class _TwoRoundNarrativeClient extends http.BaseClient {
  _TwoRoundNarrativeClient({
    required this.firstRoundContent,
    required this.secondRoundContent,
  });

  final String firstRoundContent;
  final String secondRoundContent;
  int callCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) {
      return _json(500, <String, dynamic>{'error': 'request type unsupported'});
    }

    callCount += 1;

    if (callCount == 1) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': firstRoundContent,
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_lookup_1',
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': 'lookup_schedule',
                      'arguments': '{"topic":"今晚安排"}',
                    },
                  },
                ],
              },
            },
          ],
        },
      );
    }

    if (callCount == 2) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': secondRoundContent,
              },
            },
          ],
        },
      );
    }

    return _json(
      500,
      <String, dynamic>{'error': 'unexpected extra round'},
    );
  }

  Future<http.StreamedResponse> _json(int statusCode, Object body) async {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      statusCode,
      headers: const <String, String>{
        'content-type': 'application/json',
      },
    );
  }
}

class _ThreeRoundNarrativeClient extends http.BaseClient {
  int callCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) {
      return _json(500, <String, dynamic>{'error': 'request type unsupported'});
    }

    callCount += 1;

    if (callCount == 1) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '我先帮你查一下日程。',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_lookup_schedule_1',
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': 'lookup_schedule',
                      'arguments': '{"topic":"今晚安排"}',
                    },
                  },
                ],
              },
            },
          ],
        },
      );
    }

    if (callCount == 2) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '我再帮你看下天气。',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_lookup_weather_1',
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': 'lookup_weather',
                      'arguments': '{"topic":"今晚天气"}',
                    },
                  },
                ],
              },
            },
          ],
        },
      );
    }

    if (callCount == 3) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '查好了，你今晚八点有空，天气晴。',
              },
            },
          ],
        },
      );
    }

    return _json(
      500,
      <String, dynamic>{'error': 'unexpected extra round'},
    );
  }

  Future<http.StreamedResponse> _json(int statusCode, Object body) async {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      statusCode,
      headers: const <String, String>{
        'content-type': 'application/json',
      },
    );
  }
}

class _AsyncAwareDrawImagePlugin extends BasePlugin {
  _AsyncAwareDrawImagePlugin()
      : super(
          metadata: const PluginMetadata(
            id: 'image_async_probe',
            name: 'Image Async Probe',
            description: 'captures draw_image async flag',
            version: '1.0.0',
            author: 'test',
            icon: Icons.image,
          ),
        );

  bool sawAsyncFlag = false;

  @override
  bool get enabled => true;

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async {
    return null;
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    return PluginProcessResult(
      processedText: text,
      events: const <PluginEvent>[],
      contents: const [],
    );
  }

  @override
  List<AITool> getTools() {
    return <AITool>[
      AITool(
        name: 'draw_image',
        description: 'probe draw image async flag',
        parameters: const {},
        handler: (args) async {
          sawAsyncFlag = args['_aicove_async'] == true ||
              args['_aicove_async']?.toString().toLowerCase() == 'true';
          return jsonEncode(<String, dynamic>{
            'success': true,
            'prompt': args['prompt'] ?? '',
            'images': <Map<String, dynamic>>[
              <String, dynamic>{
                'localPath': r'C:\tmp\mixed_route_generated_test.png',
                'caption': args['prompt'] ?? '',
              },
            ],
            'message': 'ok',
          });
        },
      ),
    ];
  }
}

class _MixedToolClient extends http.BaseClient {
  int callCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) {
      return _json(500, <String, dynamic>{'error': 'request type unsupported'});
    }

    callCount += 1;

    if (callCount == 1) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '我先去查日程，再顺手画张图。',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_draw_1',
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': 'draw_image',
                      'arguments': '{"prompt":"cat"}',
                    },
                  },
                  <String, dynamic>{
                    'id': 'call_lookup_1',
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': 'lookup_schedule',
                      'arguments': '{"topic":"今晚安排"}',
                    },
                  },
                ],
              },
            },
          ],
        },
      );
    }

    if (callCount == 2) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '查好了，你今晚八点有空，图也已经发给你。',
              },
            },
          ],
        },
      );
    }

    return _json(
      500,
      <String, dynamic>{'error': 'unexpected extra round'},
    );
  }

  Future<http.StreamedResponse> _json(int statusCode, Object body) async {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      statusCode,
      headers: const <String, String>{
        'content-type': 'application/json',
      },
    );
  }
}

void _runAll(RunnerFactory createRunner) {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'auto setting should force draw_image into fast route for non-vision model',
      () async {
    final fakeHttpClient = _SingleRoundDrawClient();
    final drawPlugin = _AsyncAwareDrawImagePlugin();

    final settings = _buildTestSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '帮我画一只猫',
        },
      ],
      tools: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'draw_image',
            'description': 'draw image',
            'parameters': <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'prompt': <String, dynamic>{'type': 'string'},
              },
              'required': <String>['prompt'],
            },
          },
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) => AgentApiClient(
        client: fakeHttpClient,
        timeout: timeout,
      ),
    );
    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_non_vision_test',
      userText: '帮我画一只猫',
      effectivePlugins: <Plugin>[drawPlugin],
      maxRounds: 3,
    );

    expect(fakeHttpClient.callCount, 1);
    expect(fakeHttpClient.payloads.length, 1);
    expect(drawPlugin.sawAsyncFlag, isTrue);
    expect(
      result.processedText,
      isNot(contains('__AICOVE_IMAGE_CONTEXT__')),
    );
    expect(result.processedText, contains('收到，我去生成图片'));
    expect(result.processedText, isNot(contains('[图片]')));
    expect(result.pluginContents.length, 1);
    expect(
      result.rawToolResults.singleWhere((r) => r.name == 'draw_image').result,
      contains('"delivered_to_chat":true'),
    );
  });

  test('auto mode should keep round1 narrative text when tool calls continue',
      () async {
    final fakeHttpClient = _TwoRoundNarrativeClient(
      firstRoundContent: '我先帮你查一下日程。',
      secondRoundContent: '查好了，你今晚八点有空。',
    );
    final settings = _buildTestSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': '今晚几点有空？'},
      ],
      tools: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'lookup_schedule',
            'description': 'lookup schedule',
            'parameters': <String, dynamic>{'type': 'object'},
          },
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) => AgentApiClient(
        client: fakeHttpClient,
        timeout: timeout,
      ),
    );
    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_keep_round1_narrative',
      userText: '今晚几点有空？',
      effectivePlugins: <Plugin>[_FakeLookupPlugin()],
      maxRounds: 3,
    );

    expect(fakeHttpClient.callCount, 2);
    expect(result.processedText, contains('我先帮你查一下日程。'));
    expect(result.processedText, contains('查好了，你今晚八点有空。'));
  });

  test('fast setting should fall back to stable routing for non-image tools',
      () async {
    final fakeHttpClient = _ThreeRoundNarrativeClient();
    final settings = _buildTestSettings(mode: CallFlowMode.fast);
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': '今晚几点有空？'},
      ],
      tools: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'lookup_schedule',
            'description': 'lookup schedule',
            'parameters': <String, dynamic>{'type': 'object'},
          },
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) => AgentApiClient(
        client: fakeHttpClient,
        timeout: timeout,
      ),
    );
    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_fast_lookup_followup',
      userText: '今晚几点有空？',
      effectivePlugins: <Plugin>[_FakeLookupPlugin(), _FakeWeatherPlugin()],
      maxRounds: 5,
    );

    expect(fakeHttpClient.callCount, 3);
    expect(result.processedText, contains('我先帮你查一下日程。'));
    expect(result.processedText, contains('我再帮你看下天气。'));
    expect(result.processedText, contains('查好了，你今晚八点有空，天气晴。'));
  });

  test(
      'fast setting should not pass async draw_image flag in mixed tool rounds',
      () async {
    final fakeHttpClient = _MixedToolClient();
    final drawPlugin = _AsyncAwareDrawImagePlugin();
    final settings = _buildTestSettings(mode: CallFlowMode.fast);
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': '帮我查下今晚安排，再画张图'},
      ],
      tools: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'draw_image',
            'description': 'draw image',
            'parameters': <String, dynamic>{'type': 'object'},
          },
        },
        <String, dynamic>{
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'lookup_schedule',
            'description': 'lookup schedule',
            'parameters': <String, dynamic>{'type': 'object'},
          },
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) => AgentApiClient(
        client: fakeHttpClient,
        timeout: timeout,
      ),
    );
    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_fast_mixed_tools',
      userText: '帮我查下今晚安排，再画张图',
      effectivePlugins: <Plugin>[drawPlugin, _FakeLookupPlugin()],
      maxRounds: 5,
    );

    expect(fakeHttpClient.callCount, 2);
    expect(drawPlugin.sawAsyncFlag, isFalse);
    expect(result.processedText, contains('图也已经发给你'));
  });

  test(
      'stable mode should ignore round1 tool instruction text when composing final narrative',
      () async {
    final fakeHttpClient = _TwoRoundNarrativeClient(
      firstRoundContent:
          '<execute_tool>{"action":"lookup_schedule","action_input":{"topic":"今晚安排"}}</execute_tool>',
      secondRoundContent: '查好了，你今晚八点有空。',
    );
    final settings = _buildTestSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': '今晚几点有空？'},
      ],
      tools: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'lookup_schedule',
            'description': 'lookup schedule',
            'parameters': <String, dynamic>{'type': 'object'},
          },
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) => AgentApiClient(
        client: fakeHttpClient,
        timeout: timeout,
      ),
    );
    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_filter_round1_instruction',
      userText: '今晚几点有空？',
      effectivePlugins: <Plugin>[_FakeLookupPlugin()],
      maxRounds: 3,
    );

    expect(fakeHttpClient.callCount, 2);
    expect(result.processedText, isNot(contains('<execute_tool>')));
    expect(result.processedText, isNot(contains('"action":"lookup_schedule"')));
    expect(result.processedText.trim(), '查好了，你今晚八点有空。');
  });
}

void main() {
  for (final (variant, createRunner) in apiRunnerVariants) {
    group(variant, () => _runAll(createRunner));
  }
}
