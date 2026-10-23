import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import '../../task_agent/agent_execution_reliability_test.dart' as app;
import '../../task_agent/agent_reliability_regression_test.dart' as base;

void main() {
  test('all production callers select the single kernel executor', () {
    expect(createApiRunner(), isA<KernelApiRunner>());
  });
  test(
    'independent declared reads run in parallel regardless of image route',
    () async {
      final ready = Completer<void>(), release = Completer<void>();
      var started = 0;
      final client = app.ScriptClient(
        (n, _) async => n == 1 ? app.callStep(count: 2) : app.done,
      );
      final tool = AITool(
        name: 'step',
        description: 'read',
        parameters: const {},
        effect: ToolEffect.readDiagnostic,
        handler: (_) async {
          if (++started == 2) ready.complete();
          await release.future;
          return 'read result';
        },
      );
      final run =
          KernelApiRunner.withAgentClientFactory(
            agentClientFactory: (_) => client,
          ).executeApiCall(
            config: base.config(),
            sessionId: 'parallel',
            userText: null,
            responseProcessors: const [],
            availableTools: [tool],
          );
      await ready.future;
      expect(started, 2);
      release.complete();
      await run;
    },
  );
  test(
    'historical ChatSendApiRunner entry point uses the same reliable loop',
    () async {
      var effects = 0;
      final client = app.ScriptClient(
        (n, _) async => n == 1 ? app.callStep() : app.done,
      );
      final runner = ChatSendApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      );
      final result = await runner.executeApiCall(
        config: base.config(),
        sessionId: 'compat',
        userText: null,
        responseProcessors: const [],
        availableTools: [
          app.stepTool((_) async {
            effects++;
            return 'result';
          }),
        ],
      );
      expect(effects, 1);
      expect(result.runningMessages.last['content'], '完成');
    },
  );
}
