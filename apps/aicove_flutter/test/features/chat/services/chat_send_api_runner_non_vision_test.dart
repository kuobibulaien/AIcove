import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';

class _FakeDrawImagePlugin extends BasePlugin {
  _FakeDrawImagePlugin()
      : super(
          metadata: const PluginMetadata(
            id: 'image',
            name: 'Image',
            description: 'fake image tool',
            version: '1.0.0',
            author: 'test',
            icon: Icons.image,
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
        name: 'draw_image',
        description: 'draw image for test',
        parameters: const {},
        handler: (args) async {
          return jsonEncode(<String, dynamic>{
            'success': true,
            'prompt': args['prompt'] ?? '',
            'images': <Map<String, dynamic>>[
              <String, dynamic>{
                'localPath': r'C:\tmp\generated_test.png',
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

AppSettings _buildTestSettings() {
  const modelRef = 'openai:gpt-3.5-turbo';
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
        chatCapabilities: <String>['tools'],
      ),
    },
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: true,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
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
      'gpt-3.5-turbo': 'openai',
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
    callFlowSettings: CallFlowSettings(mode: CallFlowMode.stable),
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

class _SequencedChatClient extends http.BaseClient {
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];
  int callCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) {
      return _json(500, <String, dynamic>{'error': 'request type unsupported'});
    }

    callCount += 1;
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    payloads.add(payload);

    if (callCount == 1) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'text',
                    'text': '收到，我去生成图片',
                  },
                  <String, dynamic>{
                    'type': 'image_url',
                    'image_url': <String, dynamic>{
                      'url': 'https://example.com/preview.png',
                    },
                  },
                ],
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
      final hasImage = _containsImageInput(payload['messages']);
      if (hasImage) {
        return _json(
          400,
          <String, dynamic>{
            'error': <String, dynamic>{
              'message':
                  'This model does not support image content in context.',
            },
          },
        );
      }

      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '图片已生成并发送。',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'stable mode round2 should not resend image content for non-vision model',
      () async {
    final fakeHttpClient = _SequencedChatClient();

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

    final runner = ChatSendApiRunner.withAgentClientFactory(
      agentClientFactory: (timeout) => AgentApiClient(
        client: fakeHttpClient,
        timeout: timeout,
      ),
    );
    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_non_vision_test',
      userText: '帮我画一只猫',
      effectivePlugins: <Plugin>[_FakeDrawImagePlugin()],
      maxRounds: 3,
    );

    expect(fakeHttpClient.callCount, 2);
    expect(fakeHttpClient.payloads.length, 2);
    expect(
        _containsImageInput(fakeHttpClient.payloads[1]['messages']), isFalse);
    expect(result.processedText, '');
    expect(result.pluginContents.length, 1);
  });
}
