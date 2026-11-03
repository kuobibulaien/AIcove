import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    hide ApiCallResult;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_declarations.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends AgentApiClient {
  _Client(this.steps);
  final List<List<ToolCall>> steps;
  final declarations = <List<String>>[];
  final messagesSeen = <List<Map<String, dynamic>>>[];

  SendMessageRichResult _reply(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
  ) {
    declarations.add([
      for (final schema in tools ?? <Map<String, dynamic>>[])
        (schema['function'] as Map)['name'] as String,
    ]);
    messagesSeen.add(
      jsonDecode(jsonEncode(messages)).cast<Map<String, dynamic>>(),
    );
    return SendMessageRichResult(
      text: 'done',
      toolResults: const [],
      toolCalls: steps.removeAt(0),
    );
  }

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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async => _reply(messages, tools);

  @override
  Future<SendMessageRichResult> sendMessageRichStream({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    double? topP,
    String? token,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools,
    ProviderChatRequestOptions? requestOptions,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async => _reply(messages, tools);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('mcp_loadout_'),
  );
  tearDown(() async => root.delete(recursive: true));

  AITool mcp(String name, {void Function()? onCall}) => AITool(
    name: name,
    description: '查询本地数据库订单 database orders',
    parameters: const {},
    inputSchema: const {'type': 'object', 'properties': {}},
    handler: (_) async {
      onCall?.call();
      return '订单结果';
    },
  );

  Future<ApiCallResult> run(
    _Client client,
    List<AITool> tools, {
    List<Map<String, dynamic>> history = const [],
    bool streaming = false,
    void Function(List<Map<String, dynamic>>)? onSchemas,
    String model = 'openai:test',
  }) =>
      KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      ).executeApiCall(
        config: ApiConfig(
          toolResultStore: ToolResultStore(() async => root),
          settings: mapUiModelsToAppSettings({}),
          modelFullId: model,
          providerApiBase: 'https://invalid.test',
          customConfig: const {},
          messages: [
            ...history,
            {'role': 'user', 'content': '查询订单'},
          ],
          tools: directToolSchemas(tools),
          onToolSchemasChanged: onSchemas,
        ),
        sessionId: 'test',
        userText: '查询订单',
        responseProcessors: const [],
        availableTools: tools,
        enableStreaming: streaming,
      );

  for (final streaming in [false, true]) {
    test('search activates MCP for the next model step ($streaming)', () async {
      var calls = 0;
      final budgetNames = <List<String>>[];
      final client = _Client([
        [
          const ToolCall(
            id: 'search',
            name: 'tool_search',
            arguments: {'query': '数据库'},
          ),
        ],
        [const ToolCall(id: 'lookup', name: 'mcp__db__orders', arguments: {})],
        [],
      ]);
      final result = await run(
        client,
        assembleCodemodeTools([mcp('mcp__db__orders', onCall: () => calls++)]),
        streaming: streaming,
        onSchemas: (schemas) => budgetNames.add([
          for (final schema in schemas)
            (schema['function'] as Map)['name'] as String,
        ]),
      );
      expect(client.declarations.first, contains('tool_search'));
      expect(client.declarations.first, isNot(contains('mcp__db__orders')));
      expect(client.declarations[1], contains('mcp__db__orders'));
      expect(calls, 1);
      expect(result.rawToolResults.first.name, 'tool_search');
      expect(result.rawToolResults.last.name, 'mcp__db__orders');
      expect(budgetNames, client.declarations);
    });
  }

  test(
    'recent called MCP names seed a new run, but search prose does not',
    () async {
      final history = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'old',
              'type': 'function',
              'function': {'name': 'mcp__db__orders', 'arguments': '{}'},
            },
            {
              'id': 'gone',
              'type': 'function',
              'function': {'name': 'mcp__gone__secret', 'arguments': '{}'},
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'old',
          'name': 'mcp__db__orders',
          'content': 'ok',
        },
        {
          'role': 'tool',
          'tool_call_id': 'gone',
          'name': 'mcp__gone__secret',
          'content': 'ok',
        },
        {'role': 'assistant', 'content': 'tool_search found mcp__db__unused'},
      ];
      final tools = assembleCodemodeTools([
        mcp('mcp__db__orders'),
        mcp('mcp__db__unused'),
      ]);
      final client = _Client([[]]);
      await run(client, tools, history: history);
      expect(client.declarations.single, contains('mcp__db__orders'));
      expect(client.declarations.single, isNot(contains('mcp__gone__secret')));
      expect(client.declarations.single, isNot(contains('mcp__db__unused')));
      final next = _Client([[]]);
      await run(next, tools);
      expect(next.declarations.single, isNot(contains('mcp__db__orders')));
    },
  );

  test('search with no match does not activate or execute tools', () async {
    var calls = 0;
    final client = _Client([
      [
        const ToolCall(
          id: 'search',
          name: 'tool_search',
          arguments: {'query': 'unmatchedzzzz'},
        ),
      ],
      [],
    ]);
    await run(
      client,
      assembleCodemodeTools([mcp('mcp__db__orders', onCall: () => calls++)]),
    );
    expect(client.declarations.last, isNot(contains('mcp__db__orders')));
    expect(calls, 0);
    expect(jsonEncode(client.messagesSeen.last), contains('loaded'));
  });

  test('ordinary direct tools are unchanged and do not add search', () async {
    final client = _Client([[]]);
    await run(client, [mcp('mcp__db__orders')]);
    expect(client.declarations.single, contains('mcp__db__orders'));
    expect(client.declarations.single, isNot(contains('tool_search')));
  });

  test('invalid search parameters never activate a tool', () async {
    final client = _Client([
      [
        const ToolCall(
          id: 'bad',
          name: 'tool_search',
          arguments: {'query': '数据库', 'limit': 0},
        ),
      ],
      [],
    ]);
    final result = await run(
      client,
      assembleCodemodeTools([mcp('mcp__db__orders')]),
    );
    expect(result.rawToolResults.single.isError, isTrue);
    expect(client.declarations.last, isNot(contains('mcp__db__orders')));
  });

  for (final provider in ['claude', 'gemini']) {
    test('$provider adapter continues after loading and calling MCP', () async {
      var calls = 0;
      final client = _Client([
        [
          const ToolCall(
            id: 'search',
            name: 'tool_search',
            arguments: {'query': '数据库'},
          ),
        ],
        [const ToolCall(id: 'lookup', name: 'mcp__db__orders', arguments: {})],
        [],
      ]);
      await run(
        client,
        assembleCodemodeTools([mcp('mcp__db__orders', onCall: () => calls++)]),
        model: '$provider:test',
      );
      expect(client.declarations[1], contains('mcp__db__orders'));
      expect(calls, 1);
    });
  }

  test(
    'search only activates matching deferred tools and honors the limit',
    () async {
      final client = _Client([
        [
          const ToolCall(
            id: 'search',
            name: 'tool_search',
            arguments: {'query': '数据库', 'limit': 1},
          ),
        ],
        [],
      ]);
      await run(
        client,
        assembleCodemodeTools([
          mcp('mcp__db__first'),
          mcp('mcp__db__second'),
          mcp('aicove_not_deferred'),
        ]),
      );
      expect(client.declarations.last, contains('mcp__db__first'));
      expect(client.declarations.last, isNot(contains('mcp__db__second')));
      expect(client.declarations.last, isNot(contains('aicove_not_deferred')));
    },
  );
}
