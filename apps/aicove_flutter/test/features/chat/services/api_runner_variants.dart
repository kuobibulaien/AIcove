import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';

typedef RunnerFactory =
    ApiRunner Function({
      required AgentApiClient Function(Duration timeout) agentClientFactory,
    });

/// Shared contract matrix for the single kernel-backed executor.
final List<(String, RunnerFactory)> apiRunnerVariants = [
  (
    'kernel',
    ({required agentClientFactory}) => KernelApiRunner.withAgentClientFactory(
      agentClientFactory: agentClientFactory,
    ),
  ),
];
