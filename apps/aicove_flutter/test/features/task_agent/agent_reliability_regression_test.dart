import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation, KernelCancelledException;
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult, ProviderChatRequestOptions;
import 'package:aicove_flutter/src/core/app_logger.dart' show TraceLogger;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_http_client.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_process_record.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:drift/native.dart';

class ProbeClient extends AgentApiClient {
  ProbeClient(this.respond);
  final Future<SendMessageRichResult> Function() respond;
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
  }) => respond();
}

ApiConfig config() => ApiConfig(
  settings: mapUiModelsToAppSettings({}),
  modelFullId: 'openai:gpt-test',
  providerApiBase: 'https://invalid.test',
  customConfig: const {},
  messages: const [
    {'role': 'user', 'content': 'complete a multistep task'},
  ],
);
Future<BackgroundAgentRequestConfig> resolve({
  required AppSettings settings,
  required String? modelRef,
}) async => const BackgroundAgentRequestConfig(
  modelFullId: 'openai:gpt-test',
  providerApiBase: 'https://invalid.test',
  providerApiKey: null,
  customConfig: {},
  modelTemperature: null,
  modelTopP: null,
  modelContextMessageLimit: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('no round cap: runs until the model stops; task compaction is configured', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'c',
            title: 'c',
            displayName: 'c',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
    var calls = 0;
    final tool = AITool(
      name: 'step',
      description: 'one step',
      parameters: const {},
      handler: (_) async {
        calls++;
        return 'more work remains';
      },
    );
    var requests = 0;
    final client = ProbeClient(
      () async => ++requests <= 8
          ? SendMessageRichResult(
              text: 'Doing step $requests',
              toolResults: const [],
              toolCalls: [ToolCall(id: 's$requests', name: 'step', arguments: const {})],
            )
          : const SendMessageRichResult(text: 'All steps done', toolResults: []),
    );
    final api = KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => client,
    );
    ApiConfig? observed;
    final runner = TaskAgentRunner(
      loadSettings: () async => mapUiModelsToAppSettings({}),
      requestConfig: resolve,
      executor:
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) {
            observed = config;
            return api.executeApiCall(
              config: config,
              sessionId: sessionId,
              userText: null,
              responseProcessors: const [],
              availableTools: tools,
              cancellation: cancellation,
            );
          },
    );
    final store = AgentTaskStore(database);
    final directory = await Directory.systemTemp.createTemp(
      'aicove-pi-gap-record-',
    );
    final service = TaskAgentService(
      store: store,
      process: TaskProcessRecord(directory),
      runner: runner,
      capabilities: (_, _, _) async => TaskAgentCapabilities(tools: [tool]),
      writeReceipt: (_) async {},
      relay: (_, _) async => true,
      findReceipt: (_) async => null,
      ownsConversation: (_) async => true,
      deviceId: () async => 'probe',
      newId: () => 't',
      preset: const TaskAgentPreset(),
    );
    await service.start(
      conversationId: 'c',
      instruction: 'Requires more than one step',
    );
    await service.idle();
    expect(calls, 8);
    expect(observed!.runtimeContext, isNotNull);
    expect((await store.get('t'))!.status, AgentTaskStatus.done);
  });

  test('cancellation ends an outstanding model request immediately', () async {
    final started = Completer<void>();
    final response = Completer<SendMessageRichResult>();
    final client = ProbeClient(() {
      started.complete();
      return response.future;
    });
    final api = KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => client,
    );
    final cancellation = KernelCancellation();
    var ended = false;
    final future = api.executeApiCall(
      config: config(),
      sessionId: 'cancel',
      userText: null,
      responseProcessors: const [],
      cancellation: cancellation,
    );
    final checked =
        expectLater(
          future,
          throwsA(isA<KernelCancelledException>()),
        ).whenComplete(() {
          ended = true;
        });
    await started.future;
    cancellation.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(ended, isTrue);
    response.complete(
      const SendMessageRichResult(text: 'late', toolResults: []),
    );
    await checked;
  });

  test('invalid arguments never enter the handler', () async {
    var executions = 0;
    final tool = AITool(
      name: 'typed',
      description: 'integer input',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'n': {'type': 'integer'},
        },
        'required': ['n'],
      },
      handler: (_) async {
        executions++;
        return 'ran';
      },
    );
    var requests = 0;
    final client = ProbeClient(
      () async => ++requests > 1 ? const SendMessageRichResult(text: 'done', toolResults: []) : const SendMessageRichResult(
        text: '',
        toolResults: [],
        toolCalls: [
          ToolCall(
            id: 'invalid',
            name: 'typed',
            arguments: {'n': 'not an integer'},
          ),
        ],
      ),
    );
    final api = KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => client,
    );
    await api.executeApiCall(
      config: config(),
      sessionId: 'schema',
      userText: null,
      responseProcessors: const [],
      availableTools: [tool],
    );
    expect(executions, 0);
  });

  test(
    'MCP and task transcript preserve long result references and tail readback',
    () async {
      final directory = await Directory.systemTemp.createTemp('tool-results-');
      final store = ToolResultStore(() async => directory);
      final text = '${List.filled(21000, 'x').join()}TAIL_EVIDENCE';
      final flattened = McpHttpClient.flattenToolResult({
        'content': [
          {'type': 'text', 'text': text},
        ],
      });
      expect(flattened, text);
      final preview = await store.preserve('task', flattened);
      final reference = RegExp(
        r'reference=([a-f0-9]+)',
      ).firstMatch(preview)!.group(1)!;
      expect(preview.length, lessThan(ToolResultStore.maxInlineChars));
      final process = TaskAgentRunner.processLog(
        const [ToolCall(id: 'c', name: 'mcp', arguments: {})],
        [ToolResult(toolCallId: 'c', name: 'mcp', result: preview)],
        '',
      );
      expect(process, contains(reference));
      final reopened = ToolResultStore(() async => directory);
      final page =
          jsonDecode(await reopened.read('task', reference, offset: 21000))
              as Map;
      expect(page['text'], 'TAIL_EVIDENCE');
      expect(page['eof'], true);
      await expectLater(
        reopened.read('other-task', reference),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        reopened.read('task', '../escape'),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
