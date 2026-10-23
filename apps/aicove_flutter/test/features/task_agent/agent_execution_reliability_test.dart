import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ProviderChatRequestOptions;
import 'package:aicove_flutter/src/core/api/request_control.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/tool_schema_validator.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_process_record.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_reliability_regression_test.dart' as probe;

const done = SendMessageRichResult(text: '完成', toolResults: []);
const askUser = SendMessageRichResult(
  text: '',
  toolResults: [],
  toolCalls: [
    ToolCall(
      id: 'ask',
      name: TaskAgentRunner.askToolName,
      arguments: {'question': '继续吗？'},
    ),
  ],
);
SendMessageRichResult callStep({String text = '', int count = 1}) =>
    SendMessageRichResult(
      text: text,
      toolResults: const [],
      toolCalls: [
        for (var i = 1; i <= count; i++)
          ToolCall(id: '$i', name: 'step', arguments: {'n': i}),
      ],
    );

class ScriptClient extends AgentApiClient {
  ScriptClient(this.respond);
  final Future<SendMessageRichResult> Function(int, List<Map<String, dynamic>>)
  respond;
  final requests = <List<Map<String, dynamic>>>[];
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
  }) {
    requests.add(jsonDecode(jsonEncode(messages)).cast<Map<String, dynamic>>());
    return respond(requests.length, messages);
  }
}

class Summary implements ContextSummarizerPort {
  int calls = 0;
  @override
  Future<String> summarize(
    ContextSnapshot snapshot, {
    required ContextSummaryKind kind,
    required void Function(int, int) onProgress,
    required bool Function() isCancelled,
  }) async {
    calls++;
    return '已执行 step，结果已保存；继续剩余步骤。';
  }
}

class Fixture {
  Fixture(this.database, this.store, this.records, this.results);
  final db.AppDatabase database;
  final AgentTaskStore store;
  final TaskProcessRecord records;
  final ToolResultStore results;
  final receipts = <RecordedReceipt>[];
  static Future<Fixture> create() async {
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
    final directory = await Directory.systemTemp.createTemp(
      'agent-reliability-',
    );
    return Fixture(
      database,
      AgentTaskStore(database),
      TaskProcessRecord(directory),
      ToolResultStore(() async => Directory('${directory.path}/results')),
    );
  }

  TaskAgentRunner runner(
    ScriptClient client, {
    int contextWindow = 128000,
    Summary? summary,
  }) {
    final api = KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => client,
    );
    return TaskAgentRunner(
      resultStore: results,
      summarizerFactory: summary == null ? null : () async => summary,
      loadSettings: () async => mapUiModelsToAppSettings(
        {},
      ).copyWith(contextWindowTokens: contextWindow),
      requestConfig: probe.resolve,
      executor:
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) => api.executeApiCall(
            config: config,
            sessionId: sessionId,
            userText: null,
            responseProcessors: const [],
            availableTools: tools,
            cancellation: cancellation,
          ),
    );
  }

  TaskAgentService service(
    TaskAgentRunner runner,
    List<AITool> tools, {
    int maxConcurrent = 3,
  }) => TaskAgentService(
    store: store,
    process: records,
    runner: runner,
    capabilities: (_, _, _) async => TaskAgentCapabilities(tools: tools),
    writeReceipt: (receipt) async => receipts.add(receipt),
    relay: (_, _) async => true,
    findReceipt: (_) async => null,
    ownsConversation: (_) async => true,
    deviceId: () async => 'test',
    newId: () => 't',
    preset: const TaskAgentPreset(),
    maxConcurrent: maxConcurrent,
  );
}

AITool stepTool(Future<String?> Function(Map<String, dynamic>) handler) =>
    AITool(
      name: 'step',
      description: 'step',
      parameters: const {},
      handler: handler,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no round cap: a long multi-step task finishes in one run', () async {
    final fixture = await Fixture.create();
    final client = ScriptClient((n, _) async => n <= 32 ? callStep() : done);
    var executions = 0;
    final service = fixture.service(fixture.runner(client), [
      stepTool((_) async => 'STEP_${++executions}'),
    ]);
    await service.start(conversationId: 'c', instruction: 'do thirty-two steps');
    await service.idle();
    expect((await fixture.store.get('t'))!.status, AgentTaskStatus.done);
    expect(executions, 32);
    expect(client.requests, hasLength(33));
    expect(fixture.receipts.last.block.summary, '完成');
  });

  test(
    'resuming a long checkpoint compresses old steps rather than a single protected transcript',
    () async {
      final fixture = await Fixture.create();
      final summary = Summary();
      final client = ScriptClient(
        (n, _) async => switch (n) {
          1 => callStep(),
          2 => askUser,
          _ => done,
        },
      );
      final service = fixture.service(
        fixture.runner(client, contextWindow: 3500, summary: summary),
        [stepTool((_) async => '资料' * 15000)],
      );
      await service.start(
        conversationId: 'c',
        instruction: 'complete long work',
      );
      await service.idle();
      final checkpoint = (await fixture.records.checkpoint('t'))!;
      final task = (await fixture.store.get('t'))!;
      expect(checkpoint.messages!.last['role'],'tool');
      expect(checkpoint.messages!.last['tool_call_id'],'ask');
      expect(jsonEncode(checkpoint.messages), contains('reference='));
      await service.reply(
        taskId: 't',
        controlId: 'reply',
        answersReceiptId: task.questionReceiptId,
        answer: '继续，保留出处',
      );
      await service.idle();
      expect((await fixture.store.get('t'))!.status, AgentTaskStatus.done);
      expect(summary.calls, greaterThan(0));
      expect(jsonEncode(client.requests.last), contains('继续，保留出处'));
      // The fake summarizer omits references: the runtime must retain them itself.
      expect(jsonEncode(client.requests.last), contains('reference='));
    },
  );

  test(
    'tool mode receives a reference and reads the full tail through the shared tool',
    () async {
      final fixture = await Fixture.create();
      final client = ScriptClient((n, messages) async {
        if (n == 1) return callStep();
        if (n == 2) {
          final ref = RegExp(
            r'reference=([a-f0-9]+)',
          ).firstMatch(jsonEncode(messages))!.group(1)!;
          return SendMessageRichResult(
            text: '',
            toolResults: const [],
            toolCalls: [
              ToolCall(
                id: 'read',
                name: ToolResultStore.readToolName,
                arguments: {'reference': ref, 'offset': 21000, 'limit': 20},
              ),
            ],
          );
        }
        expect(jsonEncode(messages), contains('TAIL_EVIDENCE'));
        expect(jsonEncode(messages), contains('next_offset'));
        return done;
      });
      final tool = stepTool((_) async => '${'x' * 21000}TAIL_EVIDENCE');
      final api = KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      );
      final result = await api.executeApiCall(
        config: ApiConfig(
          settings: mapUiModelsToAppSettings({}),
          modelFullId: 'openai:test',
          providerApiBase: 'https://invalid.test',
          customConfig: const {},
          messages: const [
            {'role': 'user', 'content': 'read result'},
          ],
          toolResultStore: fixture.results,
          tools: [tool.toOpenAISchema()],
        ),
        sessionId: 'c',
        userText: null,
        responseProcessors: const [],
        availableTools: [tool],
      );
      expect(result.status, ApiRunStatus.completed);
      expect(result.rawToolResults.first.result, contains('reference='));
      expect(
        jsonDecode(result.rawToolResults.last.result)['text'],
        'TAIL_EVIDENCE',
      );
    },
  );

  for (final overflow in [false, true]) {
    test(
      'task reuses runtime compression and overflow recovery (overflow=$overflow)',
      () async {
        final fixture = await Fixture.create();
        final summary = Summary();
        final client = ScriptClient((n, _) async {
          if (n == 1) return callStep();
          if (overflow && n == 2) throw Exception('context_length_exceeded');
          return done;
        });
        var executions = 0;
        final service = fixture.service(
          fixture.runner(
            client,
            contextWindow: overflow ? 128000 : 3500,
            summary: summary,
          ),
          [
            stepTool((_) async {
              executions++;
              return overflow ? 'query result ${'x' * 1000}' : '资料' * 15000;
            }),
          ],
        );
        await service.start(
          conversationId: 'c',
          instruction: 'process long results',
        );
        await service.idle();
        expect((await fixture.store.get('t'))!.status, AgentTaskStatus.done);
        expect(summary.calls, greaterThan(0));
        expect(executions, 1);
        expect(jsonEncode(client.requests.last), contains('历史步骤摘要'));
      },
    );
  }

  test(
    'a restart after N settled steps retains N checkpoints without replaying uncertain effects',
    () async {
      final fixture = await Fixture.create();
      final atCrash = Completer<void>();
      final lostProcess = Completer<String?>();
      var executions = 0;
      final service = fixture.service(
        fixture.runner(ScriptClient((_, _) async => callStep(count: 4))),
        [
          stepTool((args) async {
            executions++;
            if (args['n'] == 4) {
              atCrash.complete();
              return lostProcess.future;
            }
            return 'COMPLETED_STEP_${args['n']}';
          }),
        ],
      );
      await service.start(conversationId: 'c', instruction: 'four steps');
      await atCrash.future;
      final checkpoint = (await fixture.records.checkpoint('t'))!;
      for (var n = 1; n <= 3; n++) {
        expect(checkpoint.lastLog, contains('COMPLETED_STEP_$n'));
      }
      expect(checkpoint.lastLog, isNot(contains('COMPLETED_STEP_4')));
      // A fresh service sees only durable data, as after process loss.
      final recovered = fixture.service(
        fixture.runner(ScriptClient((_, _) async => done)),
        [],
      );
      await recovered.recover();
      await recovered.idle();
      final task = (await fixture.store.get('t'))!;
      expect(task.status, AgentTaskStatus.interrupted);
      expect(task.sideEffectUncertain, true);
      expect(
        (await fixture.records.checkpoint('t'))!.lastLog,
        checkpoint.lastLog,
      );
      expect(await fixture.records.log('t'), contains('COMPLETED_STEP_3'));
      expect(executions, 4);
      lostProcess.completeError(const KernelCancelledException());
      await service.idle();
      expect(
        (await fixture.store.get('t'))!.status,
        AgentTaskStatus.interrupted,
      );
    },
  );

  test(
    'running steering reaches a pending final response rather than being dropped',
    () async {
      final fixture = await Fixture.create();
      final started = Completer<void>();
      final pending = Completer<SendMessageRichResult>();
      final client = ScriptClient((n, messages) async {
        if (n == 1) {
          started.complete();
          return pending.future;
        }
        expect(jsonEncode(messages), contains('只输出 CSV'));
        return done;
      });
      final service = fixture.service(fixture.runner(client), []);
      await service.start(conversationId: 'c', instruction: 'write report');
      await started.future;
      expect(
        await service.steer(taskId: 't', instruction: '只输出 CSV'),
        TaskControlOutcome.applied,
      );
      pending.complete(done);
      await service.idle();
      expect(client.requests, hasLength(2));
      expect(
        (await fixture.records.checkpoint('t'))!.transcript,
        contains('只输出 CSV'),
      );
    },
  );

  test(
    'queued and waiting steering is durable and enters the next execution',
    () async {
      final fixture = await Fixture.create();
      final client = ScriptClient(
        (n, _) async => n == 1
            ? const SendMessageRichResult(
                text: '需要确认',
                toolResults: [],
                toolCalls: [
                  ToolCall(
                    id: 'q',
                    name: TaskAgentRunner.askToolName,
                    arguments: {'question': '哪种格式？'},
                  ),
                ],
              )
            : done,
      );
      final queued = fixture.service(
        fixture.runner(client),
        [],
        maxConcurrent: 0,
      );
      await queued.start(conversationId: 'c', instruction: 'write report');
      await queued.steer(taskId: 't', instruction: '保留出处');
      final service = fixture.service(fixture.runner(client), []);
      await service.pump();
      await service.idle();
      expect(jsonEncode(client.requests.first), contains('保留出处'));
      await service.steer(taskId: 't', instruction: '只输出 CSV');
      final task = (await fixture.store.get('t'))!;
      await service.reply(
        taskId: 't',
        controlId: 'reply',
        answersReceiptId: task.questionReceiptId,
        answer: '继续',
      );
      await service.idle();
      expect(jsonEncode(client.requests.last), contains('只输出 CSV'));
    },
  );

  test(
    'optional controlled tool receives cancellation and reports partial progress',
    () async {
      final cancellation = KernelCancellation();
      final started = Completer<void>();
      final progress = <String>[];
      final tool = AITool(
        name: 'step',
        description: 'step',
        parameters: const {},
        handler: (_) async => throw StateError('legacy fallback must not run'),
        controlledHandler: (_, control) async {
          expect(control.cancellation, isNotNull);
          expect(control.cancellation!.isCancelled, false);
          control.progress('partial 1');
          started.complete();
          await control.cancellation!.whenCancelled;
          control.cancellation!.throwIfCancelled();
          return const ToolOutput(text: 'late');
        },
      );
      final client = ScriptClient((n, _) async => n == 1 ? callStep() : done);
      final api = KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      );
      final future = api.executeApiCall(
        config: ApiConfig(
          settings: mapUiModelsToAppSettings({}),
          modelFullId: 'openai:test',
          providerApiBase: 'https://invalid.test',
          customConfig: const {},
          messages: const [],
          onToolProgress: (name, text) => progress.add('$name:$text'),
        ),
        sessionId: 'progress',
        userText: null,
        responseProcessors: const [],
        availableTools: [tool],
        cancellation: cancellation,
      );
      final check = expectLater(
        future,
        throwsA(isA<KernelCancelledException>()),
      );
      await started.future;
      cancellation.cancel();
      await check;
      expect(progress, ['step:partial 1']);
    },
  );

  test(
    'temporary model failure retries the current round without replaying tools',
    () async {
      var executions = 0;
      final client = ScriptClient((n, messages) async {
        if (n == 1) return callStep();
        if (n == 2) throw const ModelHttpException(503, 'busy');
        expect(jsonEncode(messages), contains('already executed'));
        return done;
      });
      final api = KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      );
      final result = await api.executeApiCall(
        config: probe.config(),
        sessionId: 'retry',
        userText: null,
        responseProcessors: const [],
        availableTools: [
          stepTool((_) async {
            executions++;
            return 'already executed';
          }),
        ],
      );
      expect(result.status, ApiRunStatus.completed);
      expect(client.requests, hasLength(3));
      expect(executions, 1);
    },
  );

  test(
    'retry backoff is bounded, honors Retry-After and cancellation interrupts waiting',
    () async {
      var attempts = 0;
      final delays = <Duration>[];
      await expectLater(
        retryModelRound<void>(
          send: () async {
            attempts++;
            throw const ModelHttpException(
              429,
              'rate limited',
              retryAfter: Duration(seconds: 3),
            );
          },
          cancellation: KernelCancellation(),
          wait: (d) async => delays.add(d),
        ),
        throwsA(isA<ModelHttpException>()),
      );
      expect(attempts, 4);
      expect(delays, [
        const Duration(seconds: 3),
        const Duration(seconds: 3),
        const Duration(seconds: 3),
      ]);
      expect(
        ModelHttpException.parseRetryAfter('2'),
        const Duration(seconds: 2),
      );
      expect(
        ModelHttpException.parseRetryAfter(
          'Thu, 22 Oct 2026 00:00:03 GMT',
          now: DateTime.utc(2026, 10, 22),
        ),
        const Duration(seconds: 3),
      );
      final cancellation = KernelCancellation();
      final waiting = Completer<void>();
      final sleep = Completer<void>();
      final future = retryModelRound<void>(
        send: () async => throw const SocketException('disconnected'),
        cancellation: cancellation,
        wait: (_) {
          waiting.complete();
          return sleep.future;
        },
      );
      final check = expectLater(
        future,
        throwsA(isA<KernelCancelledException>()),
      );
      await waiting.future;
      cancellation.cancel();
      await check;
      sleep.complete();
      attempts = 0;
      await expectLater(
        retryModelRound<void>(
          send: () async {
            attempts++;
            throw const ModelHttpException(400, 'bad request');
          },
          cancellation: KernelCancellation(),
        ),
        throwsA(isA<ModelHttpException>()),
      );
      expect(attempts, 1);
    },
  );

  test(
    'schema subset checks required, nested types, enum, ranges and extra properties',
    () {
      const schema = {
        'type': 'object',
        'properties': {
          'n': {'type': 'integer', 'minimum': 1},
          'mode': {
            'type': 'string',
            'enum': ['a', 'b'],
          },
          'items': {
            'type': 'array',
            'items': {'type': 'boolean'},
            'minItems': 1,
          },
        },
        'required': ['n'],
        'additionalProperties': false,
      };
      expect(
        validateToolArguments({
          'n': 2,
          'mode': 'a',
          'items': [true],
        }, schema),
        isEmpty,
      );
      expect(
        validateToolArguments({
          'mode': 'z',
          'items': ['wrong'],
          'extra': 1,
        }, schema),
        hasLength(4),
      );
      expect(validateToolArguments({'n': 0}, schema), hasLength(1));
    },
  );

  test(
    'a timed-out model attempt is aborted before the next attempt starts',
    () async {
      final signals = <KernelCancellation>[];
      await expectLater(
        retryModelRound<void>(
          cancellation: KernelCancellation(),
          maxRetries: 1,
          attemptTimeout: const Duration(milliseconds: 10),
          wait: (_) async {},
          send: () {
            if (signals.isNotEmpty) expect(signals.last.isCancelled, true);
            signals.add(RequestControl.cancellation!);
            return Completer<void>().future;
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(signals, hasLength(2));
      expect(signals.every((s) => s.isCancelled), true);
    },
  );

  test(
    'execution checks the original schema even if transport drops keywords',
    () async {
      var executions = 0;
      final tool = AITool(
        name: 'step',
        description: 'step',
        parameters: const {},
        inputSchema: const {'type': 'object'},
        validationSchema: const {
          'type': 'object',
          'properties': {},
          'additionalProperties': false,
        },
        handler: (_) async {
          executions++;
          return 'must not run';
        },
      );
      final client = ScriptClient((n, _) async => n == 1 ? callStep() : done);
      final api = KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      );
      final result = await api.executeApiCall(
        config: probe.config(),
        sessionId: 'original-schema',
        userText: null,
        responseProcessors: const [],
        availableTools: [tool],
      );
      expect(executions, 0);
      final error = jsonDecode(result.rawToolResults.single.result)['error'];
      expect(error['code'], 'invalid_tool_arguments');
      expect(error['details'].single['path'], r'$.n');
    },
  );

  test(
    'readback pages stay inline and preserve Unicode across page boundaries',
    () async {
      final fixture = await Fixture.create();
      final text = '${'😀"\n' * 3000}TAIL';
      final preview = await fixture.results.preserve('unicode', text);
      final ref = RegExp(
        r'reference=([a-f0-9]+)',
      ).firstMatch(preview)!.group(1)!;
      final rebuilt = StringBuffer();
      var offset = 0;
      do {
        final encoded = await fixture.results.read(
          'unicode',
          ref,
          offset: offset,
          limit: 8192,
        );
        expect(
          encoded.length,
          lessThanOrEqualTo(ToolResultStore.maxInlineChars),
        );
        final page = jsonDecode(encoded) as Map;
        rebuilt.write(page['text']);
        offset = page['next_offset'] as int;
      } while (offset < text.length);
      expect(rebuilt.toString(), text);
    },
  );
}
