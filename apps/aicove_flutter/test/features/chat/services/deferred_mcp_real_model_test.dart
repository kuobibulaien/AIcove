@Tags(['real_model'])
library;

import 'dart:io';

import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_declarations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  test(
    'DeepSeek discovers a deferred MCP tool and calls it directly',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp_real_');
      addTearDown(() => root.delete(recursive: true));
      final tools = assembleCodemodeTools([
        AITool(
          name: 'mcp__orders__lookup',
          description: '查询测试订单，返回验收暗号。',
          parameters: const {},
          inputSchema: const {'type': 'object', 'properties': {}},
          handler: (_) async => '订单暗号：MCP_DIRECT_ACCEPTED',
        ),
      ]);
      final result = await const KernelApiRunner().executeApiCall(
        config: ApiConfig(
          settings: mapUiModelsToAppSettings({}),
          modelFullId: 'openai:deepseek/deepseek-v4.1-flash-1017',
          providerApiBase: 'https://api-gateway.merge.dev/v1/openai',
          providerApiKey: key,
          customConfig: const {},
          tools: directToolSchemas(tools),
          boundTools: tools,
          toolResultStore: ToolResultStore(() async => root),
          modelTemperature: 0.0,
          messages: const [
            {
              'role': 'system',
              'content': '你是工具验收助手。使用 tool_search 搜索订单查询工具，再直接调用加载后的工具。不要编造结果。',
            },
            {'role': 'user', 'content': '查询测试订单，把返回的暗号原样告诉我。'},
          ],
        ),
        sessionId: 'mcp-real',
        userText: '查询测试订单',
        responseProcessors: const [],
      );
      expect(
        result.toolCalls.map((call) => call.name),
        containsAllInOrder(['tool_search', 'mcp__orders__lookup']),
      );
      expect(result.rawToolResults.every((output) => !output.isError), isTrue);
      expect(result.processedText, contains('MCP_DIRECT_ACCEPTED'));
    },
    skip: key == null || key.isEmpty ? 'DEEPSEEK_API_KEY is not set' : false,
  );
}
