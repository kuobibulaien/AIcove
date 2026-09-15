import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/application/runtime_context_service.dart';
import 'package:aicove_flutter/src/features/chat/domain/runtime_context_port.dart';
import 'package:aicove_flutter/src/features/chat/domain/context_window_policy.dart';
import 'package:aicove_flutter/src/features/chat/domain/topic_compaction_port.dart';
import 'package:aicove_flutter/src/features/memory/domain/compaction_memory.dart';

class Store implements RuntimeContextStorePort {
  final sources = <List<Map<String, dynamic>>>[];
  @override
  Future<String> save({
    required String owner,
    required List<Map<String, dynamic>> source,
    required List<Map<String, dynamic>> replacement,
    List<CompactionMemoryUpdate> updates = const [],
    String? expectedSourceId,
  }) async {
    sources.add(source);
    return 'record${sources.length}';
  }

  @override
  Future<String?> read(
    String owner,
    String id,
    int messageIndex, {
    int offset = 0,
    String? query,
  }) async => null;
}

class Summary implements TopicSummaryPort {
  TopicSnapshot? seen;
  @override
  Future<String> summarize(
    TopicSnapshot snapshot, {
    required void Function(int, int) onProgress,
    required bool Function() isCancelled,
  }) async {
    seen = snapshot;
    return '已经完成查询；用户的目标保持不变。';
  }
}

void main() {
  late Store store;
  late Summary summary;
  RuntimeContextService make(int window) => RuntimeContextService(
    owner: 'a',
    policy: ContextWindowPolicy(
      configured: window,
      modelWindow: window,
      outputReserve: 0,
    ),
    store: store,
    summaryFactory: () async => summary,
  );
  setUp(() {
    store = Store();
    summary = Summary();
  });
  Map<String, dynamic> call(String id) => {
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': id,
        'type': 'function',
        'function': {'name': 'search', 'arguments': '{}'},
      },
    ],
  };
  Map<String, dynamic> result(String id, String text) => {
    'role': 'tool',
    'tool_call_id': id,
    'content': text,
  };
  test('272k为容量，80%触发，16%保留；供应商较小时收紧', () {
    final p = ContextWindowPolicy(configured: 272000, modelWindow: 1000000);
    expect(p.trigger, 217600);
    expect(p.retain, 43520);
    expect(
      ContextWindowPolicy(configured: 272000, modelWindow: 32000).trigger,
      25600,
    );
  });
  test('无压力不裁剪；压力下Unicode首尾裁剪且先持久化原文', () async {
    final text = '头${'😀' * 20000}尾';
    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': '查资料'},
      call('a'),
      result('a', text),
    ];
    expect(await make(272000).prepare(messages), same(messages));
    expect(store.sources, isEmpty);
    final compressed = await make(20000).prepare(messages);
    expect(compressed[2]['content'], startsWith('头'));
    expect(compressed[2]['content'], endsWith('尾'));
    expect(
      compressed[2]['content'],
      contains('context_read id=record1 message=2'),
    );
    expect(store.sources.first[2]['content'], text);
    expect(messages[2]['content'], text);
    expect(summary.seen, isNull);
  });
  test('同一用户轮次内压缩闭合工具步骤，当前输入和未闭合调用保留', () async {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': '保持当前角色格式'},
      {'role': 'user', 'content': '先查询A再查B'},
      call('a'),
      result('a', 'a' * 7000),
      call('b'),
      result('b', 'b' * 7000),
      call('pending'),
    ];
    final compressed = await make(4000).prepare(messages);
    expect(compressed.first, messages.first);
    expect(compressed, contains(messages[1]));
    expect(compressed.last, messages.last);
    expect(summary.seen, isNotNull);
    final payload = summary.seen!.messages.map((m) => m.content).join();
    expect(payload, contains('"tool_call_id":"a"'));
    expect(payload, isNot(contains('pending')));
    expect(payload, isNot(contains('先查询A再查B')));
    final calls = compressed
        .expand((m) => (m['tool_calls'] as List? ?? []).map((c) => c['id']))
        .toSet();
    for (final m in compressed.where((m) => m['role'] == 'tool')) {
      expect(calls, contains(m['tool_call_id']));
    }
  });
  test('低于本地阈值仍能强制恢复；只有大用户输入时不删输入', () async {
    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': '旧内容${'x' * 2000}'},
      {'role': 'user', 'content': '最新要求'},
    ];
    final result = await make(272000).prepare(messages, force: true);
    expect(jsonEncode(result), contains('最新要求'));
    expect(summary.seen, isNotNull);
    await expectLater(
      make(1000).prepare([
        {'role': 'user', 'content': '原文${'x' * 10000}'},
      ]),
      throwsA(isA<TopicCompactionException>()),
    );
  });
  test('超限识别不会把鉴权、限流或普通失败变成压缩循环', () {
    expect(isContextOverflow(StateError('context_length_exceeded')), isTrue);
    for (final error in [
      '401 unauthorized',
      '429 rate limit',
      'network timeout',
    ]) {
      expect(isContextOverflow(StateError(error)), isFalse);
    }
  });
}
