import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_process_record.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _ObservedProcess extends TaskProcessRecord {
  _ObservedProcess(super.directory);

  Future<void> Function()? beforeSave;

  @override
  Future<void> saveCheckpoint(String taskId, TaskCheckpoint checkpoint) async {
    await beforeSave?.call();
    await super.saveCheckpoint(taskId, checkpoint);
  }
}

void main() {
  late db.AppDatabase database;
  late AgentTaskStore store;
  late Directory directory;
  late _ObservedProcess process;
  late TaskAgentService service;
  late List<String> relayed;
  TaskReceiptBlock? syncedReceipt;

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    store = AgentTaskStore(database);
    directory = await Directory.systemTemp.createTemp('reply_persistence');
    process = _ObservedProcess(directory);
    relayed = [];
    syncedReceipt = null;
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
    service = TaskAgentService(
      store: store,
      process: process,
      runner: TaskAgentRunner(
        loadSettings: () => throw UnimplementedError(),
        executor:
            ({
              required config,
              required tools,
              required sessionId,
              required cancellation,
            }) => throw UnimplementedError(),
      ),
      capabilities: (_, _, _, {bool readOnly = false}) async =>
          const TaskAgentCapabilities(),
      writeReceipt: (_) async {},
      relay: (_, receipt) async {
        relayed.add(receipt.receiptId);
        return true;
      },
      findReceipt: (_) async => syncedReceipt,
      ownsConversation: (_) async => true,
      deviceId: () async => 'mac',
      maxConcurrent: 0,
    );
    await store.create(
      id: 't',
      requestKey: null,
      conversationId: 'c',
      instruction: 'task',
    );
    await store.finish(
      't',
      from: {AgentTaskStatus.queued},
      to: AgentTaskStatus.needsInput,
      executorDevice: 'mac',
      question: 'city?',
    );
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<TaskControlOutcome> reply({String receipt = 't_1'}) => service.reply(
    taskId: 't',
    controlId: 'control',
    answersReceiptId: receipt,
    answer: 'Shanghai',
  );

  Future<void> seedCheckpoint() => process.saveCheckpoint(
    't',
    const TaskCheckpoint(transcript: 'task', question: 'city?'),
  );

  Future<void> expectUnconsumed() async {
    expect((await store.get('t'))!.status, AgentTaskStatus.needsInput);
    expect(
      await database.customSelect('SELECT * FROM agent_task_controls').get(),
      isEmpty,
    );
  }

  test('missing checkpoint leaves reply and control unconsumed', () async {
    expect(await reply(), TaskControlOutcome.ignored);
    await expectUnconsumed();
  });

  test(
    'checkpoint failure leaves SQLite state and control unchanged',
    () async {
      await seedCheckpoint();
      process.beforeSave = () async =>
          throw const FileSystemException('disk full');
      await expectLater(reply(), throwsA(isA<FileSystemException>()));
      await expectUnconsumed();
      expect((await process.checkpoint('t'))!.transcript, 'task');
    },
  );

  test('answer is persisted before consuming the reply', () async {
    await seedCheckpoint();
    process.beforeSave = expectUnconsumed;
    expect(await reply(), TaskControlOutcome.applied);
    expect((await store.get('t'))!.status, AgentTaskStatus.queued);
    expect((await process.checkpoint('t'))!.contextMessages.last, {
      'role': 'user',
      'content': 'Shanghai',
    });
  });

  test('wrong question never modifies the checkpoint', () async {
    await seedCheckpoint();
    process.beforeSave = () async => fail('invalid reply must not write');
    expect(await reply(receipt: 'wrong'), TaskControlOutcome.ignored);
    await expectUnconsumed();
  });

  test('already consumed control never modifies the checkpoint', () async {
    await seedCheckpoint();
    await database.customStatement(
      'INSERT INTO agent_task_controls VALUES (?,?,?)',
      ['control', 'another-task', 0],
    );
    process.beforeSave = () async => fail('duplicate control must not write');
    expect(await reply(), TaskControlOutcome.ignored);
    expect((await store.get('t'))!.status, AgentTaskStatus.needsInput);
  });

  test('missing local task and receipt finishes an invalid delivery', () async {
    await store.addDelivery(
      receiptId: 'gone_1',
      taskId: 'gone',
      conversationId: 'c',
    );
    await service.deliver('gone_1');
    expect(await store.pendingDeliveries(), isNot(contains('gone_1')));
    expect(relayed, isEmpty);
  });

  test('local task with missing receipt remains retryable', () async {
    await store.markReceiptWritten('t', 't_1');
    await service.deliver('t_1');
    expect(await store.pendingDeliveries(), contains('t_1'));
  });

  test('synced receipt without a local task is still delivered', () async {
    syncedReceipt = TaskReceiptBlock(
      messageId: 'task_receipt_remote_1',
      receiptId: 'remote_1',
      taskId: 'remote',
      receiptStatus: TaskReceiptStatus.done,
      executorDevice: 'phone',
      summary: 'done',
    );
    await store.addDelivery(
      receiptId: 'remote_1',
      taskId: 'remote',
      conversationId: 'c',
    );
    await service.deliver('remote_1');
    expect(relayed, ['remote_1']);
    expect(await store.pendingDeliveries(), isNot(contains('remote_1')));
  });
}
