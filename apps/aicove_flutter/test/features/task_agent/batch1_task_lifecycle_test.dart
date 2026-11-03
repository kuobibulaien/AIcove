import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_process_record.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _Process extends TaskProcessRecord {
  _Process() : super(Directory('test/features/task_agent'));
  TaskCheckpoint? saved;
  Completer<void>? finishing;
  Completer<void>? release;

  @override
  Future<TaskCheckpoint?> checkpoint(String taskId) async => saved;

  @override
  Future<void> saveCheckpoint(String taskId, TaskCheckpoint checkpoint) async {
    saved = checkpoint;
    if (checkpoint.lastLog == 'finished' && finishing != null) {
      finishing!.complete();
      await release!.future;
    }
  }

  @override
  Future<void> appendLog(String taskId, String heading, String text) async {}
}

class _Runner extends TaskAgentRunner {
  _Runner()
    : super(
        loadSettings: () => throw UnimplementedError(),
        executor:
            ({
              required config,
              required tools,
              required sessionId,
              required cancellation,
            }) => throw UnimplementedError(),
      );

  KernelCancellation? token;

  @override
  Future<TaskRunOutcome> run({
    required String taskId,
    required String runId,
    required String transcript,
    required TaskAgentCapabilities capabilities,
    required TaskAgentPreset preset,
    required KernelCancellation cancellation,
    AgentToolPolicy? toolPolicy,
    List<Map<String, dynamic>>? contextMessages,
    void Function()? onExternalStart,
    Future<void> Function()? onBeforeExternal,
    void Function(bool Function(String))? onRunReady,
    Future<void> Function(ToolCall, ToolResult)? onToolStep,
    Future<void> Function(List<Map<String, dynamic>>)? onTranscript,
    void Function(String, String)? onToolProgress,
  }) async {
    token = cancellation;
    return const TaskRunOutcome(
      summary: 'done',
      question: null,
      artifacts: [],
      processLog: 'finished',
    );
  }
}

void main() {
  late db.AppDatabase database;
  late AgentTaskStore store;

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    store = AgentTaskStore(database);
    for (final id in ['c1', 'c2']) {
      await database
          .into(database.conversations)
          .insert(
            db.ConversationsCompanion.insert(
              id: id,
              title: id,
              displayName: id,
              createdAt: 0,
              updatedAt: 0,
            ),
          );
    }
  });
  tearDown(() => database.close());

  Future<void> task(String id, {String conversation = 'c1'}) async {
    await store.create(
      id: id,
      requestKey: null,
      conversationId: conversation,
      instruction: 'work',
    );
  }

  Future<String> deliveryState(String id) async =>
      (await database
              .customSelect(
                "SELECT state FROM agent_task_deliveries WHERE receipt_id='$id'",
              )
              .getSingle())
          .read<String>('state');

  test(
    'missing delivery settles for deleted receipt or inactive conversation',
    () async {
      await task('t');
      for (final id in ['deleted', 'missing', 'active']) {
        await store.addDelivery(
          receiptId: id,
          taskId: 't',
          conversationId: 'c1',
        );
      }
      await database.customStatement(
        'INSERT INTO messages (id, conversation_id, role, content, created_at, deleted_at) '
        "VALUES ('task_receipt_deleted','c1','user','',0,1)",
      );
      await store.finishMissingTaskDelivery('deleted');
      expect(await deliveryState('deleted'), 'done');
      await store.finishMissingTaskDelivery('missing');
      expect(
        await deliveryState('missing'),
        'pending',
        reason: 'not synced yet',
      );
      await database.customStatement(
        "UPDATE conversations SET deleted_at=1 WHERE id='c1'",
      );
      await store.finishMissingTaskDelivery('active');
      expect(await deliveryState('active'), 'done');
    },
  );

  test(
    'missing local task settles without requiring a conversation tombstone',
    () async {
      await store.addDelivery(
        receiptId: 'remote',
        taskId: 'absent',
        conversationId: 'c1',
      );
      await store.finishMissingTaskDelivery('remote');
      expect(await deliveryState('remote'), 'done');
    },
  );

  test(
    'abort cancels only nonterminal tasks and settles every delivery',
    () async {
      for (final id in ['queued', 'running', 'waiting', 'done']) {
        await task(id);
      }
      await task('other', conversation: 'c2');
      await store.markRunning('running');
      for (final id in ['waiting', 'done']) {
        await store.finish(
          id,
          from: {AgentTaskStatus.queued},
          to: id == 'waiting'
              ? AgentTaskStatus.needsInput
              : AgentTaskStatus.done,
          executorDevice: 'mac',
        );
      }
      await store.setSwitch(false);
      await store.claimDelivery('waiting_1');
      await store.abortForDeletedConversation('c1');
      for (final id in ['queued', 'running', 'waiting']) {
        final aborted = (await store.get(id))!;
        expect(aborted.status, AgentTaskStatus.cancelled);
        expect(aborted.pendingReceipt, isNull);
        expect(aborted.frozen, isFalse);
      }
      expect((await store.get('done'))!.status, AgentTaskStatus.done);
      expect((await store.get('other'))!.status, AgentTaskStatus.queued);
      expect(await deliveryState('waiting_1'), 'done');
      expect(await deliveryState('done_1'), 'done');
      await store.completeDelivery('waiting_1', delivered: false);
      expect(
        await deliveryState('waiting_1'),
        'done',
        reason: 'late relay must not resurrect',
      );
    },
  );

  TaskAgentService service(
    _Process process,
    _Runner runner,
    List<RecordedReceipt> written,
  ) => TaskAgentService(
    store: store,
    process: process,
    runner: runner,
    capabilities: (_, _, _) async => const TaskAgentCapabilities(),
    writeReceipt: (receipt) async {
      written.add(receipt);
    },
    relay: (_, _) async => true,
    findReceipt: (_) async => null,
    ownsConversation: (_) async => true,
    deviceId: () async => 'mac',
    newId: () => 'run',
  );

  test(
    'cancel during final checkpoint produces cancellation, not completion',
    () async {
      final process = _Process()
        ..finishing = Completer<void>()
        ..release = Completer<void>();
      final runner = _Runner();
      final written = <RecordedReceipt>[];
      final agent = service(process, runner, written);
      await agent.start(conversationId: 'c1', instruction: 'work');
      await process.finishing!.future;
      final cancel = agent.cancel(taskId: 'run', controlId: 'cancel');
      await runner.token!.whenCancelled;
      process.release!.complete();
      await cancel;
      await agent.idle();
      expect((await store.get('run'))!.status, AgentTaskStatus.cancelled);
      expect(written.single.task.status, AgentTaskStatus.cancelled);
    },
  );

  test(
    'conversation abort cancels token and prevents late completion receipt',
    () async {
      final process = _Process()
        ..finishing = Completer<void>()
        ..release = Completer<void>();
      final runner = _Runner();
      final written = <RecordedReceipt>[];
      final agent = service(process, runner, written);
      await agent.start(conversationId: 'c1', instruction: 'work');
      await process.finishing!.future;
      await agent.abortForDeletedConversation('c1');
      expect(runner.token!.isCancelled, isTrue);
      process.release!.complete();
      await agent.idle();
      expect((await store.get('run'))!.status, AgentTaskStatus.cancelled);
      expect(written, isEmpty);
      expect(await store.unwrittenReceipts(), isEmpty);
      expect(await store.pendingDeliveries(), isEmpty);
    },
  );

  test(
    'non-owner settles deleted receipts but waits for unsynced receipts',
    () async {
      await task('t');
      for (final id in ['deleted', 'unsynced']) {
        await store.addDelivery(
          receiptId: id,
          taskId: 't',
          conversationId: 'c1',
        );
      }
      await database.customStatement(
        'INSERT INTO messages (id, conversation_id, role, content, created_at, deleted_at) '
        "VALUES ('task_receipt_deleted','c1','user','',0,1)",
      );
      final agent = TaskAgentService(
        store: store,
        process: _Process(),
        runner: _Runner(),
        capabilities: (_, _, _) async => const TaskAgentCapabilities(),
        writeReceipt: (_) async {},
        relay: (_, _) async => throw StateError('not owner'),
        findReceipt: (_) async => null,
        ownsConversation: (_) async => false,
        deviceId: () async => 'mac',
      );
      await agent.deliver('deleted');
      await agent.deliver('unsynced');
      expect(await deliveryState('deleted'), 'done');
      expect(await deliveryState('unsynced'), 'pending');
    },
  );
}
