import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/memory/domain/contact_memory_port.dart';
import 'package:aicove_flutter/src/features/memory/domain/compaction_memory.dart';
import 'package:aicove_flutter/src/features/memory/data/markdown_contact_memory_store.dart';
import 'package:aicove_flutter/src/features/memory/application/compaction_memory_service.dart';
import 'package:aicove_flutter/src/features/memory/application/contact_memory_reader.dart';

class Queue implements CompactionMemoryQueuePort {
  final jobs = <CompactionMemoryJob>[];
  final done = <String>{};
  bool valid = true, failFinish = false;
  @override
  Future<List<CompactionMemoryJob>> pending(String owner) async =>
      jobs.where((j) => j.owner == owner && !done.contains(j.id)).toList();
  @override
  Future<bool> sourcesValid(String id) async => valid;
  @override
  Future<void> finish(String id, {bool discarded = false}) async {
    if (failFinish) throw const FileSystemException('simulated');
    done.add(id);
  }
}

class FailingMemory implements ContactMemoryPort {
  FailingMemory(this.inner);
  final ContactMemoryPort inner;
  bool fail = true;
  @override
  Future<ContactMemoryNotebook> load(String owner) => inner.load(owner);
  @override
  Future<ContactMemoryNotebook> save(ContactMemoryNotebook n) {
    if (fail) throw const FileSystemException('simulated');
    return inner.save(n);
  }
}

void main() {
  late Directory root;
  late MarkdownContactMemoryStore store;
  late Queue queue;
  late CompactionMemoryService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('compaction-memory');
    store = MarkdownContactMemoryStore(() async => root);
    await store.save(
      (await store.load('a')).copyWith(enabled: true, core: '手写内容逐字保留'),
    );
    queue = Queue();
    service = CompactionMemoryService(
      memory: store,
      queue: queue,
      allowed: (_) async => true,
    );
  });
  tearDown(() async => root.delete(recursive: true));
  CompactionMemoryUpdate update({
    String body = '用户不吃香菜',
    ContactMemoryEvent? previous,
  }) => CompactionMemoryUpdate(
    key: 'food.coriander',
    title: '饮食偏好',
    body: body,
    kind: 'core',
    sourceIds: ['raw1'],
    existingId: previous?.id,
    expectedDigest: previous?.generatedDigest,
  );
  void add(String id, CompactionMemoryUpdate u) =>
      queue.jobs.add(CompactionMemoryJob(id, 'a', [u]));

  test('空队列完成，锁释放后下一次可继续，不等待自身future', () async {
    expect(
      await service.flush('a').timeout(const Duration(seconds: 2)),
      isTrue,
    );
    add('j1', update());
    expect(
      await service.flush('a').timeout(const Duration(seconds: 2)),
      isTrue,
    );
    expect((await store.load('a')).events, hasLength(1));
  });
  test('自动事实进入有限常驻区；保留手写正文且跨角色隔离', () async {
    add('j1', update());
    await service.flush('a');
    final notebook = await store.load('a');
    expect(notebook.core, '手写内容逐字保留');
    expect(
      await ContactMemoryReader(store).buildPrompt('a', supportsTools: true),
      contains('用户不吃香菜'),
    );
    expect((await store.load('b')).events, isEmpty);
    expect(notebook.appliedCompactions, ['j1']);
  });
  test('文件失败不清队列，服务重建后补写且不重复', () async {
    final failing = FailingMemory(store);
    add('j1', update());
    expect(
      await CompactionMemoryService(
        memory: failing,
        queue: queue,
        allowed: (_) async => true,
      ).flush('a'),
      isFalse,
    );
    expect(queue.done, isEmpty);
    expect((await store.load('a')).events, isEmpty);
    expect(await service.flush('a'), isTrue);
    await service.flush('a');
    expect((await store.load('a')).events, hasLength(1));
  });
  test('文件已写而数据库标记失败；用户删除后重试不复活', () async {
    queue.failFinish = true;
    add('j1', update());
    expect(await service.flush('a'), isFalse);
    await store.save((await store.load('a')).copyWith(events: []));
    queue.failFinish = false;
    await service.flush('a');
    expect((await store.load('a')).events, isEmpty);
  });
  test('更正未编辑自动记录；用户只改标题也不覆盖', () async {
    add('j1', update());
    await service.flush('a');
    var old = (await store.load('a')).events.single;
    add('j2', update(body: '用户现在接受香菜', previous: old));
    await service.flush('a');
    var notebook = await store.load('a');
    old = notebook.events.single;
    expect(old.body, '用户现在接受香菜');
    await store.save(
      notebook.copyWith(
        events: [
          ContactMemoryEvent(
            id: old.id,
            title: '人工标题',
            body: old.body,
            occurredAt: old.occurredAt,
            generatedKey: old.generatedKey,
            generatedDigest: old.generatedDigest,
            memoryKind: old.memoryKind,
          ),
        ],
      ),
    );
    add('j3', update(body: '再次更正', previous: old));
    await service.flush('a');
    notebook = await store.load('a');
    expect(notebook.events.single.title, '人工标题');
    expect(notebook.events.single.body, old.body);
  });
  test('来源失效和关闭记忆都不会落文件', () async {
    add('j1', update());
    queue.valid = false;
    await service.flush('a');
    expect((await store.load('a')).events, isEmpty);
    queue.valid = true;
    add('j2', update());
    await store.save((await store.load('a')).copyWith(enabled: false));
    expect(await service.flush('a'), isFalse);
    expect(queue.done, isNot(contains('j2')));
  });
}
