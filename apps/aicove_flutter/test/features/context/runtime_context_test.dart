import 'dart:typed_data';
import 'dart:io';
import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:aicove_flutter/src/core/api/tool_media.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/openai_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/tool_output.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/context/application/runtime_context_service.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/context/domain/context_window_policy.dart';

class Summary implements ContextSummarizerPort {
  ContextSnapshot? seen;
  @override
  Future<String> summarize(
    ContextSnapshot snapshot, {
    required ContextSummaryKind kind,
    required void Function(int, int) onProgress,
    required bool Function() isCancelled,
  }) async {
    seen = snapshot;
    return '已经完成查询；用户的目标保持不变。';
  }
}

class FixedResultStore extends ToolResultStore {
  FixedResultStore() : super(() async => Directory.systemTemp);

  final preserved = <String>[];

  @override
  Future<String> preserve(
    String owner,
    String text, {
    bool alreadyLimited = false,
  }) async {
    preserved.add(text);
    return 'saved reference';
  }
}

void main() {
  late Summary summary;
  late ToolResultStore results;
  RuntimeContextService make(int window, {List<Map<String, dynamic>>? tools}) =>
      RuntimeContextService(
        owner: 'a',
        resultStore: results,
        tools: tools,
        policy: ContextWindowPolicy(
          configured: window,
          modelWindow: window,
          outputReserve: 0,
        ),
        summarizerFactory: () async => summary,
      );
  setUp(() async {
    summary = Summary();
    final directory = await Directory.systemTemp.createTemp('runtime-results-');
    results = ToolResultStore(() async => directory);
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
  for (final adapter in <ProviderAdapter>[
    OpenAIAdapter(),
    ClaudeAdapter(),
    GeminiAdapter(),
  ]) {
    test(
      '${adapter.name} compacts call/results/attachments as one step, never latest user',
      () async {
        final assistant = switch (adapter.name) {
          'claude' => <String, dynamic>{
            'content': [
              {'type': 'tool_use', 'id': 'a', 'name': 'read', 'input': {}},
            ],
          },
          'gemini' => <String, dynamic>{
            'content': {
              'parts': [
                {
                  'functionCall': {'name': 'read', 'args': {}},
                },
              ],
            },
          },
          _ => call('a'),
        };
        final step = adapter.buildToolResultMessages(
          assistantMessage: assistant,
          toolResults: [
            ToolResult(
              toolCallId: 'a',
              name: 'read',
              result: 'x' * 7000,
              images: [
                ToolImage(
                  mimeType: 'image/png',
                  bytes: Uint8List.fromList([1, 2, 3]),
                  source: 'attachment',
                ),
              ],
            ),
          ],
        );
        final messages = <Map<String, dynamic>>[
          {'role': 'user', 'content': 'latest real input'},
          ...step,
        ];
        final compacted = await make(272000).prepare(messages, force: true);
        expect(compacted, contains(messages.first));
        expect(summary.seen, isNotNull);
        expect(summary.seen!.messages, hasLength(step.length));
        final text = summary.seen!.messages.map((m) => m.content).join();
        expect(text, isNot(contains('latest real input')));
        expect(text, isNot(contains('AQID')));
        expect(compacted.any((m) => m[toolStepMarker] == true), false);
      },
    );
  }
  test('272k为容量，80%触发，16%保留；供应商较小时收紧', () {
    final p = ContextWindowPolicy(configured: 272000, modelWindow: 1000000);
    expect(p.trigger, 217600);
    expect(p.retain, 43520);
    expect(
      ContextWindowPolicy(configured: 272000, modelWindow: 32000).trigger,
      25600,
    );
  });
  test('无压力不裁剪；压力下保存全文并返回引用与首尾预览', () async {
    final text = '头${'😀' * 20000}尾';
    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': '查资料'},
      call('a'),
      result('a', text),
    ];
    expect(await make(272000).prepare(messages), same(messages));
    final compressed = await make(20000).prepare(messages);
    expect(compressed[2]['content'], contains('头'));
    expect(compressed[2]['content'], endsWith('尾'));
    expect(compressed[2]['content'], contains('reference='));
    expect(compressed[2]['content'], isNot(contains('context_read')));
    expect(messages[2]['content'], text);
    expect(summary.seen, isNull);
  });
  group('分阶段裁剪工具结果', () {
    final oldText = 'old' * 4000;
    final recentText = 'recent' * 2000;

    List<Map<String, dynamic>> twoBatches() => [
      call('old'),
      result('old', oldText),
      call('recent'),
      result('recent', recentText),
      {'role': 'assistant', 'content': '', 'tool_calls': []},
    ];

    int windowForTrigger(int tokens) => (tokens * 5 + 3) ~/ 4;

    test('旧结果裁剪后低于阈值，保护最后非空调用之后的最近批', () async {
      final store = FixedResultStore();
      results = store;
      final messages = twoBatches();
      final pass1 = [...messages];
      pass1[1] = result('old', 'saved reference');
      final service = make(
        windowForTrigger(renderedContextTokens(pass1, null) + 1),
      );
      final pruned = await service.pruneToolResults(messages);

      expect(store.preserved, [oldText]);
      expect(pruned[1]['content'], 'saved reference');
      expect(pruned[3], same(messages[3]));
      expect(messages[1]['content'], oldText);
      expect(summary.seen, isNull);
    });

    for (final remainingPressure in [0, 1]) {
      test('旧结果裁剪后${remainingPressure == 0 ? '等于' : '高于'}阈值，继续裁剪最近批', () async {
        final store = FixedResultStore();
        results = store;
        final messages = twoBatches();
        final pass1 = [...messages];
        pass1[1] = result('old', 'saved reference');
        final trigger = renderedContextTokens(pass1, null) - remainingPressure;
        final service = make(windowForTrigger(trigger));
        expect(service.policy.trigger, trigger);
        final pruned = await service.pruneToolResults(messages);

        expect(store.preserved, [oldText, recentText]);
        expect(pruned[3]['content'], 'saved reference');
        expect(messages[3]['content'], recentText);
      });
    }

    test('工具定义也计入第一阶段剩余预算', () async {
      final store = FixedResultStore();
      results = store;
      final messages = twoBatches();
      final pass1 = [...messages];
      pass1[1] = result('old', 'saved reference');
      final trigger = renderedContextTokens(pass1, null) + 1;
      final tools = <Map<String, dynamic>>[
        {'type': 'function', 'description': 'tool schema' * 100},
      ];
      expect(renderedContextTokens(pass1, tools), greaterThan(trigger));
      final pruned = await make(
        windowForTrigger(trigger),
        tools: tools,
      ).pruneToolResults(messages);

      expect(store.preserved, [oldText, recentText]);
      expect(pruned[3]['content'], 'saved reference');
    });

    test('只有最近批或旧结果无需裁剪时，仍裁剪最近批', () async {
      for (final hasOld in [false, true]) {
        final store = FixedResultStore();
        results = store;
        final messages = <Map<String, dynamic>>[
          if (hasOld) ...[call('old'), result('old', 'short')],
          call('recent'),
          result('recent', recentText),
        ];
        final pruned = await make(272000).pruneToolResults(messages);

        expect(store.preserved, [recentText]);
        expect(pruned.last['content'], 'saved reference');
      }
    });

    test('没有超长结果时保留原列表，无调用标记的旧结果仍可裁剪', () async {
      final store = FixedResultStore();
      results = store;
      final messages = [call('recent'), result('recent', 'short')];
      expect(await make(1).pruneToolResults(messages), same(messages));
      expect(store.preserved, isEmpty);

      final pruned = await make(1).pruneToolResults([result('old', oldText)]);
      expect(pruned.single['content'], 'saved reference');
      expect(store.preserved, [oldText]);
    });

    test('function与文本块沿用两段裁剪，非文本附件和原文不变', () async {
      final store = FixedResultStore();
      results = store;
      final image = {
        'type': 'image_url',
        'image_url': {'url': 'image'},
      };
      final messages = <Map<String, dynamic>>[
        call('old'),
        {
          'role': 'function',
          'name': 'search',
          'content': [
            {'type': 'text', 'text': oldText},
            image,
          ],
        },
        call('recent'),
        {'role': 'function', 'name': 'search', 'content': recentText},
      ];
      final pruned = await make(272000).pruneToolResults(messages);

      expect(store.preserved, [oldText]);
      expect(pruned[1]['content'][0]['text'], 'saved reference');
      expect(pruned[1]['content'][1], same(image));
      expect(pruned[3], same(messages[3]));
      expect(messages[1]['content'][0]['text'], oldText);

      final pressured = await make(1).pruneToolResults(messages);
      expect(pressured[3]['content'], 'saved reference');
    });
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
      throwsA(isA<ContextCompactionException>()),
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
