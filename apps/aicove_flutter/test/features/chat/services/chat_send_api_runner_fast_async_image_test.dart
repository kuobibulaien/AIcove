import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/tool_parameter.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';

class _FastFollowupClient extends http.BaseClient {
  int callCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) {
      return _jsonResponse(
        500,
        <String, dynamic>{'error': 'unsupported request type'},
      );
    }

    callCount += 1;
    if (callCount == 1) {
      return _jsonResponse(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '我先去生成图片',
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
      return _jsonResponse(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '{"reply":{"type":"json","ok":true}}',
              },
            },
          ],
        },
      );
    }

    return _jsonResponse(
      500,
      <String, dynamic>{'error': 'unexpected extra round'},
    );
  }

  Future<http.StreamedResponse> _jsonResponse(int code, Object body) async {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      code,
      headers: const <String, String>{
        'content-type': 'application/json',
      },
    );
  }
}

class _AsyncAcceptedImagePlugin extends BasePlugin {
  _AsyncAcceptedImagePlugin()
      : super(
          metadata: const PluginMetadata(
            id: 'image',
            name: 'Image',
            description: 'fake async image tool',
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
        description: 'draw image async accepted for test',
        parameters: const <String, ToolParameter>{},
        handler: (args) async {
          final asyncFlag = args['_aicove_async'] == true ||
              args['_aicove_async']?.toString().toLowerCase() == 'true';
          final sessionId = args['_aicove_session_id']?.toString() ?? '';
          final turnId = args['_aicove_turn_id']?.toString() ?? '';
          if (!asyncFlag || sessionId.isEmpty || turnId.isEmpty) {
            return jsonEncode(<String, dynamic>{
              'success': false,
              'accepted': false,
              'error': 'missing async metadata',
            });
          }
          final mode = args['_aicove_flow_mode']?.toString() ?? 'unknown';
          return jsonEncode(<String, dynamic>{
            'success': true,
            'accepted': true,
            'status': 'pending',
            'job_id': 'job_fast_1',
            'mode': mode,
            'provider': 'novelai',
            'model': 'nai-diffusion-4-5-full',
            'raw_prompt': 'cat',
            'prompt': 'artist style, cat',
            'negative_prompt': 'bad anatomy, low quality',
            'artist_preset_name': '防冻液',
            'artist_preset_source': 'global_selected',
            'artist_prompt_prefix': 'artist style',
            'image_count': 0,
            'message': 'image job accepted',
          });
        },
      ),
    ];
  }
}

AppSettings _buildFastModeSettings() {
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
    callFlowSettings: CallFlowSettings(mode: CallFlowMode.fast),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'fast mode should continue follow-up round when draw_image accepted asynchronously',
      () async {
    final fakeHttpClient = _FastFollowupClient();
    final settings = _buildFastModeSettings();
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
          'content': '帮我画图并继续回复 JSON',
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

    var streamResetCount = 0;
    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_fast_async_image',
      userText: '帮我画图并继续回复 JSON',
      effectivePlugins: <Plugin>[_AsyncAcceptedImagePlugin()],
      onStreamTextReset: () {
        streamResetCount += 1;
      },
    );

    expect(fakeHttpClient.callCount, 2);
    expect(streamResetCount, 1);
    expect(result.replyText, contains('"ok":true'));
    expect(result.processedText, contains('"ok":true'));
    expect(result.toolCalls, isNotEmpty);
    expect(
        result.rawToolResults.where((r) => r.name == 'draw_image').length, 1);
    final drawToolResult =
        result.rawToolResults.firstWhere((r) => r.name == 'draw_image').result;
    expect(drawToolResult, contains('"accepted":true'));
    expect(drawToolResult, contains('"job_id":"job_fast_1"'));
    expect(drawToolResult, contains('"image_delivery_pending":true'));
    expect(drawToolResult, contains('"raw_prompt":"cat"'));
    expect(drawToolResult, contains('"prompt":"artist style, cat"'));
    expect(
      drawToolResult,
      contains('"negative_prompt":"bad anatomy, low quality"'),
    );
    expect(drawToolResult, contains('"artist_preset_name":"防冻液"'));
    expect(
      drawToolResult,
      contains('"artist_preset_source":"global_selected"'),
    );
  });
}
