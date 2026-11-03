import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_assembler.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_world_book.dart';

void main() {
  const parser = SillyTavernPresetParser();
  const assembler = SillyTavernPresetAssembler();

  group('drawing prompt macros', () {
    const drawing =
        'Draw {{char}} with {{user}}; {{setvar::leak::bad}}'
        '{{getvar::secret}}{{trim}}';

    SillyTavernAssemblyResult assembleDrawing({
      List<Map<String, dynamic>> prompts = const [],
      List<Map<String, dynamic>> history = const [],
      String prefill = '',
      String runtimeContent = 'voice rules',
      String content = drawing,
      bool fallback = true,
      bool squash = false,
      bool includeHistory = true,
      Map<String, String> variables = const {},
      List<TavernWorldInjection> worlds = const [],
      SillyTavernAssemblyContext? context,
    }) {
      final preset = parser.parseSource(
        jsonEncode({
          'assistant_prefill': prefill,
          'squash_system_messages': squash,
          'prompts': [
            ...prompts,
            {'identifier': 'chatHistory', 'marker': true},
          ],
          'prompt_order': [
            {
              'order': [
                for (final prompt in prompts)
                  {
                    'identifier': prompt['identifier'],
                    'enabled': prompt['enabled'] != false,
                  },
                {'identifier': 'chatHistory', 'enabled': includeHistory},
              ],
            },
          ],
        }),
        sourceFileName: 'drawing.json',
      );
      return assembler.assemble(
        preset: preset,
        historyMessages: history,
        context:
            context ??
            SillyTavernAssemblyContext(
              characterName: 'C',
              userName: 'U',
              characterDescription: '',
              scenario: '',
              runtimeSystemContent: runtimeContent,
              drawingPromptContent: content,
              fallbackDrawingPrompt: fallback,
              initialVariables: variables,
              worldInjections: worlds,
            ),
        maxContextTokens: 16000,
        truncateHistory: false,
      );
    }

    test('a supplied drawing contribution falls back by default', () {
      final result = assembleDrawing(
        context: const SillyTavernAssemblyContext(
          characterName: 'C',
          userName: 'U',
          characterDescription: '',
          scenario: '',
          drawingPromptContent: '  Draw a landscape.\n ',
        ),
      );
      expect(result.messages.single['content'], 'Draw a landscape.');
    });

    test('both drawing macros trim only contribution boundaries', () {
      for (final macro in ['drawing_prompt_pack', 'image_prompt_pack']) {
        final result = assembleDrawing(
          content: ' \n$drawing\n ',
          prompts: [
            {'identifier': 'main', 'content': 'Before {{$macro}} After'},
          ],
        );
        expect(result.messages.first['content'], 'Before $drawing After');
      }
      final empty = assembleDrawing(
        content: ' \n ',
        prompts: const [
          {'identifier': 'main', 'content': 'A{{drawing_prompt_pack}}B'},
        ],
      );
      expect(empty.messages.map((message) => message['content']), [
        'AB',
        'voice rules',
      ]);
    });

    for (final macro in [
      'drawing_prompt_pack',
      'image_prompt_pack',
      ' IMAGE_PROMPT_PACK ',
    ]) {
      test('$macro inserts only literal drawing text', () {
        final result = assembleDrawing(
          prompts: [
            {
              'identifier': 'main',
              'role': 'system',
              'content': 'Before {{$macro}} After',
            },
          ],
        );
        expect(result.messages.first['content'], 'Before $drawing After');
        expect(result.messages.last['content'], 'voice rules');
        expect(result.variables, isNot(contains('leak')));
        expect(result.unknownMacros, isEmpty);
      });
    }

    test(
      'setvar/getvar preserves literal payload and persisted variable values',
      () {
        final result = assembleDrawing(
          prompts: const [
            {
              'identifier': 'vars',
              'content': '{{setvar::draw::{{drawing_prompt_pack}}}}',
            },
            {'identifier': 'main', 'content': '{{getvar::draw}}'},
          ],
          variables: const {'secret': 'must-not-expand'},
        );
        expect(result.messages.first['content'], drawing);
        expect(result.variables['draw'], drawing);
        expect(result.variables, isNot(contains('leak')));
        final next = assembleDrawing(
          prompts: const [
            {'identifier': 'main', 'content': '{{getvar::draw}}'},
          ],
          variables: result.variables,
        );
        expect(next.messages.first['content'], drawing);
        expect(next.variables, isNot(contains('leak')));
      },
    );

    test('saving without emitting does not suppress automatic injection', () {
      final result = assembleDrawing(
        prompts: const [
          {
            'identifier': 'vars',
            'content': '{{setvar::draw::{{drawing_prompt_pack}}}}',
          },
        ],
      );
      expect(
        result.messages.map((message) => message['content']),
        contains(drawing),
      );
      expect(
        result.entries.any((entry) => entry.source == 'runtime.drawingPrompt'),
        isTrue,
      );
      expect(result.variables['draw'], drawing);
    });

    test('skipped or unplaced prompts do not suppress automatic injection', () {
      for (final prompt in <Map<String, dynamic>>[
        {
          'identifier': 'disabled',
          'content': '{{drawing_prompt_pack}}',
          'enabled': false,
        },
        {
          'identifier': 'ejs',
          'content': '<% unsupported %>{{drawing_prompt_pack}}',
        },
        {
          'identifier': 'mvu',
          'content': '{{get_message_variable::x}}{{drawing_prompt_pack}}',
        },
        {
          'identifier': 'absolute',
          'content': '{{drawing_prompt_pack}}',
          'injection_position': 1,
        },
      ]) {
        final result = assembleDrawing(
          prompts: [prompt],
          includeHistory: false,
        );
        expect(
          result.entries.any(
            (entry) => entry.source == 'runtime.drawingPrompt',
          ),
          isTrue,
          reason: prompt['identifier'].toString(),
        );
        expect(result.messages.last['content'], drawing);
      }
    });

    test('empty or non-injected contribution never enables fallback', () {
      final empty = assembleDrawing(
        content: '',
        prompts: const [
          {'identifier': 'main', 'content': 'A{{drawing_prompt_pack}}B'},
        ],
      );
      expect(empty.messages.first['content'], 'AB');
      expect(empty.unknownMacros, isEmpty);
      final unplaced = assembleDrawing(fallback: false);
      expect(unplaced.messages.single['content'], 'voice rules');
      final placed = assembleDrawing(
        fallback: false,
        prompts: const [
          {'identifier': 'main', 'content': '{{drawing_prompt_pack}}'},
        ],
      );
      expect(placed.messages.first['content'], drawing);
    });

    test(
      'assistant prefill and world injections can position the drawing text',
      () {
        final prefill = assembleDrawing(prefill: '{{drawing_prompt_pack}}');
        expect(prefill.messages.last['content'], drawing);
        expect(
          prefill.entries.any(
            (entry) => entry.source == 'runtime.drawingPrompt',
          ),
          isFalse,
        );
        for (final position in [0, 4]) {
          final world = assembleDrawing(
            prompts: const [
              {'identifier': 'worldInfoBefore', 'marker': true},
            ],
            worlds: [
              TavernWorldInjection(
                id: 'draw',
                content: '{{image_prompt_pack}}',
                position: position,
                depth: 0,
                role: 'system',
                order: 0,
              ),
            ],
          );
          expect(
            world.messages.map((message) => message['content']),
            contains(drawing),
          );
          expect(
            world.entries.any(
              (entry) => entry.source == 'runtime.drawingPrompt',
            ),
            isFalse,
          );
        }
      },
    );

    test(
      'late history trimming restores fallback when an attachment is removed',
      () {
        final full = assembleDrawing(
          prompts: const [
            {
              'identifier': 'draw',
              'content': '{{drawing_prompt_pack}}',
              'attach_index': 2,
              'attach_role': 'user',
              'attach_side': 'end',
            },
          ],
          history: const [
            {'role': 'user', 'content': 'old'},
            {'role': 'assistant', 'content': 'reply'},
            {'role': 'user', 'content': 'new'},
          ],
        );
        expect(
          full.entries.any((entry) => entry.source == 'runtime.drawingPrompt'),
          isFalse,
        );
        final trimmed = assembler.truncateAssembly(
          full,
          inputBudget: 2,
          estimateTokens: (messages) => messages.length,
        );
        expect(
          trimmed.messages.map((message) => message['content']),
          contains(drawing),
        );
        expect(
          trimmed.messages.map((message) => message['content']),
          contains('new'),
        );
        expect(
          trimmed.messages.map((message) => message['content']),
          isNot(contains('reply')),
        );
      },
    );

    test(
      'automatic fallback respects consecutive system message squashing',
      () {
        final result = assembleDrawing(
          squash: true,
          prompts: const [
            {'identifier': 'main', 'content': 'main'},
          ],
        );
        expect(
          result.messages.single['content'],
          'main\nvoice rules\n$drawing',
        );
        final trimmed = assembler.truncateAssembly(
          result,
          inputBudget: 10000,
          estimateTokens: (messages) => messages.length,
        );
        expect(trimmed.messages, result.messages);
      },
    );

    test('late fallback recovery keeps system message squashing', () {
      final full = assembleDrawing(
        squash: true,
        prompts: const [
          {
            'identifier': 'draw',
            'content': '{{drawing_prompt_pack}}',
            'attach_index': 2,
            'attach_role': 'user',
            'attach_side': 'end',
          },
        ],
        history: const [
          {'role': 'user', 'content': 'old'},
          {'role': 'user', 'content': 'new'},
        ],
      );
      final trimmed = assembler.truncateAssembly(
        full,
        inputBudget: 2,
        estimateTokens: (messages) => messages.length,
      );
      expect(trimmed.messages, [
        {'role': 'system', 'content': 'voice rules\n$drawing'},
        {'role': 'user', 'content': 'new'},
      ]);
    });

    test('fallback precedes history and prefill without other plugins', () {
      final result = assembleDrawing(
        runtimeContent: '',
        prefill: 'Start reply',
        history: const [
          {'role': 'user', 'content': 'new'},
        ],
      );
      expect(result.messages.map((message) => message['content']), [
        drawing,
        'new',
        'Start reply',
      ]);
    });

    test(
      'legacy callers and unpositioned presets keep automatic drawing rules',
      () {
        final result = assembleDrawing();
        expect(result.messages.map((message) => message['content']), [
          'voice rules',
          drawing,
        ]);
        expect(result.appliedMacros, isEmpty);
      },
    );
  });

  test('late preset window includes tool cost and preserves latest user', () {
    final preset = parser.parseSource(
      '''{"prompts":[{"identifier":"chatHistory","marker":true}],
      "prompt_order":[{"order":[{"identifier":"chatHistory","enabled":true}]}]}''',
      sourceFileName: 'window.json',
    );
    final full = assembler.assemble(
      preset: preset,
      historyMessages: const [
        {'role': 'user', 'content': 'old'},
        {'role': 'assistant', 'content': 'reply'},
        {'role': 'user', 'content': 'new'},
      ],
      context: const SillyTavernAssemblyContext(
        characterName: 'C',
        userName: 'U',
        characterDescription: '',
        scenario: '',
      ),
      maxContextTokens: 8000,
      truncateHistory: false,
    );
    final trimmed = assembler.truncateAssembly(
      full,
      inputBudget: 12,
      outputExceedsWindow: true,
      estimateTokens: (messages) => 10 + messages.length * 2,
    );
    expect(full.keptHistoryCount, 3);
    expect(trimmed.keptHistoryCount, 1);
    expect(trimmed.messages.single['content'], 'new');
    expect(trimmed.warnings, contains(contains('聊天记录中仍保留')));
    expect(trimmed.warnings, contains(contains('最大输出超过')));
  });

  test(
    'preserves prompt_order and expands dynamic markers and macros',
    () async {
      final source = await File(
        'test/fixtures/sillytavern/openai_default_shape.json',
      ).readAsString();
      final preset = parser.parseSource(source, sourceFileName: 'Default.json');
      final result = assembler.assemble(
        preset: preset,
        historyMessages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': '你好'},
          {'role': 'assistant', 'content': '你好呀'},
        ],
        context: const SillyTavernAssemblyContext(
          characterName: '爱丽丝',
          userName: '小云',
          characterDescription: '你是温柔的爱丽丝。',
          scenario: '两人在图书馆。',
          runtimeSystemContent: '只在必要时输出工具标签。',
        ),
        maxContextTokens: 16000,
      );

      expect(
        result.messages.map((message) => message['content']).toList(),
        <dynamic>[
          "Write 爱丽丝's next reply to 小云.",
          '你是温柔的爱丽丝。',
          '两人在图书馆。',
          '只在必要时输出工具标签。',
          '你好',
          '你好呀',
          'Stay in character.',
        ],
      );
      expect(result.historyIncluded, isTrue);
      // 空世界书是正常状态，不再报告“功能未实现”。
      expect(result.warnings, isNot(contains(contains('本批次按空节点处理'))));
    },
  );

  test(
    'absolute injections use depth then descending order and role groups',
    () {
      const source = '''
{
  "prompts": [
    {"identifier":"chatHistory","marker":true},
    {"identifier":"low","role":"system","content":"low","injection_position":1,"injection_depth":1,"injection_order":10},
    {"identifier":"low2","role":"system","content":"low2","injection_position":1,"injection_depth":1,"injection_order":10},
    {"identifier":"high","role":"system","content":"high","injection_position":1,"injection_depth":1,"injection_order":20},
    {"identifier":"userInject","role":"user","content":"user-inject","injection_position":1,"injection_depth":1,"injection_order":30}
  ],
  "prompt_order": [{"order":[
    {"identifier":"chatHistory","enabled":true},
    {"identifier":"low","enabled":true},
    {"identifier":"low2","enabled":true},
    {"identifier":"high","enabled":true},
    {"identifier":"userInject","enabled":true}
  ]}]
}
''';
      final preset = parser.parseSource(source, sourceFileName: 'inject.json');
      final result = assembler.assemble(
        preset: preset,
        historyMessages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'first'},
          {'role': 'assistant', 'content': 'latest'},
        ],
        context: const SillyTavernAssemblyContext(
          characterName: 'C',
          userName: 'U',
          characterDescription: '',
          scenario: '',
        ),
        maxContextTokens: 16000,
      );

      expect(
        result.messages.map((message) => message['content']).toList(),
        <dynamic>['first', 'low\nlow2', 'high', 'user-inject', 'latest'],
      );
    },
  );

  test('disabled chatHistory omits history but keeps runtime rules', () {
    const source = '''
{
  "prompts": [
    {"identifier":"main","role":"system","content":"main"},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":false}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'disabled.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: const <Map<String, dynamic>>[
        {'role': 'user', 'content': 'must-not-appear'},
      ],
      context: const SillyTavernAssemblyContext(
        characterName: 'C',
        userName: 'U',
        characterDescription: '',
        scenario: '',
        runtimeSystemContent: 'runtime',
        protectedRuntimeMessages: <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': '<system-reminder>\nnow\n</system-reminder>',
          },
        ],
      ),
      maxContextTokens: 16000,
    );

    expect(result.historyIncluded, isFalse);
    expect(
      result.messages.map((message) => message['content']).toList(),
      <dynamic>[
        'main',
        'runtime',
        '<system-reminder>\nnow\n</system-reminder>',
      ],
    );
  });

  test('token trimming drops oldest history without moving preset nodes', () {
    const source = '''
{
  "prompts": [
    {"identifier":"main","role":"system","content":"main"},
    {"identifier":"chatHistory","marker":true},
    {"identifier":"tail","role":"system","content":"tail"}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":true},
    {"identifier":"tail","enabled":true}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'trim.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: <Map<String, dynamic>>[
        {'role': 'user', 'content': 'old ${List.filled(200, 'x').join()}'},
        {
          'role': 'assistant',
          'content': 'middle ${List.filled(200, 'y').join()}',
        },
        {'role': 'user', 'content': 'latest'},
      ],
      context: const SillyTavernAssemblyContext(
        characterName: 'C',
        userName: 'U',
        characterDescription: '',
        scenario: '',
      ),
      maxContextTokens: 90,
      reserveTokens: 20,
    );

    expect(result.messages.first['content'], 'main');
    expect(result.messages.last['content'], 'tail');
    expect(
      result.messages.any((message) => message['content'] == 'latest'),
      isTrue,
    );
    expect(result.droppedHistoryCount, greaterThan(0));
  });

  test(
    'normal trigger skips quiet prompts and preserves unavailable macros',
    () {
      const source = '''
{
  "prompts": [
    {"identifier":"main","role":"system","content":"{{original}} {{futureMacro}}"},
    {"identifier":"quietOnly","role":"system","content":"quiet","injection_trigger":["quiet"]},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"quietOnly","enabled":true},
    {"identifier":"chatHistory","enabled":true}
  ]}]
}
''';
      final preset = parser.parseSource(source, sourceFileName: 'trigger.json');
      final result = assembler.assemble(
        preset: preset,
        historyMessages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'history'},
        ],
        context: const SillyTavernAssemblyContext(
          characterName: 'C',
          userName: 'U',
          characterDescription: '',
          scenario: '',
        ),
        maxContextTokens: 16000,
      );

      expect(result.messages.first['content'], '{{original}} {{futureMacro}}');
      expect(
        result.messages.any((message) => message['content'] == 'quiet'),
        isFalse,
      );
      expect(result.warnings, contains(contains('仅用于非 normal')));
      expect(result.warnings, contains(contains('已保留 {{original}}')));
      expect(result.warnings, contains(contains('futureMacro')));
    },
  );

  test('ARGO attachment appends ordered jailbreak prompts to last user', () {
    const source = '''
{
  "prompts": [
    {"identifier":"main","role":"system","content":"main"},
    {"identifier":"chatHistory","marker":true},
    {"identifier":"guard1","role":"system","content":"rule-1","attach_index":1,"attach_role":"user","attach_side":"end"},
    {"identifier":"guard2","role":"system","content":"rule-2","attach_index":1,"attach_role":"user","attach_side":"end"}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":true},
    {"identifier":"guard1","enabled":true},
    {"identifier":"guard2","enabled":true}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'argo.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: const <Map<String, dynamic>>[
        {'role': 'user', 'content': 'old user'},
        {'role': 'assistant', 'content': 'answer'},
        {'role': 'user', 'content': 'latest user'},
      ],
      context: const SillyTavernAssemblyContext(
        characterName: 'C',
        userName: 'U',
        characterDescription: '',
        scenario: '',
      ),
      maxContextTokens: 16000,
    );

    expect(
      result.messages.map((message) => message['content']).toList(),
      <dynamic>[
        'main',
        'old user',
        'answer',
        'latest user\n\nrule-1\n\nrule-2',
      ],
    );
    expect(
      result.messages.where((message) => message['role'] == 'system'),
      hasLength(1),
    );
    expect(result.entries.last.source, contains('attach.guard1+guard2'));
  });

  test('Cloud variables flow left-to-right across prompt nodes', () {
    const source = '''
{
  "prompts": [
    {"identifier":"vars","role":"system","content":"{{setvar::mode::bold}}{{setvar::topic::{{char}}}}"},
    {"identifier":"main","role":"system","content":"mode={{getvar::mode}} topic={{getvar::topic}}"},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"vars","enabled":true},
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":true}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'cloud.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: const <Map<String, dynamic>>[],
      context: const SillyTavernAssemblyContext(
        characterName: '爱丽丝',
        userName: 'U',
        characterDescription: '',
        scenario: '',
      ),
      maxContextTokens: 16000,
    );

    expect(result.messages.single['content'], 'mode=bold topic=爱丽丝');
    expect(result.variables, <String, String>{'mode': 'bold', 'topic': '爱丽丝'});
    expect(result.appliedMacros, containsAll(<String>['setvar', 'getvar']));
  });

  test('Two Rooms appends assistant prefill and squashes system messages', () {
    const source = '''
{
  "assistant_prefill": "思考已结束。",
  "squash_system_messages": true,
  "prompts": [
    {"identifier":"main","role":"system","content":"main"},
    {"identifier":"rules","role":"system","content":"rules"},
    {"identifier":"jailbreak","role":"system","content":""},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"rules","enabled":true},
    {"identifier":"jailbreak","enabled":true},
    {"identifier":"chatHistory","enabled":true}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'two.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: const <Map<String, dynamic>>[
        {'role': 'user', 'content': 'continue'},
      ],
      context: const SillyTavernAssemblyContext(
        characterName: 'C',
        userName: 'U',
        characterDescription: '',
        scenario: '',
      ),
      maxContextTokens: 16000,
    );

    expect(result.messages, <Map<String, dynamic>>[
      {'role': 'system', 'content': 'main\nrules'},
      {'role': 'user', 'content': 'continue'},
      {'role': 'assistant', 'content': '思考已结束。'},
    ]);
    expect(result.entries.last.protectedFromTruncation, isTrue);
  });
}
