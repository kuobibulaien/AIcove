import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_toolset.dart';
import 'package:aicove_flutter/src/features/task_agent/application/delegate_task_plugin.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_process_record.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _material = '完整参考素材：第一幕雨夜相遇，第二幕在旧车站告别。';
const _summary = '参考素材已整理好。';

class _MemoryProcess extends TaskProcessRecord {
  _MemoryProcess() : super(Directory('test/features/task_agent'));

  final checkpoints = <String, TaskCheckpoint>{};

  @override
  Future<TaskCheckpoint?> checkpoint(String taskId) async =>
      checkpoints[taskId];

  @override
  Future<void> saveCheckpoint(String taskId, TaskCheckpoint checkpoint) async {
    checkpoints[taskId] = checkpoint;
  }

  @override
  Future<void> appendLog(String taskId, String heading, String text) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.AppDatabase database;
  late AgentTaskStore store;
  late TaskAgentService service;
  late Completer<void> execute;
  late List<RecordedReceipt> written;
  late List<String> relayed;
  late int executorCalls;
  late _MemoryProcess process;
  TaskAgentExecutor? customExecutor;
  TaskAgentCapabilities runCapabilities = const TaskAgentCapabilities();
  final resolvedReadOnly = <bool>[];
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  var nextId = 0;
  final settings = mapUiModelsToAppSettings({});

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    store = AgentTaskStore(database);
    execute = Completer<void>();
    written = [];
    relayed = [];
    executorCalls = 0;
    writeGate = null;
    writeStarted = null;
    nextId = 0;
    process = _MemoryProcess();
    customExecutor = null;
    runCapabilities = const TaskAgentCapabilities();
    resolvedReadOnly.clear();
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
    final runner = TaskAgentRunner(
      loadSettings: () async => settings,
      requestConfig: ({required settings, required modelRef}) async =>
          const BackgroundAgentRequestConfig(
            modelFullId: 'openai:offline-test',
            providerApiBase: 'https://invalid.test',
            providerApiKey: null,
            customConfig: {},
            modelTemperature: null,
            modelTopP: null,
            modelContextMessageLimit: null,
          ),
      executor:
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) async {
            executorCalls++;
            if (customExecutor != null) {
              return customExecutor!(
                config: config,
                tools: tools,
                sessionId: sessionId,
                cancellation: cancellation,
              );
            }
            await execute.future;
            final materialTool = tools.singleWhere(
              (tool) => tool.name == TaskAgentRunner.materialToolName,
            );
            await materialTool.invoke({'content': _material});
            return const ApiCallResult(
              replyText: _summary,
              processedText: _summary,
              pluginEvents: [],
              toolResults: [],
            );
          },
    );
    service = TaskAgentService(
      store: store,
      process: process,
      runner: runner,
      capabilities: (_, _, _, {bool readOnly = false}) async {
        resolvedReadOnly.add(readOnly);
        return runCapabilities;
      },
      writeReceipt: (receipt) async {
        if (!(writeStarted?.isCompleted ?? true)) writeStarted!.complete();
        await writeGate?.future;
        final message = Message(
          id: receipt.messageId,
          role: 'user',
          content: receipt.block.content,
          blocks: [receipt.block],
          createdAt: DateTime.now(),
        );
        await database.transaction(() async {
          await database
              .into(database.messages)
              .insertOnConflictUpdate(
                MessageConverter.toCompanion(
                  message,
                  receipt.task.conversationId,
                ),
              );
          await database
              .into(database.messageBlocks)
              .insertOnConflictUpdate(
                MessageBlockConverter.toCompanion(receipt.block, message.id, 0),
              );
        });
        written.add(receipt);
      },
      relay: (_, receipt) async {
        relayed.add(receipt.receiptId);
        return true;
      },
      findReceipt: (id) async => written
          .where((receipt) => receipt.block.receiptId == id)
          .firstOrNull
          ?.block,
      ownsConversation: (_) async => true,
      deviceId: () async => 'offline-test',
      inlineWait: const Duration(seconds: 3),
      newId: () => 'task-${++nextId}',
    );
  });

  tearDown(() async {
    if (!execute.isCompleted) execute.complete();
    await service.idle();
    await database.close();
  });

  test(
    'material tool detail survives runner, store, and receipt projection',
    () async {
      final task = await service.start(
        conversationId: 'c',
        instruction: '整理素材',
      );
      execute.complete();
      await service.idle();
      expect(executorCalls, 1);
      expect(written, hasLength(1));
      expect(relayed, [written.single.block.receiptId]);

      final saved = await store.latestReceipt(task.id);
      expect(saved, isNotNull);
      expect(saved!.detail, _material);
      expect(saved.summary, _summary);
      final restored = TaskReceiptBlock.fromJson(saved.toJson());
      expect(restored.detail, _material);
      final receiptMessage = Message(
        id: restored.messageId,
        role: 'user',
        content: restored.content,
        blocks: [restored],
        createdAt: DateTime.now(),
      );
      final builder = ChatRequestMessageBuilder(
        readImageAsBase64: (_) async => null,
      );
      final recent = await builder.buildRequestMessages([
        receiptMessage,
      ], settings: settings);
      expect(recent.toString(), contains(_material));
      final historical = await builder.buildRequestMessages([
        receiptMessage,
        Message.text(id: 'reply', role: 'assistant', content: '已根据素材完成创作。'),
      ], settings: settings);
      expect(historical.toString(), isNot(contains(_material)));
      expect(historical.toString(), contains(_summary));
    },
  );

  for (final state in ['failed', 'cancelled', 'inProgress', 'sending']) {
    test('unfinished assistant $state preserves unconsumed material', () async {
      final receipt = TaskReceiptBlock(
        messageId: 'receipt',
        receiptId: 'receipt-id',
        taskId: 'task',
        receiptStatus: TaskReceiptStatus.done,
        summary: _summary,
        detail: _material,
        executorDevice: 'offline-test',
      );
      final unfinished = Message(
        id: 'unfinished',
        role: 'assistant',
        content: '正在处理',
        status: state == 'sending' ? 'sending' : 'sent',
        rawPayload: {
          if (state == 'failed' || state == 'cancelled') 'runStatus': state,
          if (state == 'inProgress') 'stopReason': 'inProgress',
        },
        blocks: [
          ToolBlock(
            messageId: 'unfinished',
            toolName: 'delegate_task',
            toolCallId: 'call',
            result: {
              'receipt_id': 'receipt-id',
              'summary': _summary,
              'detail': _material,
            },
          ),
        ],
        createdAt: DateTime.now(),
      );
      final history = [
        Message(
          id: 'receipt',
          role: 'user',
          content: receipt.content,
          blocks: [receipt],
          createdAt: DateTime.now(),
        ),
        unfinished,
      ];
      final builder = ChatRequestMessageBuilder(
        readImageAsBase64: (_) async => null,
      );
      final pending = await builder.buildRequestMessages(
        history,
        settings: settings,
      );
      expect(pending.first['content'], contains(_material));
      expect(
        pending.where((m) => m['role'] == 'tool').single['content'],
        contains(_material),
      );
      final consumed = await builder.buildRequestMessages([
        ...history,
        Message.text(id: 'done', role: 'assistant', content: '完成创作。'),
      ], settings: settings);
      expect(consumed.toString(), isNot(contains(_material)));
    });
  }

  for (final foregroundSucceeded in [true, false]) {
    test(
      'fast inline receipt settles $foregroundSucceeded without relay race',
      () async {
        final task = await service.start(
          conversationId: 'c',
          instruction: '整理素材',
        );
        final waiting = service.waitForReceipt(task.id);
        execute.complete();
        final receipt = await waiting;
        await service.idle();
        expect(receipt?.detail, _material);
        // No conversation-busy guard: the waiter alone must defer relay.
        expect(relayed, isEmpty);
        expect(written, hasLength(1));
        await service.settleInlineDeliveries(
          'c',
          isRelayed: (id) async {
            expect(id, receipt!.receiptId);
            return foregroundSucceeded;
          },
        );
        expect(relayed, isEmpty);
        await service.flushConversation('c');
        await service.deliverPending();
        expect(relayed, foregroundSucceeded ? isEmpty : [receipt!.receiptId]);
        expect(await store.pendingDeliveries(), isEmpty);
      },
    );
  }

  test(
    'failed foreground waits for delayed receipt write before fallback',
    () async {
      writeGate = Completer<void>();
      writeStarted = Completer<void>();
      final task = await service.start(
        conversationId: 'c',
        instruction: '整理素材',
      );
      final waiting = service.waitForReceipt(task.id);
      execute.complete();
      final receipt = await waiting;
      expect(receipt, isNotNull);
      await writeStarted!.future;
      await service.settleInlineDeliveries('c', isRelayed: (_) async => false);
      expect(written, isEmpty);
      expect(relayed, isEmpty);
      expect(await store.pendingDeliveries(), [receipt!.receiptId]);
      writeGate!.complete();
      await service.idle();
      await service.flushConversation('c');
      expect(written, hasLength(1));
      expect(relayed, [receipt.receiptId]);
      expect(await store.pendingDeliveries(), isEmpty);
    },
  );

  test('expired waiter leaves completion to asynchronous relay', () async {
    final task = await service.start(conversationId: 'c', instruction: '整理素材');
    expect(
      await service.waitForReceipt(
        task.id,
        timeout: const Duration(milliseconds: 1),
      ),
      isNull,
    );
    execute.complete();
    await service.idle();
    expect(relayed, [written.single.block.receiptId]);
  });

  test(
    'read-only task filters writes and keeps role list/read capability',
    () async {
      final toolset = AssistantToolset(
        roles: () async => [],
        presets: () async => [],
        previewContext: (_) async => throw UnimplementedError(),
        readDoc: (_) async => null,
      );
      runCapabilities = TaskAgentCapabilities(
        tools: [
          toolset.roleTool(),
          AITool(
            name: 'write_data',
            description: '',
            parameters: const {},
            effect: ToolEffect.write,
            handler: (_) async => throw StateError('write must not run'),
          ),
        ],
      );
      customExecutor =
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) async {
            expect(
              tools.map((tool) => tool.name),
              isNot(contains('write_data')),
            );
            expect(
              config.messages.first['content'],
              contains('当前任务为只读模式（read_only=true），只可查询和读取，严禁尝试写入或修改状态。'),
            );
            final role = tools.singleWhere(
              (tool) => tool.name == 'aicove_role',
            );
            expect(role.effect, ToolEffect.readPrivate);
            expect(
              (role.parameterSchema['properties'] as Map)['action']['enum'],
              ['list', 'read'],
            );
            expect(
              jsonDecode((await role.invoke({'action': 'list'})).text),
              contains('roles'),
            );
            expect(
              (await role.invoke({'action': 'create', 'name': 'bad'})).text,
              contains('只读'),
            );
            return const ApiCallResult(
              replyText: '已读取',
              processedText: '已读取',
              pluginEvents: [],
              toolResults: [],
            );
          };
      final task = await service.start(
        conversationId: 'c',
        instruction: '只取材',
        readOnly: true,
      );
      await service.idle();
      expect(resolvedReadOnly, [true]);
      expect(process.checkpoints[task.id]!.readOnly, isTrue);
    },
  );

  test(
    'delegate reply steers a running task without creating another task',
    () async {
      final ready = Completer<void>();
      final steered = <String>[];
      customExecutor =
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) async {
            config.onRunReady!((text) {
              steered.add(text);
              return true;
            });
            ready.complete();
            await execute.future;
            return const ApiCallResult(
              replyText: '完成',
              processedText: '完成',
              pluginEvents: [],
              toolResults: [],
            );
          };
      final container = ProviderContainer(
        overrides: [
          taskAgentServiceProvider.overrideWith((_) async => service),
        ],
      );
      addTearDown(container.dispose);
      final task = await service.start(
        conversationId: 'c',
        instruction: '原始任务',
      );
      await ready.future;
      final tool = delegateTaskTool(container.read(delegateTaskPortProvider));
      const context = ToolCallContext(
        sessionId: 'c',
        turnId: 'turn',
        round: 1,
        toolCallId: 'reply',
      );
      final result = await context.run(
        () => tool.invoke({
          'action': 'reply',
          'task_id': task.id,
          'answer': '改用短版本',
        }),
      );
      expect(jsonDecode(result.text)['status'], 'steering_accepted');
      expect(steered, ['改用短版本']);
      expect((await store.recent()), hasLength(1));
      expect(
        process.checkpoints[task.id]!.contextMessages.last['content'],
        '改用短版本',
      );
      execute.complete();
      await service.idle();
      final ended = await context.run(
        () => tool.invoke({
          'action': 'reply',
          'task_id': task.id,
          'answer': '再次修改',
        }),
      );
      expect(jsonDecode(ended.text)['error'], '这个任务已经结束');
    },
  );

  test(
    'steer wakes a waiting task and preserves its read-only checkpoint',
    () async {
      final seen = <ApiConfig>[];
      customExecutor =
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) async {
            seen.add(config);
            if (seen.length == 1) {
              await tools
                  .singleWhere(
                    (tool) => tool.name == TaskAgentRunner.askToolName,
                  )
                  .invoke({'question': '需要哪一段？'});
            }
            return const ApiCallResult(
              replyText: '已记录',
              processedText: '已记录',
              pluginEvents: [],
              toolResults: [],
            );
          };
      final task = await service.start(
        conversationId: 'c',
        instruction: '取材',
        readOnly: true,
      );
      await service.idle();
      expect((await store.get(task.id))!.status, AgentTaskStatus.needsInput);
      final firstLog = process.checkpoints[task.id]!.lastLog;
      expect(
        await service.steer(taskId: task.id, instruction: '第一段'),
        TaskControlOutcome.applied,
      );
      await service.idle();
      expect(seen, hasLength(2));
      expect(resolvedReadOnly, [true, true]);
      expect((await store.get(task.id))!.status, AgentTaskStatus.done);
      expect(seen.last.messages.last['content'], '第一段');
      expect(process.checkpoints[task.id]!.transcript, contains(firstLog));
      expect(process.checkpoints[task.id]!.readOnly, isTrue);
    },
  );

  test('delegate reply resumes a waiting task with its answer', () async {
    final seen = <ApiConfig>[];
    customExecutor =
        ({
          required config,
          required tools,
          required sessionId,
          required cancellation,
        }) async {
          seen.add(config);
          if (seen.length == 1) {
            await tools
                .singleWhere((tool) => tool.name == TaskAgentRunner.askToolName)
                .invoke({'question': '需要哪一段？'});
          }
          return const ApiCallResult(
            replyText: '已记录',
            processedText: '已记录',
            pluginEvents: [],
            toolResults: [],
          );
        };
    final container = ProviderContainer(
      overrides: [taskAgentServiceProvider.overrideWith((_) async => service)],
    );
    addTearDown(container.dispose);
    final task = await service.start(
      conversationId: 'c',
      instruction: '取材',
      readOnly: true,
    );
    await service.idle();
    expect((await store.get(task.id))!.status, AgentTaskStatus.needsInput);
    final tool = delegateTaskTool(container.read(delegateTaskPortProvider));
    const context = ToolCallContext(
      sessionId: 'c',
      turnId: 'turn',
      round: 1,
      toolCallId: 'waiting-reply',
    );
    final result = await context.run(
      () =>
          tool.invoke({'action': 'reply', 'task_id': task.id, 'answer': '第二段'}),
    );
    expect(jsonDecode(result.text)['status'], 'resumed');
    await service.idle();
    expect(seen, hasLength(2));
    expect(seen.last.messages.last['content'], '第二段');
    expect(resolvedReadOnly, [true, true]);
    expect((await store.get(task.id))!.status, AgentTaskStatus.done);
    expect(process.checkpoints[task.id]!.readOnly, isTrue);
  });

  test('active query returns only the newest five unfinished tasks', () async {
    for (var index = 0; index < 7; index++) {
      await store.create(
        id: 'active$index',
        requestKey: null,
        conversationId: 'c',
        instruction: '$index',
      );
      await database.customStatement(
        'UPDATE agent_tasks SET created_at=? WHERE id=?',
        [index, 'active$index'],
      );
    }
    await store.finish(
      'active6',
      from: {AgentTaskStatus.queued},
      to: AgentTaskStatus.done,
      executorDevice: 'test',
    );
    expect((await store.activeByConversation('c')).map((task) => task.id), [
      'active5',
      'active4',
      'active3',
      'active2',
      'active1',
    ]);
  });

  test(
    'checkpoint read-only flag persists and legacy files remain writable',
    () async {
      final directory = await Directory(
        'test/features/task_agent',
      ).createTemp('.checkpoint_');
      addTearDown(() => directory.delete(recursive: true));
      final records = TaskProcessRecord(directory);
      await records.saveCheckpoint(
        'new',
        const TaskCheckpoint(transcript: '只读', readOnly: true),
      );
      expect((await records.checkpoint('new'))!.readOnly, isTrue);
      expect(
        jsonDecode(
          await File('${directory.path}/new.json').readAsString(),
        )['read_only'],
        isTrue,
      );
      await File(
        '${directory.path}/old.json',
      ).writeAsString(jsonEncode({'transcript': '旧任务'}));
      expect((await records.checkpoint('old'))!.readOnly, isFalse);
    },
  );
}
