import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/tool_parameter.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_content.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+cN5kAAAAASUVORK5CYII=';

class _SequencedVisionDrawImagePlugin extends BasePlugin {
  _SequencedVisionDrawImagePlugin(this.imagePaths)
      : super(
          metadata: const PluginMetadata(
            id: 'image',
            name: 'Image',
            description: 'stable vision draw image test',
            version: '1.0.0',
            author: 'test',
            icon: Icons.image,
          ),
        );

  final List<String> imagePaths;
  int _callCount = 0;

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
      contents: const <PluginContent>[],
    );
  }

  @override
  List<AITool> getTools() {
    return <AITool>[
      AITool(
        name: 'draw_image',
        description: 'draw image for stable vision review',
        parameters: const <String, ToolParameter>{},
        handler: (args) async {
          final index = _callCount < imagePaths.length
              ? _callCount
              : imagePaths.length - 1;
          _callCount += 1;
          final prompt = args['prompt']?.toString() ?? '';
          return jsonEncode(<String, dynamic>{
            'success': true,
            'prompt': prompt,
            'images': <Map<String, dynamic>>[
              <String, dynamic>{
                'localPath': imagePaths[index],
                'caption': prompt,
                'generationSnapshot': {'version':1,'providerId':'original','modelId':'model',
                  'requestProvider':'openai','prompt':prompt,'negativePrompt':'old',
                  'width':1024,'height':768,'steps':31,'guidanceScale':6.5},
              },
            ],
            'message': 'ok',
          });
        },
      ),
    ];
  }
}

AppSettings _buildVisionSettings() {
  const modelRef = 'openai:gpt-4o-mini';
  return const AppSettings(
    ttsEnabled: false,
    defaultModelName: modelRef,
    defaultPersonaPrompt: '',
    modelList: <String>[modelRef],
    allKnownModels: <String>[modelRef],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{},
    modelConfigs: <String, ModelConfig>{
      modelRef: ModelConfig(
        chatCapabilities: <String>['tools', 'vision'],
      ),
    },
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: true,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
      ),
    ],
    modelProviderMap: <String, String>{
      modelRef: 'openai',
      'gpt-4o-mini': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: <String>[modelRef],
    callFlowSettings: CallFlowSettings(mode: CallFlowMode.auto),
  );
}

bool _containsImageInput(dynamic node) {
  if (node is List) {
    for (final item in node) {
      if (_containsImageInput(item)) return true;
    }
    return false;
  }

  if (node is! Map) return false;
  final map = <String, dynamic>{};
  node.forEach((key, value) {
    map[key.toString()] = value;
  });

  final type = (map['type'] ?? '').toString().toLowerCase();
  if (type == 'image_url' || type == 'input_image' || type == 'image') {
    return true;
  }
  if (map.containsKey('image_url')) return true;
  if (map.containsKey('inlineData')) {
    final inline = map['inlineData'];
    if (inline is Map) {
      final mime = inline['mimeType']?.toString().toLowerCase() ?? '';
      if (mime.isEmpty || mime.startsWith('image/')) return true;
    }
  }
  if (map.containsKey('fileData')) {
    final file = map['fileData'];
    if (file is Map) {
      final mime = file['mimeType']?.toString().toLowerCase() ?? '';
      if (mime.startsWith('image/')) return true;
    }
  }

  for (final value in map.values) {
    if (_containsImageInput(value)) return true;
  }
  return false;
}

bool _containsStringFragment(dynamic node, String fragment) {
  if (node is String) {
    return node.contains(fragment);
  }

  if (node is List) {
    for (final item in node) {
      if (_containsStringFragment(item, fragment)) return true;
    }
    return false;
  }

  if (node is! Map) return false;
  for (final value in node.values) {
    if (_containsStringFragment(value, fragment)) return true;
  }
  return false;
}

class _StableVisionSendClient extends http.BaseClient {
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
                'content': '我先给你出一版图。',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_draw_1',
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

    if (callCount == 2) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '我看过了，这张可以发给你：<image></image>',
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

class _StableVisionRedrawClient extends http.BaseClient {
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
                'content': '我先出第一版。',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_draw_1',
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

    if (callCount == 2) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '这张手有问题，我调整提示词后重画。',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_draw_2',
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': 'draw_image',
                      'arguments': '{"prompt":"cat, better hands"}',
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
                'content': '这版可以发给你了<image></image>',
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

Future<String> _writeTinyPng(Directory dir, String name) async {
  final path = '${dir.path}${Platform.pathSeparator}$name';
  await File(path).writeAsBytes(base64Decode(_tinyPngBase64), flush: true);
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stable vision draw_image should review image before deciding to send',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('aicove_stable_send');
    final firstImage = await _writeTinyPng(tempDir, 'stable_send.png');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final fakeHttpClient = _StableVisionSendClient();
    final settings = _buildVisionSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-4o-mini',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': '帮我画一只猫'},
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
      ],
    );

    final runner = ChatSendApiRunner.withAgentClientFactory(
      agentClientFactory: (timeout) => AgentApiClient(
        client: fakeHttpClient,
        timeout: timeout,
      ),
    );
    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stable_vision_send',
      userText: '帮我画一只猫',
      effectivePlugins: <Plugin>[
        _SequencedVisionDrawImagePlugin(<String>[firstImage]),
      ],
      maxRounds: 4,
    );

    expect(fakeHttpClient.callCount, 2);
    expect(_containsImageInput(fakeHttpClient.payloads[1]['messages']), isTrue);
    expect(
      _containsStringFragment(
        fakeHttpClient.payloads[1]['messages'],
        '"image_review_pending":true',
      ),
      isTrue,
    );
    expect(
      _containsStringFragment(
        fakeHttpClient.payloads[1]['messages'],
        '"delivered_to_chat":true',
      ),
      isFalse,
    );
    expect(result.processedText, contains('我先给你出一版图。'));
    expect(result.processedText, contains('这张可以发给你'));
    final image = result.pluginContents.whereType<PluginImageContent>().single;
    expect(image.localPath, firstImage);
    expect(image.generationSnapshot!.steps, 31);
  });

  test(
      'stable vision draw_image should allow regenerate and only deliver latest image',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('aicove_stable_redraw');
    final firstImage = await _writeTinyPng(tempDir, 'stable_redraw_1.png');
    final secondImage = await _writeTinyPng(tempDir, 'stable_redraw_2.png');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final fakeHttpClient = _StableVisionRedrawClient();
    final settings = _buildVisionSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-4o-mini',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': '帮我画一只猫'},
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
      ],
    );

    final runner = ChatSendApiRunner.withAgentClientFactory(
      agentClientFactory: (timeout) => AgentApiClient(
        client: fakeHttpClient,
        timeout: timeout,
      ),
    );
    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stable_vision_redraw',
      userText: '帮我画一只猫',
      effectivePlugins: <Plugin>[
        _SequencedVisionDrawImagePlugin(<String>[firstImage, secondImage]),
      ],
      maxRounds: 5,
    );

    expect(fakeHttpClient.callCount, 3);
    expect(_containsImageInput(fakeHttpClient.payloads[1]['messages']), isTrue);
    expect(_containsImageInput(fakeHttpClient.payloads[2]['messages']), isTrue);
    expect(
      _containsStringFragment(
        fakeHttpClient.payloads[2]['messages'],
        '"prompt":"cat, better hands"',
      ),
      isTrue,
    );
    final delivered =
        result.pluginContents.whereType<PluginImageContent>().single;
    expect(delivered.localPath, secondImage);
    expect(delivered.localPath, isNot(firstImage));
    expect(result.processedText, contains('这张手有问题'));
    expect(result.processedText, contains('这版可以发给你了'));
  });
}
