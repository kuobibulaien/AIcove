import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';

typedef RunnerFactory = ApiRunner Function({
  required AgentApiClient Function(Duration timeout) agentClientFactory,
});

/// Differential testing (ADR0064 batch 1): every runner test runs against
/// both the legacy runner and the kernel-backed runner.
final List<(String, RunnerFactory)> apiRunnerVariants = [
  (
    'legacy',
    ({required agentClientFactory}) => ChatSendApiRunner.withAgentClientFactory(
          agentClientFactory: agentClientFactory,
        ),
  ),
  (
    'kernel',
    ({required agentClientFactory}) => KernelApiRunner.withAgentClientFactory(
          agentClientFactory: agentClientFactory,
        ),
  ),
];
