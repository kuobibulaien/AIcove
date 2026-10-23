// Real-model acceptance for ADR0101 (opt-in): budget exhaustion waits and
// continues without redoing steps, long tool results are read back by
// reference, steering reaches a running task, cancel stops an in-flight
// stream, and a transient 503 is retried in the same round. DeepSeek Flash;
// skipped unless DEEPSEEK_API_KEY is set. The key is read from the
// environment only.
@Tags(['real_model'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation, KernelCancelledException, ToolEffect;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_process_record.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _apiKey = Platform.environment['DEEPSEEK_API_KEY'];
final _settings = mapUiModelsToAppSettings({});
final _runner = createApiRunner();

void _log(String text) {
  // ignore: avoid_print
  print(text);
}

class _Harness {
  _Harness(this.service, this.receipts, this.dir);
  final TaskAgentService service;
  final List<RecordedReceipt> receipts;
  final Directory dir;
}

Future<_Harness> _harness(
  List<AITool> tools, {
  String apiBase = 'https://api.deepseek.com',
}) async {
  final database = db.AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  await database
      .into(database.conversations)
      .insert(
        db.ConversationsCompanion.insert(
          id: 'c1',
          title: 't',
          displayName: 't',
          createdAt: 0,
          updatedAt: 0,
        ),
      );
  final dir = await Directory.systemTemp.createTemp('reliability_real');
  addTearDown(() => dir.delete(recursive: true));
  final receipts = <RecordedReceipt>[];
  final service = TaskAgentService(
    store: AgentTaskStore(database),
    process: TaskProcessRecord(dir),
    preset: const TaskAgentPreset(),
    runner: TaskAgentRunner(
      loadSettings: () async => _settings,
      resultStore: ToolResultStore(
        () async => Directory('${dir.path}/results'),
      ),
      requestConfig: ({required settings, required modelRef}) async =>
          BackgroundAgentRequestConfig(
            modelFullId: 'openai:deepseek-flash',
            providerApiBase: apiBase,
            providerApiKey: _apiKey,
            customConfig: const <String, dynamic>{},
            modelTemperature: 0,
            modelTopP: null,
            modelContextMessageLimit: null,
          ),
      executor:
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) => _runner.executeApiCall(
            config: config,
            sessionId: sessionId,
            userText: null,
            responseProcessors: const [],
            availableTools: tools,
            cancellation: cancellation,
          ),
    ),
    capabilities: (_, _, _) async => TaskAgentCapabilities(tools: tools),
    writeReceipt: (receipt) async => receipts.add(receipt),
    relay: (_, _) async => true,
    findReceipt: (_) async => null,
    ownsConversation: (_) async => true,
    deviceId: () async => 'mac',
  );
  return _Harness(service, receipts, dir);
}

AITool _stepTool(Map<int, int> calls, {Duration delay = Duration.zero}) =>
    AITool(
      name: 'step',
      description: '执行编号为 n 的步骤，返回该步骤的口令。每个步骤只能执行一次。',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'n': {'type': 'integer'},
        },
        'required': ['n'],
      },
      effect: ToolEffect.external,
      handler: (args) async {
        final n = (args['n'] as num).toInt();
        calls[n] = (calls[n] ?? 0) + 1;
        await Future<void>.delayed(delay);
        return jsonEncode({'step': n, 'token': 'K${n * 7}'});
      },
    );

void main() {
  final skip = _apiKey == null ? '未设置 DEEPSEEK_API_KEY' : false;

  test(
    '没有轮数上限：五步任务一次做完、每步只做一次',
    () async {
      final calls = <int, int>{};
      final h = await _harness([_stepTool(calls)]);
      final task = await h.service.start(
        conversationId: 'c1',
        instruction:
            '按顺序调用 step 工具执行步骤 1、2、3、4、5，每轮只调用一次，'
            '一次只执行一个步骤，全部完成后汇报 5 个口令。',
      );
      await h.service.idle();
      final current = (await h.service.store.get(task.id))!;
      _log('状态：${current.status} 调用=$calls');
      _log('回执：${h.receipts.last.block.content}');
      expect(current.status, AgentTaskStatus.done);
      expect(calls.keys.toSet(), {1, 2, 3, 4, 5});
      expect(calls.values.every((c) => c == 1), isTrue, reason: '步骤被重做：$calls');
      expect(h.receipts.last.block.summary, contains('K35'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    '超长工具结果按引用回读尾部',
    () async {
      final filler = List.filled(1200, '本段为季度报告正文的普通内容，不含暗号。').join();
      final report = AITool(
        name: 'fetch_report',
        description: '取回完整季度报告全文。',
        parameters: const {},
        inputSchema: const {'type': 'object', 'properties': {}},
        effect: ToolEffect.external,
        handler: (_) async => '$filler\n报告末尾附注：本季度暗号是 青柠-7421。',
      );
      final h = await _harness([report]);
      final task = await h.service.start(
        conversationId: 'c1',
        instruction: '调用 fetch_report 取回报告，找出报告末尾附注里的暗号并告诉我。',
      );
      await h.service.idle();
      final current = (await h.service.store.get(task.id))!;
      final log = await TaskProcessRecord(h.dir).log(task.id) ?? '';
      _log('状态：${current.status}\n回执：${h.receipts.last.block.content}');
      _log('用到回读：${log.contains('read_tool_result')}');
      expect(filler.length, greaterThan(20000));
      expect(current.status, AgentTaskStatus.done);
      expect(log, contains('read_tool_result'));
      expect(h.receipts.last.block.summary, contains('7421'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '运行中追加要求被接收',
    () async {
      final calls = <int, int>{};
      final h = await _harness([
        _stepTool(calls, delay: const Duration(seconds: 3)),
      ]);
      final task = await h.service.start(
        conversationId: 'c1',
        instruction: '按顺序调用 step 执行步骤 1、2、3，一次只执行一个，完成后汇报口令。',
      );
      while (calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final outcome = await h.service.steer(
        taskId: task.id,
        instruction: '追加：步骤 3 之后再执行步骤 99，并在汇报里包含它的口令。',
      );
      _log('steer：$outcome');
      await h.service.idle();
      final current = (await h.service.store.get(task.id))!;
      _log(
        '状态：${current.status} 调用=$calls\n回执：${h.receipts.last.block.content}',
      );
      expect(outcome, TaskControlOutcome.applied);
      expect(current.status, AgentTaskStatus.done);
      expect(calls.keys, contains(99));
      expect(h.receipts.last.block.summary, contains('K693'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '取消立即结束在途流式请求',
    () async {
      final cancellation = KernelCancellation();
      var deltas = 0;
      final started = Completer<void>();
      final call = _runner.executeApiCall(
        config: ApiConfig(
          settings: _settings,
          modelFullId: 'openai:deepseek-flash',
          providerApiBase: 'https://api.deepseek.com',
          providerApiKey: _apiKey,
          customConfig: const {},
          messages: const [
            {'role': 'user', 'content': '写一篇三千字的散文，主题是海边的小镇。'},
          ],
        ),
        sessionId: 's1',
        userText: null,
        responseProcessors: const [],
        enableStreaming: true,
        onStreamTextDelta: (_) {
          deltas++;
          if (!started.isCompleted) started.complete();
        },
        cancellation: cancellation,
      );
      await started.future.timeout(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(seconds: 1));
      final before = deltas;
      final watch = Stopwatch()..start();
      cancellation.cancel();
      Object? error;
      try {
        await call;
      } catch (e) {
        error = e;
      }
      watch.stop();
      await Future<void>.delayed(const Duration(seconds: 2));
      _log(
        '取消耗时 ${watch.elapsedMilliseconds}ms，取消前 $before 段，之后 ${deltas - before} 段，错误 ${error.runtimeType}',
      );
      expect(error, isA<KernelCancelledException>());
      expect(watch.elapsedMilliseconds, lessThan(1000));
      expect(deltas - before, lessThan(3));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '暂时性 503 在当前轮重试',
    () async {
      final upstream = HttpClient()..autoUncompress = false;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        upstream.close(force: true);
      });
      var hits = 0;
      server.listen((request) async {
        hits++;
        final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        if (hits == 1) {
          request.response
            ..statusCode = 503
            ..headers.set('retry-after', '1')
            ..write('busy');
          await request.response.close();
          return;
        }
        final out = await upstream.openUrl(
          request.method,
          Uri.parse('https://api.deepseek.com${request.uri}'),
        );
        request.headers.forEach((name, values) {
          if (name == 'host' || name == 'content-length') return;
          for (final v in values) {
            out.headers.add(name, v);
          }
        });
        out.add(body);
        final res = await out.close();
        request.response.statusCode = res.statusCode;
        res.headers.forEach((name, values) {
          if (name == 'content-length' || name == 'transfer-encoding') return;
          for (final v in values) {
            request.response.headers.add(name, v);
          }
        });
        await request.response.addStream(res);
        await request.response.close();
      });
      final watch = Stopwatch()..start();
      final result = await _runner.executeApiCall(
        config: ApiConfig(
          settings: _settings,
          modelFullId: 'openai:deepseek-flash',
          providerApiBase: 'http://127.0.0.1:${server.port}',
          providerApiKey: _apiKey,
          customConfig: const {},
          messages: const [
            {'role': 'user', 'content': '只回答两个字：收到'},
          ],
        ),
        sessionId: 's2',
        userText: null,
        responseProcessors: const [],
      );
      _log(
        '请求次数 $hits，耗时 ${watch.elapsedMilliseconds}ms，回复：${result.replyText}',
      );
      expect(hits, 2);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(1000));
      expect(result.status, ApiRunStatus.completed);
      expect(result.replyText, contains('收到'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
