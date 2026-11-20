import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_retrieval.dart';
import 'package:aicove_flutter/src/features/memory/data/background_memory_agent_adapter.dart';
import 'package:aicove_flutter/src/features/memory/data/sqlite_memory_store.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_item.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_ports.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

class _Agent implements MemoryAgentPort {
  _Agent(this.respond);
  List<MemoryOp> Function(List<Message> batch, List<MemoryItem> core) respond;
  final batches = <List<String>>[];
  Completer<void>? gate;
  bool fail = false;
  @override
  int batchTokenBudget = 100000;
  @override
  Future<List<MemoryOp>> propose({
    required String ownerId,
    required List<MemoryItem> core,
    required List<MemoryItem> related,
    required List<Message> messages,
  }) async {
    batches.add(messages.map((m) => m.id).toList());
    if (gate != null) await gate!.future;
    if (fail) throw StateError('model down');
    return respond(messages, core);
  }
}

Message _m(String id, int at, {String role = 'user', String? text}) => Message(
  id: id,
  role: role,
  content: text ?? '$id 的内容',
  createdAt: DateTime.fromMillisecondsSinceEpoch(at),
  status: 'sent',
);

void main() {
  late Directory root;
  late db.AppDatabase database;
  late SqliteMemoryStore store;
  late _Agent agent;
  late MemoryKeeperService keeper;
  var messages = <String, List<Message>>{};
  var boundaries = <String, Set<String>>{};
  var allowed = true;

  Future<void> owner(String id) => database.customStatement(
    "INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES(?,?,?,1,1)",
    [id, id, id],
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('memory_keeper_');
    database = db.AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/t.sqlite')),
    );
    await database.customStatement('PRAGMA foreign_keys = ON');
    await owner('a');
    await owner('b');
    store = SqliteMemoryStore(database);
    messages = {};
    boundaries = {};
    allowed = true;
    agent = _Agent(
      (batch, _) => [
        AddMemory(
          layer: MemoryLayer.archive,
          title: '聊过 ${batch.first.id}',
          content: '聊到了 ${batch.map((m) => m.id).join('、')}',
          sourceIds: [batch.first.id],
        ),
      ],
    );
    keeper = MemoryKeeperService(
      store: store,
      loadMessages: (o) async => messages[o] ?? const [],
      compactedBoundaries: (o) async => boundaries[o] ?? const {},
      agentFactory: () async => agent,
      allowed: (_) async => allowed,
    );
  });
  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  test('自动整理避让，手动重建认领后继续', () async {
    messages['a'] = [_m('a1', 1), _m('a2', 2)];
    boundaries['a'] = {'a2'};
    var claimed = 0;
    var owns = false;
    var remoteRunning = false;
    keeper = MemoryKeeperService(
      store: store,
      loadMessages: (o) async => messages[o] ?? const [],
      compactedBoundaries: (o) async => boundaries[o] ?? const {},
      agentFactory: () async => agent,
      allowed: (_) async => true,
      canAutoRun: (_) async => owns && !remoteRunning,
      claimOwnership: (_) async {
        claimed++;
      },
    );
    keeper.resumeOnce('a');
    await keeper.idle('a');
    expect(agent.batches, isEmpty);
    owns = true;
    remoteRunning = true;
    keeper.schedule('a');
    await keeper.idle('a');
    expect(agent.batches, isEmpty);
    await keeper.startRebuild('a');
    await keeper.idle('a');
    expect(claimed, 1);
    expect(agent.batches, isNotEmpty);
  });

  test('只整理被压缩覆盖的原文；书签推进后不重复整理；角色隔离', () async {
    messages['a'] = [_m('a1', 1), _m('a2', 2, role: 'assistant'), _m('a3', 3)];
    messages['b'] = [_m('b1', 1)];
    boundaries['a'] = {'a2'};
    keeper.schedule('a');
    await keeper.idle('a');
    expect(agent.batches, [
      ['a1', 'a2'],
    ]);
    expect((await store.list('a')).single.sourceIds, ['a1']);
    expect(await store.list('b'), isEmpty);
    keeper.schedule('a');
    await keeper.idle('a');
    expect(agent.batches, hasLength(1));
    boundaries['a'] = {'a2', 'a3'};
    keeper.schedule('a');
    await keeper.idle('a');
    expect(agent.batches.last, ['a3']);
    expect((await store.progress('a')).untilId, 'a3');
  });

  test('按记忆模型预算分批；失败记录错误且书签不动，之后续跑', () async {
    messages['a'] = [for (var i = 0; i < 6; i++) _m('m$i', i, text: '字' * 400)];
    boundaries['a'] = {'m5'};
    agent.batchTokenBudget = 900;
    agent.fail = true;
    keeper.schedule('a');
    await keeper.idle('a');
    expect((await store.progress('a')).lastError, contains('model down'));
    expect((await store.progress('a')).untilId, isNull);
    agent.fail = false;
    keeper.schedule('a');
    await keeper.idle('a');
    expect(agent.batches.length, greaterThan(2));
    expect(agent.batches.skip(1).expand((b) => b).toList(), [
      for (var i = 0; i < 6; i++) 'm$i',
    ]);
    expect((await store.progress('a')).lastError, isNull);
  });

  test('锁定和用户手写的记忆不被改动；删除后陈旧更新不复活', () async {
    messages['a'] = [_m('a1', 1)];
    boundaries['a'] = {'a1'};
    final mine = await store.saveByUser(
      ownerId: 'a',
      layer: MemoryLayer.core,
      title: '称呼',
      content: '叫我小林',
    );
    agent.respond = (batch, core) => [
      UpdateMemory(id: mine.id, content: '被模型改掉'),
      DeleteMemory(mine.id),
      const UpdateMemory(id: 'not-exist', content: '不存在'),
    ];
    keeper.schedule('a');
    await keeper.idle('a');
    final items = await store.list('a');
    expect(items.single.content, '叫我小林');
    expect(items.single.locked, isTrue);
  });

  test('常驻层有预算上限，超出的新常驻条目改存档案', () async {
    messages['a'] = [_m('a1', 1)];
    boundaries['a'] = {'a1'};
    agent.respond = (batch, _) => [
      for (var i = 0; i < 12; i++)
        AddMemory(
          layer: MemoryLayer.core,
          title: '事实$i',
          content: '长' * 300 + '$i',
          sourceIds: ['a1'],
        ),
    ];
    keeper.schedule('a');
    await keeper.idle('a');
    final core = await store.list('a', layer: MemoryLayer.core);
    final archive = await store.list('a', layer: MemoryLayer.archive);
    expect(core, isNotEmpty);
    expect(archive, isNotEmpty);
    expect(core.length + archive.length, 12);
  });

  test('重建：删除未锁定条目、从头整理全部原文；旧批次在代次变化后被丢弃', () async {
    messages['a'] = [_m('a1', 1), _m('a2', 2), _m('a3', 3)];
    boundaries['a'] = {'a1'};
    keeper.schedule('a');
    await keeper.idle('a');
    await store.saveByUser(
      ownerId: 'a',
      layer: MemoryLayer.archive,
      title: '手写',
      content: '保留我',
    );
    expect(await store.list('a'), hasLength(2));

    // 正在跑的旧任务在重建开始后写入，必须被丢弃。
    boundaries['a'] = {'a2'};
    agent.gate = Completer<void>();
    keeper.schedule('a');
    await Future<void>.delayed(Duration.zero);
    await store.resetForRebuild('a', messages['a']!.last);
    agent.gate!.complete();
    agent.gate = null;
    await keeper.idle('a');
    await keeper.startRebuild('a');
    await keeper.idle('a');
    final items = await store.list('a');
    expect(items.map((i) => i.title), containsAll(['手写', '聊过 a1']));
    expect(items.where((i) => !i.locked), hasLength(1));
    expect((await store.progress('a')).untilId, 'a3');
    expect((await store.progress('a')).rebuildUntilId, isNull);
  });

  test('暂停后不再整理；角色关闭记忆库时不整理', () async {
    messages['a'] = [_m('a1', 1)];
    boundaries['a'] = {'a1'};
    await keeper.pause('a');
    keeper.schedule('a');
    await keeper.idle('a');
    expect(agent.batches, isEmpty);
    allowed = false;
    await keeper.resume('a');
    await keeper.idle('a');
    expect(agent.batches, isEmpty);
    allowed = true;
    await keeper.resume('a');
    await keeper.idle('a');
    expect(agent.batches, hasLength(1));
  });

  test('检索注入：常驻全带，档案按关键词取最相关的，不跨角色', () async {
    await store.saveByUser(
      ownerId: 'a',
      layer: MemoryLayer.core,
      title: '称呼',
      content: '用户叫小林',
    );
    await store.saveByUser(
      ownerId: 'a',
      layer: MemoryLayer.archive,
      title: '看海',
      content: '周五一起去海边看日落',
    );
    await store.saveByUser(
      ownerId: 'a',
      layer: MemoryLayer.archive,
      title: '猫',
      content: '家里的猫叫团子',
    );
    await store.saveByUser(
      ownerId: 'b',
      layer: MemoryLayer.archive,
      title: '海边',
      content: 'B 的海边往事',
    );
    final injector = MemoryInjector(
      store: store,
      retriever: KeywordMemoryRetriever(store),
    );
    final memory = (await injector.build(
      ownerId: 'a',
      roleLabel: '阿绫',
      query: buildMemoryQuery([_m('x', 1, text: '还记得海边吗')], '日落好看吗'),
    ))!;
    // 常驻进系统提示，检索到的往事单独一块（放到队尾提醒），互不混入。
    expect(memory.core, contains('用户叫小林'));
    expect(memory.core, isNot(contains('海边看日落')));
    expect(memory.archive, contains('海边看日落'));
    expect(memory.archive, isNot(contains('用户叫小林')));
    final prompt = '${memory.core}\n${memory.archive}';
    expect(prompt, isNot(contains('团子')));
    expect(prompt, isNot(contains('B 的海边')));
    expect(
      await injector.build(ownerId: 'b', roleLabel: 'B', query: '猫'),
      isNull,
    );
  });

  test('记忆整理给足输出额度，服务商嫌大时逐次减半重试', () async {
    final maxes = <int?>[];
    final adapter = BackgroundMemoryAgentAdapter(
      BackgroundAgentService(
        loadRecentMessages: (_, __) async => throw StateError('不得回退缓存'),
        loadSettings: () async => mapUiModelsToAppSettings({}),
        requestConfigResolver: ({required settings, required modelRef}) async =>
            const BackgroundAgentRequestConfig(
              modelFullId: 'openai:fake',
              providerApiBase: 'https://invalid.test',
              providerApiKey: 'fake',
              customConfig: {},
              modelTemperature: .2,
              modelTopP: 1,
              modelContextMessageLimit: 30,
            ),
        executor:
            ({
              required config,
              required availableTools,
              required sessionId,
            }) async {
              maxes.add(config.providerRequestOptions?.maxOutputTokens);
              if (maxes.length == 1) {
                throw StateError('HTTP 400: max_tokens is too large');
              }
              return const ApiCallResult(
                replyText: '{"ops":[]}',
                processedText: '',
                pluginEvents: [],
                toolResults: [],
              );
            },
      ),
      store: store,
      modelRef: 'fake',
      contextTokens: 128000,
    );
    expect(
      await adapter.propose(
        ownerId: 'a',
        core: const [],
        related: const [],
        messages: [_m('x', 1)],
      ),
      isEmpty,
    );
    expect(maxes, [32000, 16000]);
  });

  test('解析记忆模型输出：丢弃越界 id、锁定目标和无来源的新增', () {
    final ops = parseMemoryOps(
      '```json\n{"ops":['
      '{"op":"add","layer":"core","title":"称呼","content":"叫小林","source_ids":["m1"]},'
      '{"op":"add","title":"无来源","content":"x","source_ids":["别的"]},'
      '{"op":"update","id":"k1","content":"更正"},'
      '{"op":"update","id":"locked","content":"不许"},'
      '{"op":"delete","id":"other-owner"}'
      ']}\n```',
      knownIds: {'k1', 'locked'},
      lockedIds: {'locked'},
      sourceIds: {'m1'},
    );
    expect(ops, hasLength(2));
    expect(ops.first, isA<AddMemory>());
    expect((ops.first as AddMemory).layer, MemoryLayer.core);
    expect((ops.last as UpdateMemory).id, 'k1');
    expect(
      () => parseMemoryOps(
        '没有 JSON',
        knownIds: const {},
        lockedIds: const {},
        sourceIds: const {},
      ),
      throwsA(isA<MemoryException>()),
    );
  });

  test('滚动窗口严格早于 24 小时并顺延连续消息', () async {
    final base = DateTime(2026, 5, 12, 12);
    Message at(String id, Duration delta) =>
        _m(id, base.add(delta).millisecondsSinceEpoch);
    messages['a'] = [
      at('old', Duration.zero),
      at('cutoff', const Duration(minutes: 10)),
      at('continued', const Duration(minutes: 20)),
      at('break', const Duration(minutes: 31)),
      at('latest', const Duration(hours: 24, minutes: 10)),
    ];
    expect((await keeper.pendingMessages('a')).map((m) => m.id), [
      'old',
      'cutoff',
      'continued',
    ]);
    messages['a'] = [
      at('recent', Duration.zero),
      at('latest', const Duration(hours: 24)),
    ];
    expect(await keeper.pendingMessages('a'), isEmpty);
  });

  test('自然日合并、预算和天数限制保持续跑一致', () async {
    final day = DateTime(2026, 5, 12, 8);
    Message at(String id, int days, {int minutes = 0, String? text}) => _m(
      id,
      day.add(Duration(days: days, minutes: minutes)).millisecondsSinceEpoch,
      text: text,
    );
    List<List<Message>> batch(List<Message> input) =>
        MemoryKeeperService.buildBatches(
          input,
          startIndex: 0,
          targetIndex: input.length - 1,
          budget: 100000,
        );
    final sparse = [for (var i = 0; i < 8; i++) at('d$i', i)];
    expect(batch(sparse.take(7).toList()), hasLength(1));
    expect(batch(sparse).map((b) => b.length), [7, 1]);
    final sameDay = [
      for (var i = 0; i < 24; i++) at('m$i', 0, minutes: i < 12 ? i : i + 180),
    ];
    expect(batch(sameDay), hasLength(1));
    final large = [
      at('a', 0, text: '字' * 2000),
      at('b', 1, text: '字' * 2000),
      at('c', 1, minutes: 1, text: '字' * 2000),
      at('d', 2, text: '字' * 2000),
    ];
    final batches = batch(large);
    expect(batches.map((b) => b.map((m) => m.id).toList()), [
      ['a'],
      ['b', 'c'],
      ['d'],
    ]);
    messages['a'] = large;
    boundaries['a'] = {'d'};
    final estimate = await keeper.estimateRebuild(
      'a',
      batchTokenBudget: 100000,
    );
    keeper.schedule('a');
    await keeper.idle('a');
    expect(estimate.batches, batches.length);
    expect(
      agent.batches,
      batches.map((b) => b.map((m) => m.id).toList()).toList(),
    );
    expect(
      MemoryKeeperService.buildBatches(
        large,
        startIndex: -1,
        targetIndex: 2,
        budget: 1,
      ),
      isEmpty,
    );
    expect(
      MemoryKeeperService.buildBatches(
        large,
        startIndex: 4,
        targetIndex: 5,
        budget: 1,
      ),
      isEmpty,
    );
    expect(
      MemoryKeeperService.buildBatches(
        large,
        startIndex: 1,
        targetIndex: 0,
        budget: 1,
      ),
      isEmpty,
    );
  });

  test('跨日来源补日期并保护批次外旧日记', () {
    final dates = {'m1': '2026-05-12', 'm2': '2026-05-13'};
    final roundDates = dates.values.toSet().toList();
    final titles = {
      'first': '2026-05-12 旅行',
      'second': '2026-05-13 海边',
      'old': '2026-05-11 往事',
    };
    final protected = {
      for (final entry in titles.entries)
        if (!roundDates.any((d) => entry.value.startsWith(d))) entry.key,
    };
    expect(protected, {'old'});
    final ops = parseMemoryOps(
      '{"ops":[{"op":"add","title":"旅行","content":"出发","source_ids":["m1"]},'
      '{"op":"add","title":"海边","content":"看海","source_ids":["m2"]},'
      '{"op":"update","id":"first","content":"补充"},'
      '{"op":"update","id":"second","content":"补充"},'
      '{"op":"update","id":"old","content":"改"},{"op":"delete","id":"old"}]}',
      knownIds: titles.keys.toSet(),
      lockedIds: {},
      sourceIds: dates.keys.toSet(),
      sourceDates: dates,
      defaultArchiveDate: '2026-05-12',
      protectedArchiveIds: protected,
    );
    expect(ops, hasLength(4));
    expect((ops[0] as AddMemory).title, '2026-05-12 旅行');
    expect((ops[1] as AddMemory).title, '2026-05-13 海边');
    expect((ops[2] as UpdateMemory).id, 'first');
    expect((ops[3] as UpdateMemory).id, 'second');
    expect(formatMemoryRoundDate(DateTime(2026, 5, 12)), '2026-05-12');
  });

  test('日记按标题日期排序且注入不附加更新日期', () async {
    for (final title in ['2026-05-12 旅行', '2026-05-10 往事', '无日期']) {
      await store.saveByUser(
        ownerId: 'a',
        layer: MemoryLayer.archive,
        title: title,
        content: '海边',
      );
    }
    expect((await store.list('a')).map((i) => i.title), [
      '2026-05-12 旅行',
      '2026-05-10 往事',
      '无日期',
    ]);
    final injector = MemoryInjector(
      store: store,
      retriever: KeywordMemoryRetriever(store),
    );
    final result = (await injector.build(
      ownerId: 'a',
      roleLabel: '角色',
      query: '海边',
    ))!;
    expect(result.archive, matches(RegExp(r'- 2026-05-12 旅行：海边(?:\n|$)')));
    expect(result.archive, matches(RegExp(r'无日期：海边（\d{4}-\d{2}-\d{2}）')));
  });

  test('运行中的触发不丢失，续跑检查按十分钟节流', () async {
    messages['a'] = [_m('a1', 1)];
    boundaries['a'] = {'a1'};
    var loads = 0;
    keeper = MemoryKeeperService(
      store: store,
      loadMessages: (o) async {
        loads++;
        return messages[o] ?? const [];
      },
      compactedBoundaries: (o) async => boundaries[o] ?? const {},
      agentFactory: () async => agent,
      allowed: (_) async => true,
    );
    agent.gate = Completer<void>();
    keeper.schedule('a');
    await Future<void>.delayed(Duration.zero);
    keeper.schedule('a');
    agent.gate!.complete();
    agent.gate = null;
    await keeper.idle('a');
    await keeper.idle('a');
    expect(agent.batches, hasLength(1));
    expect(loads, 3);
    final now = DateTime(2026, 5, 12);
    keeper.resumeOnce('a', now: now);
    await keeper.idle('a');
    keeper.resumeOnce('a', now: now.add(const Duration(minutes: 9)));
    expect(keeper.isRunning('a'), isFalse);
    keeper.resumeOnce('a', now: now.add(const Duration(minutes: 10)));
    expect(keeper.isRunning('a'), isTrue);
    await keeper.idle('a');
  });

  test('清空聊天只删自动整理的记忆和进度，用户锁定的保留', () async {
    messages['a'] = [_m('a1', 1)];
    boundaries['a'] = {'a1'};
    keeper.schedule('a');
    await keeper.idle('a');
    await store.saveByUser(
      ownerId: 'a',
      layer: MemoryLayer.archive,
      title: '手写',
      content: '保留',
    );
    await store.clearDerived('a');
    expect((await store.list('a')).single.title, '手写');
    expect((await store.progress('a')).untilId, isNull);
  });
}
