import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    hide ApiCallResult;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/core/api/tool_media.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart';
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Client extends AgentApiClient {
  final List<List<Map<String, dynamic>>> sent = [];
  bool callTools = true;
  @override
  Future<SendMessageRichResult> sendMessageRich({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    double? topP,
    String? token,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    sent.add(jsonDecode(jsonEncode(messages)).cast<Map<String, dynamic>>());
    return SendMessageRichResult(
      text: 'done',
      toolResults: const [],
      toolCalls: !callTools
          ? const []
          : switch (sent.length) {
              1 => const [
                ToolCall(id: 'p', name: 'picture', arguments: {}),
                ToolCall(id: 'e', name: 'error', arguments: {}),
              ],
              2 => const [ToolCall(id: 't', name: 'text', arguments: {})],
              _ => const [],
            },
    );
  }
}

AppSettings _settings(bool vision) => mapUiModelsToAppSettings({
  'model_configs': {
    'openai:test': {
      'chat_capabilities': ['tools', if (vision) 'vision'],
    },
  },
});
ToolImage _image() => ToolImage(
  mimeType: 'image/png',
  bytes: Uint8List.fromList([1, 2, 3]),
  source: 'test image',
);
List<AITool> _tools({String text = ''}) => [
  AITool(
    name: 'picture',
    description: 'picture',
    parameters: const {},
    handler: (_) async => 'unused',
    richHandler: (_) async => ToolOutput(
      text: text,
      images: [_image()],
      structured: const {'answer': 42},
    ),
    effect: ToolEffect.readDiagnostic,
  ),
  AITool(
    name: 'error',
    description: 'error',
    parameters: const {},
    handler: (_) async => 'unused',
    richHandler: (_) async => const ToolOutput(text: 'failure', isError: true),
    effect: ToolEffect.readDiagnostic,
  ),
  AITool(
    name: 'text',
    description: 'text',
    parameters: const {},
    handler: (_) async => 'plain',
    effect: ToolEffect.readDiagnostic,
  ),
];
ApiConfig _config(
  bool vision, {
  AgentToolPolicy? policy,
  List<Map<String, dynamic>>? messages,
}) => ApiConfig(
  settings: _settings(vision),
  modelFullId: 'openai:test',
  providerApiBase: 'https://invalid.test',
  providerApiKey: 'test',
  customConfig: const {},
  messages:
      messages ??
      [
        {'role': 'user', 'content': 'look'},
      ],
  toolPolicy: policy,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'raw chat projection omits image bytes without mutating live result',
    () {
      final image = _image();
      final live = ToolResult(
        toolCallId: 'p',
        name: 'picture',
        result: 'text',
        images: [image],
      );
      final payload = ChatMessageProjectionCodec.buildRawAssistantPayload(
        apiResult: ApiCallResult(
          replyText: 'done',
          processedText: 'done',
          pluginEvents: const [],
          toolResults: const [],
          rawToolResults: [live],
        ),
      );
      expect(jsonEncode(payload), contains('［图片已省略：test image］'));
      expect(jsonEncode(payload), isNot(contains('AQID')));
      expect(live.images.single, same(image));
    },
  );
  test(
    'kernel retains rich images across rounds, persists only text, next run replays placeholders',
    () async {
      final client = _Client();
      final runner = KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      );
      final result = await runner.executeApiCall(
        config: _config(true),
        sessionId: 'rich',
        userText: 'look',
        responseProcessors: const [],
        availableTools: _tools(),
      );
      expect(client.sent, hasLength(3));
      for (final request in client.sent.skip(1)) {
        expect(jsonEncode(request), contains('data:image/png;base64,AQID'));
        expect(jsonEncode(request), isNot(contains(toolStepMarker)));
      }
      expect(
        result.rawToolResults.map((r) => r.result),
        contains('［图片已省略：test image］'),
      );
      expect(result.rawToolResults.every((r) => r.images.isEmpty), isTrue);
      expect(
        result.rawToolResults.firstWhere((r) => r.name == 'error').isError,
        isTrue,
      );
      final replay = _Client()..callTools = false;
      await KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => replay,
      ).executeApiCall(
        config: _config(
          true,
          messages: [
            for (final r in result.rawToolResults)
              {
                'role': 'tool',
                'tool_call_id': r.toolCallId,
                'content': r.result,
              },
            {'role': 'user', 'content': 'continue'},
          ],
        ),
        sessionId: 'next',
        userText: 'continue',
        responseProcessors: const [],
      );
      expect(jsonEncode(replay.sent), isNot(contains('base64')));
      expect(jsonEncode(replay.sent), contains('图片已省略'));
    },
  );
  test('nonvision model gets the exact instruction and no image', () async {
    final client = _Client();
    await KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => client,
    ).executeApiCall(
      config: _config(false),
      sessionId: 'nonvision',
      userText: 'look',
      responseProcessors: const [],
      availableTools: _tools(),
    );
    expect(jsonEncode(client.sent), contains(nonVisionToolImage));
    expect(jsonEncode(client.sent), isNot(contains('base64')));
  });
  test('legacy executor takes the persistent text projection', () async {
    final client = _Client();
    final result =
        await ChatSendApiRunner.withAgentClientFactory(
          agentClientFactory: (_) => client,
        ).executeApiCall(
          config: _config(true),
          sessionId: 'legacy',
          userText: 'look',
          responseProcessors: const [],
          availableTools: _tools(),
        );
    expect(jsonEncode(client.sent), isNot(contains('base64')));
    expect(result.rawToolResults.first.result, '［图片已省略：test image］');
  });
  test(
    'kernel redaction does not recover stale payload by matching text',
    () async {
      final client = _Client();
      final policy = AgentToolPolicy(
        authorization: AgentToolAuthorization.allowAll,
        redactor: SecretRedactor()..register('secret'),
      );
      final result =
          await KernelApiRunner.withAgentClientFactory(
            agentClientFactory: (_) => client,
          ).executeApiCall(
            config: _config(true, policy: policy),
            sessionId: 'redacted',
            userText: 'look',
            responseProcessors: const [],
            availableTools: _tools(text: 'secret'),
          );
      expect(jsonEncode(client.sent), isNot(contains('base64')));
      expect(result.rawToolResults.first.result, SecretRedactor.mask);
    },
  );
  test(
    'errand wrapper forwards rich handler and timeout, process log omits bytes',
    () async {
      var started = 0;
      final original = _tools().first;
      final tool = AITool(
        name: original.name,
        description: original.description,
        parameters: original.parameters,
        handler: original.handler,
        richHandler: original.richHandler,
        executionTimeout: const Duration(seconds: 120),
      );
      final runner = TaskAgentRunner(
        loadSettings: () async => _settings(true),
        requestConfig: ({required settings, required modelRef}) async =>
            const BackgroundAgentRequestConfig(
              modelFullId: 'openai:test',
              providerApiBase: 'https://invalid.test',
              providerApiKey: 'test',
              customConfig: {},
              modelTemperature: null,
              modelTopP: null,
              modelContextMessageLimit: null,
            ),
        executor:
            ({
              required config,
              required tools,
              required sessionId,
              required cancellation,
            }) async {
              final wrapped = tools.firstWhere((t) => t.name == 'picture');
              expect(wrapped.executionTimeout, tool.executionTimeout);
              final output = await wrapped.invoke({});
              expect(output.images, hasLength(1));
              expect(output.structured, {'answer': 42});
              return ApiCallResult(
                replyText: 'done',
                processedText: 'done',
                pluginEvents: const [],
                toolResults: const [],
                toolCalls: const [
                  ToolCall(id: 'p', name: 'picture', arguments: {}),
                ],
                rawToolResults: [
                  ToolResult(
                    toolCallId: 'p',
                    name: 'picture',
                    result: output.text,
                    images: output.images,
                  ),
                ],
              );
            },
      );
      final result = await runner.run(
        taskId: 'task',
        runId: 'run',
        transcript: 'look',
        capabilities: TaskAgentCapabilities(tools: [tool]),
        preset: const TaskAgentPreset(),
        cancellation: KernelCancellation(),
        onExternalStart: () => started++,
      );
      expect(started, 1);
      expect(result.processLog, contains('［图片已省略：test image］'));
      expect(result.processLog, isNot(contains('base64')));
    },
  );
  for (final stream in [false, true]) {
    for (final fail in [false, true]) {
      test(
        'API and failure logs exclude image data (stream=$stream fail=$fail)',
        () async {
          ApiLogger.clear();
          final requests = <String>[];
          final httpClient = MockClient((r) async {
            requests.add(r.body);
            if (fail) throw StateError('offline');
            if (stream) {
              return http.Response(
                'data: {"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }
            return http.Response(
              '{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          });
          addTearDown(httpClient.close);
          final api = AgentApiClient(client: httpClient);
          Future<void> send() async {
            final messages = ToolMedia.wire(toolImageMessages([_image()]));
            if (stream) {
              await api.sendMessageRichStream(
                agentId: 'default',
                sessionId: 'log',
                modelFullId: 'openai:test',
                messages: messages,
                userText: '',
                providerApiBase: 'https://invalid.test',
                providerApiKey: 'test',
              );
            } else {
              await api.sendMessageRich(
                agentId: 'default',
                sessionId: 'log',
                modelFullId: 'openai:test',
                messages: messages,
                userText: '',
                providerApiBase: 'https://invalid.test',
                providerApiKey: 'test',
              );
            }
          }

          if (fail) {
            await expectLater(send(), throwsA(isA<StateError>()));
          } else {
            await send();
          }
          expect(requests.single, contains('base64,AQID'));
          expect(ApiLogger.entries.value, isNotEmpty);
          for (final entry in ApiLogger.entries.value) {
            final log =
                '${entry.requestBody}${entry.rawContext}${entry.rawRequestBody}';
            expect(log, isNot(contains('base64,AQID')));
            expect(log, contains('image_metadata'));
          }
        },
      );
    }
  }
}
