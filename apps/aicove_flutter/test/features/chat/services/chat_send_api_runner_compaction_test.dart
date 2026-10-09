import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'api_runner_variants.dart';

class OverflowClient extends AgentApiClient {
  OverflowClient() : super();
  int calls = 0;
  bool alwaysOverflow = false;
  List<Map<String, dynamic>> continuation = [];
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
    Map<String, dynamic>? toolPrefs,
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
    calls++;
    if (calls == 1) {
      return const SendMessageRichResult(
        text: '',
        toolResults: [],
        toolCalls: [
          ToolCall(
            id: 'call1',
            name: 'memory_read',
            arguments: {'id': 'a_event'},
          ),
        ],
      );
    }
    if (calls == 2 || alwaysOverflow) {
      throw StateError('context_length_exceeded');
    }
    continuation = List.of(messages);
    return const SendMessageRichResult(text: '读取完成', toolResults: []);
  }
}

class Context implements RuntimeContextPort {
  int checks = 0, recoveries = 0;
  @override
  Future<List<Map<String, dynamic>>> prepare(
    List<Map<String, dynamic>> messages, {
    bool force = false,
  }) async {
    checks++;
    if (force) recoveries++;
    return messages;
  }
}

void _runAll(RunnerFactory createRunner) {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final fail in [false, true]) {
    test('服务器超限只重试模型，不重复成功工具；持续超限=$fail', () async {
      final client = OverflowClient()..alwaysOverflow = fail;
      final context = Context();
      var executions = 0;
      final tool = AITool(
        name: 'memory_read',
        description: 'test',
        parameters: const {},
        handler: (_) async {
          executions++;
          return '已读取';
        },
      );
      final settings = mapUiModelsToAppSettings({});
      final runner = createRunner(
        agentClientFactory: (_) => client,
      );
      final future = runner.executeApiCall(
        config: ApiConfig(
          settings: settings,
          modelFullId: settings.defaultModelName,
          providerApiBase: 'https://invalid.test',
          customConfig: const {},
          toolPrefs: const {},
          messages: const [
            {'role': 'user', 'content': '读一次'},
          ],
          tools: [tool.toOpenAISchema()],
          boundTools: [tool],
          runtimeContext: context,
        ),
        sessionId: 'a',
        userText: '读一次',
        effectivePlugins: const [],
        enableStreaming: false,
      );
      if (fail) {
        await expectLater(future, throwsStateError);
      } else {
        expect((await future).replyText, '读取完成');
      }
      expect(executions, 1);
      expect(client.calls, 3);
      expect(context.recoveries, 1);
      expect(context.checks, 3);
    });
  }
}

void main() {
  for (final (variant, createRunner) in apiRunnerVariants) {
    group(variant, () => _runAll(createRunner));
  }
}
