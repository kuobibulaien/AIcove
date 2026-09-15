import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/memory/domain/contact_memory_port.dart';
import 'package:aicove_flutter/src/features/memory/data/markdown_contact_memory_store.dart';
import 'package:aicove_flutter/src/features/memory/application/contact_memory_reader.dart';

void main() {
  late Directory root;
  late MarkdownContactMemoryStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('contact_memory_test_');
    store = MarkdownContactMemoryStore(() async => root);
  });
  tearDown(() async => root.delete(recursive: true));

  ContactMemoryEvent event(String id, String body) => ContactMemoryEvent(
        id: id,
        title: '面试后散步',
        body: body,
        occurredAt: DateTime.utc(2026, 9, 1),
      );

  test('角色拥有独立 MD；重启保留正文；相同事件 id 不串库', () async {
    var a = await store.load('role-a');
    a = await store.save(a.copyWith(
      enabled: true,
      core: '不喜欢香菜',
      events: [event('same-id', 'A 的共同经历')],
    ));
    final b = await store.load('role-b');
    await store
        .save(b.copyWith(enabled: true, events: [event('same-id', 'B 的经历')]));
    final restarted = MarkdownContactMemoryStore(() async => root);
    expect((await restarted.load('role-a')).core, '不喜欢香菜');
    expect((await restarted.load('role-b')).core, isEmpty);
    final files = await root
        .list(recursive: true)
        .where((e) => e.path.endsWith('MEMORY.md'))
        .toList();
    expect(files, hasLength(2));
    expect(await File(files.first.path).readAsString(), contains('# 常驻记忆'));
    final reader = ContactMemoryReader(restarted);
    expect(await reader.readEvent('role-a', 'same-id'), contains('A 的共同经历'));
    expect(
        await reader.readEvent('role-a', 'same-id'), isNot(contains('B 的经历')));
    expect(await reader.readEvent('role-b', 'missing'), contains('not_found'));
    expect(a.revision, isNotEmpty);
  });

  test('拒绝旧版本覆盖，两个 store 并发仅允许一次提交', () async {
    final snapshot = await store.load('role-a');
    final other = MarkdownContactMemoryStore(() async => root);
    final results = await Future.wait([
      store
          .save(snapshot.copyWith(core: '版本一'))
          .then<Object>((v) => v)
          .catchError((Object e) => e),
      other
          .save(snapshot.copyWith(core: '版本二'))
          .then<Object>((v) => v)
          .catchError((Object e) => e),
    ]);
    expect(results.whereType<ContactMemoryNotebook>(), hasLength(1));
    expect(results.whereType<ContactMemoryConflict>(), hasLength(1));
  });

  test('非法 owner、结构标记、重复 id 不写盘', () async {
    await expectLater(store.load(' '), throwsArgumentError);
    final a = await store.load('role-a');
    await expectLater(store.save(a.copyWith(core: '<!-- aicove-core -->')),
        throwsFormatException);
    await expectLater(
        store.save(a.copyWith(events: [event('x', '一'), event('x', '二')])),
        throwsFormatException);
    expect((await store.load('role-a')).revision, isEmpty);
  });

  test('owner 中的路径文本不会越出根目录', () async {
    final a = await store.load('../../outside');
    await store.save(a.copyWith(core: '安全隔离'));
    final files = await root
        .list(recursive: true)
        .where((e) => e.path.endsWith('MEMORY.md'))
        .toList();
    expect(files, hasLength(1));
    expect(files.single.path, startsWith(root.path));
    expect(files.single.path, isNot(contains('outside')));
  });

  test('原文损坏或 owner 被替换时失败，不悄悄退回空记忆', () async {
    await store.save((await store.load('role-a')).copyWith(core: '原内容'));
    final file = (await root
            .list(recursive: true)
            .where((e) => e.path.endsWith('MEMORY.md'))
            .toList())
        .single;
    await File(file.path).writeAsString('broken');
    await expectLater(store.load('role-a'), throwsFormatException);
  });

  test('目录分页、关键词找旧事，常驻提示不塞入全部事件正文', () async {
    final entries = List.generate(
        25, (i) => event('e$i', '共同经历 $i：${i == 0 ? '紫色雨伞' : '散步'}'));
    await store.save((await store.load('role-a'))
        .copyWith(enabled: true, core: '先倾听', events: entries));
    final reader = ContactMemoryReader(store);
    final prompt = await reader.buildPrompt('role-a', supportsTools: true);
    expect(prompt, contains('先倾听'));
    expect(prompt, contains('memory_search'));
    expect(prompt, isNot(contains('紫色雨伞')));
    expect(await reader.search('role-a', query: '紫色雨伞'), contains('e0'));
    final ids = <String>[];
    int? offset = 0;
    while (offset != null) {
      final page = jsonDecode(await reader.search('role-a', offset: offset))
          as Map<String, dynamic>;
      ids.addAll((page['entries'] as List).map((e) => e['id'] as String));
      offset = page['nextOffset'] as int?;
    }
    expect(ids, hasLength(25));
    expect(ids.toSet(), hasLength(25));
    expect(ids, contains('e24'));
    expect(await reader.readEvent('role-a', 'e0'), contains('紫色雨伞'));
    expect(await reader.buildPrompt('role-a', supportsTools: false),
        contains('不支持'));
  });

  test('常驻超预算拒绝保存，原始内容不被裁短或覆盖', () async {
    final a =
        await store.save((await store.load('role-a')).copyWith(core: '原记忆'));
    await expectLater(
        store.save(a.copyWith(core: List.filled(2000, '字').join())),
        throwsFormatException);
    expect((await store.load('role-a')).core, '原记忆');
  });

  test('正文分页保留 Unicode 与完整细节', () async {
    final body = '${List.filled(1199, '字').join()}𠮷后续细节';
    await store.save((await store.load('role-a'))
        .copyWith(enabled: true, events: [event('long', body)]));
    final reader = ContactMemoryReader(store);
    final first = jsonDecode(await reader.readEvent('role-a', 'long'))
        as Map<String, dynamic>;
    final second = jsonDecode(await reader.readEvent('role-a', 'long',
        offset: first['nextOffset'] as int)) as Map<String, dynamic>;
    expect('${first['body']}${second['body']}', body);
    expect(second['nextOffset'], isNull);
  });

  test('外部编辑正文后，旧页面版本不能覆盖；MD owner 篡改被拒绝', () async {
    final a =
        await store.save((await store.load('role-a')).copyWith(core: '原内容'));
    final file = File((await root
            .list(recursive: true)
            .where((e) => e.path.endsWith('MEMORY.md'))
            .toList())
        .single
        .path);
    await file
        .writeAsString((await file.readAsString()).replaceFirst('原内容', '外部更新'));
    expect((await store.load('role-a')).core, '外部更新');
    await expectLater(store.save(a.copyWith(core: '过时草稿')),
        throwsA(isA<ContactMemoryConflict>()));
    await file.writeAsString((await file.readAsString())
        .replaceFirst('"ownerId":"role-a"', '"ownerId":"role-b"'));
    await expectLater(store.load('role-a'), throwsFormatException);
  });

  test('关闭后旧工具也不能读取；移除事件后不能再找回', () async {
    var a = await store.save((await store.load('role-a'))
        .copyWith(enabled: true, events: [event('x', '秘密')]));
    final reader = ContactMemoryReader(store);
    a = await store.save(a.copyWith(events: []));
    expect(await reader.readEvent('role-a', 'x'), contains('not_found'));
    await store.save(a.copyWith(enabled: false));
    expect(await reader.search('role-a'), contains('disabled'));
    expect(await reader.buildPrompt('role-a', supportsTools: true), isNull);
  });
}
