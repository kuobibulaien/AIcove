import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/request_control.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../task_agent/agent_execution_reliability_test.dart' as app;
import '../../task_agent/agent_reliability_regression_test.dart' as base;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'tool HTTP inherits the per-call cancellation rather than model attempt',
    () async {
      KernelCancellation? transportSignal;
      KernelCancellation? callSignal;
      final client = app.ScriptClient(
        (n, _) async => n == 1 ? app.callStep() : app.done,
      );
      await ChatSendApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      ).executeApiCall(
        config: base.config(),
        sessionId: 'tool-http',
        userText: null,
        responseProcessors: const [],
        availableTools: [
          AITool(
            name: 'step',
            description: 'read',
            parameters: const {},
            effect: ToolEffect.readDiagnostic,
            handler: (_) async {
              callSignal = ToolCallContext.current?.cancellation;
              transportSignal = RequestControl.cancellation;
              return 'ok';
            },
          ),
        ],
      );
      expect(callSignal, isNotNull);
      expect(transportSignal, same(callSignal));
    },
  );
  test(
    'cancelled HTTP wrapper cannot mark an uncooperative tool as settled',
    () async {
      final pending = Completer<String?>();
      KernelCancellation? transportSignal;
      final client = app.ScriptClient(
        (n, _) async => n == 1 ? app.callStep() : app.done,
      );
      final result =
          await ChatSendApiRunner.withAgentClientFactory(
            agentClientFactory: (_) => client,
          ).executeApiCall(
            config: ApiConfig(
              settings: mapUiModelsToAppSettings({}).copyWith(
                callFlowSettings: const CallFlowSettings(toolTimeoutSeconds: 1),
              ),
              modelFullId: 'openai:gpt-test',
              providerApiBase: 'https://invalid.test',
              customConfig: const {},
              messages: const [
                {'role': 'user', 'content': 'wait for tool'},
              ],
            ),
            sessionId: 'uncooperative-http',
            userText: null,
            responseProcessors: const [],
            availableTools: [
              AITool(
                name: 'step',
                description: 'read',
                parameters: const {},
                effect: ToolEffect.readDiagnostic,
                handler: (_) {
                  transportSignal = RequestControl.cancellation;
                  return pending.future;
                },
              ),
            ],
          );
      expect(transportSignal, isNotNull);
      expect(transportSignal!.isCancelled, true);
      expect(pending.isCompleted, false);
      expect(result.rawToolResults.single.result, contains('outcome_unknown'));
      pending.complete('late side effect result');
    },
  );
}
