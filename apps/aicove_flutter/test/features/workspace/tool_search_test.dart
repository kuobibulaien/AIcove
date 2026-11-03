import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_declarations.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_search.dart';
import 'package:aicove_flutter/src/features/workspace/application/tool_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only actual assistant tool calls seed names, across wire formats', () {
    expect(
      calledMcpToolNames([
        {
          'role': 'assistant',
          'tool_calls': [
            {
              'function': {'name': 'mcp__a__openai'},
            },
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'name': 'mcp__a__claude'},
          ],
        },
        {
          'role': 'model',
          'parts': [
            {
              'functionCall': {'name': 'mcp__a__gemini'},
            },
          ],
        },
        {'role': 'assistant', 'content': '摘要里提到 mcp__a__summary'},
        {
          'role': 'user',
          'tool_calls': [
            {
              'function': {'name': 'mcp__a__untrusted'},
            },
          ],
        },
        {'role': 'tool', 'name': 'mcp__a__result', 'content': 'ok'},
      ]),
      {'mcp__a__openai', 'mcp__a__claude', 'mcp__a__gemini'},
    );
  });

  test('schema parameter descriptions participate in discovery', () {
    final tool = AITool(
      name: 'mcp__db__lookup',
      description: 'lookup',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'customerOrder': {'type': 'string', 'description': '客户订单编号'},
        },
      },
      handler: (_) async => 'ok',
    );
    expect(CodemodeSearch([tool]).search('客户订单').single['name'], tool.name);
  });

  test('initial activation never adds missing or codemode-only tools', () {
    AITool tool(String name, ToolExposure exposure) => AITool(
      name: name,
      description: name,
      parameters: const {},
      exposure: exposure,
      handler: (_) async => 'ok',
    );
    expect(
      directToolSchemas(
        [
          tool('mcp__db__yes', ToolExposure.deferred),
          tool('nested_only', ToolExposure.codemode),
        ],
        activatedTools: {'mcp__db__yes', 'mcp__gone__no', 'nested_only'},
      ).map((schema) => (schema['function'] as Map)['name']),
      ['mcp__db__yes', 'tool_search'],
    );
  });
}
