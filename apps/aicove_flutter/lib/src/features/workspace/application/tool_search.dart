import '../../plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;

const toolSearchName = 'tool_search';

/// The declaration is shared by request assembly and the run-local handler.
AITool createToolSearch({
  Future<String?> Function(Map<String, dynamic>)? handler,
}) => AITool(
  name: toolSearchName,
  description:
      '搜索当前可用的外部 MCP 工具并加载匹配项。下一次模型请求会提供它们的完整参数，'
      '届时可以直接调用，不必写 codemode 脚本。搜索本身不执行外部操作。',
  parameters: const {},
  inputSchema: const {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'minLength': 1, 'description': '需要的能力或工具名称'},
      'limit': {'type': 'integer', 'minimum': 1, 'maximum': 20, 'default': 8},
    },
    'required': ['query'],
  },
  effect: ToolEffect.readDiagnostic,
  handler:
      handler ??
      (_) async => throw StateError('tool_search requires an active Agent run'),
);

/// Reads actual assistant calls from the current, uncompressed request history.
/// ToolBlock history is rendered into these calls by ChatRequestMessageBuilder.
/// Names in prose, summaries and tool results never activate anything.
Set<String> calledMcpToolNames(Iterable<Map<String, dynamic>> messages) {
  final names = <String>{};
  void add(Object? value) {
    if (value is String && value.startsWith('mcp__')) names.add(value);
  }

  for (final message in messages) {
    if (message['role'] != 'assistant' && message['role'] != 'model') continue;
    for (final call in message['tool_calls'] as List? ?? const []) {
      if (call is Map && call['function'] is Map) {
        add((call['function'] as Map)['name']);
      }
    }
    if (message['function_call'] is Map) {
      add((message['function_call'] as Map)['name']);
    }
    final content = message['content'];
    final parts =
        message['parts'] ?? (content is Map ? content['parts'] : content);
    if (parts is List) {
      for (final part in parts.whereType<Map>()) {
        if (part['type'] == 'tool_use') add(part['name']);
        if (part['functionCall'] is Map) {
          add((part['functionCall'] as Map)['name']);
        }
      }
    }
  }
  return names;
}
