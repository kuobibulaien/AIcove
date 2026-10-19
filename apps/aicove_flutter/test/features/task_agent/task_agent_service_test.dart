import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation, KernelCancelledException;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_process_record.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_sync_scanner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_supervisor.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Script =
    Future<TaskRunOutcome> Function(
      String transcript,
      KernelCancellation cancellation,
      void Function()? onExternalStart,
    );

class _FakeRunner extends TaskAgentRunner {
  _FakeRunner()
    : super(
        loadSettings: () => throw UnimplementedError(),
        executor:
            ({
              required config,
              required tools,
              required sessionId,
              required maxRounds,
              required cancellation,
            }) => throw UnimplementedError(),
      );

  final List<String> transcripts = [];
  final List<_Script> scripts = [];

  @override
  Future<TaskRunOutcome> run({
    required String taskId,
    required String runId,
    required String transcript,
    required TaskAgentCapabilities capabilities,
    required TaskAgentPreset preset,
    required KernelCancellation cancellation,
    AgentToolPolicy? toolPolicy,
    void Function()? onExternalStart,
  }) {
    transcripts.add(transcript);
    return scripts.removeAt(0)(transcript, cancellation, onExternalStart);
  }
}

TaskRunOutcome _done(String summary, {String? question}) => TaskRunOutcome(
  summary: summary,
  question: question,
  artifacts: const [],
  processLog: '- 调用 web_search\n  结果：$summary',
);

TaskReceiptBlock? _find(List<RecordedReceipt> written, String receiptId) {
  for (final receipt in written) {
    if (receipt.block.receiptId == receiptId) return receipt.block;
  }
  return null;
}

void main() {
  late db.AppDatabase database;
  late AgentTaskStore store;
  late Directory dir;
  late _FakeRunner runner;
  late List<RecordedReceipt> written;
  late List<String> relayed;
  late bool owns;
  late bool writeFails;
  late TaskAgentService service;
  var ids = 0;

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    store = AgentTaskStore(database);
    dir = await Directory.systemTemp.createTemp('task_agent_service');
    runner = _FakeRunner();
    written = [];
    relayed = [];
    owns = true;
    writeFails = false;
    ids = 0;
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'c1',
            title: 'c1',
            displayName: 'c1',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
    service = TaskAgentService(
      store: store,
      process: TaskProcessRecord(dir),
      runner: runner,
      capabilities: (_, _, _) async => const TaskAgentCapabilities(),
      writeReceipt: (receipt) async {
        if (writeFails) throw StateError('disk full');
        written.add(receipt);
      },
      relay: (conversationId, receipt) async {
        relayed.add(receipt.receiptId);
        return true;
      },
      findReceipt: (id) async => _find(written, id),
      ownsConversation: (_) async => owns,
      deviceId: () async => 'mac',
      newId: () => 't${++ids}',
    );
  });

  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  test('a task runs, writes its receipt and relays it once', () async {
    runner.scripts.add((_, _, _) async => _done('上海今天晴'));
    final task = await service.start(
      conversationId: 'c1',
      instruction: '查上海天气',
      requestKey: 'k',
    );
    await service.idle();
    expect((await store.get(task.id))!.status, AgentTaskStatus.done);
    expect(written.single.block.summary, '上海今天晴');
    expect(written.single.messageId, 'task_receipt_t1_1');
    expect(relayed, ['t1_1']);
    expect(await store.unwrittenReceipts(), isEmpty);
    expect(await store.pendingDeliveries(), isEmpty);
    expect(await TaskProcessRecord(dir).log('t1'), contains('上海今天晴'));

    final again = await service.start(
      conversationId: 'c1',
      instruction: '查上海天气',
      requestKey: 'k',
    );
    await service.idle();
    expect(again.id, task.id, reason: '同一请求键不重复建任务');
    expect(runner.transcripts, hasLength(1));
  });

  test('a question waits; the reply continues with the earlier process',
      () async {
    runner.scripts
      ..add((_, _, _) async => _done('需要城市', question: '哪个城市？'))
      ..add((_, _, _) async => _done('杭州今天小雨'));
    await service.start(conversationId: 'c1', instruction: '查天气');
    await service.idle();
    expect((await store.get('t1'))!.status, AgentTaskStatus.needsInput);
    expect(written.single.block.question, '哪个城市？');

    expect(
      await service.reply(
        taskId: 't1',
        controlId: 'ctl',
        answersReceiptId: 't1_1',
        answer: '杭州',
      ),
      TaskControlOutcome.applied,
    );
    await service.idle();
    expect((await store.get('t1'))!.status, AgentTaskStatus.done);
    final second = runner.transcripts.last;
    expect(second, contains('## 任务\n查天气'));
    expect(second, contains('哪个城市？'));
    expect(second, contains('杭州'));
    expect(second, contains('结果：需要城市'));
    expect(
      await service.reply(
        taskId: 't1',
        controlId: 'ctl',
        answersReceiptId: 't1_1',
        answer: '杭州',
      ),
      TaskControlOutcome.ignored,
    );
    expect(
      await service.reply(
        taskId: 'elsewhere',
        controlId: 'ctl2',
        answersReceiptId: null,
        answer: 'x',
      ),
      TaskControlOutcome.remote,
    );
  });

  test('cancel stops a running task after an outside call began', () async {
    final started = Completer<void>();
    runner.scripts.add((_, cancellation, onExternalStart) async {
      onExternalStart?.call();
      started.complete();
      await cancellation.whenCancelled;
      throw const KernelCancelledException();
    });
    await service.start(conversationId: 'c1', instruction: '下单');
    await started.future;
    expect(service.running, {'t1'});
    expect(
      await service.cancel(taskId: 't1', controlId: 'x'),
      TaskControlOutcome.applied,
    );
    final task = (await store.get('t1'))!;
    expect(task.status, AgentTaskStatus.cancelled);
    expect(written.single.block.receiptStatus, TaskReceiptStatus.cancelled);
    expect(written.single.block.sideEffectUncertain, isTrue);
    expect(
      await service.cancel(taskId: 't1', controlId: 'x'),
      TaskControlOutcome.ignored,
    );
  });

  test('runner errors become a failed receipt', () async {
    runner.scripts.add((_, _, _) async => throw StateError('401 Unauthorized'));
    await service.start(conversationId: 'c1', instruction: '查');
    await service.idle();
    expect((await store.get('t1'))!.status, AgentTaskStatus.failed);
    expect(written.single.block.summary, contains('401'));
  });

  test('only the owner device relays; the receipt stays pending', () async {
    owns = false;
    runner.scripts.add((_, _, _) async => _done('好了'));
    await service.start(conversationId: 'c1', instruction: '查');
    await service.idle();
    expect(written, hasLength(1));
    expect(relayed, isEmpty);
    expect(await store.pendingDeliveries(), ['t1_1']);
  });

  test('recovery interrupts stale runs and writes unwritten receipts',
      () async {
    await store.create(
      id: 'old',
      requestKey: null,
      conversationId: 'c1',
      instruction: '旧任务',
    );
    await store.markRunning('old');
    writeFails = true;
    await service.recover();
    await service.idle();
    expect((await store.get('old'))!.status, AgentTaskStatus.interrupted);
    expect(written, isEmpty);
    expect(await store.unwrittenReceipts(), hasLength(1));

    writeFails = false;
    await service.recover();
    await service.idle();
    expect(written.single.block.receiptStatus, TaskReceiptStatus.interrupted);
    expect(await store.unwrittenReceipts(), isEmpty);
  });

  test('kill switch cancels runs, freezes the queue and holds relays',
      () async {
    final service1 = TaskAgentService(
      store: store,
      process: TaskProcessRecord(dir),
      runner: runner,
      capabilities: (_, _, _) async => const TaskAgentCapabilities(),
      writeReceipt: (receipt) async => written.add(receipt),
      relay: (_, receipt) async {
        relayed.add(receipt.receiptId);
        return true;
      },
      findReceipt: (id) async => _find(written, id),
      ownsConversation: (_) async => true,
      deviceId: () async => 'mac',
      maxConcurrent: 1,
      newId: () => 's${++ids}',
    );
    final started = Completer<void>();
    runner.scripts
      ..add((_, cancellation, _) async {
        started.complete();
        await cancellation.whenCancelled;
        throw const KernelCancelledException();
      })
      ..add((_, _, _) async => _done('第二件'));
    await service1.start(conversationId: 'c1', instruction: '一');
    await service1.start(conversationId: 'c1', instruction: '二');
    await started.future;
    await service1.setEnabled(false);
    expect((await store.get('s1'))!.status, AgentTaskStatus.cancelled);
    expect((await store.get('s2'))!.frozen, isTrue);
    expect(relayed, isEmpty, reason: '关闭后不转告');
    expect(await store.pendingDeliveries(), ['s1_1']);

    await service1.setEnabled(true);
    await service1.idle();
    expect((await store.get('s2'))!.status, AgentTaskStatus.queued);
    expect(relayed, ['s1_1'], reason: '打开后补转告，但冻结任务不自动跑');
    await service1.resume('s2');
    await service1.idle();
    expect((await store.get('s2'))!.status, AgentTaskStatus.done);
  });

  group('sync scan', () {
    late Map<String, List<MessageBlock>> blocks;
    late TaskAgentSupervisor supervisor;

    Future<void> insertMessage(String id, TextBlock block) async {
      blocks[id] = [block];
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: id,
              conversationId: 'c1',
              role: 'user',
              content: block.content,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              status: const Value('sent'),
            ),
          );
    }

    setUp(() {
      blocks = {};
      supervisor = TaskAgentSupervisor(
        service: Future.value(service),
        scanner: TaskSyncScanner(database),
        loadBlocks: (id) async => blocks[id] ?? const [],
      );
    });

    test('a synced receipt gets a delivery and is relayed once', () async {
      final receipt = TaskReceiptBlock(
        messageId: 'task_receipt_remote_1',
        receiptId: 'remote_1',
        taskId: 'remote',
        receiptStatus: TaskReceiptStatus.done,
        summary: '另一台设备查好了',
        executorDevice: 'phone',
      );
      await insertMessage('task_receipt_remote_1', receipt);
      written.add(RecordedReceipt(
        (await store.create(
          id: 'shadow',
          requestKey: null,
          conversationId: 'c1',
          instruction: '',
        )).$1,
        receipt,
      ));
      // The shadow task only lends findReceipt a RecordedReceipt; it runs too.
      runner.scripts.add((_, _, _) async => _done('影子'));
      await supervisor.scan();
      await supervisor.scan();
      await service.idle();
      expect(relayed.where((id) => id == 'remote_1'), hasLength(1));
      expect(await store.pendingDeliveries(), isEmpty);
    });

    test('a synced cancel reaches the task running here', () async {
      runner.scripts.add((_, _, _) async => _done('需要城市', question: '哪个城市？'));
      await service.start(conversationId: 'c1', instruction: '查天气');
      await service.idle();
      await insertMessage(
        'task_control_ctl_phone',
        TaskControlBlock(
          messageId: 'task_control_ctl_phone',
          controlId: 'ctl_phone',
          taskId: 't1',
          kind: TaskControlKind.cancel,
        ),
      );
      await insertMessage(
        'task_control_ctl_import',
        TaskControlBlock(
          messageId: 'task_control_ctl_import',
          controlId: 'ctl_import',
          taskId: 't1',
          kind: TaskControlKind.reply,
          answersReceiptId: 't1_1',
          text: '杭州',
          executable: false,
        ),
      );
      await supervisor.scan();
      expect((await store.get('t1'))!.status, AgentTaskStatus.cancelled);
      expect(runner.transcripts, hasLength(1), reason: '导入的控制事件不执行');
    });
  });
}
