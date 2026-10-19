import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

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

  Future<AgentTask> newTask({
    String id = 't1',
    String? key = 'k1',
    String conversation = 'c1',
    TaskReceiptNotify notify = TaskReceiptNotify.always,
  }) async => (await store.create(
    id: id,
    requestKey: key,
    conversationId: conversation,
    instruction: '查天气',
    notify: notify,
  )).$1;

  test('one request key gives one task; another chat cannot reuse it', () async {
    final (first, created) = await store.create(
      id: 't1',
      requestKey: 'dev|c1|run|1|call_1',
      conversationId: 'c1',
      instruction: 'a',
    );
    expect(created, isTrue);
    final (again, createdAgain) = await store.create(
      id: 't2',
      requestKey: 'dev|c1|run|1|call_1',
      conversationId: 'c1',
      instruction: 'a',
    );
    expect(createdAgain, isFalse);
    expect(again.id, first.id);
    await expectLater(
      store.create(
        id: 't3',
        requestKey: 'dev|c1|run|1|call_1',
        conversationId: 'c2',
        instruction: 'a',
      ),
      throwsA(isA<AgentTaskKeyConflict>()),
    );
    // Same provider call id in another chat is another request key.
    final (other, createdOther) = await store.create(
      id: 't4',
      requestKey: 'dev|c2|run2|1|call_1',
      conversationId: 'c2',
      instruction: 'a',
    );
    expect(createdOther, isTrue);
    expect(other.id, 't4');
  });

  test('finishing records the receipt and its delivery together', () async {
    await newTask();
    expect(await store.markRunning('t1'), isTrue);
    expect(await store.markRunning('t1'), isFalse);
    final recorded = (await store.finish(
      't1',
      from: {AgentTaskStatus.running},
      to: AgentTaskStatus.done,
      executorDevice: 'mac',
      summary: '晴，25 度',
    ))!;
    expect(recorded.block.receiptId, 't1_1');
    expect(recorded.messageId, 'task_receipt_t1_1');
    expect(recorded.task.status, AgentTaskStatus.done);
    expect(await store.pendingDeliveries(), ['t1_1']);
    expect((await store.unwrittenReceipts()).single.block.summary, '晴，25 度');
    expect(
      await store.finish(
        't1',
        from: {AgentTaskStatus.running},
        to: AgentTaskStatus.failed,
        executorDevice: 'mac',
      ),
      isNull,
      reason: '终态不会再变',
    );
    await store.markReceiptWritten('t1', 't1_1');
    expect(await store.unwrittenReceipts(), isEmpty);
  });

  test('notify=never records no delivery except for questions', () async {
    await newTask(notify: TaskReceiptNotify.never);
    await store.markRunning('t1');
    await store.finish(
      't1',
      from: {AgentTaskStatus.running},
      to: AgentTaskStatus.needsInput,
      executorDevice: 'mac',
      question: '哪个城市？',
    );
    expect(await store.pendingDeliveries(), ['t1_1']);
    await store.consumeReply(
      controlId: 'ctl1',
      taskId: 't1',
      answersReceiptId: 't1_1',
    );
    await store.markRunning('t1');
    await store.finish(
      't1',
      from: {AgentTaskStatus.running},
      to: AgentTaskStatus.done,
      executorDevice: 'mac',
    );
    expect(await store.pendingDeliveries(), ['t1_1'], reason: '完成回执不转告');
  });

  test('a reply is consumed once and only for the open question', () async {
    await newTask();
    await store.markRunning('t1');
    await store.finish(
      't1',
      from: {AgentTaskStatus.running},
      to: AgentTaskStatus.needsInput,
      executorDevice: 'mac',
      question: '哪个城市？',
    );
    expect(
      await store.consumeReply(
        controlId: 'wrong',
        taskId: 't1',
        answersReceiptId: 'other',
      ),
      isFalse,
    );
    expect(
      await store.consumeReply(
        controlId: 'ctl',
        taskId: 't1',
        answersReceiptId: 't1_1',
      ),
      isTrue,
    );
    expect((await store.get('t1'))!.status, AgentTaskStatus.queued);
    expect(
      await store.consumeReply(
        controlId: 'ctl',
        taskId: 't1',
        answersReceiptId: 't1_1',
      ),
      isFalse,
      reason: '同一个控制事件只消费一次',
    );
  });

  test('kill switch freezes queued and waiting tasks', () async {
    await newTask(id: 'q', key: 'kq');
    await newTask(id: 'r', key: 'kr');
    await store.markRunning('r');
    final generation = await store.setSwitch(false);
    expect((await store.readSwitch()), (false, generation));
    expect((await store.get('q'))!.frozen, isTrue);
    expect((await store.get('r'))!.frozen, isFalse);
    expect(await store.runnable(), isEmpty);
    await store.setSwitch(true);
    expect(await store.runnable(), isEmpty, reason: '打开后不自动继续');
    await store.unfreeze('q');
    expect((await store.runnable()).single.id, 'q');
  });

  test('receipt block limits: summary, question, artifacts and size', () {
    TaskReceiptBlock receipt({
      String summary = '',
      String? question,
      int artifacts = 0,
    }) => TaskReceiptBlock(
      messageId: 'm',
      receiptId: 'r',
      taskId: 't',
      receiptStatus: TaskReceiptStatus.done,
      summary: summary,
      question: question,
      artifacts: [
        for (var i = 0; i < artifacts; i++)
          TaskArtifact(workspaceId: 'w', path: 'f$i'),
      ],
      executorDevice: 'mac',
    );
    expect(receipt(summary: '字' * 600).summary.length, 600);
    expect(receipt(summary: '字' * 600).truncated, isFalse);
    final over = receipt(summary: '字' * 601);
    expect(over.truncated, isTrue);
    expect(utf8.encode(over.summary).length, lessThanOrEqualTo(2048));
    expect(receipt(question: 'q' * 301).question!.length, 301, reason: '300 字＋省略号');
    expect(receipt(artifacts: 20).artifacts, hasLength(20));
    expect(receipt(artifacts: 21).artifacts, hasLength(20));
    final huge = receipt(
      summary: '😀' * 600,
      question: '😀' * 300,
      artifacts: 20,
    );
    expect(huge.byteSize, lessThanOrEqualTo(8192));
    final restored = TaskReceiptBlock.fromJson(huge.toJson());
    expect(restored.summary, huge.summary);
    expect(restored.content, huge.content);
    final control = TaskControlBlock(
      messageId: 'm',
      controlId: 'c',
      taskId: 't',
      kind: TaskControlKind.cancel,
    );
    expect(TextBlock.fromJson(control.toJson()), isA<TaskControlBlock>());
    expect(TextBlock.fromJson(control.inert().toJson()) as TaskControlBlock,
        isA<TaskControlBlock>().having((c) => c.executable, 'executable', false));
  });
}
