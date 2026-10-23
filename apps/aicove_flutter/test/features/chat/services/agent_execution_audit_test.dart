import 'dart:async';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall;
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../task_agent/agent_execution_reliability_test.dart' as app;
import '../../task_agent/agent_reliability_regression_test.dart' as base;
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';

const done = SendMessageRichResult(text: 'done', toolResults: []);
Future<ApiCallResult> run(
  app.ScriptClient client,
  List<AITool> tools, {
  ApiConfig? config,
}) => KernelApiRunner.withAgentClientFactory(agentClientFactory: (_) => client)
    .executeApiCall(
      config: config ?? base.config(),
      sessionId: 'execution-audit',
      userText: null,
      responseProcessors: const [],
      availableTools: tools,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'terminal reply and last tool result remain in the execution transcript',
    () async {
      final client = app.ScriptClient(
        (n, _) async => n == 1 ? app.callStep() : done,
      );
      final result = await run(client, [
        app.stepTool((_) async => 'last-result'),
      ]);
      expect(result.runningMessages.last['content'], 'done');
      expect(result.runningMessages.toString(), contains('last-result'));
    },
  );
  test(
    'length with calls never invokes incomplete arguments and requests resend',
    () async {
      var executions = 0;
      final client = app.ScriptClient(
        (n, _) async => n == 1
            ? const SendMessageRichResult(
                text: '',
                toolResults: [],
                rawFinishReason: 'length',
                toolCalls: [ToolCall(id: 'cut', name: 'step', arguments: {})],
              )
            : done,
      );
      final result = await run(client, [
        app.stepTool((_) async {
          executions++;
          return 'executed';
        }),
      ]);
      expect(executions, 0);
      expect(result.rawToolResults.single.isError, true);
      expect(client.requests.last.toString(), contains('重新完整调用'));
    },
  );
  test('quoted execute_tool example is only text', () async {
    var executions = 0;
    final client = app.ScriptClient(
      (n, _) async => const SendMessageRichResult(
        text:
            'Example:\n```xml\n<execute_tool>{"name":"step","arguments":{}}</execute_tool>\n```',
        toolResults: [],
      ),
    );
    await run(client, [
      app.stepTool((_) async {
        executions++;
        return 'executed';
      }),
    ]);
    expect(executions, 0);
    expect(client.requests.length, 1);
  });
  test('identical arguments can really retry a failed native call', () async {
    var executions = 0;
    final client = app.ScriptClient(
      (n, _) async => n <= 2 ? app.callStep() : done,
    );
    await run(client, [
      app.stepTool((_) async {
        if (++executions == 1) throw StateError('temporary failure');
        return 'ok';
      }),
    ]);
    expect(executions, 2);
  });
  test(
    'ask_user skips subsequent side effects and ends waitingForUser',
    () async {
      final fixture = await app.Fixture.create();
      var effects = 0;
      final client = app.ScriptClient(
        (n, _) async => n == 1
            ? const SendMessageRichResult(
                text: '',
                toolResults: [],
                toolCalls: [
                  ToolCall(
                    id: 'ask',
                    name: 'ask_user',
                    arguments: {'question': 'Continue?'},
                  ),
                  ToolCall(id: 'after', name: 'step', arguments: {}),
                ],
              )
            : done,
      );
      final result = await fixture
          .runner(client)
          .run(
            taskId: 't',
            runId: 'r',
            transcript: 'ask first',
            capabilities: TaskAgentCapabilities(
              tools: [
                app.stepTool((_) async {
                  effects++;
                  return 'effect';
                }),
              ],
            ),
            preset: const TaskAgentPreset(),
            cancellation: KernelCancellation(),
          );
      expect(effects, 0);
      expect(result.status.name, 'waitingForUser');
      expect(client.requests.length, 1);
      expect(result.processLog, contains('未执行'));
    },
  );
  test('speak failure text is not rewritten as success', () async {
    final client = app.ScriptClient(
      (n, _) async => n == 1
          ? const SendMessageRichResult(
              text: '',
              toolResults: [],
              toolCalls: [ToolCall(id: 'voice', name: 'speak', arguments: {})],
            )
          : done,
    );
    final result = await run(client, [
      AITool(
        name: 'speak',
        description: 'voice',
        parameters: const {},
        handler: (_) async => '{"success":false,"error":"synthesis failed"}',
      ),
    ]);
    expect(result.rawToolResults.single.result, contains('synthesis failed'));
    expect(result.toolAudioResults, isEmpty);
  });
  test(
    'timeout cancels cooperative handler and waits for its cleanup',
    () async {
      var lateEffect = false, settled = false;
      final client = app.ScriptClient(
        (n, _) async => n == 1 ? app.callStep() : done,
      );
      final cfg = ApiConfig(
        settings: mapUiModelsToAppSettings({}).copyWith(
          callFlowSettings: const CallFlowSettings(toolTimeoutSeconds: 1),
        ),
        modelFullId: 'openai:gpt-test',
        providerApiBase: 'https://invalid.test',
        customConfig: const {},
        messages: const [
          {'role': 'user', 'content': 'timeout'},
        ],
      );
      final result = await run(client, [
        AITool(
          name: 'step',
          description: 'step',
          parameters: const {},
          handler: (_) async => '',
          controlledHandler: (_, control) async {
            await control.cancellation!.whenCancelled;
            settled = true;
            control.cancellation!.throwIfCancelled();
            lateEffect = true;
            return const ToolOutput(text: 'late');
          },
        ),
      ], config: cfg);
      expect(settled, true);
      expect(lateEffect, false);
      expect(result.rawToolResults.single.isError, true);
      expect(result.rawToolResults.single.result, contains('timeout'));
    },
  );
  test(
    'uncooperative timed out handler is reported as outcome unknown',
    () async {
      final gate = Completer<String?>();
      final client = app.ScriptClient(
        (n, _) async => n == 1 ? app.callStep() : done,
      );
      final cfg = ApiConfig(
        settings: mapUiModelsToAppSettings({}).copyWith(
          callFlowSettings: const CallFlowSettings(toolTimeoutSeconds: 1),
        ),
        modelFullId: 'openai:gpt-test',
        providerApiBase: 'https://invalid.test',
        customConfig: const {},
        messages: const [
          {'role': 'user', 'content': 'timeout'},
        ],
      );
      final result = await run(client, [
        app.stepTool((_) => gate.future),
      ], config: cfg);
      expect(result.rawToolResults.single.result, contains('outcome_unknown'));
      gate.complete('late');
    },
  );
}
