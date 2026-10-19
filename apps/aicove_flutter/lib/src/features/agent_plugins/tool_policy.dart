import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

import '../agent_context/domain/agent_runtime_contracts.dart';
import '../plugins/mcp/mcp_connector.dart';
import '../plugins/web_search/web_search_config.dart';
import '../settings/app_settings.dart';

/// Gate for an [AgentToolAuthorization] mode (batch 2 plan §3.4).
class AuthorizationToolGate implements ToolGate {
  const AuthorizationToolGate(this.mode);

  final AgentToolAuthorization mode;

  @override
  GateVerdict check(KernelToolCall call, ToolEffect effect) => switch (mode) {
        AgentToolAuthorization.allowAll ||
        AgentToolAuthorization.unrestricted =>
          const GateVerdict.allow(),
        AgentToolAuthorization.manual => effect == ToolEffect.readDiagnostic
            ? const GateVerdict.allow()
            : GateVerdict.ask(_reasonOf(effect)),
      };

  static String _reasonOf(ToolEffect effect) => switch (effect) {
        ToolEffect.readDiagnostic => '读取诊断数据',
        ToolEffect.readPrivate => '读取聊天内容、记忆或角色设定',
        ToolEffect.write => '修改设置（可撤销）',
        ToolEffect.destructive => '删除数据（会先备份）',
        ToolEffect.external => '调用外部服务',
      };
}

/// Runtime tool policy of one run: the gate from the agent's authorization
/// mode, the approval channel and the secret redactor. A run without a
/// policy executes tools exactly as before the gate existed.
class AgentToolPolicy {
  const AgentToolPolicy({
    required this.authorization,
    this.approvals,
    this.redactor,
    this.approvalTimeout = const Duration(minutes: 2),
    this.customGate,
  });

  final AgentToolAuthorization authorization;

  /// Replaces the gate of [authorization], for agents that rate risk per
  /// call such as the AIcove assistant (ADR0073).
  final ToolGate? customGate;

  /// Asks the user; without one every `ask` verdict becomes a rejection.
  final ApprovalPort? approvals;
  final SecretRedactor? redactor;
  final Duration approvalTimeout;

  ToolGate get gate => customGate ?? AuthorizationToolGate(authorization);
}

/// A redactor holding the credentials the app keeps: model channel keys, MCP
/// tokens and header values, and web search keys (batch 2 plan §3.4). A
/// safety net only; tools must still never return secrets.
SecretRedactor redactorForCredentials({
  required AppSettings settings,
  Iterable<McpConnector> mcpConnectors = const [],
  WebSearchConfig? webSearch,
}) {
  final redactor = SecretRedactor();
  for (final provider in settings.providers) {
    provider.apiKeys.forEach(redactor.register);
  }
  for (final connector in mcpConnectors) {
    redactor.register(connector.bearerToken);
    connector.headers.values.forEach(redactor.register);
  }
  for (final entry in webSearch?.providers ?? const <WebSearchProviderEntry>[]) {
    redactor.register(entry.apiKey);
  }
  return redactor;
}
