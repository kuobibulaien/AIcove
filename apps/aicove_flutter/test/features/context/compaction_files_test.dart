import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/context/application/runtime_context_service.dart';
import 'package:aicove_flutter/src/features/context/data/background_context_summarizer.dart';
import 'package:aicove_flutter/src/features/context/domain/compaction_files.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/context/domain/context_window_policy.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

Message message(List<ToolBlock> blocks) => Message(
  id: 'm',
  role: 'assistant',
  content: '',
  blocks: blocks,
  createdAt: DateTime(2026),
);

ToolBlock tool(
  String name,
  Map<String, dynamic> args, {
  Map<String, dynamic>? result,
  BlockStatus status = BlockStatus.success,
}) => ToolBlock(
  messageId: 'm',
  toolName: name,
  arguments: args,
  result: result,
  status: status,
);

List<Map<String, dynamic>> step(
  String name,
  Map<String, dynamic> args, {
  Object result = 'ok',
  String id = 'c',
}) => [
  {
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': jsonEncode(args)},
      },
    ],
  },
  {'role': 'tool', 'tool_call_id': id, 'content': result},
];

ContextSummary previous(String text) => ContextSummary(
  id: 'p',
  ownerId: 'a',
  kind: ContextSummaryKind.auto,
  boundaryId: 'old',
  topicBoundary: null,
  summary: text,
  sourceIds: const ['old'],
  sourceDigest: '',
  createdAt: DateTime(2026),
);

class _RuntimeSummary implements ContextSummarizerPort {
  final seen = <ContextSnapshot>[];
  String text = '任务已经推进，继续下一步。'; // 故意完全不输出文件名。
  @override
  Future<String> summarize(
    ContextSnapshot snapshot, {
    required ContextSummaryKind kind,
    required void Function(int, int) onProgress,
    required bool Function() isCancelled,
  }) async {
    seen.add(snapshot);
    return text;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('跨次合并，工作区同名路径区分，已修改优先且绝对路径保持原样', () {
    final first = collectMessageFiles([
      message([
        tool('read', {'path': 'unknown.txt'}),
        tool('workspace_open', {'id': 'alpha'}),
        tool('read', {'path': 'same.txt'}),
        tool('workspace_open', {'path': '/local/project'}),
        tool('read', {'path': 'same.txt'}),
        tool('read', {'path': '/absolute.txt'}),
        tool('read', {'path': '~/home.txt'}),
        tool('read', {'path': r'C:\work\file.txt'}),
      ]),
    ]);
    expect(first.read, [
      'unknown.txt',
      '[alpha] same.txt',
      '[/local/project] same.txt',
      '/absolute.txt',
      '~/home.txt',
      r'C:\work\file.txt',
    ]);
    final second = collectMessageFiles([
      message([
        tool('edit', {'path': 'same.txt'}),
        tool('workspace_move', {'from': 'old.txt', 'to': 'new.txt'}),
        tool('workspace_delete', {'path': 'deleted.txt'}),
      ]),
    ], previous: CompactionFiles.strip(first.appendTo('旧摘要')));
    expect(second.modified, [
      '[/local/project] same.txt',
      '[/local/project] old.txt',
      '[/local/project] new.txt',
      '[/local/project] deleted.txt',
    ]);
    expect(second.read, contains('[alpha] same.txt'));
    expect(second.read, isNot(contains('[/local/project] same.txt')));
    final third = collectMessageFiles([
      message([
        tool('read', {'path': 'same.txt'}),
        tool(
          'workspace_create',
          {'name': 'new'},
          result: {'output': 'workspace: created-id\nname: new'},
        ),
        tool('write', {'path': 'same.txt'}),
      ]),
    ], previous: CompactionFiles.strip(second.appendTo('第二次摘要')));
    expect(third.workspace, 'created-id');
    expect(third.modified.last, '[created-id] same.txt');
    expect(third.read, isNot(contains('[/local/project] same.txt')));
  });

  test('清单标签往返保留特殊路径，剥离只留下任务摘要', () {
    const path = 'a\n"quoted"\n</read-files>.txt';
    final files = CompactionFiles(
      read: [path],
      modified: ['b'],
      workspace: '空间',
    );
    final text = files.appendTo('任务正文');
    final parsed = CompactionFiles.strip(text);
    expect(parsed.text, '任务正文');
    expect(parsed.read, [path]);
    expect(parsed.modified, ['b']);
    expect(parsed.workspace, '空间');
    expect(parsed.appendTo(parsed.text), text);
    expect(
      CompactionFiles.strip('<read-files>\nplain.txt\n</read-files>').read,
      ['plain.txt'],
    );
  });

  test('明确错误过滤，未知结果视为成功；失败切换不影响工作区', () {
    final files = collectMessageFiles([
      message([
        tool('workspace_open', {'id': 'good'}),
        tool('workspace_open', {'id': 'bad'}, result: {'is_error': true}),
        tool('read', {'path': 'status'}, status: BlockStatus.error),
        tool('read', {'path': 'flag'}, result: {'isError': true}),
        tool('edit', {'path': 'error-field'}, result: {'error': 'failed'}),
        tool('read', {'path': 'json'}, result: {'output': '{"is_error":true}'}),
        for (final prefix in [
          'invalid_path',
          'not_found',
          'revision_mismatch',
          'busy',
          'limit',
          'read_only',
          'unauthorized',
          'unavailable',
          'filesystem_error',
          'invalid_argument',
          'cancelled',
          'ambiguous',
          'overlap',
        ])
          tool(
            'write',
            {'path': prefix},
            result: {'output': '$prefix: failed'},
          ),
        tool(
          'workspace_create',
          {'name': 'bad'},
          result: {'workspace': 'bad', 'error': 'no'},
        ),
        tool(
          'read',
          {'path': 'unrecognized'},
          result: {'output': 'unknown response'},
        ),
        tool('write', {'path': 'no-result'}),
      ]),
    ]);
    expect(files.workspace, 'good');
    expect(files.read, ['[good] unrecognized']);
    expect(files.modified, ['[good] no-result']);
  });

  test('codemode 截断参数只提取完整字符串，外层失败保留成功子调用', () {
    final args = jsonEncode({'path': 'nested"file.txt', 'content': 'x' * 400});
    final files = collectMessageFiles([
      message([
        tool('workspace_open', {'id': 'w'}),
        tool(
          'codemode',
          {},
          status: BlockStatus.error,
          result: {
            'codemodeCalls': [
              {'name': 'write', 'status': 'ok', 'args': args.substring(0, 200)},
              {
                'name': 'workspace_move',
                'status': 'ok',
                'args': '{"from":"old","to":"new","extra":',
              },
              {'name': 'read', 'status': 'ok', 'args': '{"path":"truncated'},
              {'name': 'read', 'status': 'error', 'args': '{"path":"failed"}'},
              {'name': 'read', 'status': 'ok', 'args': '{"path":"read.txt"}'},
            ],
          },
        ),
      ]),
    ]);
    expect(files.modified, ['[w] nested"file.txt', '[w] old', '[w] new']);
    expect(files.read, ['[w] read.txt']);
    // 运行时不处理嵌套调用，即使结果中出现 codemodeCalls。
    expect(
      collectRuntimeFiles(
        step(
          'codemode',
          {},
          result: {
            'codemodeCalls': [
              {'name': 'read', 'status': 'ok', 'args': '{"path":"ignored"}'},
            ],
          },
        ),
      ).read,
      isEmpty,
    );
  });

  test('每类保留最近 100 条，重复操作更新顺序，省略数量跨压缩延续', () {
    final first = collectMessageFiles([
      message([
        for (var i = 0; i < 105; i++) tool('read', {'path': 'r$i'}),
        tool('read', {'path': 'r5'}),
        for (var i = 0; i < 103; i++) tool('write', {'path': 'm$i'}),
      ]),
    ]);
    expect(first.read, [...List.generate(99, (i) => 'r${i + 6}'), 'r5']);
    expect(first.modified, List.generate(100, (i) => 'm${i + 3}'));
    expect(first.readOmitted, 5);
    expect(first.modifiedOmitted, 3);
    final next = collectMessageFiles([
      message([
        tool('read', {'path': 'r105'}),
        tool('edit', {'path': 'r5'}),
      ]),
    ], previous: CompactionFiles.strip(first.appendTo('正文')));
    expect(next.read, [...List.generate(99, (i) => 'r${i + 6}'), 'r105']);
    expect(next.readOmitted, 5);
    expect(next.modifiedOmitted, 4);
    expect(next.modified.last, 'r5');
    expect(next.appendTo('正文'), contains('[omitted: 5]'));
  });

  test('运行时各供应商调用配对、错误过滤及工作区创建', () {
    final files = collectRuntimeFiles([
      ...step('workspace_open', {'id': 'a'}),
      ...step('read', {'path': 'same'}),
      ...step('workspace_create', {}, result: 'workspace: b\nname: B'),
      ...step('read', {'path': 'same'}),
      ...step('read', {'path': 'bad-json'}, result: '{"error":"bad"}'),
      ...step('read', {'path': 'bad-prefix'}, result: 'not_found: missing'),
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'edit',
            'name': 'edit',
            'input': {'path': 'same'},
          },
          {
            'type': 'tool_use',
            'id': 'bad',
            'name': 'write',
            'input': {'path': 'bad'},
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'bad',
            'is_error': true,
            'content': 'no',
          },
          {'type': 'tool_result', 'tool_use_id': 'edit', 'content': 'done'},
        ],
      },
      {
        'role': 'assistant',
        'content': {
          'parts': [
            {
              'functionCall': {
                'name': 'workspace_move',
                'args': {'from': 'from', 'to': 'to'},
              },
            },
          ],
        },
      },
      {
        'role': 'user',
        'content': {
          'parts': [
            {
              'functionResponse': {
                'name': 'workspace_move',
                'response': {'result': 'done'},
              },
            },
          ],
        },
      },
      {
        'role': 'assistant',
        'function_call': {
          'name': 'workspace_delete',
          'arguments': '{"path":"gone"}',
        },
      },
      {'role': 'function', 'name': 'workspace_delete', 'content': 'done'},
      ...step('read', {'path': 'unmatched'}).take(1),
    ]);
    expect(files.read, ['[a] same']);
    expect(files.modified, ['[b] same', '[b] from', '[b] to', '[b] gone']);
    expect(files.workspace, 'b');
  });

  test('运行时模型遗漏文件仍保留，连续压缩剥离旧清单并延续工作区', () async {
    final model = _RuntimeSummary();
    final service = RuntimeContextService(
      owner: 'a',
      policy: ContextWindowPolicy(
        configured: 4000,
        modelWindow: 4000,
        outputReserve: 0,
      ),
      summarizerFactory: () async => model,
    );
    final first = await service.prepare([
      {'role': 'user', 'content': '继续任务'},
      ...step('workspace_open', {'id': 'w'}, result: 'x' * 7000),
      ...step('read', {'path': 'keep.txt'}, result: 'x' * 7000),
    ], force: true);
    final firstText = first.last['content'] as String;
    expect(CompactionFiles.strip(firstText).read, ['[w] keep.txt']);
    final second = await service.prepare([
      ...first,
      ...step('edit', {'path': 'keep.txt'}, result: 'x' * 7000),
      ...step('read', {'path': 'next.txt'}, result: 'x' * 7000),
    ], force: true);
    final parsed = CompactionFiles.strip(second.last['content'] as String);
    expect(parsed.read, ['[w] next.txt']);
    expect(parsed.modified, ['[w] keep.txt']);
    final payload = model.seen.last.messages.map((m) => m.content).join();
    expect(payload, isNot(contains('<read-files>')));
    expect(payload, isNot(contains('<file-workspace>')));
    expect(jsonEncode(first), contains('<read-files>')); // 不修改输入。
  });

  test('运行时每类裁剪至 100 条后仍通过上下文缩减检查', () async {
    final model = _RuntimeSummary();
    final steps = [
      for (var i = 0; i < 110; i++)
        step('read', {'path': 'read$i'}, id: 'r$i', result: 'x' * 100),
      for (var i = 0; i < 110; i++)
        step('write', {'path': 'write$i'}, id: 'w$i', result: 'x' * 100),
    ];
    final service = RuntimeContextService(
      owner: 'a',
      policy: ContextWindowPolicy(
        configured: 12000,
        modelWindow: 12000,
        outputReserve: 0,
      ),
      summarizerFactory: () async => model,
    );
    final result = await service.prepare([
      {'role': 'user', 'content': '当前任务'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          for (final pair in steps) ...(pair.first['tool_calls'] as List),
        ],
      },
      for (final pair in steps) pair.last,
    ], force: true);
    final files = CompactionFiles.strip(result.last['content'] as String);
    expect(files.read, List.generate(100, (i) => 'read${i + 10}'));
    expect(files.modified, List.generate(100, (i) => 'write${i + 10}'));
    expect(files.readOmitted, 10);
    expect(files.modifiedOmitted, 10);
    expect(model.seen, hasLength(1));
  });

  test('文件清单不能掩盖模型返回空摘要的失败', () async {
    final model = _RuntimeSummary()..text = '';
    final service = RuntimeContextService(
      owner: 'a',
      policy: ContextWindowPolicy(
        configured: 4000,
        modelWindow: 4000,
        outputReserve: 0,
      ),
      summarizerFactory: () async => model,
    );
    await expectLater(
      service.prepare([
        {'role': 'user', 'content': '继续任务'},
        ...step('read', {'path': 'keep.txt'}, result: 'x' * 7000),
      ], force: true),
      throwsA(isA<ContextCompactionException>()),
    );
  });

  for (final mode in ['task', 'companion', 'manual']) {
    test('$mode 模板：仅任务自动压缩追加清单，模型看不到旧清单块', () async {
      final inputs = <Map>[];
      final agent = BackgroundAgentService(
        loadRecentMessages: (_, __) async => throw StateError('不得读取缓存'),
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
              inputs.add(
                jsonDecode(config.messages.last['content'] as String) as Map,
              );
              return const ApiCallResult(
                replyText: '{"facts":["任务继续，模型没有输出文件名"]}',
                processedText: '',
                pluginEvents: [],
                toolResults: [],
              );
            },
      );
      final summarizer = BackgroundContextSummarizer(
        agent,
        modelRef: 'fake',
        contextTokens: 8192,
        isCompanion: (_) async => mode == 'companion',
      );
      final old = CompactionFiles(
        read: ['[w] old.txt'],
        workspace: 'w',
      ).appendTo('旧任务');
      Future<String> compress(String? prior, List<ToolBlock> blocks) {
        final messages = [message(blocks)];
        return summarizer.summarize(
          ContextSnapshot(
            ownerId: 'a',
            previousBoundaryId: null,
            allMessages: messages,
            messages: messages,
            previous: prior == null ? null : previous(prior),
          ),
          kind: mode == 'manual'
              ? ContextSummaryKind.manual
              : ContextSummaryKind.auto,
          onProgress: (_, __) {},
          isCancelled: () => false,
        );
      }

      // 陪聊和手动翻篇使用无清单的原始摘要，确保旧行为未改变。
      final first = await compress(mode == 'task' ? old : '旧任务', [
        tool('read', {'path': 'new.txt'}),
        tool('edit', {'path': 'old.txt'}),
        if (mode == 'task')
          tool('write', {'path': 'chunked.txt', 'content': '历史内容' * 6000}),
      ]);
      if (mode == 'task') {
        expect(inputs.first['previous_facts'], '旧任务');
        expect(inputs.length, greaterThan(1));
        expect(CompactionFiles.strip(first).read, ['[w] new.txt']);
        expect(CompactionFiles.strip(first).modified, [
          '[w] old.txt',
          '[w] chunked.txt',
        ]);
        final second = await compress(first, [
          tool('write', {'path': 'third.txt'}),
        ]);
        final third = await compress(second, [
          tool('edit', {'path': 'new.txt'}),
        ]);
        final parsed = CompactionFiles.strip(third);
        expect(parsed.read, isEmpty);
        expect(parsed.modified, [
          '[w] old.txt',
          '[w] chunked.txt',
          '[w] third.txt',
          '[w] new.txt',
        ]);
        for (final input in inputs) {
          expect(input['previous_facts'], isNot(contains('<modified-files>')));
          expect(input['previous_facts'], isNot(contains('<read-files>')));
          expect(input['previous_facts'], isNot(contains('<file-workspace>')));
        }
      } else {
        expect(first, '- 任务继续，模型没有输出文件名');
        expect(first, isNot(contains('<read-files>')));
        expect(first, isNot(contains('<modified-files>')));
      }
    });
  }
}
